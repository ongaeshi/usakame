pub mod bundle;
#[cfg(not(target_arch = "wasm32"))]
pub mod cli;
pub mod emoji;
pub mod sound;

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
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

/// エンジン設定（内部仮想解像度、ウィンドウ表示倍率、スプライト・タイル倍率、テキストサイズ等）
#[derive(Debug, Clone, PartialEq)]
pub struct AppConfig {
    pub screen_width: u32,
    pub screen_height: u32,
    pub window_scale: f32,
    pub sprite_scale: f32,
    pub text_size: u32, // 0 = 自動判定 (screen_width <= 256 ? 8 : 16)
    pub title: String,
    pub show_fps: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            screen_width: SCREEN_WIDTH,
            screen_height: SCREEN_HEIGHT,
            window_scale: 2.0,
            sprite_scale: 1.0,
            text_size: 0,
            title: "Usakame Retro Engine".to_string(),
            show_fps: false,
        }
    }
}

impl AppConfig {
    pub fn resolved_text_size(&self) -> u32 {
        if self.text_size == 8 || self.text_size == 16 {
            self.text_size
        } else if self.screen_width <= 256 {
            8
        } else {
            16
        }
    }

    pub fn window_width(&self) -> i32 {
        ((self.screen_width as f32) * self.window_scale).round() as i32
    }

    pub fn window_height(&self) -> i32 {
        ((self.screen_height as f32) * self.window_scale).round() as i32
    }
}

/// スクリプトソース冒頭から `config(...)` を静的に事前解析して初期 `AppConfig` を取得する
pub fn parse_config_from_source(source: &str) -> AppConfig {
    let mut config = AppConfig::default();
    let code = match source.find("__END__") {
        Some(idx) => &source[..idx],
        None => source,
    };
    if let Some(idx) = code.find("config") {
        let rest = &code[idx + 6..];
        let content = if let Some(open) = rest.find('(') {
            if let Some(close) = rest[open..].find(')') {
                &rest[open + 1..open + close]
            } else {
                rest.lines().next().unwrap_or_default()
            }
        } else {
            rest.lines().next().unwrap_or_default()
        };
        for part in content.split(',') {
            let part = part.trim();
            if let Some(colon) = part.find(':') {
                let k = part[..colon].trim().trim_start_matches(['{', ':', ' ']);
                let v = part[colon + 1..].trim().trim_matches(['"', '\'', '}', ' ']);
                match k {
                    "width" => if let Ok(n) = v.parse::<u32>() { config.screen_width = n; },
                    "height" => if let Ok(n) = v.parse::<u32>() { config.screen_height = n; },
                    "scale" => if let Ok(n) = v.parse::<f32>() { config.window_scale = n; },
                    "sprite_scale" => if let Ok(n) = v.parse::<f32>() { config.sprite_scale = n; },
                    "text_size" => if let Ok(n) = v.parse::<u32>() { config.text_size = n; },
                    "title" => config.title = v.to_string(),
                    "show_fps" | "fps" => config.show_fps = v == "true" || v == "1",
                    _ => {}
                }
            }
        }
    }
    config
}

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

pub const DEFAULT_PAL_MAP: [u8; 16] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

fn palette_color(col: i32) -> Color {
    PALETTE[(col.rem_euclid(16)) as usize]
}

/// 指定した RGB 値に最も近い PICO-8 16色パレットのインデックス (`0..=15`) を返す
pub fn nearest_palette_index(r: u8, g: u8, b: u8) -> usize {
    for (idx, rgba) in PALETTE_RGBA.iter().enumerate() {
        if rgba[0] == r && rgba[1] == g && rgba[2] == b {
            return idx;
        }
    }
    let mut best_idx = 0usize;
    let mut best_dist = i32::MAX;
    for (idx, rgba) in PALETTE_RGBA.iter().enumerate() {
        let dr = r as i32 - rgba[0] as i32;
        let dg = g as i32 - rgba[1] as i32;
        let db = b as i32 - rgba[2] as i32;
        let dist = dr * dr + dg * dg + db * db;
        if dist < best_dist {
            best_dist = dist;
            best_idx = idx;
        }
    }
    best_idx
}

// ==========================================
// Base64 エンコード / デコード
// ==========================================
pub use bundle::{decode_base64, encode_base64};

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
    /// パレット置換・透過設定 `(pal_map, palt_mask)` ごとの変換済みテクスチャキャッシュ
    pub pal_cache: RefCell<HashMap<([u8; 16], u16), Texture2D>>,
}

impl SpriteData {
    pub fn from_rgba(width: u16, height: u16, rgba: Vec<u8>) -> Self {
        Self {
            width,
            height,
            rgba,
            texture: None,
            pal_cache: RefCell::new(HashMap::new()),
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
            pal_cache: RefCell::new(HashMap::new()),
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
        self.pal_cache.borrow_mut().clear();
    }

    /// パレット置換マップ `pal_map` と透過ビットマスク `palt_mask` を適用した RGBA ピクセル配列を生成する
    pub fn apply_palette(&self, pal_map: &[u8; 16], palt_mask: u16) -> Vec<u8> {
        if *pal_map == DEFAULT_PAL_MAP && palt_mask == 0 {
            return self.rgba.clone();
        }
        let mut out = self.rgba.clone();
        for px in out.chunks_exact_mut(4) {
            if px[3] == 0 {
                continue;
            }
            let src_idx = nearest_palette_index(px[0], px[1], px[2]);
            if (palt_mask & (1 << src_idx)) != 0 {
                px[0] = 0;
                px[1] = 0;
                px[2] = 0;
                px[3] = 0;
            } else {
                let dst_idx = (pal_map[src_idx] & 0x0F) as usize;
                if dst_idx != src_idx {
                    let dst_rgba = PALETTE_RGBA[dst_idx];
                    px[0] = dst_rgba[0];
                    px[1] = dst_rgba[1];
                    px[2] = dst_rgba[2];
                }
            }
        }
        out
    }

    /// パレット変換済みの `Texture2D` を取得またはオンデマンド生成してキャッシュから返す
    pub fn get_or_build_pal_texture(&self, pal_map: &[u8; 16], palt_mask: u16) -> Option<Texture2D> {
        if *pal_map == DEFAULT_PAL_MAP && palt_mask == 0 {
            return self.texture.clone();
        }
        let key = (*pal_map, palt_mask);
        if let Some(tex) = self.pal_cache.borrow().get(&key) {
            return Some(tex.clone());
        }
        let transformed_rgba = self.apply_palette(pal_map, palt_mask);
        let image = Image {
            bytes: transformed_rgba,
            width: self.width,
            height: self.height,
        };
        let texture = Texture2D::from_image(&image);
        texture.set_filter(FilterMode::Nearest);
        let mut cache = self.pal_cache.borrow_mut();
        if cache.len() >= 32 {
            cache.clear();
        }
        cache.insert(key, texture.clone());
        Some(texture)
    }
}

// ==========================================
// スプライトバンク管理 (256x256 シート)
// ==========================================
pub const BANK_WIDTH: usize = 256;
pub const BANK_HEIGHT: usize = 256;
pub const BANK_PIXELS: usize = BANK_WIDTH * BANK_HEIGHT;
pub const BANK_RGBA_BYTES: usize = BANK_PIXELS * 4;

pub fn rgba_to_palette_opt(rgba: &[u8]) -> Option<u8> {
    if rgba.len() < 4 || rgba[3] < 128 {
        None
    } else {
        Some(nearest_palette_index(rgba[0], rgba[1], rgba[2]) as u8)
    }
}

#[derive(Clone)]
pub struct BankData {
    pub id: i32,
    pub width: u16,
    pub height: u16,
    /// RGBA ピクセルデータ (256 * 256 * 4 bytes)
    pub rgba: Vec<u8>,
    /// パレットインデックスデータ (256 * 256 elements, 0..15 or None)
    pub indexed: Vec<Option<u8>>,
    pub texture: RefCell<Option<Texture2D>>,
    pub dirty: std::cell::Cell<bool>,
    /// パレット置換・透過設定ごとの変換済みテクスチャキャッシュ
    pub pal_cache: RefCell<HashMap<([u8; 16], u16), Texture2D>>,
}

impl Default for BankData {
    fn default() -> Self {
        Self::new(0)
    }
}

impl BankData {
    pub fn new(id: i32) -> Self {
        Self {
            id,
            width: BANK_WIDTH as u16,
            height: BANK_HEIGHT as u16,
            rgba: vec![0u8; BANK_RGBA_BYTES],
            indexed: vec![None; BANK_PIXELS],
            texture: RefCell::new(None),
            dirty: std::cell::Cell::new(false),
            pal_cache: RefCell::new(HashMap::new()),
        }
    }

    pub fn from_image(id: i32, img: &Image) -> Self {
        let mut bank = Self::new(id);
        let copy_w = (img.width as usize).min(BANK_WIDTH);
        let copy_h = (img.height as usize).min(BANK_HEIGHT);
        for y in 0..copy_h {
            let src_start = (y * img.width as usize) * 4;
            let src_end = src_start + copy_w * 4;
            let dst_start = (y * BANK_WIDTH) * 4;
            let dst_end = dst_start + copy_w * 4;
            if src_end <= img.bytes.len() && dst_end <= bank.rgba.len() {
                bank.rgba[dst_start..dst_end].copy_from_slice(&img.bytes[src_start..src_end]);
            }
            for x in 0..copy_w {
                let p_off = (y * img.width as usize + x) * 4;
                if p_off + 4 <= img.bytes.len() {
                    let col = rgba_to_palette_opt(&img.bytes[p_off..p_off + 4]);
                    bank.indexed[y * BANK_WIDTH + x] = col;
                }
            }
        }
        bank
    }

    pub fn from_png_bytes(id: i32, bytes: &[u8]) -> Result<Self, String> {
        let img = Image::from_file_with_format(bytes, Some(ImageFormat::Png))
            .map_err(|e| format!("Failed to decode PNG for bank {}: {:?}", id, e))?;
        Ok(Self::from_image(id, &img))
    }

    pub fn from_base64_png(id: i32, b64_text: &str) -> Result<Self, String> {
        let bytes = decode_base64(b64_text)?;
        Self::from_png_bytes(id, &bytes)
    }

    pub fn from_file_or_base64(id: i32, text_or_path: &str, base_dir: Option<&Path>) -> Result<Self, String> {
        let trimmed = text_or_path.trim();
        let path_candidate = if let Some(dir) = base_dir {
            dir.join(trimmed)
        } else {
            PathBuf::from(trimmed)
        };
        if path_candidate.is_file() {
            let bytes = std::fs::read(&path_candidate)
                .map_err(|e| format!("Failed to read PNG file {}: {}", path_candidate.display(), e))?;
            return Self::from_png_bytes(id, &bytes);
        }
        Self::from_base64_png(id, trimmed)
    }

    pub fn write_16x16(&mut self, slot_id: usize, src_rgba: &[u8]) {
        let slot_x = (slot_id % 16) * 16;
        let slot_y = (slot_id / 16) * 16;
        if slot_y + 16 > BANK_HEIGHT {
            return;
        }
        for y in 0..16 {
            let src_start = y * 16 * 4;
            let src_end = src_start + 16 * 4;
            let dst_start = ((slot_y + y) * BANK_WIDTH + slot_x) * 4;
            let dst_end = dst_start + 16 * 4;
            if src_end <= src_rgba.len() && dst_end <= self.rgba.len() {
                self.rgba[dst_start..dst_end].copy_from_slice(&src_rgba[src_start..src_end]);
            }
            for x in 0..16 {
                let p_off = src_start + x * 4;
                if p_off + 4 <= src_rgba.len() {
                    let col = rgba_to_palette_opt(&src_rgba[p_off..p_off + 4]);
                    self.indexed[(slot_y + y) * BANK_WIDTH + slot_x + x] = col;
                }
            }
        }
        self.dirty.set(true);
        self.pal_cache.borrow_mut().clear();
    }

    pub fn clear_16x16(&mut self, slot_id: usize) {
        let slot_x = (slot_id % 16) * 16;
        let slot_y = (slot_id / 16) * 16;
        if slot_y + 16 > BANK_HEIGHT {
            return;
        }
        for y in 0..16 {
            for x in 0..16 {
                let off = ((slot_y + y) * BANK_WIDTH + slot_x + x) * 4;
                self.rgba[off..off + 4].copy_from_slice(&[0, 0, 0, 0]);
                self.indexed[(slot_y + y) * BANK_WIDTH + slot_x + x] = None;
            }
        }
        self.dirty.set(true);
        self.pal_cache.borrow_mut().clear();
    }

    pub fn update_pixels(&mut self, pixels: &[Option<u8>]) {
        for (i, opt_c) in pixels.iter().take(BANK_PIXELS).enumerate() {
            self.indexed[i] = *opt_c;
            let off = i * 4;
            if off + 4 <= self.rgba.len() {
                if let Some(c) = opt_c {
                    let idx = (*c as usize).min(15);
                    self.rgba[off..off + 4].copy_from_slice(&PALETTE_RGBA[idx]);
                } else {
                    self.rgba[off..off + 4].copy_from_slice(&[0, 0, 0, 0]);
                }
            }
        }
        self.dirty.set(true);
        self.pal_cache.borrow_mut().clear();
    }

    pub fn set_pixel(&mut self, x: usize, y: usize, col: Option<u8>) {
        if x >= BANK_WIDTH || y >= BANK_HEIGHT {
            return;
        }
        let idx = y * BANK_WIDTH + x;
        self.indexed[idx] = col;
        let off = idx * 4;
        if off + 4 <= self.rgba.len() {
            if let Some(c) = col {
                let idx = (c as usize).min(15);
                self.rgba[off..off + 4].copy_from_slice(&PALETTE_RGBA[idx]);
            } else {
                self.rgba[off..off + 4].copy_from_slice(&[0, 0, 0, 0]);
            }
        }
        self.dirty.set(true);
        self.pal_cache.borrow_mut().clear();
    }

    pub fn update_rect(&mut self, x: usize, y: usize, w: usize, h: usize, pixels: &[Option<u8>]) {
        for row in 0..h {
            let gy = y + row;
            if gy >= BANK_HEIGHT {
                break;
            }
            for col in 0..w {
                let gx = x + col;
                if gx >= BANK_WIDTH {
                    break;
                }
                let src_idx = row * w + col;
                if src_idx < pixels.len() {
                    let opt_c = pixels[src_idx];
                    let idx = gy * BANK_WIDTH + gx;
                    self.indexed[idx] = opt_c;
                    let dst_off = idx * 4;
                    if dst_off + 4 <= self.rgba.len() {
                        if let Some(c) = opt_c {
                            let idx = (c as usize).min(15);
                            self.rgba[dst_off..dst_off + 4].copy_from_slice(&PALETTE_RGBA[idx]);
                        } else {
                            self.rgba[dst_off..dst_off + 4].copy_from_slice(&[0, 0, 0, 0]);
                        }
                    }
                }
            }
        }
        self.dirty.set(true);
        self.pal_cache.borrow_mut().clear();
    }

    pub fn get_pixel(&self, x: usize, y: usize) -> Option<u8> {
        if x < BANK_WIDTH && y < BANK_HEIGHT {
            self.indexed[y * BANK_WIDTH + x]
        } else {
            None
        }
    }

    pub fn get_rect(&self, x: usize, y: usize, w: usize, h: usize) -> Vec<Option<u8>> {
        let mut result = vec![None; w * h];
        for row in 0..h {
            let gy = y + row;
            if gy >= BANK_HEIGHT {
                break;
            }
            if x < BANK_WIDTH {
                let copy_len = w.min(BANK_WIDTH - x);
                let src_start = gy * BANK_WIDTH + x;
                let dst_start = row * w;
                result[dst_start..dst_start + copy_len]
                    .copy_from_slice(&self.indexed[src_start..src_start + copy_len]);
            }
        }
        result
    }

    pub fn get_pixels(&self) -> Vec<Option<u8>> {
        self.indexed.clone()
    }

    pub fn ensure_texture(&self) {
        #[cfg(test)]
        {
            return;
        }
        #[cfg(not(test))]
        {
            if !self.dirty.get() && self.texture.borrow().is_some() {
                return;
            }
            let image = Image {
                bytes: self.rgba.clone(),
                width: self.width,
                height: self.height,
            };
            let mut tex_ref = self.texture.borrow_mut();
            if let Some(ref tex) = *tex_ref {
                tex.update(&image);
            } else {
                let tex = Texture2D::from_image(&image);
                tex.set_filter(FilterMode::Nearest);
                *tex_ref = Some(tex);
            }
            self.dirty.set(false);
            self.pal_cache.borrow_mut().clear();
        }
    }

    pub fn build_texture(&self) {
        self.dirty.set(true);
        self.ensure_texture();
    }

    pub fn apply_palette(&self, pal_map: &[u8; 16], palt_mask: u16) -> Vec<u8> {
        if *pal_map == DEFAULT_PAL_MAP && palt_mask == 0 {
            return self.rgba.clone();
        }
        let mut out = self.rgba.clone();
        for px in out.chunks_exact_mut(4) {
            if px[3] == 0 {
                continue;
            }
            let src_idx = nearest_palette_index(px[0], px[1], px[2]);
            if (palt_mask & (1 << src_idx)) != 0 {
                px[0] = 0;
                px[1] = 0;
                px[2] = 0;
                px[3] = 0;
            } else {
                let dst_idx = (pal_map[src_idx] & 0x0F) as usize;
                if dst_idx != src_idx {
                    let dst_rgba = PALETTE_RGBA[dst_idx];
                    px[0] = dst_rgba[0];
                    px[1] = dst_rgba[1];
                    px[2] = dst_rgba[2];
                }
            }
        }
        out
    }

    pub fn get_or_build_pal_texture(&self, pal_map: &[u8; 16], palt_mask: u16) -> Option<Texture2D> {
        self.ensure_texture();
        if *pal_map == DEFAULT_PAL_MAP && palt_mask == 0 {
            return self.texture.borrow().clone();
        }
        let key = (*pal_map, palt_mask);
        if let Some(tex) = self.pal_cache.borrow().get(&key) {
            return Some(tex.clone());
        }
        let transformed_rgba = self.apply_palette(pal_map, palt_mask);
        let image = Image {
            bytes: transformed_rgba,
            width: self.width,
            height: self.height,
        };
        let texture = Texture2D::from_image(&image);
        texture.set_filter(FilterMode::Nearest);
        let mut cache = self.pal_cache.borrow_mut();
        if cache.len() >= 32 {
            cache.clear();
        }
        cache.insert(key, texture.clone());
        Some(texture)
    }

