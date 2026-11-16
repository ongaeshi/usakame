use std::collections::HashMap;
use std::path::Path;

use macroquad::prelude::*;

use crate::bundle::decode_base64;

const BG_SKY_JPG: &[u8] = include_bytes!("../assets/bg/sky.jpg");
const BG_MOUNTAIN_JPG: &[u8] = include_bytes!("../assets/bg/mountain.jpg");
const BG_FOREST_JPG: &[u8] = include_bytes!("../assets/bg/forest.jpg");
const BG_CAVE_JPG: &[u8] = include_bytes!("../assets/bg/cave.jpg");
const BG_CITY_JPG: &[u8] = include_bytes!("../assets/bg/city.jpg");

#[derive(Clone)]
pub struct BgImage {
    pub width: u16,
    pub height: u16,
    pub rgba: Vec<u8>,
    pub texture: Option<Texture2D>,
}

impl BgImage {
    pub fn from_rgba(width: u16, height: u16, rgba: Vec<u8>) -> Self {
        Self {
            width,
            height,
            rgba,
            texture: None,
        }
    }

    pub fn from_encoded_bytes(bytes: &[u8], fmt: Option<ImageFormat>) -> Result<Self, String> {
        let img = Image::from_file_with_format(bytes, fmt)
            .map_err(|e| format!("Failed to decode BG image: {:?}", e))?;
        Ok(Self::from_rgba(img.width, img.height, img.bytes))
    }

    pub fn build_texture(&mut self) {
        if self.texture.is_none() && self.width > 0 && self.height > 0 && !self.rgba.is_empty() {
            let tex = Texture2D::from_rgba8(self.width, self.height, &self.rgba);
            tex.set_filter(FilterMode::Linear);
            self.texture = Some(tex);
        }
    }
}

pub fn detect_image_format_from_path(path: &str) -> Option<ImageFormat> {
    let lower = path.trim().to_ascii_lowercase();
    if lower.ends_with(".png") {
        Some(ImageFormat::Png)
    } else if lower.ends_with(".jpg") || lower.ends_with(".jpeg") {
        Some(ImageFormat::Jpeg)
    } else if lower.ends_with(".bmp") {
        Some(ImageFormat::Bmp)
    } else if lower.ends_with(".tga") {
        Some(ImageFormat::Tga)
    } else if lower.ends_with(".gif") {
        Some(ImageFormat::Gif)
    } else {
        None
    }
}

/// `@BG <name_or_id> <path_or_base64>` ブロックをパースして `HashMap<String, BgImage>` を返す。
/// キーは先頭の `:` を除いた正規化文字列（例: `"sky"`, `"300"`）。
pub fn parse_tail_bgs(tail_data: &str, base_dir: Option<&Path>) -> HashMap<String, BgImage> {
    let mut bgs = HashMap::new();
    let mut current_key: Option<String> = None;
    let mut current_lines: Vec<String> = Vec::new();

    let flush = |key_opt: &mut Option<String>,
                 lines: &mut Vec<String>,
                 out: &mut HashMap<String, BgImage>| {
        let Some(key) = key_opt.take() else {
            lines.clear();
            return;
        };
        let joined = lines.join("");
        lines.clear();
        let trimmed = joined.trim();
        if trimmed.is_empty() {
            return;
        }

        let path_candidate = if let Some(dir) = base_dir {
            dir.join(trimmed)
        } else {
            std::path::PathBuf::from(trimmed)
        };

        if path_candidate.is_file() {
            let fmt = detect_image_format_from_path(trimmed);
            match std::fs::read(&path_candidate) {
                Ok(bytes) => match BgImage::from_encoded_bytes(&bytes, fmt) {
                    Ok(bg) => {
                        out.insert(key, bg);
                    }
                    Err(e) => {
                        eprintln!(
                            "Warning: Failed to decode @BG {} ({}): {}",
                            key,
                            path_candidate.display(),
                            e
                        );
                    }
                },
                Err(e) => {
                    eprintln!(
                        "Warning: Failed to read @BG {} ({}): {}",
                        key,
                        path_candidate.display(),
                        e
                    );
                }
            }
        } else if let Ok(bytes) = decode_base64(trimmed) {
            match BgImage::from_encoded_bytes(&bytes, None) {
                Ok(bg) => {
                    out.insert(key, bg);
                }
                Err(e) => {
                    eprintln!("Warning: Failed to decode Base64 @BG {}: {}", key, e);
                }
            }
        }
    };

    for raw_line in tail_data.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("@BG") {
            flush(&mut current_key, &mut current_lines, &mut bgs);
            let mut parts = rest.split_whitespace();
            if let Some(raw_name) = parts.next() {
                let norm = raw_name.trim_start_matches(':').to_string();
                if !norm.is_empty() {
                    current_key = Some(norm);
                    let rest_joined: String = parts.collect::<Vec<_>>().join(" ");
                    if !rest_joined.is_empty() {
                        current_lines.push(rest_joined);
                    }
                }
            }
        } else if line.starts_with('@') {
            flush(&mut current_key, &mut current_lines, &mut bgs);
        } else if current_key.is_some() {
            current_lines.push(line.to_string());
        }
    }
    flush(&mut current_key, &mut current_lines, &mut bgs);
    bgs
}

