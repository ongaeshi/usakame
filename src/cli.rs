use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::bundle::{pack_bundle, read_bundle_from_current_exe, strip_bundle_from_exe_bytes};

const WEB_INDEX_HTML: &str = include_str!("../web/index.html");
const WEB_MQ_JS_BUNDLE: &str = include_str!("../web/mq_js_bundle.js");

pub const EMBEDDED_SPRITE_EDITOR: &str = include_str!("../examples/sprite_editor.rb");
pub const EMBEDDED_TILEMAP_EDITOR: &str = include_str!("../examples/tilemap_editor.rb");
pub const EMBEDDED_API_MD: &str = include_str!("../docs/api.md");
pub const EMBEDDED_MRUBYEDGE_API_MD: &str = include_str!("../docs/mrubyedge_api.md");
pub const EMBEDDED_EXAMPLES_ARCHIVE: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/examples_archive.bin"));

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditorKind {
    Sprite,
    Tilemap,
    All,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewProjectOptions {
    pub project_dir: PathBuf,
    pub minimal: bool,
    pub split: bool,
    pub with_refs: bool,
    pub template: String,
    pub prompt: Option<String>,
    pub model: Option<String>,
    pub api_key: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliAction {
    /// `uk new <dir> [--minimal] [--split] [--with-refs] [-t <template>] [-p <prompt>]` (新規プロジェクト作成)
    New(NewProjectOptions),
    /// `uk generate <prompt> [-o <script.rb>] [--model <model>] [--api-key <key>]` (LLMによるスクリプト生成)
    Generate {
        prompt: String,
        output_path: PathBuf,
        model: Option<String>,
        api_key: Option<String>,
    },
    /// `uk examples [dest_dir]` (同梱サンプルコード群の展開)
    Examples { dest_dir: PathBuf },
    /// `uk edit [spr|map|all] [script.rb]` (内蔵スプライト/タイルマップエディタ起動)
    Edit {
        kind: EditorKind,
        target_path: PathBuf,
    },
    /// `uk run <script.rb> [args...]` (ホットリロード付きネイティブ実行)
    Run {
        script_path: PathBuf,
        script_args: Vec<String>,
        screenshot_path: Option<PathBuf>,
        screenshot_frames: u32,
    },
    /// `uk run_with_edit [script.rb]` / `uk run --edit [script.rb]` (ゲームとエディタを同時起動)
    RunWithEdit {
        script_path: PathBuf,
        script_args: Vec<String>,
        editor_kind: EditorKind,
    },
    /// 単一バイナリ（末尾にバンドル埋め込み済み）の直接起動、または埋め込みデモ起動
    RunEmbedded {
        tail_data: String,
        mrb_bytes: Vec<u8>,
        title: String,
    },
    /// `uk build <script.rb> [-o <output>]` (シングルバイナリ生成)
    Build {
        script_path: PathBuf,
        output_path: Option<PathBuf>,
    },
    /// `uk browser <script.rb> [-p <port>] [--no-open]` (ブラウザ実行)
    Browser {
        script_path: PathBuf,
        port: Option<u16>,
        open_browser: bool,
    },
    /// `uk encode <image.png> [--id <start_id>] [--tile <WxH>]` (PNGをBase64スプライト記法に変換)
    Encode {
        image_path: PathBuf,
        start_id: i32,
        tile_size: Option<(u16, u16)>,
    },
    /// `uk pack [script.rb] [-o <output>]` (外部リソースを __END__ に集約して単一 .rb に結合)
    Pack {
        script_path: PathBuf,
        output_path: Option<PathBuf>,
    },
    /// `uk unpack [script.rb]` (`__END__` から外部リソース .spr, .map, .sfx を抽出)
    Unpack { script_path: PathBuf },
    /// `uk check [script.rb] [--frames <N>] [--gacha]` (ヘッドレス構文・実行検証)
    Check {
        script_path: PathBuf,
        frames: u32,
        gacha: bool,
    },
    /// ヘルプ表示
    Help,
    /// バージョン表示
    Version,
}

pub fn print_help() {
    println!(
        "\
uk - Usakame Retro Game Engine CLI

USAGE:
    uk new <dir> [options]              Create a new Usakame game project
        --minimal                       Generate minimal files only (skip AGENTS.md & docs/)
        --split                         Separate resources into game.spr, game.map, game.sfx
        --with-refs                     Extract sample games into refs/examples/ for AI/reference
        -t, --template <name>           Template: default, minimal, split, platformer, shooter, puzzle, card, runner, rpg, survivors, dungeon
        -p, --prompt <text>             Generate initial game.rb from prompt via LLM API (with auto self-check)
        -m, --model <name>              LLM model name (default: gemini-2.5-flash)
        --api-key <key>                 LLM API key (or set GEMINI_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY)
    uk init [dir] [options]             Initialize Usakame project in current or specified directory
    uk generate <prompt> [-o <file>]    Generate or overwrite script from prompt via LLM API
    uk run [script.rb] [options]        Run script natively with live hot-reload (default: game.rb)
        -e, --edit[=spr|map|all]        Launch editor(s) alongside the running game
        -s, --screenshot <out.png>      Auto-save screenshot and exit
        --frames <N>                    Frame count before auto-screenshot (default: 10)
    uk run_with_edit [script.rb]        Run game and editors simultaneously with live sync
    uk edit [spr|map|all] [script.rb]   Launch built-in Sprite / Tilemap Editor (default: spr)
    uk examples [dest_dir]              Extract bundled example scripts (default: ./examples)
    uk check [script.rb] [options]      Headless syntax and runtime verification (default: game.rb)
        -f, --frames <N>                Simulated frame count to verify (default: 60)
        -g, --gacha, --mash             Enable random button mashing (d-pad & action keys)
    uk build [script.rb] [-o <output>]  Build a standalone single binary from script
    uk browser [script.rb] [-p <port>]  Run script in the browser with live hot-reload
    uk pack [script.rb] [-o <output>]   Pack external resources into single standalone script
    uk unpack [script.rb]               Unpack resources from script into .spr, .map, .sfx files
    uk encode <file> [--id <id>]        Encode PNG image/sheet or WAV/OGG audio into Base64 for script
    uk --help, -h                       Show this help message
    uk --version, -V                    Show version information"
    );
}

pub fn print_version() {
    println!("uk {}", env!("CARGO_PKG_VERSION"));
}

/// コマンドライン引数および自身のバイナリ末尾バンドル状態から実行アクションを決定する。
pub fn parse_cli_args<I>(args: I) -> Result<CliAction, String>
where
    I: IntoIterator<Item = String>,
{
    let args_vec: Vec<String> = args.into_iter().collect();
    let rest = if args_vec.len() > 1 {
        &args_vec[1..]
    } else {
        &[]
    };

    // 引数なしで起動された場合、まず自身にバンドルが結合されているか（`uk build` 生成バイナリか）を確認
    if rest.is_empty() {
        if let Some((tail_data, mrb_bytes)) = read_bundle_from_current_exe() {
            let exe_title = std::env::current_exe()
                .ok()
                .and_then(|p| p.file_stem().map(|s| s.to_string_lossy().into_owned()))
                .unwrap_or_else(|| "Usakame Game".to_string());
            return Ok(CliAction::RunEmbedded {
                tail_data,
                mrb_bytes,
                title: exe_title,
            });
        }

        let default_script = PathBuf::from("game.rb");
        if default_script.exists() {
            return Ok(CliAction::Run {
                script_path: default_script,
                script_args: Vec::new(),
                screenshot_path: None,
                screenshot_frames: 10,
            });
        }

        return Ok(CliAction::Help);
    }

    match rest[0].as_str() {
        "help" | "--help" | "-h" => Ok(CliAction::Help),
        "version" | "--version" | "-V" => Ok(CliAction::Version),
        "new" => parse_new_args(&rest[1..], false),
        "init" => parse_new_args(&rest[1..], true),
        "generate" | "gen" => parse_generate_args(&rest[1..]),
        "examples" | "copy_examples" => {
            let dest_dir = rest
                .get(1)
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("examples"));
            Ok(CliAction::Examples { dest_dir })
        }
        "edit" => parse_edit_args(&rest[1..], EditorKind::Sprite),
        "spr" => parse_edit_args(&rest[1..], EditorKind::Sprite),
        "map" => parse_edit_args(&rest[1..], EditorKind::Tilemap),
        "run_with_edit" => parse_run_with_edit_args(&rest[1..]),
        "run" => parse_run_args(&rest[1..]),
        "check" => parse_check_args(&rest[1..]),
        "build" => {
            let mut script_path: Option<PathBuf> = None;
            let mut output_path: Option<PathBuf> = None;
            let mut i = 1;
            while i < rest.len() {
                match rest[i].as_str() {
                    "-o" | "--output" => {
                        i += 1;
                        let out = rest
                            .get(i)
                            .ok_or_else(|| "Missing argument for -o / --output".to_string())?;
                        output_path = Some(PathBuf::from(out));
                    }
                    arg if arg.starts_with('-') => {
                        return Err(format!("Unknown option for `uk build`: {}", arg));
                    }
                    arg => {
                        if script_path.is_none() {
                            script_path = Some(PathBuf::from(arg));
                        } else {
                            return Err(format!("Unexpected extra argument: {}", arg));
                        }
                    }
                }
                i += 1;
            }
            Ok(CliAction::Build {
                script_path: script_path.unwrap_or_else(|| PathBuf::from("game.rb")),
                output_path,
            })
        }
        "browser" => {
            let mut script_path: Option<PathBuf> = None;
            let mut port: Option<u16> = None;
            let mut open_browser = true;
            let mut i = 1;
            while i < rest.len() {
                match rest[i].as_str() {
                    "-p" | "--port" => {
                        i += 1;
                        let p_str = rest
                            .get(i)
                            .ok_or_else(|| "Missing argument for -p / --port".to_string())?;
                        let p = p_str
                            .parse::<u16>()
                            .map_err(|_| format!("Invalid port number: {}", p_str))?;
                        port = Some(p);
                    }
                    "--no-open" => {
                        open_browser = false;
                    }
                    arg if arg.starts_with('-') => {
                        return Err(format!("Unknown option for `uk browser`: {}", arg));
                    }
                    arg => {
                        if script_path.is_none() {
                            script_path = Some(PathBuf::from(arg));
                        } else {
                            return Err(format!("Unexpected extra argument: {}", arg));
                        }
                    }
                }
                i += 1;
            }
            Ok(CliAction::Browser {
                script_path: script_path.unwrap_or_else(|| PathBuf::from("game.rb")),
                port,
                open_browser,
            })
        }
        "encode" | "import" => {
            let mut image_path: Option<PathBuf> = None;
            let mut start_id: i32 = 0;
            let mut tile_size: Option<(u16, u16)> = None;
            let mut i = 1;
            while i < rest.len() {
                match rest[i].as_str() {
                    "--id" | "-i" => {
                        i += 1;
                        let id_str = rest
                            .get(i)
                            .ok_or_else(|| "Missing argument for --id".to_string())?;
                        start_id = id_str
                            .parse::<i32>()
                            .map_err(|_| format!("Invalid sprite ID: {}", id_str))?;
                    }
                    "--tile" | "-t" => {
                        i += 1;
                        let t_str = rest
                            .get(i)
                            .ok_or_else(|| "Missing argument for --tile".to_string())?;
                        let lower = t_str.to_ascii_lowercase();
                        let (w_s, h_s) = lower
                            .split_once('x')
                            .ok_or_else(|| format!("Invalid tile size `{}` (expected WxH, e.g. 16x16)", t_str))?;
                        let tw = w_s
                            .parse::<u16>()
                            .map_err(|_| format!("Invalid tile width in `{}`", t_str))?;
                        let th = h_s
                            .parse::<u16>()
                            .map_err(|_| format!("Invalid tile height in `{}`", t_str))?;
                        tile_size = Some((tw, th));
                    }
                    arg if arg.starts_with('-') => {
                        return Err(format!("Unknown option for `uk encode`: {}", arg));
                    }
                    arg => {
                        if image_path.is_none() {
                            image_path = Some(PathBuf::from(arg));
                        } else {
                            return Err(format!("Unexpected extra argument: {}", arg));
                        }
                    }
                }
                i += 1;
            }
            let image_path = image_path
                .ok_or_else(|| "Missing PNG file path. Usage: `uk encode <image.png> [--id 0]`".to_string())?;
            Ok(CliAction::Encode {
                image_path,
                start_id,
                tile_size,
            })
        }
        "pack" => {
            let mut script_path: Option<PathBuf> = None;
            let mut output_path: Option<PathBuf> = None;
            let mut i = 1;
            while i < rest.len() {
                match rest[i].as_str() {
                    "-o" | "--output" => {
                        i += 1;
                        let out = rest
                            .get(i)
                            .ok_or_else(|| "Missing argument for -o / --output".to_string())?;
                        output_path = Some(PathBuf::from(out));
                    }
                    arg if arg.starts_with('-') => {
                        return Err(format!("Unknown option for `uk pack`: {}", arg));
                    }
                    arg => {
                        if script_path.is_none() {
                            script_path = Some(PathBuf::from(arg));
                        } else {
                            return Err(format!("Unexpected extra argument: {}", arg));
                        }
                    }
                }
                i += 1;
            }
            Ok(CliAction::Pack {
                script_path: script_path.unwrap_or_else(|| PathBuf::from("game.rb")),
                output_path,
            })
        }
        "unpack" => {
            let script_path = rest
                .get(1)
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("game.rb"));
            Ok(CliAction::Unpack { script_path })
        }
        other => {
            // `uk game.rb` のように直接 .rb ファイルが渡された場合も `uk run` として扱う
            let candidate = PathBuf::from(other);
            if other.ends_with(".rb") || candidate.exists() {
                parse_run_args(rest)
            } else {
                Err(format!(
                    "Unknown command `{}`. Run `uk --help` for usage.",
                    other
                ))
            }
        }
    }
}

