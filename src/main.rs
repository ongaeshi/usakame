pub mod bundle;
#[cfg(not(target_arch = "wasm32"))]
pub mod cli;
pub mod emoji;

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use macroquad::prelude::*;
use mrubyedge::rite;
use mrubyedge::yamrb::helpers::{mrb_define_cmethod, mrb_funcall};
use mrubyedge::yamrb::value::{RObject, RValue};
use mrubyedge::yamrb::vm::VM;

// ==========================================
// 仮想スクリーン設定 (256x256, ウィンドウ 512x512, 16x16 スプライト)
// ==========================================
pub const SCREEN_WIDTH: u32 = 256;
pub const SCREEN_HEIGHT: u32 = 256;
pub const WINDOW_WIDTH: i32 = 512;
pub const WINDOW_HEIGHT: i32 = 512;
pub const SPRITE_SIZE: usize = 16;

/// PICO-8 準拠の16色パレット
pub const PALETTE: [Color; 16] = [
    Color::from_rgba(0, 0, 0, 255),       // 0: Black (#000000)
    Color::from_rgba(29, 43, 83, 255),    // 1: Dark Blue (#1D2B53)
    Color::from_rgba(126, 37, 83, 255),   // 2: Dark Purple (#7E2553)
    Color::from_rgba(0, 135, 81, 255),    // 3: Dark Green (#008751)
    Color::from_rgba(171, 82, 54, 255),   // 4: Brown (#AB5236)
    Color::from_rgba(95, 87, 79, 255),    // 5: Dark Grey (#5F574F)
    Color::from_rgba(194, 195, 199, 255), // 6: Light Grey (#C2C3C7)
    Color::from_rgba(255, 241, 232, 255), // 7: White (#FFF1E8)
    Color::from_rgba(255, 0, 77, 255),    // 8: Red (#FF004D)
    Color::from_rgba(255, 163, 0, 255),   // 9: Orange (#FFA300)
    Color::from_rgba(255, 236, 39, 255),  // 10 (A): Yellow (#FFEC27)
    Color::from_rgba(0, 228, 54, 255),    // 11 (B): Green (#00E436)
    Color::from_rgba(41, 173, 255, 255),  // 12 (C): Blue (#29ADFF)
    Color::from_rgba(131, 118, 156, 255), // 13 (D): Indigo (#83769C)
    Color::from_rgba(255, 119, 168, 255), // 14 (E): Pink (#FF77A8)
    Color::from_rgba(255, 204, 170, 255), // 15 (F): Peach (#FFCCAA)
];

const PALETTE_RGBA: [[u8; 4]; 16] = [
    [0, 0, 0, 255],
    [29, 43, 83, 255],
    [126, 37, 83, 255],
    [0, 135, 81, 255],
    [171, 82, 54, 255],
    [95, 87, 79, 255],
    [194, 195, 199, 255],
    [255, 241, 232, 255],
    [255, 0, 77, 255],
    [255, 163, 0, 255],
    [255, 236, 39, 255],
    [0, 228, 54, 255],
    [41, 173, 255, 255],
    [131, 118, 156, 255],
    [255, 119, 168, 255],
    [255, 204, 170, 255],
];

fn palette_color(col: i32) -> Color {
    PALETTE[(col.rem_euclid(16)) as usize]
}

// ==========================================
// Base64 エンコード / デコード
// ==========================================
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

// ==========================================
// リソース管理 & 描画処理
// ==========================================
#[derive(Clone)]
pub struct SpriteData {
    pub width: u16,
    pub height: u16,
    /// RGBA ピクセルデータ (width * height * 4 bytes)
    pub rgba: Vec<u8>,
    pub texture: Option<Texture2D>,
}

impl SpriteData {
    pub fn from_rgba(width: u16, height: u16, rgba: Vec<u8>) -> Self {
        Self {
            width,
            height,
            rgba,
            texture: None,
        }
    }

    /// 16進数テキスト行 (`0`..`F`, `.` は透明) からスプライトを生成する（基本 16x16）
    pub fn from_lines(lines: &[&str]) -> Self {
        let max_cols = lines
            .iter()
            .map(|l| l.chars().count())
            .max()
            .unwrap_or(SPRITE_SIZE);
        let width = max_cols.max(SPRITE_SIZE);
        let height = lines.len().max(SPRITE_SIZE);
        let mut rgba = vec![0u8; width * height * 4];

        for (y, line) in lines.iter().take(height).enumerate() {
            for (x, ch) in line.chars().take(width).enumerate() {
                let color_idx = match ch {
                    '.' | ' ' => None,
                    c if c.is_ascii_hexdigit() => c.to_digit(16).map(|d| d as usize),
                    _ => None,
                };
                if let Some(idx) = color_idx {
                    let off = (y * width + x) * 4;
                    rgba[off..off + 4].copy_from_slice(&PALETTE_RGBA[idx & 0x0F]);
                }
            }
        }

        Self {
            width: width as u16,
            height: height as u16,
            rgba,
            texture: None,
        }
    }

    /// Base64 デコード後のバイト列（PNG バイナリ、または 4bit パック済み 16x16 パレットデータ）から生成
    pub fn from_compressed_bytes(bytes: &[u8]) -> Result<Self, String> {
        if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            let img = Image::from_file_with_format(bytes, Some(ImageFormat::Png))
                .map_err(|e| format!("Failed to decode PNG sprite: {:?}", e))?;
            return Ok(Self::from_rgba(img.width, img.height, img.bytes));
        }

        let total_pixels = SPRITE_SIZE * SPRITE_SIZE;
        // 128 bytes (4bit nibbles: 0=透明, 1..15=パレット色) または 160 bytes (128B nibbles + 32B 透過ビットマスク)
        if bytes.len() == total_pixels / 2 || bytes.len() == total_pixels / 2 + total_pixels / 8 {
            let has_mask = bytes.len() == total_pixels / 2 + total_pixels / 8;
            let mask_slice = if has_mask {
                &bytes[total_pixels / 2..]
            } else {
                &[][..]
            };
            let mut rgba = vec![0u8; total_pixels * 4];
            for i in 0..total_pixels {
                let nibble = if i % 2 == 0 {
                    (bytes[i / 2] >> 4) & 0x0F
                } else {
                    bytes[i / 2] & 0x0F
                };
                let opaque = if has_mask {
                    ((mask_slice[i / 8] >> (7 - (i % 8))) & 1) != 0
                } else {
                    nibble != 0
                };
                if opaque {
                    let off = i * 4;
                    rgba[off..off + 4].copy_from_slice(&PALETTE_RGBA[nibble as usize]);
                }
            }
            return Ok(Self::from_rgba(
                SPRITE_SIZE as u16,
                SPRITE_SIZE as u16,
                rgba,
            ));
        }

        // 256 bytes (1 byte per pixel: 0..15=パレット色, >=16=透明)
        if bytes.len() == total_pixels {
            let mut rgba = vec![0u8; total_pixels * 4];
            for (i, &b) in bytes.iter().enumerate() {
                if b < 16 {
                    let off = i * 4;
                    rgba[off..off + 4].copy_from_slice(&PALETTE_RGBA[b as usize]);
                }
            }
            return Ok(Self::from_rgba(
                SPRITE_SIZE as u16,
                SPRITE_SIZE as u16,
                rgba,
            ));
        }

        Err(format!(
            "Unsupported binary sprite format ({} bytes). Expected PNG or 16x16 packed palette bytes.",
            bytes.len()
        ))
    }

    pub fn from_base64(b64_text: &str) -> Result<Self, String> {
        let bytes = decode_base64(b64_text)?;
        Self::from_compressed_bytes(&bytes)
    }

    /// 16x16 パレットインデックスを 160 bytes (128B 4bit カラー + 32B 不透明マスク) にパックして Base64 化する
    pub fn encode_16x16_palette_b64(lines: &[&str]) -> String {
        let total_pixels = SPRITE_SIZE * SPRITE_SIZE;
        let mut buf = vec![0u8; total_pixels / 2 + total_pixels / 8];
        for (y, line) in lines.iter().take(SPRITE_SIZE).enumerate() {
            for (x, ch) in line.chars().take(SPRITE_SIZE).enumerate() {
                let i = y * SPRITE_SIZE + x;
                let color_idx = match ch {
                    '.' | ' ' => None,
                    c if c.is_ascii_hexdigit() => c.to_digit(16).map(|d| d as u8),
                    _ => None,
                };
                if let Some(idx) = color_idx {
                    if i % 2 == 0 {
                        buf[i / 2] |= (idx & 0x0F) << 4;
                    } else {
                        buf[i / 2] |= idx & 0x0F;
                    }
                    buf[total_pixels / 2 + i / 8] |= 1 << (7 - (i % 8));
                }
            }
        }
        encode_base64(&buf)
    }

    pub fn build_texture(&mut self) {
        let image = Image {
            bytes: self.rgba.clone(),
            width: self.width,
            height: self.height,
        };
        let texture = Texture2D::from_image(&image);
        texture.set_filter(FilterMode::Nearest);
        self.texture = Some(texture);
    }
}

