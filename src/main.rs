use std::collections::HashMap;
use std::rc::Rc;

use macroquad::prelude::*;
use mrubyedge::rite;
use mrubyedge::yamrb::helpers::{mrb_define_cmethod, mrb_funcall};
use mrubyedge::yamrb::value::{RObject, RValue};
use mrubyedge::yamrb::vm::VM;

// ==========================================
// 仮想スクリーン設定 (128x128, 16色パレット)
// ==========================================
const SCREEN_WIDTH: u32 = 128;
const SCREEN_HEIGHT: u32 = 128;
const SPRITE_SIZE: usize = 8;

/// PICO-8 準拠の16色パレット
const PALETTE: [Color; 16] = [
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

fn palette_color(col: i32) -> Color {
    PALETTE[(col.rem_euclid(16)) as usize]
}

// ==========================================
// リソース管理 & 描画処理
// ==========================================
#[derive(Clone)]
struct SpriteData {
    pixels: [[Option<u8>; SPRITE_SIZE]; SPRITE_SIZE],
    texture: Option<Texture2D>,
}

impl SpriteData {
    fn from_lines(lines: &[&str]) -> Self {
        let mut pixels = [[None; SPRITE_SIZE]; SPRITE_SIZE];

        for (y, line) in lines.iter().take(SPRITE_SIZE).enumerate() {
            for (x, ch) in line.chars().take(SPRITE_SIZE).enumerate() {
                let color_idx = match ch {
                    '.' | ' ' => None,
                    c if c.is_ascii_hexdigit() => {
                        let digit = c.to_digit(16).unwrap() as u8;
                        Some(digit)
                    }
                    _ => None,
                };
                pixels[y][x] = color_idx;
            }
        }

        Self {
            pixels,
            texture: None,
        }
    }

    fn build_texture(&mut self) {
        let mut image = Image::gen_image_color(
            SPRITE_SIZE as u16,
            SPRITE_SIZE as u16,
            Color::new(0.0, 0.0, 0.0, 0.0),
        );
        for y in 0..SPRITE_SIZE {
            for x in 0..SPRITE_SIZE {
                if let Some(idx) = self.pixels[y][x] {
                    image.set_pixel(x as u32, y as u32, PALETTE[idx as usize]);
                }
            }
        }
        let texture = Texture2D::from_image(&image);
        texture.set_filter(FilterMode::Nearest);
        self.texture = Some(texture);
    }
}

/// `__END__` 以降のスプライト定義 (`@SPRITE <id>`) をパースする
fn parse_tail_resources(data_section: &str) -> HashMap<i32, SpriteData> {
    let mut sprites = HashMap::new();
    let mut current_id: Option<i32> = None;
    let mut current_lines: Vec<&str> = Vec::new();

    for raw_line in data_section.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("@SPRITE") {
            if let Some(id) = current_id.take() {
                if !current_lines.is_empty() {
                    sprites.insert(id, SpriteData::from_lines(&current_lines));
                }
                current_lines.clear();
            }
            if let Ok(id) = rest.trim().parse::<i32>() {
                current_id = Some(id);
            }
        } else if current_id.is_some() {
            current_lines.push(line);
        }
    }

    if let Some(id) = current_id {
        if !current_lines.is_empty() {
            sprites.insert(id, SpriteData::from_lines(&current_lines));
        }
    }

    sprites
}