fn parse_new_args(args: &[String], is_init: bool) -> Result<CliAction, String> {
    let mut project_dir: Option<PathBuf> = None;
    let mut minimal = false;
    let mut split = false;
    let mut with_refs = false;
    let mut template = "default".to_string();
    let mut prompt: Option<String> = None;
    let mut model: Option<String> = None;
    let mut api_key: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--minimal" | "--no-ai" => {
                minimal = true;
            }
            "--split" => {
                split = true;
            }
            "--with-refs" | "--refs" => {
                with_refs = true;
            }
            "-t" | "--template" => {
                i += 1;
                let t = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for -t / --template".to_string())?;
                template = t.to_string();
                if template == "split" {
                    split = true;
                }
            }
            "-p" | "--prompt" => {
                i += 1;
                let p = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for -p / --prompt".to_string())?;
                prompt = Some(p.to_string());
            }
            "-m" | "--model" => {
                i += 1;
                let m = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for -m / --model".to_string())?;
                model = Some(m.to_string());
            }
            "--api-key" => {
                i += 1;
                let k = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for --api-key".to_string())?;
                api_key = Some(k.to_string());
            }
            arg if arg.starts_with('-') => {
                return Err(format!("Unknown option for `uk new`: {}", arg));
            }
            arg => {
                if project_dir.is_none() {
                    project_dir = Some(PathBuf::from(arg));
                } else {
                    return Err(format!("Unexpected extra argument for `uk new`: {}", arg));
                }
            }
        }
        i += 1;
    }

    let project_dir = match project_dir {
        Some(d) => d,
        None if is_init => PathBuf::from("."),
        None => {
            return Err(
                "Missing project directory. Usage: `uk new <project_dir> [--minimal] [--split] [--with-refs] [-p <prompt>]`"
                    .to_string(),
            );
        }
    };

    Ok(CliAction::New(NewProjectOptions {
        project_dir,
        minimal,
        split,
        with_refs,
        template,
        prompt,
        model,
        api_key,
    }))
}

fn parse_generate_args(args: &[String]) -> Result<CliAction, String> {
    let mut prompt: Option<String> = None;
    let mut output_path: Option<PathBuf> = None;
    let mut model: Option<String> = None;
    let mut api_key: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-o" | "--output" => {
                i += 1;
                let out = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for -o / --output".to_string())?;
                output_path = Some(PathBuf::from(out));
            }
            "-p" | "--prompt" => {
                i += 1;
                let p = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for -p / --prompt".to_string())?;
                prompt = Some(p.to_string());
            }
            "-m" | "--model" => {
                i += 1;
                let m = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for -m / --model".to_string())?;
                model = Some(m.to_string());
            }
            "--api-key" => {
                i += 1;
                let k = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for --api-key".to_string())?;
                api_key = Some(k.to_string());
            }
            arg if arg.starts_with('-') => {
                return Err(format!("Unknown option for `uk generate`: {}", arg));
            }
            arg => {
                if prompt.is_none() {
                    prompt = Some(arg.to_string());
                } else {
                    return Err(format!("Unexpected extra argument for `uk generate`: {}", arg));
                }
            }
        }
        i += 1;
    }

    let prompt = prompt.ok_or_else(|| {
        "Missing prompt. Usage: `uk generate \"<prompt>\" [-o game.rb] [--model <model>]`".to_string()
    })?;

    Ok(CliAction::Generate {
        prompt,
        output_path: output_path.unwrap_or_else(|| PathBuf::from("game.rb")),
        model,
        api_key,
    })
}

