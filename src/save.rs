use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

/// セーブデータとして保持可能な JSON 互換値
#[derive(Debug, Clone, PartialEq)]
pub enum SaveValue {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(String),
    Array(Vec<SaveValue>),
    Object(BTreeMap<String, SaveValue>),
}

impl SaveValue {
    pub fn to_json_string(&self) -> String {
        let mut out = String::new();
        self.write_json(&mut out);
        out
    }

    fn write_json(&self, out: &mut String) {
        match self {
            SaveValue::Null => out.push_str("null"),
            SaveValue::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            SaveValue::Int(n) => out.push_str(&n.to_string()),
            SaveValue::Float(f) => {
                if f.is_finite() {
                    let s = f.to_string();
                    out.push_str(&s);
                    if !s.contains('.') && !s.contains('e') && !s.contains('E') {
                        out.push_str(".0");
                    }
                } else {
                    out.push_str("null");
                }
            }
            SaveValue::String(s) => write_json_string(s, out),
            SaveValue::Array(arr) => {
                out.push('[');
                for (i, item) in arr.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write_json(out);
                }
                out.push(']');
            }
            SaveValue::Object(map) => {
                out.push('{');
                for (i, (k, v)) in map.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_json_string(k, out);
                    out.push(':');
                    v.write_json(out);
                }
                out.push('}');
            }
        }
    }

    pub fn from_json_str(input: &str) -> Result<Self, String> {
        let mut parser = JsonParser::new(input);
        let val = parser.parse_value(0)?;
        parser.skip_ws();
        if !parser.is_eof() {
            return Err(format!("Unexpected trailing characters at byte {}", parser.pos));
        }
        Ok(val)
    }
}

fn write_json_string(s: &str, out: &mut String) {
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
}

