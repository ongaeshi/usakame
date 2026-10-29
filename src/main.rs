pub mod bundle;
#[cfg(not(target_arch = "wasm32"))]
pub mod cli;
#[cfg(not(target_arch = "wasm32"))]
pub mod llm;
pub mod emoji;
pub mod sound;
pub mod config;
pub mod font;

pub use config::*;
pub use font::*;

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use macroquad::prelude::*;
use mrubyedge::rite;
use mrubyedge::yamrb::helpers::{
    mrb_define_cmethod, mrb_define_module_cmethod, mrb_define_singleton_cmethod, mrb_funcall,
};
use mrubyedge::yamrb::value::{RObject, RValue};
use mrubyedge::yamrb::vm::VM;

// ==========================================
// Base64 エンコード / デコード
// ==========================================
pub use bundle::{decode_base64, encode_base64};

// ==========================================
// リソース管理 & 描画処理
// ==========================================
pub type PaletteRgba = [[u8; 4]; 16];

#[derive(Clone)]
pub struct SpriteData {
    pub width: u16,
    pub height: u16,
    /// RGBA ピクセルデータ (width * height * 4 bytes)
    pub rgba: Vec<u8>,
    /// パレットインデックスデータ (0..15 or None)
    pub indexed: Vec<Option<u8>>,
    /// 関連付けられたパレットID (デフォルト 0)
    pub palette_id: i32,
    pub texture: Option<Texture2D>,
    /// パレット置換・透過設定 `(pal_map, palt_mask, palette_rgba)` ごとの変換済みテクスチャキャッシュ
    pub pal_cache: RefCell<HashMap<([u8; 16], u16, PaletteRgba), Texture2D>>,
}

impl SpriteData {
    pub fn from_rgba(width: u16, height: u16, rgba: Vec<u8>) -> Self {
        let total_pixels = width as usize * height as usize;
        let mut indexed = Vec::with_capacity(total_pixels);
        for px in rgba.chunks_exact(4) {
            indexed.push(rgba_to_palette_opt(px));
        }
        Self {
            width,
            height,
            rgba,
            indexed,
            palette_id: 0,
            texture: None,
            pal_cache: RefCell::new(HashMap::new()),
        }
    }

    /// 16進数テキスト行 (`0`..`F`, `.` は透明) からスプライトを生成する（基本 16x16）
    pub fn from_lines(lines: &[&str]) -> Self {
        Self::from_lines_with_palette_and_dims(lines, &PALETTE_RGBA, 0, None)
    }

    /// 指定したパレットRGBAを使って16進数テキスト行からスプライトを生成する
    pub fn from_lines_with_palette(lines: &[&str], palette: &PaletteRgba, palette_id: i32) -> Self {
        Self::from_lines_with_palette_and_dims(lines, palette, palette_id, None)
    }

