use crossbeam_channel::{bounded, Sender};
use regex::{Regex, RegexSet};
use serde_json::{Map, Value};
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::thread::{self, JoinHandle};
use zeroize::{Zeroize, Zeroizing};

#[derive(Default)]
pub struct Config {
    pub threshold: Option<f64>,
    pub disabled_rules: Vec<String>,
    pub allowed_hashes: Vec<String>,
}

#[derive(Default)]
pub struct Context {
    pub title: String,
    pub path: String,
    pub app: String,
    pub ocr: bool,
}

impl Config {
    pub fn from_json(json: &str) -> Result<Self, String> {
        let object = object(json)?;
        let threshold = match object.get("threshold") {
            None | Some(Value::Null) => None,
            Some(value) => Some(value.as_f64().ok_or("threshold must be a number")?),
        };
        Ok(Self {
            threshold,
            disabled_rules: strings(&object, "disabled_rules")?,
            allowed_hashes: strings(&object, "allowed_hashes")?,
        })
    }
}

impl Context {
    fn from_json(json: &str) -> Result<Self, String> {
        let mut object = object(json)?;
        let title = take_string(&mut object, "title")?;
        let path = take_string(&mut object, "path")?;
        let app = take_string(&mut object, "app")?;
        let ocr = match object.get("ocr") {
            None => false,
            Some(value) => value.as_bool().ok_or("ocr must be a boolean")?,
        };
        Ok(Self {
            title,
            path,
            app,
            ocr,
        })
    }
}

fn object(json: &str) -> Result<Map<String, Value>, String> {
    match serde_json::from_str(json).map_err(|e| e.to_string())? {
        Value::Object(object) => Ok(object),
        _ => Err("expected a JSON object".into()),
    }
}

fn strings(object: &Map<String, Value>, field: &str) -> Result<Vec<String>, String> {
    let Some(value) = object.get(field) else {
        return Ok(Vec::new());
    };
    let array = value
        .as_array()
        .ok_or_else(|| format!("{field} must be an array"))?;
    array
        .iter()
        .map(|v| {
            v.as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("{field} must contain strings"))
        })
        .collect()
}

fn take_string(object: &mut Map<String, Value>, field: &str) -> Result<String, String> {
    match object.remove(field) {
        None => Ok(String::new()),
        Some(Value::String(value)) => Ok(value),
        _ => Err(format!("{field} must be a string")),
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        self.title.zeroize();
        self.path.zeroize();
        self.app.zeroize();
    }
}

#[derive(Debug)]
pub struct Finding {
    pub start: usize,
    pub end: usize,
    pub rule: String,
    pub score: f64,
    pub hash: String,
}

struct Rule {
    id: &'static str,
    pattern: &'static str,
    score: f64,
    entropy: bool,
}

fn rules() -> Vec<Rule> {
    vec![
        Rule {
            id: "aws-access-key",
            pattern: r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
            score: 1.0,
            entropy: false,
        },
        Rule {
            id: "github-token",
            pattern: r"\b(?:gh[pousr]_[A-Za-z0-9]*|github_pat_[A-Za-z0-9_]*)",
            score: 1.0,
            entropy: false,
        },
        Rule {
            id: "stripe-key",
            pattern: r"\b(?:sk|rk)_live_[A-Za-z0-9]*",
            score: 1.0,
            entropy: false,
        },
        Rule {
            id: "slack-token",
            pattern: r"\bxox[baprs]-[A-Za-z0-9-]+",
            score: 1.0,
            entropy: false,
        },
        Rule {
            id: "google-api-key",
            pattern: r"\bAIza[A-Za-z0-9_-]{20,}",
            score: 0.98,
            entropy: false,
        },
        Rule {
            id: "anthropic-key",
            pattern: r"\bsk-ant-[A-Za-z0-9_-]+",
            score: 1.0,
            entropy: false,
        },
        Rule {
            id: "openai-key",
            pattern: r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}",
            score: 0.97,
            entropy: false,
        },
        Rule {
            id: "private-key",
            pattern: r"(?s:-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----)",
            score: 1.0,
            entropy: false,
        },
        Rule {
            id: "jwt",
            pattern: r"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{8,}",
            score: 0.9,
            entropy: false,
        },
        Rule {
            id: "database-password",
            pattern: r#"(?i:\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^\s:/@]+:(?P<value>[^\s/@]+)@[^\s]+)"#,
            score: 0.97,
            entropy: false,
        },
        Rule {
            id: "generic-secret",
            pattern: r#"(?i:\b[A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD)[A-Z0-9_]*\s*[=:]\s*[\"']?(?P<value>[A-Za-z0-9_./+~=-]{16,}))"#,
            score: 0.76,
            entropy: true,
        },
    ]
}

pub struct Matcher {
    config: Config,
    rules: Vec<Rule>,
    set: RegexSet,
    regexes: Vec<Regex>,
    key: Zeroizing<[u8; 32]>,
}

