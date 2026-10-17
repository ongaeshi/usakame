use std::collections::HashMap;

use macroquad::prelude::*;

use crate::{SPRITE_SIZE, SpriteData};

include!("emoji_table.rs");

/// 事前生成された Twemoji (CC-BY 4.0) ベースの 16x16 絵文字アトラス PNG (SFC RGB555 減色・1bit透過済み)
pub const EMOJI_ATLAS_PNG: &[u8] = include_bytes!("../assets/emoji_atlas.png");

/// 文字列（絵文字リテラル `"🐰"`, `"⚔️"` 等）から対応する絵文字コードポイントを解決する。
/// Variation Selector (`\u{FE0F}`, `\u{FE0E}`) 等が含まれていても自動的にベース絵文字を特定する。
pub fn resolve_emoji_codepoint(s: &str) -> Option<u32> {
    for ch in s.chars() {
        let cp = ch as u32;
        if cp == 0xFE0F || cp == 0xFE0E || cp == 0x200D {
            continue;
        }
        if EMOJI_CODEPOINTS.binary_search(&cp).is_ok() {
            return Some(cp);
        }
    }
    None
}

/// 16x16 絵文字スプライトのアトラス管理・オンデマンド抽出キャッシュ
pub struct EmojiAtlas {
    atlas_width: usize,
    atlas_rgba: Vec<u8>,
    cache: HashMap<u32, SpriteData>,
}

impl Default for EmojiAtlas {
    fn default() -> Self {
        Self::new()
    }
}

impl EmojiAtlas {
    pub fn new() -> Self {
        let img = Image::from_file_with_format(EMOJI_ATLAS_PNG, Some(ImageFormat::Png))
            .expect("Failed to decode embedded assets/emoji_atlas.png");
        Self {
            atlas_width: img.width as usize,
            atlas_rgba: img.bytes,
            cache: HashMap::new(),
        }
    }

    /// 指定した絵文字文字列（例: `"🐰"`, `"🐢"`, `"⚔️"`）に対応する 16x16 `SpriteData` を切り出して返す。
    pub fn extract_sprite(&self, emoji_str: &str) -> Option<SpriteData> {
        let cp = resolve_emoji_codepoint(emoji_str)?;
        let tile_idx = EMOJI_CODEPOINTS.binary_search(&cp).ok()?;
        let tile_col = tile_idx % EMOJI_ATLAS_COLS;
        let tile_row = tile_idx / EMOJI_ATLAS_COLS;

        let mut rgba = vec![0u8; SPRITE_SIZE * SPRITE_SIZE * 4];
        for y in 0..SPRITE_SIZE {
            let src_y = tile_row * SPRITE_SIZE + y;
            let src_x = tile_col * SPRITE_SIZE;
            let src_off = (src_y * self.atlas_width + src_x) * 4;
            let dst_off = y * SPRITE_SIZE * 4;
            let row_bytes = SPRITE_SIZE * 4;
            if src_off + row_bytes <= self.atlas_rgba.len() {
                rgba[dst_off..dst_off + row_bytes]
                    .copy_from_slice(&self.atlas_rgba[src_off..src_off + row_bytes]);
            }
        }

        Some(SpriteData::from_rgba(
            SPRITE_SIZE as u16,
            SPRITE_SIZE as u16,
            rgba,
        ))
    }

