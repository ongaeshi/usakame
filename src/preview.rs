use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use crate::bundle::{load_merged_tail_data, split_ruby_source_and_tail};
use crate::emoji::EmojiAtlas;
use crate::font::FONT_5X7;
use crate::sound::{
    MusicData, SAMPLE_RATE, SfxData, SoundKey, is_builtin_preset, parse_tail_sounds,
    synthesize_preset_pcm,
};
use crate::{SpriteData, parse_tail_resources_full};

// ==========================================
// 共通 RGBA 描画・PNG 書き出しヘルパ
// ==========================================

pub fn write_rgba_png(path: &Path, rgba: &[u8], width: usize, height: usize) -> Result<(), String> {
    if rgba.len() != width * height * 4 {
        return Err(format!(
            "Invalid RGBA buffer length: expected {}, got {}",
            width * height * 4,
            rgba.len()
        ));
    }
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
        && !parent.exists()
    {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create output directory `{}`: {}", parent.display(), e))?;
    }

    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, width as u32, height as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Fast);
        let mut writer = encoder
            .write_header()
            .map_err(|e| format!("PNG write_header error: {:?}", e))?;
        writer
            .write_image_data(rgba)
            .map_err(|e| format!("PNG write_image_data error: {:?}", e))?;
    }

    fs::write(path, out)
        .map_err(|e| format!("Failed to write PNG `{}`: {}", path.display(), e))?;
    Ok(())
}

fn fill_rect_rgba(
    buf: &mut [u8],
    buf_w: usize,
    buf_h: usize,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: [u8; 4],
) {
    let x0 = x.max(0) as usize;
    let y0 = y.max(0) as usize;
    let x1 = (x + w).min(buf_w as i32).max(0) as usize;
    let y1 = (y + h).min(buf_h as i32).max(0) as usize;
    if x0 >= x1 || y0 >= y1 {
        return;
    }
    for py in y0..y1 {
        for px in x0..x1 {
            let off = (py * buf_w + px) * 4;
            buf[off..off + 4].copy_from_slice(&color);
        }
    }
}

fn draw_rect_outline_rgba(
    buf: &mut [u8],
    buf_w: usize,
    buf_h: usize,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: [u8; 4],
) {
    if w <= 0 || h <= 0 {
        return;
    }
    fill_rect_rgba(buf, buf_w, buf_h, x, y, w, 1, color);
    fill_rect_rgba(buf, buf_w, buf_h, x, y + h - 1, w, 1, color);
    fill_rect_rgba(buf, buf_w, buf_h, x, y, 1, h, color);
    fill_rect_rgba(buf, buf_w, buf_h, x + w - 1, y, 1, h, color);
}

fn draw_text_rgba(
    buf: &mut [u8],
    buf_w: usize,
    buf_h: usize,
    x: i32,
    y: i32,
    text: &str,
    color: [u8; 4],
    scale: usize,
) {
    let s = scale.max(1);
    let mut cx = x;
    for ch in text.chars() {
        let code = ch as u32;
        if (0x20..=0x7E).contains(&code) {
            let glyph = FONT_5X7[(code - 0x20) as usize];
            for (row, bits) in glyph.iter().enumerate() {
                for col in 0..5 {
                    if (bits & (1 << (4 - col))) != 0 {
                        fill_rect_rgba(
                            buf,
                            buf_w,
                            buf_h,
                            cx + (col * s) as i32,
                            y + (row * s) as i32,
                            s as i32,
                            s as i32,
                            color,
                        );
                    }
                }
            }
        } else if ch != ' ' {
            // 非ASCII文字のフォールバック矩形枠
            draw_rect_outline_rgba(
                buf,
                buf_w,
                buf_h,
                cx,
                y,
                (5 * s) as i32,
                (7 * s) as i32,
                color,
            );
        }
        cx += (6 * s) as i32;
    }
}

fn blend_pixel(dst: &mut [u8], src: [u8; 4]) {
    let a = src[3] as u32;
    if a == 0 {
        return;
    }
    if a == 255 {
        dst.copy_from_slice(&src);
        return;
    }
    let inv = 255 - a;
    dst[0] = ((src[0] as u32 * a + dst[0] as u32 * inv) / 255) as u8;
    dst[1] = ((src[1] as u32 * a + dst[1] as u32 * inv) / 255) as u8;
    dst[2] = ((src[2] as u32 * a + dst[2] as u32 * inv) / 255) as u8;
    dst[3] = 255;
}

// ==========================================
// リソース読み込み共通ヘルパ
// ==========================================

pub fn load_tail_data_from_path(path: &Path) -> Result<String, String> {
    let content = fs::read_to_string(path)
        .map_err(|e| format!("Failed to read `{}`: {}", path.display(), e))?;
    let is_rb = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.eq_ignore_ascii_case("rb"))
        .unwrap_or(false);
    if is_rb {
        let (_, embedded_tail) = split_ruby_source_and_tail(&content);
        let (merged_tail, _) = load_merged_tail_data(path, embedded_tail);
        Ok(merged_tail)
    } else {
        Ok(content)
    }
}