    pub fn to_png_bytes(&self) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut out, self.width as u32, self.height as u32);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            encoder.set_compression(png::Compression::Fast);
            let mut writer = encoder
                .write_header()
                .map_err(|e| format!("PNG write_header error: {:?}", e))?;
            writer
                .write_image_data(&self.rgba)
                .map_err(|e| format!("PNG write_image_data error: {:?}", e))?;
        }
        Ok(out)
    }

    pub fn to_base64_png(&self) -> Result<String, String> {
        let bytes = self.to_png_bytes()?;
        Ok(encode_base64(&bytes))
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
    Bank(i32),
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
    banks: &mut HashMap<i32, BankData>,
    base_dir: Option<&Path>,
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
            let sp = SpriteData::from_lines(&refs);
            if (0..=255).contains(&id) {
                let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                bank0.write_16x16(id as usize, &sp.rgba);
            }
            sprites.insert(id, sp);
        }
        ResourceBlockKind::Base64Sprite(id) => {
            let joined = lines.join("");
            match SpriteData::from_base64(&joined) {
                Ok(sp) => {
                    if (0..=255).contains(&id) {
                        let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                        bank0.write_16x16(id as usize, &sp.rgba);
                    }
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
            } else {
                let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                for (id, sp) in sprites.iter() {
                    if (0..=255).contains(id) && *id >= start_id {
                        bank0.write_16x16(*id as usize, &sp.rgba);
                    }
                }
            }
        }
        ResourceBlockKind::Bank(id) => {
            let joined = lines.join("\n");
            match BankData::from_file_or_base64(id, &joined, base_dir) {
                Ok(bank) => {
                    banks.insert(id, bank);
                }
                Err(e) => {
                    eprintln!("Warning: Failed to load @BANK {}: {}", id, e);
                }
            }
        }
    }
    lines.clear();
}

/// `__END__` 以降のスプライトおよびバンク定義をパースする
pub fn parse_tail_resources_full(
    data_section: &str,
    base_dir: Option<&Path>,
) -> (HashMap<i32, SpriteData>, HashMap<i32, BankData>) {
    let mut sprites = HashMap::new();
    let mut banks = HashMap::new();
    banks.insert(0, BankData::new(0));

    let mut current_kind: Option<ResourceBlockKind> = None;
    let mut current_lines: Vec<String> = Vec::new();
    let mut emoji_atlas: Option<emoji::EmojiAtlas> = None;

    for raw_line in data_section.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some(rest) = line.strip_prefix("@BANK") {
            flush_resource_block(current_kind.take(), &mut current_lines, &mut sprites, &mut banks, base_dir);
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(id) = id_str.parse::<i32>()
            {
                let inline_content: String = parts.collect::<Vec<_>>().join(" ");
                if !inline_content.is_empty() {
                    match BankData::from_file_or_base64(id, &inline_content, base_dir) {
                        Ok(bank) => {
                            banks.insert(id, bank);
                        }
                        Err(e) => {
                            eprintln!("Warning: Failed to load inline @BANK {}: {}", id, e);
                        }
                    }
                } else {
                    current_kind = Some(ResourceBlockKind::Bank(id));
                }
            }
        } else if let Some(rest) = line
            .strip_prefix("@SPRITE_B64")
            .or_else(|| line.strip_prefix("@PNG"))
            .or_else(|| line.strip_prefix("@B64"))
        {
            flush_resource_block(current_kind.take(), &mut current_lines, &mut sprites, &mut banks, base_dir);
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(id) = id_str.parse::<i32>()
            {
                let inline_b64: String = parts.collect::<Vec<_>>().join("");
                if !inline_b64.is_empty() {
                    if let Ok(sp) = SpriteData::from_base64(&inline_b64) {
                        if (0..=255).contains(&id) {
                            let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                            bank0.write_16x16(id as usize, &sp.rgba);
                        }
                        sprites.insert(id, sp);
                    }
                } else {
                    current_kind = Some(ResourceBlockKind::Base64Sprite(id));
                }
            }
        } else if let Some(rest) = line.strip_prefix("@SHEET") {
            flush_resource_block(current_kind.take(), &mut current_lines, &mut sprites, &mut banks, base_dir);
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
            flush_resource_block(current_kind.take(), &mut current_lines, &mut sprites, &mut banks, base_dir);
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(id) = id_str.parse::<i32>()
            {
                if let Some(emoji_token) = parts.next() {
                    // 数値トークン（例: @SPRITE 1 16 16）は寸法指定であり絵文字ではないため TextSprite として扱う
                    if emoji_token.chars().all(|c| c.is_ascii_digit()) {
                        current_kind = Some(ResourceBlockKind::TextSprite(id));
                    } else {
                        let atlas = emoji_atlas.get_or_insert_with(emoji::EmojiAtlas::new);
                        if let Some(sp) = atlas.extract_sprite(emoji_token) {
                            if (0..=255).contains(&id) {
                                let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                                bank0.write_16x16(id as usize, &sp.rgba);
                            }
                            sprites.insert(id, sp);
                        } else {
                            current_kind = Some(ResourceBlockKind::TextSprite(id));
                        }
                    }
                } else {
                    current_kind = Some(ResourceBlockKind::TextSprite(id));
                }
            }
        } else if line.starts_with('@') {
            flush_resource_block(current_kind.take(), &mut current_lines, &mut sprites, &mut banks, base_dir);
        } else if current_kind.is_some() {
            current_lines.push(line.to_string());
        }
    }

    flush_resource_block(current_kind.take(), &mut current_lines, &mut sprites, &mut banks, base_dir);
    (sprites, banks)
}

/// `__END__` 以降のスプライト定義をパースする（後方互換ラッパー）
pub fn parse_tail_resources(data_section: &str) -> HashMap<i32, SpriteData> {
    parse_tail_resources_full(data_section, None).0
}

/// タイルマップ管理構造体（1セル = 16x16 スプライト番号、`0` は空タイル）
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Tilemap {
    pub cells: HashMap<(i32, i32), i32>,
    pub width: i32,
    pub height: i32,
}

fn parse_map_tile_token(tok: &str) -> i32 {
    if matches!(tok, "." | ".." | "_" | "-") {
        return 0;
    }
    if let Some(hex) = tok.strip_prefix("0x").or_else(|| tok.strip_prefix("0X")) {
        return i32::from_str_radix(hex, 16).unwrap_or(0);
    }
    if let Ok(v) = tok.parse::<i32>() {
        return v;
    }
    i32::from_str_radix(tok, 16).unwrap_or(0)
}

impl Tilemap {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, x: i32, y: i32) -> i32 {
        self.cells.get(&(x, y)).copied().unwrap_or(0)
    }

    pub fn set(&mut self, x: i32, y: i32, val: i32) {
        if val == 0 {
            self.cells.remove(&(x, y));
        } else {
            self.cells.insert((x, y), val);
        }
        if x >= 0 && x + 1 > self.width {
            self.width = x + 1;
        }
        if y >= 0 && y + 1 > self.height {
            self.height = y + 1;
        }
    }

    /// 1行分のテキスト（空白・カンマ区切りトークン、または1文字1タイルの16進文字列 `0`..`F`/`.`）を行 `y` に反映する
    pub fn parse_row_line(&mut self, start_x: i32, y: i32, line: &str) {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            return;
        }
        if trimmed.contains(|c: char| c.is_ascii_whitespace() || c == ',') {
            let mut x = start_x;
            for token in trimmed.split(|c: char| c.is_ascii_whitespace() || c == ',') {
                let tok = token.trim();
                if tok.is_empty() {
                    continue;
                }
                self.set(x, y, parse_map_tile_token(tok));
                x += 1;
            }
        } else {
            for (dx, ch) in trimmed.chars().enumerate() {
                let val = match ch {
                    '.' | '_' | '-' => 0,
                    c if c.is_ascii_hexdigit() => c.to_digit(16).unwrap_or(0) as i32,
                    _ => 0,
                };
                self.set(start_x + dx as i32, y, val);
            }
        }
    }
}

/// `__END__` 以降の `@MAP [offset_x] [offset_y]` セクションをパースして `Tilemap` を生成する
pub fn parse_tail_map(data_section: &str) -> Tilemap {
    let mut tilemap = Tilemap::new();
    let mut in_map = false;
    let mut offset_x = 0i32;
    let mut cur_y = 0i32;

    for raw_line in data_section.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some(rest) = line.strip_prefix("@MAP")
            && (rest.is_empty() || rest.starts_with(char::is_whitespace))
        {
            in_map = true;
            let mut parts = rest.split_whitespace();
            offset_x = parts
                .next()
                .and_then(|s| s.parse::<i32>().ok())
                .unwrap_or(0);
            cur_y = parts
                .next()
                .and_then(|s| s.parse::<i32>().ok())
                .unwrap_or(0);
        } else if line.starts_with('@') {
            in_map = false;
        } else if in_map {
            tilemap.parse_row_line(offset_x, cur_y, line);
            cur_y += 1;
        }
    }

    tilemap
}

/// Rubyグローバル変数 `$MAP`（文字列配列または2次元整数配列）から `Tilemap` に反映する
pub fn parse_ruby_map_global(vm: &VM, tilemap: &mut Tilemap) {
    let Some(map_obj) = vm.globals.get("$MAP") else {
        return;
    };
    let RValue::Array(ref rows_cell) = map_obj.value else {
        return;
    };

    for (y, row_item) in rows_cell.borrow().iter().enumerate() {
        match &row_item.value {
            RValue::String(_, _) => {
                if let Ok(line) = String::try_from(row_item.as_ref()) {
                    tilemap.parse_row_line(0, y as i32, &line);
                }
            }
            RValue::Array(cols_cell) => {
                for (x, cell_item) in cols_cell.borrow().iter().enumerate() {
                    let val = match cell_item.value {
                        RValue::Integer(v) => v as i32,
                        RValue::Float(v) => v as i32,
                        _ => 0,
                    };
                    tilemap.set(x as i32, y as i32, val);
                }
            }
            _ => {}
        }
    }
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
const SHINONOME_FONT_BIN: &[u8] = include_bytes!("../assets/shinonome_font.bin");

#[derive(Debug, Clone, Copy)]
pub struct ShinonomeGlyph {
    pub width: u8,
    pub bitmap: [u8; 32],
}

/// 東雲ゴシック（16x16 / 8x16 1-bit, Public Domain）のバイナリテーブルから指定Unicodeコードポイントのグリフを取得する
pub fn lookup_shinonome_glyph(cp: u16) -> Option<ShinonomeGlyph> {
    if SHINONOME_FONT_BIN.len() < 8 {
        return None;
    }
    let count = u16::from_le_bytes([SHINONOME_FONT_BIN[6], SHINONOME_FONT_BIN[7]]) as usize;
    let mut low = 0usize;
    let mut high = count;
    while low < high {
        let mid = (low + high) / 2;
        let off = 8 + mid * 35;
        let mid_cp = u16::from_le_bytes([SHINONOME_FONT_BIN[off], SHINONOME_FONT_BIN[off + 1]]);
        match mid_cp.cmp(&cp) {
            std::cmp::Ordering::Equal => {
                let width = SHINONOME_FONT_BIN[off + 2];
                let mut bitmap = [0u8; 32];
                bitmap.copy_from_slice(&SHINONOME_FONT_BIN[off + 3..off + 35]);
                return Some(ShinonomeGlyph { width, bitmap });
            }
            std::cmp::Ordering::Less => low = mid + 1,
            std::cmp::Ordering::Greater => high = mid,
        }
    }
    None
}

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
    ja16_cache: RefCell<HashMap<u16, (u8, Texture2D)>>,
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
                ja16_cache: RefCell::new(HashMap::new()),
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
            ja16_cache: RefCell::new(HashMap::new()),
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
        self.draw_text_crisp_ex(text, x, y, color, emoji_atlas, 8);
    }

    pub fn draw_text_crisp_ex(
        &self,
        text: &str,
        x: f32,
        y: f32,
        color: Color,
        emoji_atlas: &RefCell<emoji::EmojiAtlas>,
        font_size: u32,
    ) {
        let Some(ref texture) = self.texture else {
            return;
        };

        if font_size == 16 {
            let mut cur_x = x.floor();
            let mut cur_y = y.floor();
            let start_x = cur_x;

            let mut chars = text.chars().peekable();
            while let Some(ch) = chars.next() {
                if ch == '\n' {
                    cur_x = start_x;
                    cur_y += 16.0;
                    continue;
                }
                let code = ch as u32;
                if code == 0xFE0E
                    || code == 0xFE0F
                    || code == 0x200D
                    || (0x1F3FB..=0x1F3FF).contains(&code)
                {
                    continue;
                }
                let next_vs = match chars.peek().copied() {
                    Some('\u{FE0F}') | Some('\u{FE0E}') => chars.next(),
                    _ => None,
                };

                let prefer_emoji = next_vs != Some('\u{FE0E}')
                    && emoji::is_emoji_codepoint(code)
                    && (code > 0xFFFF
                        || next_vs == Some('\u{FE0F}')
                        || code >= 0x2300
                        || (code <= 0xFFFF && lookup_shinonome_glyph(code as u16).is_none()));

                if prefer_emoji {
                    let mut atlas_ref = emoji_atlas.borrow_mut();
                    if let Some(sprite) = atlas_ref.get_or_insert_16x16_by_cp(code, true)
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
                    cur_x += 16.0;
                    continue;
                }

                if code <= 0xFFFF {
                    let cp = code as u16;
                    if cp == 0x3000 {
                        cur_x += 16.0;
                        continue;
                    }
                    if cp == 0x20 {
                        cur_x += 8.0;
                        continue;
                    }

                    if !self.ja16_cache.borrow().contains_key(&cp) {
                        if let Some(glyph) = lookup_shinonome_glyph(cp) {
                            let w = glyph.width as u16;
                            let mut rgba = vec![0u8; (w as usize) * 16 * 4];
                            for gy in 0..16 {
                                let row_bits = if w == 16 {
                                    ((glyph.bitmap[gy * 2] as u16) << 8)
                                        | (glyph.bitmap[gy * 2 + 1] as u16)
                                } else {
                                    (glyph.bitmap[gy] as u16) << 8
                                };
                                for gx in 0..(w as usize) {
                                    if ((row_bits >> (15 - gx)) & 1) != 0 {
                                        let off = (gy * (w as usize) + gx) * 4;
                                        rgba[off] = 255;
                                        rgba[off + 1] = 255;
                                        rgba[off + 2] = 255;
                                        rgba[off + 3] = 255;
                                    }
                                }
                            }
                            let image = Image {
                                bytes: rgba,
                                width: w,
                                height: 16,
                            };
                            let tex = Texture2D::from_image(&image);
                            tex.set_filter(FilterMode::Nearest);
                            self.ja16_cache.borrow_mut().insert(cp, (glyph.width, tex));
                        }
                    }

                    if let Some((w, tex)) = self.ja16_cache.borrow().get(&cp) {
                        draw_texture_ex(tex, cur_x, cur_y, color, DrawTextureParams::default());
                        cur_x += *w as f32;
                    } else if let Some(tex) = self.ja_cache.borrow().get(&cp) {
                        draw_texture_ex(tex, cur_x, cur_y, color, DrawTextureParams::default());
                        cur_x += 8.0;
                    } else {
                        cur_x += 16.0;
                    }
                } else {
                    cur_x += 16.0;
                }
            }
            return;
        }

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

fn robject_to_u32(obj: &Rc<RObject>) -> Option<u32> {
    match &obj.value {
        RValue::Integer(i) => Some(*i as u32),
        RValue::Float(f) => Some(*f as u32),
        _ => None,
    }
}

fn robject_to_f32(obj: &Rc<RObject>) -> Option<f32> {
    match &obj.value {
        RValue::Integer(i) => Some(*i as f32),
        RValue::Float(f) => Some(*f as f32),
        _ => None,
    }
}

fn robject_to_bool(obj: &Rc<RObject>) -> Option<bool> {
    if let Ok(b) = bool::try_from(obj.as_ref()) {
        Some(b)
    } else {
        match &obj.value {
            RValue::Integer(i) => Some(*i != 0),
            _ => None,
        }
    }
}

fn parse_text_size_arg(args: &[Rc<RObject>], default_size: u32) -> u32 {
    if let Some(arg) = args.get(4) {
        if let Some(n) = robject_to_u32(arg) {
            return if n == 16 { 16 } else { 8 };
        }
        if let RValue::Hash(ref hash_cell) = arg.value {
            let hash = hash_cell.borrow();
            for (_k_obj, (k, v)) in hash.iter() {
                let key_str = match &k.value {
                    RValue::Symbol(s) => s.name.clone(),
                    RValue::String(s, _) => String::from_utf8_lossy(&s.borrow()).to_string(),
                    _ => continue,
                };
                if key_str == "size" {
                    if let Some(n) = robject_to_u32(v) {
                        return if n == 16 { 16 } else { 8 };
                    }
                }
            }
        }
    }
    default_size
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ButtonId {
    Left,
    Right,
    Up,
    Down,
    A,
    B,
    MouseLeft,
    MouseRight,
    MouseMiddle,
}

pub fn parse_button_name(name: &str) -> Option<ButtonId> {
    match name.to_lowercase().as_str() {
        "left" | "l" => Some(ButtonId::Left),
        "right" | "r" => Some(ButtonId::Right),
        "up" | "u" => Some(ButtonId::Up),
        "down" | "d" => Some(ButtonId::Down),
        "z" | "space" | "a" | "btn_a" => Some(ButtonId::A),
        "x" | "enter" | "b" | "btn_b" => Some(ButtonId::B),
        "mouse_l" | "mouse_left" | "mouse_1" | "click" | "lclick" => Some(ButtonId::MouseLeft),
        "mouse_r" | "mouse_right" | "mouse_2" | "rclick" => Some(ButtonId::MouseRight),
        "mouse_m" | "mouse_middle" | "mouse_3" | "mclick" => Some(ButtonId::MouseMiddle),
        _ => None,
    }
}

pub fn parse_button_arg(args: &[Rc<RObject>], index: usize) -> Option<ButtonId> {
    let obj = args.get(index)?;
    match &obj.value {
        RValue::Integer(i) => match *i {
            0 => Some(ButtonId::Left),
            1 => Some(ButtonId::Right),
            2 => Some(ButtonId::Up),
            3 => Some(ButtonId::Down),
            4 => Some(ButtonId::A),
            5 => Some(ButtonId::B),
            6 => Some(ButtonId::MouseLeft),
            7 => Some(ButtonId::MouseRight),
            8 => Some(ButtonId::MouseMiddle),
            _ => None,
        },
        RValue::Symbol(sym) => parse_button_name(&sym.name),
        RValue::String(_, _) => {
            let s = String::try_from(obj.as_ref()).ok()?;
            parse_button_name(&s)
        }
        _ => None,
    }
}

pub fn is_button_down(btn: ButtonId) -> bool {
    match btn {
        ButtonId::Left => is_key_down(KeyCode::Left) || is_key_down(KeyCode::A),
        ButtonId::Right => is_key_down(KeyCode::Right) || is_key_down(KeyCode::D),
        ButtonId::Up => is_key_down(KeyCode::Up) || is_key_down(KeyCode::W),
        ButtonId::Down => is_key_down(KeyCode::Down) || is_key_down(KeyCode::S),
        ButtonId::A => is_key_down(KeyCode::Z) || is_key_down(KeyCode::Space),
        ButtonId::B => is_key_down(KeyCode::X) || is_key_down(KeyCode::Enter),
        ButtonId::MouseLeft => is_mouse_button_down(MouseButton::Left),
        ButtonId::MouseRight => is_mouse_button_down(MouseButton::Right),
        ButtonId::MouseMiddle => is_mouse_button_down(MouseButton::Middle),
    }
}

pub fn is_button_pressed(btn: ButtonId) -> bool {
    match btn {
        ButtonId::Left => is_key_pressed(KeyCode::Left) || is_key_pressed(KeyCode::A),
        ButtonId::Right => is_key_pressed(KeyCode::Right) || is_key_pressed(KeyCode::D),
        ButtonId::Up => is_key_pressed(KeyCode::Up) || is_key_pressed(KeyCode::W),
        ButtonId::Down => is_key_pressed(KeyCode::Down) || is_key_pressed(KeyCode::S),
        ButtonId::A => is_key_pressed(KeyCode::Z) || is_key_pressed(KeyCode::Space),
        ButtonId::B => is_key_pressed(KeyCode::X) || is_key_pressed(KeyCode::Enter),
        ButtonId::MouseLeft => is_mouse_button_pressed(MouseButton::Left),
        ButtonId::MouseRight => is_mouse_button_pressed(MouseButton::Right),
        ButtonId::MouseMiddle => is_mouse_button_pressed(MouseButton::Middle),
    }
}

/// OS ウィンドウ上のスクリーン座標 (mx, my) を、
/// レターボックス比率（アスペクト比維持）に基づき 仮想画面 (virt_w x virt_h) の座標 (vx, vy) に変換する
pub fn screen_to_virtual(
    mx: f32,
    my: f32,
    win_w: f32,
    win_h: f32,
    virt_w: f32,
    virt_h: f32,
) -> (i32, i32) {
    let scale = (win_w / virt_w).min(win_h / virt_h);
    if scale <= 0.0 {
        return (0, 0);
    }
    let draw_w = virt_w * scale;
    let draw_h = virt_h * scale;
    let offset_x = ((win_w - draw_w) * 0.5).floor();
    let offset_y = ((win_h - draw_h) * 0.5).floor();

    let vx = ((mx - offset_x) / scale).floor() as i32;
    let vy = ((my - offset_y) / scale).floor() as i32;
    (vx, vy)
}

pub fn virtual_mouse_position() -> (i32, i32) {
    virtual_mouse_position_ex(SCREEN_WIDTH as f32, SCREEN_HEIGHT as f32)
}

pub fn virtual_mouse_position_ex(virt_w: f32, virt_h: f32) -> (i32, i32) {
    let (mx, my) = mouse_position();
    screen_to_virtual(
        mx,
        my,
        screen_width(),
        screen_height(),
        virt_w,
        virt_h,
    )
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
    state: &DrawState,
    x: f32,
    y: f32,
    flip_x: bool,
    flip_y: bool,
    rotate_deg: f32,
    scale: f32,
) {
    let Some((draw_x, draw_y, params)) = compute_sprite_draw_params(
        sprite.width as f32,
        sprite.height as f32,
        x,
        y,
        flip_x,
        flip_y,
        rotate_deg,
        scale,
    ) else {
        return;
    };
    if state.is_default_palette() {
        if let Some(ref texture) = sprite.texture {
            draw_texture_ex(texture, draw_x, draw_y, WHITE, params);
        }
    } else if let Some(texture) = sprite.get_or_build_pal_texture(&state.pal_map, state.palt_mask) {
        draw_texture_ex(&texture, draw_x, draw_y, WHITE, params);
    }
}

fn draw_bank_rect(
    bank: &BankData,
    state: &DrawState,
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    w: f32,
    h: f32,
    flip_x: bool,
    flip_y: bool,
    rotate_deg: f32,
    scale: f32,
) {
    if !scale.is_finite() || scale.abs() < f32::EPSILON || w <= 0.0 || h <= 0.0 {
        return;
    }
    let (s, fx, fy) = if scale < 0.0 {
        (-scale, !flip_x, !flip_y)
    } else {
        (scale, flip_x, flip_y)
    };

    let (draw_x, draw_y, params) = if rotate_deg.abs() < f32::EPSILON {
        // 回転なし: (x, y) を左上座標としてスケール (Pyxel blt 準拠)
        let scaled_w = w * s;
        let scaled_h = h * s;
        let dx = x.floor();
        let dy = y.floor();
        let p = DrawTextureParams {
            dest_size: Some(vec2(scaled_w, scaled_h)),
            source: Some(Rect { x: u, y: v, w, h }),
            rotation: 0.0,
            flip_x: fx,
            flip_y: fy,
            pivot: None,
        };
        (dx, dy, p)
    } else {
        // 回転あり: 中心ピボット回転
        let Some((dx, dy, mut p)) = compute_sprite_draw_params(
            w,
            h,
            x,
            y,
            flip_x,
            flip_y,
            rotate_deg,
            scale,
        ) else {
            return;
        };
        p.source = Some(Rect { x: u, y: v, w, h });
        (dx, dy, p)
    };

    bank.ensure_texture();

    if state.is_default_palette() {
        if let Some(ref texture) = *bank.texture.borrow() {
            draw_texture_ex(texture, draw_x, draw_y, WHITE, params);
        }
    } else if let Some(texture) = bank.get_or_build_pal_texture(&state.pal_map, state.palt_mask) {
        draw_texture_ex(&texture, draw_x, draw_y, WHITE, params);
    }
}

/// メモリ上のピクセル配列（0..15 の整数または nil、16x16 スプライト）をダイレクト描画
fn draw_pixel_data_direct(
    data: &[Rc<RObject>],
    state: &DrawState,
    x: f32,
    y: f32,
    flip_x: bool,
    flip_y: bool,
    scale: f32,
) {
    if data.is_empty() || scale <= 0.0 {
        return;
    }
    let size = 16;
    for py in 0..size {
        let src_y = if flip_y { size - 1 - py } else { py };
        let mut px = 0;
        while px < size {
            let src_x = if flip_x { size - 1 - px } else { px };
            let idx = src_y * size + src_x;
            if idx >= data.len() {
                px += 1;
                continue;
            }
            let col_val = match &data[idx].value {
                RValue::Integer(c) if (0..=15).contains(c) => Some(*c as i32),
                _ => None,
            };

            let Some(col) = col_val else {
                px += 1;
                continue;
            };

            // 透過色判定 (palt)
            if (state.palt_mask & (1 << col)) != 0 {
                px += 1;
                continue;
            }

            // 水平方向に同じ色が連続しているかスキャン（スパン結合）
            let start_px = px;
            px += 1;
            while px < size {
                let next_src_x = if flip_x { size - 1 - px } else { px };
                let next_idx = src_y * size + next_src_x;
                if next_idx >= data.len() {
                    break;
                }
                let next_col = match &data[next_idx].value {
                    RValue::Integer(c) if (0..=15).contains(c) => Some(*c as i32),
                    _ => None,
                };
                if next_col != Some(col) {
                    break;
                }
                px += 1;
            }
            let span_len = (px - start_px) as f32;
            let draw_x = x + start_px as f32 * scale;
            let draw_y = y + py as f32 * scale;
            let draw_w = span_len * scale;
            let draw_h = scale;

            let final_color = state.map_color(col);
            draw_rectangle(draw_x, draw_y, draw_w, draw_h, final_color);
        }
    }
}

/// 整数ピクセル座標系での矩形スパン (`w >= 1, h >= 1`)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PixelSpan {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl PixelSpan {
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Self {
        Self { x, y, w, h }
    }

    pub fn contains(&self, px: i32, py: i32) -> bool {
        px >= self.x && px < self.x + self.w && py >= self.y && py < self.y + self.h
    }

    pub fn pixel_count(&self) -> usize {
        if self.w > 0 && self.h > 0 {
            (self.w as usize) * (self.h as usize)
        } else {
            0
        }
    }
}

/// 画面座標系のクリッピング矩形 `(x, y, w, h)` を仮想画面 `(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT)` と交差させる
pub fn intersect_screen_clip(x: i32, y: i32, w: i32, h: i32) -> PixelSpan {
    intersect_screen_clip_ex(x, y, w, h, SCREEN_WIDTH as i32, SCREEN_HEIGHT as i32)
}

pub fn intersect_screen_clip_ex(x: i32, y: i32, w: i32, h: i32, sw: i32, sh: i32) -> PixelSpan {
    if w <= 0 || h <= 0 {
        return PixelSpan::new(0, 0, 0, 0);
    }
    let x0 = x.clamp(0, sw);
    let y0 = y.clamp(0, sh);
    let x1 = x.saturating_add(w).clamp(0, sw);
    let y1 = y.saturating_add(h).clamp(0, sh);
    PixelSpan::new(x0, y0, (x1 - x0).max(0), (y1 - y0).max(0))
}

/// 描画ステート（カメラオフセット、画面クリッピング領域、カラーパレット置換・透過設定）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DrawState {
    pub cam_x: i32,
    pub cam_y: i32,
    pub clip: Option<PixelSpan>,
    pub pal_map: [u8; 16],
    pub palt_mask: u16,
    pub screen_w: i32,
    pub screen_h: i32,
}

