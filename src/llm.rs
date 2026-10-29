use std::collections::HashMap;
use std::fs;
use std::process::Command;

use crate::cli::{EMBEDDED_API_MD, EMBEDDED_MRUBYEDGE_API_MD};

/// 最大自己修復リトライ回数（初回生成 + 最大2回のエラー修正リトライ = 計3回）
pub const MAX_LLM_ATTEMPTS: usize = 3;

#[derive(Debug, Clone, PartialEq)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<JsonValue>),
    Object(HashMap<String, JsonValue>),
}

impl JsonValue {
    pub fn get(&self, key: &str) -> Option<&JsonValue> {
        match self {
            JsonValue::Object(map) => map.get(key),
            _ => None,
        }
    }

    pub fn index(&self, idx: usize) -> Option<&JsonValue> {
        match self {
            JsonValue::Array(arr) => arr.get(idx),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            JsonValue::String(s) => Some(s.as_str()),
            _ => None,
        }
    }
}

/// 文字列を JSON リテラル（両端の `"` を含む）にエスケープする
pub fn to_json_string_literal(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 16);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\x08' => out.push_str("\\b"),
            '\x0c' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// 軽量な再帰下降 JSON パーサー（外部クレート依存ゼロ）
pub fn parse_json(input: &str) -> Result<JsonValue, String> {
    let chars: Vec<char> = input.chars().collect();
    let mut pos = 0;
    let val = parse_json_value(&chars, &mut pos)?;
    skip_ws(&chars, &mut pos);
    Ok(val)
}

fn skip_ws(chars: &[char], pos: &mut usize) {
    while *pos < chars.len() && chars[*pos].is_ascii_whitespace() {
        *pos += 1;
    }
}

fn parse_json_value(chars: &[char], pos: &mut usize) -> Result<JsonValue, String> {
    skip_ws(chars, pos);
    if *pos >= chars.len() {
        return Err("Unexpected EOF while parsing JSON".to_string());
    }
    match chars[*pos] {
        '"' => parse_json_string(chars, pos).map(JsonValue::String),
        '{' => parse_json_object(chars, pos),
        '[' => parse_json_array(chars, pos),
        't' | 'f' => parse_json_bool(chars, pos),
        'n' => parse_json_null(chars, pos),
        '-' | '0'..='9' => parse_json_number(chars, pos),
        c => Err(format!("Unexpected character `{}` at position {}", c, *pos)),
    }
}

fn parse_json_string(chars: &[char], pos: &mut usize) -> Result<String, String> {
    if chars.get(*pos) != Some(&'"') {
        return Err("Expected `\"` at start of JSON string".to_string());
    }
    *pos += 1;
    let mut out = String::new();
    while *pos < chars.len() {
        let ch = chars[*pos];
        *pos += 1;
        if ch == '"' {
            return Ok(out);
        }
        if ch == '\\' {
            if *pos >= chars.len() {
                return Err("Unexpected EOF in JSON string escape".to_string());
            }
            let esc = chars[*pos];
            *pos += 1;
            match esc {
                '"' => out.push('"'),
                '\\' => out.push('\\'),
                '/' => out.push('/'),
                'b' => out.push('\x08'),
                'f' => out.push('\x0c'),
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                'u' => {
                    let code1 = parse_hex4(chars, pos)?;
                    if (0xD800..=0xDBFF).contains(&code1) {
                        // UTF-16 surrogate pair
                        if *pos + 2 <= chars.len() && chars[*pos] == '\\' && chars[*pos + 1] == 'u'
                        {
                            *pos += 2;
                            let code2 = parse_hex4(chars, pos)?;
                            let combined = 0x10000
                                + (((code1 as u32 - 0xD800) << 10) | (code2 as u32 - 0xDC00));
                            if let Some(c) = char::from_u32(combined) {
                                out.push(c);
                            }
                        }
                    } else if let Some(c) = char::from_u32(code1 as u32) {
                        out.push(c);
                    }
                }
                other => out.push(other),
            }
        } else {
            out.push(ch);
        }
    }
    Err("Unterminated JSON string".to_string())
}