/// PNG スプライトシート (Base64) を指定タイルサイズ (デフォルト 16x16) で分割して `sprites` に登録する
pub fn decode_png_sheet_into_sprites(
    b64_text: &str,
    start_id: i32,
    tile_w: u16,
    tile_h: u16,
    sprites: &mut HashMap<i32, SpriteData>,
) -> Result<usize, String> {
    let bytes = decode_base64(b64_text)?;
    let img = Image::from_file_with_format(&bytes, Some(ImageFormat::Png))
        .map_err(|e| format!("Failed to decode @SHEET PNG: {:?}", e))?;
    let tw = tile_w.max(1) as usize;
    let th = tile_h.max(1) as usize;
    let img_w = img.width as usize;
    let img_h = img.height as usize;

    let cols = img_w / tw;
    let rows = img_h / th;
    let mut count = 0usize;

    for ry in 0..rows {
        for rx in 0..cols {
            let mut tile_rgba = vec![0u8; tw * th * 4];
            for y in 0..th {
                let src_y = ry * th + y;
                let src_x = rx * tw;
                let src_off = (src_y * img_w + src_x) * 4;
                let dst_off = y * tw * 4;
                let row_bytes = tw * 4;
                tile_rgba[dst_off..dst_off + row_bytes]
                    .copy_from_slice(&img.bytes[src_off..src_off + row_bytes]);
            }
            let id = start_id + count as i32;
            sprites.insert(id, SpriteData::from_rgba(tw as u16, th as u16, tile_rgba));
            count += 1;
        }
    }

    Ok(count)
}

#[derive(Clone, Copy)]
enum ResourceBlockKind {
    TextSprite(i32),
    Base64Sprite(i32),
    PngSheet {
        start_id: i32,
        tile_w: u16,
        tile_h: u16,
    },
}

fn parse_tile_dims(s: &str) -> Option<(u16, u16)> {
    let lower = s.trim().to_ascii_lowercase();
    let (w_str, h_str) = lower.split_once('x')?;
    let w = w_str.trim().parse::<u16>().ok()?;
    let h = h_str.trim().parse::<u16>().ok()?;
    if w > 0 && h > 0 { Some((w, h)) } else { None }
}

fn flush_resource_block(
    kind: Option<ResourceBlockKind>,
    lines: &mut Vec<String>,
    sprites: &mut HashMap<i32, SpriteData>,
) {
    let Some(block_kind) = kind else {
        lines.clear();
        return;
    };
    if lines.is_empty() {
        return;
    }

    match block_kind {
        ResourceBlockKind::TextSprite(id) => {
            let refs: Vec<&str> = lines.iter().map(|s| s.as_str()).collect();
            sprites.insert(id, SpriteData::from_lines(&refs));
        }
        ResourceBlockKind::Base64Sprite(id) => {
            let joined = lines.join("");
            match SpriteData::from_base64(&joined) {
                Ok(sp) => {
                    sprites.insert(id, sp);
                }
                Err(e) => {
                    eprintln!("Warning: Failed to decode Base64 sprite {}: {}", id, e);
                }
            }
        }
        ResourceBlockKind::PngSheet {
            start_id,
            tile_w,
            tile_h,
        } => {
            let joined = lines.join("");
            if let Err(e) =
                decode_png_sheet_into_sprites(&joined, start_id, tile_w, tile_h, sprites)
            {
                eprintln!(
                    "Warning: Failed to decode @SHEET starting at {}: {}",
                    start_id, e
                );
            }
        }
    }
    lines.clear();
}

/// `__END__` 以降のスプライト定義 (`@SPRITE`, `@PNG`, `@B64`, `@SHEET`) をパースする
pub fn parse_tail_resources(data_section: &str) -> HashMap<i32, SpriteData> {
    let mut sprites = HashMap::new();
    let mut current_kind: Option<ResourceBlockKind> = None;
    let mut current_lines: Vec<String> = Vec::new();
    let mut emoji_atlas: Option<emoji::EmojiAtlas> = None;

    for raw_line in data_section.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some(rest) = line
            .strip_prefix("@SPRITE_B64")
            .or_else(|| line.strip_prefix("@PNG"))
            .or_else(|| line.strip_prefix("@B64"))
        {
            flush_resource_block(current_kind.take(), &mut current_lines, &mut sprites);
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(id) = id_str.parse::<i32>()
            {
                let inline_b64: String = parts.collect::<Vec<_>>().join("");
                if !inline_b64.is_empty() {
                    if let Ok(sp) = SpriteData::from_base64(&inline_b64) {
                        sprites.insert(id, sp);
                    }
                } else {
                    current_kind = Some(ResourceBlockKind::Base64Sprite(id));
                }
            }
        } else if let Some(rest) = line.strip_prefix("@SHEET") {
            flush_resource_block(current_kind.take(), &mut current_lines, &mut sprites);
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(start_id) = id_str.parse::<i32>()
            {
                let (tile_w, tile_h) = parts
                    .next()
                    .and_then(parse_tile_dims)
                    .unwrap_or((SPRITE_SIZE as u16, SPRITE_SIZE as u16));
                current_kind = Some(ResourceBlockKind::PngSheet {
                    start_id,
                    tile_w,
                    tile_h,
                });
            }
        } else if let Some(rest) = line.strip_prefix("@SPRITE") {
            flush_resource_block(current_kind.take(), &mut current_lines, &mut sprites);
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(id) = id_str.parse::<i32>()
            {
                if let Some(emoji_token) = parts.next() {
                    let atlas = emoji_atlas.get_or_insert_with(emoji::EmojiAtlas::new);
                    if let Some(sp) = atlas.extract_sprite(emoji_token) {
                        sprites.insert(id, sp);
                    }
                } else {
                    current_kind = Some(ResourceBlockKind::TextSprite(id));
                }
            }
        } else if current_kind.is_some() {
            current_lines.push(line.to_string());
        }
    }

    flush_resource_block(current_kind.take(), &mut current_lines, &mut sprites);
    sprites
}

/// Rubyオブジェクトの2次元配列または文字列配列 (`$SPRITES`) からスプライトをパースする
pub fn parse_ruby_sprites_global(
    vm: &VM,
    sprites: &mut HashMap<i32, SpriteData>,
    emoji_atlas: &emoji::EmojiAtlas,
) {
    let Some(sprites_obj) = vm.globals.get("$SPRITES") else {
        return;
    };
    let RValue::Array(ref list_cell) = sprites_obj.value else {
        return;
    };

    for (idx, item) in list_cell.borrow().iter().enumerate() {
        match &item.value {
            RValue::Array(rows_cell) => {
                let mut lines_owned = Vec::new();
                for row in rows_cell.borrow().iter() {
                    if let Ok(s) = String::try_from(row.as_ref()) {
                        lines_owned.push(s);
                    }
                }
                if !lines_owned.is_empty() {
                    let line_refs: Vec<&str> = lines_owned.iter().map(|s| s.as_str()).collect();
                    sprites.insert(idx as i32, SpriteData::from_lines(&line_refs));
                }
            }
            RValue::String(_, _) => {
                if let Ok(s) = String::try_from(item.as_ref()) {
                    let trimmed = s.trim();
                    if let Some(sp) = emoji_atlas.extract_sprite(trimmed) {
                        sprites.insert(idx as i32, sp);
                    } else if let Ok(sp) = SpriteData::from_base64(trimmed) {
                        sprites.insert(idx as i32, sp);
                    }
                }
            }
            _ => {}
        }
    }
}

// ==========================================
// 1-bit ピクセルフォント (5x7 グリフ / 6x8 セル, FilterMode::Nearest)
// ==========================================
const FONT_CHAR_W: usize = 6;
const FONT_CHAR_H: usize = 8;
const FONT_ATLAS_COLS: usize = 16;