struct JsonParser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> JsonParser<'a> {
    fn new(input: &'a str) -> Self {
        Self {
            bytes: input.as_bytes(),
            pos: 0,
        }
    }

    fn is_eof(&self) -> bool {
        self.pos >= self.bytes.len()
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn next_byte(&mut self) -> Option<u8> {
        let b = self.peek()?;
        self.pos += 1;
        Some(b)
    }

    fn skip_ws(&mut self) {
        while let Some(b) = self.peek() {
            if matches!(b, b' ' | b'\t' | b'\n' | b'\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn parse_value(&mut self, depth: usize) -> Result<SaveValue, String> {
        if depth > 64 {
            return Err("JSON nesting too deep".to_string());
        }
        self.skip_ws();
        let b = self.peek().ok_or_else(|| "Unexpected end of JSON".to_string())?;
        match b {
            b'n' => self.parse_null(),
            b't' | b'f' => self.parse_bool(),
            b'"' => self.parse_string().map(SaveValue::String),
            b'[' => self.parse_array(depth + 1),
            b'{' => self.parse_object(depth + 1),
            b'-' | b'0'..=b'9' => self.parse_number(),
            _ => Err(format!("Unexpected byte '{}' at {}", b as char, self.pos)),
        }
    }

    fn parse_null(&mut self) -> Result<SaveValue, String> {
        if self.bytes[self.pos..].starts_with(b"null") {
            self.pos += 4;
            Ok(SaveValue::Null)
        } else {
            Err(format!("Invalid literal at {}", self.pos))
        }
    }

    fn parse_bool(&mut self) -> Result<SaveValue, String> {
        if self.bytes[self.pos..].starts_with(b"true") {
            self.pos += 4;
            Ok(SaveValue::Bool(true))
        } else if self.bytes[self.pos..].starts_with(b"false") {
            self.pos += 5;
            Ok(SaveValue::Bool(false))
        } else {
            Err(format!("Invalid boolean at {}", self.pos))
        }
    }

    fn parse_string(&mut self) -> Result<String, String> {
        if self.next_byte() != Some(b'"') {
            return Err(format!("Expected '\"' at {}", self.pos));
        }
        let mut out = String::new();
        while let Some(b) = self.next_byte() {
            match b {
                b'"' => return Ok(out),
                b'\\' => {
                    let esc = self
                        .next_byte()
                        .ok_or_else(|| "Unterminated escape sequence".to_string())?;
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\x08'),
                        b'f' => out.push('\x0c'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let code = self.parse_hex4()?;
                            if (0xD800..=0xDBFF).contains(&code) {
                                if self.bytes.get(self.pos..self.pos + 2) == Some(b"\\u") {
                                    self.pos += 2;
                                    let low = self.parse_hex4()?;
                                    if (0xDC00..=0xDFFF).contains(&low) {
                                        let combined =
                                            0x10000 + (((code - 0xD800) << 10) | (low - 0xDC00));
                                        let ch = char::from_u32(combined).ok_or_else(|| {
                                            "Invalid unicode surrogate pair".to_string()
                                        })?;
                                        out.push(ch);
                                    } else {
                                        return Err("Invalid low surrogate".to_string());
                                    }
                                } else {
                                    return Err("Missing low surrogate".to_string());
                                }
                            } else {
                                let ch = char::from_u32(code)
                                    .ok_or_else(|| "Invalid unicode code point".to_string())?;
                                out.push(ch);
                            }
                        }
                        other => return Err(format!("Invalid escape '\\{}'", other as char)),
                    }
                }
                c if c < 0x80 => out.push(c as char),
                c => {
                    let start = self.pos - 1;
                    let width = if c & 0b1110_0000 == 0b1100_0000 {
                        2
                    } else if c & 0b1111_0000 == 0b1110_0000 {
                        3
                    } else if c & 0b1111_1000 == 0b1111_0000 {
                        4
                    } else {
                        return Err(format!("Invalid UTF-8 byte at {}", start));
                    };
                    let end = start + width;
                    if end > self.bytes.len() {
                        return Err("Truncated UTF-8 sequence".to_string());
                    }
                    let slice = std::str::from_utf8(&self.bytes[start..end])
                        .map_err(|_| "Invalid UTF-8 sequence".to_string())?;
                    out.push_str(slice);
                    self.pos = end;
                }
            }
        }
        Err("Unterminated string".to_string())
    }

    fn parse_hex4(&mut self) -> Result<u32, String> {
        if self.pos + 4 > self.bytes.len() {
            return Err("Incomplete \\uXXXX escape".to_string());
        }
        let s = std::str::from_utf8(&self.bytes[self.pos..self.pos + 4])
            .map_err(|_| "Invalid hex escape".to_string())?;
        self.pos += 4;
        u32::from_str_radix(s, 16).map_err(|_| format!("Invalid hex digits '{}'", s))
    }

    fn parse_number(&mut self) -> Result<SaveValue, String> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        let mut is_float = false;
        let digit_start = self.pos;
        while let Some(b) = self.peek() {
            if b.is_ascii_digit() {
                self.pos += 1;
            } else {
                break;
            }
        }
        if self.pos == digit_start {
            return Err(format!("Invalid number at {}", start));
        }
        if self.peek() == Some(b'.') {
            is_float = true;
            self.pos += 1;
            let frac_start = self.pos;
            while let Some(b) = self.peek() {
                if b.is_ascii_digit() {
                    self.pos += 1;
                } else {
                    break;
                }
            }
            if self.pos == frac_start {
                return Err(format!("Invalid fraction at {}", start));
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            is_float = true;
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            let exp_start = self.pos;
            while let Some(b) = self.peek() {
                if b.is_ascii_digit() {
                    self.pos += 1;
                } else {
                    break;
                }
            }
            if self.pos == exp_start {
                return Err(format!("Invalid exponent at {}", start));
            }
        }
        let num_str = std::str::from_utf8(&self.bytes[start..self.pos])
            .map_err(|_| "Invalid UTF-8 in number".to_string())?;
        if is_float {
            let f = num_str
                .parse::<f64>()
                .map_err(|_| format!("Invalid float '{}'", num_str))?;
            Ok(SaveValue::Float(f))
        } else if let Ok(i) = num_str.parse::<i64>() {
            Ok(SaveValue::Int(i))
        } else {
            let f = num_str
                .parse::<f64>()
                .map_err(|_| format!("Invalid integer '{}'", num_str))?;
            Ok(SaveValue::Float(f))
        }
    }

    fn parse_array(&mut self, depth: usize) -> Result<SaveValue, String> {
        self.pos += 1; // '['
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(SaveValue::Array(items));
        }
        loop {
            items.push(self.parse_value(depth)?);
            self.skip_ws();
            match self.next_byte() {
                Some(b',') => continue,
                Some(b']') => return Ok(SaveValue::Array(items)),
                _ => return Err(format!("Expected ',' or ']' at {}", self.pos)),
            }
        }
    }

    fn parse_object(&mut self, depth: usize) -> Result<SaveValue, String> {
        self.pos += 1; // '{'
        let mut map = BTreeMap::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(SaveValue::Object(map));
        }
        loop {
            self.skip_ws();
            let key = self.parse_string()?;
            self.skip_ws();
            if self.next_byte() != Some(b':') {
                return Err(format!("Expected ':' at {}", self.pos));
            }
            let val = self.parse_value(depth)?;
            map.insert(key, val);
            self.skip_ws();
            match self.next_byte() {
                Some(b',') => continue,
                Some(b'}') => return Ok(SaveValue::Object(map)),
                _ => return Err(format!("Expected ',' or '}}' at {}", self.pos)),
            }
        }
    }
}