fn parse_hex4(chars: &[char], pos: &mut usize) -> Result<u16, String> {
    if *pos + 4 > chars.len() {
        return Err("Unexpected EOF in \\uXXXX escape".to_string());
    }
    let s: String = chars[*pos..*pos + 4].iter().collect();
    *pos += 4;
    u16::from_str_radix(&s, 16).map_err(|_| format!("Invalid hex escape `\\u{}`", s))
}

fn parse_json_object(chars: &[char], pos: &mut usize) -> Result<JsonValue, String> {
    *pos += 1; // skip '{'
    skip_ws(chars, pos);
    let mut map = HashMap::new();
    if chars.get(*pos) == Some(&'}') {
        *pos += 1;
        return Ok(JsonValue::Object(map));
    }
    loop {
        skip_ws(chars, pos);
        let key = parse_json_string(chars, pos)?;
        skip_ws(chars, pos);
        if chars.get(*pos) != Some(&':') {
            return Err("Expected `:` after object key in JSON".to_string());
        }
        *pos += 1;
        let val = parse_json_value(chars, pos)?;
        map.insert(key, val);
        skip_ws(chars, pos);
        match chars.get(*pos) {
            Some(',') => {
                *pos += 1;
            }
            Some('}') => {
                *pos += 1;
                return Ok(JsonValue::Object(map));
            }
            _ => return Err("Expected `,` or `}` in JSON object".to_string()),
        }
    }
}

fn parse_json_array(chars: &[char], pos: &mut usize) -> Result<JsonValue, String> {
    *pos += 1; // skip '['
    skip_ws(chars, pos);
    let mut arr = Vec::new();
    if chars.get(*pos) == Some(&']') {
        *pos += 1;
        return Ok(JsonValue::Array(arr));
    }
    loop {
        let val = parse_json_value(chars, pos)?;
        arr.push(val);
        skip_ws(chars, pos);
        match chars.get(*pos) {
            Some(',') => {
                *pos += 1;
            }
            Some(']') => {
                *pos += 1;
                return Ok(JsonValue::Array(arr));
            }
            _ => return Err("Expected `,` or `]` in JSON array".to_string()),
        }
    }
}

fn parse_json_bool(chars: &[char], pos: &mut usize) -> Result<JsonValue, String> {
    if chars[*pos..].starts_with(&['t', 'r', 'u', 'e']) {
        *pos += 4;
        Ok(JsonValue::Bool(true))
    } else if chars[*pos..].starts_with(&['f', 'a', 'l', 's', 'e']) {
        *pos += 5;
        Ok(JsonValue::Bool(false))
    } else {
        Err("Invalid boolean token in JSON".to_string())
    }
}

fn parse_json_null(chars: &[char], pos: &mut usize) -> Result<JsonValue, String> {
    if chars[*pos..].starts_with(&['n', 'u', 'l', 'l']) {
        *pos += 4;
        Ok(JsonValue::Null)
    } else {
        Err("Invalid null token in JSON".to_string())
    }
}