/// ASCII 0x20 (' ') ..= 0x7E ('~') の 95 文字分の 5x7 ビットマップデータ (各文字 7 行、上位5ビット使用)
const FONT_5X7: [[u8; 7]; 95] = [
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], // 0x20 ' '
    [0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04], // 0x21 '!'
    [0x0A, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x00], // 0x22 '"'
    [0x0A, 0x0A, 0x1F, 0x0A, 0x1F, 0x0A, 0x0A], // 0x23 '#'
    [0x04, 0x0F, 0x14, 0x0E, 0x05, 0x1E, 0x04], // 0x24 '$'
    [0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03], // 0x25 '%'
    [0x0C, 0x12, 0x14, 0x08, 0x15, 0x12, 0x0D], // 0x26 '&'
    [0x04, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00], // 0x27 '\''
    [0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02], // 0x28 '('
    [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08], // 0x29 ')'
    [0x00, 0x04, 0x15, 0x0E, 0x15, 0x04, 0x00], // 0x2A '*'
    [0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00], // 0x2B '+'
    [0x00, 0x00, 0x00, 0x00, 0x04, 0x04, 0x08], // 0x2C ','
    [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00], // 0x2D '-'
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04], // 0x2E '.'
    [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x00], // 0x2F '/'
    [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E], // 0x30 '0'
    [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E], // 0x31 '1'
    [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F], // 0x32 '2'
    [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E], // 0x33 '3'
    [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02], // 0x34 '4'
    [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E], // 0x35 '5'
    [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E], // 0x36 '6'
    [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08], // 0x37 '7'
    [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E], // 0x38 '8'
    [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C], // 0x39 '9'
    [0x00, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00], // 0x3A ':'
    [0x00, 0x00, 0x04, 0x00, 0x04, 0x04, 0x08], // 0x3B ';'
    [0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02], // 0x3C '<'
    [0x00, 0x00, 0x1F, 0x00, 0x1F, 0x00, 0x00], // 0x3D '='
    [0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08], // 0x3E '>'
    [0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04], // 0x3F '?'
    [0x0E, 0x11, 0x01, 0x0D, 0x15, 0x15, 0x0E], // 0x40 '@'
    [0x0E, 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11], // 0x41 'A'
    [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E], // 0x42 'B'
    [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E], // 0x43 'C'
    [0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C], // 0x44 'D'
    [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F], // 0x45 'E'
    [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10], // 0x46 'F'
    [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F], // 0x47 'G'
    [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11], // 0x48 'H'
    [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E], // 0x49 'I'
    [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C], // 0x4A 'J'
    [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11], // 0x4B 'K'
    [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F], // 0x4C 'L'
    [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11], // 0x4D 'M'
    [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11], // 0x4E 'N'
    [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E], // 0x4F 'O'
    [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10], // 0x50 'P'
    [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D], // 0x51 'Q'
    [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11], // 0x52 'R'
    [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E], // 0x53 'S'
    [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04], // 0x54 'T'
    [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E], // 0x55 'U'
    [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04], // 0x56 'V'
    [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A], // 0x57 'W'
    [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11], // 0x58 'X'
    [0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04], // 0x59 'Y'
    [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F], // 0x5A 'Z'
    [0x0E, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0E], // 0x5B '['
    [0x00, 0x10, 0x08, 0x04, 0x02, 0x01, 0x00], // 0x5C '\\'
    [0x0E, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0E], // 0x5D ']'
    [0x04, 0x0A, 0x11, 0x00, 0x00, 0x00, 0x00], // 0x5E '^'
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F], // 0x5F '_'
    [0x08, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00], // 0x60 '`'
    [0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F], // 0x61 'a'
    [0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x1E], // 0x62 'b'
    [0x00, 0x00, 0x0E, 0x10, 0x10, 0x11, 0x0E], // 0x63 'c'
    [0x01, 0x01, 0x0F, 0x11, 0x11, 0x11, 0x0F], // 0x64 'd'
    [0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E], // 0x65 'e'
    [0x06, 0x09, 0x08, 0x1C, 0x08, 0x08, 0x08], // 0x66 'f'
    [0x00, 0x0F, 0x11, 0x11, 0x0F, 0x01, 0x0E], // 0x67 'g'
    [0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x11], // 0x68 'h'
    [0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E], // 0x69 'i'
    [0x02, 0x00, 0x06, 0x02, 0x02, 0x12, 0x0C], // 0x6A 'j'
    [0x10, 0x10, 0x12, 0x14, 0x18, 0x14, 0x12], // 0x6B 'k'
    [0x0C, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E], // 0x6C 'l'
    [0x00, 0x00, 0x1A, 0x15, 0x15, 0x11, 0x11], // 0x6D 'm'
    [0x00, 0x00, 0x1E, 0x11, 0x11, 0x11, 0x11], // 0x6E 'n'
    [0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E], // 0x6F 'o'
    [0x00, 0x00, 0x1E, 0x11, 0x1E, 0x10, 0x10], // 0x70 'p'
    [0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x01], // 0x71 'q'
    [0x00, 0x00, 0x16, 0x19, 0x10, 0x10, 0x10], // 0x72 'r'
    [0x00, 0x00, 0x0E, 0x10, 0x0E, 0x01, 0x1E], // 0x73 's'
    [0x08, 0x08, 0x1C, 0x08, 0x08, 0x09, 0x06], // 0x74 't'
    [0x00, 0x00, 0x11, 0x11, 0x11, 0x13, 0x0D], // 0x75 'u'
    [0x00, 0x00, 0x11, 0x11, 0x11, 0x0A, 0x04], // 0x76 'v'
    [0x00, 0x00, 0x11, 0x11, 0x15, 0x15, 0x0A], // 0x77 'w'
    [0x00, 0x00, 0x11, 0x0A, 0x04, 0x0A, 0x11], // 0x78 'x'
    [0x00, 0x00, 0x11, 0x11, 0x0F, 0x01, 0x0E], // 0x79 'y'
    [0x00, 0x00, 0x1F, 0x02, 0x04, 0x08, 0x1F], // 0x7A 'z'
    [0x02, 0x04, 0x04, 0x08, 0x04, 0x04, 0x02], // 0x7B '{'
    [0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04], // 0x7C '|'
    [0x08, 0x04, 0x04, 0x02, 0x04, 0x04, 0x08], // 0x7D '}'
    [0x00, 0x00, 0x08, 0x15, 0x02, 0x00, 0x00], // 0x7E '~'
];

const MISAKI_FONT_BIN: &[u8] = include_bytes!("../assets/misaki_font.bin");

/// 美咲フォント（Misaki Gothic 2nd, 8x8 1-bit）のバイナリテーブルから指定Unicodeコードポイントの8行ビットマップを二分探索で取得する
pub fn lookup_misaki_glyph(cp: u16) -> Option<[u8; 8]> {
    let count = MISAKI_FONT_BIN.len() / 10;
    let mut low = 0usize;
    let mut high = count;
    while low < high {
        let mid = (low + high) / 2;
        let off = mid * 10;
        let mid_cp = u16::from_le_bytes([MISAKI_FONT_BIN[off], MISAKI_FONT_BIN[off + 1]]);
        match mid_cp.cmp(&cp) {
            std::cmp::Ordering::Equal => {
                let mut rows = [0u8; 8];
                rows.copy_from_slice(&MISAKI_FONT_BIN[off + 2..off + 10]);
                return Some(rows);
            }
            std::cmp::Ordering::Less => low = mid + 1,
            std::cmp::Ordering::Greater => high = mid,
        }
    }
    None
}

pub struct BitmapFont {
    texture: Option<Texture2D>,
    ja_cache: RefCell<HashMap<u16, Texture2D>>,
}

impl Default for BitmapFont {
    fn default() -> Self {
        Self::new(false)
    }
}

impl BitmapFont {
    pub fn new(build_gpu_texture: bool) -> Self {
        if !build_gpu_texture {
            return Self {
                texture: None,
                ja_cache: RefCell::new(HashMap::new()),
            };
        }
        let rows = (FONT_5X7.len() + FONT_ATLAS_COLS - 1) / FONT_ATLAS_COLS;
        let atlas_w = FONT_ATLAS_COLS * FONT_CHAR_W;
        let atlas_h = rows * FONT_CHAR_H;
        let mut rgba = vec![0u8; atlas_w * atlas_h * 4];

        for (idx, glyph) in FONT_5X7.iter().enumerate() {
            let col = idx % FONT_ATLAS_COLS;
            let row = idx / FONT_ATLAS_COLS;
            for (gy, &bits) in glyph.iter().enumerate() {
                for gx in 0..5 {
                    if ((bits >> (4 - gx)) & 1) != 0 {
                        let ax = col * FONT_CHAR_W + gx;
                        let ay = row * FONT_CHAR_H + gy;
                        let off = (ay * atlas_w + ax) * 4;
                        rgba[off] = 255;
                        rgba[off + 1] = 255;
                        rgba[off + 2] = 255;
                        rgba[off + 3] = 255;
                    }
                }
            }
        }

        let image = Image {
            bytes: rgba,
            width: atlas_w as u16,
            height: atlas_h as u16,
        };
        let texture = Texture2D::from_image(&image);
        texture.set_filter(FilterMode::Nearest);
        Self {
            texture: Some(texture),
            ja_cache: RefCell::new(HashMap::new()),
        }
    }