impl Default for DrawState {
    fn default() -> Self {
        Self {
            cam_x: 0,
            cam_y: 0,
            clip: None,
            pal_map: DEFAULT_PAL_MAP,
            palt_mask: 0,
            screen_w: SCREEN_WIDTH as i32,
            screen_h: SCREEN_HEIGHT as i32,
        }
    }
}

impl DrawState {
    pub fn set_camera(&mut self, x: i32, y: i32) {
        self.cam_x = x;
        self.cam_y = y;
    }

    pub fn reset_camera(&mut self) {
        self.cam_x = 0;
        self.cam_y = 0;
    }

    pub fn set_clip(&mut self, x: i32, y: i32, w: i32, h: i32) {
        self.clip = Some(intersect_screen_clip_ex(x, y, w, h, self.screen_w, self.screen_h));
    }

    pub fn reset_clip(&mut self) {
        self.clip = None;
    }

    pub fn is_clip_empty(&self) -> bool {
        matches!(self.clip, Some(c) if c.w <= 0 || c.h <= 0)
    }

    pub fn set_pal(&mut self, c0: i32, c1: i32) {
        let src = (c0.rem_euclid(16)) as usize;
        let dst = (c1.rem_euclid(16)) as u8;
        self.pal_map[src] = dst;
    }

    pub fn reset_pal(&mut self) {
        self.pal_map = DEFAULT_PAL_MAP;
    }

    pub fn set_palt(&mut self, col: i32, transparent: bool) {
        let idx = (col.rem_euclid(16)) as u16;
        if transparent {
            self.palt_mask |= 1 << idx;
        } else {
            self.palt_mask &= !(1 << idx);
        }
    }

    pub fn reset_palt(&mut self) {
        self.palt_mask = 0;
    }

    pub fn is_default_palette(&self) -> bool {
        self.pal_map == DEFAULT_PAL_MAP && self.palt_mask == 0
    }

    pub fn map_color_index(&self, col: i32) -> usize {
        let src = (col.rem_euclid(16)) as usize;
        (self.pal_map[src] & 0x0F) as usize
    }

    pub fn map_color(&self, col: i32) -> Color {
        PALETTE[self.map_color_index(col)]
    }

    /// ワールド座標系のスパン群にカメラオフセット `(-cam_x, -cam_y)` とクリッピング矩形 `clip` を適用する
    pub fn transform_and_clip_spans(&self, spans: &[PixelSpan]) -> Vec<PixelSpan> {
        if self.is_clip_empty() {
            return Vec::new();
        }
        let mut out = Vec::with_capacity(spans.len());
        for s in spans {
            if s.w <= 0 || s.h <= 0 {
                continue;
            }
            let sx = s.x.saturating_sub(self.cam_x);
            let sy = s.y.saturating_sub(self.cam_y);
            if let Some(clip) = self.clip {
                let x0 = sx.max(clip.x);
                let y0 = sy.max(clip.y);
                let x1 = sx.saturating_add(s.w).min(clip.x + clip.w);
                let y1 = sy.saturating_add(s.h).min(clip.y + clip.h);
                if x1 > x0 && y1 > y0 {
                    out.push(PixelSpan::new(x0, y0, x1 - x0, y1 - y0));
                }
            } else {
                out.push(PixelSpan::new(sx, sy, s.w, s.h));
            }
        }
        out
    }
}

fn apply_gl_scissor(clip: Option<PixelSpan>) {
    let gl_clip = clip.map(|c| (c.x, c.y, c.w.max(0), c.h.max(0)));
    unsafe {
        get_internal_gl().quad_gl.scissor(gl_clip);
    }
}

fn draw_spans(spans: &[PixelSpan], color: Color) {
    for span in spans {
        draw_rectangle(
            span.x as f32,
            span.y as f32,
            span.w as f32,
            span.h as f32,
            color,
        );
    }
}

fn trace_line_points(x0: i32, y0: i32, x1: i32, y1: i32, mut f: impl FnMut(i32, i32)) {
    let dx = (x1 - x0).abs();
    let sx = if x0 < x1 { 1 } else { -1 };
    let dy = -(y1 - y0).abs();
    let sy = if y0 < y1 { 1 } else { -1 };
    let mut err = dx + dy;
    let mut x = x0;
    let mut y = y0;

    loop {
        f(x, y);
        if x == x1 && y == y1 {
            break;
        }
        let e2 = 2 * err;
        if e2 >= dy {
            err += dy;
            x += sx;
        }
        if e2 <= dx {
            err += dx;
            y += sy;
        }
    }
}

fn points_to_horizontal_spans(mut points: Vec<(i32, i32)>) -> Vec<PixelSpan> {
    if points.is_empty() {
        return Vec::new();
    }
    points.sort_unstable_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
    points.dedup();

    let mut spans: Vec<PixelSpan> = Vec::new();
    for (px, py) in points {
        if let Some(last) = spans.last_mut()
            && last.y == py
            && px == last.x + last.w
        {
            last.w += 1;
        } else {
            spans.push(PixelSpan::new(px, py, 1, 1));
        }
    }
    spans
}

/// ブレゼンハムのアルゴリズムによる 1px 直線ラスタライズ `(x0, y0)` ..= `(x1, y1)`
pub fn rasterize_line(x0: i32, y0: i32, x1: i32, y1: i32) -> Vec<PixelSpan> {
    if y0 == y1 {
        let min_x = x0.min(x1);
        let w = (x0 - x1).abs() + 1;
        return vec![PixelSpan::new(min_x, y0, w, 1)];
    }
    if x0 == x1 {
        let min_y = y0.min(y1);
        let h = (y0 - y1).abs() + 1;
        return vec![PixelSpan::new(x0, min_y, 1, h)];
    }

    let dx = (x1 - x0).abs();
    let dy = -(y1 - y0).abs();
    let prefer_horizontal = dx >= -dy;
    let mut spans: Vec<PixelSpan> = Vec::new();

    trace_line_points(x0, y0, x1, y1, |x, y| {
        if let Some(last) = spans.last_mut() {
            if prefer_horizontal && last.h == 1 && last.y == y {
                if x == last.x + last.w {
                    last.w += 1;
                } else if x + 1 == last.x {
                    last.x = x;
                    last.w += 1;
                } else {
                    spans.push(PixelSpan::new(x, y, 1, 1));
                }
            } else if !prefer_horizontal && last.w == 1 && last.x == x {
                if y == last.y + last.h {
                    last.h += 1;
                } else if y + 1 == last.y {
                    last.y = y;
                    last.h += 1;
                } else {
                    spans.push(PixelSpan::new(x, y, 1, 1));
                }
            } else {
                spans.push(PixelSpan::new(x, y, 1, 1));
            }
        } else {
            spans.push(PixelSpan::new(x, y, 1, 1));
        }
    });

    spans
}

/// 枠線のみの矩形 `(x, y, w, h)` を重複のない最大4本の 1px スパンにラスタライズする
pub fn rasterize_rect(x: i32, y: i32, w: i32, h: i32) -> Vec<PixelSpan> {
    if w <= 0 || h <= 0 {
        return Vec::new();
    }
    if h == 1 {
        return vec![PixelSpan::new(x, y, w, 1)];
    }
    if w == 1 {
        return vec![PixelSpan::new(x, y, 1, h)];
    }
    if h == 2 {
        return vec![PixelSpan::new(x, y, w, 1), PixelSpan::new(x, y + 1, w, 1)];
    }
    vec![
        PixelSpan::new(x, y, w, 1),
        PixelSpan::new(x, y + h - 1, w, 1),
        PixelSpan::new(x, y + 1, 1, h - 2),
        PixelSpan::new(x + w - 1, y + 1, 1, h - 2),
    ]
}

/// 塗りつぶし矩形 `(x, y, w, h)` をラスタライズする
pub fn rasterize_rectfill(x: i32, y: i32, w: i32, h: i32) -> Vec<PixelSpan> {
    if w <= 0 || h <= 0 {
        return Vec::new();
    }
    vec![PixelSpan::new(x, y, w, h)]
}

/// ミッドポイント円アルゴリズムによる 1px 円枠 `(cx, cy, r)` のラスタライズ
pub fn rasterize_circ(cx: i32, cy: i32, r: i32) -> Vec<PixelSpan> {
    if r < 0 {
        return Vec::new();
    }
    if r == 0 {
        return vec![PixelSpan::new(cx, cy, 1, 1)];
    }
    let r = r.min(4096);
    let mut x = r;
    let mut y = 0;
    let mut d = 1 - r;
    let mut points = Vec::with_capacity((r as usize) * 8);

    while x >= y {
        points.extend_from_slice(&[
            (cx + x, cy + y),
            (cx - x, cy + y),
            (cx + x, cy - y),
            (cx - x, cy - y),
            (cx + y, cy + x),
            (cx - y, cy + x),
            (cx + y, cy - x),
            (cx - y, cy - x),
        ]);
        y += 1;
        if d < 0 {
            d += 2 * y + 1;
        } else {
            x -= 1;
            d += 2 * (y - x) + 1;
        }
    }

    points_to_horizontal_spans(points)
}

/// ミッドポイント円アルゴリズムによる塗りつぶし円 `(cx, cy, r)` の水平スパンラスタライズ（重複なし）
pub fn rasterize_circfill(cx: i32, cy: i32, r: i32) -> Vec<PixelSpan> {
    if r < 0 {
        return Vec::new();
    }
    if r == 0 {
        return vec![PixelSpan::new(cx, cy, 1, 1)];
    }
    let r = r.min(4096);
    let mut max_dx = vec![0i32; (r as usize) + 1];
    let mut x = r;
    let mut y = 0;
    let mut d = 1 - r;

    while x >= y {
        let yu = y as usize;
        let xu = x as usize;
        if x > max_dx[yu] {
            max_dx[yu] = x;
        }
        if y > max_dx[xu] {
            max_dx[xu] = y;
        }
        y += 1;
        if d < 0 {
            d += 2 * y + 1;
        } else {
            x -= 1;
            d += 2 * (y - x) + 1;
        }
    }

    let mut spans = Vec::with_capacity((2 * r + 1) as usize);
    for dy in -r..=r {
        let half = max_dx[dy.unsigned_abs() as usize];
        spans.push(PixelSpan::new(cx - half, cy + dy, 2 * half + 1, 1));
    }
    spans
}