    /// 指定したパレットRGBAおよび指定サイズを使って16進数テキスト行からスプライトを生成する
    pub fn from_lines_with_palette_and_dims(
        lines: &[&str],
        palette: &PaletteRgba,
        palette_id: i32,
        explicit_dims: Option<(u16, u16)>,
    ) -> Self {
        let (width, height) = if let Some((w, h)) = explicit_dims {
            (w.max(1) as usize, h.max(1) as usize)
        } else {
            let max_cols = lines
                .iter()
                .map(|l| l.chars().count())
                .max()
                .unwrap_or(SPRITE_SIZE);
            let w = max_cols.max(SPRITE_SIZE);
            let h = lines.len().max(SPRITE_SIZE);
            (w, h)
        };
        let mut rgba = vec![0u8; width * height * 4];
        let mut indexed = vec![None; width * height];

        for (y, line) in lines.iter().take(height).enumerate() {
            for (x, ch) in line.chars().take(width).enumerate() {
                let color_idx = match ch {
                    '.' | ' ' => None,
                    c if c.is_ascii_hexdigit() => c.to_digit(16).map(|d| d as usize),
                    _ => None,
                };
                let px_idx = y * width + x;
                if let Some(idx) = color_idx {
                    let off = px_idx * 4;
                    rgba[off..off + 4].copy_from_slice(&palette[idx & 0x0F]);
                    indexed[px_idx] = Some((idx & 0x0F) as u8);
                }
            }
        }

        Self {
            width: width as u16,
            height: height as u16,
            rgba,
            indexed,
            palette_id,
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

    /// パレット置換マップ `pal_map`、透過ビットマスク `palt_mask`、およびターゲットパレット `target_palette` を適用した RGBA ピクセル配列を生成する
    pub fn apply_palette(&self, pal_map: &[u8; 16], palt_mask: u16, target_palette: &PaletteRgba) -> Vec<u8> {
        let is_identity_pal = *pal_map == DEFAULT_PAL_MAP && *target_palette == PALETTE_RGBA;
        if is_identity_pal && palt_mask == 0 {
            return self.rgba.clone();
        }
        let mut out = self.rgba.clone();
        for (i, px) in out.chunks_exact_mut(4).enumerate() {
            if px[3] == 0 {
                continue;
            }
            let src_idx = if let Some(indexed) = self.indexed.get(i).copied().flatten() {
                indexed as usize
            } else {
                nearest_palette_index(px[0], px[1], px[2])
            };
            if (palt_mask & (1 << src_idx)) != 0 {
                px[0] = 0;
                px[1] = 0;
                px[2] = 0;
                px[3] = 0;
            } else {
                let dst_idx = (pal_map[src_idx] & 0x0F) as usize;
                let dst_rgba = target_palette[dst_idx];
                px[0] = dst_rgba[0];
                px[1] = dst_rgba[1];
                px[2] = dst_rgba[2];
                px[3] = dst_rgba[3];
            }
        }
        out
    }

    /// パレット変換済みの `Texture2D` を取得またはオンデマンド生成してキャッシュから返す
    pub fn get_or_build_pal_texture(
        &self,
        pal_map: &[u8; 16],
        palt_mask: u16,
        target_palette: &PaletteRgba,
    ) -> Option<Texture2D> {
        let is_identity_pal = *pal_map == DEFAULT_PAL_MAP && *target_palette == PALETTE_RGBA;
        if is_identity_pal && palt_mask == 0 {
            return self.texture.clone();
        }
        let key = (*pal_map, palt_mask, *target_palette);
        if let Some(tex) = self.pal_cache.borrow().get(&key) {
            return Some(tex.clone());
        }
        let transformed_rgba = self.apply_palette(pal_map, palt_mask, target_palette);
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
    /// シートの有効サイズ（ピクセル単位、デフォルト 256x256、@SHEET 192x176 等では 192x176）
    pub sheet_width: u16,
    pub sheet_height: u16,
    /// RGBA ピクセルデータ (256 * 256 * 4 bytes)
    pub rgba: Vec<u8>,
    /// パレットインデックスデータ (256 * 256 elements, 0..15 or None)
    pub indexed: Vec<Option<u8>>,
    pub texture: RefCell<Option<Texture2D>>,
    pub dirty: std::cell::Cell<bool>,
    /// パレット置換・透過設定ごとの変換済みテクスチャキャッシュ
    pub pal_cache: RefCell<HashMap<([u8; 16], u16, PaletteRgba), Texture2D>>,
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
            sheet_width: BANK_WIDTH as u16,
            sheet_height: BANK_HEIGHT as u16,
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
        bank.sheet_width = copy_w as u16;
        bank.sheet_height = copy_h as u16;
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
        self.write_tile(slot_id, (self.sheet_width / 16).max(1) as usize, src_rgba);
    }

    pub fn write_16x16_indexed(&mut self, slot_id: usize, src_rgba: &[u8], src_indexed: &[Option<u8>]) {
        self.write_tile_indexed(slot_id, (self.sheet_width / 16).max(1) as usize, src_rgba, src_indexed);
    }

    pub fn write_tile(&mut self, slot_id: usize, cols: usize, src_rgba: &[u8]) {
        self.write_tile_indexed_internal(slot_id, cols, src_rgba, None);
    }

    pub fn write_tile_indexed(&mut self, slot_id: usize, cols: usize, src_rgba: &[u8], src_indexed: &[Option<u8>]) {
        self.write_tile_indexed_internal(slot_id, cols, src_rgba, Some(src_indexed));
    }

    pub fn write_rect_indexed(
        &mut self,
        slot_x: usize,
        slot_y: usize,
        w: usize,
        h: usize,
        src_rgba: &[u8],
        src_indexed: Option<&[Option<u8>]>,
    ) {
        if slot_x >= BANK_WIDTH || slot_y >= BANK_HEIGHT || w == 0 || h == 0 {
            return;
        }
        let copy_w = w.min(BANK_WIDTH - slot_x);
        let copy_h = h.min(BANK_HEIGHT - slot_y);

        for y in 0..copy_h {
            let src_start = y * w * 4;
            let src_end = src_start + copy_w * 4;
            let dst_start = ((slot_y + y) * BANK_WIDTH + slot_x) * 4;
            let dst_end = dst_start + copy_w * 4;
            if src_end <= src_rgba.len() && dst_end <= self.rgba.len() {
                self.rgba[dst_start..dst_end].copy_from_slice(&src_rgba[src_start..src_end]);
            }
            for x in 0..copy_w {
                let px_idx = y * w + x;
                let col = if let Some(indexed) = src_indexed {
                    indexed.get(px_idx).copied().flatten()
                } else {
                    let p_off = src_start + x * 4;
                    if p_off + 4 <= src_rgba.len() {
                        rgba_to_palette_opt(&src_rgba[p_off..p_off + 4])
                    } else {
                        None
                    }
                };
                self.indexed[(slot_y + y) * BANK_WIDTH + slot_x + x] = col;
            }
        }
        self.dirty.set(true);
        self.pal_cache.borrow_mut().clear();
    }

    fn write_tile_indexed_internal(
        &mut self,
        slot_id: usize,
        cols: usize,
        src_rgba: &[u8],
        src_indexed: Option<&[Option<u8>]>,
    ) {
        let cols = cols.max(1);
        let slot_x = (slot_id % cols) * 16;
        let slot_y = (slot_id / cols) * 16;
        self.write_rect_indexed(slot_x, slot_y, 16, 16, src_rgba, src_indexed);
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

    pub fn apply_palette(&self, pal_map: &[u8; 16], palt_mask: u16, target_palette: &PaletteRgba) -> Vec<u8> {
        let is_identity_pal = *pal_map == DEFAULT_PAL_MAP && *target_palette == PALETTE_RGBA;
        if is_identity_pal && palt_mask == 0 {
            return self.rgba.clone();
        }
        let mut out = self.rgba.clone();
        for (i, px) in out.chunks_exact_mut(4).enumerate() {
            if px[3] == 0 {
                continue;
            }
            let src_idx = if let Some(indexed) = self.indexed.get(i).copied().flatten() {
                indexed as usize
            } else {
                nearest_palette_index(px[0], px[1], px[2])
            };
            if (palt_mask & (1 << src_idx)) != 0 {
                px[0] = 0;
                px[1] = 0;
                px[2] = 0;
                px[3] = 0;
            } else {
                let dst_idx = (pal_map[src_idx] & 0x0F) as usize;
                let dst_rgba = target_palette[dst_idx];
                px[0] = dst_rgba[0];
                px[1] = dst_rgba[1];
                px[2] = dst_rgba[2];
                px[3] = dst_rgba[3];
            }
        }
        out
    }

    pub fn get_or_build_pal_texture(
        &self,
        pal_map: &[u8; 16],
        palt_mask: u16,
        target_palette: &PaletteRgba,
    ) -> Option<Texture2D> {
        self.ensure_texture();
        let is_identity_pal = *pal_map == DEFAULT_PAL_MAP && *target_palette == PALETTE_RGBA;
        if is_identity_pal && palt_mask == 0 {
            return self.texture.borrow().clone();
        }
        let key = (*pal_map, palt_mask, *target_palette);
        if let Some(tex) = self.pal_cache.borrow().get(&key) {
            return Some(tex.clone());
        }
        let transformed_rgba = self.apply_palette(pal_map, palt_mask, target_palette);
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
/// 戻り値: (登録タイル数, シート幅, シート高さ)
pub fn decode_png_sheet_into_sprites(
    b64_text: &str,
    start_id: i32,
    tile_w: u16,
    tile_h: u16,
    sprites: &mut HashMap<i32, SpriteData>,
) -> Result<(usize, u16, u16), String> {
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

    Ok((count, img.width, img.height))
}

#[derive(Clone, Copy)]
enum ResourceBlockKind {
    TextSprite(i32, Option<i32>, Option<(u16, u16)>),
    Base64Sprite(i32),
    PngSheet {
        start_id: i32,
        tile_w: u16,
        tile_h: u16,
        sheet_w: Option<u16>,
        sheet_h: Option<u16>,
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

/// パレット行（例: "3: #008840", "B = #58F878", "#008840 #112233"）を解析してパレットに適用する
fn parse_palette_line(line: &str, pal: &mut PaletteRgba, next_auto_idx: &mut usize) {
    let mut parts: Vec<&str> = Vec::new();
    for tok in line.split_whitespace() {
        if tok.starts_with('#') && config::parse_hex_color(tok).is_none() {
            // # から始まりカラーコードでないものはコメント行とみなす
            break;
        }
        parts.push(tok);
    }
    if parts.is_empty() {
        return;
    }

    let mut i = 0;
    while i < parts.len() {
        let tok = parts[i];

        // 1. "idx:col" や "idx=col"
        if let Some((idx_str, col_str)) = tok.split_once(':').or_else(|| tok.split_once('=')) {
            let idx_str = idx_str.trim();
            let col_str = col_str.trim();
            let idx_opt = idx_str
                .parse::<usize>()
                .ok()
                .or_else(|| usize::from_str_radix(idx_str, 16).ok());

            if let Some(idx) = idx_opt {
                if idx < 16 {
                    if !col_str.is_empty() {
                        if let Some(rgba) = config::parse_hex_color(col_str) {
                            pal[idx] = rgba;
                            *next_auto_idx = idx + 1;
                            i += 1;
                            continue;
                        }
                    } else if i + 1 < parts.len() {
                        // "3:" の次に "#008840" が来るケース
                        let next_tok = parts[i + 1];
                        if let Some(rgba) = config::parse_hex_color(next_tok) {
                            pal[idx] = rgba;
                            *next_auto_idx = idx + 1;
                            i += 2;
                            continue;
                        }
                    }
                }
            }
        }

        // 2. "idx" の次に "#008840" が来るケース（例: "3 #008840" または "3 = #008840"）
        if let Ok(idx) = tok.parse::<usize>().or_else(|_| usize::from_str_radix(tok, 16)) {
            if idx < 16 {
                let mut next_i = i + 1;
                if next_i < parts.len() && (parts[next_i] == ":" || parts[next_i] == "=") {
                    next_i += 1;
                }
                if next_i < parts.len() {
                    if let Some(rgba) = config::parse_hex_color(parts[next_i]) {
                        pal[idx] = rgba;
                        *next_auto_idx = idx + 1;
                        i = next_i + 1;
                        continue;
                    }
                }
            }
        }

        // 3. 単独カラーコード（例: "#008840", "0x008840"）
        if let Some(rgba) = config::parse_hex_color(tok) {
            if *next_auto_idx < 16 {
                pal[*next_auto_idx] = rgba;
                *next_auto_idx += 1;
                i += 1;
                continue;
            }
        }

        i += 1;
    }
}

/// `data_section` 内の `@PALETTE [id]` ブロックを走査し、IDごとの16色パレットを抽出する
pub fn parse_tail_palettes(data_section: &str) -> HashMap<i32, PaletteRgba> {
    let mut palettes = HashMap::new();
    let mut current_id: Option<i32> = None;
    let mut current_pal = PALETTE_RGBA;
    let mut next_auto_idx = 0usize;

    for raw_line in data_section.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }

        if let Some(rest) = line.strip_prefix("@PALETTE") {
            if let Some(id) = current_id {
                palettes.insert(id, current_pal);
            }
            let mut parts = rest.split_whitespace();
            let mut pal_id = 1;
            let mut start_idx = 0;

            if let Some(first) = parts.next() {
                if let Ok(id) = first.parse::<i32>() {
                    pal_id = id;
                    start_idx = 1;
                }
            }
            if pal_id == 0 {
                eprintln!("[warn] @PALETTE 0 is reserved as the system palette (PICO-8 16-color) and cannot be overridden. Custom palettes must use ID >= 1.");
                current_id = None;
                continue;
            }
            current_id = Some(pal_id);
            current_pal = palettes.get(&pal_id).copied().unwrap_or(PALETTE_RGBA);
            next_auto_idx = 0;

            let all_parts: Vec<&str> = rest.split_whitespace().collect();
            let inline_line = all_parts[start_idx..].join(" ");
            parse_palette_line(&inline_line, &mut current_pal, &mut next_auto_idx);
            continue;
        }

        if current_id.is_none() {
            continue;
        }

        if line.starts_with('@') {
            if let Some(id) = current_id.take() {
                palettes.insert(id, current_pal);
            }
            continue;
        }

        parse_palette_line(line, &mut current_pal, &mut next_auto_idx);
    }

    if let Some(id) = current_id {
        palettes.insert(id, current_pal);
    }

    palettes.insert(0, PALETTE_RGBA);

    palettes
}

fn flush_resource_block(
    kind: Option<ResourceBlockKind>,
    lines: &mut Vec<String>,
    sprites: &mut HashMap<i32, SpriteData>,
    banks: &mut HashMap<i32, BankData>,
    palettes: &HashMap<i32, PaletteRgba>,
    occupied_slots: &mut HashMap<(usize, usize), (i32, u16, u16)>,
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
        ResourceBlockKind::TextSprite(id, pal_id_opt, dims_opt) => {
            let pal_id = pal_id_opt.unwrap_or(0);
            let pal = palettes.get(&pal_id).unwrap_or(&PALETTE_RGBA);
            let refs: Vec<&str> = lines.iter().map(|s| s.as_str()).collect();
            let sp = SpriteData::from_lines_with_palette_and_dims(&refs, pal, pal_id, dims_opt);
            if (0..=255).contains(&id) {
                let slot_x = (id as usize % 16) * 16;
                let slot_y = (id as usize / 16) * 16;
                let tiles_w = (sp.width as usize + 15) / 16;
                let tiles_h = (sp.height as usize + 15) / 16;
                let start_tx = slot_x / 16;
                let start_ty = slot_y / 16;

                for ty in start_ty..start_ty + tiles_h {
                    for tx in start_tx..start_tx + tiles_w {
                        if let Some(&(prev_id, prev_w, prev_h)) = occupied_slots.get(&(tx, ty)) {
                            if prev_id != id {
                                eprintln!(
                                    "Warning: @SPRITE {} ({}x{}) overlaps with @SPRITE {} ({}x{}) at tile ({}, {})",
                                    id, sp.width, sp.height, prev_id, prev_w, prev_h, tx, ty
                                );
                            }
                        } else {
                            occupied_slots.insert((tx, ty), (id, sp.width, sp.height));
                        }
                    }
                }

                let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                bank0.write_rect_indexed(
                    slot_x,
                    slot_y,
                    sp.width as usize,
                    sp.height as usize,
                    &sp.rgba,
                    Some(&sp.indexed),
                );
            }
            sprites.insert(id, sp);
        }
        ResourceBlockKind::Base64Sprite(id) => {
            let joined = lines.join("");
            match SpriteData::from_base64(&joined) {
                Ok(sp) => {
                    if (0..=255).contains(&id) {
                        let slot_x = (id as usize % 16) * 16;
                        let slot_y = (id as usize / 16) * 16;
                        let tiles_w = (sp.width as usize + 15) / 16;
                        let tiles_h = (sp.height as usize + 15) / 16;
                        let start_tx = slot_x / 16;
                        let start_ty = slot_y / 16;

                        for ty in start_ty..start_ty + tiles_h {
                            for tx in start_tx..start_tx + tiles_w {
                                if let Some(&(prev_id, prev_w, prev_h)) = occupied_slots.get(&(tx, ty)) {
                                    if prev_id != id {
                                        eprintln!(
                                            "Warning: @SPRITE {} ({}x{}) overlaps with @SPRITE {} ({}x{}) at tile ({}, {})",
                                            id, sp.width, sp.height, prev_id, prev_w, prev_h, tx, ty
                                        );
                                    }
                                } else {
                                    occupied_slots.insert((tx, ty), (id, sp.width, sp.height));
                                }
                            }
                        }

                        let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                        bank0.write_rect_indexed(
                            slot_x,
                            slot_y,
                            sp.width as usize,
                            sp.height as usize,
                            &sp.rgba,
                            Some(&sp.indexed),
                        );
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
            sheet_w,
            sheet_h,
        } => {
            let joined = lines.join("");
            match decode_png_sheet_into_sprites(&joined, start_id, tile_w, tile_h, sprites) {
                Err(e) => {
                    eprintln!(
                        "Warning: Failed to decode @SHEET starting at {}: {}",
                        start_id, e
                    );
                }
                Ok((_count, img_w, img_h)) => {
                    let final_w = sheet_w.unwrap_or(img_w);
                    let final_h = sheet_h.unwrap_or(img_h);
                    let cols = (final_w / tile_w.max(1)).max(1) as usize;
                    let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                    bank0.sheet_width = final_w;
                    bank0.sheet_height = final_h;
                    for (id, sp) in sprites.iter() {
                        if (0..=255).contains(id) && *id >= start_id {
                            bank0.write_tile((*id - start_id) as usize, cols, &sp.rgba);
                        }
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

/// `__END__` 以降のスプライトおよびバンク定義、パレット定義をパースする
pub fn parse_tail_resources_full(
    data_section: &str,
    base_dir: Option<&Path>,
) -> (HashMap<i32, SpriteData>, HashMap<i32, BankData>, HashMap<i32, PaletteRgba>) {
    let palettes = parse_tail_palettes(data_section);
    let mut sprites = HashMap::new();
    let mut banks = HashMap::new();
    banks.insert(0, BankData::new(0));
    let mut occupied_slots: HashMap<(usize, usize), (i32, u16, u16)> = HashMap::new();

    let mut current_kind: Option<ResourceBlockKind> = None;
    let mut current_lines: Vec<String> = Vec::new();
    let mut emoji_atlas: Option<emoji::EmojiAtlas> = None;

    for raw_line in data_section.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some(rest) = line.strip_prefix("@BANK") {
            flush_resource_block(
                current_kind.take(),
                &mut current_lines,
                &mut sprites,
                &mut banks,
                &palettes,
                &mut occupied_slots,
                base_dir,
            );
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
            flush_resource_block(
                current_kind.take(),
                &mut current_lines,
                &mut sprites,
                &mut banks,
                &palettes,
                &mut occupied_slots,
                base_dir,
            );
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(id) = id_str.parse::<i32>()
            {
                let inline_b64: String = parts.collect::<Vec<_>>().join("");
                if !inline_b64.is_empty() {
                    if let Ok(sp) = SpriteData::from_base64(&inline_b64) {
                        if (0..=255).contains(&id) {
                            let slot_x = (id as usize % 16) * 16;
                            let slot_y = (id as usize / 16) * 16;
                            let tiles_w = (sp.width as usize + 15) / 16;
                            let tiles_h = (sp.height as usize + 15) / 16;
                            let start_tx = slot_x / 16;
                            let start_ty = slot_y / 16;

                            for ty in start_ty..start_ty + tiles_h {
                                for tx in start_tx..start_tx + tiles_w {
                                    if let Some(&(prev_id, prev_w, prev_h)) = occupied_slots.get(&(tx, ty)) {
                                        if prev_id != id {
                                            eprintln!(
                                                "Warning: @SPRITE {} ({}x{}) overlaps with @SPRITE {} ({}x{}) at tile ({}, {})",
                                                id, sp.width, sp.height, prev_id, prev_w, prev_h, tx, ty
                                            );
                                        }
                                    } else {
                                        occupied_slots.insert((tx, ty), (id, sp.width, sp.height));
                                    }
                                }
                            }

                            let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                            bank0.write_rect_indexed(
                                slot_x,
                                slot_y,
                                sp.width as usize,
                                sp.height as usize,
                                &sp.rgba,
                                Some(&sp.indexed),
                            );
                        }
                        sprites.insert(id, sp);
                    }
                } else {
                    current_kind = Some(ResourceBlockKind::Base64Sprite(id));
                }
            }
        } else if let Some(rest) = line.strip_prefix("@SHEET") {
            flush_resource_block(
                current_kind.take(),
                &mut current_lines,
                &mut sprites,
                &mut banks,
                &palettes,
                &mut occupied_slots,
                base_dir,
            );
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(start_id) = id_str.parse::<i32>()
            {
                let mut tile_w = SPRITE_SIZE as u16;
                let mut tile_h = SPRITE_SIZE as u16;
                let mut sheet_w = None;
                let mut sheet_h = None;
                let mut file_path = None;
                let mut dims_tokens = Vec::new();
                for tok in parts {
                    if let Some(dims) = parse_tile_dims(tok) {
                        dims_tokens.push(dims);
                    } else if file_path.is_none() {
                        file_path = Some(tok.to_string());
                    }
                }

                if dims_tokens.len() >= 2 {
                    tile_w = dims_tokens[0].0;
                    tile_h = dims_tokens[0].1;
                    sheet_w = Some(dims_tokens[1].0);
                    sheet_h = Some(dims_tokens[1].1);
                } else if dims_tokens.len() == 1 {
                    let d = dims_tokens[0];
                    if d.0 > 32 || d.1 > 32 {
                        sheet_w = Some(d.0);
                        sheet_h = Some(d.1);
                    } else {
                        tile_w = d.0;
                        tile_h = d.1;
                    }
                }

                if let Some(path_str) = file_path {
                    let path_candidate = if let Some(dir) = base_dir {
                        dir.join(&path_str)
                    } else {
                        PathBuf::from(&path_str)
                    };
                    if path_candidate.is_file() {
                        if let Ok(bytes) = std::fs::read(&path_candidate) {
                            let b64 = encode_base64(&bytes);
                            match decode_png_sheet_into_sprites(&b64, start_id, tile_w, tile_h, &mut sprites) {
                                Err(e) => {
                                    eprintln!("Warning: Failed to decode @SHEET file {}: {}", path_candidate.display(), e);
                                }
                                Ok((_count, img_w, img_h)) => {
                                    let final_w = sheet_w.unwrap_or(img_w);
                                    let final_h = sheet_h.unwrap_or(img_h);
                                    let cols = (final_w / tile_w.max(1)).max(1) as usize;
                                    let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                                    bank0.sheet_width = final_w;
                                    bank0.sheet_height = final_h;
                                    for (id, sp) in sprites.iter() {
                                        if (0..=255).contains(id) && *id >= start_id {
                                            bank0.write_tile((*id - start_id) as usize, cols, &sp.rgba);
                                        }
                                    }
                                }
                            }
                            continue;
                        } else {
                            eprintln!("Warning: Failed to read @SHEET file: {}", path_candidate.display());
                        }
                    }
                }

                current_kind = Some(ResourceBlockKind::PngSheet {
                    start_id,
                    tile_w,
                    tile_h,
                    sheet_w,
                    sheet_h,
                });
            }
        } else if let Some(rest) = line.strip_prefix("@SPRITE") {
            flush_resource_block(
                current_kind.take(),
                &mut current_lines,
                &mut sprites,
                &mut banks,
                &palettes,
                &mut occupied_slots,
                base_dir,
            );
            let mut parts = rest.split_whitespace();
            if let Some(id_str) = parts.next()
                && let Ok(id) = id_str.parse::<i32>()
            {
                let remaining: Vec<&str> = parts.collect();
                let mut pal_id_opt = None;
                let mut dims_opt = None;
                let mut emoji_token = None;
                let mut is_dim = false;

                for tok in remaining {
                    if let Some(val_str) = tok
                        .strip_prefix("pal:")
                        .or_else(|| tok.strip_prefix("p:"))
                        .or_else(|| tok.strip_prefix("pal="))
                        .or_else(|| tok.strip_prefix("p="))
                    {
                        if let Ok(pid) = val_str.parse::<i32>() {
                            pal_id_opt = Some(pid);
                        }
                    } else if let Some(dims) = parse_tile_dims(tok) {
                        dims_opt = Some(dims);
                        is_dim = true;
                    } else if tok.chars().all(|c| c.is_ascii_digit()) {
                        is_dim = true;
                    } else if emoji_token.is_none() {
                        emoji_token = Some(tok);
                    }
                }

                if let Some(tok) = emoji_token && !is_dim {
                    let atlas = emoji_atlas.get_or_insert_with(emoji::EmojiAtlas::new);
                    if let Some(sp) = atlas.extract_sprite(tok) {
                        if (0..=255).contains(&id) {
                            let slot_x = (id as usize % 16) * 16;
                            let slot_y = (id as usize / 16) * 16;
                            occupied_slots.insert((slot_x / 16, slot_y / 16), (id, sp.width, sp.height));
                            let bank0 = banks.entry(0).or_insert_with(|| BankData::new(0));
                            bank0.write_16x16(id as usize, &sp.rgba);
                        }
                        sprites.insert(id, sp);
                    } else {
                        current_kind = Some(ResourceBlockKind::TextSprite(id, pal_id_opt, dims_opt));
                    }
                } else {
                    current_kind = Some(ResourceBlockKind::TextSprite(id, pal_id_opt, dims_opt));
                }
            }
        } else if line.starts_with('@') {
            flush_resource_block(
                current_kind.take(),
                &mut current_lines,
                &mut sprites,
                &mut banks,
                &palettes,
                &mut occupied_slots,
                base_dir,
            );
        } else if current_kind.is_some() {
            current_lines.push(line.to_string());
        }
    }

    flush_resource_block(
        current_kind.take(),
        &mut current_lines,
        &mut sprites,
        &mut banks,
        &palettes,
        &mut occupied_slots,
        base_dir,
    );
    (sprites, banks, palettes)
}

/// `__END__` 以降のスプライト定義をパースする（後方互換ラッパー）
pub fn parse_tail_resources(data_section: &str) -> HashMap<i32, SpriteData> {
    parse_tail_resources_full(data_section, None).0
}

/// タイルマップ管理構造体（1セル = 16x16 スプライト番号、`-1` は空タイル）
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Tilemap {
    pub cells: HashMap<(i32, i32), i32>,
    pub width: i32,
    pub height: i32,
}

fn parse_map_tile_token(tok: &str) -> i32 {
    if matches!(tok, "." | ".." | "_" | "-") {
        return -1;
    }
    if let Some(hex) = tok.strip_prefix("0x").or_else(|| tok.strip_prefix("0X")) {
        return i32::from_str_radix(hex, 16).unwrap_or(-1);
    }
    if let Ok(v) = tok.parse::<i32>() {
        return v;
    }
    i32::from_str_radix(tok, 16).unwrap_or(-1)
}

impl Tilemap {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, x: i32, y: i32) -> i32 {
        self.cells.get(&(x, y)).copied().unwrap_or(-1)
    }

    pub fn set(&mut self, x: i32, y: i32, val: i32) {
        if val < 0 {
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

    pub fn remove(&mut self, x: i32, y: i32) {
        self.cells.remove(&(x, y));
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
                    '.' | '_' | '-' => -1,
                    c if c.is_ascii_hexdigit() => c.to_digit(16).map(|v| v as i32).unwrap_or(-1),
                    _ => -1,
                };
                self.set(start_x + dx as i32, y, val);
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum MapPropValue {
    Integer(i64),
    Float(f64),
    String(String),
    Bool(bool),
}

#[derive(Debug, Clone, PartialEq)]
pub struct MapObject {
    pub obj_type: String,
    pub x: i32,
    pub y: i32,
    pub props: HashMap<String, MapPropValue>,
}

pub fn tokenize_object_line(line: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut cur = String::new();
    let mut in_quote = false;

    for ch in line.chars() {
        if ch == '"' {
            in_quote = !in_quote;
            cur.push(ch);
        } else if ch.is_whitespace() && !in_quote {
            if !cur.is_empty() {
                tokens.push(cur.clone());
                cur.clear();
            }
        } else {
            cur.push(ch);
        }
    }
    if !cur.is_empty() {
        tokens.push(cur);
    }
    tokens
}

pub fn parse_prop_value(val_str: &str) -> MapPropValue {
    let s = val_str.trim();
    if s.starts_with('"') && s.ends_with('"') && s.len() >= 2 {
        return MapPropValue::String(s[1..s.len() - 1].to_string());
    }
    if s == "true" {
        return MapPropValue::Bool(true);
    }
    if s == "false" {
        return MapPropValue::Bool(false);
    }
    if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        if let Ok(v) = i64::from_str_radix(hex, 16) {
            return MapPropValue::Integer(v);
        }
    }
    if let Ok(i) = s.parse::<i64>() {
        return MapPropValue::Integer(i);
    }
    if let Ok(f) = s.parse::<f64>() {
        return MapPropValue::Float(f);
    }
    MapPropValue::String(s.to_string())
}

/// `__END__` や `.map` の `@OBJECTS` セクションをパースして `Vec<MapObject>` を生成する
pub fn parse_tail_objects(data_section: &str) -> Vec<MapObject> {
    let mut objects = Vec::new();
    let mut in_objects = false;

    for raw_line in data_section.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some(rest) = line.strip_prefix("@OBJECTS")
            && (rest.is_empty() || rest.starts_with(char::is_whitespace))
        {
            in_objects = true;
            continue;
        } else if line.starts_with('@') {
            in_objects = false;
        } else if in_objects {
            let tokens = tokenize_object_line(line);
            if tokens.len() < 3 {
                continue;
            }
            let obj_type = tokens[0].clone();
            let x = tokens[1].parse::<i32>().unwrap_or(0);
            let y = tokens[2].parse::<i32>().unwrap_or(0);
            let mut props = HashMap::new();

            for tok in &tokens[3..] {
                let mut parts = tok.splitn(2, '=');
                let key = parts.next().unwrap_or("").trim();
                if key.is_empty() {
                    continue;
                }
                if let Some(val) = parts.next() {
                    props.insert(key.to_string(), parse_prop_value(val));
                } else {
                    props.insert(key.to_string(), MapPropValue::Bool(true));
                }
            }

            objects.push(MapObject {
                obj_type,
                x,
                y,
                props,
            });
        }
    }

    objects
}

impl MapObject {
    pub fn to_ruby_hash(&self) -> Rc<RObject> {
        let mut pairs: Vec<(String, Rc<RObject>)> = Vec::new();
        pairs.push(("type".to_string(), Rc::new(RObject::string(self.obj_type.clone()))));
        pairs.push(("x".to_string(), Rc::new(RObject::integer(self.x as i64))));
        pairs.push(("y".to_string(), Rc::new(RObject::integer(self.y as i64))));
        for (k, v) in &self.props {
            let robj = match v {
                MapPropValue::Integer(n) => Rc::new(RObject::integer(*n)),
                MapPropValue::Float(f) => Rc::new(RObject::float(*f)),
                MapPropValue::String(s) => Rc::new(RObject::string(s.clone())),
                MapPropValue::Bool(b) => Rc::new(RObject::boolean(*b)),
            };
            pairs.push((k.clone(), robj));
        }

        let mut hash = mrubyedge::yamrb::value::RHash::default();
        for (k, v) in pairs {
            let sym_obj = Rc::new(RObject::symbol(mrubyedge::yamrb::value::RSym::new(k)));
            if let Ok(hkey) = sym_obj.as_hash_key() {
                hash.insert(hkey, (sym_obj, v));
            }
        }
        Rc::new(RObject::hash(hash))
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
    Key(KeyCode),
}

impl ButtonId {
    pub fn as_name(&self) -> &'static str {
        match self {
            ButtonId::Left => "left",
            ButtonId::Right => "right",
            ButtonId::Up => "up",
            ButtonId::Down => "down",
            ButtonId::A => "btn_a",
            ButtonId::B => "btn_b",
            ButtonId::MouseLeft => "mouse_l",
            ButtonId::MouseRight => "mouse_r",
            ButtonId::MouseMiddle => "mouse_m",
            ButtonId::Key(_) => "key",
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct InputState {
    pub override_enabled: bool,
    pub current_down: Vec<ButtonId>,
    pub prev_down: Vec<ButtonId>,
}

impl InputState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_frame_buttons(&mut self, buttons: Vec<ButtonId>) {
        self.override_enabled = true;
        self.prev_down = std::mem::replace(&mut self.current_down, buttons);
    }

    pub fn is_down(&self, btn: ButtonId) -> bool {
        self.current_down.contains(&btn)
            || match btn {
                ButtonId::Left => {
                    self.current_down.contains(&ButtonId::Key(KeyCode::Left))
                        || self.current_down.contains(&ButtonId::Key(KeyCode::A))
                }
                ButtonId::Right => {
                    self.current_down.contains(&ButtonId::Key(KeyCode::Right))
                        || self.current_down.contains(&ButtonId::Key(KeyCode::D))
                }
                ButtonId::Up => {
                    self.current_down.contains(&ButtonId::Key(KeyCode::Up))
                        || self.current_down.contains(&ButtonId::Key(KeyCode::W))
                }
                ButtonId::Down => {
                    self.current_down.contains(&ButtonId::Key(KeyCode::Down))
                        || self.current_down.contains(&ButtonId::Key(KeyCode::S))
                }
                ButtonId::A => {
                    self.current_down.contains(&ButtonId::Key(KeyCode::Z))
                        || self.current_down.contains(&ButtonId::Key(KeyCode::Space))
                }
                ButtonId::B => {
                    self.current_down.contains(&ButtonId::Key(KeyCode::X))
                        || self.current_down.contains(&ButtonId::Key(KeyCode::Enter))
                }
                ButtonId::Key(KeyCode::Left) | ButtonId::Key(KeyCode::A) => {
                    self.current_down.contains(&ButtonId::Left)
                }
                ButtonId::Key(KeyCode::Right) | ButtonId::Key(KeyCode::D) => {
                    self.current_down.contains(&ButtonId::Right)
                }
                ButtonId::Key(KeyCode::Up) | ButtonId::Key(KeyCode::W) => {
                    self.current_down.contains(&ButtonId::Up)
                }
                ButtonId::Key(KeyCode::Down) | ButtonId::Key(KeyCode::S) => {
                    self.current_down.contains(&ButtonId::Down)
                }
                ButtonId::Key(KeyCode::Z) | ButtonId::Key(KeyCode::Space) => {
                    self.current_down.contains(&ButtonId::A)
                }
                ButtonId::Key(KeyCode::X) | ButtonId::Key(KeyCode::Enter) => {
                    self.current_down.contains(&ButtonId::B)
                }
                _ => false,
            }
    }

    pub fn is_pressed(&self, btn: ButtonId) -> bool {
        let is_now = self.is_down(btn);
        let was_before = self.prev_down.contains(&btn)
            || match btn {
                ButtonId::Left => {
                    self.prev_down.contains(&ButtonId::Key(KeyCode::Left))
                        || self.prev_down.contains(&ButtonId::Key(KeyCode::A))
                }
                ButtonId::Right => {
                    self.prev_down.contains(&ButtonId::Key(KeyCode::Right))
                        || self.prev_down.contains(&ButtonId::Key(KeyCode::D))
                }
                ButtonId::Up => {
                    self.prev_down.contains(&ButtonId::Key(KeyCode::Up))
                        || self.prev_down.contains(&ButtonId::Key(KeyCode::W))
                }
                ButtonId::Down => {
                    self.prev_down.contains(&ButtonId::Key(KeyCode::Down))
                        || self.prev_down.contains(&ButtonId::Key(KeyCode::S))
                }
                ButtonId::A => {
                    self.prev_down.contains(&ButtonId::Key(KeyCode::Z))
                        || self.prev_down.contains(&ButtonId::Key(KeyCode::Space))
                }
                ButtonId::B => {
                    self.prev_down.contains(&ButtonId::Key(KeyCode::X))
                        || self.prev_down.contains(&ButtonId::Key(KeyCode::Enter))
                }
                ButtonId::Key(KeyCode::Left) | ButtonId::Key(KeyCode::A) => {
                    self.prev_down.contains(&ButtonId::Left)
                }
                ButtonId::Key(KeyCode::Right) | ButtonId::Key(KeyCode::D) => {
                    self.prev_down.contains(&ButtonId::Right)
                }
                ButtonId::Key(KeyCode::Up) | ButtonId::Key(KeyCode::W) => {
                    self.prev_down.contains(&ButtonId::Up)
                }
                ButtonId::Key(KeyCode::Down) | ButtonId::Key(KeyCode::S) => {
                    self.prev_down.contains(&ButtonId::Down)
                }
                ButtonId::Key(KeyCode::Z) | ButtonId::Key(KeyCode::Space) => {
                    self.prev_down.contains(&ButtonId::A)
                }
                ButtonId::Key(KeyCode::X) | ButtonId::Key(KeyCode::Enter) => {
                    self.prev_down.contains(&ButtonId::B)
                }
                _ => false,
            };
        is_now && !was_before
    }
}

#[derive(Debug, Clone)]
pub struct InputFuzzer {
    state: u64,
}

impl InputFuzzer {
    pub fn new(seed: u64) -> Self {
        Self {
            state: if seed == 0 {
                0x853c49e6748fea9b
            } else {
                seed
            },
        }
    }

    fn next_u32(&mut self) -> u32 {
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;
        (self.state.wrapping_mul(0x2545F4914F6CDD1D) >> 32) as u32
    }

    /// ガチャキーモードの入力フレームを生成する。
    /// 方向キー（ニュートラル / 左右 / 上下 / 斜め）とパッドボタン（A, B）を擬似的に連打・押しっぱなしにする。
    pub fn next_frame(&mut self) -> Vec<ButtonId> {
        let mut buttons = Vec::new();

        // 1. 方向キー (ニュートラル: 35%, 左右移動: 35%, 上下: 18%, 斜め入力: 12%)
        let dir_val = self.next_u32() % 100;
        match dir_val {
            0..=34 => {} // ニュートラル
            35..=51 => buttons.push(ButtonId::Left),
            52..=69 => buttons.push(ButtonId::Right),
            70..=78 => buttons.push(ButtonId::Up),
            79..=87 => buttons.push(ButtonId::Down),
            88..=90 => {
                buttons.push(ButtonId::Up);
                buttons.push(ButtonId::Left);
            }
            91..=93 => {
                buttons.push(ButtonId::Up);
                buttons.push(ButtonId::Right);
            }
            94..=96 => {
                buttons.push(ButtonId::Down);
                buttons.push(ButtonId::Left);
            }
            _ => {
                buttons.push(ButtonId::Down);
                buttons.push(ButtonId::Right);
            }
        }

        // 2. パッドボタン A (ジャンプ / 決定 / 攻撃) 連打・トリガー (50%)
        if (self.next_u32() % 100) < 50 {
            buttons.push(ButtonId::A);
        }

        // 3. パッドボタン B (ダッシュ / サブ攻撃 / キャンセル) 連打 (35%)
        if (self.next_u32() % 100) < 35 {
            buttons.push(ButtonId::B);
        }

        buttons
    }
}

pub fn parse_button_name(name: &str) -> Option<ButtonId> {
    let lower = name.to_lowercase();
    match lower.as_str() {
        // --- 仮想ゲームパッド / マウス (既存互換) ---
        "left" | "l" => Some(ButtonId::Left),
        "right" | "r" => Some(ButtonId::Right),
        "up" | "u" => Some(ButtonId::Up),
        "down" | "d" => Some(ButtonId::Down),
        "z" | "space" | "btn_a" => Some(ButtonId::A),
        "x" | "enter" | "return" | "btn_b" => Some(ButtonId::B),
        "mouse_l" | "mouse_left" | "mouse_1" | "click" | "lclick" => Some(ButtonId::MouseLeft),
        "mouse_r" | "mouse_right" | "mouse_2" | "rclick" => Some(ButtonId::MouseRight),
        "mouse_m" | "mouse_middle" | "mouse_3" | "mclick" => Some(ButtonId::MouseMiddle),

        // --- 特殊キー ---
        "tab" => Some(ButtonId::Key(KeyCode::Tab)),
        "ctrl" | "lctrl" | "control" => Some(ButtonId::Key(KeyCode::LeftControl)),
        "rctrl" => Some(ButtonId::Key(KeyCode::RightControl)),
        "shift" | "lshift" => Some(ButtonId::Key(KeyCode::LeftShift)),
        "rshift" => Some(ButtonId::Key(KeyCode::RightShift)),
        "alt" | "lalt" => Some(ButtonId::Key(KeyCode::LeftAlt)),
        "ralt" => Some(ButtonId::Key(KeyCode::RightAlt)),
        "super" | "cmd" | "command" | "gui" => Some(ButtonId::Key(KeyCode::LeftSuper)),
        "escape" | "esc" => Some(ButtonId::Key(KeyCode::Escape)),
        "backspace" | "bs" => Some(ButtonId::Key(KeyCode::Backspace)),
        "delete" | "del" => Some(ButtonId::Key(KeyCode::Delete)),
        "insert" | "ins" => Some(ButtonId::Key(KeyCode::Insert)),
        "home" => Some(ButtonId::Key(KeyCode::Home)),
        "end" => Some(ButtonId::Key(KeyCode::End)),
        "pageup" | "page_up" => Some(ButtonId::Key(KeyCode::PageUp)),
        "pagedown" | "page_down" => Some(ButtonId::Key(KeyCode::PageDown)),

        // --- 数字キー ---
        "0" | "key_0" => Some(ButtonId::Key(KeyCode::Key0)),
        "1" | "key_1" => Some(ButtonId::Key(KeyCode::Key1)),
        "2" | "key_2" => Some(ButtonId::Key(KeyCode::Key2)),
        "3" | "key_3" => Some(ButtonId::Key(KeyCode::Key3)),
        "4" | "key_4" => Some(ButtonId::Key(KeyCode::Key4)),
        "5" | "key_5" => Some(ButtonId::Key(KeyCode::Key5)),
        "6" | "key_6" => Some(ButtonId::Key(KeyCode::Key6)),
        "7" | "key_7" => Some(ButtonId::Key(KeyCode::Key7)),
        "8" | "key_8" => Some(ButtonId::Key(KeyCode::Key8)),
        "9" | "key_9" => Some(ButtonId::Key(KeyCode::Key9)),

        // --- ファンクションキー ---
        "f1" => Some(ButtonId::Key(KeyCode::F1)),
        "f2" => Some(ButtonId::Key(KeyCode::F2)),
        "f3" => Some(ButtonId::Key(KeyCode::F3)),
        "f4" => Some(ButtonId::Key(KeyCode::F4)),
        "f5" => Some(ButtonId::Key(KeyCode::F5)),
        "f6" => Some(ButtonId::Key(KeyCode::F6)),
        "f7" => Some(ButtonId::Key(KeyCode::F7)),
        "f8" => Some(ButtonId::Key(KeyCode::F8)),
        "f9" => Some(ButtonId::Key(KeyCode::F9)),
        "f10" => Some(ButtonId::Key(KeyCode::F10)),
        "f11" => Some(ButtonId::Key(KeyCode::F11)),
        "f12" => Some(ButtonId::Key(KeyCode::F12)),

        // --- アルファベット (個別キー) ---
        "a" | "key_a" => Some(ButtonId::Key(KeyCode::A)),
        "b" | "key_b" => Some(ButtonId::Key(KeyCode::B)),
        "c" | "key_c" => Some(ButtonId::Key(KeyCode::C)),
        // "d" は ButtonId::Down (KeyCode::Down || KeyCode::S) ではなく KeyCode::D (ButtonId::Right) だった点に注意
        // 既存の "d" は ButtonId::Down なので互換性を維持しつつ "key_d" は KeyCode::D を提供
        "key_d" => Some(ButtonId::Key(KeyCode::D)),
        "e" | "key_e" => Some(ButtonId::Key(KeyCode::E)),
        "f" | "key_f" => Some(ButtonId::Key(KeyCode::F)),
        "g" | "key_g" => Some(ButtonId::Key(KeyCode::G)),
        "h" | "key_h" => Some(ButtonId::Key(KeyCode::H)),
        "i" | "key_i" => Some(ButtonId::Key(KeyCode::I)),
        "j" | "key_j" => Some(ButtonId::Key(KeyCode::J)),
        "k" | "key_k" => Some(ButtonId::Key(KeyCode::K)),
        "key_l" => Some(ButtonId::Key(KeyCode::L)), // "l" は既存の Left
        "m" | "key_m" => Some(ButtonId::Key(KeyCode::M)),
        "n" | "key_n" => Some(ButtonId::Key(KeyCode::N)),
        "o" | "key_o" => Some(ButtonId::Key(KeyCode::O)),
        "p" | "key_p" => Some(ButtonId::Key(KeyCode::P)),
        "q" | "key_q" => Some(ButtonId::Key(KeyCode::Q)),
        "key_r" => Some(ButtonId::Key(KeyCode::R)), // "r" は既存の Right
        "s" | "key_s" => Some(ButtonId::Key(KeyCode::S)),
        "t" | "key_t" => Some(ButtonId::Key(KeyCode::T)),
        "key_u" => Some(ButtonId::Key(KeyCode::U)), // "u" は既存の Up
        "v" | "key_v" => Some(ButtonId::Key(KeyCode::V)),
        "w" | "key_w" => Some(ButtonId::Key(KeyCode::W)),
        "key_x" => Some(ButtonId::Key(KeyCode::X)),
        "y" | "key_y" => Some(ButtonId::Key(KeyCode::Y)),
        "key_z" => Some(ButtonId::Key(KeyCode::Z)),

        // --- 記号キー ---
        "minus" => Some(ButtonId::Key(KeyCode::Minus)),
        "equal" => Some(ButtonId::Key(KeyCode::Equal)),
        "left_bracket" | "lbracket" | "[" => Some(ButtonId::Key(KeyCode::LeftBracket)),
        "right_bracket" | "rbracket" | "]" => Some(ButtonId::Key(KeyCode::RightBracket)),
        "semicolon" | ";" => Some(ButtonId::Key(KeyCode::Semicolon)),
        "apostrophe" | "'" => Some(ButtonId::Key(KeyCode::Apostrophe)),
        "comma" | "," => Some(ButtonId::Key(KeyCode::Comma)),
        "period" | "." => Some(ButtonId::Key(KeyCode::Period)),
        "slash" | "/" => Some(ButtonId::Key(KeyCode::Slash)),
        "backslash" | "\\" => Some(ButtonId::Key(KeyCode::Backslash)),
        "grave" | "`" => Some(ButtonId::Key(KeyCode::GraveAccent)),

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
        ButtonId::Key(k) => is_key_down(k),
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
        ButtonId::Key(k) => is_key_pressed(k),
    }
}

/// F5 キー、または Ctrl+R / Cmd+R (Super+R) が押されたか判定する
pub fn is_restart_key_pressed() -> bool {
    if is_key_pressed(KeyCode::F5) {
        return true;
    }
    let ctrl_or_super = is_key_down(KeyCode::LeftControl)
        || is_key_down(KeyCode::RightControl)
        || is_key_down(KeyCode::LeftSuper)
        || is_key_down(KeyCode::RightSuper);
    ctrl_or_super && is_key_pressed(KeyCode::R)
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
    } else if let Some(texture) = sprite.get_or_build_pal_texture(&state.pal_map, state.palt_mask, &state.palette_rgba) {
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
    } else if let Some(texture) = bank.get_or_build_pal_texture(&state.pal_map, state.palt_mask, &state.palette_rgba) {
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
    pub active_pal_bank: i32,
    pub palette_rgba: PaletteRgba,
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
            active_pal_bank: 0,
            palette_rgba: PALETTE_RGBA,
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
        self.pal_map == DEFAULT_PAL_MAP && self.palt_mask == 0 && self.palette_rgba == PALETTE_RGBA
    }

    pub fn map_color_index(&self, col: i32) -> usize {
        let src = (col.rem_euclid(16)) as usize;
        (self.pal_map[src] & 0x0F) as usize
    }

    pub fn map_color(&self, col: i32) -> Color {
        let rgba = self.palette_rgba[self.map_color_index(col)];
        Color::from_rgba(rgba[0], rgba[1], rgba[2], rgba[3])
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

/// 指定したリソースパス（または関連ファイル）が外部 PNG を直接参照しているタイプかどうか判定する。
/// 外部 PNG 直接参照タイプのリソースは、スプライトエディタ等で上書き保存できない読み込み専用として扱う。
pub fn check_resource_read_only(path_str: &str) -> bool {
    if path_str.is_empty() {
        return false;
    }
    let p = Path::new(path_str);
    if p.extension().and_then(|s| s.to_str()).map(|s| s.eq_ignore_ascii_case("png")) == Some(true) {
        return true;
    }

    let check_content = |content: &str| -> bool {
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with('#') {
                continue;
            }
            if let Some(rest) = trimmed.strip_prefix("@BANK") {
                let parts: Vec<&str> = rest.split_whitespace().collect();
                if parts.len() >= 2 && parts[1].to_ascii_lowercase().ends_with(".png") {
                    return true;
                }
            } else if let Some(rest) = trimmed.strip_prefix("@SHEET") {
                let parts: Vec<&str> = rest.split_whitespace().collect();
                for part in parts.iter().skip(1) {
                    if part.to_ascii_lowercase().ends_with(".png") {
                        return true;
                    }
                }
            }
        }
        false
    };

    if let Ok(content) = std::fs::read_to_string(p) {
        if check_content(&content) {
            return true;
        }
    }

    if matches!(p.extension().and_then(|s| s.to_str()), Some("rb" | "map")) {
        let spr_path = p.with_extension("spr");
        if let Ok(content) = std::fs::read_to_string(&spr_path) {
            if check_content(&content) {
                return true;
            }
        }
    }

    false
}

fn get_math_f64_arg(args: &[Rc<RObject>], idx: usize, func_name: &str) -> Result<f64, mrubyedge::Error> {
    if idx >= args.len() {
        return Err(mrubyedge::Error::ArgumentError(format!(
            "wrong number of arguments to {} (given {}, expected {})",
            func_name,
            args.len(),
            idx + 1
        )));
    }
    match &args[idx].value {
        RValue::Float(f) => Ok(*f),
        RValue::Integer(i) => Ok(*i as f64),
        _ => Err(mrubyedge::Error::TypeMismatch),
    }
}

/// Float / Integer の数値組み込みクラス拡張 (% / modulo, floor, ceil, round)
fn register_numeric_extensions(vm: &mut VM) {
    if let Some(float_class) = vm.builtin_class_table.get("Float").cloned() {
        // Float#%
        mrb_define_cmethod(
            vm,
            float_class.clone(),
            "%",
            Box::new(|vm, args| {
                if args.is_empty() {
                    return Err(mrubyedge::Error::ArgumentError(
                        "wrong number of arguments (given 0, expected 1)".to_string(),
                    ));
                }
                let lhs = match &vm.getself()?.value {
                    RValue::Float(f) => *f,
                    RValue::Integer(i) => *i as f64,
                    _ => return Err(mrubyedge::Error::TypeMismatch),
                };
                let rhs = match &args[0].value {
                    RValue::Float(f) => *f,
                    RValue::Integer(i) => *i as f64,
                    _ => return Err(mrubyedge::Error::TypeMismatch),
                };
                if rhs == 0.0 {
                    return Err(mrubyedge::Error::ZeroDivisionError);
                }
                let res = lhs - rhs * (lhs / rhs).floor();
                Ok(Rc::new(RObject::float(res)))
            }),
        );

        // Float#modulo
        mrb_define_cmethod(
            vm,
            float_class.clone(),
            "modulo",
            Box::new(|vm, args| {
                if args.is_empty() {
                    return Err(mrubyedge::Error::ArgumentError(
                        "wrong number of arguments (given 0, expected 1)".to_string(),
                    ));
                }
                let lhs = match &vm.getself()?.value {
                    RValue::Float(f) => *f,
                    RValue::Integer(i) => *i as f64,
                    _ => return Err(mrubyedge::Error::TypeMismatch),
                };
                let rhs = match &args[0].value {
                    RValue::Float(f) => *f,
                    RValue::Integer(i) => *i as f64,
                    _ => return Err(mrubyedge::Error::TypeMismatch),
                };
                if rhs == 0.0 {
                    return Err(mrubyedge::Error::ZeroDivisionError);
                }
                let res = lhs - rhs * (lhs / rhs).floor();
                Ok(Rc::new(RObject::float(res)))
            }),
        );

        // Float#floor
        mrb_define_cmethod(
            vm,
            float_class.clone(),
            "floor",
            Box::new(|vm, _args| {
                let lhs = match &vm.getself()?.value {
                    RValue::Float(f) => *f,
                    RValue::Integer(i) => *i as f64,
                    _ => return Err(mrubyedge::Error::TypeMismatch),
                };
                Ok(Rc::new(RObject::integer(lhs.floor() as i64)))
            }),
        );

        // Float#ceil
        mrb_define_cmethod(
            vm,
            float_class.clone(),
            "ceil",
            Box::new(|vm, _args| {
                let lhs = match &vm.getself()?.value {
                    RValue::Float(f) => *f,
                    RValue::Integer(i) => *i as f64,
                    _ => return Err(mrubyedge::Error::TypeMismatch),
                };
                Ok(Rc::new(RObject::integer(lhs.ceil() as i64)))
            }),
        );

        // Float#round
        mrb_define_cmethod(
            vm,
            float_class,
            "round",
            Box::new(|vm, _args| {
                let lhs = match &vm.getself()?.value {
                    RValue::Float(f) => *f,
                    RValue::Integer(i) => *i as f64,
                    _ => return Err(mrubyedge::Error::TypeMismatch),
                };
                Ok(Rc::new(RObject::integer(lhs.round() as i64)))
            }),
        );
    }

    if let Some(int_class) = vm.builtin_class_table.get("Integer").cloned() {
        // Integer#% (with Float rhs support and proper modulo)
        mrb_define_cmethod(
            vm,
            int_class.clone(),
            "%",
            Box::new(|vm, args| {
                if args.is_empty() {
                    return Err(mrubyedge::Error::ArgumentError(
                        "wrong number of arguments (given 0, expected 1)".to_string(),
                    ));
                }
                let lhs: i64 = vm.getself()?.as_ref().try_into()?;
                match &args[0].value {
                    RValue::Integer(rhs) => {
                        if *rhs == 0 {
                            return Err(mrubyedge::Error::ZeroDivisionError);
                        }
                        let rem = lhs % *rhs;
                        let res = if (rem > 0 && *rhs < 0) || (rem < 0 && *rhs > 0) {
                            rem + *rhs
                        } else {
                            rem
                        };
                        Ok(Rc::new(RObject::integer(res)))
                    }
                    RValue::Float(rhs) => {
                        if *rhs == 0.0 {
                            return Err(mrubyedge::Error::ZeroDivisionError);
                        }
                        let lhs_f = lhs as f64;
                        let res = lhs_f - *rhs * (lhs_f / *rhs).floor();
                        Ok(Rc::new(RObject::float(res)))
                    }
                    _ => Err(mrubyedge::Error::TypeMismatch),
                }
            }),
        );

        // Integer#modulo
        mrb_define_cmethod(
            vm,
            int_class.clone(),
            "modulo",
            Box::new(|vm, args| {
                if args.is_empty() {
                    return Err(mrubyedge::Error::ArgumentError(
                        "wrong number of arguments (given 0, expected 1)".to_string(),
                    ));
                }
                let lhs: i64 = vm.getself()?.as_ref().try_into()?;
                match &args[0].value {
                    RValue::Integer(rhs) => {
                        if *rhs == 0 {
                            return Err(mrubyedge::Error::ZeroDivisionError);
                        }
                        let rem = lhs % *rhs;
                        let res = if (rem > 0 && *rhs < 0) || (rem < 0 && *rhs > 0) {
                            rem + *rhs
                        } else {
                            rem
                        };
                        Ok(Rc::new(RObject::integer(res)))
                    }
                    RValue::Float(rhs) => {
                        if *rhs == 0.0 {
                            return Err(mrubyedge::Error::ZeroDivisionError);
                        }
                        let lhs_f = lhs as f64;
                        let res = lhs_f - *rhs * (lhs_f / *rhs).floor();
                        Ok(Rc::new(RObject::float(res)))
                    }
                    _ => Err(mrubyedge::Error::TypeMismatch),
                }
            }),
        );

        // Integer#floor / ceil / round
        mrb_define_cmethod(
            vm,
            int_class.clone(),
            "floor",
            Box::new(|vm, _args| vm.getself()),
        );
        mrb_define_cmethod(
            vm,
            int_class.clone(),
            "ceil",
            Box::new(|vm, _args| vm.getself()),
        );
        mrb_define_cmethod(
            vm,
            int_class,
            "round",
            Box::new(|vm, _args| vm.getself()),
        );
    }
}

/// Math モジュールおよび数学関数（Math.sin, Math::PI, top-level sin 等）を登録する
fn register_math_api(vm: &mut VM) {
    let math_mod = vm.define_module("Math", None);
    let math_obj = vm.consts.get("Math").unwrap().clone();
    let obj_class = vm.object_class.clone();

    // 定数: Math::PI, Math::E
    let pi_val = Rc::new(RObject::float(std::f64::consts::PI));
    math_mod.consts.borrow_mut().insert("PI".to_string(), pi_val.clone());

    let e_val = Rc::new(RObject::float(std::f64::consts::E));
    math_mod.consts.borrow_mut().insert("E".to_string(), e_val.clone());

    macro_rules! def_math {
        ($name:literal, $f:expr) => {
            mrb_define_singleton_cmethod(vm, math_obj.clone(), $name, Box::new($f));
            mrb_define_module_cmethod(vm, math_mod.clone(), $name, Box::new($f));
            mrb_define_cmethod(vm, obj_class.clone(), $name, Box::new($f));
        };
    }

    def_math!("sin", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "sin")?;
        Ok(Rc::new(RObject::float(x.sin())))
    });

    def_math!("cos", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "cos")?;
        Ok(Rc::new(RObject::float(x.cos())))
    });

    def_math!("tan", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "tan")?;
        Ok(Rc::new(RObject::float(x.tan())))
    });

    def_math!("asin", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "asin")?;
        if !(-1.0..=1.0).contains(&x) {
            return Err(mrubyedge::Error::RangeError(
                "Numerical argument is out of domain - asin".to_string(),
            ));
        }
        Ok(Rc::new(RObject::float(x.asin())))
    });

    def_math!("acos", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "acos")?;
        if !(-1.0..=1.0).contains(&x) {
            return Err(mrubyedge::Error::RangeError(
                "Numerical argument is out of domain - acos".to_string(),
            ));
        }
        Ok(Rc::new(RObject::float(x.acos())))
    });

    def_math!("atan", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "atan")?;
        Ok(Rc::new(RObject::float(x.atan())))
    });

    def_math!("atan2", |_vm, args| {
        let y = get_math_f64_arg(args, 0, "atan2")?;
        let x = get_math_f64_arg(args, 1, "atan2")?;
        Ok(Rc::new(RObject::float(y.atan2(x))))
    });

    def_math!("sqrt", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "sqrt")?;
        if x < 0.0 {
            return Err(mrubyedge::Error::RangeError(
                "Numerical argument is out of domain - sqrt".to_string(),
            ));
        }
        Ok(Rc::new(RObject::float(x.sqrt())))
    });