impl Matcher {
    pub fn new(config: Config, key: [u8; 32]) -> Result<Self, String> {
        if config
            .threshold
            .is_some_and(|n| !n.is_finite() || !(0.0..=1.0).contains(&n))
        {
            return Err("threshold must be between 0 and 1".into());
        }
        let rules = rules();
        let patterns: Vec<_> = rules.iter().map(|r| r.pattern).collect();
        let set = RegexSet::new(&patterns).map_err(|e| e.to_string())?;
        let regexes = patterns
            .iter()
            .map(|p| Regex::new(p))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        Ok(Self {
            config,
            rules,
            set,
            regexes,
            key: Zeroizing::new(key),
        })
    }

    pub fn hash(&self, value: &str) -> String {
        blake3::keyed_hash(&self.key, value.as_bytes())
            .to_hex()
            .to_string()
    }

    pub fn scan(&self, text: &str, context: &Context) -> Vec<Finding> {
        let mut findings = Vec::new();
        for i in self.set.matches(text).iter() {
            let rule = &self.rules[i];
            if self.config.disabled_rules.iter().any(|id| id == rule.id) {
                continue;
            }
            for cap in self.regexes[i].captures_iter(text) {
                let Some(value) = cap.name("value").or_else(|| cap.get(0)) else {
                    continue;
                };
                if rule.entropy && entropy(value.as_str()) < 3.5 {
                    continue;
                }
                let hash = self.hash(value.as_str());
                if self.config.allowed_hashes.contains(&hash) {
                    continue;
                }
                let mut score = rule.score;
                if rule.entropy {
                    let title = context.title.to_lowercase();
                    if title.contains(".env")
                        || title.contains("secret")
                        || context.path.ends_with(".env")
                    {
                        score += 0.1;
                    }
                    if is_hex_digest(value.as_str()) {
                        score -= 0.3;
                    }
                }
                score = score.clamp(0.0, 1.0);
                if score < self.config.threshold.unwrap_or(0.65) {
                    continue;
                }
                findings.push(Finding {
                    start: value.start(),
                    end: value.end(),
                    rule: rule.id.into(),
                    score,
                    hash,
                });
            }
        }
        findings.sort_by(|a, b| {
            a.start
                .cmp(&b.start)
                .then(b.end.cmp(&a.end))
                .then(b.score.total_cmp(&a.score))
        });
        let mut result: Vec<Finding> = Vec::new();
        for finding in findings {
            if result
                .last()
                .is_some_and(|previous| previous.end >= finding.end)
            {
                continue;
            }
            result.push(finding);
        }
        result
    }
}

fn entropy(value: &str) -> f64 {
    let mut counts = [0usize; 256];
    for byte in value.bytes() {
        counts[byte as usize] += 1;
    }
    counts
        .iter()
        .filter(|&&n| n > 0)
        .map(|&n| {
            let p = n as f64 / value.len() as f64;
            -p * p.log2()
        })
        .sum()
}

fn is_hex_digest(value: &str) -> bool {
    matches!(value.len(), 32 | 40 | 64 | 128) && value.bytes().all(|b| b.is_ascii_hexdigit())
}

enum Request {
    Scan(Zeroizing<String>, Context, Sender<Vec<Finding>>),
    Hash(Zeroizing<String>, Sender<String>),
}

pub struct Engine {
    sender: Option<Sender<Request>>,
    worker: Option<JoinHandle<()>>,
}

