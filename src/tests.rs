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
fn test_shinonome_japanese_font_lookup() {
    for ch in ['あ', 'い', 'ウ', 'サ', 'ギ', '兎', '亀', '漢', '字', '！'] {
        let glyph = lookup_shinonome_glyph(ch as u16)
            .unwrap_or_else(|| panic!("Shinonome glyph should exist for '{}'", ch));
        assert_eq!(glyph.width, 16, "Glyph '{}' should be width 16", ch);
        assert!(
            glyph.bitmap.iter().any(|&b| b != 0),
            "Glyph '{}' should have non-zero pixel bytes",
            ch
        );
    }
    for ch in ['A', 'Z', '0', '9', '?'] {
        let glyph = lookup_shinonome_glyph(ch as u16)
            .unwrap_or_else(|| panic!("Shinonome glyph should exist for '{}'", ch));
        assert_eq!(glyph.width, 8, "Glyph '{}' should be width 8", ch);
        assert!(
            glyph.bitmap.iter().any(|&b| b != 0),
            "Glyph '{}' should have non-zero pixel bytes",
            ch
        );
    }
}

#[test]
fn test_parse_config_from_source() {
    let code = r#"
config(
  width: 640,
  height: 480,
  scale: 1.5,
  sprite_scale: 2.0,
  text_size: 16,
  title: "MY RETRO RPG",
  show_fps: true
)
x = 10
"#;
    let cfg = parse_config_from_source(code);
    assert_eq!(cfg.screen_width, 640);
    assert_eq!(cfg.screen_height, 480);
    assert_eq!(cfg.window_scale, 1.5);
    assert_eq!(cfg.sprite_scale, 2.0);
    assert_eq!(cfg.text_size, 16);
    assert_eq!(cfg.title, "MY RETRO RPG");
    assert!(cfg.show_fps);
    assert_eq!(cfg.resolved_text_size(), 16);
    assert_eq!(cfg.window_width(), 960);
    assert_eq!(cfg.window_height(), 720);

    // デフォルト判定
    let default_cfg = AppConfig::default();
    assert_eq!(default_cfg.resolved_text_size(), 8); // 256x256 -> 8
    let vga_cfg = AppConfig {
        screen_width: 640,
        screen_height: 480,
        ..Default::default()
    };
    assert_eq!(vga_cfg.resolved_text_size(), 16); // 640x480 -> 16
}

#[test]
fn test_config_api_and_text_size_in_ruby_script() {
    let script = r#"
config(
  width: 640,
  height: 480,
  scale: 2,
  sprite_scale: 2,
  text_size: 16,
  title: "Test RPG"
)

def update
end

def draw
  cls(1)
  spr(1, 10, 20)
  spr(1, 50, 50, false, false, 0, 1.0)
  map(0, 0, 0, 0, 10, 10)
  print_text("こんにちは！🐰", 10, 10, 7)
  print_text("STATUS", 10, 30, 7, size: 8)
  print_text("VGA", 10, 50, 7, 16)
end
"#;
    let (tail, mrb) = cli::compile_ruby_script_str_with_filename(script, Some("test.rb")).expect("Compile should succeed");
    let mut runtime = GameRuntime::new(&tail, &mrb, true).expect("Runtime init should succeed");
    assert_eq!(runtime.config.borrow().screen_width, 640);
    assert_eq!(runtime.config.borrow().screen_height, 480);
    assert_eq!(runtime.config.borrow().sprite_scale, 2.0);
    assert_eq!(runtime.config.borrow().text_size, 16);
    assert_eq!(runtime.config.borrow().resolved_text_size(), 16);
    assert_eq!(runtime.config.borrow().title, "Test RPG");

    runtime.call_update();
    runtime.call_draw();
}

#[test]
fn test_direct_sprite_data_in_ruby_script() {
    let script = r#"
        pixels = Array.new(256, 7)
        pixels[0] = nil
        spr(pixels, 10, 20)
        draw_sprite_data(pixels, 30, 40, 2.0)
        spr_data(pixels, 50, 60)
        $ok = true
    "#;
    let (tail, mrb) = cli::compile_ruby_script_str_with_filename(script, Some("test.rb")).unwrap();
    let runtime = GameRuntime::new(&tail, &mrb, true).unwrap();
    assert_eq!(
        runtime.vm.globals.get("$ok").map(|v| v.as_ref().clone()),
        Some(RObject::boolean(true))
    );
}

#[test]
fn bench_slot_rendering() {
    let old_script = r#"
        $slots = Array.new(16) { Array.new(256, 8) }
        def draw
          16.times do |sid|
            sgrid = $slots[sid]
            16.times do |py|
              16.times do |px|
                c = sgrid[py * 16 + px]
                pset(px, py, c) if c
              end
            end
          end
        end
    "#;
    let new_script = r#"
        $slots = Array.new(16) { Array.new(256, 8) }
        def draw
          16.times do |sid|
            spr($slots[sid], 0, 0)
          end
        end
    "#;
    let (_, old_mrb) = cli::compile_ruby_script_str(old_script).unwrap();
    let mut old_rt = GameRuntime::new("", &old_mrb, true).unwrap();

    let (_, new_mrb) = cli::compile_ruby_script_str(new_script).unwrap();
    let mut new_rt = GameRuntime::new("", &new_mrb, true).unwrap();

    for _ in 0..10 {
        old_rt.call_draw();
        new_rt.call_draw();
    }

    let iters = 20;
    let t0 = std::time::Instant::now();
    for _ in 0..iters {
        old_rt.call_draw();
    }
    let old_dur = t0.elapsed();

    let t1 = std::time::Instant::now();
    for _ in 0..iters {
        new_rt.call_draw();
    }
    let new_dur = t1.elapsed();

    let old_frame_ms = old_dur.as_secs_f64() * 1000.0 / iters as f64;
    let new_frame_ms = new_dur.as_secs_f64() * 1000.0 / iters as f64;

    assert!(old_frame_ms > new_frame_ms, "spr direct drawing should be significantly faster than pset loops");
}

#[test]
fn test_screen_to_virtual_coordinates() {
    // 等倍 512x512 ウィンドウ -> 256x256 仮想画面（スケール 2.0, オフセット 0）
    assert_eq!(screen_to_virtual(0.0, 0.0, 512.0, 512.0, 256.0, 256.0), (0, 0));
    assert_eq!(screen_to_virtual(100.0, 200.0, 512.0, 512.0, 256.0, 256.0), (50, 100));
    assert_eq!(screen_to_virtual(511.0, 511.0, 512.0, 512.0, 256.0, 256.0), (255, 255));

    // 横長 640x480 ウィンドウ -> 256x256 仮想画面（スケール 1.875, 480x480 表示, 左右オフセット 80.0）
    assert_eq!(screen_to_virtual(80.0, 0.0, 640.0, 480.0, 256.0, 256.0), (0, 0));
    assert_eq!(screen_to_virtual(560.0, 480.0, 640.0, 480.0, 256.0, 256.0), (256, 256));
    // 黒帯内（左側）
    assert!(screen_to_virtual(0.0, 240.0, 640.0, 480.0, 256.0, 256.0).0 < 0);
}

#[test]
fn test_button_parsing_symbols_and_numbers() {
    assert_eq!(parse_button_name("left"), Some(ButtonId::Left));
    assert_eq!(parse_button_name("l"), Some(ButtonId::Left));
    assert_eq!(parse_button_name("right"), Some(ButtonId::Right));
    assert_eq!(parse_button_name("r"), Some(ButtonId::Right));
    assert_eq!(parse_button_name("up"), Some(ButtonId::Up));
    assert_eq!(parse_button_name("u"), Some(ButtonId::Up));
    assert_eq!(parse_button_name("down"), Some(ButtonId::Down));
    assert_eq!(parse_button_name("d"), Some(ButtonId::Down));
    assert_eq!(parse_button_name("z"), Some(ButtonId::A));
    assert_eq!(parse_button_name("space"), Some(ButtonId::A));
    assert_eq!(parse_button_name("btn_a"), Some(ButtonId::A));
    assert_eq!(parse_button_name("x"), Some(ButtonId::B));
    assert_eq!(parse_button_name("enter"), Some(ButtonId::B));
    assert_eq!(parse_button_name("btn_b"), Some(ButtonId::B));
    assert_eq!(parse_button_name("mouse_l"), Some(ButtonId::MouseLeft));
    assert_eq!(parse_button_name("click"), Some(ButtonId::MouseLeft));
    assert_eq!(parse_button_name("mouse_r"), Some(ButtonId::MouseRight));
    assert_eq!(parse_button_name("mouse_m"), Some(ButtonId::MouseMiddle));
    assert_eq!(parse_button_name("invalid"), None);
}

#[test]
fn test_split_ruby_source_and_tail() {
    // コメント内に __END__ が含まれていても誤検知せず、独立した行の __END__ を正しく認識する
    let source_with_comment = r#"# サウンドはすべてこのスクリプト内（__END__ 以降の @SFX / @MUSIC）で定義されています。
def update; end
def draw; end
__END__
@SFX 0 c2 e2 g2
"#;
    let (code, tail) = bundle::split_ruby_source_and_tail(source_with_comment);
    assert!(code.contains("def update; end"));
    assert!(code.contains("def draw; end"));
    assert!(!code.contains("c2 e2 g2"));
    assert!(tail.contains("@SFX 0 c2 e2 g2"));

    // __END__ が存在しない場合
    let source_no_end = "def update; end\ndef draw; end\n";
    let (code, tail) = bundle::split_ruby_source_and_tail(source_no_end);
    assert_eq!(code, source_no_end);
    assert_eq!(tail, "");
}