fn parse_editor_kind_token(s: &str) -> Option<EditorKind> {
    match s.to_ascii_lowercase().as_str() {
        "spr" | "sprite" | "sprites" => Some(EditorKind::Sprite),
        "map" | "tilemap" => Some(EditorKind::Tilemap),
        "all" | "both" => Some(EditorKind::All),
        _ => None,
    }
}

fn parse_edit_args(args: &[String], default_kind: EditorKind) -> Result<CliAction, String> {
    let mut kind = default_kind;
    let mut kind_specified = false;
    let mut target_path: Option<PathBuf> = None;

    for arg in args {
        match arg.as_str() {
            "--all" | "-a" => {
                kind = EditorKind::All;
                kind_specified = true;
            }
            "--spr" | "--sprite" => {
                kind = EditorKind::Sprite;
                kind_specified = true;
            }
            "--map" | "--tilemap" => {
                kind = EditorKind::Tilemap;
                kind_specified = true;
            }
            s if s.starts_with('-') => {
                return Err(format!("Unknown option for `uk edit`: {}", s));
            }
            s => {
                if !kind_specified
                    && target_path.is_none()
                    && let Some(parsed_kind) = parse_editor_kind_token(s)
                {
                    kind = parsed_kind;
                    kind_specified = true;
                } else if target_path.is_none() {
                    target_path = Some(PathBuf::from(s));
                } else {
                    return Err(format!("Unexpected extra argument for `uk edit`: {}", s));
                }
            }
        }
    }

    Ok(CliAction::Edit {
        kind,
        target_path: target_path.unwrap_or_else(|| PathBuf::from("game.rb")),
    })
}

fn parse_run_with_edit_args(args: &[String]) -> Result<CliAction, String> {
    let mut script_path: Option<PathBuf> = None;
    let mut script_args = Vec::new();
    let mut editor_kind = EditorKind::All;
    let mut kind_specified = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--spr" | "--sprite" => {
                editor_kind = EditorKind::Sprite;
                kind_specified = true;
            }
            "--map" | "--tilemap" => {
                editor_kind = EditorKind::Tilemap;
                kind_specified = true;
            }
            "--all" | "-a" => {
                editor_kind = EditorKind::All;
                kind_specified = true;
            }
            "--" => {
                i += 1;
                while i < args.len() {
                    script_args.push(args[i].clone());
                    i += 1;
                }
                break;
            }
            arg if arg.starts_with('-') => {
                return Err(format!("Unknown option for `uk run_with_edit`: {}", arg));
            }
            arg => {
                if !kind_specified
                    && script_path.is_none()
                    && let Some(parsed_kind) = parse_editor_kind_token(arg)
                {
                    editor_kind = parsed_kind;
                    kind_specified = true;
                } else if script_path.is_none() {
                    script_path = Some(PathBuf::from(arg));
                } else {
                    script_args.push(arg.to_string());
                }
            }
        }
        i += 1;
    }

    Ok(CliAction::RunWithEdit {
        script_path: script_path.unwrap_or_else(|| PathBuf::from("game.rb")),
        script_args,
        editor_kind,
    })
}

fn parse_run_args(args: &[String]) -> Result<CliAction, String> {
    let mut script_path: Option<PathBuf> = None;
    let mut script_args = Vec::new();
    let mut screenshot_path: Option<PathBuf> = None;
    let mut screenshot_frames: u32 = 10;
    let mut with_edit: Option<EditorKind> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--edit" | "-e" => {
                with_edit = Some(EditorKind::All);
            }
            arg if arg.starts_with("--edit=") => {
                let val = &arg["--edit=".len()..];
                let kind = parse_editor_kind_token(val).ok_or_else(|| {
                    format!("Invalid editor kind `{}` (expected spr, map, or all)", val)
                })?;
                with_edit = Some(kind);
            }
            "--screenshot" | "-s" => {
                i += 1;
                let s = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for --screenshot".to_string())?;
                screenshot_path = Some(PathBuf::from(s));
            }
            "--frames" | "--screenshot-frames" => {
                i += 1;
                let f = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for --frames".to_string())?;
                screenshot_frames = f
                    .parse::<u32>()
                    .map_err(|_| format!("Invalid frame count: {}", f))?;
            }
            "--" => {
                i += 1;
                while i < args.len() {
                    script_args.push(args[i].clone());
                    i += 1;
                }
                break;
            }
            arg if arg.starts_with('-') => {
                return Err(format!("Unknown option for `uk run`: {}", arg));
            }
            arg => {
                if script_path.is_none() {
                    script_path = Some(PathBuf::from(arg));
                } else {
                    script_args.push(arg.to_string());
                }
            }
        }
        i += 1;
    }

    let script_path = script_path.unwrap_or_else(|| PathBuf::from("game.rb"));
    if let Some(editor_kind) = with_edit {
        return Ok(CliAction::RunWithEdit {
            script_path,
            script_args,
            editor_kind,
        });
    }

    Ok(CliAction::Run {
        script_path,
        script_args,
        screenshot_path,
        screenshot_frames,
    })
}

fn parse_check_args(args: &[String]) -> Result<CliAction, String> {
    let mut script_path: Option<PathBuf> = None;
    let mut frames: u32 = 60;
    let mut gacha: bool = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-f" | "--frames" => {
                i += 1;
                let f = args
                    .get(i)
                    .ok_or_else(|| "Missing argument for -f / --frames".to_string())?;
                frames = f
                    .parse::<u32>()
                    .map_err(|_| format!("Invalid frame count: {}", f))?;
            }
            "-g" | "--gacha" | "--mash" | "--fuzz" => {
                gacha = true;
            }
            arg if arg.starts_with('-') => {
                return Err(format!("Unknown option for `uk check`: {}", arg));
            }
            arg => {
                if script_path.is_none() {
                    script_path = Some(PathBuf::from(arg));
                } else {
                    return Err(format!("Unexpected extra argument for `uk check`: {}", arg));
                }
            }
        }
        i += 1;
    }

    Ok(CliAction::Check {
        script_path: script_path.unwrap_or_else(|| PathBuf::from("game.rb")),
        frames,
        gacha,
    })
}

/// PNG 画像バイト列を `__END__` セクション用の `@PNG` または `@SHEET` テキストブロックに変換する。
pub fn encode_png_bytes_to_script_block(
    png_bytes: &[u8],
    label: &str,
    start_id: i32,
    tile_size: Option<(u16, u16)>,
) -> Result<String, String> {
    let img = macroquad::texture::Image::from_file_with_format(
        png_bytes,
        Some(macroquad::prelude::ImageFormat::Png),
    )
    .map_err(|e| format!("Invalid PNG image `{}`: {:?}", label, e))?;

    let b64 = crate::encode_base64(png_bytes);
    let mut out = String::new();

    if tile_size.is_none() && img.width == crate::SPRITE_SIZE as u16 && img.height == crate::SPRITE_SIZE as u16 {
        out.push_str(&format!("# {} ({}x{})\n", label, img.width, img.height));
        out.push_str(&format!("@PNG {}\n", start_id));
    } else {
        let (tw, th) = tile_size.unwrap_or((crate::SPRITE_SIZE as u16, crate::SPRITE_SIZE as u16));
        let cols = (img.width / tw.max(1)).max(1);
        let rows = (img.height / th.max(1)).max(1);
        out.push_str(&format!(
            "# {} ({}x{}, {}x{} tiles x {})\n",
            label,
            img.width,
            img.height,
            tw,
            th,
            cols * rows
        ));
        out.push_str(&format!("@SHEET {} {}x{}\n", start_id, tw, th));
    }

    for chunk in b64.as_bytes().chunks(76) {
        out.push_str(std::str::from_utf8(chunk).unwrap_or(""));
        out.push('\n');
    }

    Ok(out)
}

