pub mod bundle;
#[cfg(not(target_arch = "wasm32"))]
pub mod cli;

use std::cell::RefCell;
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
pub struct SpriteData {
    pub pixels: [[Option<u8>; SPRITE_SIZE]; SPRITE_SIZE],
    pub texture: Option<Texture2D>,
}

impl SpriteData {
    pub fn from_lines(lines: &[&str]) -> Self {
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

    pub fn build_texture(&mut self) {
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
pub fn parse_tail_resources(data_section: &str) -> HashMap<i32, SpriteData> {
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

    if let Some(id) = current_id
        && !current_lines.is_empty()
    {
        sprites.insert(id, SpriteData::from_lines(&current_lines));
    }

    sprites
}

/// Rubyオブジェクトの2次元配列または文字列配列 (`$SPRITES`) からスプライトをパースする
pub fn parse_ruby_sprites_global(vm: &VM, sprites: &mut HashMap<i32, SpriteData>) {
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

fn register_engine_api(
    vm: &mut VM,
    sprites: Rc<RefCell<HashMap<i32, SpriteData>>>,
    headless: bool,
) {
    let obj_class = vm.object_class.clone();

    if headless {
        // ヘッドレステスト用スタブ登録
        for name in ["cls", "pset", "rectfill", "spr", "print_text"] {
            mrb_define_cmethod(
                vm,
                obj_class.clone(),
                name,
                Box::new(|_vm, _args| Ok(Rc::new(RObject::nil()))),
            );
        }
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

            let sprites_ref = sprites_for_spr.borrow();
            if let Some(sprite) = sprites_ref.get(&id)
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
        register_engine_api(&mut vm, sprites.clone(), headless);

        vm.run()
            .map_err(|e| format!("Failed to run top-level Ruby script: {:?}", e))?;

        parse_ruby_sprites_global(&vm, &mut sprites_map);
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

        register_engine_api(&mut new_vm, self.sprites.clone(), self.headless);

        new_vm
            .run()
            .map_err(|e| format!("Ruby top-level error on reload: {:?}", e))?;

        parse_ruby_sprites_global(&new_vm, &mut new_sprites_map);
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
        window_width: (SCREEN_WIDTH * 4) as i32,
        window_height: (SCREEN_HEIGHT * 4) as i32,
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
    window_conf_with_title("Usakame Retro Engine (128x128)")
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
11111111
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
22222222

@SPRITE 2
33333333
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
    }
}