// ==========================================
// `uk preview spr` / `uk spr`
// ==========================================

pub struct SpritePreviewItem {
    pub label: String,
    pub meta: String,
    pub sort_id: i32,
    pub frames: Vec<(i32, SpriteData)>,
}

fn sanitize_filename_part(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.trim().trim_start_matches(':').chars() {
        if ch.is_ascii_alphanumeric() || ch == '_' || ch == '-' {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        "sprite".to_string()
    } else {
        out
    }
}

fn default_spr_output_path(script_path: &Path, target: Option<&str>) -> PathBuf {
    let stem = script_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("sprites");
    if let Some(t) = target {
        PathBuf::from(format!("screenshots/{}_{}.png", stem, sanitize_filename_part(t)))
    } else {
        PathBuf::from(format!("screenshots/{}_sprites.png", stem))
    }
}

fn resolve_sprite_items(
    sprites: &HashMap<i32, SpriteData>,
    name_table: &HashMap<String, Vec<i32>>,
    target: Option<&str>,
    script_path: &Path,
) -> Result<Vec<SpritePreviewItem>, String> {
    if let Some(t) = target {
        let clean = t.trim().trim_start_matches(':');
        let matched_ids = name_table
            .get(clean)
            .or_else(|| name_table.get(t.trim()))
            .or_else(|| {
                let lower = clean.to_ascii_lowercase();
                name_table
                    .iter()
                    .find(|(k, _)| !k.starts_with(':') && k.to_ascii_lowercase() == lower)
                    .map(|(_, v)| v)
            });

        if let Some(ids) = matched_ids {
            let mut frames = Vec::new();
            for &id in ids {
                if let Some(sp) = sprites.get(&id) {
                    frames.push((id, sp.clone()));
                }
            }
            if !frames.is_empty() {
                let first = &frames[0].1;
                let meta = format!(
                    "{}x{} {}f pal:{}",
                    first.width,
                    first.height,
                    frames.len(),
                    first.palette_id
                );
                return Ok(vec![SpritePreviewItem {
                    label: format!(":{}", clean),
                    meta,
                    sort_id: ids[0],
                    frames,
                }]);
            }
        }

        if let Ok(id) = clean.trim_start_matches('#').parse::<i32>()
            && let Some(sp) = sprites.get(&id)
        {
            let meta = format!("{}x{} pal:{}", sp.width, sp.height, sp.palette_id);
            return Ok(vec![SpritePreviewItem {
                label: format!("#{}", id),
                meta,
                sort_id: id,
                frames: vec![(id, sp.clone())],
            }]);
        }

        let atlas = EmojiAtlas::new();
        if let Some(sp) = atlas.extract_sprite(t.trim()) {
            let meta = format!("{}x{} emoji", sp.width, sp.height);
            return Ok(vec![SpritePreviewItem {
                label: t.trim().to_string(),
                meta,
                sort_id: -1,
                frames: vec![(-1, sp)],
            }]);
        }

        return Err(format!(
            "Sprite `{}` not found in `{}`",
            t,
            script_path.display()
        ));
    }

    // 全スプライト収集（名前付き + 未命名）
    let mut covered_ids: HashSet<i32> = HashSet::new();
    let mut items: Vec<SpritePreviewItem> = Vec::new();

    let mut named_entries: Vec<(&String, &Vec<i32>)> = name_table
        .iter()
        .filter(|(k, _)| !k.starts_with(':'))
        .collect();
    named_entries.sort_by(|a, b| {
        let aid = a.1.first().copied().unwrap_or(i32::MAX);
        let bid = b.1.first().copied().unwrap_or(i32::MAX);
        aid.cmp(&bid).then_with(|| a.0.cmp(b.0))
    });

    for (name, ids) in named_entries {
        let mut frames = Vec::new();
        for &id in ids {
            if let Some(sp) = sprites.get(&id) {
                covered_ids.insert(id);
                frames.push((id, sp.clone()));
            }
        }
        if !frames.is_empty() {
            let first = &frames[0].1;
            let meta = if frames.len() > 1 {
                format!("{}x{} {}f", first.width, first.height, frames.len())
            } else {
                format!("{}x{}", first.width, first.height)
            };
            items.push(SpritePreviewItem {
                label: format!(":{} #{}", name, ids[0]),
                meta,
                sort_id: ids[0],
                frames,
            });
        }
    }

    let mut unnamed_ids: Vec<i32> = sprites
        .keys()
        .copied()
        .filter(|id| !covered_ids.contains(id))
        .collect();
    unnamed_ids.sort();

    for id in unnamed_ids {
        if let Some(sp) = sprites.get(&id) {
            items.push(SpritePreviewItem {
                label: format!("#{}", id),
                meta: format!("{}x{}", sp.width, sp.height),
                sort_id: id,
                frames: vec![(id, sp.clone())],
            });
        }
    }

    items.sort_by_key(|it| it.sort_id);
    if items.is_empty() {
        return Err(format!(
            "No sprites found in `{}`",
            script_path.display()
        ));
    }
    Ok(items)
}

pub fn render_sprites_overview_rgba(
    items: &[SpritePreviewItem],
    header_title: &str,
    scale: usize,
) -> (Vec<u8>, usize, usize) {
    let scale = scale.clamp(1, 32);
    let pad = 10usize;
    let header_h = 22usize;
    let label_h = 18usize;
    let frame_gap = 6usize;
    let card_pad = 6usize;
    let min_card_w = 88usize;
    let max_row_w = 1024usize;

    struct CardLayout {
        item_idx: usize,
        w: usize,
        h: usize,
        frames_w: usize,
        frames_h: usize,
    }

    let mut cards = Vec::with_capacity(items.len());
    for (idx, item) in items.iter().enumerate() {
        let frames_w: usize = item
            .frames
            .iter()
            .map(|(_, sp)| sp.width as usize * scale)
            .sum::<usize>()
            + frame_gap * item.frames.len().saturating_sub(1);
        let frames_h: usize = item
            .frames
            .iter()
            .map(|(_, sp)| sp.height as usize * scale)
            .max()
            .unwrap_or(16 * scale);
        let label_min_w = item.label.chars().count().max(item.meta.chars().count()) * 6 + card_pad * 2;
        let card_w = (frames_w + card_pad * 2).max(min_card_w).max(label_min_w);
        let card_h = label_h + frames_h + card_pad * 2;
        cards.push(CardLayout {
            item_idx: idx,
            w: card_w,
            h: card_h,
            frames_w,
            frames_h,
        });
    }

    // 行折り返しレイアウト計算
    let mut rows: Vec<(Vec<(usize, usize, usize)>, usize, usize)> = Vec::new(); // (vec<(card_idx, x, y)>, row_w, row_h)
    let mut cur_row: Vec<(usize, usize, usize)> = Vec::new();
    let mut cur_x = pad;
    let mut cur_y = header_h + pad;
    let mut row_max_h = 0usize;

    for (ci, card) in cards.iter().enumerate() {
        if !cur_row.is_empty() && cur_x + card.w + pad > max_row_w {
            let row_w = cur_x;
            rows.push((std::mem::take(&mut cur_row), row_w, row_max_h));
            cur_y += row_max_h + pad;
            cur_x = pad;
            row_max_h = 0;
        }
        cur_row.push((ci, cur_x, cur_y));
        cur_x += card.w + pad;
        row_max_h = row_max_h.max(card.h);
    }
    if !cur_row.is_empty() {
        rows.push((cur_row, cur_x, row_max_h));
    }

    let min_header_w = header_title.chars().count() * 6 + pad * 2;
    let canvas_w = rows
        .iter()
        .map(|(_, rw, _)| *rw)
        .max()
        .unwrap_or(320)
        .max(min_header_w)
        .max(240);
    let canvas_h = rows
        .last()
        .map(|(r, _, rh)| r[0].2 + rh + pad)
        .unwrap_or(header_h + pad * 2);

    let mut buf = vec![0u8; canvas_w * canvas_h * 4];
    // 背景
    fill_rect_rgba(
        &mut buf,
        canvas_w,
        canvas_h,
        0,
        0,
        canvas_w as i32,
        canvas_h as i32,
        [24, 26, 32, 255],
    );
    // ヘッダバー
    fill_rect_rgba(
        &mut buf,
        canvas_w,
        canvas_h,
        0,
        0,
        canvas_w as i32,
        header_h as i32,
        [34, 38, 48, 255],
    );
    fill_rect_rgba(
        &mut buf,
        canvas_w,
        canvas_h,
        0,
        header_h as i32 - 1,
        canvas_w as i32,
        1,
        [62, 68, 84, 255],
    );
    draw_text_rgba(
        &mut buf,
        canvas_w,
        canvas_h,
        pad as i32,
        7,
        header_title,
        [235, 240, 250, 255],
        1,
    );

    let checker_sz = scale.max(4);
    let checker_a = [58u8, 63, 75, 255];
    let checker_b = [44u8, 48, 58, 255];

    for (row_cards, _, _) in rows {
        for (ci, cx, cy) in row_cards {
            let card = &cards[ci];
            let item = &items[card.item_idx];

            // カード背景＆枠
            fill_rect_rgba(
                &mut buf,
                canvas_w,
                canvas_h,
                cx as i32,
                cy as i32,
                card.w as i32,
                card.h as i32,
                [30, 33, 42, 255],
            );
            draw_rect_outline_rgba(
                &mut buf,
                canvas_w,
                canvas_h,
                cx as i32,
                cy as i32,
                card.w as i32,
                card.h as i32,
                [66, 72, 88, 255],
            );

            // ラベル & メタ情報
            draw_text_rgba(
                &mut buf,
                canvas_w,
                canvas_h,
                (cx + card_pad) as i32,
                (cy + 4) as i32,
                &item.label,
                [255, 236, 120, 255],
                1,
            );
            draw_text_rgba(
                &mut buf,
                canvas_w,
                canvas_h,
                (cx + card_pad) as i32,
                (cy + 13) as i32,
                &item.meta,
                [160, 172, 194, 255],
                1,
            );

            // フレーム群を中央寄せで描画
            let mut fx = cx + (card.w.saturating_sub(card.frames_w)) / 2;
            let fy_base = cy + card_pad + label_h;

            for (_, sp) in &item.frames {
                let fw = sp.width as usize * scale;
                let fh = sp.height as usize * scale;
                let fy = fy_base + (card.frames_h.saturating_sub(fh)) / 2;

                // 市松背景
                for py in 0..fh {
                    for px in 0..fw {
                        let is_a = ((px / checker_sz) + (py / checker_sz)) % 2 == 0;
                        let bg = if is_a { checker_a } else { checker_b };
                        let off = ((fy + py) * canvas_w + (fx + px)) * 4;
                        buf[off..off + 4].copy_from_slice(&bg);
                    }
                }

                // スプライトピクセル拡大描画
                for sy in 0..sp.height as usize {
                    for sx in 0..sp.width as usize {
                        let src_off = (sy * sp.width as usize + sx) * 4;
                        let src_px = [
                            sp.rgba[src_off],
                            sp.rgba[src_off + 1],
                            sp.rgba[src_off + 2],
                            sp.rgba[src_off + 3],
                        ];
                        if src_px[3] == 0 {
                            continue;
                        }
                        for dy in 0..scale {
                            for dx in 0..scale {
                                let dst_off =
                                    ((fy + sy * scale + dy) * canvas_w + (fx + sx * scale + dx)) * 4;
                                blend_pixel(&mut buf[dst_off..dst_off + 4], src_px);
                            }
                        }
                    }
                }

                // 枠線
                draw_rect_outline_rgba(
                    &mut buf,
                    canvas_w,
                    canvas_h,
                    fx as i32 - 1,
                    fy as i32 - 1,
                    fw as i32 + 2,
                    fh as i32 + 2,
                    [88, 96, 116, 255],
                );

                fx += fw + frame_gap;
            }
        }
    }

    (buf, canvas_w, canvas_h)
}

pub fn cmd_preview_spr(
    script_path: &Path,
    target: Option<&str>,
    output_path: Option<&Path>,
    scale_opt: Option<usize>,
) -> Result<(), String> {
    let tail_data = load_tail_data_from_path(script_path)?;
    let base_dir = script_path.parent();
    let (sprites, _banks, palettes, name_table) = parse_tail_resources_full(&tail_data, base_dir);

    let items = resolve_sprite_items(&sprites, &name_table, target, script_path)?;
    let total_frames: usize = items.iter().map(|it| it.frames.len()).sum();
    let scale = scale_opt
        .unwrap_or(if target.is_some() { 8 } else { 4 })
        .clamp(1, 32);

    let custom_pal_count = palettes.keys().filter(|&&id| id > 0).count();
    let header_title = format!(
        "{} | {} sprite(s), {} frame(s), {} custom pal | {}x",
        script_path.display(),
        items.len(),
        total_frames,
        custom_pal_count,
        scale
    );

    let (rgba, out_w, out_h) = render_sprites_overview_rgba(&items, &header_title, scale);
    let out_path = output_path
        .map(PathBuf::from)
        .unwrap_or_else(|| default_spr_output_path(script_path, target));

    write_rgba_png(&out_path, &rgba, out_w, out_h)?;

    println!(
        "[uk spr] Saved {} ({}x{}, {} sprite(s), {} frame(s), scale {}x)",
        out_path.display(),
        out_w,
        out_h,
        items.len(),
        total_frames,
        scale
    );
    for item in &items {
        println!("  - {} ({})", item.label, item.meta);
    }

    Ok(())
}

// ==========================================
// `uk preview sfx` / `uk sfx`
// ==========================================

#[derive(Debug, Clone)]
pub struct AudioStats {
    pub sample_count: usize,
    pub duration_sec: f32,
    pub peak: i16,
    pub peak_norm: f32,
    pub rms_norm: f32,
    pub clipped_samples: usize,
    pub is_silent: bool,
}

pub fn analyze_pcm(pcm: &[i16]) -> AudioStats {
    if pcm.is_empty() {
        return AudioStats {
            sample_count: 0,
            duration_sec: 0.0,
            peak: 0,
            peak_norm: 0.0,
            rms_norm: 0.0,
            clipped_samples: 0,
            is_silent: true,
        };
    }

    let mut max_abs: i32 = 0;
    let mut sum_sq: f64 = 0.0;
    let mut clipped: usize = 0;

    for &s in pcm {
        let abs = (s as i32).abs();
        if abs > max_abs {
            max_abs = abs;
        }
        if abs >= 32760 {
            clipped += 1;
        }
        let f = s as f64 / 32767.0;
        sum_sq += f * f;
    }

    let peak = max_abs.min(32767) as i16;
    let peak_norm = (max_abs as f32 / 32767.0).min(1.0);
    let rms_norm = (sum_sq / pcm.len() as f64).sqrt() as f32;

    AudioStats {
        sample_count: pcm.len(),
        duration_sec: pcm.len() as f32 / SAMPLE_RATE as f32,
        peak,
        peak_norm,
        rms_norm,
        clipped_samples: clipped,
        is_silent: max_abs == 0,
    }
}

fn print_audio_stats(label: &str, kind: &str, stats: &AudioStats) {
    let rms_db = if stats.rms_norm > 1e-6 {
        format!("{:.1} dBFS", 20.0 * stats.rms_norm.log10())
    } else {
        "-inf dBFS".to_string()
    };
    println!("[uk sfx] {} ({})", label, kind);
    println!(
        "  Duration : {:.3} s ({} samples @ {} Hz)",
        stats.duration_sec, stats.sample_count, SAMPLE_RATE
    );
    println!(
        "  Peak     : {:.3} ({} / 32767)",
        stats.peak_norm, stats.peak
    );
    println!("  RMS      : {:.3} ({})", stats.rms_norm, rms_db);
    println!(
        "  Clipping : {}",
        if stats.clipped_samples > 0 {
            format!("YES ({} samples)", stats.clipped_samples)
        } else {
            "no (0 samples)".to_string()
        }
    );
    println!(
        "  Silent   : {}",
        if stats.is_silent {
            "YES (0-amplitude)"
        } else {
            "no"
        }
    );
}

pub fn render_waveform_png(
    label: &str,
    kind: &str,
    pcm: &[i16],
    stats: &AudioStats,
    music_spec: Option<&str>,
) -> (Vec<u8>, usize, usize) {
    let w = 640usize;
    let header_h = 26usize;
    let lane_h = if music_spec.is_some() { 96usize } else { 0usize };
    let wave_h = 180usize;
    let footer_h = 22usize;
    let h = header_h + lane_h + wave_h + footer_h;

    let mut buf = vec![0u8; w * h * 4];
    fill_rect_rgba(&mut buf, w, h, 0, 0, w as i32, h as i32, [24, 26, 32, 255]);
    fill_rect_rgba(
        &mut buf,
        w,
        h,
        0,
        0,
        w as i32,
        header_h as i32,
        [34, 38, 48, 255],
    );

    let title = format!(
        "{} ({}) | {:.3}s | Peak:{:.2} | RMS:{:.2}{}{}",
        label,
        kind,
        stats.duration_sec,
        stats.peak_norm,
        stats.rms_norm,
        if stats.clipped_samples > 0 { " | CLIP!" } else { "" },
        if stats.is_silent { " | SILENT" } else { "" }
    );
    draw_text_rgba(&mut buf, w, h, 10, 9, &title, [235, 240, 250, 255], 1);

    let pad_x = 16usize;
    let plot_w = w - pad_x * 2;

    // @MUSIC チャンネル別簡易ピアノロール / アクティビティレーン
    if let Some(spec) = music_spec {
        let mut ch_texts: [Vec<String>; 4] = Default::default();
        for raw in spec.lines() {
            let trimmed = raw.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let lower = trimmed.to_ascii_lowercase();
            let mut matched = false;
            for (idx, pfx) in ["ch0", "ch1", "ch2", "ch3"].iter().enumerate() {
                if lower.starts_with(pfx) {
                    let rest = trimmed[pfx.len()..].trim().trim_start_matches(':').trim();
                    if !rest.is_empty() {
                        ch_texts[idx].push(rest.to_string());
                    }
                    matched = true;
                    break;
                }
            }
            if !matched && !lower.starts_with("loop") && lower != "end" {
                ch_texts[0].push(trimmed.to_string());
            }
        }

        let ch_colors = [
            [255, 119, 168, 255],
            [41, 173, 255, 255],
            [0, 228, 54, 255],
            [255, 236, 39, 255],
        ];
        let row_h = (lane_h - 8) / 4;
        for ch_idx in 0..4 {
            let ry = header_h + 4 + ch_idx * row_h;
            draw_text_rgba(
                &mut buf,
                w,
                h,
                pad_x as i32,
                (ry + 6) as i32,
                &format!("CH{}", ch_idx),
                ch_colors[ch_idx],
                1,
            );
            let bar_x = pad_x + 28;
            let bar_w = plot_w.saturating_sub(28);
            fill_rect_rgba(
                &mut buf,
                w,
                h,
                bar_x as i32,
                (ry + 2) as i32,
                bar_w as i32,
                (row_h - 4) as i32,
                [30, 34, 44, 255],
            );

            let joined = ch_texts[ch_idx].join(" ");
            let tokens: Vec<&str> = joined.split_whitespace().collect();
            if !tokens.is_empty() {
                let n = tokens.len();
                for (ti, tok) in tokens.iter().enumerate() {
                    let is_rest = matches!(*tok, "r" | "." | "-" | "_");
                    let is_cmd = tok.starts_with("wave")
                        || tok.starts_with("vol")
                        || tok.starts_with('T')
                        || tok.starts_with('t')
                        || tok.starts_with('L')
                        || tok.starts_with('l')
                        || tok.starts_with('O')
                        || tok.starts_with('o')
                        || *tok == "<"
                        || *tok == ">";
                    if is_rest || is_cmd {
                        continue;
                    }
                    let bx0 = bar_x + (ti * bar_w) / n;
                    let bx1 = bar_x + ((ti + 1) * bar_w) / n;
                    let bw = (bx1.saturating_sub(bx0)).max(2);
                    fill_rect_rgba(
                        &mut buf,
                        w,
                        h,
                        bx0 as i32,
                        (ry + 4) as i32,
                        bw.saturating_sub(1).max(1) as i32,
                        (row_h - 8) as i32,
                        ch_colors[ch_idx],
                    );
                }
            }
        }
    }

    // 波形プロット領域
    let wave_top = header_h + lane_h + 8;
    let wave_plot_h = wave_h - 16;
    let mid_y = wave_top + wave_plot_h / 2;
    let half_h = (wave_plot_h / 2) as f32;

    fill_rect_rgba(
        &mut buf,
        w,
        h,
        pad_x as i32,
        wave_top as i32,
        plot_w as i32,
        wave_plot_h as i32,
        [18, 20, 26, 255],
    );
    // +/- 0.5 ガイド線 & ゼロライン
    let q1_y = wave_top + wave_plot_h / 4;
    let q3_y = wave_top + (wave_plot_h * 3) / 4;
    fill_rect_rgba(&mut buf, w, h, pad_x as i32, q1_y as i32, plot_w as i32, 1, [38, 42, 52, 255]);
    fill_rect_rgba(&mut buf, w, h, pad_x as i32, q3_y as i32, plot_w as i32, 1, [38, 42, 52, 255]);
    fill_rect_rgba(&mut buf, w, h, pad_x as i32, mid_y as i32, plot_w as i32, 1, [66, 74, 92, 255]);

    if !pcm.is_empty() {
        for col in 0..plot_w {
            let s0 = (col * pcm.len()) / plot_w;
            let s1 = (((col + 1) * pcm.len()) / plot_w).max(s0 + 1).min(pcm.len());
            let mut min_v = 0i16;
            let mut max_v = 0i16;
            let mut has_clip = false;
            for &sample in &pcm[s0..s1] {
                if sample < min_v {
                    min_v = sample;
                }
                if sample > max_v {
                    max_v = sample;
                }
                if sample.saturating_abs() >= 32760 {
                    has_clip = true;
                }
            }
            let y_top = (mid_y as f32 - (max_v as f32 / 32767.0) * (half_h - 2.0)).round() as i32;
            let y_bot = (mid_y as f32 - (min_v as f32 / 32767.0) * (half_h - 2.0)).round() as i32;
            let bar_y = y_top.min(y_bot);
            let bar_h = (y_bot - y_top).abs().max(1);
            let color = if has_clip {
                [255, 0, 77, 255]
            } else {
                [41, 173, 255, 255]
            };
            fill_rect_rgba(&mut buf, w, h, (pad_x + col) as i32, bar_y, 1, bar_h, color);
        }
    }

    draw_rect_outline_rgba(
        &mut buf,
        w,
        h,
        pad_x as i32,
        wave_top as i32,
        plot_w as i32,
        wave_plot_h as i32,
        [66, 72, 88, 255],
    );

    // フッタ時間軸
    let footer_y = header_h + lane_h + wave_h + 4;
    draw_text_rgba(&mut buf, w, h, pad_x as i32, footer_y as i32, "0.00s", [160, 172, 194, 255], 1);
    let end_label = format!("{:.2}s", stats.duration_sec);
    let end_x = (pad_x + plot_w).saturating_sub(end_label.len() * 6);
    draw_text_rgba(&mut buf, w, h, end_x as i32, footer_y as i32, &end_label, [160, 172, 194, 255], 1);

    (buf, w, h)
}

fn play_wav_bytes_blocking(wav_bytes: &[u8]) -> Result<(), String> {
    let temp_path = std::env::temp_dir().join(format!("uk_preview_sfx_{}.wav", std::process::id()));
    fs::write(&temp_path, wav_bytes)
        .map_err(|e| format!("Failed to write temp WAV `{}`: {}", temp_path.display(), e))?;

    let res = {
        #[cfg(target_os = "windows")]
        {
            let ps_path = temp_path.to_string_lossy().replace('\'', "''");
            let cmd = format!(
                "(New-Object Media.SoundPlayer '{}').PlaySync()",
                ps_path
            );
            std::process::Command::new("powershell")
                .args(["-NoProfile", "-Command", &cmd])
                .status()
                .map_err(|e| format!("Failed to run PowerShell SoundPlayer: {}", e))
                .and_then(|st| {
                    if st.success() {
                        Ok(())
                    } else {
                        Err(format!("PowerShell SoundPlayer exited with {}", st))
                    }
                })
        }
        #[cfg(target_os = "macos")]
        {
            std::process::Command::new("afplay")
                .arg(&temp_path)
                .status()
                .map_err(|e| format!("Failed to run afplay: {}", e))
                .and_then(|st| {
                    if st.success() {
                        Ok(())
                    } else {
                        Err(format!("afplay exited with {}", st))
                    }
                })
        }
        #[cfg(all(unix, not(target_os = "macos")))]
        {
            let try_cmd = |bin: &str, args: &[&str]| -> Option<Result<(), String>> {
                match std::process::Command::new(bin).args(args).arg(&temp_path).status() {
                    Ok(st) if st.success() => Some(Ok(())),
                    Ok(_) => None,
                    Err(_) => None,
                }
            };
            try_cmd("aplay", &["-q"])
                .or_else(|| try_cmd("paplay", &[]))
                .or_else(|| try_cmd("ffplay", &["-nodisp", "-autoexit", "-loglevel", "quiet"]))
                .unwrap_or_else(|| Err("No CLI audio player found (tried aplay, paplay, ffplay)".to_string()))
        }
    };

    let _ = fs::remove_file(&temp_path);
    res
}

enum ResolvedSound<'a> {
    Sfx {
        label: String,
        kind: &'a str,
        pcm: Vec<i16>,
        wav_bytes: Vec<u8>,
    },
    Music {
        label: String,
        data: MusicData,
    },
}

