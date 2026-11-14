use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use flate2::Compression;
use flate2::write::ZlibEncoder;

fn main() {
    println!("cargo:rerun-if-changed=game.rb");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=examples");
    println!("cargo:rerun-if-changed=docs");
    println!("cargo:rerun-if-changed=AGENTS.md");

    setup_git_version();

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
    build_skills_archive(
        Path::new(".agents").join("skills").as_path(),
        &Path::new(&out_dir).join("skills_archive.bin"),
    );
}

fn is_ignored_bundle_entry(name: &str) -> bool {
    name.starts_with('.')
        || name.ends_with('~')
        || name.ends_with(".bak")
        || name.ends_with(".tmp")
        || name.eq_ignore_ascii_case("Thumbs.db")
        || name.eq_ignore_ascii_case(".DS_Store")
}

fn is_valid_example_entry(name: &str) -> bool {
    // 隠しファイル、バックアップ、一時ファイル、システムファイルを除外
    if is_ignored_bundle_entry(name) {
        return false;
    }
    // 配布・参照に必要なファイル拡張子のみを厳選同梱
    let valid_exts = [".rb", ".spr", ".map", ".sfx", ".png", ".wav", ".ogg", ".md"];
    valid_exts.iter().any(|ext| name.ends_with(ext))
}

fn write_compressed_archive(mut entries: Vec<(String, Vec<u8>)>, archive_out_path: &Path) {
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
        .expect("Failed to compress archive");
    let compressed = encoder
        .finish()
        .expect("Failed to finish compressing archive");
    fs::write(archive_out_path, compressed).expect("Failed to write archive");
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
    write_compressed_archive(entries, archive_out_path);
}

fn collect_skill_files_recursive(
    base_dir: &Path,
    current_dir: &Path,
    rel_prefix: &str,
    entries: &mut Vec<(String, Vec<u8>)>,
) {
    let read_dir = fs::read_dir(current_dir)
        .unwrap_or_else(|e| panic!("Failed to read skill directory `{}`: {}", current_dir.display(), e));
    for entry in read_dir.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if is_ignored_bundle_entry(name) {
            continue;
        }
        let rel_path = format!("{}/{}", rel_prefix, name);
        if path.is_dir() {
            collect_skill_files_recursive(base_dir, &path, &rel_path, entries);
        } else if path.is_file() {
            println!("cargo:rerun-if-changed={}", path.display());
            let bytes = fs::read(&path)
                .unwrap_or_else(|e| panic!("Failed to read skill file `{}`: {}", path.display(), e));
            entries.push((rel_path, bytes));
        }
    }
}

/// `.agents/skills/PROJECT_SKILLS` に明示記載されたスキルのみをアーカイブに同梱する。
fn build_skills_archive(skills_dir: &Path, archive_out_path: &Path) {
    let manifest_path = skills_dir.join("PROJECT_SKILLS");
    println!("cargo:rerun-if-changed={}", manifest_path.display());

    let manifest = fs::read_to_string(&manifest_path).unwrap_or_else(|e| {
        panic!(
            "Failed to read `{}`: {}",
            manifest_path.display(),
            e
        )
    });

    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for (idx, raw_line) in manifest.lines().enumerate() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.contains('/') || line.contains('\\') || line.contains("..") {
            panic!(
                "Invalid skill name `{}` at `{}:{}`",
                line,
                manifest_path.display(),
                idx + 1
            );
        }
        if !seen.insert(line.to_string()) {
            continue;
        }

        let skill_dir = skills_dir.join(line);
        if !skill_dir.is_dir() {
            panic!(
                "Skill `{}` listed in `{}` does not exist as a directory: `{}`",
                line,
                manifest_path.display(),
                skill_dir.display()
            );
        }
        let skill_md = skill_dir.join("SKILL.md");
        if !skill_md.is_file() {
            panic!(
                "Skill `{}` listed in `{}` is missing SKILL.md: `{}`",
                line,
                manifest_path.display(),
                skill_md.display()
            );
        }
        println!("cargo:rerun-if-changed={}", skill_dir.display());
        collect_skill_files_recursive(&skill_dir, &skill_dir, line, &mut entries);
    }

    write_compressed_archive(entries, archive_out_path);
}

fn setup_git_version() {
    let commit_hash = env::var("UK_COMMIT_HASH").ok().or_else(|| {
        let output = std::process::Command::new("git")
            .args(["rev-parse", "--short", "HEAD"])
            .output()
            .ok()?;
        if output.status.success() {
            let s = String::from_utf8(output.stdout).ok()?.trim().to_string();
            if !s.is_empty() {
                return Some(s);
            }
        }
        None
    });

    let commit_date = env::var("UK_COMMIT_DATE").ok().or_else(|| {
        let output = std::process::Command::new("git")
            .args(["log", "-1", "--date=short", "--format=%cd"])
            .output()
            .ok()?;
        if output.status.success() {
            let s = String::from_utf8(output.stdout).ok()?.trim().to_string();
            if !s.is_empty() {
                return Some(s);
            }
        }
        None
    });

    if let Some(hash) = commit_hash {
        println!("cargo:rustc-env=UK_COMMIT_HASH={}", hash);
    }
    if let Some(date) = commit_date {
        println!("cargo:rustc-env=UK_COMMIT_DATE={}", date);
    }

    // git の HEAD や参照の更新を検知して再ビルド
    let git_dir_path = std::process::Command::new("git")
        .args(["rev-parse", "--git-dir"])
        .output()
        .ok()
        .and_then(|output| {
            if output.status.success() {
                String::from_utf8(output.stdout).ok().map(|s| s.trim().to_string())
            } else {
                None
            }
        })
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(".git"));

    if git_dir_path.exists() {
        let head_path = git_dir_path.join("HEAD");
        if head_path.exists() {
            println!("cargo:rerun-if-changed={}", head_path.display());
            if let Ok(head_content) = fs::read_to_string(&head_path) {
                if let Some(ref_path) = head_content.strip_prefix("ref: ") {
                    let ref_path = ref_path.trim();
                    let target_ref = git_dir_path.join(ref_path);
                    if target_ref.exists() {
                        println!("cargo:rerun-if-changed={}", target_ref.display());
                    }
                }
            }
        }
        let packed_refs = git_dir_path.join("packed-refs");
        if packed_refs.exists() {
            println!("cargo:rerun-if-changed={}", packed_refs.display());
        }
    }
}