    pub fn draw_text_crisp(
        &self,
        text: &str,
        x: f32,
        y: f32,
        color: Color,
        emoji_atlas: &RefCell<emoji::EmojiAtlas>,
    ) {
        let Some(ref texture) = self.texture else {
            return;
        };
        let mut cur_x = x.floor();
        let mut cur_y = y.floor();
        let start_x = cur_x;

        let mut chars = text.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch == '\n' {
                cur_x = start_x;
                cur_y += FONT_CHAR_H as f32;
                continue;
            }
            let code = ch as u32;
            // Variation Selector (FE0E, FE0F), Zero Width Joiner (200D), スキントーン修飾子は単体では幅を進めない
            if code == 0xFE0E
                || code == 0xFE0F
                || code == 0x200D
                || (0x1F3FB..=0x1F3FF).contains(&code)
            {
                continue;
            }

            // 直後に Variation Selector が続く場合は先読みして消費する
            let next_vs = match chars.peek().copied() {
                Some('\u{FE0F}') | Some('\u{FE0E}') => chars.next(),
                _ => None,
            };

            if (0x20..=0x7E).contains(&code) {
                let idx = (code - 0x20) as usize;
                let col = idx % FONT_ATLAS_COLS;
                let row = idx / FONT_ATLAS_COLS;
                draw_texture_ex(
                    texture,
                    cur_x,
                    cur_y,
                    color,
                    DrawTextureParams {
                        source: Some(Rect::new(
                            (col * FONT_CHAR_W) as f32,
                            (row * FONT_CHAR_H) as f32,
                            FONT_CHAR_W as f32,
                            FONT_CHAR_H as f32,
                        )),
                        ..Default::default()
                    },
                );
                cur_x += FONT_CHAR_W as f32;
                continue;
            }

            // 絵文字判定:
            // - テキスト異体字セレクタ (FE0E) が明示されていない
            // - 絵文字アトラスに収録されており、以下のいずれかを満たす:
            //   1) 非BMP文字 (code > 0xFFFF, 例: 🐰, 🐢, 🍎)
            //   2) 絵文字異体字セレクタ (FE0F) が付与されている (例: ⚔️, ❤️, ☀️)
            //   3) 0x2300 以上の絵文字記号または美咲フォントに存在しない絵文字コードポイント (例: ⭐, ✨)
            let prefer_emoji = next_vs != Some('\u{FE0E}')
                && emoji::is_emoji_codepoint(code)
                && (code > 0xFFFF
                    || next_vs == Some('\u{FE0F}')
                    || code >= 0x2300
                    || lookup_misaki_glyph(code as u16).is_none());

            if prefer_emoji {
                let mut atlas_ref = emoji_atlas.borrow_mut();
                if let Some(sprite) = atlas_ref.get_or_insert_8x8_by_cp(code, true)
                    && let Some(ref emoji_tex) = sprite.texture
                {
                    draw_texture_ex(
                        emoji_tex,
                        cur_x,
                        cur_y,
                        WHITE,
                        DrawTextureParams::default(),
                    );
                }
                cur_x += 8.0;
                continue;
            }

            if code <= 0xFFFF {
                let cp = code as u16;
                if cp != 0x3000 {
                    // 全角空白以外ならグリフテクスチャを取得または生成して描画
                    if !self.ja_cache.borrow().contains_key(&cp) {
                        if let Some(rows) = lookup_misaki_glyph(cp) {
                            let mut rgba = vec![0u8; 8 * 8 * 4];
                            for (gy, &bits) in rows.iter().enumerate() {
                                for gx in 0..8 {
                                    if ((bits >> (7 - gx)) & 1) != 0 {
                                        let off = (gy * 8 + gx) * 4;
                                        rgba[off] = 255;
                                        rgba[off + 1] = 255;
                                        rgba[off + 2] = 255;
                                        rgba[off + 3] = 255;
                                    }
                                }
                            }
                            let image = Image {
                                bytes: rgba,
                                width: 8,
                                height: 8,
                            };
                            let tex = Texture2D::from_image(&image);
                            tex.set_filter(FilterMode::Nearest);
                            self.ja_cache.borrow_mut().insert(cp, tex);
                        }
                    }
                    if let Some(tex) = self.ja_cache.borrow().get(&cp) {
                        draw_texture_ex(tex, cur_x, cur_y, color, DrawTextureParams::default());
                    }
                }
                // 半角カタカナ (0xFF61..=0xFF9F) は幅4px、全角文字・記号は幅8px
                if (0xFF61..=0xFF9F).contains(&cp) {
                    cur_x += 4.0;
                } else {
                    cur_x += 8.0;
                }
            } else {
                cur_x += FONT_CHAR_W as f32;
            }
        }
    }
}

// ==========================================
// Ruby エンジン API の登録
// ==========================================
fn arg_i32(args: &[Rc<RObject>], index: usize, default: i32) -> i32 {
    args.get(index)
        .and_then(|v| match &v.value {
            RValue::Integer(i) => Some(*i as i32),
            RValue::Float(f) => Some(*f as i32),
            _ => i32::try_from(v.as_ref()).ok(),
        })
        .unwrap_or(default)
}

fn arg_f32(args: &[Rc<RObject>], index: usize, default: f32) -> f32 {
    args.get(index)
        .and_then(|v| match &v.value {
            RValue::Integer(i) => Some(*i as f32),
            RValue::Float(f) => Some(*f as f32),
            _ => f64::try_from(v.as_ref()).ok().map(|f| f as f32),
        })
        .unwrap_or(default)
}

fn arg_bool(args: &[Rc<RObject>], index: usize, default: bool) -> bool {
    args.get(index)
        .and_then(|v| bool::try_from(v.as_ref()).ok())
        .unwrap_or(default)
}

/// スプライトの元の矩形 `(x, y, w, h)` の中心を基準（ピボット）として、
/// 回転角 `rotate_deg`（度数法・時計回り）および拡大率 `scale` を適用した描画座標と `DrawTextureParams` を計算する。
pub fn compute_sprite_draw_params(
    w: f32,
    h: f32,
    x: f32,
    y: f32,
    flip_x: bool,
    flip_y: bool,
    rotate_deg: f32,
    scale: f32,
) -> Option<(f32, f32, DrawTextureParams)> {
    if !scale.is_finite() || scale.abs() < f32::EPSILON {
        return None;
    }
    let (s, fx, fy) = if scale < 0.0 {
        (-scale, !flip_x, !flip_y)
    } else {
        (scale, flip_x, flip_y)
    };

    let base_x = x.floor();
    let base_y = y.floor();
    let center_x = base_x + w * 0.5;
    let center_y = base_y + h * 0.5;
    let scaled_w = w * s;
    let scaled_h = h * s;
    let draw_x = center_x - scaled_w * 0.5;
    let draw_y = center_y - scaled_h * 0.5;
    let rotation = if rotate_deg.is_finite() {
        rotate_deg.to_radians()
    } else {
        0.0
    };

    Some((
        draw_x,
        draw_y,
        DrawTextureParams {
            dest_size: Some(vec2(scaled_w, scaled_h)),
            rotation,
            flip_x: fx,
            flip_y: fy,
            pivot: Some(vec2(center_x, center_y)),
            ..Default::default()
        },
    ))
}

fn draw_sprite_transformed(
    sprite: &SpriteData,
    x: f32,
    y: f32,
    flip_x: bool,
    flip_y: bool,
    rotate_deg: f32,
    scale: f32,
) {
    let Some(ref texture) = sprite.texture else {
        return;
    };
    if let Some((draw_x, draw_y, params)) = compute_sprite_draw_params(
        sprite.width as f32,
        sprite.height as f32,
        x,
        y,
        flip_x,
        flip_y,
        rotate_deg,
        scale,
    ) {
        draw_texture_ex(texture, draw_x, draw_y, WHITE, params);
    }
}