/// 音声ファイル（WAV/OGG）のバイト列を `__END__` セクション用の `@WAV` または `@OGG` テキストブロックに変換する。
pub fn encode_audio_bytes_to_script_block(
    audio_bytes: &[u8],
    label: &str,
    start_id: i32,
    is_ogg: bool,
) -> Result<String, String> {
    if audio_bytes.is_empty() {
        return Err(format!("Audio file `{}` is empty", label));
    }
    let b64 = crate::encode_base64(audio_bytes);
    let tag = if is_ogg { "@OGG" } else { "@WAV" };
    let mut out = String::new();
    out.push_str(&format!("# {} ({} bytes)\n", label, audio_bytes.len()));
    out.push_str(&format!("{} {}\n", tag, start_id));

    for chunk in b64.as_bytes().chunks(76) {
        out.push_str(std::str::from_utf8(chunk).unwrap_or(""));
        out.push('\n');
    }

    Ok(out)
}

pub fn cmd_encode(
    file_path: &Path,
    start_id: i32,
    tile_size: Option<(u16, u16)>,
) -> Result<String, String> {
    let bytes = fs::read(file_path)
        .map_err(|e| format!("Failed to read asset `{}`: {}", file_path.display(), e))?;
    let label = file_path
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "asset".to_string());
    let ext = file_path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    let block = if ext == "wav" {
        encode_audio_bytes_to_script_block(&bytes, &label, start_id, false)?
    } else if ext == "ogg" {
        encode_audio_bytes_to_script_block(&bytes, &label, start_id, true)?
    } else {
        encode_png_bytes_to_script_block(&bytes, &label, start_id, tile_size)?
    };

    print!("{}", block);
    Ok(block)
}

/// Ruby スクリプト文字列（`__END__` 区切り対応）をコンパイルし `(tail_data, mrb_bytes)` を返す。
pub fn compile_ruby_script_str(full_source: &str) -> Result<(String, Vec<u8>), String> {
    compile_ruby_script_str_with_filename(full_source, None)
}

pub fn compile_ruby_script_str_with_filename(
    full_source: &str,
    filename: Option<&str>,
) -> Result<(String, Vec<u8>), String> {
    let (ruby_code, tail_data) = crate::bundle::split_ruby_source_and_tail(full_source);
    let tail_data = tail_data.to_string();
    let normalized_code = crate::bundle::normalize_ruby_config_syntax(ruby_code);

    let mrb_bytes = unsafe {
        let mut compiler = mruby_compiler2_sys::MRubyCompiler2Context::new();
        if let Some(fn_str) = filename {
            compiler.set_filename(fn_str);
        }
        compiler
            .compile(&normalized_code)
            .map_err(|e| format!("{}", e))?
    };

    Ok((tail_data, mrb_bytes))
}

/// 指定パスの `.rb` ファイルを読み込み、外部リソース（`.spr`, `.map`, `.sfx`, `.res`）をマージして
/// コンパイルし `(full_source, merged_tail_data, mrb_bytes)` を返す。
pub fn compile_ruby_script_file(path: &Path) -> Result<(String, String, Vec<u8>), String> {
    let full_source = fs::read_to_string(path)
        .map_err(|e| format!("Failed to read script `{}`: {}", path.display(), e))?;
    let path_str = path.to_string_lossy();
    let (embedded_tail, mrb_bytes) =
        compile_ruby_script_str_with_filename(&full_source, Some(&path_str))?;
    let (merged_tail, _) = crate::bundle::load_merged_tail_data(path, &embedded_tail);
    let parent_dir = path.parent().unwrap_or_else(|| Path::new(""));
    let final_tail = crate::bundle::inline_bank_file_paths_in_tail(&merged_tail, parent_dir);
    Ok((full_source, final_tail, mrb_bytes))
}

/// `uk pack <script.rb> [-o <output>]` の実装:
/// 外部リソース（`.spr`, `.map`, `.sfx`, `.res`）を `__END__` に統合した単一の `.rb` ファイルを出力する。
pub fn cmd_pack(script_path: &Path, output_path: Option<&Path>) -> Result<PathBuf, String> {
    let packed_source = crate::bundle::pack_script_to_standalone_source(script_path)?;
    let target = match output_path {
        Some(p) => p.to_path_buf(),
        None => script_path.to_path_buf(),
    };
    fs::write(&target, packed_source)
        .map_err(|e| format!("Failed to write packed script `{}`: {}", target.display(), e))?;
    println!("Successfully packed `{}` -> `{}`", script_path.display(), target.display());
    Ok(target)
}

/// `uk unpack <script.rb>` の実装:
/// `__END__` セクションからリソースを抽出し、外部ファイル（`<stem>.spr`, `<stem>.map`, `<stem>.sfx`）に展開する。
pub fn cmd_unpack(script_path: &Path) -> Result<Vec<PathBuf>, String> {
    let generated = crate::bundle::unpack_script_to_files(script_path)?;
    println!("Successfully unpacked resources from `{}`:", script_path.display());
    for f in &generated {
        println!("  - {}", f.display());
    }
    Ok(generated)
}

/// `uk build <script.rb>` の実装:
/// 現在の `uk` 実行バイナリのクローン末尾にコンパイル済み `.mrb` と `tail_data` を結合し、
/// 単一実行可能バイナリを生成する。
pub fn cmd_build(script_path: &Path, output_path: Option<&Path>) -> Result<PathBuf, String> {
    let current_exe = std::env::current_exe()
        .map_err(|e| format!("Failed to locate current uk executable: {}", e))?;
    cmd_build_with_base_exe(&current_exe, script_path, output_path)
}

pub fn cmd_build_with_base_exe(
    base_exe_path: &Path,
    script_path: &Path,
    output_path: Option<&Path>,
) -> Result<PathBuf, String> {
    let (_source, tail_data, mrb_bytes) = compile_ruby_script_file(script_path)?;

    let raw_exe_bytes = fs::read(base_exe_path).map_err(|e| {
        format!(
            "Failed to read base executable `{}`: {}",
            base_exe_path.display(),
            e
        )
    })?;
    let clean_exe_bytes = strip_bundle_from_exe_bytes(&raw_exe_bytes);
    let bundle_payload = pack_bundle(&tail_data, &mrb_bytes);

    let out_path = match output_path {
        Some(p) => p.to_path_buf(),
        None => default_output_binary_path(script_path),
    };

    // 自分自身の実行ファイルを上書きしないよう保護
    if let (Ok(canon_base), Ok(canon_out)) = (base_exe_path.canonicalize(), out_path.canonicalize())
        && canon_base == canon_out
    {
        return Err(format!(
            "Output path `{}` is the same as the running `uk` binary. Specify a different `-o <output>`.",
            out_path.display()
        ));
    }

    if let Some(parent) = out_path.parent()
        && !parent.as_os_str().is_empty()
    {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create output directory: {}", e))?;
    }

    let mut out_file = fs::File::create(&out_path).map_err(|e| {
        format!(
            "Failed to create output binary `{}`: {}",
            out_path.display(),
            e
        )
    })?;
    out_file
        .write_all(clean_exe_bytes)
        .map_err(|e| format!("Failed to write executable base: {}", e))?;
    out_file
        .write_all(&bundle_payload)
        .map_err(|e| format!("Failed to write embedded bundle: {}", e))?;
    out_file
        .flush()
        .map_err(|e| format!("Failed to flush output binary: {}", e))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(meta) = fs::metadata(&out_path) {
            let mut perms = meta.permissions();
            perms.set_mode(0o755);
            let _ = fs::set_permissions(&out_path, perms);
        }
    }

    let total_bytes = clean_exe_bytes.len() + bundle_payload.len();
    println!(
        "Built standalone binary `{}` ({:.2} MB) from `{}`",
        out_path.display(),
        total_bytes as f64 / (1024.0 * 1024.0),
        script_path.display()
    );

    Ok(out_path)
}

fn default_output_binary_path(script_path: &Path) -> PathBuf {
    let mut stem = script_path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "game".to_string());

    if stem.eq_ignore_ascii_case("uk") {
        stem = "uk_game".to_string();
    }

    if cfg!(windows) {
        PathBuf::from(format!("{}.exe", stem))
    } else {
        PathBuf::from(stem)
    }
}

