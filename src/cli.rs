use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use crate::bundle::{pack_bundle, read_bundle_from_current_exe, strip_bundle_from_exe_bytes};

const WEB_INDEX_HTML: &str = include_str!("../web/index.html");
const WEB_MQ_JS_BUNDLE: &str = include_str!("../web/mq_js_bundle.js");

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliAction {
    /// `uk run <script.rb>` (ホットリロード付きネイティブ実行)
    Run { script_path: PathBuf },
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
    uk run [script.rb]                  Run script natively with live hot-reload (default: game.rb)
    uk build [script.rb] [-o <output>]  Build a standalone single binary from script
    uk browser [script.rb] [-p <port>]  Run script in the browser with live hot-reload
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
            });
        }

        return Ok(CliAction::Help);
    }

    match rest[0].as_str() {
        "help" | "--help" | "-h" => Ok(CliAction::Help),
        "version" | "--version" | "-V" => Ok(CliAction::Version),
        "run" => {
            let script_path = rest
                .get(1)
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("game.rb"));
            Ok(CliAction::Run { script_path })
        }
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
        other => {
            // `uk game.rb` のように直接 .rb ファイルが渡された場合も `uk run` として扱う
            let candidate = PathBuf::from(other);
            if other.ends_with(".rb") || candidate.exists() {
                Ok(CliAction::Run {
                    script_path: candidate,
                })
            } else {
                Err(format!(
                    "Unknown command `{}`. Run `uk --help` for usage.",
                    other
                ))
            }
        }
    }
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
    let (ruby_code, tail_data) = crate::bundle::split_ruby_source_and_tail(full_source);
    let tail_data = tail_data.to_string();
    let normalized_code = crate::bundle::normalize_ruby_config_syntax(ruby_code);

    let mrb_bytes = unsafe {
        let mut compiler = mruby_compiler2_sys::MRubyCompiler2Context::new();
        compiler
            .compile(&normalized_code)
            .map_err(|e| format!("Ruby compile error: {}", e))?
    };

    Ok((tail_data, mrb_bytes))
}

/// 指定パスの `.rb` ファイルを読み込み、コンパイルして `(full_source, tail_data, mrb_bytes)` を返す。
pub fn compile_ruby_script_file(path: &Path) -> Result<(String, String, Vec<u8>), String> {
    let full_source = fs::read_to_string(path)
        .map_err(|e| format!("Failed to read script `{}`: {}", path.display(), e))?;
    let (tail_data, mrb_bytes) = compile_ruby_script_str(&full_source)?;
    Ok((full_source, tail_data, mrb_bytes))
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
    let (initial_source, tail_data, mrb_bytes) = compile_ruby_script_file(script_path)?;
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

    // 4. ファイル変更監視スレッド（ホットリロード用）
    {
        let watch_path = script_path.to_path_buf();
        let shared_bundle_for_watcher = Arc::clone(&shared_bundle);
        let sse_clients_for_watcher = Arc::clone(&sse_clients);
        let mut last_source = initial_source;
        let mut last_modified: Option<SystemTime> =
            fs::metadata(&watch_path).and_then(|m| m.modified()).ok();

        std::thread::spawn(move || {
            loop {
                std::thread::sleep(Duration::from_millis(250));

                let current_modified = fs::metadata(&watch_path).and_then(|m| m.modified()).ok();
                if current_modified == last_modified {
                    continue;
                }
                last_modified = current_modified;

                let Ok(new_source) = fs::read_to_string(&watch_path) else {
                    continue;
                };
                if new_source.is_empty() || new_source == last_source {
                    continue;
                }
                last_source = new_source.clone();

                match compile_ruby_script_str(&new_source) {
                    Ok((new_tail, new_mrb)) => {
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