pub fn is_preset_bg_name(name: &str) -> bool {
    matches!(
        name,
        "training"
            | "checker"
            | "space"
            | "cyber"
            | "sky"
            | "mountain"
            | "forest"
            | "cave"
            | "city"
    )
}

pub fn generate_preset_bg(name: &str) -> Option<BgImage> {
    match name {
        "training" | "checker" => Some(gen_preset_training()),
        "space" => Some(gen_preset_space()),
        "cyber" => Some(gen_preset_cyber()),
        "sky" => BgImage::from_encoded_bytes(BG_SKY_JPG, Some(ImageFormat::Jpeg)).ok(),
        "mountain" => BgImage::from_encoded_bytes(BG_MOUNTAIN_JPG, Some(ImageFormat::Jpeg)).ok(),
        "forest" => BgImage::from_encoded_bytes(BG_FOREST_JPG, Some(ImageFormat::Jpeg)).ok(),
        "cave" => BgImage::from_encoded_bytes(BG_CAVE_JPG, Some(ImageFormat::Jpeg)).ok(),
        "city" => BgImage::from_encoded_bytes(BG_CITY_JPG, Some(ImageFormat::Jpeg)).ok(),
        _ => None,
    }
}

#[inline]
fn hash2_u32(ix: i32, iy: i32, seed: i32) -> f32 {
    let mut n = (ix.wrapping_mul(374761393))
        .wrapping_add(iy.wrapping_mul(668265263))
        .wrapping_add(seed.wrapping_mul(1442695041)) as u32;
    n = (n ^ (n >> 13)).wrapping_mul(1274126177);
    n ^= n >> 16;
    (n as f32) / (u32::MAX as f32)
}

#[inline]
fn smooth(t: f32) -> f32 {
    t * t * (3.0 - 2.0 * t)
}

#[inline]
fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

fn periodic_noise2_xy(u: f32, v: f32, px: i32, py: i32, seed: i32) -> f32 {
    let x = u * px as f32;
    let y = v * py as f32;
    let ix0 = x.floor() as i32;
    let iy0 = y.floor() as i32;
    let fx = smooth(x - ix0 as f32);
    let fy = smooth(y - iy0 as f32);
    let ix0_m = ix0.rem_euclid(px);
    let ix1_m = (ix0 + 1).rem_euclid(px);
    let iy0_m = iy0.rem_euclid(py);
    let iy1_m = (iy0 + 1).rem_euclid(py);
    let v00 = hash2_u32(ix0_m, iy0_m, seed);
    let v10 = hash2_u32(ix1_m, iy0_m, seed);
    let v01 = hash2_u32(ix0_m, iy1_m, seed);
    let v11 = hash2_u32(ix1_m, iy1_m, seed);
    lerp(lerp(v00, v10, fx), lerp(v01, v11, fx), fy)
}

