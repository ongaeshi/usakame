use std::env;
use std::fs;
use std::path::Path;

fn main() {
    println!("cargo:rerun-if-changed=game.rb");
    println!("cargo:rerun-if-changed=build.rs");

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
}