/// `uk browser <script.rb>` の実装:
/// WASM ランタイム (`uk.wasm`) の準備、ローカル HTTP サーバーの起動、スクリプト監視によるホットリロード配信を行う。
pub fn cmd_browser(
    script_path: &Path,
    preferred_port: Option<u16>,
    open_browser: bool,
) -> Result<(), String> {
    // 1. 初回スクリプトのコンパイル検証
    let (_initial_source, tail_data, mrb_bytes) = compile_ruby_script_file(script_path)?;
    let initial_bundle = pack_bundle(&tail_data, &mrb_bytes);

    // 2. WASM ランタイム (`uk.wasm`) の取得またはビルド
    let wasm_bytes = locate_or_build_wasm()?;

    // 3. ローカル HTTP サーバーのバインド
    let listener = bind_local_server(preferred_port)?;
    let local_addr = listener
        .local_addr()
        .map_err(|e| format!("Failed to get local server address: {}", e))?;
    let url = format!("http://127.0.0.1:{}", local_addr.port());

    println!("Running `{}` in browser at {}", script_path.display(), url);
    println!("Editing `{}` will automatically hot-reload in the browser.", script_path.display());
    println!("Press Ctrl+C to stop the server.");

    let shared_bundle = Arc::new(Mutex::new(initial_bundle));
    let sse_clients: Arc<Mutex<Vec<TcpStream>>> = Arc::new(Mutex::new(Vec::new()));

    // 4. ファイル変更監視スレッド（ホットリロード用: スクリプトおよび外部リソースを監視）
    {
        let watch_path = script_path.to_path_buf();
        let shared_bundle_for_watcher = Arc::clone(&shared_bundle);
        let sse_clients_for_watcher = Arc::clone(&sse_clients);
        let mut last_snapshot = crate::bundle::get_script_and_resources_snapshot(&watch_path);

        std::thread::spawn(move || {
            loop {
                std::thread::sleep(Duration::from_millis(250));

                let current_snapshot =
                    crate::bundle::get_script_and_resources_snapshot(&watch_path);
                if current_snapshot == last_snapshot {
                    continue;
                }
                last_snapshot = current_snapshot;

                match compile_ruby_script_file(&watch_path) {
                    Ok((_new_src, new_tail, new_mrb)) => {
                        let new_bundle = pack_bundle(&new_tail, &new_mrb);
                        if let Ok(mut guard) = shared_bundle_for_watcher.lock() {
                            *guard = new_bundle;
                        }
                        println!("[uk browser] Hot-reloaded `{}`", watch_path.display());

                        if let Ok(mut clients) = sse_clients_for_watcher.lock() {
                            clients.retain_mut(|stream| {
                                stream
                                    .write_all(b"data: reload\n\n")
                                    .and_then(|_| stream.flush())
                                    .is_ok()
                            });
                        }
                    }
                    Err(err) => {
                        eprintln!(
                            "[uk browser] Compile error in `{}`:\n{}",
                            watch_path.display(),
                            err
                        );
                    }
                }
            }
        });
    }

    // 5. デフォルトブラウザを開く
    if open_browser {
        open_url_in_browser(&url);
    }

    // 6. HTTP リクエスト処理ループ
    let wasm_bytes = Arc::new(wasm_bytes);
    for stream in listener.incoming().flatten() {
        let shared_bundle = Arc::clone(&shared_bundle);
        let sse_clients = Arc::clone(&sse_clients);
        let wasm_bytes = Arc::clone(&wasm_bytes);

        std::thread::spawn(move || {
            handle_http_client(stream, &wasm_bytes, &shared_bundle, &sse_clients);
        });
    }

    Ok(())
}

fn bind_local_server(preferred_port: Option<u16>) -> Result<TcpListener, String> {
    if let Some(port) = preferred_port {
        return TcpListener::bind(("127.0.0.1", port))
            .map_err(|e| format!("Failed to bind to 127.0.0.1:{}: {}", port, e));
    }

    for port in 8080..=8099 {
        if let Ok(listener) = TcpListener::bind(("127.0.0.1", port)) {
            return Ok(listener);
        }
    }

    TcpListener::bind(("127.0.0.1", 0)).map_err(|e| format!("Failed to bind local server: {}", e))
}

fn handle_http_client(
    mut stream: TcpStream,
    wasm_bytes: &[u8],
    shared_bundle: &Arc<Mutex<Vec<u8>>>,
    sse_clients: &Arc<Mutex<Vec<TcpStream>>>,
) {
    let mut buf = [0u8; 4096];
    let Ok(n) = stream.read(&mut buf) else {
        return;
    };
    if n == 0 {
        return;
    }

    let req = String::from_utf8_lossy(&buf[..n]);
    let Some(first_line) = req.lines().next() else {
        return;
    };
    let raw_path = first_line.split_whitespace().nth(1).unwrap_or("/");
    let path = raw_path.split('?').next().unwrap_or("/");

    match path {
        "/" | "/index.html" => {
            let _ = write_http_response(
                &mut stream,
                "200 OK",
                "text/html; charset=utf-8",
                WEB_INDEX_HTML.as_bytes(),
            );
        }
        "/mq_js_bundle.js" => {
            let _ = write_http_response(
                &mut stream,
                "200 OK",
                "application/javascript; charset=utf-8",
                WEB_MQ_JS_BUNDLE.as_bytes(),
            );
        }
        "/uk.wasm" => {
            let _ = write_http_response(&mut stream, "200 OK", "application/wasm", wasm_bytes);
        }
        "/__uk_bundle.bin" => {
            let bundle = shared_bundle
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default();
            let _ = write_http_response(
                &mut stream,
                "200 OK",
                "application/octet-stream",
                &bundle,
            );
        }
        "/__uk_events" => {
            let headers = concat!(
                "HTTP/1.1 200 OK\r\n",
                "Content-Type: text/event-stream\r\n",
                "Cache-Control: no-cache, no-store\r\n",
                "Connection: keep-alive\r\n",
                "Access-Control-Allow-Origin: *\r\n",
                "\r\n",
                ": connected\n\n"
            );
            if stream.write_all(headers.as_bytes()).is_ok() && stream.flush().is_ok() {
                if let Ok(mut clients) = sse_clients.lock() {
                    clients.push(stream);
                }
            }
        }
        _ => {
            let _ = write_http_response(
                &mut stream,
                "404 Not Found",
                "text/plain; charset=utf-8",
                b"Not Found",
            );
        }
    }
}

fn write_http_response(
    stream: &mut TcpStream,
    status: &str,
    content_type: &str,
    body: &[u8],
) -> std::io::Result<()> {
    let header = format!(
        "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        status,
        content_type,
        body.len()
    );
    stream.write_all(header.as_bytes())?;
    stream.write_all(body)?;
    stream.flush()
}

fn locate_or_build_wasm() -> Result<Vec<u8>, String> {
    if let Ok(custom_path) = std::env::var("UK_WASM_PATH") {
        let p = PathBuf::from(custom_path);
        if p.exists() {
            return fs::read(&p)
                .map_err(|e| format!("Failed to read UK_WASM_PATH `{}`: {}", p.display(), e));
        }
    }

    // 実行ファイルと同じディレクトリに uk.wasm がある場合（配布環境など）
    if let Ok(exe_path) = std::env::current_exe()
        && let Some(exe_dir) = exe_path.parent()
    {
        let side_by_side = exe_dir.join("uk.wasm");
        if side_by_side.exists() {
            return fs::read(&side_by_side)
                .map_err(|e| format!("Failed to read `{}`: {}", side_by_side.display(), e));
        }
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let candidates = [
        PathBuf::from("target/wasm32-unknown-unknown/release/uk.wasm"),
        PathBuf::from("target/wasm32-unknown-unknown/debug/uk.wasm"),
        manifest_dir.join("target/wasm32-unknown-unknown/release/uk.wasm"),
        manifest_dir.join("target/wasm32-unknown-unknown/debug/uk.wasm"),
    ];

    let src_modified = fs::metadata(manifest_dir.join("src/main.rs"))
        .and_then(|m| m.modified())
        .ok();

    for candidate in &candidates {
        if candidate.exists() {
            let wasm_up_to_date = match (
                src_modified,
                fs::metadata(candidate).and_then(|m| m.modified()).ok(),
            ) {
                (Some(src_t), Some(wasm_t)) => wasm_t >= src_t,
                _ => true,
            };
            if wasm_up_to_date {
                return fs::read(candidate)
                    .map_err(|e| format!("Failed to read `{}`: {}", candidate.display(), e));
            }
        }
    }

    // 未ビルドまたはソース更新時は自動で cargo build --target wasm32-unknown-unknown を実行
    println!("Building WASM runtime (`uk.wasm`)...");
    let work_dir = if manifest_dir.join("Cargo.toml").exists() {
        manifest_dir.clone()
    } else {
        PathBuf::from(".")
    };

    let status = Command::new("cargo")
        .args(["build", "--target", "wasm32-unknown-unknown", "--bin", "uk"])
        .current_dir(&work_dir)
        .status()
        .map_err(|e| format!("Failed to invoke `cargo build --target wasm32-unknown-unknown`: {}", e))?;

    if !status.success() {
        return Err(
            "Failed to build WASM runtime. Make sure `rustup target add wasm32-unknown-unknown` is installed."
                .to_string(),
        );
    }

    let built_wasm = work_dir.join("target/wasm32-unknown-unknown/debug/uk.wasm");
    fs::read(&built_wasm)
        .map_err(|e| format!("Failed to read built WASM `{}`: {}", built_wasm.display(), e))
}

fn open_url_in_browser(url: &str) {
    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("cmd").args(["/C", "start", "", url]).spawn();
    }
    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("open").arg(url).spawn();
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let _ = Command::new("xdg-open").arg(url).spawn();
    }
}