    /// キャッシュから絵文字スプライトを取得し、未生成であれば切り出して（必要に応じGPUテクスチャ化して）返す。
    pub fn get_or_insert(&mut self, emoji_str: &str, build_texture: bool) -> Option<&SpriteData> {
        let cp = resolve_emoji_codepoint(emoji_str)?;
        if !self.cache.contains_key(&cp) {
            let mut sprite = self.extract_sprite(emoji_str)?;
            if build_texture {
                sprite.build_texture();
            }
            self.cache.insert(cp, sprite);
        }
        self.cache.get(&cp)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn test_emoji_lookup_and_extraction() {
        let atlas = EmojiAtlas::new();
        for emoji in ["🐰", "🐢", "🍎", "⚔️", "🛡️", "🔥", "👾", "❤️", "⭐", "🏰"] {
            let sprite = atlas
                .extract_sprite(emoji)
                .unwrap_or_else(|| panic!("Emoji {} should be supported", emoji));
            assert_eq!(sprite.width, 16);
            assert_eq!(sprite.height, 16);
            assert_eq!(sprite.rgba.len(), 16 * 16 * 4);
            // 透明でないピクセルが存在することを確認
            let non_transparent = sprite.rgba.chunks_exact(4).filter(|px| px[3] > 0).count();
            assert!(
                non_transparent > 10,
                "Emoji {} should have visible pixels (got {})",
                emoji,
                non_transparent
            );
        }
    }

    fn read_u16_be(data: &[u8], off: usize) -> u16 {
        u16::from_be_bytes([data[off], data[off + 1]])
    }

    fn read_u32_be(data: &[u8], off: usize) -> u32 {
        u32::from_be_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]])
    }

    struct SegmentCollector {
        cur_x: f32,
        cur_y: f32,
        start_x: f32,
        start_y: f32,
        segments: Vec<(f32, f32, f32, f32)>,
        min_x: f32,
        min_y: f32,
        max_x: f32,
        max_y: f32,
    }

    impl SegmentCollector {
        fn new() -> Self {
            Self {
                cur_x: 0.0,
                cur_y: 0.0,
                start_x: 0.0,
                start_y: 0.0,
                segments: Vec::new(),
                min_x: f32::MAX,
                min_y: f32::MAX,
                max_x: f32::MIN,
                max_y: f32::MIN,
            }
        }

        fn add_seg(&mut self, x0: f32, y0: f32, x1: f32, y1: f32) {
            self.min_x = self.min_x.min(x0).min(x1);
            self.min_y = self.min_y.min(y0).min(y1);
            self.max_x = self.max_x.max(x0).max(x1);
            self.max_y = self.max_y.max(y0).max(y1);
            if (y0 - y1).abs() > 1e-5 {
                self.segments.push((x0, y0, x1, y1));
            }
        }
    }

    impl ttf_parser::OutlineBuilder for SegmentCollector {
        fn move_to(&mut self, x: f32, y: f32) {
            self.cur_x = x;
            self.cur_y = y;
            self.start_x = x;
            self.start_y = y;
        }

        fn line_to(&mut self, x: f32, y: f32) {
            self.add_seg(self.cur_x, self.cur_y, x, y);
            self.cur_x = x;
            self.cur_y = y;
        }

        fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32) {
            let x0 = self.cur_x;
            let y0 = self.cur_y;
            let steps = 6;
            let mut px = x0;
            let mut py = y0;
            for i in 1..=steps {
                let t = (i as f32) / (steps as f32);
                let mt = 1.0 - t;
                let nx = mt * mt * x0 + 2.0 * mt * t * x1 + t * t * x;
                let ny = mt * mt * y0 + 2.0 * mt * t * y1 + t * t * y;
                self.add_seg(px, py, nx, ny);
                px = nx;
                py = ny;
            }
            self.cur_x = x;
            self.cur_y = y;
        }

        fn curve_to(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) {
            let x0 = self.cur_x;
            let y0 = self.cur_y;
            let steps = 8;
            let mut px = x0;
            let mut py = y0;
            for i in 1..=steps {
                let t = (i as f32) / (steps as f32);
                let mt = 1.0 - t;
                let nx = mt * mt * mt * x0
                    + 3.0 * mt * mt * t * x1
                    + 3.0 * mt * t * t * x2
                    + t * t * t * x;
                let ny = mt * mt * mt * y0
                    + 3.0 * mt * mt * t * y1
                    + 3.0 * mt * t * t * y2
                    + t * t * t * y;
                self.add_seg(px, py, nx, ny);
                px = nx;
                py = ny;
            }
            self.cur_x = x;
            self.cur_y = y;
        }

        fn close(&mut self) {
            if (self.cur_x - self.start_x).abs() > 1e-4 || (self.cur_y - self.start_y).abs() > 1e-4
            {
                self.add_seg(self.cur_x, self.cur_y, self.start_x, self.start_y);
            }
            self.cur_x = self.start_x;
            self.cur_y = self.start_y;
        }
    }

    /// TwemojiMozilla.ttf (CC-BY 4.0) から `assets/emoji_atlas.png` と `src/emoji_table.rs` を生成する開発用テスト。
    /// 実行方法: `TWEMOJI_TTF_PATH=path/to/TwemojiMozilla.ttf cargo test generate_emoji_atlas_from_twemoji -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn generate_emoji_atlas_from_twemoji() {
        let font_path = std::env::var("TWEMOJI_TTF_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(r"C:\Users\ongaeshi\.gemini\antigravity\brain\5460a452-9ef8-4371-87b5-112dde97df72\scratch\TwemojiMozilla.ttf")
            });
        assert!(
            font_path.exists(),
            "TwemojiMozilla.ttf not found at {}",
            font_path.display()
        );

        let data = fs::read(&font_path).expect("Failed to read TwemojiMozilla.ttf");
        let face = ttf_parser::Face::parse(&data, 0).expect("ttf-parser failed to parse Twemoji");

        let num_tables = read_u16_be(&data, 4) as usize;
        let mut tables = HashMap::new();
        for i in 0..num_tables {
            let rec = 12 + i * 16;
            let tag = std::str::from_utf8(&data[rec..rec + 4]).unwrap_or("");
            let offset = read_u32_be(&data, rec + 8) as usize;
            tables.insert(tag.to_string(), offset);
        }

        let colr_off = *tables.get("COLR").expect("No COLR table");
        let num_base = read_u16_be(&data, colr_off + 2) as usize;
        let base_off = read_u32_be(&data, colr_off + 4) as usize;
        let layer_off = read_u32_be(&data, colr_off + 8) as usize;

        let mut base_glyphs = HashMap::new();
        for i in 0..num_base {
            let pos = colr_off + base_off + i * 6;
            let gid = read_u16_be(&data, pos);
            let first_layer = read_u16_be(&data, pos + 2) as usize;
            let num_layers = read_u16_be(&data, pos + 4) as usize;
            base_glyphs.insert(gid, (first_layer, num_layers));
        }

        let cpal_off = *tables.get("CPAL").expect("No CPAL table");
        let num_color_rec = read_u16_be(&data, cpal_off + 6) as usize;
        let color_off = read_u32_be(&data, cpal_off + 8) as usize;
        let mut palette = Vec::with_capacity(num_color_rec);
        for i in 0..num_color_rec {
            let pos = cpal_off + color_off + i * 4;
            let b = data[pos];
            let g = data[pos + 1];
            let r = data[pos + 2];
            let a = data[pos + 3];
            palette.push((r, g, b, a));
        }

        let cmap_off = *tables.get("cmap").expect("No cmap table");
        let num_sub = read_u16_be(&data, cmap_off + 2) as usize;
        let mut cmap12_off = None;
        for i in 0..num_sub {
            let sub_off = read_u32_be(&data, cmap_off + 4 + i * 8 + 4) as usize;
            let fmt = read_u16_be(&data, cmap_off + sub_off);
            if fmt == 12 {
                cmap12_off = Some(cmap_off + sub_off);
                break;
            }
        }
        let cmap12 = cmap12_off.expect("No cmap format 12");
        let num_groups = read_u32_be(&data, cmap12 + 12) as usize;
        let mut codepoints: Vec<(u32, u16)> = Vec::new();
        for i in 0..num_groups {
            let pos = cmap12 + 16 + i * 12;
            let start_c = read_u32_be(&data, pos);
            let end_c = read_u32_be(&data, pos + 4);
            let start_g = read_u32_be(&data, pos + 8);
            for c in start_c..=end_c {
                let gid = (start_g + (c - start_c)) as u16;
                if base_glyphs.contains_key(&gid) {
                    codepoints.push((c, gid));
                }
            }
        }
        codepoints.sort_by_key(|&(c, _)| c);
        codepoints.dedup_by_key(|&mut (c, _)| c);

        let cols = 40usize;
        let rows = (codepoints.len() + cols - 1) / cols;
        let atlas_w = cols * 16;
        let atlas_h = rows * 16;
        let mut atlas_rgba = vec![0u8; atlas_w * atlas_h * 4];
        let mut valid_codepoints = Vec::new();

        const HI_RES: usize = 48;
        let mut intersections = Vec::with_capacity(32);

        for &(cp, base_gid) in &codepoints {
            let &(first_layer, num_layers) = &base_glyphs[&base_gid];
            let mut layers = Vec::with_capacity(num_layers);
            let mut min_x = f32::MAX;
            let mut min_y = f32::MAX;
            let mut max_x = f32::MIN;
            let mut max_y = f32::MIN;

            for l in 0..num_layers {
                let lpos = colr_off + layer_off + (first_layer + l) * 4;
                let lgid = read_u16_be(&data, lpos);
                let pal_idx = read_u16_be(&data, lpos + 2) as usize;
                let color = if pal_idx == 0xFFFF {
                    (0u8, 0u8, 0u8, 255u8)
                } else if pal_idx < palette.len() {
                    palette[pal_idx]
                } else {
                    continue;
                };
                if color.3 == 0 {
                    continue;
                }
                let mut collector = SegmentCollector::new();
                if face
                    .outline_glyph(ttf_parser::GlyphId(lgid), &mut collector)
                    .is_some()
                    && !collector.segments.is_empty()
                {
                    min_x = min_x.min(collector.min_x);
                    min_y = min_y.min(collector.min_y);
                    max_x = max_x.max(collector.max_x);
                    max_y = max_y.max(collector.max_y);
                    layers.push((color, collector.segments));
                }
            }

            if layers.is_empty() || max_x <= min_x || max_y <= min_y {
                continue;
            }

            let bw = max_x - min_x;
            let bh = max_y - min_y;
            let max_dim = bw.max(bh);
            let offset_x = (max_dim - bw) * 0.5;
            let offset_y = (max_dim - bh) * 0.5;

            let mut canvas = vec![[0.0f32; 4]; HI_RES * HI_RES];

            for ((cr, cg, cb, ca), segments) in &layers {
                let src_a = (*ca as f32) / 255.0;
                let rf = (*cr as f32) / 255.0;
                let gf = (*cg as f32) / 255.0;
                let bf = (*cb as f32) / 255.0;
                let inv_a = 1.0 - src_a;

                for hy in 0..HI_RES {
                    let fy = max_y + offset_y - ((hy as f32 + 0.5) / (HI_RES as f32)) * max_dim;
                    intersections.clear();
                    for &(x0, y0, x1, y1) in segments {
                        if (y0 <= fy && y1 > fy) || (y1 <= fy && y0 > fy) {
                            let t = (fy - y0) / (y1 - y0);
                            let ix = x0 + t * (x1 - x0);
                            let dir = if y1 > y0 { 1i32 } else { -1i32 };
                            intersections.push((ix, dir));
                        }
                    }
                    if intersections.len() < 2 {
                        continue;
                    }
                    intersections.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());

                    let mut winding = 0i32;
                    let mut prev_x = 0.0f32;
                    for &(ix, dir) in &intersections {
                        if winding != 0 {
                            let hx0_f = ((prev_x - (min_x - offset_x)) / max_dim) * (HI_RES as f32);
                            let hx1_f = ((ix - (min_x - offset_x)) / max_dim) * (HI_RES as f32);
                            let hx0 = (hx0_f.round() as i32).clamp(0, HI_RES as i32) as usize;
                            let hx1 = (hx1_f.round() as i32).clamp(0, HI_RES as i32) as usize;
                            for hx in hx0..hx1 {
                                let dst = &mut canvas[hy * HI_RES + hx];
                                dst[0] = rf * src_a + dst[0] * inv_a;
                                dst[1] = gf * src_a + dst[1] * inv_a;
                                dst[2] = bf * src_a + dst[2] * inv_a;
                                dst[3] = src_a + dst[3] * inv_a;
                            }
                        }
                        winding += dir;
                        prev_x = ix;
                    }
                }
            }

            let tile_idx = valid_codepoints.len();
            valid_codepoints.push(cp);
            let tile_col = tile_idx % cols;
            let tile_row = tile_idx / cols;

            for oy in 0..16usize {
                for ox in 0..16usize {
                    let mut sum_r = 0.0f32;
                    let mut sum_g = 0.0f32;
                    let mut sum_b = 0.0f32;
                    let mut sum_a = 0.0f32;
                    for sy in 0..3 {
                        for sx in 0..3 {
                            let p = canvas[(oy * 3 + sy) * HI_RES + (ox * 3 + sx)];
                            sum_r += p[0];
                            sum_g += p[1];
                            sum_b += p[2];
                            sum_a += p[3];
                        }
                    }
                    if (sum_a / 9.0) >= 0.35 && sum_a > 0.001 {
                        let r = ((sum_r / sum_a).clamp(0.0, 1.0) * 255.0).round() as u8;
                        let g = ((sum_g / sum_a).clamp(0.0, 1.0) * 255.0).round() as u8;
                        let b = ((sum_b / sum_a).clamp(0.0, 1.0) * 255.0).round() as u8;
                        let qr = (r & 0xF8) | (r >> 5);
                        let qg = (g & 0xF8) | (g >> 5);
                        let qb = (b & 0xF8) | (b >> 5);

                        let ax = tile_col * 16 + ox;
                        let ay = tile_row * 16 + oy;
                        let a_idx = (ay * atlas_w + ax) * 4;
                        atlas_rgba[a_idx] = qr;
                        atlas_rgba[a_idx + 1] = qg;
                        atlas_rgba[a_idx + 2] = qb;
                        atlas_rgba[a_idx + 3] = 255;
                    }
                }
            }
        }

        let used_rows = (valid_codepoints.len() + cols - 1) / cols;
        let final_h = used_rows * 16;
        atlas_rgba.truncate(atlas_w * final_h * 4);

        fs::create_dir_all("assets").unwrap();
        let file = fs::File::create("assets/emoji_atlas.png").unwrap();
        let mut encoder = png::Encoder::new(file, atlas_w as u32, final_h as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Best);
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(&atlas_rgba).unwrap();
        writer.finish().unwrap();

        let png_size = fs::metadata("assets/emoji_atlas.png").unwrap().len();
        println!(
            "Generated Twemoji assets/emoji_atlas.png: {} emojis, {}x{}, {} bytes ({:.1} KB)",
            valid_codepoints.len(),
            atlas_w,
            final_h,
            png_size,
            png_size as f64 / 1024.0
        );

        let mut table_src =
            String::from("// Auto-generated emoji codepoint lookup table (Twemoji CC-BY 4.0)\n");
        table_src.push_str(&format!("pub const EMOJI_ATLAS_COLS: usize = {};\n", cols));
        table_src.push_str(&format!(
            "pub const EMOJI_CODEPOINTS: [u32; {}] = [\n",
            valid_codepoints.len()
        ));
        for chunk in valid_codepoints.chunks(12) {
            table_src.push_str("    ");
            for cp in chunk {
                table_src.push_str(&format!("0x{:05X}, ", cp));
            }
            table_src.push('\n');
        }
        table_src.push_str("];\n");
        fs::write("src/emoji_table.rs", table_src).unwrap();
    }
}
