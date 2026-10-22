extern crate cc;
use glob::glob;

fn main() {
    let out_dir = std::env::var("OUT_DIR").unwrap();

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=vendor");
    println!("cargo:rustc-link-search={}", out_dir);

    let mut build = cc::Build::new();
    build
        .files(
            glob("./vendor/mruby-compiler2/src/**/*.c")
                .expect("cannot find c source")
                .map(|x| x.unwrap()),
        )
        .files(
            glob("./vendor/mruby-compiler2/lib/prism/src/**/*.c")
                .expect("cannot find c source")
                .map(|x| x.unwrap()),
        )
        .warnings(false)
        .define("MRB_NO_PRESYM", "")
        .define("MRB_INT64", "1")
        .define("PRISM_XALLOCATOR", "")
        .define("PRISM_BUILD_MINIMAL", "")
        .define("PICORB_VM_MRUBYC", "")
        .define("MRBC_ALLOC_LIBC", "")
        .include("./vendor/include")
        .include("./vendor/mruby-compiler2/include")
        .include("./vendor/mruby-compiler2/lib/prism/include");

    if !cfg!(target_env = "msvc") {
        build.flag_if_supported("-fPIC");
    }

    build.compile("mrubycompiler2");
    println!("cargo:rustc-link-lib=mrubycompiler2");
}