fn resolve_single_sound<'a>(
    sfx_map: &HashMap<SoundKey, SfxData>,
    music_map: &HashMap<SoundKey, MusicData>,
    target: &str,
) -> Result<ResolvedSound<'a>, String> {
    let trimmed = target.trim();
    if let Some(key) = SoundKey::from_tail_token(trimmed) {
        if let Some(sfx) = sfx_map.get(&key) {
            return Ok(ResolvedSound::Sfx {
                label: key.to_string(),
                kind: "@SFX",
                pcm: sfx.pcm.clone(),
                wav_bytes: sfx.wav_bytes.clone(),
            });
        }
        if let Some(music) = music_map.get(&key) {
            return Ok(ResolvedSound::Music {
                label: key.to_string(),
                data: music.clone(),
            });
        }
    }

    let norm = SoundKey::normalize_name(trimmed);
    if is_builtin_preset(&norm)
        && let Some(pcm) = synthesize_preset_pcm(&norm, 1.0, 1.0, 1.0)
    {
        let wav_bytes = crate::sound::pcm_to_wav_bytes(&pcm, SAMPLE_RATE);
        return Ok(ResolvedSound::Sfx {
            label: format!(":{}", norm),
            kind: "preset",
            pcm,
            wav_bytes,
        });
    }

    // シンボル名指定だが未定義・非プリセットの場合はエラー
    if trimmed.starts_with(':') && !trimmed.contains(char::is_whitespace) {
        return Err(format!("Unknown SFX / MUSIC symbol `{}`", trimmed));
    }

    // インラインスペックとして合成
    let sfx = SfxData::from_spec(trimmed);
    if sfx.pcm.is_empty() {
        return Err(format!("Could not synthesize sound from `{}`", trimmed));
    }
    Ok(ResolvedSound::Sfx {
        label: trimmed.to_string(),
        kind: "inline",
        pcm: sfx.pcm,
        wav_bytes: sfx.wav_bytes,
    })
}