fn parse_json_number(chars: &[char], pos: &mut usize) -> Result<JsonValue, String> {
    let start = *pos;
    while *pos < chars.len()
        && matches!(
            chars[*pos],
            '0'..='9' | '-' | '+' | '.' | 'e' | 'E'
        )
    {
        *pos += 1;
    }
    let s: String = chars[start..*pos].iter().collect();
    let n = s
        .parse::<f64>()
        .map_err(|_| format!("Invalid JSON number `{}`", s))?;
    Ok(JsonValue::Number(n))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LlmProvider {
    Gemini { api_key: String, model: String },
    OpenAi { api_key: String, model: String },
    Anthropic { api_key: String, model: String },
}

/// 環境変数および CLI オプションから利用する LLM プロバイダとモデルを解決する
pub fn resolve_llm_provider(
    explicit_api_key: Option<&str>,
    explicit_model: Option<&str>,
) -> Result<LlmProvider, String> {
    let model_env = std::env::var("UK_LLM_MODEL").ok();
    let model_opt = explicit_model.or(model_env.as_deref());

    // 1. 明示的にモデル名からプロバイダが判別できる場合、または対応する環境変数を確認
    if let Some(key) = explicit_api_key.filter(|k| !k.is_empty()) {
        let m = model_opt.unwrap_or("gemini-2.5-flash").to_string();
        if m.starts_with("gpt-") || m.starts_with("o1") || m.starts_with("o3") || m.starts_with("o4") {
            return Ok(LlmProvider::OpenAi {
                api_key: key.to_string(),
                model: m,
            });
        } else if m.starts_with("claude-") {
            return Ok(LlmProvider::Anthropic {
                api_key: key.to_string(),
                model: m,
            });
        } else {
            return Ok(LlmProvider::Gemini {
                api_key: key.to_string(),
                model: m,
            });
        }
    }

    if let Ok(key) = std::env::var("GEMINI_API_KEY").or_else(|_| std::env::var("GOOGLE_API_KEY"))
        && !key.trim().is_empty()
    {
        return Ok(LlmProvider::Gemini {
            api_key: key.trim().to_string(),
            model: model_opt.unwrap_or("gemini-2.5-flash").to_string(),
        });
    }

    if let Ok(key) = std::env::var("OPENAI_API_KEY")
        && !key.trim().is_empty()
    {
        return Ok(LlmProvider::OpenAi {
            api_key: key.trim().to_string(),
            model: model_opt.unwrap_or("gpt-4o").to_string(),
        });
    }

    if let Ok(key) = std::env::var("ANTHROPIC_API_KEY")
        && !key.trim().is_empty()
    {
        return Ok(LlmProvider::Anthropic {
            api_key: key.trim().to_string(),
            model: model_opt
                .unwrap_or("claude-sonnet-4-20250514")
                .to_string(),
        });
    }

    Err(
        "No LLM API key found. Set `GEMINI_API_KEY` (or `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`) environment variable, or pass `--api-key <KEY>`."
            .to_string(),
    )
}

/// LLM の返答テキストから Markdown コードブロック（```ruby ... ```）を除去して純粋な Ruby スクリプトを取り出す
pub fn extract_ruby_code_from_response(raw: &str) -> String {
    let trimmed = raw.trim();

    // ```ruby または ``` で囲まれたブロックがあれば最初のコードブロックを抽出
    let mut in_fence = false;
    let mut fence_lines: Vec<&str> = Vec::new();
    for line in trimmed.lines() {
        let l = line.trim();
        if !in_fence {
            if l.starts_with("```") {
                in_fence = true;
                continue;
            }
        } else if l == "```" {
            break;
        } else {
            fence_lines.push(line);
        }
    }

    if !fence_lines.is_empty() {
        return format!("{}\n", fence_lines.join("\n").trim());
    }

    format!("{}\n", trimmed)
}

/// Usakame ゲーム生成用のシステムプロンプトを構築する
pub fn build_usakame_system_prompt() -> String {
    format!(
        r#"You are an expert retro game developer for the **Usakame (`uk`)** game engine.
Your job is to output a complete, self-contained, playable Usakame Ruby script (`game.rb`) including pixel-art sprites (`@SPRITE`), optional tilemaps (`@MAP`), and sound effects (`@SFX` / `@MUSIC`) in the `__END__` section.

# CRITICAL RULES
1. Output **ONLY** the valid Ruby source code for `game.rb` (with `__END__` resources at the bottom). Do not include explanations outside the code block.
2. Usakame uses **mrubyedge** (a lightweight Ruby VM). Many standard CRuby methods DO NOT EXIST and will crash with `NoMethodError`.
   - NEVER use `array.sample` -> ALWAYS use `array[rand(array.size)]`
   - NEVER use `array.shuffle` -> Implement swap loop manually if needed
   - NEVER use `array.reverse` -> Iterate backwards with `while` loop
   - NEVER use `array.delete(val)` -> ALWAYS use `array.reject! {{ |x| x == val }}` or `array.delete_at(idx)`
   - NEVER use `hash.key?(k)` or `hash.include?(k)` -> ALWAYS use `hash.has_key?(k)`
   - NEVER use `string.gsub` or `string.sub` -> Use `string.split(pat).join(rep)`
   - NEVER use `n.upto(m)` or `n.downto(m)` -> ALWAYS use `(n..m).each` or a `while` loop
   - NEVER use `n.even?` or `n.odd?` -> ALWAYS use `n % 2 == 0` or `n % 2 != 0`
   - NEVER use `Time.now` or `sleep` -> Use a frame counter `$frame += 1` inside `update` (60 FPS)
   - NEVER use `require`, `load`, or `eval`
   - NEVER use `Struct.new` or `attr_accessor` if simple Hashes (`{{ x: 10, y: 20, vx: 1.0 }}`) or global state variables work cleanly. (Hashes with symbol keys are fast, idiomatic, and hot-reload friendly in Usakame!)
3. Tilemap (`mget` / `mset` / `mdel`) rules:
   - `mget(x, y)` returns `nil` for empty cells (NOT `-1`!).
   - Check if a tile exists with `if mget(x, y)`.
   - Erase a tile with `mdel(x, y)` or `mset(x, y, nil)` (NEVER pass `-1` to `mset`, which raises `ArgumentError`).
4. Make the game immediately fun and playable!
   - Include a title / start state OR start immediately in gameplay with clear on-screen controls (e.g. `ARROWS: MOVE  Z: JUMP/SHOOT`) and score/HP display.
   - Include custom 16x16 pixel-art `@SPRITE` definitions (using hex colors `0`..`F` and `.` for transparent) AND/OR emoji sprites (`spr("🐰", x, y)`).
   - Include `@SFX` sound effects (or preset `sfx(:jump)`, `sfx(:coin)`, `sfx(:boom)`, `sfx(:hit)`, `sfx(:select)`) so actions feel responsive.

---
# USAKAME ENGINE API REFERENCE
{api_md}

---
# MRUBYEDGE SUPPORTED METHODS REFERENCE
{mruby_md}
"#,
        api_md = EMBEDDED_API_MD,
        mruby_md = EMBEDDED_MRUBYEDGE_API_MD,
    )
}

/// Gemini / OpenAI / Anthropic の JSON リクエストペイロードを構築する
pub fn build_api_request_json(
    provider: &LlmProvider,
    system_prompt: &str,
    conversation: &[(String, String)],
) -> String {
    match provider {
        LlmProvider::Gemini { .. } => {
            let mut contents_items = Vec::new();
            for (role, text) in conversation {
                let gemini_role = if role == "assistant" || role == "model" {
                    "model"
                } else {
                    "user"
                };
                contents_items.push(format!(
                    r#"{{"role":{},"parts":[{{"text":{}}}]}}"#,
                    to_json_string_literal(gemini_role),
                    to_json_string_literal(text)
                ));
            }
            format!(
                r#"{{"system_instruction":{{"parts":[{{"text":{}}}]}},"contents":[{}],"generationConfig":{{"temperature":0.7}}}}"#,
                to_json_string_literal(system_prompt),
                contents_items.join(",")
            )
        }
        LlmProvider::OpenAi { model, .. } => {
            let mut messages = Vec::new();
            messages.push(format!(
                r#"{{"role":"system","content":{}}}"#,
                to_json_string_literal(system_prompt)
            ));
            for (role, text) in conversation {
                let oa_role = if role == "model" || role == "assistant" {
                    "assistant"
                } else {
                    "user"
                };
                messages.push(format!(
                    r#"{{"role":{},"content":{}}}"#,
                    to_json_string_literal(oa_role),
                    to_json_string_literal(text)
                ));
            }
            format!(
                r#"{{"model":{},"messages":[{}]}}"#,
                to_json_string_literal(model),
                messages.join(",")
            )
        }
        LlmProvider::Anthropic { model, .. } => {
            let mut messages = Vec::new();
            for (role, text) in conversation {
                let anth_role = if role == "model" || role == "assistant" {
                    "assistant"
                } else {
                    "user"
                };
                messages.push(format!(
                    r#"{{"role":{},"content":{}}}"#,
                    to_json_string_literal(anth_role),
                    to_json_string_literal(text)
                ));
            }
            format!(
                r#"{{"model":{},"max_tokens":8192,"system":{},"messages":[{}]}}"#,
                to_json_string_literal(model),
                to_json_string_literal(system_prompt),
                messages.join(",")
            )
        }
    }
}

/// API レスポンス JSON からアシスタントのテキスト応答を抽出する
pub fn parse_api_response_json(provider: &LlmProvider, raw_json: &str) -> Result<String, String> {
    let parsed = parse_json(raw_json)
        .map_err(|e| format!("Failed to parse LLM JSON response: {}\nRaw: {}", e, raw_json))?;

    if let Some(err_obj) = parsed.get("error") {
        let msg = err_obj
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("Unknown API error");
        return Err(format!("LLM API returned error: {}", msg));
    }

    match provider {
        LlmProvider::Gemini { .. } => {
            let parts = parsed
                .get("candidates")
                .and_then(|c| c.index(0))
                .and_then(|c0| c0.get("content"))
                .and_then(|cnt| cnt.get("parts"))
                .ok_or_else(|| format!("Unexpected Gemini response structure: {}", raw_json))?;
            if let JsonValue::Array(arr) = parts {
                let mut combined = String::new();
                for p in arr {
                    if let Some(t) = p.get("text").and_then(|v| v.as_str()) {
                        combined.push_str(t);
                    }
                }
                if !combined.is_empty() {
                    return Ok(combined);
                }
            }
            Err(format!("No text found in Gemini response: {}", raw_json))
        }
        LlmProvider::OpenAi { .. } => parsed
            .get("choices")
            .and_then(|c| c.index(0))
            .and_then(|c0| c0.get("message"))
            .and_then(|m| m.get("content"))
            .and_then(|t| t.as_str())
            .map(String::from)
            .ok_or_else(|| format!("Unexpected OpenAI response structure: {}", raw_json)),
        LlmProvider::Anthropic { .. } => parsed
            .get("content")
            .and_then(|c| c.index(0))
            .and_then(|c0| c0.get("text"))
            .and_then(|t| t.as_str())
            .map(String::from)
            .ok_or_else(|| format!("Unexpected Anthropic response structure: {}", raw_json)),
    }
}

/// OS 標準の `curl` を用いて LLM REST API を呼び出す
pub fn call_llm_http_api(
    provider: &LlmProvider,
    system_prompt: &str,
    conversation: &[(String, String)],
) -> Result<String, String> {
    let req_json = build_api_request_json(provider, system_prompt, conversation);
    let temp_req_path =
        std::env::temp_dir().join(format!("uk_llm_req_{}.json", std::process::id()));
    fs::write(&temp_req_path, &req_json)
        .map_err(|e| format!("Failed to write temporary request payload: {}", e))?;

    let req_file_arg = format!("@{}", temp_req_path.to_string_lossy());
    let curl_bin = if cfg!(windows) { "curl.exe" } else { "curl" };

    let mut cmd = Command::new(curl_bin);
    cmd.args(["-sS", "-X", "POST", "-H", "Content-Type: application/json"]);

    match provider {
        LlmProvider::Gemini { api_key, model } => {
            let url = format!(
                "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent?key={}",
                model, api_key
            );
            cmd.arg(url);
        }
        LlmProvider::OpenAi { api_key, .. } => {
            cmd.args([
                "-H",
                &format!("Authorization: Bearer {}", api_key),
                "https://api.openai.com/v1/chat/completions",
            ]);
        }
        LlmProvider::Anthropic { api_key, .. } => {
            cmd.args([
                "-H",
                &format!("x-api-key: {}", api_key),
                "-H",
                "anthropic-version: 2023-06-01",
                "https://api.anthropic.com/v1/messages",
            ]);
        }
    }

    cmd.args(["--data-binary", &req_file_arg]);

    let output = cmd.output();
    let _ = fs::remove_file(&temp_req_path);

    let output =
        output.map_err(|e| format!("Failed to execute `{}` for LLM API call: {}", curl_bin, e))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("curl failed ({}): {}", output.status, stderr));
    }

    let resp_body = String::from_utf8_lossy(&output.stdout).to_string();
    parse_api_response_json(provider, &resp_body)
}