fn register_engine_api(
    vm: &mut VM,
    sprites: Rc<RefCell<HashMap<i32, SpriteData>>>,
    emoji_atlas: Rc<RefCell<emoji::EmojiAtlas>>,
    bitmap_font: Rc<BitmapFont>,
    headless: bool,
) {
    let obj_class = vm.object_class.clone();

    if headless {
        // ヘッドレステスト用スタブ登録 (spr / print_text に絵文字が渡された場合はキャッシュ抽出も検証可能にする)
        for name in ["cls", "pset", "rectfill"] {
            mrb_define_cmethod(
                vm,
                obj_class.clone(),
                name,
                Box::new(|_vm, _args| Ok(Rc::new(RObject::nil()))),
            );
        }
        let emoji_for_headless_print = emoji_atlas.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "print_text",
            Box::new(move |_vm, args| {
                if let Some(first) = args.first()
                    && let Ok(text) = String::try_from(first.as_ref())
                {
                    let mut atlas = emoji_for_headless_print.borrow_mut();
                    for ch in text.chars() {
                        let cp = ch as u32;
                        if emoji::is_emoji_codepoint(cp) {
                            let _ = atlas.get_or_insert_8x8_by_cp(cp, false);
                        }
                    }
                }
                Ok(Rc::new(RObject::nil()))
            }),
        );
        let sprites_for_headless = sprites.clone();
        let emoji_for_headless = emoji_atlas.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "spr",
            Box::new(move |_vm, args| {
                let x = arg_f32(args, 1, 0.0);
                let y = arg_f32(args, 2, 0.0);
                let flip_x = arg_bool(args, 3, false);
                let flip_y = arg_bool(args, 4, false);
                let rotate = arg_f32(args, 5, 0.0);
                let scale = arg_f32(args, 6, 1.0);

                if let Some(first) = args.first() {
                    if matches!(first.value, RValue::String(_, _)) {
                        if let Ok(s) = String::try_from(first.as_ref()) {
                            if let Some(sp) = emoji_for_headless.borrow_mut().get_or_insert(&s, false) {
                                let _ = compute_sprite_draw_params(
                                    sp.width as f32,
                                    sp.height as f32,
                                    x,
                                    y,
                                    flip_x,
                                    flip_y,
                                    rotate,
                                    scale,
                                );
                            }
                        }
                        return Ok(Rc::new(RObject::nil()));
                    }
                }
                let id = arg_i32(args, 0, 0);
                if let Some(sp) = sprites_for_headless.borrow().get(&id) {
                    let _ = compute_sprite_draw_params(
                        sp.width as f32,
                        sp.height as f32,
                        x,
                        y,
                        flip_x,
                        flip_y,
                        rotate,
                        scale,
                    );
                }
                Ok(Rc::new(RObject::nil()))
            }),
        );
        mrb_define_cmethod(
            vm,
            obj_class,
            "btn",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::boolean(false)))),
        );
        return;
    }

    // cls(col = 0): 画面を指定したパレット色でクリア
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "cls",
        Box::new(|_vm, args| {
            let col = arg_i32(args, 0, 0);
            clear_background(palette_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // pset(x, y, col = 7): 1ドット描画
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "pset",
        Box::new(|_vm, args| {
            let x = arg_i32(args, 0, 0) as f32;
            let y = arg_i32(args, 1, 0) as f32;
            let col = arg_i32(args, 2, 7);
            draw_rectangle(x, y, 1.0, 1.0, palette_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // rectfill(x, y, w, h, col = 7): 塗りつぶし矩形
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "rectfill",
        Box::new(|_vm, args| {
            let x = arg_i32(args, 0, 0) as f32;
            let y = arg_i32(args, 1, 0) as f32;
            let w = arg_i32(args, 2, 16) as f32;
            let h = arg_i32(args, 3, 16) as f32;
            let col = arg_i32(args, 4, 7);
            draw_rectangle(x, y, w, h, palette_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // spr(id_or_emoji, x = 0, y = 0, flip_x = false, flip_y = false, rotate = 0, scale = 1.0): スプライトまたは16x16絵文字描画
    let sprites_for_spr = sprites.clone();
    let emoji_for_spr = emoji_atlas.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "spr",
        Box::new(move |_vm, args| {
            let x = arg_f32(args, 1, 0.0);
            let y = arg_f32(args, 2, 0.0);
            let flip_x = arg_bool(args, 3, false);
            let flip_y = arg_bool(args, 4, false);
            let rotate = arg_f32(args, 5, 0.0);
            let scale = arg_f32(args, 6, 1.0);

            if let Some(first) = args.first()
                && matches!(first.value, RValue::String(_, _))
                && let Ok(emoji_str) = String::try_from(first.as_ref())
            {
                let mut atlas_ref = emoji_for_spr.borrow_mut();
                if let Some(sprite) = atlas_ref.get_or_insert(&emoji_str, true) {
                    draw_sprite_transformed(sprite, x, y, flip_x, flip_y, rotate, scale);
                }
                return Ok(Rc::new(RObject::nil()));
            }

            let id = arg_i32(args, 0, 0);
            let sprites_ref = sprites_for_spr.borrow();
            if let Some(sprite) = sprites_ref.get(&id) {
                draw_sprite_transformed(sprite, x, y, flip_x, flip_y, rotate, scale);
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // btn(id): ボタン入力判定 (0:左, 1:右, 2:上, 3:下, 4:Z/Space, 5:X/Enter)
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "btn",
        Box::new(|_vm, args| {
            let id = arg_i32(args, 0, 0);
            let pressed = match id {
                0 => is_key_down(KeyCode::Left) || is_key_down(KeyCode::A),
                1 => is_key_down(KeyCode::Right) || is_key_down(KeyCode::D),
                2 => is_key_down(KeyCode::Up) || is_key_down(KeyCode::W),
                3 => is_key_down(KeyCode::Down) || is_key_down(KeyCode::S),
                4 => is_key_down(KeyCode::Z) || is_key_down(KeyCode::Space),
                5 => is_key_down(KeyCode::X) || is_key_down(KeyCode::Enter),
                _ => false,
            };
            Ok(Rc::new(RObject::boolean(pressed)))
        }),
    );

    // print_text(text, x = 0, y = 0, col = 7): 1-bit ピクセルフォント + 8x8 縮小絵文字でくっきりテキスト描画
    let font_for_print = bitmap_font.clone();
    let emoji_for_print = emoji_atlas.clone();
    mrb_define_cmethod(
        vm,
        obj_class,
        "print_text",
        Box::new(move |_vm, args| {
            let text = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            let x = arg_i32(args, 1, 0) as f32;
            let y = arg_i32(args, 2, 0) as f32;
            let col = arg_i32(args, 3, 7);
            font_for_print.draw_text_crisp(&text, x, y, palette_color(col), &emoji_for_print);
            Ok(Rc::new(RObject::nil()))
        }),
    );
}

// ==========================================
// ゲームランタイム & ホットリロード管理
// ==========================================
fn deep_clone_robject(obj: &Rc<RObject>) -> Rc<RObject> {
    let cloned_value = match &obj.value {
        RValue::Array(arr) => {
            let items = arr.borrow().iter().map(deep_clone_robject).collect();
            RValue::Array(RefCell::new(items))
        }
        RValue::Hash(map) => {
            let cloned_map = map
                .borrow()
                .iter()
                .map(|(k, (rk, rv))| (k.clone(), (deep_clone_robject(rk), deep_clone_robject(rv))))
                .collect();
            RValue::Hash(RefCell::new(cloned_map))
        }
        RValue::Range(start, end, excl) => {
            RValue::Range(deep_clone_robject(start), deep_clone_robject(end), *excl)
        }
        other => other.clone(),
    };
    let mut cloned = (**obj).clone();
    cloned.value = cloned_value;
    Rc::new(cloned)
}

fn robject_equals(a: &RObject, b: &RObject) -> bool {
    match (&a.value, &b.value) {
        (RValue::Nil, RValue::Nil) => true,
        (RValue::Bool(x), RValue::Bool(y)) => x == y,
        (RValue::Integer(x), RValue::Integer(y)) => x == y,
        (RValue::Float(x), RValue::Float(y)) => x == y,
        (RValue::Symbol(x), RValue::Symbol(y)) => x.name == y.name,
        (RValue::String(x, _), RValue::String(y, _)) => *x.borrow() == *y.borrow(),
        (RValue::Array(x), RValue::Array(y)) => {
            let xb = x.borrow();
            let yb = y.borrow();
            xb.len() == yb.len()
                && xb
                    .iter()
                    .zip(yb.iter())
                    .all(|(xi, yi)| robject_equals(xi, yi))
        }
        (RValue::Range(s1, e1, ex1), RValue::Range(s2, e2, ex2)) => {
            ex1 == ex2 && robject_equals(s1, s2) && robject_equals(e1, e2)
        }
        _ => a.object_id.get() == b.object_id.get(),
    }
}

fn snapshot_globals(vm: &VM) -> HashMap<String, Rc<RObject>> {
    vm.globals
        .iter()
        .map(|(k, v)| (k.clone(), deep_clone_robject(v)))
        .collect()
}

pub struct GameRuntime {
    pub vm: VM,
    pub sprites: Rc<RefCell<HashMap<i32, SpriteData>>>,
    pub emoji_atlas: Rc<RefCell<emoji::EmojiAtlas>>,
    pub bitmap_font: Rc<BitmapFont>,
    initial_globals: HashMap<String, Rc<RObject>>,
    headless: bool,
}

impl GameRuntime {
    pub fn new(tail_data: &str, mrb_bytes: &[u8], headless: bool) -> Result<Self, String> {
        let mut sprites_map = parse_tail_resources(tail_data);

        let mut rite =
            rite::load(mrb_bytes).map_err(|e| format!("Failed to load RITE(.mrb): {:?}", e))?;
        let mut vm = VM::open(&mut rite);

        let sprites = Rc::new(RefCell::new(HashMap::new()));
        let emoji_atlas = Rc::new(RefCell::new(emoji::EmojiAtlas::new()));
        let bitmap_font = Rc::new(BitmapFont::new(!headless));
        register_engine_api(
            &mut vm,
            sprites.clone(),
            emoji_atlas.clone(),
            bitmap_font.clone(),
            headless,
        );

        vm.run()
            .map_err(|e| format!("Failed to run top-level Ruby script: {:?}", e))?;

        parse_ruby_sprites_global(&vm, &mut sprites_map, &emoji_atlas.borrow());
        if !headless {
            for sprite in sprites_map.values_mut() {
                sprite.build_texture();
            }
        }
        *sprites.borrow_mut() = sprites_map;

        let initial_globals = snapshot_globals(&vm);

        Ok(Self {
            vm,
            sprites,
            emoji_atlas,
            bitmap_font,
            initial_globals,
            headless,
        })
    }

    /// グローバル変数（`$x`, `$y`, `$t` 等）の実行時状態を維持したまま、
    /// メソッド定義とスプライト定義をホットリロードする。
    /// ただしスクリプト上のトップレベル初期値自体が書き換えられた変数は新しい初期値を採用する。
    pub fn hot_reload(&mut self, new_tail_data: &str, new_mrb_bytes: &[u8]) -> Result<(), String> {
        let mut new_sprites_map = parse_tail_resources(new_tail_data);

        let mut new_rite = rite::load(new_mrb_bytes)
            .map_err(|e| format!("Failed to load RITE(.mrb) on reload: {:?}", e))?;
        let mut new_vm = VM::open(&mut new_rite);

        register_engine_api(
            &mut new_vm,
            self.sprites.clone(),
            self.emoji_atlas.clone(),
            self.bitmap_font.clone(),
            self.headless,
        );

        new_vm
            .run()
            .map_err(|e| format!("Ruby top-level error on reload: {:?}", e))?;

        parse_ruby_sprites_global(&new_vm, &mut new_sprites_map, &self.emoji_atlas.borrow());
        if !self.headless {
            for sprite in new_sprites_map.values_mut() {
                sprite.build_texture();
            }
        }
        *self.sprites.borrow_mut() = new_sprites_map;

        let new_initial_globals = snapshot_globals(&new_vm);

        // 以前のVMから現在のグローバル変数を引き継ぐ
        for (name, live_val) in &self.vm.globals {
            if name == "$SPRITES" {
                continue;
            }
            let init_changed = match (
                self.initial_globals.get(name),
                new_initial_globals.get(name),
            ) {
                (Some(old_init), Some(new_init)) => !robject_equals(old_init, new_init),
                _ => false,
            };

            if !init_changed {
                new_vm
                    .globals
                    .insert(name.clone(), deep_clone_robject(live_val));
            }
        }

        self.vm = new_vm;
        self.initial_globals = new_initial_globals;
        Ok(())
    }

    pub fn call_update(&mut self) {
        if let Err(e) = mrb_funcall(&mut self.vm, None, "update", &[]) {
            eprintln!("Ruby error in `update`: {:?}", e);
        }
    }

    pub fn call_draw(&mut self) {
        if let Err(e) = mrb_funcall(&mut self.vm, None, "draw", &[]) {
            eprintln!("Ruby error in `draw`: {:?}", e);
        }
    }
}

// ==========================================
// ウィンドウ & 描画ループ共通処理
// ==========================================
fn window_conf_with_title(title: &str) -> Conf {
    Conf {
        window_title: title.to_owned(),
        window_width: WINDOW_WIDTH,
        window_height: WINDOW_HEIGHT,
        window_resizable: true,
        ..Default::default()
    }
}

fn create_virtual_screen() -> (RenderTarget, Camera2D) {
    let rt = render_target(SCREEN_WIDTH, SCREEN_HEIGHT);
    rt.texture.set_filter(FilterMode::Nearest);

    let mut cam =
        Camera2D::from_display_rect(Rect::new(0.0, 0.0, SCREEN_WIDTH as f32, SCREEN_HEIGHT as f32));
    cam.render_target = Some(rt.clone());
    (rt, cam)
}

fn present_virtual_screen(render_target: &RenderTarget, reload_banner_frames: u32) {
    set_default_camera();
    clear_background(BLACK);

    let win_w = screen_width();
    let win_h = screen_height();
    let scale = (win_w / SCREEN_WIDTH as f32).min(win_h / SCREEN_HEIGHT as f32);
    let draw_w = SCREEN_WIDTH as f32 * scale;
    let draw_h = SCREEN_HEIGHT as f32 * scale;
    let offset_x = ((win_w - draw_w) * 0.5).floor();
    let offset_y = ((win_h - draw_h) * 0.5).floor();

    draw_texture_ex(
        &render_target.texture,
        offset_x,
        offset_y,
        WHITE,
        DrawTextureParams {
            dest_size: Some(vec2(draw_w, draw_h)),
            // Macroquad の RenderTarget は上下反転するため flip_y: true で正立させる
            flip_y: true,
            ..Default::default()
        },
    );

    if reload_banner_frames > 0 {
        let banner_h = 22.0;
        draw_rectangle(
            offset_x,
            offset_y,
            draw_w,
            banner_h,
            Color::new(0.0, 0.53, 0.32, 0.85),
        );
        draw_text(
            "HOT RELOADED",
            offset_x + 8.0,
            offset_y + 15.0,
            16.0,
            palette_color(7),
        );
    }
}

// ==========================================
// ネイティブ環境エントリポイント (`uk` CLI)
// ==========================================
#[cfg(not(target_arch = "wasm32"))]
async fn run_native_with_hot_reload(
    script_path: std::path::PathBuf,
    initial_source: String,
    initial_tail: String,
    initial_mrb: Vec<u8>,
) {
    let mut runtime = match GameRuntime::new(&initial_tail, &initial_mrb, false) {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("{}", e);
            return;
        }
    };

    let (render_target, virtual_camera) = create_virtual_screen();
    let mut last_source = initial_source;
    let mut last_modified = std::fs::metadata(&script_path)
        .and_then(|m| m.modified())
        .ok();
    let mut frame_count: u64 = 0;
    let mut reload_banner_frames: u32 = 0;

    loop {
        frame_count = frame_count.wrapping_add(1);

        // 15フレーム (~0.25秒) ごとにスクリプトファイルの変更を検知してホットリロード
        if frame_count.is_multiple_of(15) {
            let current_modified = std::fs::metadata(&script_path)
                .and_then(|m| m.modified())
                .ok();
            if current_modified != last_modified {
                last_modified = current_modified;
                if let Ok(new_source) = std::fs::read_to_string(&script_path)
                    && !new_source.is_empty()
                    && new_source != last_source
                {
                    last_source = new_source.clone();
                    match cli::compile_ruby_script_str(&new_source) {
                        Ok((new_tail, new_mrb)) => {
                            match runtime.hot_reload(&new_tail, &new_mrb) {
                                Ok(()) => {
                                    println!("[uk run] Hot-reloaded `{}`", script_path.display());
                                    reload_banner_frames = 60;
                                }
                                Err(e) => {
                                    eprintln!(
                                        "[uk run] Hot-reload runtime error in `{}`:\n{}",
                                        script_path.display(),
                                        e
                                    );
                                }
                            }
                        }
                        Err(e) => {
                            eprintln!(
                                "[uk run] Hot-reload compile error in `{}`:\n{}",
                                script_path.display(),
                                e
                            );
                        }
                    }
                }
            }
        }

        runtime.call_update();

        set_camera(&virtual_camera);
        runtime.call_draw();

        present_virtual_screen(&render_target, reload_banner_frames);
        reload_banner_frames = reload_banner_frames.saturating_sub(1);

        next_frame().await;
    }
}

#[cfg(not(target_arch = "wasm32"))]
async fn run_embedded_game(tail_data: String, mrb_bytes: Vec<u8>) {
    let mut runtime = match GameRuntime::new(&tail_data, &mrb_bytes, false) {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("{}", e);
            return;
        }
    };

    let (render_target, virtual_camera) = create_virtual_screen();

    loop {
        runtime.call_update();

        set_camera(&virtual_camera);
        runtime.call_draw();

        present_virtual_screen(&render_target, 0);

        next_frame().await;
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn main() {
    let action = match cli::parse_cli_args(std::env::args()) {
        Ok(act) => act,
        Err(err) => {
            eprintln!("Error: {}", err);
            std::process::exit(1);
        }
    };

    match action {
        cli::CliAction::Help => {
            cli::print_help();
        }
        cli::CliAction::Version => {
            cli::print_version();
        }
        cli::CliAction::Build {
            script_path,
            output_path,
        } => {
            if let Err(err) = cli::cmd_build(&script_path, output_path.as_deref()) {
                eprintln!("Error: {}", err);
                std::process::exit(1);
            }
        }
        cli::CliAction::Browser {
            script_path,
            port,
            open_browser,
        } => {
            if let Err(err) = cli::cmd_browser(&script_path, port, open_browser) {
                eprintln!("Error: {}", err);
                std::process::exit(1);
            }
        }
        cli::CliAction::Encode {
            image_path,
            start_id,
            tile_size,
        } => {
            if let Err(err) = cli::cmd_encode(&image_path, start_id, tile_size) {
                eprintln!("Error: {}", err);
                std::process::exit(1);
            }
        }
        cli::CliAction::Run { script_path } => {
            let (initial_source, tail_data, mrb_bytes) =
                match cli::compile_ruby_script_file(&script_path) {
                    Ok(res) => res,
                    Err(err) => {
                        eprintln!("Error: {}", err);
                        std::process::exit(1);
                    }
                };
            let title = format!("Usakame - {}", script_path.display());
            macroquad::Window::from_config(
                window_conf_with_title(&title),
                run_native_with_hot_reload(script_path, initial_source, tail_data, mrb_bytes),
            );
        }
        cli::CliAction::RunEmbedded {
            tail_data,
            mrb_bytes,
            title,
        } => {
            macroquad::Window::from_config(
                window_conf_with_title(&title),
                run_embedded_game(tail_data, mrb_bytes),
            );
        }
    }
}

// ==========================================
// WASM (ブラウザ) 環境エントリポイント
// ==========================================
#[cfg(target_arch = "wasm32")]
const EMBEDDED_SOURCE: &str = include_str!("../game.rb");
#[cfg(target_arch = "wasm32")]
const EMBEDDED_MRB: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/game.mrb"));

#[cfg(target_arch = "wasm32")]
static WASM_RELOAD_REQUESTED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

#[cfg(target_arch = "wasm32")]
#[unsafe(no_mangle)]
pub extern "C" fn uk_notify_reload() {
    WASM_RELOAD_REQUESTED.store(true, std::sync::atomic::Ordering::SeqCst);
}

#[cfg(target_arch = "wasm32")]
fn window_conf_wasm() -> Conf {
    window_conf_with_title("Usakame Retro Engine (256x256)")
}

#[cfg(target_arch = "wasm32")]
#[macroquad::main(window_conf_wasm)]
async fn main() {
    // `uk browser` サーバーから配信される `/__uk_bundle.bin` を優先取得し、無ければ埋め込みデータへフォールバック
    let (tail_data, mrb_bytes) = match macroquad::file::load_file("__uk_bundle.bin").await {
        Ok(bytes) => bundle::unpack_bundle_from_bytes(&bytes).unwrap_or_else(|| {
            let tail = EMBEDDED_SOURCE
                .splitn(2, "__END__")
                .nth(1)
                .unwrap_or("")
                .to_string();
            (tail, EMBEDDED_MRB.to_vec())
        }),
        Err(_) => {
            let tail = EMBEDDED_SOURCE
                .splitn(2, "__END__")
                .nth(1)
                .unwrap_or("")
                .to_string();
            (tail, EMBEDDED_MRB.to_vec())
        }
    };

    let mut runtime = GameRuntime::new(&tail_data, &mrb_bytes, false)
        .expect("Failed to initialize WASM GameRuntime");
    let (render_target, virtual_camera) = create_virtual_screen();
    let mut reload_banner_frames: u32 = 0;

    loop {
        if WASM_RELOAD_REQUESTED.swap(false, std::sync::atomic::Ordering::SeqCst) {
            let url = format!("__uk_bundle.bin?t={}", macroquad::time::get_time());
            if let Ok(bytes) = macroquad::file::load_file(&url).await
                && let Some((new_tail, new_mrb)) = bundle::unpack_bundle_from_bytes(&bytes)
            {
                match runtime.hot_reload(&new_tail, &new_mrb) {
                    Ok(()) => {
                        reload_banner_frames = 60;
                    }
                    Err(e) => {
                        eprintln!("Hot-reload error in browser: {}", e);
                    }
                }
            }
        }

        runtime.call_update();

        set_camera(&virtual_camera);
        runtime.call_draw();

        present_virtual_screen(&render_target, reload_banner_frames);
        reload_banner_frames = reload_banner_frames.saturating_sub(1);

        next_frame().await;
    }
}

// ==========================================
// テスト
// ==========================================
#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundle::{pack_bundle, strip_bundle_from_exe_bytes, unpack_bundle_from_bytes};

    #[test]
    fn test_resolution_and_sprite_constants() {
        assert_eq!(SCREEN_WIDTH, 256);
        assert_eq!(SCREEN_HEIGHT, 256);
        assert_eq!(WINDOW_WIDTH, 512);
        assert_eq!(WINDOW_HEIGHT, 512);
        assert_eq!(SPRITE_SIZE, 16);
    }

    #[test]
    fn test_script_compile_and_sprite_parse() {
        let (_, tail_data, mrb_bytes) =
            cli::compile_ruby_script_file(std::path::Path::new("game.rb"))
                .expect("game.rb should compile");

        let mut runtime =
            GameRuntime::new(&tail_data, &mrb_bytes, true).expect("Runtime should initialize");

        {
            let sprites = runtime.sprites.borrow();
            assert!(sprites.contains_key(&0), "Sprite 0 should be parsed");
            assert!(sprites.contains_key(&1), "Sprite 1 should be parsed");
            assert_eq!(sprites[&0].width, 16);
            assert_eq!(sprites[&0].height, 16);
        }

        runtime.call_update();
        let t_val: i32 = runtime
            .vm
            .globals
            .get("$t")
            .expect("$t should exist")
            .as_ref()
            .try_into()
            .unwrap();
        assert_eq!(t_val, 1);
    }

    #[test]
    fn test_emoji_and_base64_sprites_in_script() {
        let pattern_lines = [
            "....77....77....",
            "...7887..7887...",
            "...7887..7887...",
            "...7777..7777...",
            "...7777777777...",
            "..777777777777..",
            ".77707777770777.",
            ".777777EE777777.",
            ".77777777777777.",
            "..777777777777..",
            "...7777777777...",
            "..777777777777..",
            "..777777777777..",
            "...7777..7777...",
            "...777....777...",
            "................",
        ];
        let b64_compact = SpriteData::encode_16x16_palette_b64(&pattern_lines);

        let script = format!(
            r#"
def update
end

def draw
  spr("🐰", 10, 20)
  spr("🐢", 30, 40, true, false)
  spr("⚔️", 50, 60)
  spr(10, 70, 80)
  spr(20, 90, 100)
end
__END__
@SPRITE 10 🍎

@B64 20
{}
"#,
            b64_compact
        );

        let (tail, mrb) = cli::compile_ruby_script_str(&script).unwrap();
        let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();

        {
            let sprites = runtime.sprites.borrow();
            // @SPRITE 10 🍎 (絵文字エイリアス)
            assert!(sprites.contains_key(&10));
            assert_eq!(sprites[&10].width, 16);
            assert_eq!(sprites[&10].height, 16);

            // @B64 20 (Base64圧縮パレットスプライト)
            assert!(sprites.contains_key(&20));
            let expected = SpriteData::from_lines(&pattern_lines);
            assert_eq!(sprites[&20].rgba, expected.rgba);
        }

        // draw 内で spr("🐰", ...) 等が呼ばれてもエラーにならないこと
        runtime.call_draw();
    }

    #[test]
    fn test_hot_reload_preserves_globals_and_updates_methods_and_sprites() {
        let script_v1 = r#"
$x = 60
$y = 60
$t = 0

def update
  $x += 5
  $t += 1
end

def draw
end
__END__
@SPRITE 0
1111111111111111
"#;
        let (tail_v1, mrb_v1) = cli::compile_ruby_script_str(script_v1).unwrap();
        let mut runtime = GameRuntime::new(&tail_v1, &mrb_v1, true).unwrap();

        // 2フレーム進める: $x = 70, $t = 2
        runtime.call_update();
        runtime.call_update();

        let x_before: i32 = runtime.vm.globals.get("$x").unwrap().as_ref().try_into().unwrap();
        assert_eq!(x_before, 70);

        // スクリプト編集: $x の初期値(60)は変えず、update の移動量を +10 に変更し、新しいグローバル $score = 100 と @SPRITE 2 を追加
        let script_v2 = r#"
$x = 60
$y = 60
$t = 0
$score = 100

def update
  $x += 10
  $t += 1
end

def draw
end
__END__
@SPRITE 0
2222222222222222

@SPRITE 2
3333333333333333
"#;
        let (tail_v2, mrb_v2) = cli::compile_ruby_script_str(script_v2).unwrap();
        runtime.hot_reload(&tail_v2, &mrb_v2).expect("Hot reload should succeed");

        // $x はリセットされず 70 のまま維持されていること
        let x_after_reload: i32 = runtime.vm.globals.get("$x").unwrap().as_ref().try_into().unwrap();
        assert_eq!(x_after_reload, 70);

        // 新規追加された $score = 100 も反映されていること
        let score: i32 = runtime.vm.globals.get("$score").unwrap().as_ref().try_into().unwrap();
        assert_eq!(score, 100);

        // スプライト2が追加されていること
        assert!(runtime.sprites.borrow().contains_key(&2));

        // 新しい update メソッド (+10) が使われること
        runtime.call_update();
        let x_after_step: i32 = runtime.vm.globals.get("$x").unwrap().as_ref().try_into().unwrap();
        assert_eq!(x_after_step, 80);
    }

    #[test]
    fn test_bundle_pack_and_unpack() {
        let fake_exe = b"MZ_FAKE_EXE_HEADER_BYTES";
        let tail = "@SPRITE 0\n12345678\n";
        let mrb = vec![1u8, 2, 3, 4, 5, 6, 7, 8];

        let bundle = pack_bundle(tail, &mrb);
        let mut combined = fake_exe.to_vec();
        combined.extend_from_slice(&bundle);

        let (unpacked_tail, unpacked_mrb) =
            unpack_bundle_from_bytes(&combined).expect("Should unpack bundle from exe");
        assert_eq!(unpacked_tail, tail);
        assert_eq!(unpacked_mrb, mrb);

        let stripped = strip_bundle_from_exe_bytes(&combined);
        assert_eq!(stripped, fake_exe);
    }

    #[test]
    fn test_cli_arg_parsing() {
        let run_act = cli::parse_cli_args(["uk", "run", "game.rb"].map(String::from)).unwrap();
        assert_eq!(
            run_act,
            cli::CliAction::Run {
                script_path: std::path::PathBuf::from("game.rb")
            }
        );

        let build_act = cli::parse_cli_args(
            ["uk", "build", "game.rb", "-o", "dist/mygame.exe"].map(String::from),
        )
        .unwrap();
        assert_eq!(
            build_act,
            cli::CliAction::Build {
                script_path: std::path::PathBuf::from("game.rb"),
                output_path: Some(std::path::PathBuf::from("dist/mygame.exe")),
            }
        );

        let browser_act = cli::parse_cli_args(
            ["uk", "browser", "game.rb", "-p", "3000", "--no-open"].map(String::from),
        )
        .unwrap();
        assert_eq!(
            browser_act,
            cli::CliAction::Browser {
                script_path: std::path::PathBuf::from("game.rb"),
                port: Some(3000),
                open_browser: false,
            }
        );

        let encode_act = cli::parse_cli_args(
            ["uk", "encode", "sheet.png", "--id", "10", "--tile", "16x16"].map(String::from),
        )
        .unwrap();
        assert_eq!(
            encode_act,
            cli::CliAction::Encode {
                image_path: std::path::PathBuf::from("sheet.png"),
                start_id: 10,
                tile_size: Some((16, 16)),
            }
        );
    }

    #[test]
    fn test_png_sheet_encode_and_parse() {
        // 1x1 透明PNGを最小構成でテスト、または内蔵絵文字アトラスPNGから @SHEET ブロックを生成してパース検証
        let block = cli::encode_png_bytes_to_script_block(
            emoji::EMOJI_ATLAS_PNG,
            "emoji_atlas.png",
            100,
            Some((16, 16)),
        )
        .expect("Should encode PNG bytes into @SHEET block");
        assert!(block.contains("@SHEET 100 16x16"));

        let parsed = parse_tail_resources(&block);
        assert!(parsed.contains_key(&100));
        assert!(parsed.contains_key(&101));
        assert_eq!(parsed[&100].width, 16);
        assert_eq!(parsed[&100].height, 16);
    }

    #[test]
    fn test_misaki_japanese_font_lookup() {
        for ch in ['あ', 'い', 'ウ', 'サ', 'ギ', '兎', '亀', 'ｱ', '！'] {
            let rows = lookup_misaki_glyph(ch as u16)
                .unwrap_or_else(|| panic!("Misaki glyph should exist for '{}'", ch));
            assert!(
                rows.iter().any(|&b| b != 0),
                "Glyph '{}' should have non-zero pixel rows",
                ch
            );
        }
    }

    #[test]
    fn test_print_text_with_emoji_8x8() {
        let script = r#"
def update
end

def draw
  print_text("🐰うさぎと🐢かめ⚔️❤️⭐", 8, 8, 7)
end
"#;
        let (tail, mrb) = cli::compile_ruby_script_str(script).unwrap();
        let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();
        runtime.call_draw();

        let mut atlas = runtime.emoji_atlas.borrow_mut();
        for emoji in ["🐰", "🐢", "⚔️", "❤️", "⭐"] {
            let cp = emoji::resolve_emoji_codepoint(emoji).unwrap();
            let sp8 = atlas
                .get_or_insert_8x8_by_cp(cp, false)
                .expect("8x8 emoji should be cached");
            assert_eq!(sp8.width, 8);
            assert_eq!(sp8.height, 8);
        }
    }

    #[test]
    fn test_sprite_rotate_and_scale() {
        // 16x16 スプライトを座標 (100, 120) に描画する場合、元の中心は (108, 128)
        let (dx, dy, params) =
            compute_sprite_draw_params(16.0, 16.0, 100.0, 120.0, false, false, 90.0, 2.0)
                .expect("Should compute draw params");
        // scale = 2.0 のときサイズは 32x32、中心 (108, 128) を維持するため左上は (92, 112)
        assert!((dx - 92.0).abs() < 1e-4);
        assert!((dy - 112.0).abs() < 1e-4);
        assert_eq!(params.dest_size, Some(vec2(32.0, 32.0)));
        assert_eq!(params.pivot, Some(vec2(108.0, 128.0)));
        assert!((params.rotation - 90.0f32.to_radians()).abs() < 1e-5);
        assert!(!params.flip_x);
        assert!(!params.flip_y);

        // scale = 0.0 は描画しない
        assert!(
            compute_sprite_draw_params(16.0, 16.0, 100.0, 120.0, false, false, 0.0, 0.0).is_none()
        );

        // 負の scale は反転として扱う
        let (_, _, neg_params) =
            compute_sprite_draw_params(16.0, 16.0, 10.0, 20.0, false, true, 45.0, -1.5).unwrap();
        assert_eq!(neg_params.dest_size, Some(vec2(24.0, 24.0)));
        assert!(neg_params.flip_x);
        assert!(!neg_params.flip_y);

        // Ruby スクリプトから整数・浮動小数点両方で rotate, scale を渡せることを検証
        let script = r#"
def update
end

def draw
  spr("🐰", 40, 50, false, false, 45, 2)
  spr("🐢", 80.5, 90.2, true, false, 180.0, 1.5)
  spr(0, 120, 120, false, false, 270, 0.5)
end
__END__
@SPRITE 0
1111111111111111
"#;
        let (tail, mrb) = cli::compile_ruby_script_str(script).unwrap();
        let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();
        runtime.call_draw();
    }
}
