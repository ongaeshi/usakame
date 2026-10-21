use std::cell::RefCell;
use std::collections::HashMap;
use macroquad::prelude::*;
use crate::emoji;

pub const FONT_CHAR_W: usize = 6;
pub const FONT_CHAR_H: usize = 8;
pub const FONT_ATLAS_COLS: usize = 16;

/// ASCII 0x20 (' ') ..= 0x7E ('~') の 95 文字分の 5x7 ビットマップデータ (各文字 7 行、上位5ビット使用)
pub const FONT_5X7: [[u8; 7]; 95] = [
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