/// 圧縮済みの `examples_archive.bin` バイト列を展開し、`(ファイル名, 内容)` のリストを返す。
pub fn unpack_examples_archive(compressed: &[u8]) -> Result<Vec<(String, Vec<u8>)>, String> {
    let mut decoder = flate2::read::ZlibDecoder::new(compressed);
    let mut raw = Vec::new();
    decoder
        .read_to_end(&mut raw)
        .map_err(|e| format!("Failed to decompress examples archive: {}", e))?;

    if raw.len() < 4 {
        return Err("Invalid examples archive (too short)".to_string());
    }
    let count = u32::from_le_bytes(raw[0..4].try_into().unwrap()) as usize;
    let mut pos = 4;
    let mut entries = Vec::with_capacity(count);

    for _ in 0..count {
        if pos + 4 > raw.len() {
            return Err("Corrupted examples archive (unexpected EOF reading name len)".to_string());
        }
        let name_len = u32::from_le_bytes(raw[pos..pos + 4].try_into().unwrap()) as usize;
        pos += 4;
        if pos + name_len > raw.len() {
            return Err("Corrupted examples archive (unexpected EOF reading name)".to_string());
        }
        let name = String::from_utf8(raw[pos..pos + name_len].to_vec())
            .map_err(|e| format!("Invalid UTF-8 filename in archive: {}", e))?;
        pos += name_len;

        if pos + 4 > raw.len() {
            return Err("Corrupted examples archive (unexpected EOF reading data len)".to_string());
        }
        let data_len = u32::from_le_bytes(raw[pos..pos + 4].try_into().unwrap()) as usize;
        pos += 4;
        if pos + data_len > raw.len() {
            return Err("Corrupted examples archive (unexpected EOF reading data)".to_string());
        }
        let data = raw[pos..pos + data_len].to_vec();
        pos += data_len;

        entries.push((name, data));
    }

    Ok(entries)
}

/// 指定ディレクトリに同梱の `examples/` ファイルをすべて展開する。
pub fn extract_examples_to_dir(dest_dir: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = unpack_examples_archive(EMBEDDED_EXAMPLES_ARCHIVE)?;
    fs::create_dir_all(dest_dir).map_err(|e| {
        format!(
            "Failed to create directory `{}`: {}",
            dest_dir.display(),
            e
        )
    })?;

    let mut written = Vec::with_capacity(entries.len());
    for (name, bytes) in entries {
        let out_path = dest_dir.join(&name);
        fs::write(&out_path, &bytes)
            .map_err(|e| format!("Failed to write `{}`: {}", out_path.display(), e))?;
        written.push(out_path);
    }
    Ok(written)
}

/// `uk examples [dest_dir]` の実装
pub fn cmd_examples(dest_dir: &Path) -> Result<Vec<PathBuf>, String> {
    let written = extract_examples_to_dir(dest_dir)?;
    println!(
        "Extracted {} example files to `{}`!",
        written.len(),
        dest_dir.display()
    );
    println!("Try running an example:");
    println!(
        "  uk run {}/platformer.rb",
        dest_dir.to_string_lossy().replace('\\', "/")
    );
    println!(
        "  uk run {}/survivors.rb",
        dest_dir.to_string_lossy().replace('\\', "/")
    );
    Ok(written)
}