impl Engine {
    fn new(matcher: Matcher) -> Result<Self, String> {
        let (sender, receiver) = bounded::<Request>(8);
        let worker = thread::Builder::new()
            .name("veil-matcher".into())
            .spawn(move || {
                while let Ok(request) = receiver.recv() {
                    match request {
                        Request::Scan(text, context, reply) => {
                            let _ = reply.send(matcher.scan(&text, &context));
                        }
                        Request::Hash(text, reply) => {
                            let _ = reply.send(matcher.hash(&text));
                        }
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        Ok(Self {
            sender: Some(sender),
            worker: Some(worker),
        })
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.sender.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

unsafe fn input(pointer: *const c_char) -> Result<Zeroizing<String>, String> {
    if pointer.is_null() {
        return Err("null input".into());
    }
    let value = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|_| "input must be UTF-8")?;
    Ok(Zeroizing::new(value.to_owned()))
}

fn output(value: String) -> *mut c_char {
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

fn json_error(message: &str) -> *mut c_char {
    output(serde_json::json!({"error": message, "matches": []}).to_string())
}

#[no_mangle]
pub unsafe extern "C" fn veil_engine_new(config: *const c_char, key: *const u8) -> *mut Engine {
    catch_unwind(AssertUnwindSafe(|| {
        if key.is_null() {
            return ptr::null_mut();
        }
        let Ok(json) = (unsafe { input(config) }) else {
            return ptr::null_mut();
        };
        let Ok(config) = Config::from_json(&json) else {
            return ptr::null_mut();
        };
        let mut bytes = Zeroizing::new([0u8; 32]);
        bytes.copy_from_slice(unsafe { std::slice::from_raw_parts(key, 32) });
        match Matcher::new(config, *bytes).and_then(Engine::new) {
            Ok(engine) => Box::into_raw(Box::new(engine)),
            Err(_) => ptr::null_mut(),
        }
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn veil_config_validate(config: *const c_char) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let result = unsafe { input(config) }
            .and_then(|json| Config::from_json(&json))
            .and_then(|config| Matcher::new(config, [0; 32]));
        match result {
            Ok(_) => output(serde_json::json!({"valid": true}).to_string()),
            Err(error) => output(serde_json::json!({"valid": false, "error": error}).to_string()),
        }
    }))
    .unwrap_or_else(|_| json_error("validation failed"))
}

#[no_mangle]
pub unsafe extern "C" fn veil_engine_scan(
    engine: *const Engine,
    text: *const c_char,
    context: *const c_char,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(engine) = (unsafe { engine.as_ref() }) else {
            return json_error("null engine");
        };
        let result = (|| {
            let text = unsafe { input(text) }?;
            let context = if context.is_null() {
                Context::default()
            } else {
                Context::from_json(&unsafe { input(context) }?)?
            };
            let (sender, receiver) = bounded(1);
            engine
                .sender
                .as_ref()
                .ok_or("engine stopped")?
                .send(Request::Scan(text, context, sender))
                .map_err(|_| "engine stopped")?;
            receiver.recv().map_err(|_| "engine stopped".to_string())
        })();
        match result {
            Ok(matches) => {
                let matches: Vec<_> = matches.into_iter().map(|m| serde_json::json!({
                    "start": m.start, "end": m.end, "rule": m.rule, "score": m.score, "hash": m.hash
                })).collect();
                output(serde_json::json!({"matches": matches}).to_string())
            }
            Err(error) => json_error(&error),
        }
    }))
    .unwrap_or_else(|_| json_error("scan failed"))
}

#[no_mangle]
pub unsafe extern "C" fn veil_engine_hash(
    engine: *const Engine,
    text: *const c_char,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(engine) = (unsafe { engine.as_ref() }) else {
            return ptr::null_mut();
        };
        let Ok(text) = (unsafe { input(text) }) else {
            return ptr::null_mut();
        };
        let (sender, receiver) = bounded(1);
        if engine
            .sender
            .as_ref()
            .is_none_or(|s| s.send(Request::Hash(text, sender)).is_err())
        {
            return ptr::null_mut();
        }
        receiver.recv().map(output).unwrap_or(ptr::null_mut())
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn veil_engine_free(engine: *mut Engine) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn veil_string_free(value: *mut c_char) {
    if !value.is_null() {
        let mut bytes = unsafe { CString::from_raw(value) }.into_bytes_with_nul();
        bytes.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matcher() -> Matcher {
        Matcher::new(Config::default(), [7; 32]).unwrap()
    }

    #[test]
    fn known_keys_and_unicode_byte_ranges() {
        let text = "中文 ghp_abcdefghijklmnopqrstuvwxyz1234567890";
        let result = matcher().scan(text, &Context::default());
        assert_eq!(result.len(), 1);
        assert_eq!(
            &text[result[0].start..result[0].end],
            "ghp_abcdefghijklmnopqrstuvwxyz1234567890"
        );
        assert_eq!(result[0].start, 7);
    }

    #[test]
    fn assignments_mask_only_high_entropy_values() {
        let text = "API_KEY = AbCdEfGh1234_XyZ98qR\nPASSWORD=aaaaaaaaaaaaaaaaaaaaaaaa";
        let result = matcher().scan(text, &Context::default());
        assert_eq!(result.len(), 1);
        assert_eq!(
            &text[result[0].start..result[0].end],
            "AbCdEfGh1234_XyZ98qR"
        );
    }

    #[test]
    fn prefixes_are_caught_while_typing() {
        assert_eq!(
            matcher().scan("ghp_ sk_live_", &Context::default()).len(),
            2
        );
    }

    #[test]
    fn database_credentials_are_isolated() {
        let text = "postgres://user:p4ssword@localhost/database";
        let result = matcher().scan(text, &Context::default());
        assert_eq!(&text[result[0].start..result[0].end], "p4ssword");
    }

    #[test]
    fn hashes_depend_on_install_key() {
        let a = matcher();
        let b = Matcher::new(Config::default(), [8; 32]).unwrap();
        assert_eq!(a.hash("same"), a.hash("same"));
        assert_ne!(a.hash("same"), b.hash("same"));
    }

    #[test]
    fn ffi_roundtrip_and_invalid_config() {
        unsafe {
            let config = CString::new("{}").unwrap();
            let engine = veil_engine_new(config.as_ptr(), [7; 32].as_ptr());
            assert!(!engine.is_null());
            let text = CString::new("ghp_example").unwrap();
            let result = veil_engine_scan(engine, text.as_ptr(), ptr::null());
            let json: serde_json::Value =
                serde_json::from_str(CStr::from_ptr(result).to_str().unwrap()).unwrap();
            assert_eq!(json["matches"][0]["rule"], "github-token");
            assert!(json["matches"][0].get("value").is_none());
            veil_string_free(result);
            veil_engine_free(engine);
            let invalid = CString::new(r#"{"threshold":2}"#).unwrap();
            assert!(veil_engine_new(invalid.as_ptr(), [7; 32].as_ptr()).is_null());
        }
    }
}
