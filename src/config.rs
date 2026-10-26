use macroquad::prelude::Color;

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

pub const PALETTE_RGBA: [[u8; 4]; 16] = [
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

pub fn palette_color(col: i32) -> Color {
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

/// 16進数カラーコード文字列（`#RRGGBB`, `#RGB`, `0xRRGGBB`, `RRGGBB`）を `[r, g, b, 255]` に変換する
pub fn parse_hex_color(s: &str) -> Option<[u8; 4]> {
    let trimmed = s.trim();
    let hex_str = if let Some(stripped) = trimmed.strip_prefix('#') {
        stripped
    } else if let Some(stripped) = trimmed.strip_prefix("0x").or_else(|| trimmed.strip_prefix("0X")) {
        stripped
    } else {
        trimmed
    };

    if hex_str.len() == 6 && hex_str.chars().all(|c| c.is_ascii_hexdigit()) {
        let r = u8::from_str_radix(&hex_str[0..2], 16).ok()?;
        let g = u8::from_str_radix(&hex_str[2..4], 16).ok()?;
        let b = u8::from_str_radix(&hex_str[4..6], 16).ok()?;
        Some([r, g, b, 255])
    } else if hex_str.len() == 3 && hex_str.chars().all(|c| c.is_ascii_hexdigit()) {
        let r_ch = hex_str.chars().nth(0)?;
        let g_ch = hex_str.chars().nth(1)?;
        let b_ch = hex_str.chars().nth(2)?;
        let r = u8::from_str_radix(&format!("{}{}", r_ch, r_ch), 16).ok()?;
        let g = u8::from_str_radix(&format!("{}{}", g_ch, g_ch), 16).ok()?;
        let b = u8::from_str_radix(&format!("{}{}", b_ch, b_ch), 16).ok()?;
        Some([r, g, b, 255])
    } else {
        None
    }
}

