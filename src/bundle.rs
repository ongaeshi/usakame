#![allow(dead_code)]

#[cfg(not(target_arch = "wasm32"))]
use std::fs::File;
#[cfg(not(target_arch = "wasm32"))]
use std::io::{Read, Seek, SeekFrom};
#[cfg(not(target_arch = "wasm32"))]
use std::path::Path;

/// バイナリ末尾または配信バンドル末尾に付与するマジックナンバー (8 bytes)
pub const BUNDLE_MAGIC: &[u8; 8] = b"USAKAME1";
/// フッター全体のサイズ: tail_len (8B) + mrb_len (8B) + BUNDLE_MAGIC (8B) = 24 bytes
pub const FOOTER_SIZE: usize = 24;

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
}