#[test]
fn test_mouse_and_btn_api_in_ruby_script() {
    let script = r#"
        $bx = btn(:left)
        $bm = btn(:mouse_l)
        $bpm = btnp(:mouse_l)
        $mx = mouse_x
        $my = mouse_y
        $mw = mouse_wheel
        show_mouse(false)
        show_mouse(true)
        show_mouse
        $cur_fps = fps
        $ok = true
    "#;
    let (tail, mrb_bytes) = cli::compile_ruby_script_str_with_filename(script, Some("test.rb")).unwrap();
    let runtime = GameRuntime::new(&tail, &mrb_bytes, true).unwrap();
    assert_eq!(
        runtime.vm.globals.get("$ok").map(|v| v.as_ref().clone()),
        Some(RObject::boolean(true))
    );
    assert_eq!(
        runtime.vm.globals.get("$cur_fps").map(|v| v.as_ref().clone()),
        Some(RObject::integer(60))
    );
    assert_eq!(
        runtime.vm.globals.get("$bx").map(|v| v.as_ref().clone()),
        Some(RObject::boolean(false))
    );
    assert_eq!(
        runtime.vm.globals.get("$bm").map(|v| v.as_ref().clone()),
        Some(RObject::boolean(false))
    );
    assert_eq!(
        runtime.vm.globals.get("$bpm").map(|v| v.as_ref().clone()),
        Some(RObject::boolean(false))
    );
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
            script_path: std::path::PathBuf::from("game.rb"),
            script_args: Vec::new(),
        }
    );

    let run_with_args = cli::parse_cli_args(["uk", "run", "editor.rb", "--", "target.spr"].map(String::from)).unwrap();
    assert_eq!(
        run_with_args,
        cli::CliAction::Run {
            script_path: std::path::PathBuf::from("editor.rb"),
            script_args: vec!["target.spr".to_string()],
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

    let pack_act = cli::parse_cli_args(
        ["uk", "pack", "my_game.rb", "-o", "packed.rb"].map(String::from),
    )
    .unwrap();
    assert_eq!(
        pack_act,
        cli::CliAction::Pack {
            script_path: std::path::PathBuf::from("my_game.rb"),
            output_path: Some(std::path::PathBuf::from("packed.rb")),
        }
    );

    let unpack_act = cli::parse_cli_args(
        ["uk", "unpack", "my_game.rb"].map(String::from),
    )
    .unwrap();
    assert_eq!(
        unpack_act,
        cli::CliAction::Unpack {
            script_path: std::path::PathBuf::from("my_game.rb"),
        }
    );
}

#[test]
fn test_external_resource_overlay_and_pack_unpack() {
    let temp_dir = std::env::temp_dir().join("uk_test_overlay");
    let _ = std::fs::remove_dir_all(&temp_dir);
    std::fs::create_dir_all(&temp_dir).unwrap();

    let rb_path = temp_dir.join("game.rb");
    let spr_path = temp_dir.join("game.spr");
    let packed_path = temp_dir.join("game_packed.rb");

    // 1. game.rb には初期スプライト @SPRITE 0 (色 0) を定義
    let rb_src = "def update; end\ndef draw; end\n__END__\n@SPRITE 0\n0000\n0000\n";
    std::fs::write(&rb_path, rb_src).unwrap();

    // 2. 外部 game.spr にオーバーレイスプライト @SPRITE 0 (色 7) を定義
    let spr_src = "@SPRITE 0\n7777\n7777\n";
    std::fs::write(&spr_path, spr_src).unwrap();

    // 3. compile_ruby_script_file で読み込み、外部スプライトで上書きされているか検証
    let (_, merged_tail, _mrb) = cli::compile_ruby_script_file(&rb_path).unwrap();
    let sprites = parse_tail_resources(&merged_tail);
    let sp0 = sprites.get(&0).expect("Sprite 0 should exist");
    // 外部リソース @SPRITE 0 (色 7) の内容が適用されている
    assert_eq!(&sp0.rgba[0..4], &PALETTE_RGBA[7]);

    // 4. pack コマンドで単一ファイルに統合
    let packed_out = cli::cmd_pack(&rb_path, Some(&packed_path)).unwrap();
    assert_eq!(packed_out, packed_path);
    let packed_content = std::fs::read_to_string(&packed_path).unwrap();
    assert!(packed_content.contains("__END__"));
    assert!(packed_content.contains("Loaded external resource: game.spr"));

    // 5. unpack コマンドで外部ファイルに再展開
    let unpacked_dir = temp_dir.join("unpacked_dest");
    std::fs::create_dir_all(&unpacked_dir).unwrap();
    let copy_packed = unpacked_dir.join("stage.rb");
    std::fs::write(&copy_packed, &packed_content).unwrap();
    let gen_files = cli::cmd_unpack(&copy_packed).unwrap();
    assert_eq!(gen_files.len(), 1);
    assert_eq!(gen_files[0], unpacked_dir.join("stage.spr"));

    let _ = std::fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_argv_and_file_io_in_ruby() {
    let temp_dir = std::env::temp_dir().join("uk_test_file_io");
    let _ = std::fs::remove_dir_all(&temp_dir);
    std::fs::create_dir_all(&temp_dir).unwrap();

    let test_file = temp_dir.join("hello.txt");
    let test_file_str = test_file.to_str().unwrap().replace('\\', "/");

    let script = format!(r#"
$arg0 = ARGV[0]
$arg1 = $ARGV[1]
$write_ok = save_file("{}", "Hello Usakame!")
$read_back = read_file("{}")
"#, test_file_str, test_file_str);

    let (_, mrb) = cli::compile_ruby_script_str(&script).unwrap();
    let args = vec!["arg_one".to_string(), "arg_two".to_string()];
    let runtime = GameRuntime::new_with_args("", &mrb, true, &args).unwrap();

    let arg0: String = runtime.vm.globals.get("$arg0").unwrap().as_ref().try_into().unwrap();
    let arg1: String = runtime.vm.globals.get("$arg1").unwrap().as_ref().try_into().unwrap();
    assert_eq!(arg0, "arg_one");
    assert_eq!(arg1, "arg_two");

    let write_ok: bool = runtime.vm.globals.get("$write_ok").unwrap().as_ref().try_into().unwrap();
    assert!(write_ok);

    let read_back: String = runtime.vm.globals.get("$read_back").unwrap().as_ref().try_into().unwrap();
    assert_eq!(read_back, "Hello Usakame!");

    // file_mtime と load_resource_map のテスト
    let map_file = temp_dir.join("test.map");
    let map_file_str = map_file.to_str().unwrap().replace('\\', "/");
    let map_content = "@MAP 0 0\n12\n34\n";
    std::fs::write(&map_file, map_content).unwrap();

    let map_script = format!(r#"
$mtime = file_mtime("{}")
$map_tiles = load_resource_map("{}", 2, 2)
"#, map_file_str, map_file_str);
    let (_, mrb_map) = cli::compile_ruby_script_str(&map_script).unwrap();
    let runtime_map = GameRuntime::new("", &mrb_map, true).unwrap();

    let mtime: i64 = runtime_map.vm.globals.get("$mtime").unwrap().as_ref().try_into().unwrap();
    assert!(mtime > 0);

    let map_tiles_obj = runtime_map.vm.globals.get("$map_tiles").unwrap();
    if let RValue::Array(arr) = &map_tiles_obj.value {
        let borrowed = arr.borrow();
        assert_eq!(borrowed.len(), 4);
        let t0: i64 = borrowed[0].as_ref().try_into().unwrap();
        let t1: i64 = borrowed[1].as_ref().try_into().unwrap();
        let t2: i64 = borrowed[2].as_ref().try_into().unwrap();
        let t3: i64 = borrowed[3].as_ref().try_into().unwrap();
        assert_eq!(t0, 1);
        assert_eq!(t1, 2);
        assert_eq!(t2, 3);
        assert_eq!(t3, 4);
    } else {
        panic!("$map_tiles should be an Array");
    }

    let _ = std::fs::remove_dir_all(&temp_dir);
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
fn test_audio_wav_encode_and_parse() {
    let pcm = sound::synthesize_preset_pcm("coin", 1.0, 1.0, 1.0).unwrap();
    let wav_bytes = sound::pcm_to_wav_bytes(&pcm, sound::SAMPLE_RATE);
    let block = cli::encode_audio_bytes_to_script_block(&wav_bytes, "coin.wav", 42, false)
        .expect("Should encode WAV bytes into @WAV block");
    assert!(block.contains("@WAV 42"));

    let (sfx_map, _) = sound::parse_tail_sounds(&block);
    assert!(sfx_map.contains_key(&42));
    assert!(!sfx_map[&42].pcm.is_empty());
    assert_eq!(sfx_map[&42].wav_bytes, wav_bytes);
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
    let (tail, mrb) = cli::compile_ruby_script_str_with_filename(script, Some("test.rb")).unwrap();
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
    let (tail, mrb) = cli::compile_ruby_script_str_with_filename(script, Some("test.rb")).unwrap();
    let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();
    runtime.call_draw();
}

#[test]
fn test_basic_shape_rasterization() {
    // 1. line: 水平・垂直・斜め・単一点
    assert_eq!(rasterize_line(10, 20, 10, 20), vec![PixelSpan::new(10, 20, 1, 1)]);
    assert_eq!(rasterize_line(15, 20, 10, 20), vec![PixelSpan::new(10, 20, 6, 1)]);
    assert_eq!(rasterize_line(10, 25, 10, 20), vec![PixelSpan::new(10, 20, 1, 6)]);

    let diag = rasterize_line(0, 0, 3, 3);
    assert_eq!(diag.len(), 4);
    for i in 0..=3 {
        assert!(diag.iter().any(|s| s.contains(i, i)));
    }

    // 2. rect / rectfill: 枠線と塗りつぶし
    assert!(rasterize_rect(0, 0, 0, 5).is_empty());
    assert!(rasterize_rectfill(0, 0, -2, 5).is_empty());
    assert_eq!(rasterize_rect(5, 6, 1, 1), vec![PixelSpan::new(5, 6, 1, 1)]);

    let rect_spans = rasterize_rect(10, 20, 4, 3);
    let rect_pixels: usize = rect_spans.iter().map(|s| s.pixel_count()).sum();
    // 4x3 矩形の外周ピクセル数は 4*3 - 2*1 = 10 ピクセル（重複なし）
    assert_eq!(rect_pixels, 10);
    assert!(rect_spans.iter().any(|s| s.contains(10, 20)));
    assert!(rect_spans.iter().any(|s| s.contains(13, 22)));
    assert!(!rect_spans.iter().any(|s| s.contains(11, 21)));
    assert!(!rect_spans.iter().any(|s| s.contains(12, 21)));

    // 3. circ / circfill: 半径負・0・正の対称性と重複なし検証
    assert!(rasterize_circ(10, 10, -1).is_empty());
    assert!(rasterize_circfill(10, 10, -1).is_empty());
    assert_eq!(rasterize_circ(10, 10, 0), vec![PixelSpan::new(10, 10, 1, 1)]);
    assert_eq!(rasterize_circfill(10, 10, 0), vec![PixelSpan::new(10, 10, 1, 1)]);

    // r = 1 の円枠は上下左右の4ピクセル（中心は含まない）
    let c1 = rasterize_circ(10, 10, 1);
    let c1_pixels: usize = c1.iter().map(|s| s.pixel_count()).sum();
    assert_eq!(c1_pixels, 4);
    assert!(c1.iter().any(|s| s.contains(10, 9)));
    assert!(c1.iter().any(|s| s.contains(10, 11)));
    assert!(c1.iter().any(|s| s.contains(9, 10)));
    assert!(c1.iter().any(|s| s.contains(11, 10)));
    assert!(!c1.iter().any(|s| s.contains(10, 10)));

    // r = 4 の塗りつぶし円は 2*4 + 1 = 9 本の水平スパンからなり、中心および四端を含む
    let cf4 = rasterize_circfill(50, 60, 4);
    assert_eq!(cf4.len(), 9);
    assert!(cf4.iter().any(|s| s.contains(50, 60)));
    assert!(cf4.iter().any(|s| s.contains(50, 56)));
    assert!(cf4.iter().any(|s| s.contains(50, 64)));
    assert!(cf4.iter().any(|s| s.contains(46, 60)));
    assert!(cf4.iter().any(|s| s.contains(54, 60)));

    // 4. tri / trifill: 三角形の枠線と塗りつぶし
    let tri_outline = rasterize_tri(10, 10, 16, 10, 13, 13);
    let tri_filled = rasterize_trifill(10, 10, 16, 10, 13, 13);
    assert_eq!(tri_filled.len(), 4); // y = 10..=13
    // 枠線上のすべてのピクセルが塗りつぶし三角形にも含まれていること
    for span in &tri_outline {
        for py in span.y..(span.y + span.h) {
            for px in span.x..(span.x + span.w) {
                assert!(
                    tri_filled.iter().any(|fs| fs.contains(px, py)),
                    "Filled triangle should contain outline pixel ({}, {})",
                    px,
                    py
                );
            }
        }
    }
    // 内部ピクセル (13, 11) は trifill に含まれ、tri (枠線) には含まれない
    assert!(tri_filled.iter().any(|s| s.contains(13, 11)));
    assert!(!tri_outline.iter().any(|s| s.contains(13, 11)));
}

#[test]
fn test_basic_shapes_in_ruby_script() {
    let script = r#"
def update
end

def draw
  line(0, 0, 255, 255, 8)
  line(10.5, 20.2, 50.8, 20.2, 12)
  rect(16, 16, 32, 24, 7)
  rectfill(20, 20, 24, 16, 1)
  circ(128, 128, 20, 10)
  circle(128, 128, 24, 11)
  circfill(64, 64, 12, 14)
  circlefill(192, 64, 12, 15)
  tri(100, 180, 120, 180, 110, 165, 9)
  trifill(140, 180, 160, 180, 150, 165, 11)
end
"#;
    let (tail, mrb) = cli::compile_ruby_script_str_with_filename(script, Some("test.rb")).unwrap();
    let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();
    runtime.call_draw();
}

#[test]
fn test_camera_and_clip_state_and_spans() {
    let mut state = DrawState::default();
    assert_eq!(state.cam_x, 0);
    assert_eq!(state.cam_y, 0);
    assert_eq!(state.clip, None);

    // カメラオフセット (100, 50) の適用検証
    state.set_camera(100, 50);
    let raw_rect = rasterize_rectfill(120, 80, 16, 10);
    let transformed = state.transform_and_clip_spans(&raw_rect);
    assert_eq!(transformed, vec![PixelSpan::new(20, 30, 16, 10)]);

    // クリッピング領域 (25, 32, 8, 6) を画面座標系で設定
    state.set_clip(25, 32, 8, 6);
    assert_eq!(state.clip, Some(PixelSpan::new(25, 32, 8, 6)));
    let clipped = state.transform_and_clip_spans(&raw_rect);
    // 画面座標 (20..36, 30..40) と clip (25..33, 32..38) の交差は (25, 32, 8, 6)
    assert_eq!(clipped, vec![PixelSpan::new(25, 32, 8, 6)]);

    // 画面外にはみ出す clip 指定は (0, 0, 256, 256) にクランプされること
    state.set_clip(-10, 200, 50, 100);
    assert_eq!(state.clip, Some(PixelSpan::new(0, 200, 40, 56)));

    // 幅または高さが 0 以下の clip は空領域となり何も描画されないこと
    state.set_clip(10, 10, 0, 20);
    assert!(state.is_clip_empty());
    assert!(state.transform_and_clip_spans(&raw_rect).is_empty());

    // リセット確認
    state.reset_camera();
    state.reset_clip();
    assert_eq!(state, DrawState::default());
}

#[test]
fn test_camera_and_clip_in_ruby_script() {
    let script = r#"
def update
  camera(32, 16)
end

def draw
  cls(1)
  rectfill(32, 16, 64, 64, 3)
  spr("🐰", 48, 32)
  print_text("WORLD", 40, 20, 7)

  # 画面座標系でのクリッピング設定と部分クリア
  clip(160, 8, 88, 64)
  cls(0)
  camera(100, 50)
  circfill(140, 80, 24, 11)
  line(100, 50, 200, 120, 8)
  spr("🐢", 132, 72)

  # クリッピング解除・カメラを特定オフセットに設定して終了（テスト側で状態検証）
  clip()
  camera(12, -8)
end
"#;
    let (tail, mrb) = cli::compile_ruby_script_str_with_filename(script, Some("test.rb")).unwrap();
    let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();

    runtime.call_update();
    assert_eq!(runtime.draw_state.borrow().cam_x, 32);
    assert_eq!(runtime.draw_state.borrow().cam_y, 16);

    runtime.call_draw();
    assert_eq!(runtime.draw_state.borrow().cam_x, 12);
    assert_eq!(runtime.draw_state.borrow().cam_y, -8);
    assert_eq!(runtime.draw_state.borrow().clip, None);
}

#[test]
fn test_camera_clip_example_script() {
    let (_, tail_data, mrb_bytes) = cli::compile_ruby_script_file(std::path::Path::new(
        "examples/camera_clip.rb",
    ))
    .expect("examples/camera_clip.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("Example should initialize");

    for _ in 0..5 {
        runtime.call_update();
        runtime.call_draw();
    }
    assert_eq!(runtime.draw_state.borrow().cam_x, 0);
    assert_eq!(runtime.draw_state.borrow().cam_y, 0);
    assert_eq!(runtime.draw_state.borrow().clip, None);
}

#[test]
fn test_sound_example_script() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/sound.rb"))
            .expect("examples/sound.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("Example should initialize");
    {
        let bank = runtime.sound_bank.borrow();
        for id in 0..4 {
            assert!(bank.sfx.contains_key(&id), "@SFX {} should be parsed", id);
            assert!(!bank.sfx[&id].pcm.is_empty());
        }
        assert!(bank.music.contains_key(&0), "@MUSIC 0 should be parsed");
        // 約 4 小節 (T140) 以上の長さ
        assert!(bank.music[&0].pcm.len() > sound::SAMPLE_RATE as usize * 4);
    }
    for _ in 0..5 {
        runtime.call_update();
        runtime.call_draw();
    }
}

#[test]
fn test_sound_api_queues_commands() {
    let src = r#"
$SFX = ["square c2 e2 g2"]
def update
  sfx(0)
  sfx(:jump, 2, 0.5)
  sfx("tri c3")
  stop_sfx(1)
  music(0, false)
  stop_music
end
def draw; end
__END__
@MUSIC 0
ch0 T120 L4 O4 c d e f
"#;
    let (tail, mrb) = cli::compile_ruby_script_str(src).unwrap();
    let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();
    assert!(runtime.sound_bank.borrow().sfx.contains_key(&0));
    assert!(runtime.sound_bank.borrow().music.contains_key(&0));

    runtime.call_update();
    {
        let bank = runtime.sound_bank.borrow();
        use sound::AudioCommand::*;
        assert_eq!(bank.pending_commands.len(), 6);
        assert!(matches!(bank.pending_commands[0], PlaySfxId { id: 0, channel: -1, .. }));
        assert!(matches!(
            &bank.pending_commands[1],
            PlaySfxInline { spec, channel: 2, .. } if spec == "jump"
        ));
        assert!(matches!(
            &bank.pending_commands[2],
            PlaySfxInline { spec, .. } if spec == "tri c3"
        ));
        assert!(matches!(bank.pending_commands[3], StopSfx { channel: 1 }));
        assert!(matches!(bank.pending_commands[4], PlayMusic { id: 0, looped: false, .. }));
        assert!(matches!(bank.pending_commands[5], StopMusic));
        assert!(bank.inline_cache.contains_key("jump"));
        assert!(bank.inline_cache.contains_key("tri c3"));
    }
}

#[test]
fn test_sound_api_callable_at_top_level() {
    let src = "$t = 0\nmusic(0)\nsfx(:jump)\ndef update\n  $t += 1\nend\ndef draw; end\n__END__\n@MUSIC 0\nch0 T120 L4 O4 c d e f\n";
    let (tail, mrb) = cli::compile_ruby_script_str(src).unwrap();
    let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();
    assert_eq!(runtime.sound_bank.borrow().current_music_id, Some(0));
    runtime.call_update();
    let t: i32 = runtime.vm.globals.get("$t").unwrap().as_ref().try_into().unwrap();
    assert_eq!(t, 1);
}

#[test]
fn test_game_script_sound_resources() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("game.rb"))
            .expect("game.rb should compile");
    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("game.rb should initialize");
    {
        let bank = runtime.sound_bank.borrow();
        for id in 0..=16 {
            assert!(bank.sfx.contains_key(&id), "game.rb @SFX {} missing", id);
        }
        for id in 0..=2 {
            assert!(bank.music.contains_key(&id), "game.rb @MUSIC {} missing", id);
        }
        // トップレベルでタイトル BGM を要求している
        assert_eq!(bank.current_music_id, Some(0));
    }
    runtime.call_update();
    runtime.call_draw();

    // 各 @MUSIC の ch0..ch3 が同じ長さ（ループ時にズレない）であること
    let mut block: Vec<String> = Vec::new();
    let mut blocks: Vec<Vec<String>> = Vec::new();
    for line in tail_data.lines() {
        let l = line.trim();
        if l.starts_with('@') {
            if !block.is_empty() {
                blocks.push(std::mem::take(&mut block));
            }
            if !l.starts_with("@MUSIC") {
                continue;
            }
            block.push(String::new());
        } else if !block.is_empty() && l.starts_with("ch") {
            block.push(l[3..].trim().to_string());
        }
    }
    if !block.is_empty() {
        blocks.push(block);
    }
    assert_eq!(blocks.len(), 3);
    for b in &blocks {
        let lens: Vec<usize> = b[1..]
            .iter()
            .map(|s| sound::parse_and_synthesize_sfx_pcm(s).len())
            .collect();
        let max = *lens.iter().max().unwrap();
        let min = *lens.iter().min().unwrap();
        assert!(max - min < sound::SAMPLE_RATE as usize / 50, "channel lengths differ: {:?}", lens);
    }
}

#[test]
fn test_sound_sharp_is_not_comment() {
    assert_eq!(sound::strip_sound_comment("c# d# # comment"), "c# d#");
    assert_eq!(sound::strip_sound_comment("# whole line"), "");
    // シャープ付きは半音上で、ナチュラルとは異なる波形になる
    let natural = sound::parse_and_synthesize_sfx_pcm("c2 d2");
    let sharp = sound::parse_and_synthesize_sfx_pcm("c#2 d#2");
    assert_eq!(natural.len(), sharp.len());
    assert_ne!(natural, sharp);
}

#[test]
fn test_sound_hot_reload_updates_definitions() {
    let v1 = "def update; end\ndef draw; end\n__END__\n@SFX 0 c2 e2\n";
    let v2 = "def update; end\ndef draw; end\n__END__\n@SFX 0 c2 e2 g2 c3\n@SFX 1 :coin\n";
    let (tail1, mrb1) = cli::compile_ruby_script_str(v1).unwrap();
    let (tail2, mrb2) = cli::compile_ruby_script_str(v2).unwrap();
    let mut runtime = GameRuntime::new(&tail1, &mrb1, true).unwrap();
    let len1 = runtime.sound_bank.borrow().sfx[&0].pcm.len();
    runtime.hot_reload(&tail2, &mrb2).unwrap();
    let bank = runtime.sound_bank.borrow();
    assert!(bank.sfx[&0].pcm.len() > len1);
    assert!(bank.sfx.contains_key(&1));
}

#[test]
fn test_oval_and_ovalfill_rasterization() {
    // 負の半径は空
    assert!(rasterize_oval(10, 10, -1, 5).is_empty());
    assert!(rasterize_oval(10, 10, 5, -1).is_empty());
    assert!(rasterize_ovalfill(10, 10, -1, 5).is_empty());
    assert!(rasterize_ovalfill(10, 10, 5, -1).is_empty());

    // 半径 (0, 0) は 1x1 点
    assert_eq!(rasterize_oval(10, 20, 0, 0), vec![PixelSpan::new(10, 20, 1, 1)]);
    assert_eq!(
        rasterize_ovalfill(10, 20, 0, 0),
        vec![PixelSpan::new(10, 20, 1, 1)]
    );

    // ry = 0 は水平線分、rx = 0 は垂直線分
    assert_eq!(rasterize_oval(10, 20, 4, 0), vec![PixelSpan::new(6, 20, 9, 1)]);
    assert_eq!(
        rasterize_ovalfill(10, 20, 4, 0),
        vec![PixelSpan::new(6, 20, 9, 1)]
    );
    assert_eq!(rasterize_oval(10, 20, 0, 3), vec![PixelSpan::new(10, 17, 1, 7)]);
    assert_eq!(rasterize_ovalfill(10, 20, 0, 3).len(), 7);

    // rx == ry の場合は circ / circfill と完全一致すること
    assert_eq!(rasterize_oval(50, 60, 8, 8), rasterize_circ(50, 60, 8));
    assert_eq!(
        rasterize_ovalfill(50, 60, 8, 8),
        rasterize_circfill(50, 60, 8)
    );

    // 横長楕円 (rx = 12, ry = 6) および縦長楕円 (rx = 5, ry = 11) の対称性と包含関係
    for &(cx, cy, rx, ry) in &[(100, 120, 12, 6), (80, 90, 5, 11)] {
        let outline = rasterize_oval(cx, cy, rx, ry);
        let filled = rasterize_ovalfill(cx, cy, rx, ry);

        // 塗りつぶし楕円のスパン数は 2 * ry + 1 本（各スキャンライン1本）
        assert_eq!(filled.len(), (2 * ry + 1) as usize);

        // 四端および中心が含まれること
        assert!(outline.iter().any(|s| s.contains(cx - rx, cy)));
        assert!(outline.iter().any(|s| s.contains(cx + rx, cy)));
        assert!(outline.iter().any(|s| s.contains(cx, cy - ry)));
        assert!(outline.iter().any(|s| s.contains(cx, cy + ry)));
        assert!(!outline.iter().any(|s| s.contains(cx, cy)));
        assert!(filled.iter().any(|s| s.contains(cx, cy)));

        // 枠線上の全ピクセルが上下左右対称であり、かつ塗りつぶし領域に含まれること
        for span in &outline {
            for py in span.y..(span.y + span.h) {
                for px in span.x..(span.x + span.w) {
                    let dx = px - cx;
                    let dy = py - cy;
                    assert!(outline.iter().any(|s| s.contains(cx - dx, cy + dy)));
                    assert!(outline.iter().any(|s| s.contains(cx + dx, cy - dy)));
                    assert!(outline.iter().any(|s| s.contains(cx - dx, cy - dy)));
                    assert!(filled.iter().any(|s| s.contains(px, py)));
                }
            }
        }
    }
}

#[test]
fn test_oval_example_script() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/oval.rb"))
            .expect("examples/oval.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("Example should initialize");

    for _ in 0..5 {
        runtime.call_update();
        runtime.call_draw();
    }
}

#[test]
fn test_mouse_example_script() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/mouse.rb"))
            .expect("examples/mouse.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("Mouse example should initialize");

    for _ in 0..10 {
        runtime.call_update();
        runtime.call_draw();
    }
}

#[test]
fn test_sprite_editor_example_script() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/sprite_editor.rb"))
            .expect("examples/sprite_editor.rb should compile");

    let mut runtime =
        GameRuntime::new_with_args(&tail_data, &mrb_bytes, true, &["game.rb".to_string()])
            .expect("Sprite editor should initialize with args");

    assert_eq!(runtime.config.borrow().resolved_text_size(), 8);
    assert!(runtime.banks.borrow().contains_key(&0), "Bank 0 should be retained in runtime right after initialization");

    for _ in 0..10 {
        runtime.call_update_result().expect("call_update should succeed");
        runtime.call_draw_result().expect("call_draw should succeed");
    }

    // スプライトエディタで出力される形式が __END__ リソースとして正常にパースできることを検証
    let sample_output = r#"
@SPRITE 0
....77....77....
...7EE7..7EE7...
...7EE7..7EE7...
...7777..7777...
...7777777777...
..888888888888..
.77707777770777.
.77707777770777.
.777777EE777777.
..777777777777..
...8888AA8888...
..778888888877..
..77.777777.77..
....777..777....
...777....777...
................
"#;
    let sprites = parse_tail_resources(sample_output);
    assert!(sprites.contains_key(&0));
    let sp0 = &sprites[&0];
    assert_eq!(sp0.width, 16);
    assert_eq!(sp0.height, 16);
    // (0, 0) は '.' (透明)
    assert_eq!(sp0.rgba[3], 0);
    // (4, 0) は '7' (白 = 0xFF, 0xF1, 0xE8, 0xFF)
    let off = 4 * 4;
    assert_eq!(sp0.rgba[off + 3], 255);
}

#[test]
fn test_pal_and_palt_state_and_sprite_rgba() {
    let mut state = DrawState::default();
    assert!(state.is_default_palette());
    assert_eq!(state.map_color_index(8), 8);

    // pal(8, 12): 8 (Red) -> 12 (Blue)
    state.set_pal(8, 12);
    assert!(!state.is_default_palette());
    assert_eq!(state.map_color_index(8), 12);
    assert_eq!(state.map_color(8), PALETTE[12]);
    // 負数・16以上のインデックスも mod 16 でラップアラウンド
    state.set_pal(-8, 28); // -8 mod 16 == 8, 28 mod 16 == 12
    assert_eq!(state.map_color_index(24), 12);

    state.reset_pal();
    assert!(state.is_default_palette());
    assert_eq!(state.map_color_index(8), 8);

    // palt(1, true): 色1を透過に設定
    state.set_palt(1, true);
    assert!(!state.is_default_palette());
    assert_eq!(state.palt_mask, 1 << 1);
    state.set_palt(1, false);
    assert!(state.is_default_palette());

    // スプライトの RGBA パレット置換 & 透過マスク検証
    // (0,0)=1(Dark Blue), (1,0)=8(Red), (2,0)=0(Black), (3,0)='.'(Transparent)
    let sp = SpriteData::from_lines(&["180."]);
    let mut pal_map = DEFAULT_PAL_MAP;
    pal_map[8] = 12; // Red -> Blue
    let palt_mask = 1 << 1; // Dark Blue を透明化
    let transformed = sp.apply_palette(&pal_map, palt_mask);

    // (0,0): Dark Blue (1) -> palt により透明 [0, 0, 0, 0]
    assert_eq!(&transformed[0..4], &[0, 0, 0, 0]);
    // (1,0): Red (8) -> Blue (12)
    assert_eq!(&transformed[4..8], &PALETTE_RGBA[12]);
    // (2,0): Black (0) -> 不透明の黒のまま
    assert_eq!(&transformed[8..12], &PALETTE_RGBA[0]);
    // (3,0): 元から透明 '.' -> 透明のまま
    assert_eq!(&transformed[12..16], &[0, 0, 0, 0]);
}

#[test]
fn test_pal_and_palt_in_ruby_script() {
    let ruby_code = r#"
$ok = false
def update
  pal(8, 12)
  pal([0, 1, 2, 3, 4, 5, 6, 7, 12, 9, 10, 11, 8, 13, 14, 15])
  palt(0, true)
  palt(1, true)
  palt(0, false)
  $ok = true
end
def draw
  cls(0)
  rectfill(10, 10, 20, 20, 8)
  oval(30, 30, 10, 6, 8)
  spr(0, 16, 16)
  spr("🐰", 32, 16)
  print_text("PAL", 4, 4, 8)
  pal()
  palt()
end
__END__
@SPRITE 0
180.
"#;
    let (tail, mrb) =
        cli::compile_ruby_script_str(ruby_code).expect("Ruby script should compile");
    let mut runtime = GameRuntime::new(&tail, &mrb, true).expect("Runtime should init");
    runtime.call_update();
    runtime.call_draw();
    let ok_obj = runtime.vm.globals.get("$ok").expect("$ok should exist");
    assert_eq!(
        bool::try_from(ok_obj.as_ref()).expect("$ok should be bool"),
        true
    );
    assert!(runtime.draw_state.borrow().is_default_palette());
}

#[test]
fn test_pal_example_script() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/pal.rb"))
            .expect("examples/pal.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("Example should initialize");

    for _ in 0..5 {
        runtime.call_update();
        runtime.call_draw();
    }
}

#[test]
fn test_tilemap_parse_and_mget_mset() {
    let data = r#"
@SPRITE 1 🌲
@SPRITE 2 🍎
@MAP 0 0
1.2a
1 0 12 0x1F
@MAP 10 5
3,4,.,7
"#;
    let sprites = parse_tail_resources(data);
    assert!(sprites.contains_key(&1));
    assert!(sprites.contains_key(&2));

    let mut tmap = parse_tail_map(data);
    // Row 0 (compact hex mode): '1'->1, '.'->0, '2'->2, 'a'->10
    assert_eq!(tmap.get(0, 0), 1);
    assert_eq!(tmap.get(1, 0), 0);
    assert_eq!(tmap.get(2, 0), 2);
    assert_eq!(tmap.get(3, 0), 10);
    // Row 1 (space-separated mode): 1, 0, 12, 31
    assert_eq!(tmap.get(0, 1), 1);
    assert_eq!(tmap.get(1, 1), 0);
    assert_eq!(tmap.get(2, 1), 12);
    assert_eq!(tmap.get(3, 1), 31);
    // Second @MAP block at offset (10, 5): 3, 4, 0, 7
    assert_eq!(tmap.get(10, 5), 3);
    assert_eq!(tmap.get(11, 5), 4);
    assert_eq!(tmap.get(12, 5), 0);
    assert_eq!(tmap.get(13, 5), 7);
    assert_eq!(tmap.width, 14);
    assert_eq!(tmap.height, 6);

    // mset で書き換え・0消去確認
    tmap.set(1, 0, 99);
    assert_eq!(tmap.get(1, 0), 99);
    tmap.set(1, 0, 0);
    assert_eq!(tmap.get(1, 0), 0);
    assert!(!tmap.cells.contains_key(&(1, 0)));
}

#[test]
fn test_map_mget_mset_in_ruby_script_and_hot_reload() {
    let script_v1 = r#"
$tile_at_2_0 = 0
def update
  $tile_at_2_0 = mget(2, 0)
  mset(2, 0, 0)
  mset(5, 3, 2)
end
def draw
  cls(0)
  map(0, 0, 0, 0, 8, 4)
end
__END__
@SPRITE 1 🌲
@SPRITE 2 🍎
@MAP 0 0
11211111
1......1
"#;
    let (tail_v1, mrb_v1) = cli::compile_ruby_script_str(script_v1).unwrap();
    let mut runtime = GameRuntime::new(&tail_v1, &mrb_v1, true).unwrap();
    runtime.call_update();
    runtime.call_draw();

    let read_val: i32 = runtime
        .vm
        .globals
        .get("$tile_at_2_0")
        .unwrap()
        .as_ref()
        .try_into()
        .unwrap();
    assert_eq!(read_val, 2);
    assert_eq!(runtime.tilemap.borrow().get(2, 0), 0);
    assert_eq!(runtime.tilemap.borrow().get(5, 3), 2);

    // @MAP を変更せずにコードだけホットリロードした場合、実行時の mset 変更が維持されること
    let script_v2 = r#"
$tile_at_2_0 = 0
def update
  $tile_at_2_0 = mget(5, 3)
end
def draw
  map()
end
__END__
@SPRITE 1 🌲
@SPRITE 2 🍎
@MAP 0 0
11211111
1......1
"#;
    let (tail_v2, mrb_v2) = cli::compile_ruby_script_str(script_v2).unwrap();
    runtime.hot_reload(&tail_v2, &mrb_v2).unwrap();
    assert_eq!(runtime.tilemap.borrow().get(2, 0), 0);
    assert_eq!(runtime.tilemap.borrow().get(5, 3), 2);

    // @MAP 自体を編集してホットリロードした場合、新しい @MAP が反映されること
    let script_v3 = r#"
$tile_at_2_0 = 0
def update
end
def draw
  map()
end
__END__
@SPRITE 1 🌲
@SPRITE 2 🍎
@MAP 0 0
22222222
"#;
    let (tail_v3, mrb_v3) = cli::compile_ruby_script_str(script_v3).unwrap();
    runtime.hot_reload(&tail_v3, &mrb_v3).unwrap();
    assert_eq!(runtime.tilemap.borrow().get(2, 0), 2);
    assert_eq!(runtime.tilemap.borrow().get(5, 3), 0);
}

#[test]
fn test_tilemap_example_script() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/tilemap.rb"))
            .expect("examples/tilemap.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("Example should initialize");

    for _ in 0..5 {
        runtime.call_update();
        runtime.call_draw();
    }
}

#[test]
fn test_tilemap_editor_example_script() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/tilemap_editor.rb"))
            .expect("examples/tilemap_editor.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("Tilemap editor should initialize");

    assert_eq!(runtime.config.borrow().resolved_text_size(), 8);

    let mut update_time = std::time::Duration::ZERO;
    let mut draw_time = std::time::Duration::ZERO;
    for _ in 0..60 {
        let t0 = std::time::Instant::now();
        runtime.call_update_result().expect("Tilemap editor call_update should succeed");
        update_time += t0.elapsed();

        let t1 = std::time::Instant::now();
        runtime.call_draw_result().expect("Tilemap editor call_draw should succeed");
        draw_time += t1.elapsed();
    }
    println!("Update total: {:?} ({:.2} ms/frame)", update_time, update_time.as_secs_f64() * 1000.0 / 60.0);
    println!("Draw total: {:?} ({:.2} ms/frame)", draw_time, draw_time.as_secs_f64() * 1000.0 / 60.0);
    if !cfg!(debug_assertions) {
        assert!(draw_time.as_secs_f64() * 1000.0 / 60.0 < 20.0, "Draw time should easily maintain 60 FPS (got {:.2} ms/frame)", draw_time.as_secs_f64() * 1000.0 / 60.0);
    }

    // タイルマップエディタが出力する形式の @MAP および @SPRITE をパースできることを検証
    let sample_map_output = r#"
@MAP 0 0
11111111111111111111111111111111
1..............................1
1...4444.......................1
1..............................1
"#;
    let parsed_map = parse_tail_map(sample_map_output);
    assert_eq!(parsed_map.get(0, 0), 1);
    assert_eq!(parsed_map.get(1, 1), 0);
    assert_eq!(parsed_map.get(4, 2), 4);
}

#[test]
fn test_parse_tail_objects_and_ruby_api() {
    let sample = r#"
@MAP 0 0
1111
1001

@OBJECTS
# type x y [properties]
player 48 48 spr="🐰" hp=100
apple 144 32 spr="🍎" score=100 sound="coin"
door 160 80 spr=13 target="stage2:16,32" key_id="gold"
enemy 208 48 spr="🦇" hp=30 speed=1.5 patrol="lr"
sign 112 112 spr=14 text="Hello world! Danger ahead."
zone 64 64 w=48 h=32 name="boss_trigger" once=true active
"#;

    let objs = parse_tail_objects(sample);
    assert_eq!(objs.len(), 6);

    // 1. player
    let p = &objs[0];
    assert_eq!(p.obj_type, "player");
    assert_eq!(p.x, 48);
    assert_eq!(p.y, 48);
    assert_eq!(p.props.get("spr"), Some(&MapPropValue::String("🐰".to_string())));
    assert_eq!(p.props.get("hp"), Some(&MapPropValue::Integer(100)));

    // 2. apple
    let a = &objs[1];
    assert_eq!(a.obj_type, "apple");
    assert_eq!(a.x, 144);
    assert_eq!(a.y, 32);
    assert_eq!(a.props.get("score"), Some(&MapPropValue::Integer(100)));
    assert_eq!(a.props.get("sound"), Some(&MapPropValue::String("coin".to_string())));

    // 3. door (spr as int)
    let d = &objs[2];
    assert_eq!(d.obj_type, "door");
    assert_eq!(d.props.get("spr"), Some(&MapPropValue::Integer(13)));
    assert_eq!(d.props.get("target"), Some(&MapPropValue::String("stage2:16,32".to_string())));

    // 4. enemy (float speed)
    let e = &objs[3];
    assert_eq!(e.obj_type, "enemy");
    assert_eq!(e.props.get("speed"), Some(&MapPropValue::Float(1.5)));

    // 5. sign (quoted space string)
    let s = &objs[4];
    assert_eq!(s.obj_type, "sign");
    assert_eq!(s.props.get("text"), Some(&MapPropValue::String("Hello world! Danger ahead.".to_string())));

    // 6. zone (flag boolean)
    let z = &objs[5];
    assert_eq!(z.obj_type, "zone");
    assert_eq!(z.props.get("w"), Some(&MapPropValue::Integer(48)));
    assert_eq!(z.props.get("h"), Some(&MapPropValue::Integer(32)));
    assert_eq!(z.props.get("once"), Some(&MapPropValue::Bool(true)));
    assert_eq!(z.props.get("active"), Some(&MapPropValue::Bool(true)));

    // Ruby API execution test
    let script = format!(r#"
$found_player = nil
$found_apples = []
objects.each do |obj|
  if obj[:type] == "player"
    $found_player = obj
  end
end

objects(:apple).each do |a|
  $found_apples << a
end

$obj_count = objects.size

def update
end
def draw
end
__END__
{}
"#, sample);

    let (tail, mrb) = cli::compile_ruby_script_str(&script).unwrap();
    let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();
    println!("GLOBALS: {:?}", runtime.vm.globals.keys().collect::<Vec<_>>());
    runtime.call_update_result().unwrap();

    // Verify globals
    let found_p = runtime.vm.globals.get("$found_player").expect("found player");
    assert!(!found_p.is_nil());
    let apples = runtime.vm.globals.get("$found_apples").expect("found apples");
    if let RValue::Array(ref arr) = apples.value {
        assert_eq!(arr.borrow().len(), 1);
    } else {
        panic!("$found_apples must be array");
    }
    let count_val = runtime.vm.globals.get("$obj_count").expect("obj count");
    if let RValue::Integer(cnt) = count_val.value {
        assert_eq!(cnt, 6);
    } else {
        panic!("$obj_count must be 6");
    }

    // load_resource_objects test
    let test_map_path = "target/test_objects.map";
    std::fs::write(test_map_path, sample).unwrap();

    let load_script = format!(r#"
$loaded_all = load_resource_objects("{}")
$loaded_apples = load_resource_objects("{}", :apple)
"#, test_map_path, test_map_path);

    let (_, load_mrb) = cli::compile_ruby_script_str(&load_script).unwrap();
    let mut load_rt = GameRuntime::new("", &load_mrb, true).unwrap();
    let _ = load_rt.call_update_result();

    let loaded_all = load_rt.vm.globals.get("$loaded_all").unwrap();
    if let RValue::Array(ref arr) = loaded_all.value {
        assert_eq!(arr.borrow().len(), 6);
    } else {
        panic!("$loaded_all must be array of 6");
    }

    let loaded_apples = load_rt.vm.globals.get("$loaded_apples").unwrap();
    if let RValue::Array(ref arr) = loaded_apples.value {
        assert_eq!(arr.borrow().len(), 1);
    } else {
        panic!("$loaded_apples must be array of 1");
    }

    let _ = std::fs::remove_file(test_map_path);
}

#[test]
fn test_tilemap_editor_object_layer_workflow() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/tilemap_editor.rb"))
            .expect("tilemap_editor.rb should compile");

    let mut runtime =
        GameRuntime::new_with_args(&tail_data, &mrb_bytes, true, &[])
            .expect("Tilemap editor should initialize");

    // 1フレーム実行
    runtime.call_update_result().unwrap();
    runtime.call_draw_result().unwrap();

    // generate_map_text を呼び出して初期状態のマップテキストを確認
    let res = mrb_funcall(&mut runtime.vm, None, "generate_map_text", &[]).unwrap();
    let text: String = res.as_ref().try_into().unwrap();
    assert!(text.contains("@MAP 0 0"));

    // $objects にオブジェクトを追加して generate_map_text をテスト
    let obj1 = MapObject {
        obj_type: "player".to_string(),
        x: 48,
        y: 64,
        props: [
            ("spr".to_string(), MapPropValue::String("🐰".to_string())),
            ("hp".to_string(), MapPropValue::Integer(100)),
        ]
        .into_iter()
        .collect(),
    };
    let obj2 = MapObject {
        obj_type: "apple".to_string(),
        x: 112,
        y: 80,
        props: [
            ("spr".to_string(), MapPropValue::String("🍎".to_string())),
            ("score".to_string(), MapPropValue::Integer(50)),
        ]
        .into_iter()
        .collect(),
    };
    let obj3 = MapObject {
        obj_type: "door".to_string(),
        x: 160,
        y: 32,
        props: [
            ("spr".to_string(), MapPropValue::Integer(13)),
            ("target".to_string(), MapPropValue::String("room2".to_string())),
        ]
        .into_iter()
        .collect(),
    };

    let objs_ruby = Rc::new(RObject::array(vec![
        obj1.to_ruby_hash(),
        obj2.to_ruby_hash(),
        obj3.to_ruby_hash(),
    ]));
    runtime.vm.globals.insert("$objects".to_string(), objs_ruby);

    let res_with_objs = mrb_funcall(&mut runtime.vm, None, "generate_map_text", &[]).unwrap();
    let out_str: String = res_with_objs.as_ref().try_into().unwrap();

    assert!(out_str.contains("@MAP 0 0"), "Should contain @MAP");
    assert!(out_str.contains("@OBJECTS"), "Should contain @OBJECTS section");
    assert!(out_str.contains("player 48 64"), "Should contain player pos");
    assert!(out_str.contains(r#"spr="🐰""#), "Should contain player spr");
    assert!(out_str.contains("hp=100"), "Should contain player hp");
    assert!(out_str.contains("apple 112 80"), "Should contain apple pos");
    assert!(out_str.contains(r#"spr="🍎""#), "Should contain apple spr");
    assert!(out_str.contains("score=50"), "Should contain apple score");
    assert!(out_str.contains("door 160 32"), "Should contain door pos");
    assert!(out_str.contains("spr=13"), "Should contain door spr");
    assert!(out_str.contains(r#"target="room2""#), "Should contain door target");

    // オブジェクトモードに切り替えてキャンバス上で描画 (NoMethodError: floor for Float が出ないことの確認)
    runtime.vm.globals.insert("$current_mode".to_string(), Rc::new(RObject::symbol("objects".into())));
    let obj_cls = runtime.vm.object_class.clone();
    mrb_define_cmethod(
        &mut runtime.vm,
        obj_cls.clone(),
        "mouse_x",
        Box::new(|_, _| Ok(Rc::new(RObject::integer(50)))),
    );
    mrb_define_cmethod(
        &mut runtime.vm,
        obj_cls.clone(),
        "mouse_y",
        Box::new(|_, _| Ok(Rc::new(RObject::integer(50)))),
    );
    runtime.call_draw_result().expect("Draw in objects mode should succeed without floor error");

    // ヘッダーバー TERRAIN (x: 100, y: 10) クリック判定
    mrb_define_cmethod(
        &mut runtime.vm,
        obj_cls.clone(),
        "mouse_x",
        Box::new(|_, _| Ok(Rc::new(RObject::integer(100)))),
    );
    mrb_define_cmethod(
        &mut runtime.vm,
        obj_cls.clone(),
        "mouse_y",
        Box::new(|_, _| Ok(Rc::new(RObject::integer(10)))),
    );
    mrb_define_cmethod(
        &mut runtime.vm,
        obj_cls.clone(),
        "btnp",
        Box::new(|_, _| Ok(Rc::new(RObject::boolean(true)))),
    );
    runtime.call_update_result().unwrap();
    let mode = runtime.vm.globals.get("$current_mode").unwrap();
    assert_eq!(mode.as_ref(), &RObject::symbol("terrain".into()), "Clicking x:100 y:10 should switch to TERRAIN");

    // ヘッダーバー OBJECTS (x: 150, y: 10) クリック判定
    mrb_define_cmethod(
        &mut runtime.vm,
        obj_cls.clone(),
        "mouse_x",
        Box::new(|_, _| Ok(Rc::new(RObject::integer(150)))),
    );
    runtime.call_update_result().unwrap();
    let mode = runtime.vm.globals.get("$current_mode").unwrap();
    assert_eq!(mode.as_ref(), &RObject::symbol("objects".into()), "Clicking x:150 y:10 should switch to OBJECTS");

    // キャンバス上の空白をクリックして新規オブジェクトを配置 (x: 100, y: 100)
    mrb_define_cmethod(
        &mut runtime.vm,
        obj_cls.clone(),
        "mouse_x",
        Box::new(|_, _| Ok(Rc::new(RObject::integer(100)))),
    );
    mrb_define_cmethod(
        &mut runtime.vm,
        obj_cls.clone(),
        "mouse_y",
        Box::new(|_, _| Ok(Rc::new(RObject::integer(100)))),
    );
    runtime.call_update_result().expect("Placing object in objects mode should succeed");
    runtime.call_draw_result().expect("Drawing after placing object should succeed");
}

#[test]
fn test_usakame_survivors_full_simulation() {
    let (full_src, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("game.rb"))
            .expect("game.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("game.rb should initialize");

    // 1. タイトル画面での update / draw
    for _ in 0..3 {
        runtime.call_update();
        runtime.call_draw();
    }

    // 2. ゲーム開始・全武器解禁・全敵スポーン・スキル・タッグ切替・描画の総合検証スクリプトを実行
    let (code_prefix, _) = bundle::split_ruby_source_and_tail(&full_src);
    let sim_driver = format!(
        "{}\n{}",
        code_prefix,
        r#"
def run_full_sim
  start_new_game
  # 全アップグレードを Lv2 にして全ウェポン(🥕🛡️⚡🔥🌙🧲❤️⭐)を同時稼働させる
  $upg_lv = [2, 2, 2, 2, 2, 2, 2, 2]
  # 全種類の敵(0..6)をスポーン
  spawn_enemy(0, 260, 248)
  spawn_enemy(1, 230, 248)
  spawn_enemy(2, 248, 270)
  spawn_enemy(3, 248, 220)
  spawn_enemy(4, 280, 260)
  spawn_enemy(5, 290, 248)
  spawn_enemy(6, 200, 248)

  # 60フレーム戦闘を進める
  step = 0
  while step < 60
update
draw
if step == 10
  trigger_active_skill
elsif step == 20
  $tag_gauge = 100
  trigger_tag_switch
elsif step == 30
  trigger_active_skill
elsif step == 40
  break_tile_at(3, 1)
  break_tile_at(4, 2)
end
step += 1
  end

  # 全種類のアイテム回収とレベルアップ遷移・選択の検証
  spawn_item($px, $py, 0, 5)
  spawn_item($px, $py, 1, 10)
  spawn_item($px, $py, 2, 20)
  spawn_item($px, $py, 3, 25)
  spawn_item($px, $py, 4, 1)
  spawn_item($px, $py, 5, 1)
  update_items
  if $state == STATE_LEVELUP
draw
apply_upgrade($choices[0])
$state = STATE_PLAY
  end

  # VICTORY 画面と GAMEOVER 画面の描画検証
  $state = STATE_VICTORY
  update
  draw
  $state = STATE_GAMEOVER
  update
  draw
end
"#
    );

    let (_, sim_mrb) = cli::compile_ruby_script_str(&sim_driver).unwrap();
    runtime.hot_reload(&tail_data, &sim_mrb).unwrap();
    mrb_funcall(&mut runtime.vm, None, "run_full_sim", &[])
        .expect("Full simulation of USAKAME SURVIVORS should succeed without any Ruby error");
}

#[test]
fn test_demo_example_script() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/demo.rb"))
            .expect("examples/demo.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("examples/demo.rb should initialize");

    // 登場歩行 -> 全会話 -> 暗転完了まで 3500 フレーム回して完走を検証
    for _ in 0..3500 {
        runtime.call_update();
        runtime.call_draw();
    }
}

#[test]
fn test_resolution_example_script() {
    let (full_src, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/resolution.rb"))
            .expect("examples/resolution.rb should compile");

    let initial_config = parse_config_from_source(&full_src);
    assert_eq!(initial_config.screen_width, 640);
    assert_eq!(initial_config.screen_height, 480);
    assert_eq!(initial_config.window_scale, 2.0);
    assert_eq!(initial_config.sprite_scale, 2.0);
    assert_eq!(initial_config.text_size, 16);

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("examples/resolution.rb should initialize");

    assert_eq!(runtime.config.borrow().screen_width, 640);
    assert_eq!(runtime.config.borrow().screen_height, 480);
    assert_eq!(runtime.config.borrow().sprite_scale, 2.0);
    assert_eq!(runtime.config.borrow().text_size, 16);

    assert!(runtime.sprites.borrow().contains_key(&1), "Sprite 1 should be loaded");
    assert!(runtime.sprites.borrow().contains_key(&2), "Sprite 2 should be loaded");
    assert!(runtime.sprites.borrow().contains_key(&3), "Sprite 3 should be loaded");
    assert_eq!(runtime.tilemap.borrow().get(0, 0), 3, "Tilemap at (0, 0) should be 3");

    for _ in 0..60 {
        runtime.call_update();
        runtime.call_draw();
    }
}

#[test]
fn test_editor_and_game_mutual_sync_workflow() {
    let temp_dir = std::env::temp_dir().join("uk_test_sync_workflow");
    let _ = std::fs::remove_dir_all(&temp_dir);
    std::fs::create_dir_all(&temp_dir).unwrap();

    let game_rb = temp_dir.join("game.rb");
    let game_spr = temp_dir.join("game.spr");
    let game_map = temp_dir.join("game.map");

    // 1. game.rb の初期状態 (コードのみ、リソースなし)
    let game_src = r#"
$tile_0_0 = 0
def update
  $tile_0_0 = mget(0, 0)
end
def draw
  map()
  spr(1, 0, 0)
end
"#;
    std::fs::write(&game_rb, game_src).unwrap();

    // 2. スプライトエディタスクリプトの実行を模擬:
    //    game.rb を対象にしてスプライト1を作成し、game.spr に保存
    let spr_editor_script = format!(r#"
$target = "{}"
$save = $target[0, $target.size - 3] + ".spr"
$custom_spr_text = "@SPRITE 1\n8888888888888888\n" + ("8888888888888888\n" * 15)
save_file($save, $custom_spr_text)
"#, game_rb.to_str().unwrap().replace('\\', "/"));

    let (_, mrb_spr_editor) = cli::compile_ruby_script_str(&spr_editor_script).unwrap();
    let _ = GameRuntime::new("", &mrb_spr_editor, true).unwrap();

    assert!(game_spr.exists(), "game.spr should be generated by sprite editor");

    // 3. タイルマップエディタスクリプトの実行を模擬:
    //    game.rb を対象にしてマップ (0, 0)=1 を作成し、game.map に保存
    //    同時に game.spr からスプライト1が正しく読み込めることを確認
    let map_editor_script = format!(r#"
$target = "{}"
$save = $target[0, $target.size - 3] + ".map"
$spr_path = $target[0, $target.size - 3] + ".spr"

# スプライトの相互同期チェック
$slots = load_resource_sprites($spr_path, 2)
$spr1_loaded = (!$slots[1].nil?)

# マップデータの保存
$map_text = "@MAP 0 0\n1\n"
save_file($save, $map_text)
"#, game_rb.to_str().unwrap().replace('\\', "/"));

    let (_, mrb_map_editor) = cli::compile_ruby_script_str(&map_editor_script).unwrap();
    let rt_map_editor = GameRuntime::new("", &mrb_map_editor, true).unwrap();

    let spr1_loaded: bool = rt_map_editor.vm.globals.get("$spr1_loaded").unwrap().as_ref().try_into().unwrap();
    assert!(spr1_loaded, "Tilemap editor should load sprite 1 from game.spr");
    assert!(game_map.exists(), "game.map should be generated by tilemap editor");

    // 4. ゲーム側 (game.rb) をコンパイル & 実行:
    //    game.spr と game.map が自動マージされてゲームに反映されること
    let (_, merged_tail, game_mrb) = cli::compile_ruby_script_file(&game_rb).unwrap();
    assert!(merged_tail.contains("@SPRITE 1"));
    assert!(merged_tail.contains("@MAP 0 0"));

    let mut game_rt = GameRuntime::new(&merged_tail, &game_mrb, true).unwrap();
    game_rt.call_update();
    game_rt.call_draw();

    let tile_0_0: i32 = game_rt.vm.globals.get("$tile_0_0").unwrap().as_ref().try_into().unwrap();
    assert_eq!(tile_0_0, 1, "Game should read tile (0, 0) as 1 from external game.map");
    assert!(game_rt.sprites.borrow().contains_key(&1), "Game should load sprite 1 from external game.spr");

    // 5. ホットリロードの相互検証:
    //    スプライトエディタで game.spr を更新した場合、スナップショットが変化してゲームがホットリロードされること
    let snap_before = bundle::get_script_and_resources_snapshot(&game_rb);

    // スプライトを色 11 (緑) で上書き
    let updated_spr_text = format!("@SPRITE 1\nBBBBBBBBBBBBBBBB\n{}", "BBBBBBBBBBBBBBBB\n".repeat(15));
    std::fs::write(&game_spr, updated_spr_text).unwrap();

    let snap_after = bundle::get_script_and_resources_snapshot(&game_rb);
    assert_ne!(snap_before, snap_after, "Snapshot must detect changes in game.spr");

    // ゲーム側にホットリロードを適用
    let (_, reloaded_tail, reloaded_mrb) = cli::compile_ruby_script_file(&game_rb).unwrap();
    game_rt.hot_reload(&reloaded_tail, &reloaded_mrb).unwrap();

    // タイルマップエディタ側でも file_mtime が更新されること
    let mtime_after = std::fs::metadata(&game_spr).unwrap().modified().unwrap();
    assert!(mtime_after > std::time::UNIX_EPOCH);

    let _ = std::fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_split_game_example_script() {
    // examples/split_game.rb の自動コンパイル・リソース結合をテスト
    let split_script = std::path::Path::new("examples/split_game.rb");
    assert!(split_script.exists());

    // 外部リソース (.spr, .map, .sfx) が自動検出され、マージされていること
    let (_full_src, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(split_script).expect("split_game.rb should compile");

    assert!(tail_data.contains("@SPRITE 0"), "Should contain @SPRITE from split_game.spr");
    assert!(tail_data.contains("@MAP 0 0"), "Should contain @MAP from split_game.map");
    assert!(tail_data.contains("@SFX 0"), "Should contain @SFX from split_game.sfx");
    assert!(tail_data.contains("@MUSIC 0"), "Should contain @MUSIC from split_game.sfx");

    // ランタイム起動
    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("split_game.rb should initialize");

    // スプライトとマップが正常に初期化されていること
    assert!(runtime.sprites.borrow().contains_key(&0));
    assert!(runtime.sprites.borrow().contains_key(&1));
    assert_eq!(runtime.tilemap.borrow().get(0, 0), 3, "Outer tile should be water (3)");

    // update と draw を複数フレーム回す
    for _ in 0..10 {
        runtime.call_update_result().expect("split_game update should succeed");
        runtime.call_draw_result().expect("split_game draw should succeed");
    }

    // uk pack でスタンドアロンスクリプトにパックできることのテスト
    let temp_packed = std::env::temp_dir().join("test_split_packed.rb");
    let packed_content = bundle::pack_script_to_standalone_source(split_script).unwrap();
    std::fs::write(&temp_packed, &packed_content).unwrap();

    assert!(packed_content.contains("__END__"));
    assert!(packed_content.contains("@SPRITE 0"));
    assert!(packed_content.contains("@MAP 0 0"));
    assert!(packed_content.contains("@SFX 0"));

    let _ = std::fs::remove_file(&temp_packed);
}

#[test]
fn test_rabbit_knight_example_script() {
    let script = std::path::Path::new("examples/rabbit_knight.rb");
    assert!(script.exists());

    let (_full_src, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(script).expect("rabbit_knight.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("rabbit_knight.rb should initialize");

    // スプライト 0〜5 (うさぎ剣士) と 6〜8 (タイル) が存在すること
    for id in 0..=8 {
        assert!(
            runtime.sprites.borrow().contains_key(&id),
            "Sprite {} should be defined",
            id
        );
    }

    // 複数フレーム実行 (update と draw)
    for _ in 0..15 {
        runtime
            .call_update_result()
            .expect("rabbit_knight update should succeed");
        runtime
            .call_draw_result()
            .expect("rabbit_knight draw should succeed");
    }

    // can_move_to? (移動判定) が正常に動作することを検証
    let can_move = mrb_funcall(
        &mut runtime.vm,
        None,
        "can_move_to?",
        &[Rc::new(RObject::integer(32)), Rc::new(RObject::integer(32))],
    )
    .expect("can_move_to? should succeed");
    assert_eq!(can_move.as_ref(), &RObject::boolean(true));
}

#[test]
fn test_bank_parse_and_sprite_sync() {
    let tail = "@SPRITE 0\n7777\n7777\n@SPRITE 1\n8888\n8888\n";
    let (sprites, banks) = parse_tail_resources_full(tail, None);

    assert!(sprites.contains_key(&0));
    assert!(sprites.contains_key(&1));
    assert!(banks.contains_key(&0));

    let bank0 = &banks[&0];
    assert_eq!(bank0.width, 256);
    assert_eq!(bank0.height, 256);

    // Bank 0 の (0, 0) にスプライト 0 (色 7 = 白) が反映されていること
    let off0 = 0;
    assert_eq!(&bank0.rgba[off0..off0 + 4], &PALETTE_RGBA[7]);

    // Bank 0 の (16, 0) にスプライト 1 (色 8 = 赤) が反映されていること
    let off1 = 16 * 4;
    assert_eq!(&bank0.rgba[off1..off1 + 4], &PALETTE_RGBA[8]);

    // PNG エンコードとデコードの往復
    let png_bytes = bank0.to_png_bytes().expect("Should encode bank to PNG");
    let decoded_bank = BankData::from_png_bytes(0, &png_bytes).expect("Should decode bank from PNG");
    assert_eq!(bank0.rgba, decoded_bank.rgba);
}

#[test]
fn test_bank_api_and_blt_in_ruby_script() {
    let src = r#"
spr_bank(0)
map_bank(0)

def update
end

def draw
  cls(0)
  # 基本スプライト (16x16)
  spr(0, 10, 20)
  # 左右反転
  spr(0, 30, 20, true, false)
  # PICO-8 スタイル: 2x2タイル (32x32) 描画
  spr(0, 50, 20, 2, 2)
  # PICO-8 スタイル: 2x2タイル + 左右反転
  spr(0, 90, 20, 2, 2, true, false)

  # blt: バンク0の (0, 0) から 18x16 px を描画
  blt(10, 60, 0, 0, 0, 18, 16)
  # blt: 負数フリップ (左右反転)
  blt(40, 60, 0, 0, 0, -18, 16)
  # blt: 回転と拡大
  blt(80, 60, 0, 0, 0, 18, 16, 45, 1.5)

  # マップ描画 (第7引数でバンク指定も可能)
  map(0, 0, 0, 100, 4, 4, 0)
end
__END__
@SPRITE 0
7777777777777777
7777777777777777
"#;
    let (tail_data, mrb_bytes) = cli::compile_ruby_script_str(src).unwrap();
    let mut runtime = GameRuntime::new(&tail_data, &mrb_bytes, true).unwrap();

    // update, draw が正常に動作すること
    runtime.call_update_result().unwrap();
    runtime.call_draw_result().unwrap();

    assert_eq!(*runtime.active_spr_bank.borrow(), 0);
    assert_eq!(*runtime.active_map_bank.borrow(), 0);
}

#[test]
fn test_bank_load_and_b64_helpers_in_ruby() {
    let src = r#"
$pixels = Array.new(256 * 256, 7)
$b64 = bank_to_b64_png($pixels)
__END__
@SPRITE 0
8888
"#;
    let (tail_data, mrb_bytes) = cli::compile_ruby_script_str(src).unwrap();
    let runtime = GameRuntime::new(&tail_data, &mrb_bytes, true).unwrap();

    let vm = &runtime.vm;
    let b64_val = vm.globals.get("$b64").expect("$b64 should be set");
    if let RValue::String(ref s, _) = b64_val.value {
        let str_val = String::from_utf8_lossy(&s.borrow()).to_string();
        assert!(!str_val.is_empty());
        // デコードして 256x256 BankData に復元できるか検証
        let bank = BankData::from_base64_png(0, &str_val).expect("Should decode generated b64");
        assert_eq!(bank.width, 256);
        assert_eq!(bank.height, 256);
        assert_eq!(&bank.rgba[0..4], &PALETTE_RGBA[7]);
    } else {
        panic!("Expected $b64 to be a String");
    }
}

#[test]
fn test_bank_get_set_pixel_and_rect_apis_in_ruby() {
    let src = r#"
# 1. 1ピクセル設定
set_bank_pixel(0, 10, 20, 8)
$p1 = get_bank_pixel(0, 10, 20)
$p2 = get_bank_pixel(0, 11, 20)

# 2. 矩形領域更新 & 取得
rect_in = [1, 2, 3, 4]
update_bank_rect(0, 5, 5, 2, 2, rect_in)
$rect_out = get_bank_rect(0, 5, 5, 2, 2)

# 3. 全体取得
$all_pixels = get_bank_pixels(0)
__END__
"#;
    let (tail_data, mrb_bytes) = cli::compile_ruby_script_str(src).unwrap();
    let runtime = GameRuntime::new(&tail_data, &mrb_bytes, true).unwrap();
    let vm = &runtime.vm;

    // p1 == 8, p2 == nil
    let p1 = vm.globals.get("$p1").unwrap();
    assert!(matches!(p1.value, RValue::Integer(8)));
    let p2 = vm.globals.get("$p2").unwrap();
    assert!(matches!(p2.value, RValue::Nil));

    // rect_out == [1, 2, 3, 4]
    let r_val = vm.globals.get("$rect_out").unwrap();
    if let RValue::Array(ref ary) = r_val.value {
        let ary_b = ary.borrow();
        assert_eq!(ary_b.len(), 4);
        assert!(matches!(ary_b[0].value, RValue::Integer(1)));
        assert!(matches!(ary_b[1].value, RValue::Integer(2)));
        assert!(matches!(ary_b[2].value, RValue::Integer(3)));
        assert!(matches!(ary_b[3].value, RValue::Integer(4)));
    } else {
        panic!("Expected $rect_out to be Array");
    }

    // all_pixels.len == 65536
    let all_val = vm.globals.get("$all_pixels").unwrap();
    if let RValue::Array(ref ary) = all_val.value {
        assert_eq!(ary.borrow().len(), 256 * 256);
    } else {
        panic!("Expected $all_pixels to be Array");
    }
}


#[test]
fn test_exception_stacktrace_reporting() {
    let script = r#"
def helper_func
  raise "sample custom error"
end

def update
  helper_func
end
"#;
    let (tail, mrb) = cli::compile_ruby_script_str_with_filename(script, Some("my_game.rb")).unwrap();
    let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();
    let res = runtime.call_update_result();
    assert!(res.is_err());
    let err = res.unwrap_err();

    assert_eq!(err.title, "RuntimeError: sample custom error");
    assert!(err.backtrace.iter().any(|f| f.contains("my_game.rb:3") && f.contains("helper_func")));
    assert!(err.backtrace.iter().any(|f| f.contains("my_game.rb:7") && f.contains("update")));
    assert!(err.full_message.contains("[Ruby Exception in `update`] RuntimeError: sample custom error"));
    assert!(err.full_message.contains("my_game.rb:3:in helper_func"));
    assert!(err.full_message.contains("my_game.rb:7:in update"));
}

#[test]
fn test_syntax_error_message_with_line_and_col() {
    let script = "def foo
";
    let res = cli::compile_ruby_script_str_with_filename(script, Some("broken.rb"));
    assert!(res.is_err());
    let err = res.unwrap_err();
    assert!(err.contains("broken.rb:1:8: syntax error"));
}

#[test]
fn test_error_recovery_and_restart() {
    // 1. 最初は例外が発生するスクリプト
    let bug_script = r#"
def update
  undefined_variable_or_method
end
"#;
    let (tail1, mrb1) = cli::compile_ruby_script_str_with_filename(bug_script, Some("game.rb")).unwrap();
    let mut runtime = GameRuntime::new(&tail1, &mrb1, true).unwrap();
    let res1 = runtime.call_update_result();
    assert!(res1.is_err());
    let err1 = res1.unwrap_err();
    assert!(err1.full_message.contains("game.rb"));

    // 2. 修正したスクリプトで再スタート（新規 GameRuntime の初期化）
    let fixed_script = r#"
$count = 0
def update
  $count += 1
end
"#;
    let (tail2, mrb2) = cli::compile_ruby_script_str_with_filename(fixed_script, Some("game.rb")).unwrap();
    let mut restarted_runtime = GameRuntime::new(&tail2, &mrb2, true).expect("Restart should succeed");
    let res2 = restarted_runtime.call_update_result();
    assert!(res2.is_ok());

    let count_val = restarted_runtime.vm.globals.get("$count").unwrap();
    assert!(matches!(count_val.value, RValue::Integer(1)));
}

#[test]
fn test_script_error_overlay_non_blocking_behavior() {
    // 実行時に例外が発生しても GameRuntime がパニックせず、エラー情報を保持して後続フレームを実行できる
    let script = r#"
$frame = 0

def update
  $frame += 1
  undefined_variable_or_method
end
"#;
    let (tail, mrb) = cli::compile_ruby_script_str_with_filename(script, Some("nomethod.rb")).unwrap();
    let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();

    // 1フレーム目: NoMethodError でエラーが返る
    let err1 = runtime.call_update_result().unwrap_err();
    assert!(err1.full_message.contains("nomethod.rb") || err1.title.contains("undefined"));

    // ゲームは強制終了せず、ランタイムは生きておりグローバル変数も更新されている
    let f1 = runtime.vm.globals.get("$frame").unwrap();
    assert!(matches!(f1.value, RValue::Integer(1)));

    // 2. ホットリロードでバグを修正したスクリプトを適用
    let fixed_script = r#"
def update
  $frame += 1
end
"#;
    let (tail_v2, mrb_v2) = cli::compile_ruby_script_str_with_filename(fixed_script, Some("nomethod.rb")).unwrap();
    runtime.hot_reload(&tail_v2, &mrb_v2).expect("Hot reload should succeed");

    // 2フレーム目: 状態（$frame = 1）を維持したまま正常に復旧して完了
    let res2 = runtime.call_update_result();
    assert!(res2.is_ok());

    let f2 = runtime.vm.globals.get("$frame").unwrap();
    assert!(matches!(f2.value, RValue::Integer(2)));
}

#[test]
fn test_game_restart_resets_globals_and_state() {
    let script = r#"
$score = 100
$x = 10

def update
  $score += 50
  $x += 20
end

def draw
end
"#;
    let (tail, mrb) = cli::compile_ruby_script_str(script).unwrap();
    let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();

    // 初期状態の確認
    let s0: i32 = runtime.vm.globals.get("$score").unwrap().as_ref().try_into().unwrap();
    let x0: i32 = runtime.vm.globals.get("$x").unwrap().as_ref().try_into().unwrap();
    assert_eq!(s0, 100);
    assert_eq!(x0, 10);

    // 1フレーム実行
    runtime.call_update();
    let s1: i32 = runtime.vm.globals.get("$score").unwrap().as_ref().try_into().unwrap();
    let x1: i32 = runtime.vm.globals.get("$x").unwrap().as_ref().try_into().unwrap();
    assert_eq!(s1, 150);
    assert_eq!(x1, 30);

    // ホットリロード時は状態が継続される（普段の動作）
    runtime.hot_reload(&tail, &mrb).expect("Hot reload should succeed");
    let s_reloaded: i32 = runtime.vm.globals.get("$score").unwrap().as_ref().try_into().unwrap();
    let x_reloaded: i32 = runtime.vm.globals.get("$x").unwrap().as_ref().try_into().unwrap();
    assert_eq!(s_reloaded, 150);
    assert_eq!(x_reloaded, 30);

    // リスタート時は先頭からやり直される（初期値にリセットされる）
    runtime.restart(&tail, &mrb).expect("Restart should succeed");
    let s_restarted: i32 = runtime.vm.globals.get("$score").unwrap().as_ref().try_into().unwrap();
    let x_restarted: i32 = runtime.vm.globals.get("$x").unwrap().as_ref().try_into().unwrap();
    assert_eq!(s_restarted, 100);
    assert_eq!(x_restarted, 10);
}

#[test]
fn test_ruby_restart_api() {
    let script = r#"
def update
  restart
end

def draw
end
"#;
    let (tail, mrb) = cli::compile_ruby_script_str(script).unwrap();
    let mut runtime = GameRuntime::new(&tail, &mrb, true).unwrap();

    assert!(!runtime.is_restart_requested());

    // update 内で restart を呼び出す
    runtime.call_update();
    assert!(runtime.is_restart_requested());

    runtime.reset_restart_request();
    assert!(!runtime.is_restart_requested());

    // reset エイリアスのテスト
    let script_reset = r#"
def update
  reset
end

def draw
end
"#;
    let (tail2, mrb2) = cli::compile_ruby_script_str(script_reset).unwrap();
    let mut runtime2 = GameRuntime::new(&tail2, &mrb2, true).unwrap();
    assert!(!runtime2.is_restart_requested());
    runtime2.call_update();
    assert!(runtime2.is_restart_requested());
}

#[test]
fn test_tiny_dungeon_example_script() {
    let script = std::path::Path::new("examples/tiny_dungeon.rb");
    assert!(script.exists());

    let (_full_src, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(script).expect("tiny_dungeon.rb should compile");

    let mut runtime =
        GameRuntime::new(&tail_data, &mrb_bytes, true).expect("tiny_dungeon.rb should initialize");

    // @SHEET から 0〜131 の全132タイルがロードされていること
    assert!(
        runtime.sprites.borrow().len() >= 132,
        "Should load at least 132 sprites from @SHEET"
    );
    for id in 0..132 {
        assert!(
            runtime.sprites.borrow().contains_key(&id),
            "Sprite {} should be loaded",
            id
        );
    }

    // 複数フレーム実行 (update と draw)
    for _ in 0..15 {
        runtime
            .call_update_result()
            .expect("tiny_dungeon update should succeed");
        runtime
            .call_draw_result()
            .expect("tiny_dungeon draw should succeed");
    }

    // can_walk? の呼び出しテスト (移動判定が正常に動作し、例外が出ないこと)
    let can_walk = mrb_funcall(
        &mut runtime.vm,
        None,
        "can_walk?",
        &[Rc::new(RObject::integer(64)), Rc::new(RObject::integer(64))],
    )
    .expect("can_walk? should succeed");
    assert_eq!(can_walk.as_ref(), &RObject::boolean(true));

    // 画面端スクロールのテスト (プレイヤーが右下へ移動するとカメラがスクロールすること)
    runtime.vm.globals.insert("$px".to_string(), Rc::new(RObject::integer(300)));
    runtime.vm.globals.insert("$py".to_string(), Rc::new(RObject::integer(300)));
    runtime.call_update_result().expect("update should succeed");
    runtime.call_draw_result().expect("draw should succeed");

    let cam_x: i32 = runtime.vm.globals.get("$cam_x").unwrap().as_ref().try_into().unwrap();
    let cam_y: i32 = runtime.vm.globals.get("$cam_y").unwrap().as_ref().try_into().unwrap();
    assert!(cam_x > 0, "cam_x should scroll when player moves right");
    assert!(cam_y > 0, "cam_y should scroll when player moves down");
}

#[test]
fn test_png_backed_resource_read_only_in_sprite_editor() {
    // 外部 PNG 参照リソースの判定テスト
    assert!(check_resource_read_only("examples/tiny_dungeon.spr"));
    assert!(check_resource_read_only("examples/tiny_dungeon.rb"));
    assert!(check_resource_read_only("examples/tiny_dungeon.png"));
    assert!(!check_resource_read_only("game.rb"));

    // スプライトエディタで tiny_dungeon.rb を開いて正常に読み込み専用として起動・描画できること
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/sprite_editor.rb"))
            .expect("examples/sprite_editor.rb should compile");

    let mut runtime =
        GameRuntime::new_with_args(&tail_data, &mrb_bytes, true, &["examples/tiny_dungeon.rb".to_string()])
            .expect("Sprite editor should initialize with tiny_dungeon.rb");

    for _ in 0..10 {
        runtime.call_update_result().expect("call_update should succeed");
        runtime.call_draw_result().expect("call_draw should succeed");
    }

    // $is_read_only グローバル変数が true であること
    let is_ro = runtime.vm.globals.get("$is_read_only");
    assert_eq!(is_ro.map(|v| v.as_ref().clone()), Some(RObject::boolean(true)));
}



#[test]
fn test_256_palette_emojis_available() {
    let (_, tail_data, mrb_bytes) =
        cli::compile_ruby_script_file(std::path::Path::new("examples/tilemap_editor.rb"))
            .expect("tilemap_editor.rb should compile");

    let runtime =
        GameRuntime::new_with_args(&tail_data, &mrb_bytes, true, &[])
            .expect("Tilemap editor should initialize");

    // デフォルトタブが :chip であること
    let tab = runtime.vm.globals.get("$obj_palette_tab").expect("$obj_palette_tab must exist");
    assert_eq!(tab.as_ref(), &RObject::symbol("chip".into()));

    // EMOJI_PALETTE 定数が存在し、要素数が256個であること
    let emoji_palette = runtime.vm.consts.get("EMOJI_PALETTE").expect("EMOJI_PALETTE must exist");
    if let RValue::Array(ref arr) = emoji_palette.value {
        let emojis = arr.borrow();
        assert_eq!(emojis.len(), 256, "EMOJI_PALETTE must have exactly 256 emojis");

        for (i, emoji_obj) in emojis.iter().enumerate() {
            let s: String = emoji_obj.as_ref().try_into().expect("emoji must be a string");
            let cp = crate::emoji::resolve_emoji_codepoint(&s);
            assert!(
                cp.is_some(),
                "Emoji at index {} '{}' could not be resolved in EMOJI_ATLAS / EMOJI_CODEPOINTS",
                i,
                s
            );
        }
    } else {
        panic!("EMOJI_PALETTE must be an Array");
    }
}
