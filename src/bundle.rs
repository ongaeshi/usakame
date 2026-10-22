#![allow(dead_code)]

#[cfg(not(target_arch = "wasm32"))]
use std::fs::File;
#[cfg(not(target_arch = "wasm32"))]
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// バイナリ末尾または配信バンドル末尾に付与するマジックナンバー (8 bytes)
pub const BUNDLE_MAGIC: &[u8; 8] = b"USAKAME1";
/// フッター全体のサイズ: tail_len (8B) + mrb_len (8B) + BUNDLE_MAGIC (8B) = 24 bytes
pub const FOOTER_SIZE: usize = 24;

const B64_CHARS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn encode_base64(input: &[u8]) -> String {
    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;

        out.push(B64_CHARS[((triple >> 18) & 0x3F) as usize] as char);
        out.push(B64_CHARS[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(B64_CHARS[((triple >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(B64_CHARS[(triple & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

pub fn decode_base64(input: &str) -> Result<Vec<u8>, String> {
    let mut clean = Vec::with_capacity(input.len());
    for line in input.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('#') {
            continue;
        }
        for b in trimmed.bytes() {
            if !b.is_ascii_whitespace() {
                clean.push(b);
            }
        }
    }
    if clean.is_empty() {
        return Ok(Vec::new());
    }

    let mut out = Vec::with_capacity(clean.len() * 3 / 4);
    let mut buf = 0u32;
    let mut bits = 0u8;

    for &b in &clean {
        if b == b'=' {
            break;
        }
        let val = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return Err(format!("Invalid Base64 character: `{}`", b as char)),
        };
        buf = (buf << 6) | (val as u32);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xFF) as u8);
        }
    }

    Ok(out)
}

/// `tail_data` (`__END__` 以降のリソース) と `.mrb` バイトコードを単一バイナリペイロードへパックする。
///
/// フォーマット:
/// `[tail_bytes][mrb_bytes][tail_len: u64 LE][mrb_len: u64 LE][b"USAKAME1"]`
pub fn pack_bundle(tail_data: &str, mrb_bytes: &[u8]) -> Vec<u8> {
    let tail_bytes = tail_data.as_bytes();
    let tail_len = tail_bytes.len() as u64;
    let mrb_len = mrb_bytes.len() as u64;

    let mut out = Vec::with_capacity(tail_bytes.len() + mrb_bytes.len() + FOOTER_SIZE);
    out.extend_from_slice(tail_bytes);
    out.extend_from_slice(mrb_bytes);
    out.extend_from_slice(&tail_len.to_le_bytes());
    out.extend_from_slice(&mrb_len.to_le_bytes());
    out.extend_from_slice(BUNDLE_MAGIC);
    out
}

/// バイト列末尾からバンドル (`tail_data`, `mrb_bytes`) を展開する。
/// 単体のバンドルデータにも、実行ファイル末尾に結合されたデータにも対応する。
pub fn unpack_bundle_from_bytes(bytes: &[u8]) -> Option<(String, Vec<u8>)> {
    let payload_offset = find_bundle_payload_offset(bytes)?;
    let footer_start = bytes.len() - FOOTER_SIZE;

    let tail_len = u64::from_le_bytes(bytes[footer_start..footer_start + 8].try_into().ok()?) as usize;
    let mrb_len = u64::from_le_bytes(bytes[footer_start + 8..footer_start + 16].try_into().ok()?) as usize;

    let tail_start = payload_offset;
    let mrb_start = tail_start + tail_len;
    let mrb_end = mrb_start + mrb_len;

    let tail_data = String::from_utf8(bytes[tail_start..mrb_start].to_vec()).ok()?;
    let mrb_bytes = bytes[mrb_start..mrb_end].to_vec();

    Some((tail_data, mrb_bytes))
}

/// 実行ファイル等のバイト列末尾にバンドルが存在する場合、その開始オフセットを返す。
pub fn find_bundle_payload_offset(bytes: &[u8]) -> Option<usize> {
    if bytes.len() < FOOTER_SIZE {
        return None;
    }
    let footer_start = bytes.len() - FOOTER_SIZE;
    if &bytes[footer_start + 16..footer_start + 24] != BUNDLE_MAGIC {
        return None;
    }

    let tail_len = u64::from_le_bytes(bytes[footer_start..footer_start + 8].try_into().ok()?) as usize;
    let mrb_len = u64::from_le_bytes(bytes[footer_start + 8..footer_start + 16].try_into().ok()?) as usize;
    let total_payload = tail_len.checked_add(mrb_len)?.checked_add(FOOTER_SIZE)?;

    if bytes.len() < total_payload {
        return None;
    }

    Some(bytes.len() - total_payload)
}

/// 実行ファイルのバイト列に既存のバンドルが付与されていれば除去したスライスを返す。
#[cfg(not(target_arch = "wasm32"))]
pub fn strip_bundle_from_exe_bytes(exe_bytes: &[u8]) -> &[u8] {
    if let Some(offset) = find_bundle_payload_offset(exe_bytes) {
        &exe_bytes[..offset]
    } else {
        exe_bytes
    }
}

/// 指定した実行ファイル末尾からバンドル (`tail_data`, `mrb_bytes`) を読み取る。
#[cfg(not(target_arch = "wasm32"))]
pub fn read_bundle_from_file(path: &Path) -> Option<(String, Vec<u8>)> {
    let mut file = File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    if file_len < FOOTER_SIZE as u64 {
        return None;
    }

    file.seek(SeekFrom::End(-(FOOTER_SIZE as i64))).ok()?;
    let mut footer = [0u8; FOOTER_SIZE];
    file.read_exact(&mut footer).ok()?;

    if &footer[16..24] != BUNDLE_MAGIC {
        return None;
    }

    let tail_len = u64::from_le_bytes(footer[0..8].try_into().ok()?);
    let mrb_len = u64::from_le_bytes(footer[8..16].try_into().ok()?);
    let payload_size = tail_len.checked_add(mrb_len)?.checked_add(FOOTER_SIZE as u64)?;

    if file_len < payload_size {
        return None;
    }

    let payload_start = file_len - payload_size;
    file.seek(SeekFrom::Start(payload_start)).ok()?;

    let mut tail_buf = vec![0u8; tail_len as usize];
    file.read_exact(&mut tail_buf).ok()?;
    let tail_data = String::from_utf8(tail_buf).ok()?;

    let mut mrb_bytes = vec![0u8; mrb_len as usize];
    file.read_exact(&mut mrb_bytes).ok()?;

    Some((tail_data, mrb_bytes))
}

/// 現在実行中のバイナリ (`std::env::current_exe()`) 末尾からバンドルを読み取る。
#[cfg(not(target_arch = "wasm32"))]
pub fn read_bundle_from_current_exe() -> Option<(String, Vec<u8>)> {
    let exe_path = std::env::current_exe().ok()?;
    read_bundle_from_file(&exe_path)
}

/// Ruby スクリプト全体を行単位で走査し、独立した行にある `__END__` を境界として
/// `(ruby_code, tail_data)` に分割する。
/// コメント行や文字列リテラル内に `__END__` という文字列が含まれていても誤検知しない。
pub fn split_ruby_source_and_tail(full_source: &str) -> (&str, &str) {
    let mut byte_offset = 0;
    for line in full_source.split_inclusive('\n') {
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed == "__END__"
            || (trimmed.starts_with("__END__")
                && trimmed[7..].chars().all(|c| c.is_whitespace() || c == '#'))
        {
            let code_part = &full_source[..byte_offset];
            let tail_part = &full_source[byte_offset + line.len()..];
            return (code_part, tail_part);
        }
        byte_offset += line.len();
    }
    (full_source, "")
}

/// Ruby スクリプト中の `config(...)` 呼び出しを検出し、波括弧がない場合は `config({...})` に正規化する。
///
/// mruby 3.0 (mruby_compiler2) は波括弧なしのキーワード引数を `karg` コール規約でコンパイルするため、
/// C拡張メソッド（mrubyedge）が第1引数として Hash を直接受領できるように `{ ... }` で囲む。
pub fn normalize_ruby_config_syntax(code: &str) -> String {
    let mut result = String::with_capacity(code.len() + 16);
    let mut cursor = 0;
    while let Some(pos) = code[cursor..].find("config") {
        let abs_pos = cursor + pos;
        let before = if abs_pos > 0 { code.as_bytes()[abs_pos - 1] } else { b' ' };
        if before.is_ascii_alphanumeric() || before == b'_' {
            result.push_str(&code[cursor..=abs_pos]);
            cursor = abs_pos + 1;
            continue;
        }

        let after_config = &code[abs_pos + 6..];
        let trimmed_after = after_config.trim_start();
        if !trimmed_after.starts_with('(') {
            result.push_str(&code[cursor..abs_pos + 6]);
            cursor = abs_pos + 6;
            continue;
        }

        let open_paren_idx = abs_pos + 6 + (after_config.len() - trimmed_after.len());
        let mut depth = 0;
        let mut close_paren_idx = None;
        let mut in_string = None;
        let bytes = code.as_bytes();
        let mut i = open_paren_idx;
        while i < bytes.len() {
            let b = bytes[i];
            if let Some(quote) = in_string {
                if b == quote && (i == 0 || bytes[i - 1] != b'\\') {
                    in_string = None;
                }
            } else if b == b'"' || b == b'\'' {
                in_string = Some(b);
            } else if b == b'(' {
                depth += 1;
            } else if b == b')' {
                depth -= 1;
                if depth == 0 {
                    close_paren_idx = Some(i);
                    break;
                }
            }
            i += 1;
        }

        if let Some(close_idx) = close_paren_idx {
            let inner = &code[open_paren_idx + 1..close_idx];
            let trimmed_inner = inner.trim();
            if !trimmed_inner.is_empty()
                && !(trimmed_inner.starts_with('{') && trimmed_inner.ends_with('}'))
            {
                result.push_str(&code[cursor..open_paren_idx + 1]);
                result.push('{');
                result.push_str(inner);
                result.push('}');
                result.push(')');
                cursor = close_idx + 1;
                continue;
            }
        }

        result.push_str(&code[cursor..abs_pos + 6]);
        cursor = abs_pos + 6;
    }
    result.push_str(&code[cursor..]);
    result
}

/// 外部リソースとして自動認識・マージされる拡張子リスト（優先度順）
pub const ASSOCIATED_RESOURCE_EXTENSIONS: &[&str] = &["res", "spr", "map", "sfx"];

/// 対象スクリプト（例: `game.rb`）と同ディレクトリにある外部リソースファイルを検索する。
pub fn find_associated_resource_paths(script_path: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let parent = script_path.parent().unwrap_or_else(|| Path::new(""));
    let stem = match script_path.file_stem().and_then(|s| s.to_str()) {
        Some(s) => s,
        None => return found,
    };

    for ext in ASSOCIATED_RESOURCE_EXTENSIONS {
        let candidate = if parent.as_os_str().is_empty() {
            PathBuf::from(format!("{}.{}", stem, ext))
        } else {
            parent.join(format!("{}.{}", stem, ext))
        };
        if candidate.is_file() {
            found.push(candidate);
        }
    }
    found
}

/// スクリプト本体および関連する外部リソースファイルの更新日時スナップショットを取得する。
/// ファイルの増減や更新を検知するために使用する。
#[cfg(not(target_arch = "wasm32"))]
pub fn get_script_and_resources_snapshot(
    script_path: &Path,
) -> (Option<SystemTime>, Vec<(PathBuf, Option<SystemTime>)>) {
    let script_mod = std::fs::metadata(script_path).and_then(|m| m.modified()).ok();
    let res_paths = find_associated_resource_paths(script_path);
    let mut res_mods = Vec::with_capacity(res_paths.len());
    for p in res_paths {
        let m = std::fs::metadata(&p).and_then(|meta| meta.modified()).ok();
        res_mods.push((p, m));
    }
    (script_mod, res_mods)
}

/// 埋め込み `tail_data` と、外部リソースファイルの内容をマージした `tail_data` を生成する。
/// 外部リソースの内容は末尾に追加されるため、同一IDのスプライトやマップ、効果音は外部定義で上書きされます。
/// 戻り値: (マージ後 tail_data, 検出された外部リソースのパス一覧)
pub fn load_merged_tail_data(script_path: &Path, embedded_tail: &str) -> (String, Vec<PathBuf>) {
    let res_paths = find_associated_resource_paths(script_path);
    if res_paths.is_empty() {
        return (embedded_tail.to_string(), res_paths);
    }

    let mut merged = String::with_capacity(embedded_tail.len() + 1024);
    merged.push_str(embedded_tail);
    if !merged.is_empty() && !merged.ends_with('\n') {
        merged.push('\n');
    }

    for path in &res_paths {
        if let Ok(content) = std::fs::read_to_string(path) {
            let fname = path
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("res");
            merged.push_str(&format!("# --- Loaded external resource: {} ---\n", fname));
            merged.push_str(&content);
            if !merged.ends_with('\n') {
                merged.push('\n');
            }
        }
    }

    (merged, res_paths)
}

/// 対象スクリプトとその外部リソース（`.spr`, `.map`, `.sfx`, `.res`）を結合し、
/// 完全に自立した単一の Ruby スクリプト文字列を生成する。
pub fn pack_script_to_standalone_source(script_path: &Path) -> Result<String, String> {
    let full_source = std::fs::read_to_string(script_path)
        .map_err(|e| format!("Failed to read script `{}`: {}", script_path.display(), e))?;

    let (ruby_code, embedded_tail) = split_ruby_source_and_tail(&full_source);
    let (merged_tail, _) = load_merged_tail_data(script_path, embedded_tail);
    let parent_dir = script_path.parent().unwrap_or_else(|| Path::new(""));
    let final_tail = inline_bank_file_paths_in_tail(&merged_tail, parent_dir);

    let trimmed_code = ruby_code.trim_end();
    if final_tail.trim().is_empty() {
        Ok(trimmed_code.to_string() + "\n")
    } else {
        Ok(format!("{}\n\n__END__\n{}", trimmed_code, final_tail))
    }
}

/// `@BANK <id> path/to/image.png` のような外部ファイル参照を Base64 にインライン化する
pub fn inline_bank_file_paths_in_tail(tail_data: &str, base_dir: &Path) -> String {
    let mut out_lines = Vec::new();
    let mut in_bank_block = false;
    let mut current_bank_id = None;

    for line in tail_data.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("@SHEET") {
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(id) = id_str.parse::<i32>()
            {
                let mut dims = None;
                let mut file_path = None;
                for tok in parts {
                    if tok.contains('x') || tok.contains('X') {
                        dims = Some(tok);
                    } else if file_path.is_none() {
                        file_path = Some(tok);
                    }
                }
                if let Some(path_str) = file_path {
                    let path_candidate = base_dir.join(path_str);
                    if path_candidate.is_file() {
                        if let Ok(bytes) = std::fs::read(&path_candidate) {
                            let b64 = encode_base64(&bytes);
                            let dims_str = dims.unwrap_or("16x16");
                            out_lines.push(format!("@SHEET {} {}", id, dims_str));
                            out_lines.push(b64);
                            continue;
                        }
                    }
                }
            }
            out_lines.push(line.to_string());
            continue;
        }

        if let Some(rest) = trimmed.strip_prefix("@BANK") {
            in_bank_block = true;
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(id) = id_str.parse::<i32>()
            {
                current_bank_id = Some(id);
                let inline_content = parts.collect::<Vec<_>>().join(" ");
                if !inline_content.is_empty() {
                    let path_candidate = base_dir.join(&inline_content);
                    if path_candidate.is_file() {
                        if let Ok(bytes) = std::fs::read(&path_candidate) {
                            let b64 = encode_base64(&bytes);
                            out_lines.push(format!("@BANK {}", id));
                            out_lines.push(b64);
                            in_bank_block = false;
                            continue;
                        }
                    }
                }
            }
            out_lines.push(line.to_string());
            continue;
        }

        if in_bank_block {
            if trimmed.starts_with('@') {
                in_bank_block = false;
                current_bank_id = None;
            } else if let Some(_id) = current_bank_id {
                let path_candidate = base_dir.join(trimmed);
                if path_candidate.is_file() {
                    if let Ok(bytes) = std::fs::read(&path_candidate) {
                        let b64 = encode_base64(&bytes);
                        out_lines.push(b64);
                        in_bank_block = false;
                        current_bank_id = None;
                        continue;
                    }
                }
            }
        }

        out_lines.push(line.to_string());
    }

    out_lines.join("\n")
}

/// `tail_data` の各行・ブロックを、スプライト／マップ／サウンドに分類して抽出する。
/// 戻り値: (spr_text, map_text, sfx_text)
pub fn unpack_tail_data_to_sections(
    tail_data: &str,
) -> (Option<String>, Option<String>, Option<String>) {
    let mut spr_blocks = Vec::new();
    let mut map_blocks = Vec::new();
    let mut sfx_blocks = Vec::new();

    #[derive(Debug, PartialEq, Eq, Clone, Copy)]
    enum Category {
        Sprite,
        Map,
        Sound,
    }

    let mut current_cat: Option<Category> = None;
    let mut current_lines: Vec<&str> = Vec::new();

    for line in tail_data.lines() {
        let trimmed = line.trim();
        let detected = if trimmed.starts_with("@SPRITE")
            || trimmed.starts_with("@BANK")
            || trimmed.starts_with("@PNG")
            || trimmed.starts_with("@SHEET")
            || trimmed.starts_with("@B64")
        {
            Some(Category::Sprite)
        } else if trimmed.starts_with("@MAP") || trimmed.starts_with("@OBJECTS") {
            Some(Category::Map)
        } else if trimmed.starts_with("@SFX")
            || trimmed.starts_with("@MUSIC")
            || trimmed.starts_with("@WAV")
            || trimmed.starts_with("@OGG")
        {
            Some(Category::Sound)
        } else {
            None
        };

        if let Some(new_cat) = detected {
            if let Some(cat) = current_cat {
                let text = current_lines.join("\n");
                match cat {
                    Category::Sprite => spr_blocks.push(text),
                    Category::Map => map_blocks.push(text),
                    Category::Sound => sfx_blocks.push(text),
                }
                current_lines.clear();
            }
            current_cat = Some(new_cat);
        }
        current_lines.push(line);
    }

    if let Some(cat) = current_cat {
        let text = current_lines.join("\n");
        match cat {
            Category::Sprite => spr_blocks.push(text),
            Category::Map => map_blocks.push(text),
            Category::Sound => sfx_blocks.push(text),
        }
    }

    let spr_opt = if spr_blocks.is_empty() {
        None
    } else {
        Some(spr_blocks.join("\n\n") + "\n")
    };
    let map_opt = if map_blocks.is_empty() {
        None
    } else {
        Some(map_blocks.join("\n\n") + "\n")
    };
    let sfx_opt = if sfx_blocks.is_empty() {
        None
    } else {
        Some(sfx_blocks.join("\n\n") + "\n")
    };

    (spr_opt, map_opt, sfx_opt)
}

/// 対象スクリプトの `__END__` からリソースを抽出し、外部ファイル（`<stem>.spr`, `<stem>.map`, `<stem>.sfx`）に展開する。
pub fn unpack_script_to_files(script_path: &Path) -> Result<Vec<PathBuf>, String> {
    let full_source = std::fs::read_to_string(script_path)
        .map_err(|e| format!("Failed to read script `{}`: {}", script_path.display(), e))?;

    let (_, tail_data) = split_ruby_source_and_tail(&full_source);
    if tail_data.trim().is_empty() {
        return Err(format!(
            "Script `{}` does not have any `__END__` resource section.",
            script_path.display()
        ));
    }

    let parent = script_path.parent().unwrap_or_else(|| Path::new(""));
    let stem = script_path
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or_else(|| format!("Invalid script file name: {}", script_path.display()))?;

    let (spr_text, map_text, sfx_text) = unpack_tail_data_to_sections(tail_data);
    let mut generated = Vec::new();

    if let Some(text) = spr_text {
        let p = parent.join(format!("{}.spr", stem));
        std::fs::write(&p, text).map_err(|e| format!("Failed to write `{}`: {}", p.display(), e))?;
        generated.push(p);
    }
    if let Some(text) = map_text {
        let p = parent.join(format!("{}.map", stem));
        std::fs::write(&p, text).map_err(|e| format!("Failed to write `{}`: {}", p.display(), e))?;
        generated.push(p);
    }
    if let Some(text) = sfx_text {
        let p = parent.join(format!("{}.sfx", stem));
        std::fs::write(&p, text).map_err(|e| format!("Failed to write `{}`: {}", p.display(), e))?;
        generated.push(p);
    }

    if generated.is_empty() {
        return Err(format!(
            "No extractable resources found in `__END__` of `{}`",
            script_path.display()
        ));
    }

    Ok(generated)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_ruby_config_syntax() {
        let raw = "config(width: 640, height: 480)\ndef update\nend";
        assert_eq!(
            normalize_ruby_config_syntax(raw),
            "config({width: 640, height: 480})\ndef update\nend"
        );

        let multi = "config(\n  width: 640,\n  height: 480\n)";
        assert_eq!(
            normalize_ruby_config_syntax(multi),
            "config({\n  width: 640,\n  height: 480\n})"
        );

        let already_braced = "config({ width: 640, height: 480 })";
        assert_eq!(
            normalize_ruby_config_syntax(already_braced),
            "config({ width: 640, height: 480 })"
        );

        let other = "configure(123)\nmy_config(456)";
        assert_eq!(normalize_ruby_config_syntax(other), other);
    }

    #[test]
    fn test_unpack_tail_data_to_sections() {
        let tail = r#"
# sprites
@SPRITE 0
0123
4567

# maps
@MAP
0 1 2

# sounds
@SFX 0
c2 e2 g2
"#;
        let (spr, map, sfx) = unpack_tail_data_to_sections(tail);
        assert!(spr.is_some());
        assert!(map.is_some());
        assert!(sfx.is_some());

        let spr_str = spr.unwrap();
        assert!(spr_str.contains("@SPRITE 0"));
        assert!(!spr_str.contains("@MAP"));

        let map_str = map.unwrap();
        assert!(map_str.contains("@MAP"));
        assert!(!map_str.contains("@SFX"));

        let sfx_str = sfx.unwrap();
        assert!(sfx_str.contains("@SFX 0"));
        assert!(!sfx_str.contains("@SPRITE"));
    }

    #[test]
    fn test_inline_bank_file_paths_in_tail() {
        let temp_dir = std::env::temp_dir().join("test_inline_bank");
        let _ = std::fs::create_dir_all(&temp_dir);
        let png_file = temp_dir.join("test.png");
        std::fs::write(&png_file, b"FAKE_PNG_BYTES").unwrap();

        let tail = "@BANK 0 test.png\n@MAP\n0 0\n";
        let inlined = inline_bank_file_paths_in_tail(tail, &temp_dir);

        assert!(inlined.contains("@BANK 0"));
        assert!(inlined.contains(&encode_base64(b"FAKE_PNG_BYTES")));
        assert!(!inlined.contains("test.png"));
        assert!(inlined.contains("@MAP"));

        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}