const PROJECT_GITIGNORE: &str = "\
# Usakame generated files
/screenshots/
/*_packed.rb
/*.exe
/*.wasm

# AI / Reference files (untracked)
/refs/
";

const TEMPLATE_MINIMAL_RB: &str = r#"# ==============================================================================
# 🐰 {{PROJECT_TITLE}}
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2,
  title: "{{PROJECT_TITLE}}"
)

$frame = 0

def update
  $frame += 1
end

def draw
  cls(1)
  print_text("HELLO USAKAME!", 72, 110, 7)
  spr("🐰", 120, 128 + (sin($frame * 0.1) * 4).to_i)
end
"#;

const TEMPLATE_STARTER_CODE_RB: &str = r#"# ==============================================================================
# 🐰 {{PROJECT_TITLE}}
# ------------------------------------------------------------------------------
# Run:            uk run game.rb
# Run + Editors:  uk run_with_edit game.rb
# Edit Sprites:   uk edit spr game.rb
# Edit Tilemap:   uk edit map game.rb
# Build EXE:      uk build game.rb
# Web Browser:    uk browser game.rb
# ==============================================================================

config(
  width: 256,
  height: 256,
  scale: 2,
  title: "{{PROJECT_TITLE}}"
)

$px = 120.0
$py = 120.0
$facing_left = false
$frame = 0

def can_move_to?(nx, ny)
  corners = [
    [nx + 2, ny + 2],
    [nx + 13, ny + 2],
    [nx + 2, ny + 13],
    [nx + 13, ny + 13]
  ]
  corners.each do |pt|
    tx = (pt[0] / 16).to_i
    ty = (pt[1] / 16).to_i
    return false if tx < 0 || tx >= 16 || ty < 0 || ty >= 16
    return false if mget(tx, ty) == 2
  end
  true
end

def update
  $frame += 1

  speed = 1.5
  dx = 0.0
  dy = 0.0

  if btn(:left)
    dx -= speed
    $facing_left = true
  end
  if btn(:right)
    dx += speed
    $facing_left = false
  end
  dy -= speed if btn(:up)
  dy += speed if btn(:down)

  if dx != 0.0 && can_move_to?($px + dx, $py)
    $px += dx
  end
  if dy != 0.0 && can_move_to?($px, $py + dy)
    $py += dy
  end

  if btnp(:z) || btnp(:space)
    sfx(0)
  end
end

def draw
  cls(1)

  # Draw 16x16 tilemap
  map(0, 0, 0, 0, 16, 16)

  # Draw player sprite
  moving = btn(:left) || btn(:right) || btn(:up) || btn(:down)
  bob = (moving && ($frame / 6) % 2 == 1) ? -1 : 0
  spr(0, $px, $py + bob, $facing_left, false)

  # Header UI
  rectfill(0, 0, 256, 14, 0)
  print_text("{{PROJECT_TITLE}}", 6, 3, 7)
  print_text("ARROWS:MOVE Z:ACT", 114, 3, 10)
end
"#;

const TEMPLATE_STARTER_SPR: &str = "\
@SPRITE 0
....77....77....
...7EE7..7EE7...
...7EE7..7EE7...
...7777..7777...
...7777777777...
..777777777777..
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

@SPRITE 1
3333333333333333
33B3333333333B33
3333333333333333
3333333B33333333
3333333333333333
3B33333333333333
33333333333B3333
3333333333333333
3333B33333333333
3333333333333333
333333333B333333
33333333333333B3
33B3333333333333
333333B333333333
3333333333333333
3333333333333333

@SPRITE 2
.....BBBBBB.....
...BBBBBBBBBB...
..BBBB3333BBBB..
.BBBB33BB33BBBB.
.BBB33BBBB33BBB.
.BBB3BBBBBB3BBB.
.BBBBBBBBBBBBBB.
..BBBB3333BBBB..
...BBBBBBBBBB...
.....334433.....
......4444......
......4444......
.....444444.....
....33333333....
...3333333333...
................

@SPRITE 3
3333333333333333
3333333333333333
3333337733333333
333337AA73333333
3333337733333333
333333BB33333333
33333B33B3333333
3333333333333333
3333333333773333
3333333337EE7333
3333333333773333
3333333333BB3333
333333333B33B333
3333333333333333
3333333333333333
3333333333333333
";

const TEMPLATE_STARTER_MAP: &str = "\
@MAP 0 0
2222222222222222
2111111111111112
2131111111111312
2111111111111112
2111221111221112
2111111111111112
2111111331111112
2111111111111112
2111111111111112
2111111331111112
2111111111111112
2111221111221112
2111111111111112
2131111111111312
2111111111111112
2222222222222222
";

const TEMPLATE_STARTER_SFX: &str = "\
@SFX 0
square T180 L16 c5 e5 g5 c6
";

const PROJECT_AGENTS_MD: &str = r#"# AGENTS.md ({{PROJECT_TITLE}})

このプロジェクトはレトロゲームエンジン **Usakame (`uk`)** で作成された Ruby ゲームプロジェクトです。
AI エージェントがコードの生成・編集・デバッグを行う際は、以下のガイドラインを必ず遵守してください。

---

## 1. ドキュメント（編集前に必ず確認すること）

Usakame のスクリプト実行環境は軽量 Ruby VM **mrubyedge** です。標準の CRuby とは利用できる組み込みメソッドが異なります。
コードを記述する前に必ず以下のローカルドキュメントを参照してください。

* **[docs/mrubyedge_api.md](docs/mrubyedge_api.md)**: mrubyedge で利用可能な Ruby 標準クラス・メソッド一覧、および未実装メソッドと代替コード集。
* **[docs/api.md](docs/api.md)**: Usakame エンジン固有の描画・入力・タイルマップ・バンク・サウンド API（`cls`, `spr`, `blt`, `btn`, `map`, `sfx`, `music` 等）。
* **`refs/examples/*.rb`**（存在する場合、または `uk examples refs/examples` でいつでも展開可能）: 実践的なサンプルゲーム群（アクション、サバイバー、RPG、エディタ等）。

---

## 2. ⚠️ Ruby コード作成・編集時の絶対ルール（最重要）

以下のメソッドは **mrubyedge に存在しないため呼び出すと `NoMethodError` でクラッシュします**。必ず記載の代替パターンを使用してください。

* ❌ `array.sample` → ⭕ **`array[rand(array.size)]`**
* ❌ `array.shuffle` → ⭕ ランダムスワップ処理を自前で実装する
* ❌ `array.reverse` → ⭕ インデックスを逆順に回す（`i = array.size - 1; while i >= 0 ...`）
* ❌ `array.delete(item)` → ⭕ **`array.reject! { |x| x == item }`** または `delete_at(idx)`
* ❌ `hash.key?(k)` / `include?` → ⭕ **`hash.has_key?(k)`**
* ❌ `hash.dig(...)` → ⭕ `hash[a] && hash[a][b]`
* ❌ `string.gsub` / `sub` → ⭕ `string.split(pat).join(rep)` 等で代替
* ❌ `n.upto(m)` / `downto` → ⭕ **`(n..m).each`** または `while` ループ
* ❌ `n.even?` / `odd?` → ⭕ **`n % 2 == 0`** / **`n % 2 != 0`**
* ❌ `sleep(sec)` / `Time.now` → ⭕ ゲームループ（毎フレーム呼ばれる `update`）内のフレームカウンタ変数で制御
* ❌ `require` / `load` / `eval` → ⭕ 単一スクリプト構成で記述する

### タイルマップ API（`mget` / `mset` / `mdel`）のルール
* **空マスの取得**: `mget(x, y)` は空マス・未設定セルに対して **`nil`** を返します（`-1` ではありません）。
  * ⭕ `if mget(x, y)` でタイルが存在するか判定できます（0番タイルも真になります）。
  * ❌ `if mget(x, y) > 0` や `if mget(x, y) != -1` と書かないこと。
* **タイルの消去**: 消去には **`mdel(x, y)`** または **`mset(x, y, nil)`** を使用してください（`-1` を渡すと `ArgumentError` になります）。

---

## 3. 実行・テスト・AI による自動視覚検証コマンド

* **🤖 高速ヘッドレス検証（構文 & 60フレーム実行チェック、推奨）**:
  GUI ウィンドウを開かずに一瞬（0.1秒未満）で構文エラーや実行時例外（`NoMethodError` 等）を検証できます：
  ```bash
  uk check game.rb
  # ガチャキーモード（方向キー・パッドボタンの擬似連打テスト）
  uk check game.rb -g --frames 120
  ```
  コードを生成・編集した直後は、まずこのコマンドを実行してクラッシュしないことを確認してください。
* **ゲームの起動（ホットリロード対応）**:
  ```bash
  uk run game.rb
  ```
* **ゲームとエディタ（スプライト／タイルマップ）の同時起動**:
  ```bash
  uk run_with_edit game.rb
  ```
* **スプライトエディタ／タイルマップエディタ単体起動**:
  ```bash
  uk edit spr game.rb
  uk edit map game.rb
  ```
* **🤖 AI エージェントによる自動動作確認 & スクリーンショット検証**:
  画面の描画結果を画像として自律確認したい場合は、以下を実行すると指定フレーム後に PNG を保存して自動終了します（構文エラーや実行時エラーがあれば標準エラー出力に表示されます）：
  ```bash
  uk run game.rb --screenshot screenshots/check.png --frames 60
  ```
  コードを変更した後はこのコマンドでクラッシュがないか・描画が意図通りかを自律的に確認してください。
* **リソース分離・結合・配布ビルド**:
  ```bash
  uk unpack game.rb        # __END__ リソースを .spr / .map / .sfx に分離
  uk pack game.rb          # .spr / .map / .sfx を game.rb の __END__ に統合
  uk build game.rb         # 単一実行ファイル (.exe) を生成
  uk browser game.rb       # ブラウザ (WASM) でホットリロード実行
  ```
"#;

/// テンプレート名に対応する埋め込みサンプルスクリプトの stem 名を解決する
fn resolve_example_template_stem(template_lower: &str) -> Option<&str> {
    match template_lower {
        "default" | "starter" | "minimal" | "empty" | "split" => None,
        "rpg" | "knight" => Some("rabbit_knight"),
        "shooter" | "stg" => Some("shooter"),
        "survivors" | "vampire" => Some("survivors"),
        "puzzle" | "match3" | "falling" => Some("puzzle"),
        "card" | "deck" | "roguelite" => Some("card_roguelite"),
        "runner" | "flappy" => Some("flappy_runner"),
        "particles" | "effects" | "juicy" => Some("particles"),
        "dungeon" => Some("tiny_dungeon"),
        other => Some(other),
    }
}

/// `uk new <dir>` / `uk init [dir]` の実装
pub fn cmd_new(opts: &NewProjectOptions) -> Result<Vec<PathBuf>, String> {
    cmd_new_with_generator(opts, |prompt, title| {
        crate::llm::generate_verified_game_rb(
            prompt,
            title,
            opts.api_key.as_deref(),
            opts.model.as_deref(),
        )
    })
}

/// 任意の LLM 生成関数（テスト時のモック等）を注入可能な `uk new` 実装
pub fn cmd_new_with_generator<G>(
    opts: &NewProjectOptions,
    mut generator: G,
) -> Result<Vec<PathBuf>, String>
where
    G: FnMut(&str, &str) -> Result<(String, usize), String>,
{
    let dir = &opts.project_dir;
    let game_rb_path = dir.join("game.rb");
    if game_rb_path.exists() {
        return Err(format!(
            "`{}` already exists. Aborting so existing files are not overwritten.",
            game_rb_path.display()
        ));
    }

    fs::create_dir_all(dir)
        .map_err(|e| format!("Failed to create directory `{}`: {}", dir.display(), e))?;

    let project_title = dir
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty() && *s != ".")
        .or_else(|| {
            std::env::current_dir()
                .ok()
                .and_then(|c| c.file_name().and_then(|s| s.to_str()).map(String::from))
                .as_deref()
                .map(|_| "Usakame Game")
        })
        .unwrap_or("Usakame Game")
        .to_uppercase();

    let mut created_files = Vec::new();

    // 1. .gitignore
    let gitignore_path = dir.join(".gitignore");
    if !gitignore_path.exists() {
        fs::write(&gitignore_path, PROJECT_GITIGNORE)
            .map_err(|e| format!("Failed to write `{}`: {}", gitignore_path.display(), e))?;
        created_files.push(gitignore_path);
    }

    // 2. game.rb (LLM生成 / 埋め込みサンプルテンプレート / 標準テンプレート)
    let tpl_lower = opts.template.to_ascii_lowercase();
    if let Some(ref prompt_text) = opts.prompt {
        let (generated_rb, attempts) = generator(prompt_text, &project_title)?;
        println!(
            "✨ Generated and verified `game.rb` in {} attempt(s)!",
            attempts
        );
        if opts.split {
            let (code_only, tail_only) = crate::bundle::split_ruby_source_and_tail(&generated_rb);
            fs::write(&game_rb_path, format!("{}\n", code_only.trim_end()))
                .map_err(|e| format!("Failed to write `{}`: {}", game_rb_path.display(), e))?;
            created_files.push(game_rb_path.clone());

            if !tail_only.trim().is_empty() {
                let tmp_packed = dir.join("__tmp_full_game.rb");
                fs::write(&tmp_packed, &generated_rb).ok();
                let _ = crate::bundle::unpack_script_to_files(&game_rb_path);
                let _ = fs::remove_file(&tmp_packed);
                // Write full first, unpack, then strip __END__
                fs::write(&game_rb_path, &generated_rb).ok();
                if let Ok(unpacked) = crate::bundle::unpack_script_to_files(&game_rb_path) {
                    created_files.extend(unpacked);
                }
                fs::write(&game_rb_path, format!("{}\n", code_only.trim_end())).ok();
            }
        } else {
            fs::write(&game_rb_path, &generated_rb)
                .map_err(|e| format!("Failed to write `{}`: {}", game_rb_path.display(), e))?;
            created_files.push(game_rb_path);
        }
    } else if let Some(example_stem) = resolve_example_template_stem(&tpl_lower) {
        let entries = unpack_examples_archive(EMBEDDED_EXAMPLES_ARCHIVE)?;
        let target_rb_name = format!("{}.rb", example_stem);
        let found_rb = entries
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case(&target_rb_name));

        let Some((_, rb_bytes)) = found_rb else {
            return Err(format!(
                "Unknown template `{}`. Available templates: default, minimal, split, platformer, shooter, puzzle, card, runner, rpg, survivors, dungeon, demo, sound",
                opts.template
            ));
        };

        let rb_str = String::from_utf8_lossy(rb_bytes).to_string();
        fs::write(&game_rb_path, &rb_str)
            .map_err(|e| format!("Failed to write `{}`: {}", game_rb_path.display(), e))?;
        created_files.push(game_rb_path.clone());

        // 同梱の関連アセット (例: platformer_bg.png, tiny_dungeon.png, split_game.spr 等) もコピー
        for (name, data) in &entries {
            if name.eq_ignore_ascii_case(&target_rb_name) {
                continue;
            }
            if name.starts_with(example_stem) {
                let ext = Path::new(name)
                    .extension()
                    .and_then(|s| s.to_str())
                    .unwrap_or("");
                let dest_file = if matches!(ext, "spr" | "map" | "sfx" | "res")
                    && name.eq_ignore_ascii_case(&format!("{}.{}", example_stem, ext))
                {
                    dir.join(format!("game.{}", ext))
                } else {
                    dir.join(name)
                };
                fs::write(&dest_file, data)
                    .map_err(|e| format!("Failed to write `{}`: {}", dest_file.display(), e))?;
                created_files.push(dest_file);
            }
        }

        if opts.split {
            let (code_only, tail_only) = crate::bundle::split_ruby_source_and_tail(&rb_str);
            if !tail_only.trim().is_empty() {
                if let Ok(unpacked) = crate::bundle::unpack_script_to_files(&game_rb_path) {
                    created_files.extend(unpacked);
                }
                fs::write(&game_rb_path, format!("{}\n", code_only.trim_end())).ok();
            }
        }
    } else {
        let code_body = if tpl_lower == "minimal" || tpl_lower == "empty" {
            TEMPLATE_MINIMAL_RB.replace("{{PROJECT_TITLE}}", &project_title)
        } else {
            TEMPLATE_STARTER_CODE_RB.replace("{{PROJECT_TITLE}}", &project_title)
        };

        if opts.split {
            fs::write(&game_rb_path, &code_body)
                .map_err(|e| format!("Failed to write `{}`: {}", game_rb_path.display(), e))?;
            created_files.push(game_rb_path);

            let spr_path = dir.join("game.spr");
            fs::write(&spr_path, TEMPLATE_STARTER_SPR)
                .map_err(|e| format!("Failed to write `{}`: {}", spr_path.display(), e))?;
            created_files.push(spr_path);

            let map_path = dir.join("game.map");
            fs::write(&map_path, TEMPLATE_STARTER_MAP)
                .map_err(|e| format!("Failed to write `{}`: {}", map_path.display(), e))?;
            created_files.push(map_path);

            let sfx_path = dir.join("game.sfx");
            fs::write(&sfx_path, TEMPLATE_STARTER_SFX)
                .map_err(|e| format!("Failed to write `{}`: {}", sfx_path.display(), e))?;
            created_files.push(sfx_path);
        } else if tpl_lower == "minimal" || tpl_lower == "empty" {
            fs::write(&game_rb_path, &code_body)
                .map_err(|e| format!("Failed to write `{}`: {}", game_rb_path.display(), e))?;
            created_files.push(game_rb_path);
        } else {
            let full_game_rb = format!(
                "{}\n__END__\n{}\n{}\n{}",
                code_body.trim_end(),
                TEMPLATE_STARTER_SPR.trim_end(),
                TEMPLATE_STARTER_MAP.trim_end(),
                TEMPLATE_STARTER_SFX
            );
            fs::write(&game_rb_path, full_game_rb)
                .map_err(|e| format!("Failed to write `{}`: {}", game_rb_path.display(), e))?;
            created_files.push(game_rb_path);
        }
    }

    // 3. AI Agent Docs (default ON, skipped if --minimal)
    if !opts.minimal {
        let agents_md_path = dir.join("AGENTS.md");
        let agents_content = PROJECT_AGENTS_MD.replace("{{PROJECT_TITLE}}", &project_title);
        fs::write(&agents_md_path, agents_content)
            .map_err(|e| format!("Failed to write `{}`: {}", agents_md_path.display(), e))?;
        created_files.push(agents_md_path);

        let docs_dir = dir.join("docs");
        fs::create_dir_all(&docs_dir)
            .map_err(|e| format!("Failed to create `{}`: {}", docs_dir.display(), e))?;

        let api_md_path = docs_dir.join("api.md");
        fs::write(&api_md_path, EMBEDDED_API_MD)
            .map_err(|e| format!("Failed to write `{}`: {}", api_md_path.display(), e))?;
        created_files.push(api_md_path);

        let mruby_md_path = docs_dir.join("mrubyedge_api.md");
        fs::write(&mruby_md_path, EMBEDDED_MRUBYEDGE_API_MD)
            .map_err(|e| format!("Failed to write `{}`: {}", mruby_md_path.display(), e))?;
        created_files.push(mruby_md_path);
    }

    // 4. Reference examples (--with-refs)
    if opts.with_refs {
        let refs_examples_dir = dir.join("refs").join("examples");
        let extracted = extract_examples_to_dir(&refs_examples_dir)?;
        created_files.extend(extracted);
    }

    println!("🐰 Created new Usakame project in `{}`!", dir.display());
    for f in &created_files {
        if !f.components().any(|c| c.as_os_str() == "refs") {
            println!("  + {}", f.display());
        }
    }
    if opts.with_refs {
        println!(
            "  + {}/refs/examples/* (bundled reference examples)",
            dir.display()
        );
    }
    println!("\nNext steps:");
    if dir != Path::new(".") {
        println!("  cd {}", dir.display());
    }
    println!("  uk run                 # Run the game with live hot-reload");
    println!("  uk run_with_edit       # Run the game + Sprite & Tilemap Editors together");
    println!("  uk edit                # Open Sprite Editor (or `uk edit map` for Tilemap)");

    Ok(created_files)
}

/// `uk generate "<prompt>" [-o <script.rb>]` の実装
pub fn cmd_generate(
    prompt: &str,
    output_path: &Path,
    model: Option<&str>,
    api_key: Option<&str>,
) -> Result<PathBuf, String> {
    let title = output_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("Usakame Game")
        .to_uppercase();
    let (generated_rb, attempts) =
        crate::llm::generate_verified_game_rb(prompt, &title, api_key, model)?;
    if let Some(parent) = output_path.parent()
        && !parent.as_os_str().is_empty()
    {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create directory `{}`: {}", parent.display(), e))?;
    }
    fs::write(output_path, &generated_rb)
        .map_err(|e| format!("Failed to write `{}`: {}", output_path.display(), e))?;
    println!(
        "✨ Generated and verified `{}` in {} attempt(s)!",
        output_path.display(),
        attempts
    );
    Ok(output_path.to_path_buf())
}

/// エディタプロセスをバックグラウンド（子プロセス）で起動する
pub fn spawn_editor_processes(kind: EditorKind, target_path: &Path) -> Vec<std::process::Child> {
    let mut children = Vec::new();
    let Ok(exe) = std::env::current_exe() else {
        return children;
    };
    let target_str = target_path.to_string_lossy().to_string();

    let kinds_to_spawn: &[&str] = match kind {
        EditorKind::Sprite => &["spr"],
        EditorKind::Tilemap => &["map"],
        EditorKind::All => &["spr", "map"],
    };

    for k in kinds_to_spawn {
        if let Ok(child) = Command::new(&exe).args(["edit", k, &target_str]).spawn() {
            children.push(child);
        }
    }
    children
}