fn run_sfx_once(
    script_path: Option<&Path>,
    target: Option<&str>,
    output_path: Option<&Path>,
    should_play: bool,
) -> Result<(), String> {
    let (sfx_map, music_map) = if let Some(path) = script_path {
        let tail = load_tail_data_from_path(path)?;
        parse_tail_sounds(&tail)
    } else if target.is_some() && Path::new("game.rb").is_file() {
        let tail = load_tail_data_from_path(Path::new("game.rb"))?;
        parse_tail_sounds(&tail)
    } else {
        (HashMap::new(), HashMap::new())
    };

    if let Some(t) = target {
        let resolved = resolve_single_sound(&sfx_map, &music_map, t)?;
        match resolved {
            ResolvedSound::Sfx {
                label,
                kind,
                pcm,
                wav_bytes,
            } => {
                let stats = analyze_pcm(&pcm);
                print_audio_stats(&label, kind, &stats);
                if let Some(out) = output_path {
                    let (rgba, w, h) = render_waveform_png(&label, kind, &pcm, &stats, None);
                    write_rgba_png(out, &rgba, w, h)?;
                    println!("  Waveform : {} ({}x{})", out.display(), w, h);
                }
                if should_play {
                    if let Err(e) = play_wav_bytes_blocking(&wav_bytes) {
                        eprintln!("  [warn] Audio playback skipped: {}", e);
                    }
                }
            }
            ResolvedSound::Music { label, data } => {
                let stats = analyze_pcm(&data.pcm);
                print_audio_stats(&label, "@MUSIC", &stats);
                if let Some(out) = output_path {
                    let (rgba, w, h) =
                        render_waveform_png(&label, "@MUSIC", &data.pcm, &stats, Some(&data.spec));
                    write_rgba_png(out, &rgba, w, h)?;
                    println!("  PianoRoll: {} ({}x{})", out.display(), w, h);
                }
                if should_play {
                    if let Err(e) = play_wav_bytes_blocking(&data.wav_bytes) {
                        eprintln!("  [warn] Audio playback skipped: {}", e);
                    }
                }
            }
        }
        return Ok(());
    }

    // target 未指定: 定義済み @SFX / @MUSIC の一覧サマリ出力
    let mut sfx_sorted: BTreeMap<String, &SfxData> = BTreeMap::new();
    for (k, v) in &sfx_map {
        sfx_sorted.insert(k.to_string(), v);
    }
    let mut music_sorted: BTreeMap<String, &MusicData> = BTreeMap::new();
    for (k, v) in &music_map {
        music_sorted.insert(k.to_string(), v);
    }

    if sfx_sorted.is_empty() && music_sorted.is_empty() {
        return Err(format!(
            "No @SFX or @MUSIC definitions found in `{}`",
            script_path
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "game.rb".to_string())
        ));
    }

    for (label, sfx) in &sfx_sorted {
        let stats = analyze_pcm(&sfx.pcm);
        print_audio_stats(label, "@SFX", &stats);
    }
    for (label, music) in &music_sorted {
        let stats = analyze_pcm(&music.pcm);
        print_audio_stats(label, "@MUSIC", &stats);
    }

    if let Some(out) = output_path {
        if let Some((label, sfx)) = sfx_sorted.iter().next() {
            let stats = analyze_pcm(&sfx.pcm);
            let (rgba, w, h) = render_waveform_png(label, "@SFX", &sfx.pcm, &stats, None);
            write_rgba_png(out, &rgba, w, h)?;
            println!("[uk sfx] Saved waveform PNG for {} -> {} ({}x{})", label, out.display(), w, h);
        } else if let Some((label, music)) = music_sorted.iter().next() {
            let stats = analyze_pcm(&music.pcm);
            let (rgba, w, h) =
                render_waveform_png(label, "@MUSIC", &music.pcm, &stats, Some(&music.spec));
            write_rgba_png(out, &rgba, w, h)?;
            println!("[uk sfx] Saved piano-roll PNG for {} -> {} ({}x{})", label, out.display(), w, h);
        }
    }

    Ok(())
}