    def_math!("cbrt", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "cbrt")?;
        Ok(Rc::new(RObject::float(x.cbrt())))
    });

    def_math!("exp", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "exp")?;
        Ok(Rc::new(RObject::float(x.exp())))
    });

    def_math!("log", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "log")?;
        if x <= 0.0 {
            return Err(mrubyedge::Error::RangeError(
                "Numerical argument is out of domain - log".to_string(),
            ));
        }
        if args.len() >= 2 {
            let base = get_math_f64_arg(args, 1, "log")?;
            if base <= 0.0 || (base - 1.0).abs() < f64::EPSILON {
                return Err(mrubyedge::Error::RangeError(
                    "Numerical argument is out of domain - log".to_string(),
                ));
            }
            Ok(Rc::new(RObject::float(x.log(base))))
        } else {
            Ok(Rc::new(RObject::float(x.ln())))
        }
    });

    def_math!("log2", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "log2")?;
        if x <= 0.0 {
            return Err(mrubyedge::Error::RangeError(
                "Numerical argument is out of domain - log2".to_string(),
            ));
        }
        Ok(Rc::new(RObject::float(x.log2())))
    });

    def_math!("log10", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "log10")?;
        if x <= 0.0 {
            return Err(mrubyedge::Error::RangeError(
                "Numerical argument is out of domain - log10".to_string(),
            ));
        }
        Ok(Rc::new(RObject::float(x.log10())))
    });

    def_math!("hypot", |_vm, args| {
        let x = get_math_f64_arg(args, 0, "hypot")?;
        let y = get_math_f64_arg(args, 1, "hypot")?;
        Ok(Rc::new(RObject::float(x.hypot(y))))
    });
}