fn fnv1a_64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

/// セーブID / ソルトをファイル名・localStorageキー向けに安全な文字列へ正規化する
pub fn sanitize_id_part(raw: &str) -> String {
    let trimmed = raw.trim();
    let mut out = String::new();
    let mut prev_underscore = false;
    let mut has_non_ascii_or_unsafe = false;
    for ch in trimmed.chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            out.push(ch);
            prev_underscore = false;
        } else {
            has_non_ascii_or_unsafe = true;
            if !prev_underscore && !out.is_empty() {
                out.push('_');
                prev_underscore = true;
            }
        }
    }
    let out = out.trim_matches('_').to_string();
    if out.is_empty() {
        format!("id_{:08x}", fnv1a_64(trimmed.as_bytes()) as u32)
    } else if has_non_ascii_or_unsafe && !trimmed.is_ascii() {
        format!("{}_{:08x}", out, fnv1a_64(trimmed.as_bytes()) as u32)
    } else {
        out
    }
}

static SALT_COUNTER: AtomicU64 = AtomicU64::new(1);

/// 8桁 hex のランダムな save_salt を生成する
pub fn generate_random_salt() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9e3779b97f4a7c15);
    let pid = std::process::id() as u64;
    let cnt = SALT_COUNTER.fetch_add(1, Ordering::Relaxed);
    let mut x = nanos ^ pid.wrapping_mul(0x9e3779b97f4a7c15) ^ cnt.wrapping_mul(0xbf58476d1ce4e5b9);
    // SplitMix64
    x = (x ^ (x >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94d049bb133111eb);
    x = x ^ (x >> 31);
    format!("{:08x}", (x & 0xffff_ffff) as u32)
}

#[cfg(target_arch = "wasm32")]
unsafe extern "C" {
    fn uk_storage_get_len(key_ptr: *const u8, key_len: usize) -> i32;
    fn uk_storage_get_copy(key_ptr: *const u8, key_len: usize, out_ptr: *mut u8, out_len: usize) -> i32;
    fn uk_storage_set(key_ptr: *const u8, key_len: usize, val_ptr: *const u8, val_len: usize) -> i32;
    fn uk_storage_remove(key_ptr: *const u8, key_len: usize) -> i32;
}

/// 永続セーブデータストア
#[derive(Debug, Clone)]
pub struct SaveStore {
    pub save_id: Option<String>,
    pub save_salt: Option<String>,
    pub headless: bool,
    pub custom_dir: Option<PathBuf>,
    loaded: bool,
    dirty: bool,
    data: BTreeMap<String, SaveValue>,
}

impl SaveStore {
    pub fn new(headless: bool) -> Self {
        Self {
            save_id: None,
            save_salt: None,
            headless,
            custom_dir: None,
            loaded: false,
            dirty: false,
            data: BTreeMap::new(),
        }
    }