fn trace_midpoint_ellipse(rx: i32, ry: i32, mut f: impl FnMut(i32, i32)) {
    let rx64 = rx.min(4096) as i64;
    let ry64 = ry.min(4096) as i64;
    let rx2 = rx64 * rx64;
    let ry2 = ry64 * ry64;

    let mut x = 0i64;
    let mut y = ry64;

    // Region 1: 接線の傾きの絶対値 < 1 (ry^2 * x < rx^2 * y)
    let mut d1 = 4 * ry2 + rx2 * (1 - 4 * ry64);
    while ry2 * x < rx2 * y {
        f(x as i32, y as i32);
        x += 1;
        if d1 < 0 {
            d1 += 4 * ry2 * (2 * x + 1);
        } else {
            y -= 1;
            d1 += 4 * ry2 * (2 * x + 1) - 8 * rx2 * y;
        }
    }

    // Region 2: 接線の傾きの絶対値 >= 1 (y >= 0 まで降下)
    let mut d2 = ry2 * (2 * x + 1) * (2 * x + 1) + 4 * rx2 * (y - 1) * (y - 1) - 4 * rx2 * ry2;
    while y >= 0 {
        f(x as i32, y as i32);
        y -= 1;
        if d2 > 0 {
            d2 += 4 * rx2 * (1 - 2 * y);
        } else {
            x += 1;
            d2 += 8 * ry2 * x + 4 * rx2 * (1 - 2 * y);
        }
    }
}

/// ミッドポイント楕円アルゴリズムによる 1px 楕円枠 `(cx, cy, rx, ry)` のラスタライズ
pub fn rasterize_oval(cx: i32, cy: i32, rx: i32, ry: i32) -> Vec<PixelSpan> {
    if rx < 0 || ry < 0 {
        return Vec::new();
    }
    if rx == ry {
        return rasterize_circ(cx, cy, rx);
    }
    let rx = rx.min(4096);
    let ry = ry.min(4096);
    if ry == 0 {
        return vec![PixelSpan::new(cx - rx, cy, 2 * rx + 1, 1)];
    }
    if rx == 0 {
        return vec![PixelSpan::new(cx, cy - ry, 1, 2 * ry + 1)];
    }

    let mut points = Vec::with_capacity(((rx + ry) as usize) * 4);
    trace_midpoint_ellipse(rx, ry, |dx, dy| {
        points.extend_from_slice(&[
            (cx + dx, cy + dy),
            (cx - dx, cy + dy),
            (cx + dx, cy - dy),
            (cx - dx, cy - dy),
        ]);
    });

    points_to_horizontal_spans(points)
}

/// ミッドポイント楕円アルゴリズムによる塗りつぶし楕円 `(cx, cy, rx, ry)` の水平スパンラスタライズ（重複なし）
pub fn rasterize_ovalfill(cx: i32, cy: i32, rx: i32, ry: i32) -> Vec<PixelSpan> {
    if rx < 0 || ry < 0 {
        return Vec::new();
    }
    if rx == ry {
        return rasterize_circfill(cx, cy, rx);
    }
    let rx = rx.min(4096);
    let ry = ry.min(4096);
    if ry == 0 {
        return vec![PixelSpan::new(cx - rx, cy, 2 * rx + 1, 1)];
    }
    if rx == 0 {
        return (cy - ry..=cy + ry)
            .map(|y| PixelSpan::new(cx, y, 1, 1))
            .collect();
    }

    let mut max_dx = vec![0i32; (ry as usize) + 1];
    trace_midpoint_ellipse(rx, ry, |dx, dy| {
        let yu = dy as usize;
        if dx > max_dx[yu] {
            max_dx[yu] = dx;
        }
    });

    let mut spans = Vec::with_capacity((2 * ry + 1) as usize);
    for dy in -ry..=ry {
        let half = max_dx[dy.unsigned_abs() as usize];
        spans.push(PixelSpan::new(cx - half, cy + dy, 2 * half + 1, 1));
    }
    spans
}

/// 三角形枠線 `(x0, y0) - (x1, y1) - (x2, y2)` のラスタライズ
pub fn rasterize_tri(x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32) -> Vec<PixelSpan> {
    let mut points = Vec::new();
    trace_line_points(x0, y0, x1, y1, |x, y| points.push((x, y)));
    trace_line_points(x1, y1, x2, y2, |x, y| points.push((x, y)));
    trace_line_points(x2, y2, x0, y0, |x, y| points.push((x, y)));
    points_to_horizontal_spans(points)
}

/// 塗りつぶし三角形 `(x0, y0) - (x1, y1) - (x2, y2)` の水平スパンラスタライズ
pub fn rasterize_trifill(x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32) -> Vec<PixelSpan> {
    let min_y = y0.min(y1).min(y2);
    let max_y = y0.max(y1).max(y2);
    let height = (max_y - min_y + 1) as usize;
    let mut row_bounds = vec![(i32::MAX, i32::MIN); height];

    let mut record = |x: i32, y: i32| {
        let idx = (y - min_y) as usize;
        let b = &mut row_bounds[idx];
        if x < b.0 {
            b.0 = x;
        }
        if x > b.1 {
            b.1 = x;
        }
    };

    trace_line_points(x0, y0, x1, y1, &mut record);
    trace_line_points(x1, y1, x2, y2, &mut record);
    trace_line_points(x2, y2, x0, y0, &mut record);

    let mut spans = Vec::with_capacity(height);
    for (i, &(min_x, max_x)) in row_bounds.iter().enumerate() {
        if min_x <= max_x {
            spans.push(PixelSpan::new(min_x, min_y + i as i32, max_x - min_x + 1, 1));
        }
    }
    spans
}

/// Ruby 引数から SFX 指定（整数ID / 文字列 / シンボル）を取り出す
enum SfxArg {
    Id(i32),
    Spec(String),
}

fn arg_sfx(args: &[Rc<RObject>], index: usize) -> Option<SfxArg> {
    let obj = args.get(index)?;
    match &obj.value {
        RValue::Integer(v) => Some(SfxArg::Id(*v as i32)),
        RValue::Float(v) => Some(SfxArg::Id(*v as i32)),
        RValue::Symbol(sym) => Some(SfxArg::Spec(sym.name.clone())),
        RValue::String(_, _) => String::try_from(obj.as_ref()).ok().map(SfxArg::Spec),
        _ => None,
    }
}

