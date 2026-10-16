extern crate mruby_compiler2_sys;
use mruby_compiler2_sys::MRubyCompiler2Context;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    unsafe {
        let mut cxt = MRubyCompiler2Context::new();
        cxt.compile_to_c_function(
            "puts \"Hello, mruby-compiler2!\"",
            "init_test_func",
            std::path::Path::new("examples/out.c"),
        )?;
    }
    println!("Created examples/out.c");
    Ok(())
}