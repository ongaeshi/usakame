use std::env;
use std::fs;
use std::io::Write;
use std::path::Path;

use flate2::Compression;
use flate2::write::ZlibEncoder;

fn main() {
    println!("cargo:rerun-if-changed=game.rb");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=examples");
    println!("cargo:rerun-if-changed=docs");
    println!("cargo:rerun-if-changed=AGENTS.md");

    let out_dir = env::var("OUT_DIR").expect("OUT_DIR not set");
    let dest_path = Path::new(&out_dir).join("game.mrb");

    let full_source = fs::read_to_string("game.rb").expect("Failed to read game.rb");
    #[path = "src/bundle.rs"]
    mod bundle;

    let (ruby_code, _) = bundle::split_ruby_source_and_tail(&full_source);
    let normalized = bundle::normalize_ruby_config_syntax(ruby_code);

    unsafe {
        let mut compiler = mruby_compiler2_sys::MRubyCompiler2Context::new();
        compiler
            .compile_to_file(&normalized, &dest_path)
            .expect("Failed to compile game.rb to bytecode in build.rs");
    }

    build_examples_archive(Path::new("examples"), &Path::new(&out_dir).join("examples_archive.bin"));
}

fn is_valid_example_entry(name: &str) -> bool {
    // 隠しファイル、バックアップ、一時ファイル、システムファイルを除外
    if name.starts_with('.')
        || name.ends_with('~')
        || name.ends_with(".bak")
        || name.ends_with(".tmp")
        || name.eq_ignore_ascii_case("Thumbs.db")
        || name.eq_ignore_ascii_case(".DS_Store")
    {
        return false;
    }
    // 配布・参照に必要なファイル拡張子のみを厳選同梱
    let valid_exts = [".rb", ".spr", ".map", ".sfx", ".png", ".wav", ".ogg", ".md"];
    valid_exts.iter().any(|ext| name.ends_with(ext))
}

fn build_examples_archive(examples_dir: &Path, archive_out_path: &Path) {
    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
    if let Ok(read_dir) = fs::read_dir(examples_dir) {
        for entry in read_dir.flatten() {
            let path = entry.path();
            if path.is_file() {
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    if is_valid_example_entry(name) {
                        println!("cargo:rerun-if-changed=examples/{}", name);
                        if let Ok(bytes) = fs::read(&path) {
                            entries.push((name.to_string(), bytes));
                        }
                    }
                }
            }
        }
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));

    let mut raw_buf = Vec::new();
    raw_buf.extend_from_slice(&(entries.len() as u32).to_le_bytes());
    for (name, data) in &entries {
        let name_bytes = name.as_bytes();
        raw_buf.extend_from_slice(&(name_bytes.len() as u32).to_le_bytes());
        raw_buf.extend_from_slice(name_bytes);
        raw_buf.extend_from_slice(&(data.len() as u32).to_le_bytes());
        raw_buf.extend_from_slice(data);
    }

    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::best());
    encoder
        .write_all(&raw_buf)
        .expect("Failed to compress examples archive");
    let compressed = encoder
        .finish()
        .expect("Failed to finish compressing examples archive");
    fs::write(archive_out_path, compressed).expect("Failed to write examples_archive.bin");
}