/// サウンド API (`sfx`, `stop_sfx`, `music`, `stop_music`) を登録する
fn register_sound_api(vm: &mut VM, sound_bank: Rc<RefCell<sound::SoundBank>>) {
    let obj_class = vm.object_class.clone();

    // sfx(id_or_spec, channel = -1, volume = 1.0):
    //   整数: `@SFX` 定義番号 / シンボル: プリセット (`:jump` 等) / 文字列: インラインMML (`"square c3 e3 g3"`)
    //   id が -1 の場合は該当チャンネル（-1なら全チャンネル）を停止
    let bank_for_sfx = sound_bank.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "sfx",
        Box::new(move |_vm, args| {
            let channel = arg_i32(args, 1, -1);
            let volume = arg_f32(args, 2, 1.0);
            let mut bank = bank_for_sfx.borrow_mut();
            match arg_sfx(args, 0) {
                Some(SfxArg::Id(id)) => bank.queue_play_sfx_id(id, channel, volume),
                Some(SfxArg::Spec(spec)) => bank.queue_play_sfx_inline(&spec, channel, volume),
                None => {}
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // stop_sfx(channel = -1): 指定チャンネル（省略時は全チャンネル）の効果音を停止
    let bank_for_stop_sfx = sound_bank.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "stop_sfx",
        Box::new(move |_vm, args| {
            let channel = arg_i32(args, 0, -1);
            bank_for_stop_sfx.borrow_mut().queue_stop_sfx(channel);
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // music(id, loop = true, volume = 1.0): `@MUSIC` 定義の BGM を再生（id が -1 なら停止）
    let bank_for_music = sound_bank.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "music",
        Box::new(move |_vm, args| {
            let id = arg_i32(args, 0, 0);
            let looped = arg_bool(args, 1, true);
            let volume = arg_f32(args, 2, 1.0);
            bank_for_music.borrow_mut().queue_play_music(id, looped, volume);
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // stop_music(): BGM を停止
    let bank_for_stop_music = sound_bank;
    mrb_define_cmethod(
        vm,
        obj_class,
        "stop_music",
        Box::new(move |_vm, _args| {
            bank_for_stop_music.borrow_mut().queue_stop_music();
            Ok(Rc::new(RObject::nil()))
        }),
    );
}

fn register_engine_api(
    vm: &mut VM,
    sprites: Rc<RefCell<HashMap<i32, SpriteData>>>,
    banks: Rc<RefCell<HashMap<i32, BankData>>>,
    active_spr_bank: Rc<RefCell<i32>>,
    active_map_bank: Rc<RefCell<i32>>,
    tilemap: Rc<RefCell<Tilemap>>,
    emoji_atlas: Rc<RefCell<emoji::EmojiAtlas>>,
    bitmap_font: Rc<BitmapFont>,
    draw_state: Rc<RefCell<DrawState>>,
    config: Rc<RefCell<AppConfig>>,
    headless: bool,
) {
    let obj_class = vm.object_class.clone();

    // spr_bank(id = 0): spr の参照先バンクを設定
    let active_spr_bank_for_spr_bank = active_spr_bank.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "spr_bank",
        Box::new(move |_vm, args| {
            let id = arg_i32(args, 0, 0);
            *active_spr_bank_for_spr_bank.borrow_mut() = id;
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // map_bank(id = 0): map の参照先バンクを設定
    let active_map_bank_for_map_bank = active_map_bank.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "map_bank",
        Box::new(move |_vm, args| {
            let id = arg_i32(args, 0, 0);
            *active_map_bank_for_map_bank.borrow_mut() = id;
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // config(opts): 画面解像度・倍率・フォント等の設定
    let cfg_for_config = config.clone();
    let state_for_config = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "config",
        Box::new(move |_vm, args| {
            if let Some(arg) = args.first() {
                if let RValue::Hash(ref hash_cell) = arg.value {
                    let hash = hash_cell.borrow();
                    let mut cfg = cfg_for_config.borrow_mut();
                    for (_k_obj, (k, v)) in hash.iter() {
                        let key_str = match &k.value {
                            RValue::Symbol(s) => s.name.clone(),
                            RValue::String(s, _) => String::from_utf8_lossy(&s.borrow()).to_string(),
                            _ => continue,
                        };
                        match key_str.as_str() {
                            "width" => {
                                if let Some(n) = robject_to_u32(v) {
                                    cfg.screen_width = n;
                                }
                            }
                            "height" => {
                                if let Some(n) = robject_to_u32(v) {
                                    cfg.screen_height = n;
                                }
                            }
                            "scale" => {
                                if let Some(f) = robject_to_f32(v) {
                                    cfg.window_scale = f;
                                }
                            }
                            "sprite_scale" => {
                                if let Some(f) = robject_to_f32(v) {
                                    cfg.sprite_scale = f;
                                }
                            }
                            "text_size" => {
                                if let Some(n) = robject_to_u32(v) {
                                    cfg.text_size = n;
                                }
                            }
                            "title" => {
                                if let Ok(s) = String::try_from(v.as_ref()) {
                                    cfg.title = s;
                                }
                            }
                            "show_fps" | "fps" => {
                                if let Some(b) = robject_to_bool(v) {
                                    cfg.show_fps = b;
                                }
                            }
                            _ => {}
                        }
                    }
                    state_for_config.borrow_mut().screen_w = cfg.screen_width as i32;
                    state_for_config.borrow_mut().screen_h = cfg.screen_height as i32;
                }
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // 組み込みクラス拡張: ! 演算子 (FalseClass, NilClass, TrueClass, Object)
    if let Some(false_class) = vm.builtin_class_table.get("FalseClass").cloned() {
        mrb_define_cmethod(
            vm,
            false_class,
            "!",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::boolean(true)))),
        );
    }
    if let Some(nil_class) = vm.builtin_class_table.get("NilClass").cloned() {
        mrb_define_cmethod(
            vm,
            nil_class,
            "!",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::boolean(true)))),
        );
    }
    if let Some(true_class) = vm.builtin_class_table.get("TrueClass").cloned() {
        mrb_define_cmethod(
            vm,
            true_class,
            "!",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::boolean(false)))),
        );
    }
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "!",
        Box::new(|_vm, _args| Ok(Rc::new(RObject::boolean(false)))),
    );

    // Symbol#upcase, Symbol#downcase
    if let Some(sym_class) = vm.builtin_class_table.get("Symbol").cloned() {
        mrb_define_cmethod(
            vm,
            sym_class.clone(),
            "upcase",
            Box::new(|vm, _args| {
                let s: String = vm.getself()?.as_ref().try_into()?;
                Ok(Rc::new(RObject::string(s.to_uppercase())))
            }),
        );
        mrb_define_cmethod(
            vm,
            sym_class,
            "downcase",
            Box::new(|vm, _args| {
                let s: String = vm.getself()?.as_ref().try_into()?;
                Ok(Rc::new(RObject::string(s.to_lowercase())))
            }),
        );
    }

    // camera(x = 0, y = 0): カメラオフセットを設定（引数なしで (0, 0) にリセット）
    let state_for_cam = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "camera",
        Box::new(move |_vm, args| {
            let x = arg_i32(args, 0, 0);
            let y = arg_i32(args, 1, 0);
            state_for_cam.borrow_mut().set_camera(x, y);
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // clip(x = nil, y = nil, w = nil, h = nil): 画面座標系での描画クリッピング領域を設定（引数なしまたは nil で解除）
    let state_for_clip = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "clip",
        Box::new(move |_vm, args| {
            let mut state = state_for_clip.borrow_mut();
            if args.is_empty() || matches!(args[0].value, RValue::Nil) {
                state.reset_clip();
            } else {
                let x = arg_i32(args, 0, 0);
                let y = arg_i32(args, 1, 0);
                let w = arg_i32(args, 2, SCREEN_WIDTH as i32);
                let h = arg_i32(args, 3, SCREEN_HEIGHT as i32);
                state.set_clip(x, y, w, h);
            }
            if !headless {
                apply_gl_scissor(state.clip);
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // pal(c0 = nil, c1 = nil): パレット色 c0 を c1 に置き換える（引数なしまたは nil でパレット置換と palt をリセット）
    let state_for_pal = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "pal",
        Box::new(move |_vm, args| {
            let mut state = state_for_pal.borrow_mut();
            if args.is_empty() || matches!(args[0].value, RValue::Nil) {
                state.reset_pal();
                state.reset_palt();
            } else if let RValue::Array(ref arr_cell) = args[0].value {
                for (idx, item) in arr_cell.borrow().iter().take(16).enumerate() {
                    let dst = match item.value {
                        RValue::Integer(v) => v as i32,
                        RValue::Float(v) => v as i32,
                        _ => idx as i32,
                    };
                    state.set_pal(idx as i32, dst);
                }
            } else {
                let c0 = arg_i32(args, 0, 0);
                let c1 = arg_i32(args, 1, c0);
                state.set_pal(c0, c1);
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // palt(col = nil, t = false): スプライト描画時にパレット色 col を透明として扱うか設定（引数なしまたは nil でリセット）
    let state_for_palt = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "palt",
        Box::new(move |_vm, args| {
            let mut state = state_for_palt.borrow_mut();
            if args.is_empty() || matches!(args[0].value, RValue::Nil) {
                state.reset_palt();
            } else {
                let col = arg_i32(args, 0, 0);
                let transparent = arg_bool(args, 1, true);
                state.set_palt(col, transparent);
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // mget(cel_x = 0, cel_y = 0): タイルマップ上のセル (cel_x, cel_y) のタイル番号を取得（未設定は 0）
    let map_for_mget = tilemap.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "mget",
        Box::new(move |_vm, args| {
            let cx = arg_i32(args, 0, 0);
            let cy = arg_i32(args, 1, 0);
            let val = map_for_mget.borrow().get(cx, cy);
            Ok(Rc::new(RObject::integer(val as i64)))
        }),
    );

    // mset(cel_x = 0, cel_y = 0, val = 0): タイルマップ上のセル (cel_x, cel_y) にタイル番号 val を設定
    let map_for_mset = tilemap.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "mset",
        Box::new(move |_vm, args| {
            let cx = arg_i32(args, 0, 0);
            let cy = arg_i32(args, 1, 0);
            let val = arg_i32(args, 2, 0);
            map_for_mset.borrow_mut().set(cx, cy, val);
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // read_file(path): 指定パスのテキストを読み込み、文字列またはnilを返す
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "read_file",
        Box::new(|_vm, args| {
            let path = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            if path.is_empty() {
                return Ok(Rc::new(RObject::nil()));
            }
            match std::fs::read_to_string(&path) {
                Ok(text) => Ok(Rc::new(RObject::string(text))),
                Err(_) => Ok(Rc::new(RObject::nil())),
            }
        }),
    );

    // save_file(path, content): 指定パスにテキストを書き込む
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "save_file",
        Box::new(|_vm, args| {
            let path = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            let content = args
                .get(1)
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            if path.is_empty() {
                return Ok(Rc::new(RObject::boolean(false)));
            }
            match std::fs::write(&path, content) {
                Ok(()) => Ok(Rc::new(RObject::boolean(true))),
                Err(e) => {
                    eprintln!("[save_file] Error writing `{}`: {}", path, e);
                    Ok(Rc::new(RObject::boolean(false)))
                }
            }
        }),
    );

    // load_resource_sprites(path, num_slots = 16): 指定スクリプトまたは外部リソースファイルから
    // スプライト（16x16）を読み込み、スロットごとのドット配列 (256要素 or nil) の配列を返す。
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "load_resource_sprites",
        Box::new(|_vm, args| {
            let path_str = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            let num_slots = arg_i32(args, 1, 16).max(1) as usize;

            if path_str.is_empty() {
                return Ok(Rc::new(RObject::array(vec![Rc::new(RObject::nil()); num_slots])));
            }

            let p = std::path::Path::new(&path_str);
            let tail = if p.extension().and_then(|s| s.to_str()) == Some("rb") {
                cli::compile_ruby_script_file(p)
                    .map(|(_, t, _)| t)
                    .unwrap_or_default()
            } else if p.is_file() {
                std::fs::read_to_string(p).unwrap_or_default()
            } else {
                String::new()
            };

            let (sprites, banks) = parse_tail_resources_full(&tail, p.parent());
            let bank0_opt = banks.get(&0);
            let mut slot_list = Vec::with_capacity(num_slots);

            for sid in 0..num_slots {
                if let Some(sp) = sprites.get(&(sid as i32)) {
                    let mut pixels = Vec::with_capacity(256);
                    let w = sp.width.min(16) as usize;
                    let h = sp.height.min(16) as usize;
                    for y in 0..16 {
                        for x in 0..16 {
                            if x < w && y < h {
                                let off = (y * sp.width as usize + x) * 4;
                                if off + 4 <= sp.rgba.len() {
                                    let r = sp.rgba[off];
                                    let g = sp.rgba[off + 1];
                                    let b = sp.rgba[off + 2];
                                    let a = sp.rgba[off + 3];
                                    if a == 0 {
                                        pixels.push(Rc::new(RObject::nil()));
                                    } else {
                                        let c = nearest_palette_index(r, g, b) as i64;
                                        pixels.push(Rc::new(RObject::integer(c)));
                                    }
                                } else {
                                    pixels.push(Rc::new(RObject::nil()));
                                }
                            } else {
                                pixels.push(Rc::new(RObject::nil()));
                            }
                        }
                    }
                    slot_list.push(Rc::new(RObject::array(pixels)));
                } else if let Some(bank) = bank0_opt {
                    let mut pixels = Vec::with_capacity(256);
                    let slot_x = (sid % 16) * 16;
                    let slot_y = (sid / 16) * 16;
                    let mut has_pixel = false;
                    for y in 0..16 {
                        for x in 0..16 {
                            let off = ((slot_y + y) * BANK_WIDTH + slot_x + x) * 4;
                            if off + 4 <= bank.rgba.len() {
                                let a = bank.rgba[off + 3];
                                if a == 0 {
                                    pixels.push(Rc::new(RObject::nil()));
                                } else {
                                    has_pixel = true;
                                    let c = nearest_palette_index(bank.rgba[off], bank.rgba[off + 1], bank.rgba[off + 2]) as i64;
                                    pixels.push(Rc::new(RObject::integer(c)));
                                }
                            } else {
                                pixels.push(Rc::new(RObject::nil()));
                            }
                        }
                    }
                    if has_pixel || sid == 0 {
                        slot_list.push(Rc::new(RObject::array(pixels)));
                    } else {
                        slot_list.push(Rc::new(RObject::nil()));
                    }
                } else {
                    slot_list.push(Rc::new(RObject::nil()));
                }
            }

            Ok(Rc::new(RObject::array(slot_list)))
        }),
    );

    // load_resource_bank(path, bank_id = 0): バンク（256x256）全体のドット配列 (65536要素) を返す
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "load_resource_bank",
        Box::new(|_vm, args| {
            let path_str = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            let bank_id = arg_i32(args, 1, 0);

            let p = std::path::Path::new(&path_str);
            let base_dir = p.parent();

            if p.extension().and_then(|s| s.to_str()).map(|s| s.eq_ignore_ascii_case("png")) == Some(true)
                && p.is_file()
            {
                if let Ok(bank) = BankData::from_file_or_base64(bank_id, &path_str, None) {
                    let mut pixels = Vec::with_capacity(BANK_PIXELS);
                    for px in bank.rgba.chunks_exact(4) {
                        if px[3] == 0 {
                            pixels.push(Rc::new(RObject::nil()));
                        } else {
                            let c = nearest_palette_index(px[0], px[1], px[2]) as i64;
                            pixels.push(Rc::new(RObject::integer(c)));
                        }
                    }
                    return Ok(Rc::new(RObject::array(pixels)));
                }
            }

            let tail = if p.extension().and_then(|s| s.to_str()) == Some("rb") {
                cli::compile_ruby_script_file(p)
                    .map(|(_, t, _)| t)
                    .unwrap_or_default()
            } else if p.is_file() {
                std::fs::read_to_string(p).unwrap_or_default()
            } else {
                String::new()
            };

            let (_sprites, banks) = parse_tail_resources_full(&tail, base_dir);
            if let Some(bank) = banks.get(&bank_id) {
                let mut pixels = Vec::with_capacity(BANK_PIXELS);
                for px in bank.rgba.chunks_exact(4) {
                    if px[3] == 0 {
                        pixels.push(Rc::new(RObject::nil()));
                    } else {
                        let c = nearest_palette_index(px[0], px[1], px[2]) as i64;
                        pixels.push(Rc::new(RObject::integer(c)));
                    }
                }
                Ok(Rc::new(RObject::array(pixels)))
            } else {
                Ok(Rc::new(RObject::nil()))
            }
        }),
    );

    // bank_to_b64_png(pixels): 65536要素のカラーインデックス配列から Base64 PNG を生成
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "bank_to_b64_png",
        Box::new(|_vm, args| {
            if let Some(first) = args.first()
                && let RValue::Array(ref ary_cell) = first.value
            {
                let ary = ary_cell.borrow();
                let mut bank = BankData::new(0);
                for (i, val) in ary.iter().take(BANK_PIXELS).enumerate() {
                    let col_idx = match &val.value {
                        RValue::Integer(c) if (0..=15).contains(c) => Some(*c as usize),
                        _ => None,
                    };
                    if let Some(idx) = col_idx {
                        let off = i * 4;
                        bank.rgba[off..off + 4].copy_from_slice(&PALETTE_RGBA[idx]);
                    }
                }
                if let Ok(b64) = bank.to_base64_png() {
                    return Ok(Rc::new(RObject::string(b64)));
                }
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // load_resource_map(path, width = 32, height = 32): 指定スクリプトまたは外部リソースから
    // タイルマップデータを読み込み、(width * height) 要素のタイルID配列を返す。@MAPがない場合はnilを返す。
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "load_resource_map",
        Box::new(|_vm, args| {
            let path_str = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            let width = arg_i32(args, 1, 32).max(1) as usize;
            let height = arg_i32(args, 2, 32).max(1) as usize;

            if path_str.is_empty() {
                return Ok(Rc::new(RObject::nil()));
            }

            let p = std::path::Path::new(&path_str);
            let tail = if p.extension().and_then(|s| s.to_str()) == Some("rb") {
                cli::compile_ruby_script_file(p)
                    .map(|(_, t, _)| t)
                    .unwrap_or_default()
            } else if p.is_file() {
                std::fs::read_to_string(p).unwrap_or_default()
            } else {
                String::new()
            };

            if !tail.contains("@MAP") {
                return Ok(Rc::new(RObject::nil()));
            }

            let tmap = parse_tail_map(&tail);
            let mut tiles = Vec::with_capacity(width * height);
            for y in 0..height {
                for x in 0..width {
                    let tid = tmap.get(x as i32, y as i32);
                    tiles.push(Rc::new(RObject::integer(tid as i64)));
                }
            }

            Ok(Rc::new(RObject::array(tiles)))
        }),
    );

    // file_mtime(path): 指定ファイルの最終更新時刻（UNIXミリ秒）を返す。存在しない場合は0。
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "file_mtime",
        Box::new(|_vm, args| {
            let path_str = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            if path_str.is_empty() {
                return Ok(Rc::new(RObject::integer(0)));
            }
            let mtime_ms = std::fs::metadata(&path_str)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            Ok(Rc::new(RObject::integer(mtime_ms)))
        }),
    );

    if headless {
        // ヘッドレステスト用スタブ登録 (図形ラスタライズ・カメラ・クリッピング・パレット変換および絵文字キャッシュ抽出も検証可能にする)
        let state_for_cls = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "cls",
            Box::new(move |_vm, args| {
                let col = arg_i32(args, 0, 0);
                let _ = state_for_cls.borrow().map_color(col);
                Ok(Rc::new(RObject::nil()))
            }),
        );
        let state_for_pset = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "pset",
            Box::new(move |_vm, args| {
                let x = arg_i32(args, 0, 0);
                let y = arg_i32(args, 1, 0);
                let col = arg_i32(args, 2, 7);
                let state = *state_for_pset.borrow();
                let _ = state.map_color(col);
                let _ = state.transform_and_clip_spans(&[PixelSpan::new(x, y, 1, 1)]);
                Ok(Rc::new(RObject::nil()))
            }),
        );
        let state_for_line = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "line",
            Box::new(move |_vm, args| {
                let x0 = arg_i32(args, 0, 0);
                let y0 = arg_i32(args, 1, 0);
                let x1 = arg_i32(args, 2, 0);
                let y1 = arg_i32(args, 3, 0);
                let col = arg_i32(args, 4, 7);
                let spans = rasterize_line(x0, y0, x1, y1);
                let state = *state_for_line.borrow();
                let _ = state.map_color(col);
                let _ = state.transform_and_clip_spans(&spans);
                Ok(Rc::new(RObject::nil()))
            }),
        );
        let state_for_rect = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "rect",
            Box::new(move |_vm, args| {
                let x = arg_i32(args, 0, 0);
                let y = arg_i32(args, 1, 0);
                let w = arg_i32(args, 2, 16);
                let h = arg_i32(args, 3, 16);
                let col = arg_i32(args, 4, 7);
                let spans = rasterize_rect(x, y, w, h);
                let state = *state_for_rect.borrow();
                let _ = state.map_color(col);
                let _ = state.transform_and_clip_spans(&spans);
                Ok(Rc::new(RObject::nil()))
            }),
        );
        let state_for_rectfill = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "rectfill",
            Box::new(move |_vm, args| {
                let x = arg_i32(args, 0, 0);
                let y = arg_i32(args, 1, 0);
                let w = arg_i32(args, 2, 16);
                let h = arg_i32(args, 3, 16);
                let col = arg_i32(args, 4, 7);
                let spans = rasterize_rectfill(x, y, w, h);
                let state = *state_for_rectfill.borrow();
                let _ = state.map_color(col);
                let _ = state.transform_and_clip_spans(&spans);
                Ok(Rc::new(RObject::nil()))
            }),
        );
        for name in ["circ", "circle"] {
            let state_for_circ = draw_state.clone();
            mrb_define_cmethod(
                vm,
                obj_class.clone(),
                name,
                Box::new(move |_vm, args| {
                    let x = arg_i32(args, 0, 0);
                    let y = arg_i32(args, 1, 0);
                    let r = arg_i32(args, 2, 4);
                    let col = arg_i32(args, 3, 7);
                    let spans = rasterize_circ(x, y, r);
                    let state = *state_for_circ.borrow();
                    let _ = state.map_color(col);
                    let _ = state.transform_and_clip_spans(&spans);
                    Ok(Rc::new(RObject::nil()))
                }),
            );
        }
        for name in ["circfill", "circlefill"] {
            let state_for_circfill = draw_state.clone();
            mrb_define_cmethod(
                vm,
                obj_class.clone(),
                name,
                Box::new(move |_vm, args| {
                    let x = arg_i32(args, 0, 0);
                    let y = arg_i32(args, 1, 0);
                    let r = arg_i32(args, 2, 4);
                    let col = arg_i32(args, 3, 7);
                    let spans = rasterize_circfill(x, y, r);
                    let state = *state_for_circfill.borrow();
                    let _ = state.map_color(col);
                    let _ = state.transform_and_clip_spans(&spans);
                    Ok(Rc::new(RObject::nil()))
                }),
            );
        }
        for name in ["oval", "ellipse"] {
            let state_for_oval = draw_state.clone();
            mrb_define_cmethod(
                vm,
                obj_class.clone(),
                name,
                Box::new(move |_vm, args| {
                    let x = arg_i32(args, 0, 0);
                    let y = arg_i32(args, 1, 0);
                    let rx = arg_i32(args, 2, 6);
                    let ry = arg_i32(args, 3, 4);
                    let col = arg_i32(args, 4, 7);
                    let spans = rasterize_oval(x, y, rx, ry);
                    let state = *state_for_oval.borrow();
                    let _ = state.map_color(col);
                    let _ = state.transform_and_clip_spans(&spans);
                    Ok(Rc::new(RObject::nil()))
                }),
            );
        }
        for name in ["ovalfill", "ellipsefill"] {
            let state_for_ovalfill = draw_state.clone();
            mrb_define_cmethod(
                vm,
                obj_class.clone(),
                name,
                Box::new(move |_vm, args| {
                    let x = arg_i32(args, 0, 0);
                    let y = arg_i32(args, 1, 0);
                    let rx = arg_i32(args, 2, 6);
                    let ry = arg_i32(args, 3, 4);
                    let col = arg_i32(args, 4, 7);
                    let spans = rasterize_ovalfill(x, y, rx, ry);
                    let state = *state_for_ovalfill.borrow();
                    let _ = state.map_color(col);
                    let _ = state.transform_and_clip_spans(&spans);
                    Ok(Rc::new(RObject::nil()))
                }),
            );
        }
        let state_for_tri = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "tri",
            Box::new(move |_vm, args| {
                let x0 = arg_i32(args, 0, 0);
                let y0 = arg_i32(args, 1, 0);
                let x1 = arg_i32(args, 2, 8);
                let y1 = arg_i32(args, 3, 0);
                let x2 = arg_i32(args, 4, 4);
                let y2 = arg_i32(args, 5, 8);
                let col = arg_i32(args, 6, 7);
                let spans = rasterize_tri(x0, y0, x1, y1, x2, y2);
                let state = *state_for_tri.borrow();
                let _ = state.map_color(col);
                let _ = state.transform_and_clip_spans(&spans);
                Ok(Rc::new(RObject::nil()))
            }),
        );
        let state_for_trifill = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "trifill",
            Box::new(move |_vm, args| {
                let x0 = arg_i32(args, 0, 0);
                let y0 = arg_i32(args, 1, 0);
                let x1 = arg_i32(args, 2, 8);
                let y1 = arg_i32(args, 3, 0);
                let x2 = arg_i32(args, 4, 4);
                let y2 = arg_i32(args, 5, 8);
                let col = arg_i32(args, 6, 7);
                let spans = rasterize_trifill(x0, y0, x1, y1, x2, y2);
                let state = *state_for_trifill.borrow();
                let _ = state.map_color(col);
                let _ = state.transform_and_clip_spans(&spans);
                Ok(Rc::new(RObject::nil()))
            }),
        );
        let emoji_for_headless_print = emoji_atlas.clone();
        let state_for_headless_print = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "print_text",
            Box::new(move |_vm, args| {
                let state = *state_for_headless_print.borrow();
                if state.is_clip_empty() {
                    return Ok(Rc::new(RObject::nil()));
                }
                let col = arg_i32(args, 3, 7);
                let _ = state.map_color(col);
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
        let banks_for_headless_blt = banks.clone();
        let state_for_headless_blt = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "blt",
            Box::new(move |_vm, args| {
                let state = *state_for_headless_blt.borrow();
                if state.is_clip_empty() {
                    return Ok(Rc::new(RObject::nil()));
                }
                let x = arg_f32(args, 0, 0.0) - state.cam_x as f32;
                let y = arg_f32(args, 1, 0.0) - state.cam_y as f32;
                let bank_id = arg_i32(args, 2, 0);
                let _u = arg_f32(args, 3, 0.0);
                let _v = arg_f32(args, 4, 0.0);
                let raw_w = arg_f32(args, 5, 16.0);
                let raw_h = arg_f32(args, 6, 16.0);
                let rotate = arg_f32(args, 7, 0.0);
                let scale = arg_f32(args, 8, 1.0);
                if raw_w == 0.0 || raw_h == 0.0 || scale <= 0.0 {
                    return Ok(Rc::new(RObject::nil()));
                }
                let flip_x = raw_w < 0.0;
                let flip_y = raw_h < 0.0;
                let w = raw_w.abs();
                let h = raw_h.abs();
                if let Some(bank) = banks_for_headless_blt.borrow().get(&bank_id) {
                    if !state.is_default_palette() {
                        let _ = bank.apply_palette(&state.pal_map, state.palt_mask);
                    }
                    let _ = compute_sprite_draw_params(
                        w, h, x, y, flip_x, flip_y, rotate, scale,
                    );
                }
                Ok(Rc::new(RObject::nil()))
            }),
        );
        let banks_for_headless_update = banks.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "update_bank",
            Box::new(move |_vm, args| {
                let bank_id = arg_i32(args, 0, 0);
                if let Some(second) = args.get(1)
                    && let RValue::Array(ref ary_cell) = second.value
                {
                    let ary = ary_cell.borrow();
                    let mut pixels = Vec::with_capacity(ary.len());
                    for val in ary.iter() {
                        match &val.value {
                            RValue::Integer(c) if (0..=15).contains(c) => pixels.push(Some(*c as u8)),
                            _ => pixels.push(None),
                        }
                    }
                    let mut banks_mut = banks_for_headless_update.borrow_mut();
                    let bank = banks_mut.entry(bank_id).or_insert_with(|| BankData::new(bank_id));
                    bank.update_pixels(&pixels);
                    return Ok(Rc::new(RObject::boolean(true)));
                }
                Ok(Rc::new(RObject::boolean(false)))
            }),
        );
        let banks_for_headless_set_pixel = banks.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "set_bank_pixel",
            Box::new(move |_vm, args| {
                let bank_id = arg_i32(args, 0, 0);
                let x = arg_i32(args, 1, 0);
                let y = arg_i32(args, 2, 0);
                let col = match args.get(3).map(|v| &v.value) {
                    Some(RValue::Integer(c)) if (0..=15).contains(c) => Some(*c as u8),
                    _ => None,
                };
                if x >= 0 && x < BANK_WIDTH as i32 && y >= 0 && y < BANK_HEIGHT as i32 {
                    let mut banks_mut = banks_for_headless_set_pixel.borrow_mut();
                    let bank = banks_mut.entry(bank_id).or_insert_with(|| BankData::new(bank_id));
                    bank.set_pixel(x as usize, y as usize, col);
                    return Ok(Rc::new(RObject::boolean(true)));
                }
                Ok(Rc::new(RObject::boolean(false)))
            }),
        );
        let banks_for_headless_update_rect = banks.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "update_bank_rect",
            Box::new(move |_vm, args| {
                let bank_id = arg_i32(args, 0, 0);
                let x = arg_i32(args, 1, 0).max(0) as usize;
                let y = arg_i32(args, 2, 0).max(0) as usize;
                let w = arg_i32(args, 3, 32).max(1) as usize;
                let h = arg_i32(args, 4, 32).max(1) as usize;
                if let Some(sixth) = args.get(5)
                    && let RValue::Array(ref ary_cell) = sixth.value
                {
                    let ary = ary_cell.borrow();
                    let mut pixels = Vec::with_capacity(ary.len());
                    for val in ary.iter() {
                        match &val.value {
                            RValue::Integer(c) if (0..=15).contains(c) => pixels.push(Some(*c as u8)),
                            _ => pixels.push(None),
                        }
                    }
                    let mut banks_mut = banks_for_headless_update_rect.borrow_mut();
                    let bank = banks_mut.entry(bank_id).or_insert_with(|| BankData::new(bank_id));
                    bank.update_rect(x, y, w, h, &pixels);
                    return Ok(Rc::new(RObject::boolean(true)));
                }
                Ok(Rc::new(RObject::boolean(false)))
            }),
        );
        let banks_for_headless_get_rect = banks.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "get_bank_rect",
            Box::new(move |_vm, args| {
                let bank_id = arg_i32(args, 0, 0);
                let x = arg_i32(args, 1, 0).max(0) as usize;
                let y = arg_i32(args, 2, 0).max(0) as usize;
                let w = arg_i32(args, 3, 32).max(1) as usize;
                let h = arg_i32(args, 4, 32).max(1) as usize;
                let banks_ref = banks_for_headless_get_rect.borrow();
                let rect_pixels = if let Some(bank) = banks_ref.get(&bank_id) {
                    bank.get_rect(x, y, w, h)
                } else {
                    vec![None; w * h]
                };
                let ary: Vec<Rc<RObject>> = rect_pixels
                    .into_iter()
                    .map(|opt| match opt {
                        Some(c) => Rc::new(RObject::integer(c as i64)),
                        None => Rc::new(RObject::nil()),
                    })
                    .collect();
                Ok(Rc::new(RObject::array(ary)))
            }),
        );
        let banks_for_headless_get_pixel = banks.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "get_bank_pixel",
            Box::new(move |_vm, args| {
                let bank_id = arg_i32(args, 0, 0);
                let x = arg_i32(args, 1, 0);
                let y = arg_i32(args, 2, 0);
                if x >= 0 && x < BANK_WIDTH as i32 && y >= 0 && y < BANK_HEIGHT as i32 {
                    let banks_ref = banks_for_headless_get_pixel.borrow();
                    if let Some(bank) = banks_ref.get(&bank_id) {
                        if let Some(col) = bank.get_pixel(x as usize, y as usize) {
                            return Ok(Rc::new(RObject::integer(col as i64)));
                        }
                    }
                }
                Ok(Rc::new(RObject::nil()))
            }),
        );
        let banks_for_headless_get_pixels = banks.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "get_bank_pixels",
            Box::new(move |_vm, args| {
                let bank_id = arg_i32(args, 0, 0);
                let banks_ref = banks_for_headless_get_pixels.borrow();
                let pixels = if let Some(bank) = banks_ref.get(&bank_id) {
                    bank.get_pixels()
                } else {
                    vec![None; BANK_PIXELS]
                };
                let ary: Vec<Rc<RObject>> = pixels
                    .into_iter()
                    .map(|opt| match opt {
                        Some(c) => Rc::new(RObject::integer(c as i64)),
                        None => Rc::new(RObject::nil()),
                    })
                    .collect();
                Ok(Rc::new(RObject::array(ary)))
            }),
        );
        let banks_for_headless_spr = banks.clone();
        let act_spr_for_headless = active_spr_bank.clone();
        let sprites_for_headless = sprites.clone();
        let emoji_for_headless = emoji_atlas.clone();
        let state_for_headless_spr = draw_state.clone();
        let cfg_for_headless_spr = config.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "spr",
            Box::new(move |_vm, args| {
                let state = *state_for_headless_spr.borrow();
                if state.is_clip_empty() {
                    return Ok(Rc::new(RObject::nil()));
                }
                let default_scale = cfg_for_headless_spr.borrow().sprite_scale;
                let x = arg_f32(args, 1, 0.0) - state.cam_x as f32;
                let y = arg_f32(args, 2, 0.0) - state.cam_y as f32;

                let (tile_w, tile_h, flip_x, flip_y, rotate, scale) = if let Some(arg3) = args.get(3) {
                    match &arg3.value {
                        RValue::Bool(b) => {
                            let fy = arg_bool(args, 4, false);
                            let rot = arg_f32(args, 5, 0.0);
                            let sc = arg_f32(args, 6, default_scale);
                            (1, 1, *b, fy, rot, sc)
                        }
                        _ => {
                            let tw = arg_i32(args, 3, 1).max(1);
                            let th = arg_i32(args, 4, 1).max(1);
                            let fx = arg_bool(args, 5, false);
                            let fy = arg_bool(args, 6, false);
                            let rot = arg_f32(args, 7, 0.0);
                            let sc = arg_f32(args, 8, default_scale);
                            (tw, th, fx, fy, rot, sc)
                        }
                    }
                } else {
                    (1, 1, false, false, 0.0, default_scale)
                };

                if let Some(first) = args.first() {
                    if let RValue::Array(_) = first.value {
                        return Ok(Rc::new(RObject::nil()));
                    }
                    if matches!(first.value, RValue::String(_, _)) {
                        if let Ok(s) = String::try_from(first.as_ref()) {
                            if let Some(sp) = emoji_for_headless.borrow_mut().get_or_insert(&s, false) {
                                if !state.is_default_palette() {
                                    let _ = sp.apply_palette(&state.pal_map, state.palt_mask);
                                }
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
                let cur_bank_id = *act_spr_for_headless.borrow();
                let banks_ref = banks_for_headless_spr.borrow();
                if let Some(bank) = banks_ref.get(&cur_bank_id) {
                    if !state.is_default_palette() {
                        let _ = bank.apply_palette(&state.pal_map, state.palt_mask);
                    }
                    let _ = compute_sprite_draw_params(
                        (tile_w * 16) as f32,
                        (tile_h * 16) as f32,
                        x,
                        y,
                        flip_x,
                        flip_y,
                        rotate,
                        scale,
                    );
                } else if let Some(sp) = sprites_for_headless.borrow().get(&id) {
                    if !state.is_default_palette() {
                        let _ = sp.apply_palette(&state.pal_map, state.palt_mask);
                    }
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
        let banks_for_headless_map = banks.clone();
        let act_map_for_headless = active_map_bank.clone();
        let sprites_for_headless_map = sprites.clone();
        let map_for_headless = tilemap.clone();
        let state_for_headless_map = draw_state.clone();
        let cfg_for_headless_map = config.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "map",
            Box::new(move |_vm, args| {
                let state = *state_for_headless_map.borrow();
                if state.is_clip_empty() {
                    return Ok(Rc::new(RObject::nil()));
                }
                let cfg = cfg_for_headless_map.borrow();
                let sp_scale = cfg.sprite_scale;
                let sw = cfg.screen_width as f32;
                let sh = cfg.screen_height as f32;
                let tmap = map_for_headless.borrow();
                let cel_x = arg_i32(args, 0, 0);
                let cel_y = arg_i32(args, 1, 0);
                let sx = arg_i32(args, 2, 0);
                let sy = arg_i32(args, 3, 0);
                let cel_w = arg_i32(args, 4, tmap.width.max(16));
                let cel_h = arg_i32(args, 5, tmap.height.max(16));
                let target_bank_id = if args.len() >= 7 && !args[6].is_nil() {
                    arg_i32(args, 6, 0)
                } else {
                    *act_map_for_headless.borrow()
                };
                if cel_w <= 0 || cel_h <= 0 {
                    return Ok(Rc::new(RObject::nil()));
                }
                let banks_ref = banks_for_headless_map.borrow();
                let bank_opt = banks_ref.get(&target_bank_id);
                let sprites_ref = sprites_for_headless_map.borrow();
                let step = (SPRITE_SIZE as f32 * sp_scale) as i32;
                for dy in 0..cel_h {
                    for dx in 0..cel_w {
                        let tile_id = tmap.get(cel_x + dx, cel_y + dy);
                        if tile_id <= 0 {
                            continue;
                        }
                        let draw_x =
                            (sx + dx * step - state.cam_x) as f32;
                        let draw_y =
                            (sy + dy * step - state.cam_y) as f32;
                        if draw_x + 16.0 * sp_scale <= 0.0
                            || draw_x >= sw
                            || draw_y + 16.0 * sp_scale <= 0.0
                            || draw_y >= sh
                        {
                            continue;
                        }
                        if let Some(bank) = bank_opt {
                            if !state.is_default_palette() {
                                let _ = bank.apply_palette(&state.pal_map, state.palt_mask);
                            }
                            let _ = compute_sprite_draw_params(
                                16.0,
                                16.0,
                                draw_x,
                                draw_y,
                                false,
                                false,
                                0.0,
                                sp_scale,
                            );
                        } else if let Some(sp) = sprites_ref.get(&tile_id) {
                            if !state.is_default_palette() {
                                let _ = sp.apply_palette(&state.pal_map, state.palt_mask);
                            }
                            let _ = compute_sprite_draw_params(
                                sp.width as f32,
                                sp.height as f32,
                                draw_x,
                                draw_y,
                                false,
                                false,
                                0.0,
                                sp_scale,
                            );
                        }
                    }
                }
                Ok(Rc::new(RObject::nil()))
            }),
        );
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "btn",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::boolean(false)))),
        );
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "btnp",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::boolean(false)))),
        );
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "mouse_x",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::integer(0)))),
        );
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "mouse_y",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::integer(0)))),
        );
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "mouse_wheel",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::float(0.0)))),
        );
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "show_mouse",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::nil()))),
        );
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "fps",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::integer(60)))),
        );
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "draw_sprite_data",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::nil()))),
        );
        mrb_define_cmethod(
            vm,
            obj_class,
            "spr_data",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::nil()))),
        );
        return;
    }

    // cls(col = 0): 画面（または現在のクリッピング領域）を指定したパレット色でクリア
    let state_for_cls = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "cls",
        Box::new(move |_vm, args| {
            let col = arg_i32(args, 0, 0);
            let state = *state_for_cls.borrow();
            let color = state.map_color(col);
            if let Some(clip_rect) = state.clip {
                if clip_rect.w > 0 && clip_rect.h > 0 {
                    draw_rectangle(
                        clip_rect.x as f32,
                        clip_rect.y as f32,
                        clip_rect.w as f32,
                        clip_rect.h as f32,
                        color,
                    );
                }
            } else {
                clear_background(color);
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // pset(x = 0, y = 0, col = 7): 1ドット描画
    let state_for_pset = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "pset",
        Box::new(move |_vm, args| {
            let x = arg_i32(args, 0, 0);
            let y = arg_i32(args, 1, 0);
            let col = arg_i32(args, 2, 7);
            let state = *state_for_pset.borrow();
            let spans = state.transform_and_clip_spans(&[PixelSpan::new(x, y, 1, 1)]);
            draw_spans(&spans, state.map_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // line(x0 = 0, y0 = 0, x1 = 0, y1 = 0, col = 7): 直線描画（ブレゼンハム 1px）
    let state_for_line = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "line",
        Box::new(move |_vm, args| {
            let x0 = arg_i32(args, 0, 0);
            let y0 = arg_i32(args, 1, 0);
            let x1 = arg_i32(args, 2, 0);
            let y1 = arg_i32(args, 3, 0);
            let col = arg_i32(args, 4, 7);
            let raw = rasterize_line(x0, y0, x1, y1);
            let state = *state_for_line.borrow();
            let spans = state.transform_and_clip_spans(&raw);
            draw_spans(&spans, state.map_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // rect(x = 0, y = 0, w = 16, h = 16, col = 7): 枠線のみの矩形
    let state_for_rect = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "rect",
        Box::new(move |_vm, args| {
            let x = arg_i32(args, 0, 0);
            let y = arg_i32(args, 1, 0);
            let w = arg_i32(args, 2, 16);
            let h = arg_i32(args, 3, 16);
            let col = arg_i32(args, 4, 7);
            let raw = rasterize_rect(x, y, w, h);
            let state = *state_for_rect.borrow();
            let spans = state.transform_and_clip_spans(&raw);
            draw_spans(&spans, state.map_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // rectfill(x = 0, y = 0, w = 16, h = 16, col = 7): 塗りつぶし矩形
    let state_for_rectfill = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "rectfill",
        Box::new(move |_vm, args| {
            let x = arg_i32(args, 0, 0);
            let y = arg_i32(args, 1, 0);
            let w = arg_i32(args, 2, 16);
            let h = arg_i32(args, 3, 16);
            let col = arg_i32(args, 4, 7);
            let raw = rasterize_rectfill(x, y, w, h);
            let state = *state_for_rectfill.borrow();
            let spans = state.transform_and_clip_spans(&raw);
            draw_spans(&spans, state.map_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // circ(x = 0, y = 0, r = 4, col = 7) / circle(x = 0, y = 0, r = 4, col = 7): 枠線のみの円
    for name in ["circ", "circle"] {
        let state_for_circ = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            name,
            Box::new(move |_vm, args| {
                let x = arg_i32(args, 0, 0);
                let y = arg_i32(args, 1, 0);
                let r = arg_i32(args, 2, 4);
                let col = arg_i32(args, 3, 7);
                let raw = rasterize_circ(x, y, r);
                let state = *state_for_circ.borrow();
                let spans = state.transform_and_clip_spans(&raw);
                draw_spans(&spans, state.map_color(col));
                Ok(Rc::new(RObject::nil()))
            }),
        );
    }

    // circfill(x = 0, y = 0, r = 4, col = 7) / circlefill(x = 0, y = 0, r = 4, col = 7): 塗りつぶし円
    for name in ["circfill", "circlefill"] {
        let state_for_circfill = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            name,
            Box::new(move |_vm, args| {
                let x = arg_i32(args, 0, 0);
                let y = arg_i32(args, 1, 0);
                let r = arg_i32(args, 2, 4);
                let col = arg_i32(args, 3, 7);
                let raw = rasterize_circfill(x, y, r);
                let state = *state_for_circfill.borrow();
                let spans = state.transform_and_clip_spans(&raw);
                draw_spans(&spans, state.map_color(col));
                Ok(Rc::new(RObject::nil()))
            }),
        );
    }

    // oval(x = 0, y = 0, rx = 6, ry = 4, col = 7) / ellipse(x = 0, y = 0, rx = 6, ry = 4, col = 7): 枠線のみの楕円
    for name in ["oval", "ellipse"] {
        let state_for_oval = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            name,
            Box::new(move |_vm, args| {
                let x = arg_i32(args, 0, 0);
                let y = arg_i32(args, 1, 0);
                let rx = arg_i32(args, 2, 6);
                let ry = arg_i32(args, 3, 4);
                let col = arg_i32(args, 4, 7);
                let raw = rasterize_oval(x, y, rx, ry);
                let state = *state_for_oval.borrow();
                let spans = state.transform_and_clip_spans(&raw);
                draw_spans(&spans, state.map_color(col));
                Ok(Rc::new(RObject::nil()))
            }),
        );
    }

    // ovalfill(x = 0, y = 0, rx = 6, ry = 4, col = 7) / ellipsefill(x = 0, y = 0, rx = 6, ry = 4, col = 7): 塗りつぶし楕円
    for name in ["ovalfill", "ellipsefill"] {
        let state_for_ovalfill = draw_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            name,
            Box::new(move |_vm, args| {
                let x = arg_i32(args, 0, 0);
                let y = arg_i32(args, 1, 0);
                let rx = arg_i32(args, 2, 6);
                let ry = arg_i32(args, 3, 4);
                let col = arg_i32(args, 4, 7);
                let raw = rasterize_ovalfill(x, y, rx, ry);
                let state = *state_for_ovalfill.borrow();
                let spans = state.transform_and_clip_spans(&raw);
                draw_spans(&spans, state.map_color(col));
                Ok(Rc::new(RObject::nil()))
            }),
        );
    }

    // tri(x0 = 0, y0 = 0, x1 = 8, y1 = 0, x2 = 4, y2 = 8, col = 7): 枠線のみの三角形
    let state_for_tri = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "tri",
        Box::new(move |_vm, args| {
            let x0 = arg_i32(args, 0, 0);
            let y0 = arg_i32(args, 1, 0);
            let x1 = arg_i32(args, 2, 8);
            let y1 = arg_i32(args, 3, 0);
            let x2 = arg_i32(args, 4, 4);
            let y2 = arg_i32(args, 5, 8);
            let col = arg_i32(args, 6, 7);
            let raw = rasterize_tri(x0, y0, x1, y1, x2, y2);
            let state = *state_for_tri.borrow();
            let spans = state.transform_and_clip_spans(&raw);
            draw_spans(&spans, state.map_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // trifill(x0 = 0, y0 = 0, x1 = 8, y1 = 0, x2 = 4, y2 = 8, col = 7): 塗りつぶし三角形
    let state_for_trifill = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "trifill",
        Box::new(move |_vm, args| {
            let x0 = arg_i32(args, 0, 0);
            let y0 = arg_i32(args, 1, 0);
            let x1 = arg_i32(args, 2, 8);
            let y1 = arg_i32(args, 3, 0);
            let x2 = arg_i32(args, 4, 4);
            let y2 = arg_i32(args, 5, 8);
            let col = arg_i32(args, 6, 7);
            let raw = rasterize_trifill(x0, y0, x1, y1, x2, y2);
            let state = *state_for_trifill.borrow();
            let spans = state.transform_and_clip_spans(&raw);
            draw_spans(&spans, state.map_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // blt(x, y, bank, u, v, w, h, rotate = 0, scale = 1.0): ピクセル矩形転送
    let banks_for_blt = banks.clone();
    let state_for_blt = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "blt",
        Box::new(move |_vm, args| {
            let state = *state_for_blt.borrow();
            if state.is_clip_empty() {
                return Ok(Rc::new(RObject::nil()));
            }
            let x = arg_f32(args, 0, 0.0) - state.cam_x as f32;
            let y = arg_f32(args, 1, 0.0) - state.cam_y as f32;
            let bank_id = arg_i32(args, 2, 0);
            let u = arg_f32(args, 3, 0.0);
            let v = arg_f32(args, 4, 0.0);
            let raw_w = arg_f32(args, 5, 16.0);
            let raw_h = arg_f32(args, 6, 16.0);
            let rotate = arg_f32(args, 7, 0.0);
            let scale = arg_f32(args, 8, 1.0);

            if raw_w == 0.0 || raw_h == 0.0 || scale <= 0.0 {
                return Ok(Rc::new(RObject::nil()));
            }

            let flip_x = raw_w < 0.0;
            let flip_y = raw_h < 0.0;
            let w = raw_w.abs();
            let h = raw_h.abs();

            let banks_ref = banks_for_blt.borrow();
            if let Some(bank) = banks_ref.get(&bank_id) {
                draw_bank_rect(
                    bank,
                    &state,
                    x,
                    y,
                    u,
                    v,
                    w,
                    h,
                    flip_x,
                    flip_y,
                    rotate,
                    scale,
                );
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // update_bank(bank_id, pixels): ランタイム内のバンクデータを更新し、テクスチャを再構築
    let banks_for_update = banks.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "update_bank",
        Box::new(move |_vm, args| {
            let bank_id = arg_i32(args, 0, 0);
            if let Some(second) = args.get(1)
                && let RValue::Array(ref ary_cell) = second.value
            {
                let ary = ary_cell.borrow();
                let mut pixels = Vec::with_capacity(ary.len());
                for val in ary.iter() {
                    match &val.value {
                        RValue::Integer(c) if (0..=15).contains(c) => pixels.push(Some(*c as u8)),
                        _ => pixels.push(None),
                    }
                }
                let mut banks_mut = banks_for_update.borrow_mut();
                let bank = banks_mut.entry(bank_id).or_insert_with(|| BankData::new(bank_id));
                bank.update_pixels(&pixels);
                return Ok(Rc::new(RObject::boolean(true)));
            }
            Ok(Rc::new(RObject::boolean(false)))
        }),
    );

    // set_bank_pixel(bank_id, x, y, col): 1ピクセルを即座に更新 (描画時に自動テクスチャ更新)
    let banks_for_set_pixel = banks.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "set_bank_pixel",
        Box::new(move |_vm, args| {
            let bank_id = arg_i32(args, 0, 0);
            let x = arg_i32(args, 1, 0);
            let y = arg_i32(args, 2, 0);
            let col = match args.get(3).map(|v| &v.value) {
                Some(RValue::Integer(c)) if (0..=15).contains(c) => Some(*c as u8),
                _ => None,
            };
            if x >= 0 && x < BANK_WIDTH as i32 && y >= 0 && y < BANK_HEIGHT as i32 {
                let mut banks_mut = banks_for_set_pixel.borrow_mut();
                let bank = banks_mut.entry(bank_id).or_insert_with(|| BankData::new(bank_id));
                bank.set_pixel(x as usize, y as usize, col);
                return Ok(Rc::new(RObject::boolean(true)));
            }
            Ok(Rc::new(RObject::boolean(false)))
        }),
    );

    // update_bank_rect(bank_id, x, y, w, h, pixels): 矩形領域ピクセル配列で部分更新 (描画時に自動テクスチャ更新)
    let banks_for_update_rect = banks.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "update_bank_rect",
        Box::new(move |_vm, args| {
            let bank_id = arg_i32(args, 0, 0);
            let x = arg_i32(args, 1, 0).max(0) as usize;
            let y = arg_i32(args, 2, 0).max(0) as usize;
            let w = arg_i32(args, 3, 32).max(1) as usize;
            let h = arg_i32(args, 4, 32).max(1) as usize;
            if let Some(sixth) = args.get(5)
                && let RValue::Array(ref ary_cell) = sixth.value
            {
                let ary = ary_cell.borrow();
                let mut pixels = Vec::with_capacity(ary.len());
                for val in ary.iter() {
                    match &val.value {
                        RValue::Integer(c) if (0..=15).contains(c) => pixels.push(Some(*c as u8)),
                        _ => pixels.push(None),
                    }
                }
                let mut banks_mut = banks_for_update_rect.borrow_mut();
                let bank = banks_mut.entry(bank_id).or_insert_with(|| BankData::new(bank_id));
                bank.update_rect(x, y, w, h, &pixels);
                return Ok(Rc::new(RObject::boolean(true)));
            }
            Ok(Rc::new(RObject::boolean(false)))
        }),
    );

    // get_bank_rect(bank_id, x, y, w, h): 矩形領域のピクセル配列を取得 ([Option<u8>])
    let banks_for_get_rect = banks.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "get_bank_rect",
        Box::new(move |_vm, args| {
            let bank_id = arg_i32(args, 0, 0);
            let x = arg_i32(args, 1, 0).max(0) as usize;
            let y = arg_i32(args, 2, 0).max(0) as usize;
            let w = arg_i32(args, 3, 32).max(1) as usize;
            let h = arg_i32(args, 4, 32).max(1) as usize;
            let banks_ref = banks_for_get_rect.borrow();
            let rect_pixels = if let Some(bank) = banks_ref.get(&bank_id) {
                bank.get_rect(x, y, w, h)
            } else {
                vec![None; w * h]
            };
            let ary: Vec<Rc<RObject>> = rect_pixels
                .into_iter()
                .map(|opt| match opt {
                    Some(c) => Rc::new(RObject::integer(c as i64)),
                    None => Rc::new(RObject::nil()),
                })
                .collect();
            Ok(Rc::new(RObject::array(ary)))
        }),
    );

    // get_bank_pixel(bank_id, x, y): 1ピクセルのカラー番号 (0..15 または nil) を取得
    let banks_for_get_pixel = banks.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "get_bank_pixel",
        Box::new(move |_vm, args| {
            let bank_id = arg_i32(args, 0, 0);
            let x = arg_i32(args, 1, 0);
            let y = arg_i32(args, 2, 0);
            if x >= 0 && x < BANK_WIDTH as i32 && y >= 0 && y < BANK_HEIGHT as i32 {
                let banks_ref = banks_for_get_pixel.borrow();
                if let Some(bank) = banks_ref.get(&bank_id) {
                    if let Some(col) = bank.get_pixel(x as usize, y as usize) {
                        return Ok(Rc::new(RObject::integer(col as i64)));
                    }
                }
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // get_bank_pixels(bank_id): 256x256 の全ピクセル配列 (65536要素) を取得
    let banks_for_get_pixels = banks.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "get_bank_pixels",
        Box::new(move |_vm, args| {
            let bank_id = arg_i32(args, 0, 0);
            let banks_ref = banks_for_get_pixels.borrow();
            let pixels = if let Some(bank) = banks_ref.get(&bank_id) {
                bank.get_pixels()
            } else {
                vec![None; BANK_PIXELS]
            };
            let ary: Vec<Rc<RObject>> = pixels
                .into_iter()
                .map(|opt| match opt {
                    Some(c) => Rc::new(RObject::integer(c as i64)),
                    None => Rc::new(RObject::nil()),
                })
                .collect();
            Ok(Rc::new(RObject::array(ary)))
        }),
    );

    // spr(id_or_emoji, x = 0, y = 0, w = 1, h = 1, flip_x = false, flip_y = false): スプライトまたは絵文字描画
    let banks_for_spr = banks.clone();
    let act_spr_for_spr = active_spr_bank.clone();
    let sprites_for_spr = sprites.clone();
    let emoji_for_spr = emoji_atlas.clone();
    let state_for_spr = draw_state.clone();
    let cfg_for_spr = config.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "spr",
        Box::new(move |_vm, args| {
            let state = *state_for_spr.borrow();
            if state.is_clip_empty() {
                return Ok(Rc::new(RObject::nil()));
            }
            let default_scale = cfg_for_spr.borrow().sprite_scale;
            let x = arg_f32(args, 1, 0.0) - state.cam_x as f32;
            let y = arg_f32(args, 2, 0.0) - state.cam_y as f32;

            // 第4引数の型によるスマート判定 (数値なら w, h / 真偽値なら flip_x, flip_y)
            let (tile_w, tile_h, flip_x, flip_y, rotate, scale) = if let Some(arg3) = args.get(3) {
                match &arg3.value {
                    RValue::Bool(b) => {
                        let fy = arg_bool(args, 4, false);
                        let rot = arg_f32(args, 5, 0.0);
                        let sc = arg_f32(args, 6, default_scale);
                        (1, 1, *b, fy, rot, sc)
                    }
                    _ => {
                        let tw = arg_i32(args, 3, 1).max(1);
                        let th = arg_i32(args, 4, 1).max(1);
                        let fx = arg_bool(args, 5, false);
                        let fy = arg_bool(args, 6, false);
                        let rot = arg_f32(args, 7, 0.0);
                        let sc = arg_f32(args, 8, default_scale);
                        (tw, th, fx, fy, rot, sc)
                    }
                }
            } else {
                (1, 1, false, false, 0.0, default_scale)
            };

            if let Some(first) = args.first() {
                if let RValue::Array(ref ary_cell) = first.value {
                    let ary = ary_cell.borrow();
                    draw_pixel_data_direct(&ary, &state, x, y, flip_x, flip_y, scale);
                    return Ok(Rc::new(RObject::nil()));
                }
                if matches!(first.value, RValue::String(_, _))
                    && let Ok(emoji_str) = String::try_from(first.as_ref())
                {
                    let mut atlas_ref = emoji_for_spr.borrow_mut();
                    if let Some(sprite) = atlas_ref.get_or_insert(&emoji_str, true) {
                        draw_sprite_transformed(sprite, &state, x, y, flip_x, flip_y, rotate, scale);
                    }
                    return Ok(Rc::new(RObject::nil()));
                }
            }

            let id = arg_i32(args, 0, 0);
            let cur_bank_id = *act_spr_for_spr.borrow();
            let banks_ref = banks_for_spr.borrow();
            if let Some(bank) = banks_ref.get(&cur_bank_id) {
                let u = ((id % 16) * 16) as f32;
                let v = ((id / 16) * 16) as f32;
                let w = (tile_w * 16) as f32;
                let h = (tile_h * 16) as f32;
                draw_bank_rect(
                    bank,
                    &state,
                    x,
                    y,
                    u,
                    v,
                    w,
                    h,
                    flip_x,
                    flip_y,
                    rotate,
                    scale,
                );
            } else {
                let sprites_ref = sprites_for_spr.borrow();
                if let Some(sprite) = sprites_ref.get(&id) {
                    draw_sprite_transformed(sprite, &state, x, y, flip_x, flip_y, rotate, scale);
                }
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // draw_sprite_data(pixels, x = 0, y = 0, scale = 1.0, flip_x = false, flip_y = false): ピクセル配列ダイレクト描画
    let state_for_draw_sp_data = draw_state.clone();
    let cfg_for_draw_sp_data = config.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "draw_sprite_data",
        Box::new(move |_vm, args| {
            let state = *state_for_draw_sp_data.borrow();
            if state.is_clip_empty() {
                return Ok(Rc::new(RObject::nil()));
            }
            let default_scale = cfg_for_draw_sp_data.borrow().sprite_scale;
            let x = arg_f32(args, 1, 0.0) - state.cam_x as f32;
            let y = arg_f32(args, 2, 0.0) - state.cam_y as f32;
            let scale = arg_f32(args, 3, default_scale);
            let flip_x = arg_bool(args, 4, false);
            let flip_y = arg_bool(args, 5, false);

            if let Some(first) = args.first() {
                if let RValue::Array(ref ary_cell) = first.value {
                    let ary = ary_cell.borrow();
                    draw_pixel_data_direct(&ary, &state, x, y, flip_x, flip_y, scale);
                }
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    let state_for_spr_data = draw_state.clone();
    let cfg_for_spr_data = config.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "spr_data",
        Box::new(move |_vm, args| {
            let state = *state_for_spr_data.borrow();
            if state.is_clip_empty() {
                return Ok(Rc::new(RObject::nil()));
            }
            let default_scale = cfg_for_spr_data.borrow().sprite_scale;
            let x = arg_f32(args, 1, 0.0) - state.cam_x as f32;
            let y = arg_f32(args, 2, 0.0) - state.cam_y as f32;
            let scale = arg_f32(args, 3, default_scale);
            let flip_x = arg_bool(args, 4, false);
            let flip_y = arg_bool(args, 5, false);

            if let Some(first) = args.first() {
                if let RValue::Array(ref ary_cell) = first.value {
                    let ary = ary_cell.borrow();
                    draw_pixel_data_direct(&ary, &state, x, y, flip_x, flip_y, scale);
                }
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // map(cel_x = 0, cel_y = 0, sx = 0, sy = 0, cel_w = map.width, cel_h = map.height, bank = nil): タイルマップを描画
    let banks_for_map = banks.clone();
    let act_map_for_map = active_map_bank.clone();
    let sprites_for_map = sprites.clone();
    let map_for_draw = tilemap.clone();
    let state_for_map = draw_state.clone();
    let cfg_for_map = config.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "map",
        Box::new(move |_vm, args| {
            let state = *state_for_map.borrow();
            if state.is_clip_empty() {
                return Ok(Rc::new(RObject::nil()));
            }
            let cfg = cfg_for_map.borrow();
            let sp_scale = cfg.sprite_scale;
            let sw = cfg.screen_width as f32;
            let sh = cfg.screen_height as f32;
            let tmap = map_for_draw.borrow();
            let cel_x = arg_i32(args, 0, 0);
            let cel_y = arg_i32(args, 1, 0);
            let sx = arg_i32(args, 2, 0);
            let sy = arg_i32(args, 3, 0);
            let cel_w = arg_i32(args, 4, tmap.width.max(16));
            let cel_h = arg_i32(args, 5, tmap.height.max(16));
            let target_bank_id = if args.len() >= 7 && !args[6].is_nil() {
                arg_i32(args, 6, 0)
            } else {
                *act_map_for_map.borrow()
            };
            if cel_w <= 0 || cel_h <= 0 {
                return Ok(Rc::new(RObject::nil()));
            }
            let banks_ref = banks_for_map.borrow();
            let bank_opt = banks_ref.get(&target_bank_id);
            let sprites_ref = sprites_for_map.borrow();
            let step = (SPRITE_SIZE as f32 * sp_scale) as i32;
            for dy in 0..cel_h {
                for dx in 0..cel_w {
                    let tile_id = tmap.get(cel_x + dx, cel_y + dy);
                    if tile_id <= 0 {
                        continue;
                    }
                    let draw_x = (sx + dx * step - state.cam_x) as f32;
                    let draw_y = (sy + dy * step - state.cam_y) as f32;
                    let tile_size_scaled = SPRITE_SIZE as f32 * sp_scale;
                    if draw_x + tile_size_scaled <= 0.0
                        || draw_x >= sw
                        || draw_y + tile_size_scaled <= 0.0
                        || draw_y >= sh
                    {
                        continue;
                    }
                    if let Some(bank) = bank_opt {
                        let u = ((tile_id % 16) * 16) as f32;
                        let v = ((tile_id / 16) * 16) as f32;
                        draw_bank_rect(
                            bank,
                            &state,
                            draw_x,
                            draw_y,
                            u,
                            v,
                            16.0,
                            16.0,
                            false,
                            false,
                            0.0,
                            sp_scale,
                        );
                    } else if let Some(sprite) = sprites_ref.get(&tile_id) {
                        draw_sprite_transformed(
                            sprite, &state, draw_x, draw_y, false, false, 0.0, sp_scale,
                        );
                    }
                }
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // btn(id_or_sym): ボタン入力判定（キーボード: 0..5 または :left, :right, :up, :down, :z, :x / マウス: 6..8 または :mouse_l, :mouse_r, :mouse_m）
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "btn",
        Box::new(|_vm, args| {
            let pressed = parse_button_arg(args, 0)
                .map(is_button_down)
                .unwrap_or(false);
            Ok(Rc::new(RObject::boolean(pressed)))
        }),
    );

    // btnp(id_or_sym): ボタンがこのフレームで押された瞬間か判定
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "btnp",
        Box::new(|_vm, args| {
            let pressed = parse_button_arg(args, 0)
                .map(is_button_pressed)
                .unwrap_or(false);
            Ok(Rc::new(RObject::boolean(pressed)))
        }),
    );

    // mouse_x: 仮想スクリーン上のマウス X 座標
    let cfg_for_mouse_x = config.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "mouse_x",
        Box::new(move |_vm, _args| {
            let cfg = cfg_for_mouse_x.borrow();
            let (mx, _) = virtual_mouse_position_ex(cfg.screen_width as f32, cfg.screen_height as f32);
            Ok(Rc::new(RObject::integer(mx as i64)))
        }),
    );

    // mouse_y: 仮想スクリーン上のマウス Y 座標
    let cfg_for_mouse_y = config.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "mouse_y",
        Box::new(move |_vm, _args| {
            let cfg = cfg_for_mouse_y.borrow();
            let (_, my) = virtual_mouse_position_ex(cfg.screen_width as f32, cfg.screen_height as f32);
            Ok(Rc::new(RObject::integer(my as i64)))
        }),
    );

    // mouse_wheel: マウスホイールのスクロール量（縦方向）
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "mouse_wheel",
        Box::new(|_vm, _args| {
            let (_, wy) = mouse_wheel();
            Ok(Rc::new(RObject::float(wy as f64)))
        }),
    );

    // show_mouse(visible = true): OS マウスカーソルの表示/非表示を切り替え
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "show_mouse",
        Box::new(|_vm, args| {
            let visible = arg_bool(args, 0, true);
            show_mouse(visible);
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // fps: 現在のフレームレート (FPS) を取得
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "fps",
        Box::new(|_vm, _args| {
            let current_fps = get_fps();
            Ok(Rc::new(RObject::integer(current_fps as i64)))
        }),
    );

    // print_text(text, x = 0, y = 0, col = 7, size = nil): 1-bit ピクセルフォント + 絵文字でくっきりテキスト描画
    let font_for_print = bitmap_font.clone();
    let emoji_for_print = emoji_atlas.clone();
    let state_for_print = draw_state;
    let cfg_for_print = config.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "print_text",
        Box::new(move |_vm, args| {
            let state = *state_for_print.borrow();
            if state.is_clip_empty() {
                return Ok(Rc::new(RObject::nil()));
            }
            let text = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            let x = (arg_i32(args, 1, 0).saturating_sub(state.cam_x)) as f32;
            let y = (arg_i32(args, 2, 0).saturating_sub(state.cam_y)) as f32;
            let col = arg_i32(args, 3, 7);
            let size = parse_text_size_arg(args, cfg_for_print.borrow().resolved_text_size());
            font_for_print.draw_text_crisp_ex(&text, x, y, state.map_color(col), &emoji_for_print, size);
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
    pub banks: Rc<RefCell<HashMap<i32, BankData>>>,
    pub active_spr_bank: Rc<RefCell<i32>>,
    pub active_map_bank: Rc<RefCell<i32>>,
    pub tilemap: Rc<RefCell<Tilemap>>,
    pub emoji_atlas: Rc<RefCell<emoji::EmojiAtlas>>,
    pub bitmap_font: Rc<BitmapFont>,
    pub draw_state: Rc<RefCell<DrawState>>,
    pub sound_bank: Rc<RefCell<sound::SoundBank>>,
    pub config: Rc<RefCell<AppConfig>>,
    pub script_args: Vec<String>,
    initial_globals: HashMap<String, Rc<RObject>>,
    initial_tail_map: Tilemap,
    headless: bool,
}

impl GameRuntime {
    pub fn new(tail_data: &str, mrb_bytes: &[u8], headless: bool) -> Result<Self, String> {
        Self::new_with_args(tail_data, mrb_bytes, headless, &[])
    }

    pub fn new_with_args(
        tail_data: &str,
        mrb_bytes: &[u8],
        headless: bool,
        script_args: &[String],
    ) -> Result<Self, String> {
        let (mut sprites_map, mut banks_map) = parse_tail_resources_full(tail_data, None);
        let tail_map = parse_tail_map(tail_data);
        let (mut sfx_map, mut music_map) = sound::parse_tail_sounds(tail_data);

        let mut rite =
            rite::load(mrb_bytes).map_err(|e| format!("Failed to load RITE(.mrb): {:?}", e))?;
        let mut vm = VM::open(&mut rite);

        // ARGV および $ARGV の登録
        let argv_elements: Vec<Rc<RObject>> = script_args
            .iter()
            .map(|s| Rc::new(RObject::string(s.clone())))
            .collect();
        let argv_obj = Rc::new(RObject::array(argv_elements));
        vm.consts.insert("ARGV".to_string(), argv_obj.clone());
        vm.globals.insert("$ARGV".to_string(), argv_obj);

        if !headless {
            for sprite in sprites_map.values_mut() {
                sprite.build_texture();
            }
            for bank in banks_map.values_mut() {
                bank.build_texture();
            }
        }

        let sprites = Rc::new(RefCell::new(sprites_map));
        let banks = Rc::new(RefCell::new(banks_map));
        let active_spr_bank = Rc::new(RefCell::new(0));
        let active_map_bank = Rc::new(RefCell::new(0));
        let tilemap = Rc::new(RefCell::new(tail_map.clone()));
        let emoji_atlas = Rc::new(RefCell::new(emoji::EmojiAtlas::new()));
        let bitmap_font = Rc::new(BitmapFont::new(!headless));
        let draw_state = Rc::new(RefCell::new(DrawState::default()));
        let sound_bank = Rc::new(RefCell::new(sound::SoundBank::new(
            HashMap::new(),
            HashMap::new(),
        )));
        let config = Rc::new(RefCell::new(AppConfig::default()));

        register_engine_api(
            &mut vm,
            sprites.clone(),
            banks.clone(),
            active_spr_bank.clone(),
            active_map_bank.clone(),
            tilemap.clone(),
            emoji_atlas.clone(),
            bitmap_font.clone(),
            draw_state.clone(),
            config.clone(),
            headless,
        );
        register_sound_api(&mut vm, sound_bank.clone());

        vm.run()
            .map_err(|e| format!("Failed to run top-level Ruby script: {:?}", e))?;

        let mut current_sprites = sprites.borrow().clone();
        parse_ruby_sprites_global(&vm, &mut current_sprites, &emoji_atlas.borrow());
        parse_ruby_map_global(&vm, &mut tilemap.borrow_mut());
        sound::parse_ruby_sounds_globals(&vm, &mut sfx_map, &mut music_map);
        sound_bank
            .borrow_mut()
            .update_definitions(sfx_map, music_map);
        if !headless {
            for sprite in current_sprites.values_mut() {
                if sprite.texture.is_none() {
                    sprite.build_texture();
                }
            }
            for bank in banks.borrow_mut().values_mut() {
                if bank.texture.borrow().is_none() {
                    bank.build_texture();
                }
            }
        }
        *sprites.borrow_mut() = current_sprites;

        let initial_globals = snapshot_globals(&vm);
        let initial_tail_map = tilemap.borrow().clone();

        Ok(Self {
            vm,
            sprites,
            banks,
            active_spr_bank,
            active_map_bank,
            tilemap,
            emoji_atlas,
            bitmap_font,
            draw_state,
            sound_bank,
            config,
            script_args: script_args.to_vec(),
            initial_globals,
            initial_tail_map,
            headless,
        })
    }

    /// グローバル変数（`$x`, `$y`, `$t` 等）や実行時タイルマップの操作状態を維持したまま、
    /// メソッド定義とスプライト・マップ定義をホットリロードする。
    /// ただしスクリプト上のトップレベル初期値や `@MAP` 自体が書き換えられた場合は新しい定義を採用する。
    pub fn hot_reload(&mut self, new_tail_data: &str, new_mrb_bytes: &[u8]) -> Result<(), String> {
        let (mut new_sprites_map, mut new_banks_map) = parse_tail_resources_full(new_tail_data, None);
        let new_tail_map = parse_tail_map(new_tail_data);
        let (mut new_sfx_map, mut new_music_map) = sound::parse_tail_sounds(new_tail_data);

        let mut new_rite = rite::load(new_mrb_bytes)
            .map_err(|e| format!("Failed to load RITE(.mrb) on reload: {:?}", e))?;
        let mut new_vm = VM::open(&mut new_rite);

        // ARGV および $ARGV の再登録
        let argv_elements: Vec<Rc<RObject>> = self
            .script_args
            .iter()
            .map(|s| Rc::new(RObject::string(s.clone())))
            .collect();
        let argv_obj = Rc::new(RObject::array(argv_elements));
        new_vm.consts.insert("ARGV".to_string(), argv_obj.clone());
        new_vm.globals.insert("$ARGV".to_string(), argv_obj);

        // リロード前に再生中だった BGM を記録（トップレベルの `music(...)` 呼び出しで再スタートさせないため）
        let (prev_music_id, prev_music_spec, prev_pending_len) = {
            let bank = self.sound_bank.borrow();
            let id = bank.current_music_id;
            let spec = id.and_then(|i| bank.music.get(&i).map(|m| m.spec.clone()));
            (id, spec, bank.pending_commands.len())
        };

        let temp_tilemap = Rc::new(RefCell::new(new_tail_map));
        {
            let mut ds = self.draw_state.borrow_mut();
            *ds = DrawState::default();
            ds.screen_w = self.config.borrow().screen_width as i32;
            ds.screen_h = self.config.borrow().screen_height as i32;
        }
        register_engine_api(
            &mut new_vm,
            self.sprites.clone(),
            self.banks.clone(),
            self.active_spr_bank.clone(),
            self.active_map_bank.clone(),
            temp_tilemap.clone(),
            self.emoji_atlas.clone(),
            self.bitmap_font.clone(),
            self.draw_state.clone(),
            self.config.clone(),
            self.headless,
        );
        register_sound_api(&mut new_vm, self.sound_bank.clone());

        new_vm
            .run()
            .map_err(|e| format!("Ruby top-level error on reload: {:?}", e))?;

        parse_ruby_sprites_global(&new_vm, &mut new_sprites_map, &self.emoji_atlas.borrow());
        parse_ruby_map_global(&new_vm, &mut temp_tilemap.borrow_mut());
        sound::parse_ruby_sounds_globals(&new_vm, &mut new_sfx_map, &mut new_music_map);
        {
            let mut bank = self.sound_bank.borrow_mut();
            // トップレベル実行中に積まれたサウンドコマンドは破棄し、BGM 状態を復元
            bank.pending_commands.truncate(prev_pending_len);
            bank.current_music_id = prev_music_id;
            bank.update_definitions(new_sfx_map, new_music_map);
            // 再生中 BGM の定義が書き換わっていたら新しい内容で再生し直す
            if let Some(id) = prev_music_id {
                let new_spec = bank.music.get(&id).map(|m| m.spec.clone());
                if new_spec != prev_music_spec {
                    if new_spec.is_some() {
                        bank.queue_play_music(id, true, 1.0);
                    } else {
                        bank.queue_stop_music();
                    }
                }
            }
        }
        if !self.headless {
            for sprite in new_sprites_map.values_mut() {
                sprite.build_texture();
            }
            for bank in new_banks_map.values_mut() {
                bank.build_texture();
            }
        }
        *self.sprites.borrow_mut() = new_sprites_map;
        *self.banks.borrow_mut() = new_banks_map;
        *self.active_spr_bank.borrow_mut() = 0;
        *self.active_map_bank.borrow_mut() = 0;

        let new_initial_map = temp_tilemap.borrow().clone();
        if new_initial_map != self.initial_tail_map {
            *self.tilemap.borrow_mut() = new_initial_map.clone();
            self.initial_tail_map = new_initial_map;
        }
        // 新VMの mget / mset / map が self.tilemap を参照するように再登録
        register_engine_api(
            &mut new_vm,
            self.sprites.clone(),
            self.banks.clone(),
            self.active_spr_bank.clone(),
            self.active_map_bank.clone(),
            self.tilemap.clone(),
            self.emoji_atlas.clone(),
            self.bitmap_font.clone(),
            self.draw_state.clone(),
            self.config.clone(),
            self.headless,
        );

        let new_initial_globals = snapshot_globals(&new_vm);

        // 以前のVMから現在のグローバル変数を引き継ぐ
        for (name, live_val) in &self.vm.globals {
            if matches!(name.as_str(), "$SPRITES" | "$MAP" | "$SFX" | "$MUSIC") {
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

    pub fn call_update_result(&mut self) -> Result<(), String> {
        mrb_funcall(&mut self.vm, None, "update", &[])
            .map(|_| ())
            .map_err(|e| format!("{:?}", e))
    }

    pub fn call_update(&mut self) {
        if let Err(e) = self.call_update_result() {
            eprintln!("Ruby error in `update`: {}", e);
        }
    }

    pub fn call_draw_result(&mut self) -> Result<(), String> {
        if !self.headless {
            apply_gl_scissor(self.draw_state.borrow().clip);
        }
        let res = mrb_funcall(&mut self.vm, None, "draw", &[])
            .map(|_| ())
            .map_err(|e| format!("{:?}", e));
        if !self.headless {
            apply_gl_scissor(None);
        }
        res
    }

    pub fn call_draw(&mut self) {
        if let Err(e) = self.call_draw_result() {
            eprintln!("Ruby error in `draw`: {}", e);
        }
    }

    /// `@SFX` / `@MUSIC` 定義とプリセットのサウンドを事前ロードする（初回再生の遅延防止）
    pub async fn preload_audio(&mut self) {
        if self.headless {
            return;
        }
        let bank = self.sound_bank.clone();
        bank.borrow_mut().preload_all().await;
    }

    /// フレーム中に `sfx` / `music` で積まれたコマンドを実際に再生する
    pub async fn process_audio(&mut self) {
        if self.headless {
            self.sound_bank.borrow_mut().pending_commands.clear();
            return;
        }
        let bank = self.sound_bank.clone();
        bank.borrow_mut().process_audio().await;
    }
}

// ==========================================
// ウィンドウ & 描画ループ共通処理
// ==========================================
pub fn window_conf_with_title_and_size(title: &str, w: i32, h: i32) -> Conf {
    Conf {
        window_title: title.to_owned(),
        window_width: w,
        window_height: h,
        window_resizable: true,
        ..Default::default()
    }
}

pub fn window_conf_with_title(title: &str) -> Conf {
    window_conf_with_title_and_size(title, WINDOW_WIDTH, WINDOW_HEIGHT)
}

pub fn create_virtual_screen(w: u32, h: u32) -> (RenderTarget, Camera2D) {
    let rt = render_target(w, h);
    rt.texture.set_filter(FilterMode::Nearest);

    let mut cam =
        Camera2D::from_display_rect(Rect::new(0.0, 0.0, w as f32, h as f32));
    cam.render_target = Some(rt.clone());
    (rt, cam)
}

pub fn present_virtual_screen(
    render_target: &RenderTarget,
    virt_w: u32,
    virt_h: u32,
    reload_banner_frames: u32,
    show_fps: bool,
) {
    apply_gl_scissor(None);
    set_default_camera();
    clear_background(BLACK);

    let win_w = screen_width();
    let win_h = screen_height();
    let scale = (win_w / virt_w as f32).min(win_h / virt_h as f32);
    let draw_w = virt_w as f32 * scale;
    let draw_h = virt_h as f32 * scale;
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

    if show_fps {
        let fps_text = format!("FPS: {}", get_fps());
        let fps_w = 64.0;
        let fps_h = 18.0;
        let box_x = (offset_x + draw_w - fps_w - 6.0).max(0.0);
        let box_y = (offset_y + draw_h - fps_h - 6.0).max(0.0);
        draw_rectangle(box_x, box_y, fps_w, fps_h, Color::new(0.0, 0.0, 0.0, 0.75));
        draw_text(
            &fps_text,
            box_x + 6.0,
            box_y + 13.0,
            14.0,
            palette_color(11),
        );
    }
}

// ==========================================
// ネイティブ環境エントリポイント (`uk` CLI)
// ==========================================
#[cfg(not(target_arch = "wasm32"))]
async fn run_native_with_hot_reload(
    script_path: std::path::PathBuf,
    script_args: Vec<String>,
    initial_source: String,
    initial_tail: String,
    initial_mrb: Vec<u8>,
) {
    let initial_config = parse_config_from_source(&initial_source);
    let mut runtime = match GameRuntime::new_with_args(&initial_tail, &initial_mrb, false, &script_args) {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("{}", e);
            return;
        }
    };
    if initial_config != AppConfig::default() {
        let mut cfg = runtime.config.borrow_mut();
        *cfg = initial_config;
        runtime.draw_state.borrow_mut().screen_w = cfg.screen_width as i32;
        runtime.draw_state.borrow_mut().screen_h = cfg.screen_height as i32;
    }

    let mut cur_virt_w = runtime.config.borrow().screen_width;
    let mut cur_virt_h = runtime.config.borrow().screen_height;
    let (mut render_target, mut virtual_camera) = create_virtual_screen(cur_virt_w, cur_virt_h);
    runtime.preload_audio().await;
    let mut last_snapshot = bundle::get_script_and_resources_snapshot(&script_path);
    let mut frame_count: u64 = 0;
    let mut reload_banner_frames: u32 = 0;

    loop {
        frame_count = frame_count.wrapping_add(1);

        // 15フレーム (~0.25秒) ごとにスクリプトファイルおよび外部リソースの変更を検知してホットリロード
        if frame_count.is_multiple_of(15) {
            let current_snapshot = bundle::get_script_and_resources_snapshot(&script_path);
            if current_snapshot != last_snapshot {
                last_snapshot = current_snapshot;
                match cli::compile_ruby_script_file(&script_path) {
                    Ok((new_source, new_tail, new_mrb)) => {
                        let new_parsed_config = parse_config_from_source(&new_source);
                        if new_parsed_config != AppConfig::default() {
                            let mut cfg = runtime.config.borrow_mut();
                            *cfg = new_parsed_config;
                        }
                        match runtime.hot_reload(&new_tail, &new_mrb) {
                            Ok(()) => {
                                runtime.preload_audio().await;
                                println!("[uk run] Hot-reloaded `{}`", script_path.display());
                                reload_banner_frames = 60;
                                let (new_w, new_h) = {
                                    let cfg = runtime.config.borrow();
                                    (cfg.screen_width, cfg.screen_height)
                                };
                                if new_w != cur_virt_w || new_h != cur_virt_h {
                                    cur_virt_w = new_w;
                                    cur_virt_h = new_h;
                                    let (rt, cam) = create_virtual_screen(cur_virt_w, cur_virt_h);
                                    render_target = rt;
                                    virtual_camera = cam;
                                }
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

        if is_key_pressed(KeyCode::F3) {
            let mut cfg = runtime.config.borrow_mut();
            cfg.show_fps = !cfg.show_fps;
        }

        runtime.call_update();
        runtime.process_audio().await;

        set_camera(&virtual_camera);
        runtime.call_draw();

        let show_fps = runtime.config.borrow().show_fps;
        present_virtual_screen(&render_target, cur_virt_w, cur_virt_h, reload_banner_frames, show_fps);
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

    let (virt_w, virt_h) = {
        let cfg = runtime.config.borrow();
        (cfg.screen_width, cfg.screen_height)
    };
    let (render_target, virtual_camera) = create_virtual_screen(virt_w, virt_h);
    runtime.preload_audio().await;

    loop {
        if is_key_pressed(KeyCode::F3) {
            let mut cfg = runtime.config.borrow_mut();
            cfg.show_fps = !cfg.show_fps;
        }

        runtime.call_update();
        runtime.process_audio().await;

        set_camera(&virtual_camera);
        runtime.call_draw();

        let show_fps = runtime.config.borrow().show_fps;
        present_virtual_screen(&render_target, virt_w, virt_h, 0, show_fps);

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
        cli::CliAction::Pack {
            script_path,
            output_path,
        } => {
            if let Err(err) = cli::cmd_pack(&script_path, output_path.as_deref()) {
                eprintln!("Error: {}", err);
                std::process::exit(1);
            }
        }
        cli::CliAction::Unpack { script_path } => {
            if let Err(err) = cli::cmd_unpack(&script_path) {
                eprintln!("Error: {}", err);
                std::process::exit(1);
            }
        }
        cli::CliAction::Run {
            script_path,
            script_args,
        } => {
            let (initial_source, tail_data, mrb_bytes) =
                match cli::compile_ruby_script_file(&script_path) {
                    Ok(res) => res,
                    Err(err) => {
                        eprintln!("Error: {}", err);
                        std::process::exit(1);
                    }
                };
            let parsed_cfg = parse_config_from_source(&initial_source);
            let title = if parsed_cfg.title != "Usakame Retro Engine" {
                parsed_cfg.title.clone()
            } else {
                format!("Usakame - {}", script_path.display())
            };
            macroquad::Window::from_config(
                window_conf_with_title_and_size(&title, parsed_cfg.window_width(), parsed_cfg.window_height()),
                run_native_with_hot_reload(script_path, script_args, initial_source, tail_data, mrb_bytes),
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
    window_conf_with_title("Usakame Retro Engine")
}

#[cfg(target_arch = "wasm32")]
#[macroquad::main(window_conf_wasm)]
async fn main() {
    // `uk browser` サーバーから配信される `/__uk_bundle.bin` を優先取得し、無ければ埋め込みデータへフォールバック
    let (tail_data, mrb_bytes) = match macroquad::file::load_file("__uk_bundle.bin").await {
        Ok(bytes) => bundle::unpack_bundle_from_bytes(&bytes).unwrap_or_else(|| {
            let (_, tail) = bundle::split_ruby_source_and_tail(EMBEDDED_SOURCE);
            (tail.to_string(), EMBEDDED_MRB.to_vec())
        }),
        Err(_) => {
            let (_, tail) = bundle::split_ruby_source_and_tail(EMBEDDED_SOURCE);
            (tail.to_string(), EMBEDDED_MRB.to_vec())
        }
    };

    let mut runtime = GameRuntime::new(&tail_data, &mrb_bytes, false)
        .expect("Failed to initialize WASM GameRuntime");
    let mut cur_virt_w = runtime.config.borrow().screen_width;
    let mut cur_virt_h = runtime.config.borrow().screen_height;
    let (mut render_target, mut virtual_camera) = create_virtual_screen(cur_virt_w, cur_virt_h);
    runtime.preload_audio().await;
    let mut reload_banner_frames: u32 = 0;

    loop {
        if WASM_RELOAD_REQUESTED.swap(false, std::sync::atomic::Ordering::SeqCst) {
            let url = format!("__uk_bundle.bin?t={}", macroquad::time::get_time());
            if let Ok(bytes) = macroquad::file::load_file(&url).await
                && let Some((new_tail, new_mrb)) = bundle::unpack_bundle_from_bytes(&bytes)
            {
                match runtime.hot_reload(&new_tail, &new_mrb) {
                    Ok(()) => {
                        runtime.preload_audio().await;
                        reload_banner_frames = 60;
                        let (new_w, new_h) = {
                            let cfg = runtime.config.borrow();
                            (cfg.screen_width, cfg.screen_height)
                        };
                        if new_w != cur_virt_w || new_h != cur_virt_h {
                            cur_virt_w = new_w;
                            cur_virt_h = new_h;
                            let (rt, cam) = create_virtual_screen(cur_virt_w, cur_virt_h);
                            render_target = rt;
                            virtual_camera = cam;
                        }
                    }
                    Err(e) => {
                        eprintln!("Hot-reload error in browser: {}", e);
                    }
                }
            }
        }

        runtime.call_update();
        runtime.process_audio().await;

        set_camera(&virtual_camera);
        runtime.call_draw();

        let show_fps = runtime.config.borrow().show_fps;
        present_virtual_screen(&render_target, cur_virt_w, cur_virt_h, reload_banner_frames, show_fps);
        reload_banner_frames = reload_banner_frames.saturating_sub(1);

        next_frame().await;
    }
}

// ==========================================
// テスト
// ==========================================
#[cfg(test)]
mod tests;