    pub fn configure(&mut self, save_id: Option<String>, save_salt: Option<String>) {
        let norm_id = save_id.and_then(|s| {
            let t = s.trim().to_string();
            if t.is_empty() { None } else { Some(t) }
        });
        let norm_salt = save_salt.and_then(|s| {
            let t = s.trim().to_string();
            if t.is_empty() { None } else { Some(t) }
        });
        if self.save_id != norm_id || self.save_salt != norm_salt {
            if self.dirty {
                self.flush_if_dirty();
            }
            self.save_id = norm_id;
            self.save_salt = norm_salt;
            self.loaded = false;
            self.dirty = false;
            self.data.clear();
        }
    }

    pub fn require_configured(&self) -> Result<(String, String), String> {
        match (&self.save_id, &self.save_salt) {
            (Some(id), Some(salt)) if !id.is_empty() && !salt.is_empty() => {
                Ok((sanitize_id_part(id), sanitize_id_part(salt)))
            }
            _ => Err(
                "Save API requires both `save_id` and `save_salt` in `config(...)`. Example: config(save_id: \"my_game\", save_salt: \"a1b2c3d4\") or run `uk save-init`"
                    .to_string(),
            ),
        }
    }

    pub fn storage_key_parts(&self) -> Result<(String, String), String> {
        self.require_configured()
    }

    pub fn resolve_native_path(&self) -> Result<Option<PathBuf>, String> {
        let (id, salt) = self.require_configured()?;
        let base = if let Some(ref dir) = self.custom_dir {
            Some(dir.clone())
        } else if self.headless {
            None
        } else {
            default_save_dir()
        };
        Ok(base.map(|dir| dir.join(format!("{}_{}.json", id, salt))))
    }

    pub fn ensure_loaded(&mut self) -> Result<(), String> {
        let (id, salt) = self.require_configured()?;
        if self.loaded {
            return Ok(());
        }
        self.data.clear();
        if let Some(json_str) = self.read_backend_raw(&id, &salt)? {
            match SaveValue::from_json_str(&json_str) {
                Ok(SaveValue::Object(map)) => {
                    self.data = map;
                }
                Ok(_) => {
                    eprintln!("[save] Ignoring non-object save data for {}_{}", id, salt);
                }
                Err(e) => {
                    eprintln!("[save] Failed to parse save data for {}_{}: {}", id, salt, e);
                }
            }
        }
        self.loaded = true;
        self.dirty = false;
        Ok(())
    }

    pub fn get(&mut self, key: &str) -> Result<Option<SaveValue>, String> {
        self.ensure_loaded()?;
        Ok(self.data.get(key).cloned())
    }

    pub fn set(&mut self, key: &str, val: SaveValue) -> Result<(), String> {
        self.ensure_loaded()?;
        let changed = self.data.get(key) != Some(&val);
        if changed {
            self.data.insert(key.to_string(), val);
            self.dirty = true;
        }
        Ok(())
    }

    pub fn delete(&mut self, key: &str) -> Result<bool, String> {
        self.ensure_loaded()?;
        let removed = self.data.remove(key).is_some();
        if removed {
            self.dirty = true;
        }
        Ok(removed)
    }

    pub fn has_key(&mut self, key: &str) -> Result<bool, String> {
        self.ensure_loaded()?;
        Ok(self.data.contains_key(key))
    }

    pub fn keys(&mut self) -> Result<Vec<String>, String> {
        self.ensure_loaded()?;
        Ok(self.data.keys().cloned().collect())
    }

    pub fn clear(&mut self) -> Result<(), String> {
        self.ensure_loaded()?;
        if !self.data.is_empty() {
            self.data.clear();
            self.dirty = true;
        } else {
            // 空でも既存ファイル/キーを消したいケースに対応
            self.dirty = true;
        }
        Ok(())
    }