/// Rubyオブジェクトの2次元配列または文字列配列 (`$SPRITES`) からスプライトをパースする
fn parse_ruby_sprites_global(vm: &VM, sprites: &mut HashMap<i32, SpriteData>) {
    let Some(sprites_obj) = vm.globals.get("$SPRITES") else {
        return;
    };
    let RValue::Array(ref list_cell) = sprites_obj.value else {
        return;
    };

    for (idx, item) in list_cell.borrow().iter().enumerate() {
        if let RValue::Array(ref rows_cell) = item.value {
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
    }
}

// ==========================================
// Ruby エンジン API の登録
// ==========================================
fn arg_i32(args: &[Rc<RObject>], index: usize, default: i32) -> i32 {
    args.get(index)
        .and_then(|v| i32::try_from(v.as_ref()).ok())
        .unwrap_or(default)
}

fn arg_bool(args: &[Rc<RObject>], index: usize, default: bool) -> bool {
    args.get(index)
        .and_then(|v| bool::try_from(v.as_ref()).ok())
        .unwrap_or(default)
}

fn register_engine_api(vm: &mut VM, sprites: Rc<HashMap<i32, SpriteData>>) {
    let obj_class = vm.object_class.clone();

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
            let w = arg_i32(args, 2, 8) as f32;
            let h = arg_i32(args, 3, 8) as f32;
            let col = arg_i32(args, 4, 7);
            draw_rectangle(x, y, w, h, palette_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );

    // spr(id, x, y, flip_x = false, flip_y = false): スプライト描画
    let sprites_for_spr = sprites.clone();
    mrb_define_cmethod(
        vm,
        obj_class.clone(),
        "spr",
        Box::new(move |_vm, args| {
            let id = arg_i32(args, 0, 0);
            let x = arg_i32(args, 1, 0) as f32;
            let y = arg_i32(args, 2, 0) as f32;
            let flip_x = arg_bool(args, 3, false);
            let flip_y = arg_bool(args, 4, false);

            if let Some(sprite) = sprites_for_spr.get(&id)
                && let Some(ref texture) = sprite.texture
            {
                draw_texture_ex(
                    texture,
                    x.floor(),
                    y.floor(),
                    WHITE,
                    DrawTextureParams {
                        flip_x,
                        flip_y,
                        ..Default::default()
                    },
                );
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

    // print_text(text, x = 0, y = 0, col = 7): テキスト描画
    mrb_define_cmethod(
        vm,
        obj_class,
        "print_text",
        Box::new(|_vm, args| {
            let text = args
                .first()
                .and_then(|v| String::try_from(v.as_ref()).ok())
                .unwrap_or_default();
            let x = arg_i32(args, 1, 0) as f32;
            let y = arg_i32(args, 2, 0) as f32;
            let col = arg_i32(args, 3, 7);
            // Macroquad の draw_text はベースライン基準のため y + 6.0 で左上座標に合わせる
            draw_text(&text, x.floor(), (y + 6.0).floor(), 8.0, palette_color(col));
            Ok(Rc::new(RObject::nil()))
        }),
    );
}

// ==========================================
// スクリプト読み込み (開発時 .rb / 配布・WASM時 .mrb 自動切り替え)
// ==========================================
const EMBEDDED_SOURCE: &str = include_str!("../game.rb");
const EMBEDDED_MRB: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/game.mrb"));

fn load_script_and_bytecode() -> (String, Vec<u8>) {
    #[cfg(not(target_arch = "wasm32"))]
    {
        // コマンドライン引数またはカレントディレクトリの `game.rb` があれば動的にコンパイルする
        let script_path = std::env::args()
            .nth(1)
            .unwrap_or_else(|| "game.rb".to_string());

        if let Ok(full_source) = std::fs::read_to_string(&script_path) {
            let mut parts = full_source.splitn(2, "__END__");
            let ruby_code = parts.next().unwrap_or("");
            let tail_data = parts.next().unwrap_or("").to_string();

            let mrb_bytes = unsafe {
                let mut compiler = mruby_compiler2_sys::MRubyCompiler2Context::new();
                compiler
                    .compile(ruby_code)
                    .expect("Failed to compile Ruby script")
            };
            return (tail_data, mrb_bytes);
        }
    }

    // WASM 環境、または単一バイナリ配布時（外部に .rb ファイルが無い場合）は埋め込みリソースを使用
    let tail_data = EMBEDDED_SOURCE
        .splitn(2, "__END__")
        .nth(1)
        .unwrap_or("")
        .to_string();
    (tail_data, EMBEDDED_MRB.to_vec())
}

// ==========================================
// Macroquad ウィンドウ設定 & メインループ
// ==========================================
fn window_conf() -> Conf {
    Conf {
        window_title: "Usakame Retro Engine (128x128)".to_owned(),
        window_width: (SCREEN_WIDTH * 4) as i32,
        window_height: (SCREEN_HEIGHT * 4) as i32,
        window_resizable: true,
        ..Default::default()
    }
}

#[macroquad::main(window_conf)]
async fn main() {
    // 1. スクリプトと末尾データ(__END__ 以降)のロード
    let (tail_data, mrb_bytes) = load_script_and_bytecode();
    let mut sprites_map = parse_tail_resources(&tail_data);

    // 2. mruby/edge VM の初期化とトップレベル実行
    let mut rite = rite::load(&mrb_bytes).expect("Failed to load RITE(.mrb) bytecode");
    let mut vm = VM::open(&mut rite);

    // 先にスクリプトのトップレベルを実行し、`update` / `draw` のメソッド定義や `$SPRITES` 定数などを評価する
    vm.run().expect("Failed to run Ruby top-level script");

    // もしスクリプト内で `$SPRITES` グローバル配列が定義されていれば追加で取り込む
    parse_ruby_sprites_global(&vm, &mut sprites_map);

    // GPU テクスチャを生成
    for sprite in sprites_map.values_mut() {
        sprite.build_texture();
    }

    // エンジン API (`cls`, `spr`, `btn`, `pset`, `rectfill`, `print_text`) を VM に登録
    let sprites = Rc::new(sprites_map);
    register_engine_api(&mut vm, sprites);

    // 3. 128x128 の仮想スクリーン用 RenderTarget を作成 (ドットがぼやけないよう Nearest フィルタ)
    let render_target = render_target(SCREEN_WIDTH, SCREEN_HEIGHT);
    render_target.texture.set_filter(FilterMode::Nearest);

    let mut virtual_camera =
        Camera2D::from_display_rect(Rect::new(0.0, 0.0, SCREEN_WIDTH as f32, SCREEN_HEIGHT as f32));
    virtual_camera.render_target = Some(render_target.clone());

    // 4. ゲームループ (毎フレーム update と draw を呼び出す)
    loop {
        // --- Ruby 側の update 呼び出し ---
        if let Err(e) = mrb_funcall(&mut vm, None, "update", &[]) {
            eprintln!("Ruby error in `update`: {:?}", e);
        }

        // --- 仮想スクリーン (128x128) への描画 ---
        set_camera(&virtual_camera);
        if let Err(e) = mrb_funcall(&mut vm, None, "draw", &[]) {
            eprintln!("Ruby error in `draw`: {:?}", e);
        }

        // --- 実ウィンドウへのレターボックス拡大描画 ---
        set_default_camera();
        clear_background(BLACK);

        let win_w = screen_width();
        let win_h = screen_height();
        let scale = (win_w / SCREEN_WIDTH as f32).min(win_h / SCREEN_HEIGHT as f32);
        // 整数倍スケーリングを優先したい場合は scale.floor().max(1.0) に変更可能
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

        next_frame().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_script_compile_and_sprite_parse() {
        let (tail_data, mrb_bytes) = load_script_and_bytecode();
        let sprites = parse_tail_resources(&tail_data);
        assert!(sprites.contains_key(&0), "Sprite 0 should be parsed");
        assert!(sprites.contains_key(&1), "Sprite 1 should be parsed");

        let mut rite = rite::load(&mrb_bytes).expect("Failed to load RITE(.mrb)");
        let mut vm = VM::open(&mut rite);
        // ヘッドレステスト用にダミーの btn メソッドを登録
        let obj_class = vm.object_class.clone();
        mrb_define_cmethod(
            &mut vm,
            obj_class,
            "btn",
            Box::new(|_vm, _args| Ok(Rc::new(RObject::boolean(false)))),
        );

        vm.run().expect("Failed to execute top-level Ruby script");

        // update を1フレーム呼び出して $t が 0 -> 1 に増えることを確認
        mrb_funcall(&mut vm, None, "update", &[]).expect("Failed to call update");
        let t_val: i32 = vm
            .globals
            .get("$t")
            .expect("$t should exist")
            .as_ref()
            .try_into()
            .unwrap();
        assert_eq!(t_val, 1);
    }
}