fn collect_sound_watch_mtimes(script_path: &Path) -> Vec<(PathBuf, Option<SystemTime>)> {
    let mut paths = vec![script_path.to_path_buf()];
    paths.extend(crate::bundle::find_associated_resource_paths(script_path));
    paths
        .into_iter()
        .map(|p| {
            let m = fs::metadata(&p).and_then(|meta| meta.modified()).ok();
            (p, m)
        })
        .collect()
}

pub fn cmd_preview_sfx(
    script_path: Option<&Path>,
    target: Option<&str>,
    output_path: Option<&Path>,
    play: Option<bool>,
    watch: bool,
) -> Result<(), String> {
    let should_play = play.unwrap_or(output_path.is_none());
    run_sfx_once(script_path, target, output_path, should_play)?;

    if watch {
        let watch_path = script_path.unwrap_or_else(|| Path::new("game.rb"));
        if !watch_path.exists() {
            return Err(format!(
                "Cannot watch `{}`: file not found",
                watch_path.display()
            ));
        }
        println!(
            "[uk sfx] Watching `{}` for changes (Ctrl+C to stop)...",
            watch_path.display()
        );
        let mut last_mtimes = collect_sound_watch_mtimes(watch_path);
        loop {
            std::thread::sleep(Duration::from_millis(200));
            let cur_mtimes = collect_sound_watch_mtimes(watch_path);
            if cur_mtimes != last_mtimes {
                last_mtimes = cur_mtimes;
                println!("--- Reloaded ---");
                if let Err(e) = run_sfx_once(Some(watch_path), target, output_path, should_play) {
                    eprintln!("[uk sfx] Error: {}", e);
                }
            }
        }
    }

    Ok(())
}