fn periodic_fbm2_xy(u: f32, v: f32, base_p: i32, octaves: i32, seed: i32) -> f32 {
    let mut val = 0.0f32;
    let mut amp = 0.5f32;
    let mut freq = 1i32;
    let mut norm = 0.0f32;
    for i in 0..octaves {
        let p = base_p * freq;
        val += amp * periodic_noise2_xy(u, v, p, p, seed + i * 31);
        norm += amp;
        amp *= 0.5;
        freq *= 2;
    }
    val / norm
}

#[inline]
fn bayer4(x: u32, y: u32) -> f32 {
    const M: [f32; 16] = [
        0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0,
    ];
    (M[((y & 3) * 4 + (x & 3)) as usize] / 16.0 - 0.5) * 2.0
}

/// トレモ用グリッド市松模様（256x256・上下左右完全シームレス）
fn gen_preset_training() -> BgImage {
    const W: usize = 256;
    const H: usize = 256;
    let mut rgba = vec![0u8; W * H * 4];
    for y in 0..H {
        for x in 0..W {
            let cell_x = x / 32;
            let cell_y = y / 32;
            let is_light = (cell_x + cell_y) % 2 == 0;
            let is_major = (x % 64 == 0) || (y % 64 == 0);
            let is_minor = (x % 16 == 0) || (y % 16 == 0);

            let (mut r, mut g, mut b) = if is_light {
                (52u8, 58u8, 70u8)
            } else {
                (40u8, 45u8, 56u8)
            };

            if is_major {
                r = r.saturating_add(24);
                g = g.saturating_add(26);
                b = b.saturating_add(32);
            } else if is_minor {
                r = r.saturating_add(8);
                g = g.saturating_add(9);
                b = b.saturating_add(12);
            }

            let idx = (y * W + x) * 4;
            rgba[idx] = r;
            rgba[idx + 1] = g;
            rgba[idx + 2] = b;
            rgba[idx + 3] = 255;
        }
    }
    BgImage::from_rgba(W as u16, H as u16, rgba)
}

/// 深宇宙・星雲・星団（256x256・上下左右完全シームレス、縦/横STG両対応）
fn gen_preset_space() -> BgImage {
    const W: usize = 256;
    const H: usize = 256;
    let mut rgba = vec![0u8; W * H * 4];

    for y in 0..H {
        let v = y as f32 / H as f32;
        for x in 0..W {
            let u = x as f32 / W as f32;
            // 周期星雲ノイズ（上下左右シームレス）
            let neb1 = periodic_fbm2_xy(u, v, 3, 4, 701);
            let neb2 = periodic_fbm2_xy(u + 0.31, v + 0.17, 4, 4, 733);
            let cloud1 = ((neb1 - 0.48) * 3.2).clamp(0.0, 1.0);
            let cloud2 = ((neb2 - 0.52) * 3.5).clamp(0.0, 1.0);

            let mut r = 6.0 + cloud1 * 28.0 + cloud2 * 48.0;
            let mut g = 8.0 + cloud1 * 22.0 + cloud2 * 18.0;
            let mut b = 22.0 + cloud1 * 68.0 + cloud2 * 56.0;

            // 星の生成（256x256 シームレスハッシュ）
            let h = hash2_u32(x as i32, y as i32, 907);
            if h > 0.9965 {
                let bright = ((h - 0.9965) / 0.0035).clamp(0.0, 1.0);
                let tint = hash2_u32(x as i32, y as i32, 911);
                let (sr, sg, sb) = if tint < 0.3 {
                    (180.0, 210.0, 255.0)
                } else if tint < 0.7 {
                    (255.0, 252.0, 245.0)
                } else {
                    (255.0, 220.0, 175.0)
                };
                let k = 0.45 + 0.55 * bright;
                r = lerp(r, sr, k);
                g = lerp(g, sg, k);
                b = lerp(b, sb, k);
            } else if h > 0.990 {
                r += 42.0;
                g += 46.0;
                b += 65.0;
            }

            let d = bayer4(x as u32, y as u32);
            let idx = (y * W + x) * 4;
            rgba[idx] = (r + d).clamp(0.0, 255.0) as u8;
            rgba[idx + 1] = (g + d).clamp(0.0, 255.0) as u8;
            rgba[idx + 2] = (b + d).clamp(0.0, 255.0) as u8;
            rgba[idx + 3] = 255;
        }
    }
    BgImage::from_rgba(W as u16, H as u16, rgba)
}