fn mrb_sprintf(_vm: &mut VM, args: &[Rc<RObject>]) -> Result<Rc<RObject>, mrubyedge::Error> {
    if args.is_empty() {
        return Err(mrubyedge::Error::ArgumentError(
            "too few arguments for sprintf/format".to_string(),
        ));
    }
    let fmt_str: String = match &args[0].value {
        RValue::String(bytes, _) => String::from_utf8_lossy(&bytes.borrow()).to_string(),
        _ => args[0].as_ref().try_into().map_err(|_| mrubyedge::Error::TypeMismatch)?,
    };

    let mut out = String::new();
    let mut chars = fmt_str.chars().peekable();
    let mut arg_idx = 1;

    while let Some(ch) = chars.next() {
        if ch != '%' {
            out.push(ch);
            continue;
        }

        if chars.peek() == Some(&'%') {
            chars.next();
            out.push('%');
            continue;
        }

        // Flags
        let mut zero_pad = false;
        let mut left_align = false;
        let mut plus_sign = false;
        let mut space_sign = false;

        while let Some(&c) = chars.peek() {
            match c {
                '0' => {
                    zero_pad = true;
                    chars.next();
                }
                '-' => {
                    left_align = true;
                    chars.next();
                }
                '+' => {
                    plus_sign = true;
                    chars.next();
                }
                ' ' => {
                    space_sign = true;
                    chars.next();
                }
                _ => break,
            }
        }
        if left_align {
            zero_pad = false;
        }

        // Width
        let mut width: Option<usize> = None;
        if let Some(&c) = chars.peek() {
            if c.is_ascii_digit() {
                let mut w = 0;
                while let Some(&c) = chars.peek() {
                    if c.is_ascii_digit() {
                        w = w * 10 + (c as usize - '0' as usize);
                        chars.next();
                    } else {
                        break;
                    }
                }
                width = Some(w);
            }
        }

        // Precision
        let mut precision: Option<usize> = None;
        if chars.peek() == Some(&'.') {
            chars.next();
            let mut p = 0;
            while let Some(&c) = chars.peek() {
                if c.is_ascii_digit() {
                    p = p * 10 + (c as usize - '0' as usize);
                    chars.next();
                } else {
                    break;
                }
            }
            precision = Some(p);
        }

        let spec = match chars.next() {
            Some(c) => c,
            None => {
                out.push('%');
                break;
            }
        };

        let arg = args.get(arg_idx);
        arg_idx += 1;

        match spec {
            'd' | 'i' | 'u' => {
                let num: i64 = match arg {
                    Some(a) => match &a.value {
                        RValue::Integer(i) => *i,
                        RValue::Float(f) => *f as i64,
                        _ => i64::try_from(a.as_ref()).unwrap_or(0),
                    },
                    None => 0,
                };
                let is_neg = num < 0;
                let abs_num = num.unsigned_abs();
                let num_str = abs_num.to_string();
                let sign = if is_neg {
                    "-"
                } else if plus_sign {
                    "+"
                } else if space_sign {
                    " "
                } else {
                    ""
                };

                let w = width.unwrap_or(0);
                if zero_pad {
                    let total_len = sign.len() + num_str.len();
                    out.push_str(sign);
                    if total_len < w {
                        for _ in 0..(w - total_len) {
                            out.push('0');
                        }
                    }
                    out.push_str(&num_str);
                } else {
                    let full_val = format!("{}{}", sign, num_str);
                    if full_val.len() < w {
                        let pad = w - full_val.len();
                        if left_align {
                            out.push_str(&full_val);
                            for _ in 0..pad {
                                out.push(' ');
                            }
                        } else {
                            for _ in 0..pad {
                                out.push(' ');
                            }
                            out.push_str(&full_val);
                        }
                    } else {
                        out.push_str(&full_val);
                    }
                }
            }
            'x' | 'X' => {
                let num: i64 = match arg {
                    Some(a) => match &a.value {
                        RValue::Integer(i) => *i,
                        RValue::Float(f) => *f as i64,
                        _ => i64::try_from(a.as_ref()).unwrap_or(0),
                    },
                    None => 0,
                };
                let num_str = if spec == 'x' {
                    format!("{:x}", num as u64)
                } else {
                    format!("{:X}", num as u64)
                };
                let w = width.unwrap_or(0);
                if num_str.len() < w {
                    let pad = w - num_str.len();
                    let pad_char = if zero_pad { '0' } else { ' ' };
                    if left_align {
                        out.push_str(&num_str);
                        for _ in 0..pad {
                            out.push(' ');
                        }
                    } else {
                        for _ in 0..pad {
                            out.push(pad_char);
                        }
                        out.push_str(&num_str);
                    }
                } else {
                    out.push_str(&num_str);
                }
            }
            'f' => {
                let num: f64 = match arg {
                    Some(a) => match &a.value {
                        RValue::Float(f) => *f,
                        RValue::Integer(i) => *i as f64,
                        _ => f64::try_from(a.as_ref()).unwrap_or(0.0),
                    },
                    None => 0.0,
                };
                let prec = precision.unwrap_or(6);
                let num_str = format!("{:.*}", prec, num);
                let w = width.unwrap_or(0);
                if num_str.len() < w {
                    let pad = w - num_str.len();
                    let pad_char = if zero_pad { '0' } else { ' ' };
                    if left_align {
                        out.push_str(&num_str);
                        for _ in 0..pad {
                            out.push(' ');
                        }
                    } else {
                        for _ in 0..pad {
                            out.push(pad_char);
                        }
                        out.push_str(&num_str);
                    }
                } else {
                    out.push_str(&num_str);
                }
            }
            's' => {
                let s = match arg {
                    Some(a) => match &a.value {
                        RValue::String(bytes, _) => {
                            String::from_utf8_lossy(&bytes.borrow()).to_string()
                        }
                        RValue::Symbol(sym) => sym.name.clone(),
                        RValue::Integer(i) => i.to_string(),
                        RValue::Float(f) => f.to_string(),
                        RValue::Bool(b) => b.to_string(),
                        RValue::Nil => "".to_string(),
                        _ => a.as_ref().try_into().unwrap_or_default(),
                    },
                    None => "".to_string(),
                };
                let w = width.unwrap_or(0);
                if s.len() < w {
                    let pad = w - s.len();
                    if left_align {
                        out.push_str(&s);
                        for _ in 0..pad {
                            out.push(' ');
                        }
                    } else {
                        for _ in 0..pad {
                            out.push(' ');
                        }
                        out.push_str(&s);
                    }
                } else {
                    out.push_str(&s);
                }
            }
            _ => {
                out.push('%');
                out.push(spec);
            }
        }
    }

    Ok(Rc::new(RObject::string(out)))
}

fn register_string_format_extensions(vm: &mut VM) {
    let obj_class = vm.object_class.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "sprintf",
        Box::new(mrb_sprintf),
    );
    mrb_define_cmethod(
        vm,
        obj_class,
        "format",
        Box::new(mrb_sprintf),
    );

    if let Some(str_class) = vm.builtin_class_table.get("String").cloned() {
        mrb_define_cmethod(
            vm,
            str_class,
            "%",
            Box::new(|vm, args| {
                if args.is_empty() {
                    return Err(mrubyedge::Error::ArgumentError(
                        "wrong number of arguments (given 0, expected 1)".to_string(),
                    ));
                }
                let fmt_obj = vm.getself()?;
                let mut sprintf_args = vec![fmt_obj];
                if let RValue::Array(ary) = &args[0].value {
                    sprintf_args.extend(ary.borrow().iter().cloned());
                } else {
                    sprintf_args.push(args[0].clone());
                }
                mrb_sprintf(vm, &sprintf_args)
            }),
        );
    }
}

/// rand(max), rand(Range), rand() の拡張（Range対応）
fn mrb_engine_rand(_vm: &mut VM, args: &[Rc<RObject>]) -> Result<Rc<RObject>, mrubyedge::Error> {
    if args.is_empty() {
        let val: f32 = ::macroquad::rand::gen_range(0.0, 1.0);
        return Ok(Rc::new(RObject::float(val as f64)));
    }
    match &args[0].value {
        RValue::Integer(max) => {
            if *max <= 0 {
                return Err(mrubyedge::Error::ArgumentError("max must be positive".to_string()));
            }
            let val = ::macroquad::rand::gen_range(0, *max as i32);
            Ok(Rc::new(RObject::integer(val as i64)))
        }
        RValue::Float(max) => {
            if *max <= 0.0 {
                return Err(mrubyedge::Error::ArgumentError("max must be positive".to_string()));
            }
            let val = ::macroquad::rand::gen_range(0.0, *max as f32);
            Ok(Rc::new(RObject::float(val as f64)))
        }
        RValue::Range(start, end, exclusive) => {
            match (&start.value, &end.value) {
                (RValue::Integer(beg), RValue::Integer(last)) => {
                    let end_exclusive = if *exclusive { *last } else { *last + 1 };
                    if end_exclusive <= *beg {
                        return Err(mrubyedge::Error::ArgumentError("invalid range".to_string()));
                    }
                    let val = ::macroquad::rand::gen_range(*beg as i32, end_exclusive as i32);
                    Ok(Rc::new(RObject::integer(val as i64)))
                }
                _ => {
                    let beg_f = match &start.value {
                        RValue::Float(f) => *f,
                        RValue::Integer(i) => *i as f64,
                        _ => return Err(mrubyedge::Error::ArgumentError("invalid range".to_string())),
                    };
                    let last_f = match &end.value {
                        RValue::Float(f) => *f,
                        RValue::Integer(i) => *i as f64,
                        _ => return Err(mrubyedge::Error::ArgumentError("invalid range".to_string())),
                    };
                    if last_f <= beg_f {
                        return Err(mrubyedge::Error::ArgumentError("invalid range".to_string()));
                    }
                    let val = ::macroquad::rand::gen_range(beg_f as f32, last_f as f32);
                    Ok(Rc::new(RObject::float(val as f64)))
                }
            }
        }
        _ => Err(mrubyedge::Error::ArgumentError("argument must be a number or range".to_string())),
    }
}

fn register_rand_extension(vm: &mut VM) {
    let obj_class = vm.object_class.clone();
    mrb_define_cmethod(
        vm,
        obj_class,
        "rand",
        Box::new(mrb_engine_rand),
    );

    if let Some(random_obj) = vm.consts.get("Random").cloned() {
        mrb_define_singleton_cmethod(
            vm,
            random_obj,
            "rand",
            Box::new(mrb_engine_rand),
        );
    }
}