/// ユーザープロンプトから `game.rb` を生成し、コンパイルおよびヘッドレス60フレーム実行検証を行い、
/// エラーがあれば自動でエラー内容をフィードバックして自己修復リトライする。
pub fn generate_verified_game_rb_with_backend<F>(
    user_prompt: &str,
    project_title: &str,
    mut call_backend: F,
) -> Result<(String, usize), String>
where
    F: FnMut(&[(String, String)]) -> Result<String, String>,
{
    let initial_user_msg = format!(
        "Create a complete, fun, playable Usakame game (`game.rb`) titled \"{}\" based on the following request:\n\n{}\n\nRemember: Output ONLY the valid Ruby code for `game.rb` (including `__END__` resources if needed), strictly following all mrubyedge rules.",
        project_title, user_prompt
    );

    let mut conversation: Vec<(String, String)> = vec![("user".to_string(), initial_user_msg)];
    let mut last_error = String::new();

    for attempt in 1..=MAX_LLM_ATTEMPTS {
        let raw_response = call_backend(&conversation)?;
        let candidate_code = extract_ruby_code_from_response(&raw_response);

        match crate::verify_ruby_script_headless(&candidate_code, 60) {
            Ok(()) => {
                return Ok((candidate_code, attempt));
            }
            Err(verify_err) => {
                last_error = verify_err.clone();
                if attempt < MAX_LLM_ATTEMPTS {
                    eprintln!(
                        "  [AI Self-Check] Attempt {}/{} caught an error; auto-fixing...\n  -> {}",
                        attempt,
                        MAX_LLM_ATTEMPTS,
                        verify_err.lines().next().unwrap_or(&verify_err)
                    );
                    conversation.push(("model".to_string(), raw_response));
                    let fix_prompt = format!(
                        "The generated `game.rb` failed verification with the following error in Usakame (mrubyedge):\n\n```\n{}\n```\n\nPlease fix this error and output the complete, corrected `game.rb` script. Remember all mrubyedge method restrictions (no `.sample`, `.shuffle`, `.reverse`, `.delete(val)`, `Hash#key?`, `String#gsub`, `upto`/`downto`, `even?`/`odd?`, and `mget` returns `nil` for empty cells).",
                        verify_err
                    );
                    conversation.push(("user".to_string(), fix_prompt));
                }
            }
        }
    }

    Err(format!(
        "Generated code failed verification after {} attempts. Last error:\n{}",
        MAX_LLM_ATTEMPTS, last_error
    ))
}

/// 実際の LLM プロバイダを用いて `game.rb` を生成・検証する
pub fn generate_verified_game_rb(
    user_prompt: &str,
    project_title: &str,
    explicit_api_key: Option<&str>,
    explicit_model: Option<&str>,
) -> Result<(String, usize), String> {
    let provider = resolve_llm_provider(explicit_api_key, explicit_model)?;
    let model_name = match &provider {
        LlmProvider::Gemini { model, .. } => format!("Gemini ({})", model),
        LlmProvider::OpenAi { model, .. } => format!("OpenAI ({})", model),
        LlmProvider::Anthropic { model, .. } => format!("Anthropic ({})", model),
    };
    println!(
        "🤖 Generating game with {} from prompt: \"{}\"...",
        model_name, user_prompt
    );

    let system_prompt = build_usakame_system_prompt();
    generate_verified_game_rb_with_backend(user_prompt, project_title, |conv| {
        call_llm_http_api(&provider, &system_prompt, conv)
    })
}