    pub fn flush_if_dirty(&mut self) {
        if !self.dirty {
            return;
        }
        let Ok((id, salt)) = self.require_configured() else {
            self.dirty = false;
            return;
        };
        if self.data.is_empty() {
            if let Err(e) = self.remove_backend(&id, &salt) {
                eprintln!("[save] Failed to remove save data: {}", e);
            }
        } else {
            let json = SaveValue::Object(self.data.clone()).to_json_string();
            if let Err(e) = self.write_backend_raw(&id, &salt, &json) {
                eprintln!("[save] Failed to write save data: {}", e);
            }
        }
        self.dirty = false;
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn read_backend_raw(&self, _id: &str, _salt: &str) -> Result<Option<String>, String> {
        let Some(path) = self.resolve_native_path()? else {
            return Ok(None);
        };
        if !path.exists() {
            return Ok(None);
        }
        match std::fs::read_to_string(&path) {
            Ok(text) => Ok(Some(text)),
            Err(e) => {
                eprintln!("[save] Failed to read `{}`: {}", path.display(), e);
                Ok(None)
            }
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn write_backend_raw(&self, _id: &str, _salt: &str, json: &str) -> Result<(), String> {
        let Some(path) = self.resolve_native_path()? else {
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("Failed to create directory `{}`: {}", parent.display(), e))?;
        }
        std::fs::write(&path, json)
            .map_err(|e| format!("Failed to write `{}`: {}", path.display(), e))
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn remove_backend(&self, _id: &str, _salt: &str) -> Result<(), String> {
        let Some(path) = self.resolve_native_path()? else {
            return Ok(());
        };
        if path.exists() {
            std::fs::remove_file(&path)
                .map_err(|e| format!("Failed to remove `{}`: {}", path.display(), e))?;
        }
        Ok(())
    }

    #[cfg(target_arch = "wasm32")]
    fn read_backend_raw(&self, id: &str, salt: &str) -> Result<Option<String>, String> {
        let key = format!("usakame_save:{}:{}", id, salt);
        let key_bytes = key.as_bytes();
        let len = unsafe { uk_storage_get_len(key_bytes.as_ptr(), key_bytes.len()) };
        if len < 0 {
            return Ok(None);
        }
        let mut buf = vec![0u8; len as usize];
        if len > 0 {
            let copied = unsafe {
                uk_storage_get_copy(key_bytes.as_ptr(), key_bytes.len(), buf.as_mut_ptr(), buf.len())
            };
            if copied < 0 {
                return Ok(None);
            }
        }
        match String::from_utf8(buf) {
            Ok(s) => Ok(Some(s)),
            Err(_) => Ok(None),
        }
    }

    #[cfg(target_arch = "wasm32")]
    fn write_backend_raw(&self, id: &str, salt: &str, json: &str) -> Result<(), String> {
        let key = format!("usakame_save:{}:{}", id, salt);
        let key_bytes = key.as_bytes();
        let val_bytes = json.as_bytes();
        let rc = unsafe {
            uk_storage_set(
                key_bytes.as_ptr(),
                key_bytes.len(),
                val_bytes.as_ptr(),
                val_bytes.len(),
            )
        };
        if rc == 0 {
            Ok(())
        } else {
            Err("Failed to write to browser localStorage".to_string())
        }
    }

    #[cfg(target_arch = "wasm32")]
    fn remove_backend(&self, id: &str, salt: &str) -> Result<(), String> {
        let key = format!("usakame_save:{}:{}", id, salt);
        let key_bytes = key.as_bytes();
        let rc = unsafe { uk_storage_remove(key_bytes.as_ptr(), key_bytes.len()) };
        if rc == 0 {
            Ok(())
        } else {
            Err("Failed to remove from browser localStorage".to_string())
        }
    }
}

pub fn default_save_dir() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            return Some(PathBuf::from(appdata).join("usakame").join("saves"));
        }
        if let Some(home) = std::env::var_os("USERPROFILE") {
            return Some(PathBuf::from(home).join(".usakame").join("saves"));
        }
        None
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            return Some(
                PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
                    .join("usakame")
                    .join("saves"),
            );
        }
        None
    }
    #[cfg(all(not(target_os = "windows"), not(target_os = "macos"), not(target_arch = "wasm32")))]
    {
        if let Some(xdg) = std::env::var_os("XDG_DATA_HOME") {
            if !xdg.is_empty() {
                return Some(PathBuf::from(xdg).join("usakame").join("saves"));
            }
        }
        if let Some(home) = std::env::var_os("HOME") {
            return Some(PathBuf::from(home).join(".local").join("share").join("usakame").join("saves"));
        }
        None
    }
    #[cfg(target_arch = "wasm32")]
    {
        None
    }
}