fn register_engine_api(
    vm: &mut VM,
    sprites: Rc<RefCell<HashMap<i32, SpriteData>>>,
    banks: Rc<RefCell<HashMap<i32, BankData>>>,
    active_spr_bank: Rc<RefCell<i32>>,
    active_map_bank: Rc<RefCell<i32>>,
    palettes: Rc<RefCell<HashMap<i32, PaletteRgba>>>,
    active_pal_bank: Rc<RefCell<i32>>,
    tilemap: Rc<RefCell<Tilemap>>,
    objects: Rc<RefCell<Vec<MapObject>>>,
    emoji_atlas: Rc<RefCell<emoji::EmojiAtlas>>,
    bitmap_font: Rc<BitmapFont>,
    draw_state: Rc<RefCell<DrawState>>,
    config: Rc<RefCell<AppConfig>>,
    restart_requested: Rc<RefCell<bool>>,
    input_state: Rc<RefCell<InputState>>,
    headless: bool,
) {
    register_numeric_extensions(vm);
    register_math_api(vm);
    register_string_format_extensions(vm);
    register_rand_extension(vm);
    let obj_class = vm.object_class.clone();

    // restart / reset: ゲームの先頭からのリスタートを要求する
    let restart_flag_for_restart = restart_requested.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "restart",
        Box::new(move |_vm, _args| {
            *restart_flag_for_restart.borrow_mut() = true;
            Ok(Rc::new(RObject::nil()))
        }),
    );
    let restart_flag_for_reset = restart_requested;
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "reset",
        Box::new(move |_vm, _args| {
            *restart_flag_for_reset.borrow_mut() = true;
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // spr_bank(id = 0): spr の参照先バンクを設定（同番号の @PALETTE があれば自動連動）
    let active_spr_bank_for_spr_bank = active_spr_bank.clone();
    let active_pal_bank_for_spr_bank = active_pal_bank.clone();
    let palettes_for_spr_bank = palettes.clone();
    let state_for_spr_bank = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "spr_bank",
        Box::new(move |_vm, args| {
            let id = arg_i32(args, 0, 0);
            *active_spr_bank_for_spr_bank.borrow_mut() = id;
            if let Some(pal) = palettes_for_spr_bank.borrow().get(&id) {
                *active_pal_bank_for_spr_bank.borrow_mut() = id;
                let mut state = state_for_spr_bank.borrow_mut();
                state.active_pal_bank = id;
                state.palette_rgba = *pal;
            }
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // pal_bank(id = 0): 描画用カラーパレットバンクを設定
    let active_pal_bank_for_pal_bank = active_pal_bank.clone();
    let palettes_for_pal_bank = palettes.clone();
    let state_for_pal_bank = draw_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "pal_bank",
        Box::new(move |_vm, args| {
            let id = arg_i32(args, 0, 0);
            *active_pal_bank_for_pal_bank.borrow_mut() = id;
            let mut state = state_for_pal_bank.borrow_mut();
            state.active_pal_bank = id;
            if id == 0 {
                state.palette_rgba = PALETTE_RGBA;
            } else if let Some(pal) = palettes_for_pal_bank.borrow().get(&id) {
                state.palette_rgba = *pal;
            } else {
                state.palette_rgba = PALETTE_RGBA;
            }
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
    let active_pal_bank_for_config = active_pal_bank.clone();
    let palettes_for_config = palettes.clone();
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
                            "palette" | "pal" => {
                                if let Some(n) = robject_to_u32(v).map(|x| x as i32) {
                                    cfg.default_palette = n;
                                    *active_pal_bank_for_config.borrow_mut() = n;
                                    let mut state = state_for_config.borrow_mut();
                                    state.active_pal_bank = n;
                                    if n == 0 {
                                        state.palette_rgba = PALETTE_RGBA;
                                    } else if let Some(pal) = palettes_for_config.borrow().get(&n) {
                                        state.palette_rgba = *pal;
                                    } else {
                                        state.palette_rgba = PALETTE_RGBA;
                                    }
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
    let palettes_for_pal = palettes.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "pal",
        Box::new(move |_vm, args| {
            let mut state = state_for_pal.borrow_mut();
            if args.is_empty() || matches!(args[0].value, RValue::Nil) {
                state.reset_pal();
                state.reset_palt();
                let bank_id = state.active_pal_bank;
                if let Some(pal) = palettes_for_pal.borrow().get(&bank_id) {
                    state.palette_rgba = *pal;
                } else {
                    state.palette_rgba = PALETTE_RGBA;
                }
            } else if let RValue::Array(ref arr_cell) = args[0].value {
                for (idx, item) in arr_cell.borrow().iter().take(16).enumerate() {
                    let dst = match item.value {
                        RValue::Integer(v) => v as i32,
                        RValue::Float(v) => v as i32,
                        _ => idx as i32,
                    };
                    state.set_pal(idx as i32, dst);
                }
            } else if args.len() >= 4 {
                // pal(c0, r, g, b): RGB直接変更
                let c0 = (arg_i32(args, 0, 0).rem_euclid(16)) as usize;
                let r = arg_i32(args, 1, 0).clamp(0, 255) as u8;
                let g = arg_i32(args, 2, 0).clamp(0, 255) as u8;
                let b = arg_i32(args, 3, 0).clamp(0, 255) as u8;
                state.palette_rgba[c0] = [r, g, b, 255];
            } else {
                let c0 = arg_i32(args, 0, 0);
                if let Some(arg1) = args.get(1) {
                    if let Ok(color_str) = String::try_from(arg1.as_ref()) {
                        if let Some(rgba) = config::parse_hex_color(&color_str) {
                            let idx = (c0.rem_euclid(16)) as usize;
                            state.palette_rgba[idx] = rgba;
                            return Ok(Rc::new(RObject::nil()));
                        }
                    }
                }
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

    // mget(cel_x = 0, cel_y = 0): タイルマップ上のセル (cel_x, cel_y) のタイル番号を取得（未設定・空セルは nil）
    let map_for_mget = tilemap.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "mget",
        Box::new(move |_vm, args| {
            let cx = arg_i32(args, 0, 0);
            let cy = arg_i32(args, 1, 0);
            let val = map_for_mget.borrow().get(cx, cy);
            if val < 0 {
                Ok(Rc::new(RObject::nil()))
            } else {
                Ok(Rc::new(RObject::integer(val as i64)))
            }
        }),
    );

    // mset(cel_x = 0, cel_y = 0, val = nil): タイルマップ上のセル (cel_x, cel_y) にタイル番号 val を設定（nil で消去、負数は ArgumentError）
    let map_for_mset = tilemap.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "mset",
        Box::new(move |_vm, args| {
            let cx = arg_i32(args, 0, 0);
            let cy = arg_i32(args, 1, 0);
            if args.len() < 3 || args[2].is_nil() {
                map_for_mset.borrow_mut().remove(cx, cy);
                return Ok(Rc::new(RObject::nil()));
            }
            let val = match &args[2].value {
                RValue::Integer(n) => *n,
                RValue::Float(f) => *f as i64,
                _ => return Err(mrubyedge::Error::TypeMismatch),
            };
            if val < 0 {
                return Err(mrubyedge::Error::ArgumentError(format!(
                    "tile ID cannot be negative ({val}). Use nil or mdel(x, y) to erase a tile."
                )));
            }
            map_for_mset.borrow_mut().set(cx, cy, val as i32);
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // mdel(cel_x = 0, cel_y = 0): タイルマップ上のセル (cel_x, cel_y) のタイルを消去
    let map_for_mdel = tilemap.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "mdel",
        Box::new(move |_vm, args| {
            let cx = arg_i32(args, 0, 0);
            let cy = arg_i32(args, 1, 0);
            map_for_mdel.borrow_mut().remove(cx, cy);
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // mclear(cel_x = 0, cel_y = 0): mdel のエイリアス
    let map_for_mclear = tilemap.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "mclear",
        Box::new(move |_vm, args| {
            let cx = arg_i32(args, 0, 0);
            let cy = arg_i32(args, 1, 0);
            map_for_mclear.borrow_mut().remove(cx, cy);
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

    // is_resource_read_only(path) / resource_read_only?(path): リソースが外部PNG直接参照で読み込み専用かどうか判定
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "is_resource_read_only",
        Box::new(|_vm, args| {
            let path = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            Ok(Rc::new(RObject::boolean(check_resource_read_only(&path))))
        }),
    );
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "resource_read_only?",
        Box::new(|_vm, args| {
            let path = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            Ok(Rc::new(RObject::boolean(check_resource_read_only(&path))))
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

            let (sprites, banks, _) = parse_tail_resources_full(&tail, p.parent());
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

            let (sprites, banks, _) = parse_tail_resources_full(&tail, base_dir);
            let has_bank_directive = tail.lines().any(|l| {
                let t = l.trim();
                t.starts_with("@BANK")
                    || t.starts_with("@SHEET")
                    || t.starts_with("@SPRITE")
                    || t.starts_with("@PNG")
                    || t.starts_with("@B64")
            });
            if (!has_bank_directive && sprites.is_empty()) || !banks.contains_key(&bank_id) {
                return Ok(Rc::new(RObject::nil()));
            }
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

    // load_resource_palettes(path): ターゲットファイル内の全パレットをランタイムに登録し、有効なパレットID配列を返す
    let palettes_for_load_palettes = palettes.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "load_resource_palettes",
        Box::new(move |_vm, args| {
            let path_str = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            let p = std::path::Path::new(&path_str);
            let tail = if p.extension().and_then(|s| s.to_str()) == Some("rb") {
                cli::compile_ruby_script_file(p)
                    .map(|(_, t, _)| t)
                    .unwrap_or_default()
            } else if p.is_file() {
                let content = std::fs::read_to_string(p).unwrap_or_default();
                if p.extension().and_then(|s| s.to_str()) == Some("map") {
                    let spr_path = p.with_extension("spr");
                    if spr_path.is_file() {
                        let spr_content = std::fs::read_to_string(&spr_path).unwrap_or_default();
                        format!("{}\n{}", content, spr_content)
                    } else {
                        content
                    }
                } else {
                    content
                }
            } else {
                String::new()
            };

            let parsed_pals = parse_tail_palettes(&tail);
            let mut pal_ids: Vec<i32> = Vec::new();
            if !parsed_pals.is_empty() {
                let mut pals_mut = palettes_for_load_palettes.borrow_mut();
                for (id, pal) in parsed_pals {
                    pals_mut.insert(id, pal);
                    pal_ids.push(id);
                }
            }
            if !pal_ids.contains(&0) {
                pal_ids.push(0);
            }
            pal_ids.sort();
            let ary: Vec<Rc<RObject>> = pal_ids
                .into_iter()
                .map(|id| Rc::new(RObject::integer(id as i64)))
                .collect();
            Ok(Rc::new(RObject::array(ary)))
        }),
    );

    // load_resource_sprite_palettes(path): ターゲットファイル内の全スプライトのパレット割り当て { sprite_id => palette_id } を返す
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "load_resource_sprite_palettes",
        Box::new(move |_vm, args| {
            let path_str = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            let p = std::path::Path::new(&path_str);
            let base_dir = p.parent();
            let tail = if p.extension().and_then(|s| s.to_str()) == Some("rb") {
                cli::compile_ruby_script_file(p)
                    .map(|(_, t, _)| t)
                    .unwrap_or_default()
            } else if p.is_file() {
                let content = std::fs::read_to_string(p).unwrap_or_default();
                if p.extension().and_then(|s| s.to_str()) == Some("map") {
                    let spr_path = p.with_extension("spr");
                    if spr_path.is_file() {
                        let spr_content = std::fs::read_to_string(&spr_path).unwrap_or_default();
                        format!("{}\n{}", content, spr_content)
                    } else {
                        content
                    }
                } else {
                    content
                }
            } else {
                String::new()
            };

            let (sprites, _, _) = parse_tail_resources_full(&tail, base_dir);
            let mut hash = mrubyedge::yamrb::value::RHash::default();
            for (id, sp) in &sprites {
                let slot_x = *id as usize % 16;
                let slot_y = *id as usize / 16;
                let tiles_w = (sp.width as usize + 15) / 16;
                let tiles_h = (sp.height as usize + 15) / 16;
                for ty in slot_y..slot_y + tiles_h {
                    for tx in slot_x..slot_x + tiles_w {
                        if tx < 16 && ty < 16 {
                            let tile_id = (ty * 16 + tx) as i64;
                            let key = Rc::new(RObject::integer(tile_id));
                            let val = Rc::new(RObject::integer(sp.palette_id as i64));
                            if let Ok(hkey) = key.as_hash_key() {
                                hash.insert(hkey, (key, val));
                            }
                        }
                    }
                }
            }
            Ok(Rc::new(RObject::hash(hash)))
        }),
    );

    // load_bank(bank_id, path_or_source, src_bank_id = nil):
    // 外部ファイル（PNG画像、.spr、.rb、.map等の定義）から減色処理を行わずにフルカラーRGBAのまま直接バンクへロードする。
    let banks_for_load_bank = banks.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "load_bank",
        Box::new(move |_vm, args| {
            let bank_id = arg_i32(args, 0, 0);
            let path_str = args
                .get(1)
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            let src_bank_id = if args.len() >= 3 && !args[2].is_nil() {
                arg_i32(args, 2, bank_id)
            } else {
                bank_id
            };

            let p = std::path::Path::new(&path_str);
            let base_dir = p.parent();

            // 1. PNG 画像ファイル直接指定の場合
            if p.extension().and_then(|s| s.to_str()).map(|s| s.eq_ignore_ascii_case("png")) == Some(true)
                && p.is_file()
            {
                if let Ok(bank) = BankData::from_file_or_base64(bank_id, &path_str, None) {
                    if !headless {
                        bank.build_texture();
                    }
                    let mut banks_mut = banks_for_load_bank.borrow_mut();
                    banks_mut.insert(bank_id, bank);
                    return Ok(Rc::new(RObject::boolean(true)));
                }
            }

            // 2. スクリプトまたは外部リソースファイルからのパース
            let tail = if p.extension().and_then(|s| s.to_str()) == Some("rb") {
                cli::compile_ruby_script_file(p)
                    .map(|(_, t, _)| t)
                    .unwrap_or_default()
            } else if p.is_file() {
                let content = std::fs::read_to_string(p).unwrap_or_default();
                if p.extension().and_then(|s| s.to_str()) == Some("map") {
                    let spr_path = p.with_extension("spr");
                    if spr_path.is_file() {
                        let spr_content = std::fs::read_to_string(&spr_path).unwrap_or_default();
                        format!("{}\n{}", content, spr_content)
                    } else {
                        content
                    }
                } else {
                    content
                }
            } else {
                path_str.clone()
            };

            let (parsed_sprites, parsed_banks, _) = parse_tail_resources_full(&tail, base_dir);
            let has_bank_directive = tail.lines().any(|l| {
                let t = l.trim();
                t.starts_with("@BANK")
                    || t.starts_with("@SHEET")
                    || t.starts_with("@SPRITE")
                    || t.starts_with("@PNG")
                    || t.starts_with("@B64")
            });
            if !has_bank_directive && parsed_sprites.is_empty() {
                return Ok(Rc::new(RObject::boolean(false)));
            }
            let source_bank = parsed_banks
                .get(&src_bank_id)
                .or_else(|| parsed_banks.get(&0))
                .or_else(|| parsed_banks.values().next());

            if let Some(src_bank) = source_bank {
                let mut loaded_bank = src_bank.clone();
                loaded_bank.id = bank_id;
                if !headless {
                    loaded_bank.build_texture();
                }
                let mut banks_mut = banks_for_load_bank.borrow_mut();
                banks_mut.insert(bank_id, loaded_bank);
                Ok(Rc::new(RObject::boolean(true)))
            } else {
                Ok(Rc::new(RObject::boolean(false)))
            }
        }),
    );

    // bank_size(bank_id = 0): バンクのシートサイズ [sheet_width, sheet_height] を返す
    let banks_for_bank_size = banks.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "bank_size",
        Box::new(move |_vm, args| {
            let bank_id = arg_i32(args, 0, 0);
            let banks_ref = banks_for_bank_size.borrow();
            let (w, h) = if let Some(bank) = banks_ref.get(&bank_id) {
                (bank.sheet_width as i64, bank.sheet_height as i64)
            } else {
                (BANK_WIDTH as i64, BANK_HEIGHT as i64)
            };
            Ok(Rc::new(RObject::array(vec![
                Rc::new(RObject::integer(w)),
                Rc::new(RObject::integer(h)),
            ])))
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
                    if tid < 0 {
                        tiles.push(Rc::new(RObject::nil()));
                    } else {
                        tiles.push(Rc::new(RObject::integer(tid as i64)));
                    }
                }
            }

            Ok(Rc::new(RObject::array(tiles)))
        }),
    );

    // load_resource_objects(path, filter_type = nil): 指定スクリプトまたは外部マップファイルから
    // オブジェクト一覧を読み込んで配列で返す。@OBJECTS がない場合は空配列を返す。
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "load_resource_objects",
        Box::new(|_vm, args| {
            let path_str = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            if path_str.is_empty() {
                return Ok(Rc::new(RObject::array(Vec::new())));
            }

            let filter_opt: Option<String> = args.get(1).and_then(|arg| {
                match &arg.value {
                    RValue::Symbol(sym) => Some(sym.name.clone()),
                    RValue::String(s, _) => String::from_utf8(s.borrow().clone()).ok(),
                    _ => None,
                }
            });

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

            let objs = parse_tail_objects(&tail);
            let mut result = Vec::new();
            for obj in objs.iter() {
                if let Some(ref filter) = filter_opt {
                    if &obj.obj_type != filter {
                        continue;
                    }
                }
                result.push(obj.to_ruby_hash());
            }

            Ok(Rc::new(RObject::array(result)))
        }),
    );

    // objects(filter_type = nil): 現在のマップに配置されたオブジェクト一覧を取得する。
    // filter_type が指定された場合はその type に一致するもののみを返す。
    let objects_for_api = objects.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "objects",
        Box::new(move |_vm, args| {
            let filter_opt: Option<String> = args.first().and_then(|arg| {
                match &arg.value {
                    RValue::Symbol(sym) => Some(sym.name.clone()),
                    RValue::String(s, _) => String::from_utf8(s.borrow().clone()).ok(),
                    _ => None,
                }
            });

            let list = objects_for_api.borrow();
            let mut result = Vec::new();
            for obj in list.iter() {
                if let Some(ref filter) = filter_opt {
                    if &obj.obj_type != filter {
                        continue;
                    }
                }
                result.push(obj.to_ruby_hash());
            }

            Ok(Rc::new(RObject::array(result)))
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

    // spawn_editor(kind = "spr", target_path = "game.rb"):
    // スプライトエディタ ("spr") またはタイルマップエディタ ("map") を別プロセスで起動する。
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "spawn_editor",
        Box::new(move |_vm, args| {
            let kind = args
                .first()
                .and_then(|v| match &v.value {
                    RValue::Symbol(sym) => Some(sym.name.clone()),
                    _ => String::try_from(v.as_ref()).ok(),
                })
                .unwrap_or_else(|| "spr".to_string());
            let target_path = args
                .get(1)
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_else(|| "game.rb".to_string());

            if headless {
                return Ok(Rc::new(RObject::boolean(true)));
            }

            #[cfg(not(target_arch = "wasm32"))]
            {
                if let Ok(exe) = std::env::current_exe() {
                    let ok = std::process::Command::new(exe)
                        .args(["edit", &kind, &target_path])
                        .spawn()
                        .is_ok();
                    return Ok(Rc::new(RObject::boolean(ok)));
                }
            }
            Ok(Rc::new(RObject::boolean(false)))
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
        let palettes_for_headless_blt = palettes.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "blt",
            Box::new(move |_vm, args| {
                let mut state = *state_for_headless_blt.borrow();
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
                let pal_arg = args.get(9);

                if let Some(arg) = pal_arg && !arg.is_nil() {
                    let pid = match &arg.value {
                        RValue::Integer(v) => *v as i32,
                        RValue::Float(v) => *v as i32,
                        _ => 0,
                    };
                    if let Some(target_pal) = palettes_for_headless_blt.borrow().get(&pid) {
                        state.palette_rgba = *target_pal;
                    }
                }

                if raw_w == 0.0 || raw_h == 0.0 || scale <= 0.0 {
                    return Ok(Rc::new(RObject::nil()));
                }
                let flip_x = raw_w < 0.0;
                let flip_y = raw_h < 0.0;
                let w = raw_w.abs();
                let h = raw_h.abs();
                if let Some(bank) = banks_for_headless_blt.borrow().get(&bank_id) {
                    if !state.is_default_palette() {
                        let _ = bank.apply_palette(&state.pal_map, state.palt_mask, &state.palette_rgba);
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

                let has_explicit_tiles = if let Some(arg3) = args.get(3) {
                    !matches!(arg3.value, RValue::Bool(_))
                } else {
                    false
                };

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
                                    let _ = sp.apply_palette(&state.pal_map, state.palt_mask, &state.palette_rgba);
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
                let sprites_ref = sprites_for_headless.borrow();
                let (draw_w, draw_h) = if has_explicit_tiles {
                    ((tile_w * 16) as f32, (tile_h * 16) as f32)
                } else if let Some(sp) = sprites_ref.get(&id) {
                    (sp.width as f32, sp.height as f32)
                } else {
                    (16.0, 16.0)
                };

                if let Some(bank) = banks_ref.get(&cur_bank_id) {
                    if !state.is_default_palette() {
                        let _ = bank.apply_palette(&state.pal_map, state.palt_mask, &state.palette_rgba);
                    }
                    let _ = compute_sprite_draw_params(
                        draw_w,
                        draw_h,
                        x,
                        y,
                        flip_x,
                        flip_y,
                        rotate,
                        scale,
                    );
                } else if let Some(sp) = sprites_ref.get(&id) {
                    if !state.is_default_palette() {
                        let _ = sp.apply_palette(&state.pal_map, state.palt_mask, &state.palette_rgba);
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
                        if tile_id < 0 {
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
                                let _ = bank.apply_palette(&state.pal_map, state.palt_mask, &state.palette_rgba);
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
                                let _ = sp.apply_palette(&state.pal_map, state.palt_mask, &state.palette_rgba);
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
        let input_state_for_btn = input_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "btn",
            Box::new(move |_vm, args| {
                let pressed = parse_button_arg(args, 0)
                    .map(|b| {
                        let st = input_state_for_btn.borrow();
                        if st.override_enabled {
                            st.is_down(b)
                        } else {
                            false
                        }
                    })
                    .unwrap_or(false);
                Ok(Rc::new(RObject::boolean(pressed)))
            }),
        );
        let input_state_for_btnp = input_state.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "btnp",
            Box::new(move |_vm, args| {
                let pressed = parse_button_arg(args, 0)
                    .map(|b| {
                        let st = input_state_for_btnp.borrow();
                        if st.override_enabled {
                            st.is_pressed(b)
                        } else {
                            false
                        }
                    })
                    .unwrap_or(false);
                Ok(Rc::new(RObject::boolean(pressed)))
            }),
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
        let banks_for_headless_bank_size = banks.clone();
        mrb_define_cmethod(
            vm,
            obj_class.clone(),
            "bank_size",
            Box::new(move |_vm, args| {
                let bank_id = arg_i32(args, 0, 0);
                let banks_ref = banks_for_headless_bank_size.borrow();
                let (w, h) = if let Some(bank) = banks_ref.get(&bank_id) {
                    (bank.sheet_width as i64, bank.sheet_height as i64)
                } else {
                    (BANK_WIDTH as i64, BANK_HEIGHT as i64)
                };
                Ok(Rc::new(RObject::array(vec![
                    Rc::new(RObject::integer(w)),
                    Rc::new(RObject::integer(h)),
                ])))
            }),
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

    // blt(x, y, bank, u, v, w, h, rotate = 0, scale = 1.0, pal = nil): ピクセル矩形転送
    let banks_for_blt = banks.clone();
    let state_for_blt = draw_state.clone();
    let palettes_for_blt = palettes.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "blt",
        Box::new(move |_vm, args| {
            let mut state = *state_for_blt.borrow();
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
            let pal_arg = args.get(9);

            if let Some(arg) = pal_arg && !arg.is_nil() {
                let pid = match &arg.value {
                    RValue::Integer(v) => *v as i32,
                    RValue::Float(v) => *v as i32,
                    _ => 0,
                };
                if let Some(target_pal) = palettes_for_blt.borrow().get(&pid) {
                    state.palette_rgba = *target_pal;
                }
            }

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
            let has_explicit_tiles = if let Some(arg3) = args.get(3) {
                !matches!(arg3.value, RValue::Bool(_))
            } else {
                false
            };

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
            let sprites_ref = sprites_for_spr.borrow();
            let (draw_w, draw_h) = if has_explicit_tiles {
                ((tile_w * 16) as f32, (tile_h * 16) as f32)
            } else if let Some(sp) = sprites_ref.get(&id) {
                (sp.width as f32, sp.height as f32)
            } else {
                (16.0, 16.0)
            };

            if let Some(bank) = banks_ref.get(&cur_bank_id) {
                let cols = (bank.sheet_width / 16).max(1) as i32;
                let u = ((id % cols) * 16) as f32;
                let v = ((id / cols) * 16) as f32;
                draw_bank_rect(
                    bank,
                    &state,
                    x,
                    y,
                    u,
                    v,
                    draw_w,
                    draw_h,
                    flip_x,
                    flip_y,
                    rotate,
                    scale,
                );
            } else if let Some(sprite) = sprites_ref.get(&id) {
                draw_sprite_transformed(sprite, &state, x, y, flip_x, flip_y, rotate, scale);
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
                    if tile_id < 0 {
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
                        let cols = (bank.sheet_width / 16).max(1) as i32;
                        let u = ((tile_id % cols) * 16) as f32;
                        let v = ((tile_id / cols) * 16) as f32;
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
    let input_state_for_btn = input_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "btn",
        Box::new(move |_vm, args| {
            let pressed = parse_button_arg(args, 0)
                .map(|b| {
                    let st = input_state_for_btn.borrow();
                    if st.override_enabled {
                        st.is_down(b)
                    } else {
                        is_button_down(b)
                    }
                })
                .unwrap_or(false);
            Ok(Rc::new(RObject::boolean(pressed)))
        }),
    );

    // btnp(id_or_sym): ボタンがこのフレームで押された瞬間か判定
    let input_state_for_btnp = input_state.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "btnp",
        Box::new(move |_vm, args| {
            let pressed = parse_button_arg(args, 0)
                .map(|b| {
                    let st = input_state_for_btnp.borrow();
                    if st.override_enabled {
                        st.is_pressed(b)
                    } else {
                        is_button_pressed(b)
                    }
                })
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

    let initial_objs_array: Vec<Rc<RObject>> =
        objects.borrow().iter().map(|o| o.to_ruby_hash()).collect();
    vm.globals.insert("$OBJECTS".to_string(), Rc::new(RObject::array(initial_objs_array)));
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptError {
    pub title: String,
    pub backtrace: Vec<String>,
    pub full_message: String,
}

impl std::fmt::Display for ScriptError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.full_message)
    }
}

impl std::error::Error for ScriptError {}

impl From<String> for ScriptError {
    fn from(s: String) -> Self {
        ScriptError {
            title: s.clone(),
            backtrace: Vec::new(),
            full_message: s,
        }
    }
}

impl From<&str> for ScriptError {
    fn from(s: &str) -> Self {
        Self::from(s.to_string())
    }
}

impl From<ScriptError> for String {
    fn from(err: ScriptError) -> Self {
        err.full_message
    }
}

impl ScriptError {
    pub fn from_vm(vm: &mut VM, context: &str) -> Self {
        if let Some(exc) = vm.exception.take() {
            let class_name = exc.class.module.sym_id.name.clone();
            let msg = exc.message.clone();
            let mut bt = exc.backtrace.clone();
            if bt.is_empty() {
                bt = vm.backtrace();
            }

            let title = if msg.is_empty() {
                class_name.clone()
            } else {
                format!("{}: {}", class_name, msg)
            };

            let mut lines = Vec::new();
            lines.push(format!("[Ruby Exception in `{}`] {}", context, title));
            for frame in &bt {
                if frame.ends_with(":in raise") {
                    continue;
                }
                lines.push(format!("  from {}", frame));
            }
            if lines.len() == 1 {
                for frame in &bt {
                    lines.push(format!("  from {}", frame));
                }
            }
            let full_message = lines.join("\n");
            ScriptError {
                title,
                backtrace: bt,
                full_message,
            }
        } else {
            let title = format!("Error in `{}`", context);
            let full_message = format!("[Ruby Error] {}", title);
            ScriptError {
                title,
                backtrace: Vec::new(),
                full_message,
            }
        }
    }

    pub fn from_message(title: &str, msg: &str) -> Self {
        ScriptError {
            title: title.to_string(),
            backtrace: Vec::new(),
            full_message: msg.to_string(),
        }
    }
}

pub fn wrap_text_lines(text: &str, max_chars: usize) -> Vec<String> {
    let mut result = Vec::new();
    for orig_line in text.lines() {
        if orig_line.chars().count() <= max_chars {
            result.push(orig_line.to_string());
        } else {
            let mut cur = String::new();
            for ch in orig_line.chars() {
                cur.push(ch);
                if cur.chars().count() >= max_chars {
                    result.push(cur);
                    cur = String::new();
                }
            }
            if !cur.is_empty() {
                result.push(cur);
            }
        }
    }
    result
}

pub fn render_error_screen(err: &ScriptError) {
    apply_gl_scissor(None);
    set_default_camera();
    clear_background(Color::new(0.06, 0.06, 0.06, 1.0));

    let win_w = screen_width();
    let win_h = screen_height();

    // 上部赤色ヘッダー
    let header_h = 32.0;
    draw_rectangle(0.0, 0.0, win_w, header_h, Color::new(0.75, 0.1, 0.1, 1.0));
    draw_text("RUBY ERROR OCCURRED", 14.0, 22.0, 20.0, WHITE);

    let red_color = Color::new(1.0, 0.3, 0.3, 1.0);
    let trace_color = Color::new(0.95, 0.5, 0.5, 1.0);
    let font_size = 18.0;
    let line_h = 22.0;
    let max_chars = ((win_w / 11.0) as usize).max(30);
    let mut y = 60.0;

    // タイトル（エラークラス名・メッセージ）
    for line in wrap_text_lines(&err.title, max_chars) {
        if y > win_h - 45.0 {
            break;
        }
        draw_text(&line, 16.0, y, font_size, red_color);
        y += line_h;
    }

    y += 10.0;

    // スタックトレース
    if !err.backtrace.is_empty() {
        draw_text(
            "Traceback (most recent call first):",
            16.0,
            y,
            16.0,
            Color::new(0.85, 0.85, 0.85, 1.0),
        );
        y += line_h;

        for frame in &err.backtrace {
            if frame.ends_with(":in raise") {
                continue;
            }
            if y > win_h - 45.0 {
                break;
            }
            let text = format!("  from {}", frame);
            for line in wrap_text_lines(&text, max_chars) {
                if y > win_h - 45.0 {
                    break;
                }
                draw_text(&line, 16.0, y, 15.0, trace_color);
                y += line_h;
            }
        }
    } else if !err.full_message.is_empty() {
        for line in err.full_message.lines() {
            if y > win_h - 45.0 {
                break;
            }
            for wrapped in wrap_text_lines(line, max_chars) {
                if y > win_h - 45.0 {
                    break;
                }
                draw_text(&wrapped, 16.0, y, 15.0, trace_color);
                y += line_h;
            }
        }
    }

    // 下部フッター案内バー
    let footer_h = 28.0;
    draw_rectangle(
        0.0,
        win_h - footer_h,
        win_w,
        footer_h,
        Color::new(0.12, 0.12, 0.12, 0.95),
    );
    draw_text(
        "Edit and save script to restart",
        16.0,
        win_h - 9.0,
        15.0,
        Color::new(0.8, 0.8, 0.8, 1.0),
    );
}

/// エラーオーバーレイ（トースト通知）の表示フレーム数（60fps環境で約3秒間）
pub const ERROR_OVERLAY_DURATION_FRAMES: u32 = 180;

pub fn render_error_overlay(err: &ScriptError) {
    apply_gl_scissor(None);
    set_default_camera();

    let win_w = screen_width();
    let font_size = 15.0;
    let line_h = 20.0;
    let pad_x = 12.0;
    let pad_y = 8.0;

    let max_chars = ((win_w - pad_x * 2.0) / 9.0).max(20.0) as usize;
    let mut lines: Vec<(String, Color)> = Vec::new();

    // 1. エラータイトル
    let header = format!("[SCRIPT ERROR] {}", err.title);
    for line in wrap_text_lines(&header, max_chars) {
        lines.push((line, Color::new(1.0, 0.35, 0.35, 1.0)));
        if lines.len() >= 2 {
            break;
        }
    }

    // 2. 発生箇所 (バックトレース先頭、または full_message 内の行)
    if lines.len() < 4 {
        if let Some(frame) = err.backtrace.iter().find(|f| !f.ends_with(":in raise")) {
            let trace_text = format!("  at {}", frame);
            for line in wrap_text_lines(&trace_text, max_chars) {
                lines.push((line, Color::new(0.9, 0.7, 0.7, 1.0)));
                if lines.len() >= 3 {
                    break;
                }
            }
        } else if !err.full_message.is_empty() {
            for orig_line in err.full_message.lines().skip(1) {
                let trimmed = orig_line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                for line in wrap_text_lines(trimmed, max_chars) {
                    lines.push((line, Color::new(0.9, 0.7, 0.7, 1.0)));
                    if lines.len() >= 3 {
                        break;
                    }
                }
                if lines.len() >= 3 {
                    break;
                }
            }
        }
    }

    let footer_h = 16.0;
    let box_h = pad_y * 2.0 + (lines.len() as f32) * line_h + footer_h;

    // 半透明背景ボックス
    draw_rectangle(0.0, 0.0, win_w, box_h, Color::new(0.12, 0.02, 0.02, 0.90));
    // 下端の境界線
    draw_rectangle(0.0, box_h - 2.0, win_w, 2.0, Color::new(0.85, 0.22, 0.22, 0.95));

    let mut y = pad_y + line_h * 0.75;
    for (text, col) in &lines {
        draw_text(text, pad_x, y, font_size, *col);
        y += line_h;
    }

    // ヒント案内
    draw_text(
        "Edit and save script to fix / hot-reload",
        pad_x,
        box_h - 6.0,
        12.0,
        Color::new(0.75, 0.75, 0.75, 0.85),
    );
}

pub struct GameRuntime {
    pub vm: VM,
    pub sprites: Rc<RefCell<HashMap<i32, SpriteData>>>,
    pub banks: Rc<RefCell<HashMap<i32, BankData>>>,
    pub active_spr_bank: Rc<RefCell<i32>>,
    pub active_map_bank: Rc<RefCell<i32>>,
    pub palettes: Rc<RefCell<HashMap<i32, PaletteRgba>>>,
    pub active_pal_bank: Rc<RefCell<i32>>,
    pub tilemap: Rc<RefCell<Tilemap>>,
    pub objects: Rc<RefCell<Vec<MapObject>>>,
    pub emoji_atlas: Rc<RefCell<emoji::EmojiAtlas>>,
    pub bitmap_font: Rc<BitmapFont>,
    pub draw_state: Rc<RefCell<DrawState>>,
    pub sound_bank: Rc<RefCell<sound::SoundBank>>,
    pub config: Rc<RefCell<AppConfig>>,
    pub restart_requested: Rc<RefCell<bool>>,
    pub input_state: Rc<RefCell<InputState>>,
    pub script_args: Vec<String>,
    initial_globals: HashMap<String, Rc<RObject>>,
    initial_tail_map: Tilemap,
    headless: bool,
}

impl GameRuntime {
    pub fn new(tail_data: &str, mrb_bytes: &[u8], headless: bool) -> Result<Self, ScriptError> {
        Self::new_with_args(tail_data, mrb_bytes, headless, &[])
    }

    pub fn new_with_args(
        tail_data: &str,
        mrb_bytes: &[u8],
        headless: bool,
        script_args: &[String],
    ) -> Result<Self, ScriptError> {
        let (mut sprites_map, mut banks_map, palettes_map) = parse_tail_resources_full(tail_data, None);
        let tail_map = parse_tail_map(tail_data);
        let tail_objects = parse_tail_objects(tail_data);
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
        let palettes = Rc::new(RefCell::new(palettes_map));
        let active_pal_bank = Rc::new(RefCell::new(0));
        let tilemap = Rc::new(RefCell::new(tail_map.clone()));
        let objects = Rc::new(RefCell::new(tail_objects));
        let emoji_atlas = Rc::new(RefCell::new(emoji::EmojiAtlas::new()));
        let bitmap_font = Rc::new(BitmapFont::new(!headless));
        let initial_draw_state = DrawState::default();
        let draw_state = Rc::new(RefCell::new(initial_draw_state));
        let sound_bank = Rc::new(RefCell::new(sound::SoundBank::new(
            HashMap::new(),
            HashMap::new(),
        )));
        let config = Rc::new(RefCell::new(AppConfig::default()));
        let restart_requested = Rc::new(RefCell::new(false));
        let input_state = Rc::new(RefCell::new(InputState::new()));

        register_engine_api(
            &mut vm,
            sprites.clone(),
            banks.clone(),
            active_spr_bank.clone(),
            active_map_bank.clone(),
            palettes.clone(),
            active_pal_bank.clone(),
            tilemap.clone(),
            objects.clone(),
            emoji_atlas.clone(),
            bitmap_font.clone(),
            draw_state.clone(),
            config.clone(),
            restart_requested.clone(),
            input_state.clone(),
            headless,
        );
        register_sound_api(&mut vm, sound_bank.clone());

        if let Err(_) = vm.run() {
            return Err(ScriptError::from_vm(&mut vm, "top-level"));
        }

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
            palettes,
            active_pal_bank,
            tilemap,
            objects,
            emoji_atlas,
            bitmap_font,
            draw_state,
            sound_bank,
            config,
            restart_requested,
            input_state,
            script_args: script_args.to_vec(),
            initial_globals,
            initial_tail_map,
            headless,
        })
    }

    pub fn is_restart_requested(&self) -> bool {
        *self.restart_requested.borrow()
    }

    pub fn request_restart(&self) {
        *self.restart_requested.borrow_mut() = true;
    }

    pub fn reset_restart_request(&self) {
        *self.restart_requested.borrow_mut() = false;
    }

    /// ランタイムを初期状態から再生成してリスタートする（トップレベルを再実行し、グローバル変数も初期化）
    pub fn restart(&mut self, tail_data: &str, mrb_bytes: &[u8]) -> Result<(), ScriptError> {
        let new_rt = Self::new_with_args(tail_data, mrb_bytes, self.headless, &self.script_args)?;
        if *self.config.borrow() != AppConfig::default() {
            let cfg = self.config.borrow().clone();
            *new_rt.config.borrow_mut() = cfg.clone();
            new_rt.draw_state.borrow_mut().screen_w = cfg.screen_width as i32;
            new_rt.draw_state.borrow_mut().screen_h = cfg.screen_height as i32;
        }
        *self = new_rt;
        Ok(())
    }

    /// グローバル変数（`$x`, `$y`, `$t` 等）や実行時タイルマップの操作状態を維持したまま、
    /// メソッド定義とスプライト・マップ定義をホットリロードする。
    /// ただしスクリプト上のトップレベル初期値や `@MAP` 自体が書き換えられた場合は新しい定義を採用する。
    pub fn hot_reload(&mut self, new_tail_data: &str, new_mrb_bytes: &[u8]) -> Result<(), ScriptError> {
        let (mut new_sprites_map, mut new_banks_map, new_palettes_map) = parse_tail_resources_full(new_tail_data, None);
        let new_tail_map = parse_tail_map(new_tail_data);
        let new_tail_objects = parse_tail_objects(new_tail_data);
        let (mut new_sfx_map, mut new_music_map) = sound::parse_tail_sounds(new_tail_data);

        *self.objects.borrow_mut() = new_tail_objects;
        *self.palettes.borrow_mut() = new_palettes_map;
        *self.active_pal_bank.borrow_mut() = 0;

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
            let def_pal = self.config.borrow().default_palette;
            if def_pal > 0 && let Some(pal) = self.palettes.borrow().get(&def_pal) {
                ds.active_pal_bank = def_pal;
                ds.palette_rgba = *pal;
            }
        }
        register_engine_api(
            &mut new_vm,
            self.sprites.clone(),
            self.banks.clone(),
            self.active_spr_bank.clone(),
            self.active_map_bank.clone(),
            self.palettes.clone(),
            self.active_pal_bank.clone(),
            temp_tilemap.clone(),
            self.objects.clone(),
            self.emoji_atlas.clone(),
            self.bitmap_font.clone(),
            self.draw_state.clone(),
            self.config.clone(),
            self.restart_requested.clone(),
            self.input_state.clone(),
            self.headless,
        );
        register_sound_api(&mut new_vm, self.sound_bank.clone());

        if let Err(_) = new_vm.run() {
            return Err(ScriptError::from_vm(&mut new_vm, "top-level reload"));
        }

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
            self.palettes.clone(),
            self.active_pal_bank.clone(),
            self.tilemap.clone(),
            self.objects.clone(),
            self.emoji_atlas.clone(),
            self.bitmap_font.clone(),
            self.draw_state.clone(),
            self.config.clone(),
            self.restart_requested.clone(),
            self.input_state.clone(),
            self.headless,
        );

        let new_initial_globals = snapshot_globals(&new_vm);

        // 以前のVMから現在のグローバル変数を引き継ぐ
        for (name, live_val) in &self.vm.globals {
            if matches!(name.as_str(), "$SPRITES" | "$MAP" | "$SFX" | "$MUSIC" | "$OBJECTS") {
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

    pub fn call_update_result(&mut self) -> Result<(), ScriptError> {
        mrb_funcall(&mut self.vm, None, "update", &[])
            .map(|_| ())
            .map_err(|_| ScriptError::from_vm(&mut self.vm, "update"))
    }

    pub fn call_update(&mut self) {
        if let Err(e) = self.call_update_result() {
            eprintln!("{}", e.full_message);
        }
    }

    pub fn call_draw_result(&mut self) -> Result<(), ScriptError> {
        if !self.headless {
            apply_gl_scissor(self.draw_state.borrow().clip);
        }
        let res = mrb_funcall(&mut self.vm, None, "draw", &[])
            .map(|_| ())
            .map_err(|_| ScriptError::from_vm(&mut self.vm, "draw"));
        if !self.headless {
            apply_gl_scissor(None);
        }
        res
    }

    pub fn call_draw(&mut self) {
        if let Err(e) = self.call_draw_result() {
            eprintln!("{}", e.full_message);
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
    reload_banner_text: &str,
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
            reload_banner_text,
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

#[cfg(not(target_arch = "wasm32"))]
pub fn scale_rgba_nearest(
    src: &[u8],
    width: usize,
    height: usize,
    scale: usize,
) -> (Vec<u8>, usize, usize) {
    if scale <= 1 {
        return (src.to_vec(), width, height);
    }
    let out_w = width * scale;
    let out_h = height * scale;
    let mut dst = vec![0u8; out_w * out_h * 4];

    for y in 0..height {
        let src_row_start = y * width * 4;
        for sy in 0..scale {
            let dst_y = y * scale + sy;
            let dst_row_start = dst_y * out_w * 4;
            for x in 0..width {
                let px_start = src_row_start + x * 4;
                let px = &src[px_start..px_start + 4];
                for sx in 0..scale {
                    let dst_x = x * scale + sx;
                    let target = dst_row_start + dst_x * 4;
                    dst[target..target + 4].copy_from_slice(px);
                }
            }
        }
    }
    (dst, out_w, out_h)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn encode_screenshot_png(
    rgba: &[u8],
    width: usize,
    height: usize,
    scale: usize,
) -> Result<(Vec<u8>, usize, usize), String> {
    if rgba.len() != width * height * 4 {
        return Err(format!(
            "Invalid RGBA buffer length: expected {}, got {}",
            width * height * 4,
            rgba.len()
        ));
    }
    let mut bytes = rgba.to_vec();
    let row_bytes = width * 4;

    // RenderTarget は OpenGL のため上下反転しているのを正立させる
    for y in 0..(height / 2) {
        let top_start = y * row_bytes;
        let bottom_start = (height - 1 - y) * row_bytes;
        for i in 0..row_bytes {
            bytes.swap(top_start + i, bottom_start + i);
        }
    }

    let (scaled_bytes, out_w, out_h) = scale_rgba_nearest(&bytes, width, height, scale);

    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, out_w as u32, out_h as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Fast);
        let mut writer = encoder
            .write_header()
            .map_err(|e| format!("PNG write_header error: {:?}", e))?;
        writer
            .write_image_data(&scaled_bytes)
            .map_err(|e| format!("PNG write_image_data error: {:?}", e))?;
    }
    Ok((out, out_w, out_h))
}

#[cfg(not(target_arch = "wasm32"))]
pub fn save_screenshot_from_render_target(
    render_target: &RenderTarget,
    scale: usize,
    custom_path: Option<&std::path::Path>,
) -> Result<(String, usize, usize), String> {
    let image = render_target.texture.get_texture_data();
    let width = image.width as usize;
    let height = image.height as usize;
    let (png_bytes, out_w, out_h) = encode_screenshot_png(&image.bytes, width, height, scale)?;

    let filepath = if let Some(p) = custom_path {
        if let Some(parent) = p.parent() {
            if !parent.as_os_str().is_empty() && !parent.exists() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| format!("Failed to create screenshot dir: {}", e))?;
            }
        }
        p.to_string_lossy().into_owned()
    } else {
        let dir = std::path::Path::new("screenshots");
        if !dir.exists() {
            std::fs::create_dir_all(dir).map_err(|e| format!("Failed to create screenshots dir: {}", e))?;
        }

        let mut filepath = String::new();
        for i in 1..=9999 {
            let candidate = format!("screenshots/screenshot_{:03}.png", i);
            if !std::path::Path::new(&candidate).exists() {
                filepath = candidate;
                break;
            }
        }
        if filepath.is_empty() {
            filepath = format!(
                "screenshots/screenshot_{}.png",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis()
            );
        }
        filepath
    };

    std::fs::write(&filepath, png_bytes)
        .map_err(|e| format!("Failed to write screenshot file: {}", e))?;

    Ok((filepath, out_w, out_h))
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
    initial_error: Option<ScriptError>,
    screenshot_path: Option<std::path::PathBuf>,
    screenshot_frames: u32,
) {
    let mut current_error: Option<ScriptError> = initial_error;
    let mut runtime_opt: Option<Box<GameRuntime>> = None;
    let mut cur_virt_w = SCREEN_WIDTH as u32;
    let mut cur_virt_h = SCREEN_HEIGHT as u32;

    if current_error.is_none() {
        let initial_config = parse_config_from_source(&initial_source);
        match GameRuntime::new_with_args(&initial_tail, &initial_mrb, false, &script_args) {
            Ok(rt) => {
                if initial_config != AppConfig::default() {
                    let mut cfg = rt.config.borrow_mut();
                    *cfg = initial_config;
                    rt.draw_state.borrow_mut().screen_w = cfg.screen_width as i32;
                    rt.draw_state.borrow_mut().screen_h = cfg.screen_height as i32;
                }
                cur_virt_w = rt.config.borrow().screen_width;
                cur_virt_h = rt.config.borrow().screen_height;
                runtime_opt = Some(Box::new(rt));
            }
            Err(e) => {
                eprintln!("[uk run] Runtime error in `{}`:\n{}", script_path.display(), e.full_message);
                current_error = Some(e);
            }
        }
    }

    let (mut render_target, mut virtual_camera) = create_virtual_screen(cur_virt_w, cur_virt_h);
    if let Some(ref mut rt) = runtime_opt {
        rt.preload_audio().await;
    }

    let mut last_snapshot = bundle::get_script_and_resources_snapshot(&script_path);
    let mut frame_count: u64 = 0;
    let mut reload_banner_frames: u32 = 0;
    let mut reload_banner_text: String = "HOT RELOADED".to_string();
    let mut error_overlay_frames: u32 = 0;

    loop {
        frame_count = frame_count.wrapping_add(1);

        // リスタート要求判定（ショートカットキー F5 / Ctrl+R / Cmd+R、または Ruby スクリプトからの restart / reset 呼び出し）
        let restart_requested = is_restart_key_pressed()
            || runtime_opt.as_ref().map_or(false, |rt| rt.is_restart_requested());

        if restart_requested {
            last_snapshot = bundle::get_script_and_resources_snapshot(&script_path);
            match cli::compile_ruby_script_file(&script_path) {
                Ok((new_source, new_tail, new_mrb)) => {
                    let new_parsed_config = parse_config_from_source(&new_source);
                    match GameRuntime::new_with_args(&new_tail, &new_mrb, false, &script_args) {
                        Ok(mut new_rt) => {
                            if new_parsed_config != AppConfig::default() {
                                let mut cfg = new_rt.config.borrow_mut();
                                *cfg = new_parsed_config;
                                new_rt.draw_state.borrow_mut().screen_w = cfg.screen_width as i32;
                                new_rt.draw_state.borrow_mut().screen_h = cfg.screen_height as i32;
                            }
                            new_rt.preload_audio().await;
                            println!("[uk run] Restarted `{}`", script_path.display());
                            current_error = None;
                            error_overlay_frames = 0;
                            reload_banner_text = "RESTARTED".to_string();
                            reload_banner_frames = 60;

                            let (new_w, new_h) = {
                                let cfg = new_rt.config.borrow();
                                (cfg.screen_width, cfg.screen_height)
                            };
                            if new_w != cur_virt_w || new_h != cur_virt_h {
                                cur_virt_w = new_w;
                                cur_virt_h = new_h;
                                let (rt_screen, cam) = create_virtual_screen(cur_virt_w, cur_virt_h);
                                render_target = rt_screen;
                                virtual_camera = cam;
                            }
                            runtime_opt = Some(Box::new(new_rt));
                        }
                        Err(restart_err) => {
                            eprintln!(
                                "[uk run] Restart error in `{}`:\n{}",
                                script_path.display(),
                                restart_err.full_message
                            );
                            current_error = Some(restart_err);
                            error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
                        }
                    }
                }
                Err(e) => {
                    eprintln!(
                        "[uk run] Compile error on restart in `{}`:\n{}",
                        script_path.display(),
                        e
                    );
                    current_error = Some(ScriptError {
                        title: "Syntax / Compilation Error".to_string(),
                        backtrace: Vec::new(),
                        full_message: e,
                    });
                    error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
                }
            }
        } else if frame_count.is_multiple_of(15) {
            // 15フレーム (~0.25秒) ごとにスクリプトファイルおよび外部リソースの変更を検知してホットリロード / 再スタート
            let current_snapshot = bundle::get_script_and_resources_snapshot(&script_path);
            if current_snapshot != last_snapshot {
                last_snapshot = current_snapshot;
                match cli::compile_ruby_script_file(&script_path) {
                    Ok((new_source, new_tail, new_mrb)) => {
                        let new_parsed_config = parse_config_from_source(&new_source);
                        if let Some(ref mut rt) = runtime_opt {
                            // 既存ランタイムがある場合はホットリロード（コード更新＆状態保持）を試みる
                            if new_parsed_config != AppConfig::default() {
                                let mut cfg = rt.config.borrow_mut();
                                *cfg = new_parsed_config.clone();
                            }
                            match rt.hot_reload(&new_tail, &new_mrb) {
                                Ok(()) => {
                                    rt.preload_audio().await;
                                    println!("[uk run] Hot-reloaded `{}`", script_path.display());
                                    current_error = None;
                                    error_overlay_frames = 0;
                                    reload_banner_text = "HOT RELOADED".to_string();
                                    reload_banner_frames = 60;
                                    let (new_w, new_h) = {
                                        let cfg = rt.config.borrow();
                                        (cfg.screen_width, cfg.screen_height)
                                    };
                                    if new_w != cur_virt_w || new_h != cur_virt_h {
                                        cur_virt_w = new_w;
                                        cur_virt_h = new_h;
                                        let (rt_screen, cam) = create_virtual_screen(cur_virt_w, cur_virt_h);
                                        render_target = rt_screen;
                                        virtual_camera = cam;
                                    }
                                }
                                Err(_e) => {
                                    // hot_reload に失敗した場合はインスタンス再生成での復帰を試みる
                                    match GameRuntime::new_with_args(&new_tail, &new_mrb, false, &script_args) {
                                        Ok(mut new_rt) => {
                                            if new_parsed_config != AppConfig::default() {
                                                let mut cfg = new_rt.config.borrow_mut();
                                                *cfg = new_parsed_config;
                                                new_rt.draw_state.borrow_mut().screen_w = cfg.screen_width as i32;
                                                new_rt.draw_state.borrow_mut().screen_h = cfg.screen_height as i32;
                                            }
                                            new_rt.preload_audio().await;
                                            println!("[uk run] Restarted `{}`", script_path.display());
                                            current_error = None;
                                            error_overlay_frames = 0;
                                            reload_banner_text = "RESTARTED".to_string();
                                            reload_banner_frames = 60;

                                            let (new_w, new_h) = {
                                                let cfg = new_rt.config.borrow();
                                                (cfg.screen_width, cfg.screen_height)
                                            };
                                            if new_w != cur_virt_w || new_h != cur_virt_h {
                                                cur_virt_w = new_w;
                                                cur_virt_h = new_h;
                                                let (rt_screen, cam) = create_virtual_screen(cur_virt_w, cur_virt_h);
                                                render_target = rt_screen;
                                                virtual_camera = cam;
                                            }
                                            runtime_opt = Some(Box::new(new_rt));
                                        }
                                        Err(restart_err) => {
                                            eprintln!(
                                                "[uk run] Hot-reload and restart error in `{}`:\n{}",
                                                script_path.display(),
                                                restart_err.full_message
                                            );
                                            current_error = Some(restart_err);
                                            error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
                                        }
                                    }
                                }
                            }
                        } else {
                            // ランタイムが未初期化だった場合（初回エラー等）は新規生成
                            match GameRuntime::new_with_args(&new_tail, &new_mrb, false, &script_args) {
                                Ok(mut new_rt) => {
                                    if new_parsed_config != AppConfig::default() {
                                        let mut cfg = new_rt.config.borrow_mut();
                                        *cfg = new_parsed_config;
                                        new_rt.draw_state.borrow_mut().screen_w = cfg.screen_width as i32;
                                        new_rt.draw_state.borrow_mut().screen_h = cfg.screen_height as i32;
                                    }
                                    new_rt.preload_audio().await;
                                    println!("[uk run] Restarted `{}`", script_path.display());
                                    current_error = None;
                                    error_overlay_frames = 0;
                                    reload_banner_text = "RESTARTED".to_string();
                                    reload_banner_frames = 60;

                                    let (new_w, new_h) = {
                                        let cfg = new_rt.config.borrow();
                                        (cfg.screen_width, cfg.screen_height)
                                    };
                                    if new_w != cur_virt_w || new_h != cur_virt_h {
                                        cur_virt_w = new_w;
                                        cur_virt_h = new_h;
                                        let (rt_screen, cam) = create_virtual_screen(cur_virt_w, cur_virt_h);
                                        render_target = rt_screen;
                                        virtual_camera = cam;
                                    }
                                    runtime_opt = Some(Box::new(new_rt));
                                }
                                Err(e) => {
                                    eprintln!(
                                        "[uk run] Restart runtime error in `{}`:\n{}",
                                        script_path.display(),
                                        e.full_message
                                    );
                                    current_error = Some(e);
                                    error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
                                }
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!(
                            "[uk run] Compile error in `{}`:\n{}",
                            script_path.display(),
                            e
                        );
                        current_error = Some(ScriptError {
                            title: "Syntax / Compilation Error".to_string(),
                            backtrace: Vec::new(),
                            full_message: e,
                        });
                        error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
                    }
                }
            }
        }

        if let Some(ref rt) = runtime_opt {
            if is_key_pressed(KeyCode::F3) {
                let mut cfg = rt.config.borrow_mut();
                cfg.show_fps = !cfg.show_fps;
            }
        }

        if runtime_opt.is_none() {
            if let Some(ref err) = current_error {
                render_error_screen(err);
            }
        } else if let Some(ref mut rt) = runtime_opt {
            if let Err(err) = rt.call_update_result() {
                if current_error.as_ref() != Some(&err) {
                    eprintln!("{}", err.full_message);
                }
                current_error = Some(err);
                error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
            }
            rt.process_audio().await;

            set_camera(&virtual_camera);
            if let Err(err) = rt.call_draw_result() {
                if current_error.as_ref() != Some(&err) {
                    eprintln!("{}", err.full_message);
                }
                current_error = Some(err);
                error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
            }

            let show_fps = rt.config.borrow().show_fps;
            present_virtual_screen(
                &render_target,
                cur_virt_w,
                cur_virt_h,
                reload_banner_frames,
                &reload_banner_text,
                show_fps,
            );
            reload_banner_frames = reload_banner_frames.saturating_sub(1);

            if let Some(ref auto_path) = screenshot_path {
                if frame_count >= screenshot_frames as u64 {
                    let scale = rt
                        .config
                        .borrow()
                        .window_scale
                        .round()
                        .max(1.0) as usize;
                    match save_screenshot_from_render_target(&render_target, scale, Some(auto_path)) {
                        Ok((path, out_w, out_h)) => {
                            println!(
                                "[screenshot] Auto saved to {} ({}x{}, {}x) after {} frames",
                                path, out_w, out_h, scale, frame_count
                            );
                            std::process::exit(0);
                        }
                        Err(err) => {
                            eprintln!("[screenshot] Auto screenshot failed: {}", err);
                            std::process::exit(1);
                        }
                    }
                }
            }

            if is_key_pressed(KeyCode::F12) {
                let scale = rt
                    .config
                    .borrow()
                    .window_scale
                    .round()
                    .max(1.0) as usize;
                match save_screenshot_from_render_target(&render_target, scale, None) {
                    Ok((path, out_w, out_h)) => {
                        println!("[screenshot] Saved to {} ({}x{}, {}x)", path, out_w, out_h, scale);
                        reload_banner_text = format!("SCREENSHOT: {} ({}x)", path, scale);
                        reload_banner_frames = 90;
                    }
                    Err(err) => {
                        eprintln!("[screenshot] Failed: {}", err);
                    }
                }
            }

            if error_overlay_frames > 0 {
                if let Some(ref err) = current_error {
                    render_error_overlay(err);
                }
                error_overlay_frames = error_overlay_frames.saturating_sub(1);
                if error_overlay_frames == 0 {
                    current_error = None;
                }
            }
        }

        next_frame().await;
    }
}

#[cfg(not(target_arch = "wasm32"))]
async fn run_embedded_game_with_args(
    tail_data: String,
    mrb_bytes: Vec<u8>,
    script_args: Vec<String>,
) {
    let mut runtime = match GameRuntime::new_with_args(&tail_data, &mrb_bytes, false, &script_args) {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("{}", e.full_message);
            return;
        }
    };

    let (mut virt_w, mut virt_h) = {
        let cfg = runtime.config.borrow();
        (cfg.screen_width, cfg.screen_height)
    };
    let (mut render_target, mut virtual_camera) = create_virtual_screen(virt_w, virt_h);
    runtime.preload_audio().await;
    let mut reload_banner_frames: u32 = 0;
    let mut reload_banner_text: String = String::new();

    loop {
        if is_key_pressed(KeyCode::F3) {
            let mut cfg = runtime.config.borrow_mut();
            cfg.show_fps = !cfg.show_fps;
        }

        if is_restart_key_pressed() || runtime.is_restart_requested() {
            match GameRuntime::new_with_args(&tail_data, &mrb_bytes, false, &script_args) {
                Ok(mut new_rt) => {
                    new_rt.preload_audio().await;
                    reload_banner_text = "RESTARTED".to_string();
                    reload_banner_frames = 60;
                    let (new_w, new_h) = {
                        let cfg = new_rt.config.borrow();
                        (cfg.screen_width, cfg.screen_height)
                    };
                    if new_w != virt_w || new_h != virt_h {
                        virt_w = new_w;
                        virt_h = new_h;
                        let (rt_screen, cam) = create_virtual_screen(virt_w, virt_h);
                        render_target = rt_screen;
                        virtual_camera = cam;
                    }
                    runtime = new_rt;
                }
                Err(e) => {
                    eprintln!("[embedded] Restart error: {}", e.full_message);
                }
            }
        }

        runtime.call_update();
        runtime.process_audio().await;

        set_camera(&virtual_camera);
        runtime.call_draw();

        let show_fps = runtime.config.borrow().show_fps;
        present_virtual_screen(
            &render_target,
            virt_w,
            virt_h,
            reload_banner_frames,
            &reload_banner_text,
            show_fps,
        );
        reload_banner_frames = reload_banner_frames.saturating_sub(1);

        if is_key_pressed(KeyCode::F12) {
            let scale = runtime
                .config
                .borrow()
                .window_scale
                .round()
                .max(1.0) as usize;
            match save_screenshot_from_render_target(&render_target, scale, None) {
                Ok((path, out_w, out_h)) => {
                    println!("[screenshot] Saved to {} ({}x{}, {}x)", path, out_w, out_h, scale);
                    reload_banner_text = format!("SCREENSHOT: {} ({}x)", path, scale);
                    reload_banner_frames = 90;
                }
                Err(err) => {
                    eprintln!("[screenshot] Failed: {}", err);
                }
            }
        }

        next_frame().await;
    }
}

/// Ruby スクリプト文字列をコンパイルし、ヘッドレス環境で指定フレーム数だけ `update` / `draw` を実行して
/// 構文エラーや `NoMethodError` 等の実行時例外が発生しないかを検証する（デフォルトでガチャキー入力検証を含む）。
#[cfg(not(target_arch = "wasm32"))]
pub fn verify_ruby_script_headless(full_source: &str, frames: u32) -> Result<(), String> {
    verify_ruby_script_headless_ex(full_source, frames, true)
}

/// ガチャキー（擬似ボタン連打）の有効・無効を指定可能なヘッドレス検証。
#[cfg(not(target_arch = "wasm32"))]
pub fn verify_ruby_script_headless_ex(
    full_source: &str,
    frames: u32,
    gacha: bool,
) -> Result<(), String> {
    let (tail_data, mrb_bytes) =
        cli::compile_ruby_script_str_with_filename(full_source, Some("game.rb"))?;
    let mut runtime = GameRuntime::new(&tail_data, &mrb_bytes, true).map_err(|e| e.full_message)?;
    let mut fuzzer = InputFuzzer::new(0xdeadbeef);
    for frame in 1..=frames {
        let input_desc = if gacha {
            let btns = fuzzer.next_frame();
            let desc = format!(
                "[{}]",
                btns.iter()
                    .map(|b| b.as_name())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
            runtime.input_state.borrow_mut().set_frame_buttons(btns);
            desc
        } else {
            "[]".to_string()
        };

        runtime
            .call_update_result()
            .map_err(|e| {
                if gacha {
                    format!(
                        "Runtime error at frame {} in `update` (inputs: {}): {}",
                        frame, input_desc, e.full_message
                    )
                } else {
                    format!("Runtime error at frame {} in `update`: {}", frame, e.full_message)
                }
            })?;
        runtime
            .call_draw_result()
            .map_err(|e| format!("Runtime error at frame {} in `draw`: {}", frame, e.full_message))?;
    }
    Ok(())
}

/// 指定ファイルから外部リソース等を含めて読み込み、構文エラーや実行時例外が発生しないかを検証する。
#[cfg(not(target_arch = "wasm32"))]
pub fn verify_ruby_script_file_headless(
    path: &Path,
    frames: u32,
    gacha: bool,
) -> Result<(), String> {
    if !path.exists() {
        return Err(format!("Target script '{}' not found.", path.display()));
    }
    let (_source, tail_data, mrb_bytes) = cli::compile_ruby_script_file(path)?;
    let mut runtime = GameRuntime::new(&tail_data, &mrb_bytes, true).map_err(|e| e.full_message)?;
    let mut fuzzer = InputFuzzer::new(0xdeadbeef);
    for frame in 1..=frames {
        let input_desc = if gacha {
            let btns = fuzzer.next_frame();
            let desc = format!(
                "[{}]",
                btns.iter()
                    .map(|b| b.as_name())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
            runtime.input_state.borrow_mut().set_frame_buttons(btns);
            desc
        } else {
            "[]".to_string()
        };

        runtime
            .call_update_result()
            .map_err(|e| {
                if gacha {
                    format!(
                        "Runtime error at frame {} in `update` (inputs: {}): {}",
                        frame, input_desc, e.full_message
                    )
                } else {
                    format!("Runtime error at frame {} in `update`: {}", frame, e.full_message)
                }
            })?;
        runtime
            .call_draw_result()
            .map_err(|e| format!("Runtime error at frame {} in `draw`: {}", frame, e.full_message))?;
    }
    Ok(())
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
        cli::CliAction::New(opts) => {
            if let Err(err) = cli::cmd_new(&opts) {
                eprintln!("Error: {}", err);
                std::process::exit(1);
            }
        }
        cli::CliAction::Generate {
            prompt,
            output_path,
            model,
            api_key,
        } => {
            if let Err(err) = cli::cmd_generate(
                &prompt,
                &output_path,
                model.as_deref(),
                api_key.as_deref(),
            ) {
                eprintln!("Error: {}", err);
                std::process::exit(1);
            }
        }
        cli::CliAction::Examples { dest_dir } => {
            if let Err(err) = cli::cmd_examples(&dest_dir) {
                eprintln!("Error: {}", err);
                std::process::exit(1);
            }
        }
        cli::CliAction::Edit { kind, target_path } => {
            if kind == cli::EditorKind::All {
                let _ = cli::spawn_editor_processes(cli::EditorKind::Tilemap, &target_path);
            }
            let (editor_src, editor_filename) = match kind {
                cli::EditorKind::Sprite | cli::EditorKind::All => {
                    (cli::EMBEDDED_SPRITE_EDITOR, "sprite_editor.rb")
                }
                cli::EditorKind::Tilemap => {
                    (cli::EMBEDDED_TILEMAP_EDITOR, "tilemap_editor.rb")
                }
            };
            let (tail_data, mrb_bytes) =
                match cli::compile_ruby_script_str_with_filename(editor_src, Some(editor_filename)) {
                    Ok(res) => res,
                    Err(err) => {
                        eprintln!("Failed to compile built-in editor: {}", err);
                        std::process::exit(1);
                    }
                };
            let parsed_cfg = parse_config_from_source(editor_src);
            let title = format!("{} - {}", parsed_cfg.title, target_path.display());
            let args = vec![target_path.to_string_lossy().to_string()];
            macroquad::Window::from_config(
                window_conf_with_title_and_size(
                    &title,
                    parsed_cfg.window_width(),
                    parsed_cfg.window_height(),
                ),
                run_embedded_game_with_args(tail_data, mrb_bytes, args),
            );
        }
        cli::CliAction::Check {
            script_path,
            frames,
            gacha,
        } => {
            match verify_ruby_script_file_headless(&script_path, frames, gacha) {
                Ok(()) => {
                    let mode_str = if gacha { " (gacha-key mash mode)" } else { "" };
                    println!(
                        "✓ [uk check] '{}': Syntax and {} frame(s) headless execution verified successfully{}.",
                        script_path.display(),
                        frames,
                        mode_str
                    );
                }
                Err(err) => {
                    eprintln!(
                        "✗ [uk check] Verification failed for '{}':\n{}",
                        script_path.display(),
                        err
                    );
                    std::process::exit(1);
                }
            }
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
        cli::CliAction::RunWithEdit {
            script_path,
            script_args,
            editor_kind,
        } => {
            let _editor_children = cli::spawn_editor_processes(editor_kind, &script_path);
            let compile_res = cli::compile_ruby_script_file(&script_path);
            let initial_error = match &compile_res {
                Ok(_) => None,
                Err(err) => {
                    eprintln!("[uk run] Initial compilation error in `{}`:\n{}", script_path.display(), err);
                    Some(ScriptError {
                        title: "Syntax / Compilation Error".to_string(),
                        backtrace: Vec::new(),
                        full_message: err.clone(),
                    })
                }
            };
            let (initial_source, tail_data, mrb_bytes) = compile_res.unwrap_or_else(|_| (String::new(), String::new(), Vec::new()));
            let parsed_cfg = parse_config_from_source(&initial_source);
            let title = if parsed_cfg.title != "Usakame Retro Engine" {
                parsed_cfg.title.clone()
            } else {
                format!("Usakame - {}", script_path.display())
            };
            macroquad::Window::from_config(
                window_conf_with_title_and_size(&title, parsed_cfg.window_width(), parsed_cfg.window_height()),
                run_native_with_hot_reload(
                    script_path,
                    script_args,
                    initial_source,
                    tail_data,
                    mrb_bytes,
                    initial_error,
                    None,
                    10,
                ),
            );
        }
        cli::CliAction::Run {
            script_path,
            script_args,
            screenshot_path,
            screenshot_frames,
        } => {
            let compile_res = cli::compile_ruby_script_file(&script_path);
            let initial_error = match &compile_res {
                Ok(_) => None,
                Err(err) => {
                    eprintln!("[uk run] Initial compilation error in `{}`:\n{}", script_path.display(), err);
                    Some(ScriptError {
                        title: "Syntax / Compilation Error".to_string(),
                        backtrace: Vec::new(),
                        full_message: err.clone(),
                    })
                }
            };
            let (initial_source, tail_data, mrb_bytes) = compile_res.unwrap_or_else(|_| (String::new(), String::new(), Vec::new()));
            let parsed_cfg = parse_config_from_source(&initial_source);
            let title = if parsed_cfg.title != "Usakame Retro Engine" {
                parsed_cfg.title.clone()
            } else {
                format!("Usakame - {}", script_path.display())
            };
            macroquad::Window::from_config(
                window_conf_with_title_and_size(&title, parsed_cfg.window_width(), parsed_cfg.window_height()),
                run_native_with_hot_reload(
                    script_path,
                    script_args,
                    initial_source,
                    tail_data,
                    mrb_bytes,
                    initial_error,
                    screenshot_path,
                    screenshot_frames,
                ),
            );
        }
        cli::CliAction::RunEmbedded {
            tail_data,
            mrb_bytes,
            title,
        } => {
            macroquad::Window::from_config(
                window_conf_with_title(&title),
                run_embedded_game_with_args(tail_data, mrb_bytes, Vec::new()),
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

    let mut current_error: Option<ScriptError> = None;
    let mut runtime_opt = match GameRuntime::new(&tail_data, &mrb_bytes, false) {
        Ok(rt) => Some(rt),
        Err(e) => {
            eprintln!("Failed to initialize WASM GameRuntime: {}", e.full_message);
            current_error = Some(e);
            None
        }
    };
    let mut cur_virt_w = runtime_opt.as_ref().map(|rt| rt.config.borrow().screen_width).unwrap_or(SCREEN_WIDTH as u32);
    let mut cur_virt_h = runtime_opt.as_ref().map(|rt| rt.config.borrow().screen_height).unwrap_or(SCREEN_HEIGHT as u32);
    let (mut render_target, mut virtual_camera) = create_virtual_screen(cur_virt_w, cur_virt_h);
    if let Some(ref mut rt) = runtime_opt {
        rt.preload_audio().await;
    }
    let mut reload_banner_frames: u32 = 0;
    let mut reload_banner_text: String = "HOT RELOADED".to_string();
    let mut error_overlay_frames: u32 = 0;

    loop {
        // リスタート要求判定（ショートカットキー F5 / Ctrl+R / Cmd+R、または Ruby スクリプトからの restart / reset 呼び出し）
        let restart_requested = is_restart_key_pressed()
            || runtime_opt.as_ref().map_or(false, |rt| rt.is_restart_requested());

        if restart_requested {
            let url = format!("__uk_bundle.bin?t={}", macroquad::time::get_time());
            let (use_tail, use_mrb) = match macroquad::file::load_file(&url).await {
                Ok(bytes) => bundle::unpack_bundle_from_bytes(&bytes).unwrap_or((tail_data.clone(), mrb_bytes.clone())),
                Err(_) => (tail_data.clone(), mrb_bytes.clone()),
            };
            match GameRuntime::new(&use_tail, &use_mrb, false) {
                Ok(mut new_rt) => {
                    new_rt.preload_audio().await;
                    current_error = None;
                    error_overlay_frames = 0;
                    reload_banner_text = "RESTARTED".to_string();
                    reload_banner_frames = 60;
                    let (new_w, new_h) = {
                        let cfg = new_rt.config.borrow();
                        (cfg.screen_width, cfg.screen_height)
                    };
                    if new_w != cur_virt_w || new_h != cur_virt_h {
                        cur_virt_w = new_w;
                        cur_virt_h = new_h;
                        let (rt_screen, cam) = create_virtual_screen(cur_virt_w, cur_virt_h);
                        render_target = rt_screen;
                        virtual_camera = cam;
                    }
                    runtime_opt = Some(new_rt);
                }
                Err(e) => {
                    eprintln!("Restart error in browser: {}", e.full_message);
                    current_error = Some(e);
                    error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
                }
            }
        } else if WASM_RELOAD_REQUESTED.swap(false, std::sync::atomic::Ordering::SeqCst) {
            let url = format!("__uk_bundle.bin?t={}", macroquad::time::get_time());
            if let Ok(bytes) = macroquad::file::load_file(&url).await
                && let Some((new_tail, new_mrb)) = bundle::unpack_bundle_from_bytes(&bytes)
            {
                if let Some(ref mut rt) = runtime_opt {
                    match rt.hot_reload(&new_tail, &new_mrb) {
                        Ok(()) => {
                            rt.preload_audio().await;
                            current_error = None;
                            error_overlay_frames = 0;
                            reload_banner_text = "HOT RELOADED".to_string();
                            reload_banner_frames = 60;
                            let (new_w, new_h) = {
                                let cfg = rt.config.borrow();
                                (cfg.screen_width, cfg.screen_height)
                            };
                            if new_w != cur_virt_w || new_h != cur_virt_h {
                                cur_virt_w = new_w;
                                cur_virt_h = new_h;
                                let (rt_screen, cam) = create_virtual_screen(cur_virt_w, cur_virt_h);
                                render_target = rt_screen;
                                virtual_camera = cam;
                            }
                        }
                        Err(_e) => {
                            match GameRuntime::new(&new_tail, &new_mrb, false) {
                                Ok(mut new_rt) => {
                                    new_rt.preload_audio().await;
                                    current_error = None;
                                    error_overlay_frames = 0;
                                    reload_banner_text = "RESTARTED".to_string();
                                    reload_banner_frames = 60;
                                    let (new_w, new_h) = {
                                        let cfg = new_rt.config.borrow();
                                        (cfg.screen_width, cfg.screen_height)
                                    };
                                    if new_w != cur_virt_w || new_h != cur_virt_h {
                                        cur_virt_w = new_w;
                                        cur_virt_h = new_h;
                                        let (rt_screen, cam) = create_virtual_screen(cur_virt_w, cur_virt_h);
                                        render_target = rt_screen;
                                        virtual_camera = cam;
                                    }
                                    runtime_opt = Some(new_rt);
                                }
                                Err(restart_err) => {
                                    eprintln!("Hot-reload and restart error in browser: {}", restart_err.full_message);
                                    current_error = Some(restart_err);
                                    error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
                                }
                            }
                        }
                    }
                } else {
                    match GameRuntime::new(&new_tail, &new_mrb, false) {
                        Ok(mut new_rt) => {
                            new_rt.preload_audio().await;
                            current_error = None;
                            error_overlay_frames = 0;
                            reload_banner_text = "RESTARTED".to_string();
                            reload_banner_frames = 60;
                            let (new_w, new_h) = {
                                let cfg = new_rt.config.borrow();
                                (cfg.screen_width, cfg.screen_height)
                            };
                            if new_w != cur_virt_w || new_h != cur_virt_h {
                                cur_virt_w = new_w;
                                cur_virt_h = new_h;
                                let (rt_screen, cam) = create_virtual_screen(cur_virt_w, cur_virt_h);
                                render_target = rt_screen;
                                virtual_camera = cam;
                            }
                            runtime_opt = Some(new_rt);
                        }
                        Err(e) => {
                            eprintln!("Restart error in browser: {}", e.full_message);
                            current_error = Some(e);
                            error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
                        }
                    }
                }
            }
        }

        if runtime_opt.is_none() {
            if let Some(ref err) = current_error {
                render_error_screen(err);
            }
        } else if let Some(ref mut rt) = runtime_opt {
            if let Err(err) = rt.call_update_result() {
                if current_error.as_ref() != Some(&err) {
                    eprintln!("{}", err.full_message);
                }
                current_error = Some(err);
                error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
            }
            rt.process_audio().await;

            set_camera(&virtual_camera);
            if let Err(err) = rt.call_draw_result() {
                if current_error.as_ref() != Some(&err) {
                    eprintln!("{}", err.full_message);
                }
                current_error = Some(err);
                error_overlay_frames = ERROR_OVERLAY_DURATION_FRAMES;
            }

            let show_fps = rt.config.borrow().show_fps;
            present_virtual_screen(
                &render_target,
                cur_virt_w,
                cur_virt_h,
                reload_banner_frames,
                &reload_banner_text,
                show_fps,
            );
            reload_banner_frames = reload_banner_frames.saturating_sub(1);

            if error_overlay_frames > 0 {
                if let Some(ref err) = current_error {
                    render_error_overlay(err);
                }
                error_overlay_frames = error_overlay_frames.saturating_sub(1);
                if error_overlay_frames == 0 {
                    current_error = None;
                }
            }
        }

        next_frame().await;
    }
}

// ==========================================
// テスト
// ==========================================
#[cfg(test)]
mod tests;

