use std::env;
use std::fs;
use std::path::Path;

fn main() {
    println!("cargo:rerun-if-changed=game.rb");
    println!("cargo:rerun-if-changed=build.rs");

    let out_dir = env::var("OUT_DIR").expect("OUT_DIR not set");
    let dest_path = Path::new(&out_dir).join("game.mrb");

    let full_source = fs::read_to_string("game.rb").expect("Failed to read game.rb");
    let mut ruby_code = full_source.as_str();
    let mut byte_offset = 0;
    for line in full_source.split_inclusive('\n') {
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed == "__END__"
            || (trimmed.starts_with("__END__")
                && trimmed[7..].chars().all(|c| c.is_whitespace() || c == '#'))
        {
            ruby_code = &full_source[..byte_offset];
            break;
        }
        byte_offset += line.len();
    }

    unsafe {
        let mut compiler = mruby_compiler2_sys::MRubyCompiler2Context::new();
        compiler
            .compile_to_file(ruby_code, &dest_path)
            .expect("Failed to compile game.rb to bytecode in build.rs");
    }
}