/// 遠近ネオングリッド＋地平線グロー（256x256・横シームレス）
fn gen_preset_cyber() -> BgImage {
    const W: usize = 256;
    const H: usize = 256;
    let mut rgba = vec![0u8; W * H * 4];
    let horizon = 0.54f32;

    for y in 0..H {
        let v = y as f32 / (H - 1) as f32;
        for x in 0..W {
            let u = x as f32 / W as f32;

            let (mut r, mut g, mut b) = if v < horizon {
                // 上半分：夜空＋地平線ネオングロー＋微細星
                let t = (v / horizon).clamp(0.0, 1.0);
                let glow = (t * t * t).clamp(0.0, 1.0);
                let mut sr = lerp(10.0, 74.0, glow);
                let mut sg = lerp(8.0, 20.0, glow);
                let mut sb = lerp(34.0, 118.0, glow);

                let h = hash2_u32(x as i32, y as i32, 503);
                if h > 0.994 && t < 0.75 {
                    let k = 1.0 - t / 0.75;
                    sr += 150.0 * k;
                    sg += 170.0 * k;
                    sb += 220.0 * k;
                }
                (sr, sg, sb)
            } else {
                // 下半分：パース付きネオングリッド（X=256周期でシームレス）
                let dy = (v - horizon).max(0.004);
                let depth = 0.14 / dy;
                // X 方向は画面幅 256 に対して 8 分割の格子がパースで広がる
                let world_x = (u - 0.5) * depth * 8.0;
                let gx = (world_x - world_x.floor()).min(1.0 - (world_x - world_x.floor()));
                let gz = (depth - depth.floor()).min(1.0 - (depth - depth.floor()));

                let line_w_x = (0.045 * (0.5 + depth * 0.25)).clamp(0.02, 0.14);
                let line_w_z = 0.06;
                let lx = (1.0 - (gx / line_w_x)).clamp(0.0, 1.0);
                let lz = (1.0 - (gz / line_w_z)).clamp(0.0, 1.0);
                let grid = lx.max(lz);
                let fog = ((v - horizon) / (1.0 - horizon)).clamp(0.0, 1.0);
                let grid_strength = grid * (0.25 + 0.75 * fog);

                let base_r = lerp(42.0, 12.0, fog);
                let base_g = lerp(14.0, 10.0, fog);
                let base_b = lerp(78.0, 36.0, fog);

                (
                    lerp(base_r, 40.0, grid_strength),
                    lerp(base_g, 235.0, grid_strength),
                    lerp(base_b, 255.0, grid_strength),
                )
            };

            // 地平線ライン
            let h_dist = (v - horizon).abs();
            if h_dist < 0.02 {
                let k = 1.0 - h_dist / 0.02;
                r = lerp(r, 255.0, k * 0.85);
                g = lerp(g, 90.0, k * 0.85);
                b = lerp(b, 220.0, k * 0.85);
            }

            let d = bayer4(x as u32, y as u32);
            let idx = (y * W + x) * 4;
            rgba[idx] = (r + d).clamp(0.0, 255.0) as u8;
            rgba[idx + 1] = (g + d).clamp(0.0, 255.0) as u8;
            rgba[idx + 2] = (b + d).clamp(0.0, 255.0) as u8;
            rgba[idx + 3] = 255;
        }
    }
    BgImage::from_rgba(W as u16, H as u16, rgba)
}
