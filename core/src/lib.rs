use crossbeam_channel::{bounded, Sender};
use regex::{Regex, RegexBuilder, RegexSet, RegexSetBuilder};
use serde_json::{Map, Value};
use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::thread::{self, JoinHandle};
use zeroize::{Zeroize, Zeroizing};

pub struct Config {
    pub threshold: Option<f64>,
    pub known: bool,
    pub generic: bool,
    pub personal: bool,
    pub emails: bool,
    pub phones: bool,
    pub disabled_rules: Vec<String>,
    pub allowed_hashes: Vec<String>,
    pub allowed_paths: Vec<String>,
    custom_rules: Vec<Rule>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            threshold: None,
            known: true,
            generic: true,
            personal: true,
            emails: false,
            phones: false,
            disabled_rules: Vec::new(),
            allowed_hashes: Vec::new(),
            allowed_paths: Vec::new(),
            custom_rules: Vec::new(),
        }
    }
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
        if json.len() > 2_200_000 {
            return Err("configuration is too large".into());
        }
        let object = object(json)?;
        for key in object.keys() {
            if ![
                "threshold",
                "known",
                "generic",
                "personal",
                "emails",
                "phones",
                "disabled_rules",
                "allowed_hashes",
                "allowed_paths",
                "custom_rules",
            ]
            .contains(&key.as_str())
            {
                return Err(format!("unknown configuration field: {key}"));
            }
        }
        let threshold = match object.get("threshold") {
            None | Some(Value::Null) => None,
            Some(value) => Some(score(value, "threshold")?),
        };
        let mut custom_rules = Vec::new();
        if let Some(value) = object.get("custom_rules") {
            let rules = value.as_array().ok_or("custom_rules must be an array")?;
            if rules.len() > 128 {
                return Err("at most 128 custom rules are allowed".into());
            }
            for rule in rules {
                custom_rules.push(Rule::from_value(rule, true)?);
            }
        }
        let allowed_hashes = strings(&object, "allowed_hashes")?;
        if allowed_hashes
            .iter()
            .any(|hash| hash.len() != 64 || !hash.bytes().all(|c| c.is_ascii_hexdigit()))
        {
            return Err("allowed_hashes must contain 64-character hexadecimal digests".into());
        }
        let allowed_paths = strings(&object, "allowed_paths")?;
        if allowed_paths
            .iter()
            .any(|path| !path.starts_with('/') || path.contains('\0'))
        {
            return Err("allowed_paths must contain absolute paths".into());
        }
        Ok(Self {
            threshold,
            custom_rules,
            allowed_paths,
            allowed_hashes: allowed_hashes
                .into_iter()
                .map(|s| s.to_ascii_lowercase())
                .collect(),
            known: boolean(&object, "known", true)?,
            generic: boolean(&object, "generic", true)?,
            personal: boolean(&object, "personal", true)?,
            emails: boolean(&object, "emails", false)?,
            phones: boolean(&object, "phones", false)?,
            disabled_rules: strings(&object, "disabled_rules")?,
        })
    }
}

impl Context {
    fn from_json(json: &str) -> Result<Self, String> {
        let mut object = object(json)?;
        Ok(Self {
            title: take_string(&mut object, "title")?,
            path: take_string(&mut object, "path")?,
            app: take_string(&mut object, "app")?,
            ocr: boolean(&object, "ocr", false)?,
        })
    }
}

fn object(json: &str) -> Result<Map<String, Value>, String> {
    match serde_json::from_str(json).map_err(|e| e.to_string())? {
        Value::Object(object) => Ok(object),
        _ => Err("expected a JSON object".into()),
    }
}

fn boolean(object: &Map<String, Value>, field: &str, default: bool) -> Result<bool, String> {
    match object.get(field) {
        None => Ok(default),
        Some(value) => value
            .as_bool()
            .ok_or_else(|| format!("{field} must be a boolean")),
    }
}

fn score(value: &Value, field: &str) -> Result<f64, String> {
    let n = value
        .as_f64()
        .ok_or_else(|| format!("{field} must be a number"))?;
    if !n.is_finite() || !(0.0..=1.0).contains(&n) {
        return Err(format!("{field} must be between 0 and 1"));
    }
    Ok(n)
}

fn strings(object: &Map<String, Value>, field: &str) -> Result<Vec<String>, String> {
    let Some(value) = object.get(field) else {
        return Ok(Vec::new());
    };
    let array = value
        .as_array()
        .ok_or_else(|| format!("{field} must be an array"))?;
    if array.len() > 10_000 {
        return Err(format!("{field} is too large"));
    }
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
    id: String,
    pattern: String,
    score: f64,
    tier: String,
    validator: String,
}

impl Rule {
    fn from_value(value: &Value, custom: bool) -> Result<Self, String> {
        let object = value.as_object().ok_or("each rule must be an object")?;
        if custom
            && object
                .keys()
                .any(|key| !["id", "pattern", "score"].contains(&key.as_str()))
        {
            return Err("custom rules support id, pattern and score only".into());
        }
        let id = object
            .get("id")
            .and_then(Value::as_str)
            .ok_or("rule id must be a string")?;
        if id.is_empty()
            || id.len() > 64
            || !id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"_.-".contains(&c))
        {
            return Err(
                "rule id must use 1-64 letters, digits, dots, dashes or underscores".into(),
            );
        }
        let pattern = object
            .get("pattern")
            .and_then(Value::as_str)
            .ok_or("rule pattern must be a string")?;
        if pattern.is_empty() || pattern.len() > 16_384 {
            return Err("rule pattern must use 1-16384 bytes".into());
        }
        Ok(Self {
            id: id.into(),
            pattern: pattern.into(),
            score: object
                .get("score")
                .map(|v| score(v, "rule score"))
                .transpose()?
                .unwrap_or(0.9),
            tier: if custom {
                "custom"
            } else {
                object
                    .get("tier")
                    .and_then(Value::as_str)
                    .unwrap_or("known")
            }
            .into(),
            validator: if custom {
                "none"
            } else {
                object
                    .get("validator")
                    .and_then(Value::as_str)
                    .unwrap_or("none")
            }
            .into(),
        })
    }

    fn enabled(&self, config: &Config) -> bool {
        if config.disabled_rules.contains(&self.id) {
            return false;
        }
        match self.tier.as_str() {
            "known" => config.known,
            "generic" => config.generic,
            "personal" => config.personal,
            "email" => config.emails,
            "phone" => config.phones,
            _ => true,
        }
    }
}

pub struct Matcher {
    config: Config,
    rules: Vec<Rule>,
    set: RegexSet,
    regexes: Vec<Regex>,
    key: Zeroizing<[u8; 32]>,
}

impl Matcher {
    pub fn new(mut config: Config, key: [u8; 32]) -> Result<Self, String> {
        if config
            .threshold
            .is_some_and(|n| !n.is_finite() || !(0.0..=1.0).contains(&n))
        {
            return Err("threshold must be between 0 and 1".into());
        }
        let values: Vec<Value> = serde_json::from_str(include_str!("../rules/builtin.json"))
            .map_err(|e| e.to_string())?;
        let mut rules = values
            .iter()
            .map(|v| Rule::from_value(v, false))
            .collect::<Result<Vec<_>, _>>()?;
        rules.append(&mut config.custom_rules);
        let mut ids = HashSet::new();
        let mut regexes = Vec::new();
        for rule in &rules {
            if !ids.insert(rule.id.as_str()) {
                return Err(format!("duplicate rule id: {}", rule.id));
            }
            let regex = RegexBuilder::new(&rule.pattern)
                .size_limit(2_000_000)
                .build()
                .map_err(|_| format!("invalid or overly complex pattern in rule {}", rule.id))?;
            if regex.is_match("") {
                return Err(format!("rule {} must not match empty text", rule.id));
            }
            regexes.push(regex);
        }
        for id in &config.disabled_rules {
            if !ids.contains(id.as_str()) {
                return Err(format!("unknown disabled rule: {id}"));
            }
        }
        let set = RegexSetBuilder::new(rules.iter().map(|r| &r.pattern))
            .size_limit(16_000_000)
            .build()
            .map_err(|_| "combined rules are too complex")?;
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
        if !context.path.is_empty() && self.config.allowed_paths.contains(&context.path) {
            return Vec::new();
        }
        let mut findings = Vec::new();
        for i in self.set.matches(text).iter() {
            let rule = &self.rules[i];
            if !rule.enabled(&self.config) {
                continue;
            }
            let mut offset = 0;
            while offset <= text.len() {
                let Some(cap) = self.regexes[i].captures_at(text, offset) else {
                    break;
                };
                let full = cap.get(0).unwrap();
                offset = if rule.validator == "iban" || full.is_empty() {
                    full.start()
                        + text[full.start()..]
                            .chars()
                            .next()
                            .map(char::len_utf8)
                            .unwrap_or(1)
                } else {
                    full.end()
                };
                let Some(value) = cap.name("value").or_else(|| cap.get(0)) else {
                    continue;
                };
                let Some(length) = valid_length(&rule.validator, value.as_str(), context.ocr)
                else {
                    continue;
                };
                if length == 0 {
                    continue;
                }
                if rule.validator == "iban" {
                    offset = value.start() + length;
                }
                let raw = &value.as_str()[..length];
                let hash = self.hash(raw);
                if self.config.allowed_hashes.contains(&hash) {
                    continue;
                }
                let mut confidence = rule.score;
                if rule.validator == "entropy" {
                    let title = Zeroizing::new(context.title.to_lowercase());
                    if title.contains(".env")
                        || title.contains("secret")
                        || context.path.ends_with(".env")
                    {
                        confidence += 0.1;
                    }
                    if is_hex_digest(raw) || is_uuid(raw) {
                        confidence -= 0.3;
                    }
                    let label = Zeroizing::new(
                        text[cap.get(0).unwrap().start()..value.start()].to_ascii_lowercase(),
                    );
                    if label.contains("checksum")
                        || label.contains("sha256")
                        || label.contains("git_")
                    {
                        confidence -= 0.25;
                    }
                }
                // TODO: tune OCR confidence penalties against a larger set of terminal fonts.
                confidence = confidence.clamp(0.0, 1.0);
                if confidence < self.config.threshold.unwrap_or(0.65) {
                    continue;
                }
                findings.push(Finding {
                    start: value.start(),
                    end: value.start() + length,
                    rule: rule.id.clone(),
                    score: confidence,
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

fn valid_length(validator: &str, value: &str, ocr: bool) -> Option<usize> {
    match validator {
        "entropy" => (entropy(value) >= 3.5).then_some(value.len()),
        "aws" => (ocr || !value.contains('l')).then_some(value.len()),
        "card" | "ssn" | "phone" => {
            let digits = digits(value, ocr)?;
            let valid = match validator {
                "card" => luhn(&digits),
                "ssn" => valid_ssn(&digits),
                _ => (10..=15).contains(&digits.len()),
            };
            valid.then_some(value.len())
        }
        "iban" => iban_length(value, ocr),
        _ => Some(value.len()),
    }
}

fn digits(value: &str, ocr: bool) -> Option<Zeroizing<Vec<u8>>> {
    let mut digits = Zeroizing::new(Vec::new());
    for character in value.chars() {
        match character {
            '0'..='9' => digits.push(character as u8 - b'0'),
            'O' if ocr => digits.push(0),
            'l' | 'I' if ocr => digits.push(1),
            '-' | '‐' | '‑' | '‒' | '–' | '—' | '−' | '﹣' | '－' | '(' | ')' | '+' =>
                {}
            c if c.is_whitespace() => {}
            _ => return None,
        }
    }
    Some(digits)
}

fn luhn(digits: &[u8]) -> bool {
    if !(13..=19).contains(&digits.len()) || digits.iter().all(|d| *d == digits[0]) {
        return false;
    }
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(i, &d)| {
            let n = if i % 2 == 1 { d * 2 } else { d };
            u32::from(if n > 9 { n - 9 } else { n })
        })
        .sum();
    sum % 10 == 0
}

fn valid_ssn(digits: &[u8]) -> bool {
    if digits.len() != 9 {
        return false;
    }
    let area = u16::from(digits[0]) * 100 + u16::from(digits[1]) * 10 + u16::from(digits[2]);
    area > 0
        && area < 900
        && area != 666
        && digits[3..5].iter().any(|d| *d != 0)
        && digits[5..].iter().any(|d| *d != 0)
}

fn iban_country_length(country: &[u8]) -> Option<usize> {
    let code = std::str::from_utf8(country).ok()?;
    Some(match code {
        "NO" => 15,
        "BE" => 16,
        "DK" | "FI" | "FK" | "FO" | "GL" | "NL" | "SD" => 18,
        "MK" | "SI" => 19,
        "AT" | "BA" | "EE" | "KZ" | "LT" | "LU" | "MN" | "XK" => 20,
        "CH" | "HR" | "LI" | "LV" => 21,
        "BH" | "BG" | "CR" | "DE" | "GB" | "GE" | "IE" | "ME" | "RS" | "VA" => 22,
        "AE" | "GI" | "IL" | "IQ" | "OM" | "SO" | "TL" => 23,
        "AD" | "CZ" | "ES" | "MD" | "PK" | "RO" | "SA" | "SE" | "SK" | "TN" | "VG" => 24,
        "LY" | "PT" | "ST" => 25,
        "IS" | "TR" => 26,
        "BI" | "DJ" | "FR" | "GR" | "IT" | "MC" | "MR" | "SM" => 27,
        "AL" | "AZ" | "BY" | "CY" | "DO" | "GT" | "HN" | "HU" | "LB" | "NI" | "PL" | "SV" => 28,
        "BR" | "EG" | "PS" | "QA" | "UA" => 29,
        "JO" | "KW" | "MU" | "YE" => 30,
        "MT" | "SC" => 31,
        "LC" => 32,
        "RU" => 33,
        _ => return None,
    })
}

fn iban_length(value: &str, ocr: bool) -> Option<usize> {
    let mut compact = Zeroizing::new(Vec::new());
    let mut end = 0;
    let expected = iban_country_length(&value.as_bytes()[..2].to_ascii_uppercase())?;
    for (index, byte) in value.bytes().enumerate() {
        if byte == b' ' {
            continue;
        }
        let mut byte = byte.to_ascii_uppercase();
        if compact.len() == 2 || compact.len() == 3 {
            byte = match byte {
                b'O' if ocr => b'0',
                b'L' | b'I' if ocr => b'1',
                _ => byte,
            };
            if !byte.is_ascii_digit() {
                return None;
            }
        }
        compact.push(byte);
        if compact.len() == expected {
            end = index + 1;
            break;
        }
    }
    if compact.len() != expected {
        return None;
    }
    if value
        .as_bytes()
        .get(end)
        .is_some_and(|b| b.is_ascii_alphanumeric())
    {
        return None;
    }
    if iban_checksum(&compact) {
        return Some(end);
    }
    if ocr {
        let numeric_start = match &compact[..2] {
            b"GB" | b"IE" | b"NL" => Some(8),
            b"AE" | b"AT" | b"BA" | b"BE" | b"CH" | b"CZ" | b"DE" | b"DK" | b"EE" | b"ES"
            | b"FI" | b"FO" | b"GL" | b"HR" | b"HU" | b"LI" | b"LT" | b"LU" | b"ME" | b"MK"
            | b"NO" | b"PL" | b"PT" | b"RS" | b"SE" | b"SI" | b"SK" => Some(4),
            _ => None,
        };
        if let Some(start) = numeric_start {
            for byte in &mut compact[start..] {
                *byte = match *byte {
                    b'O' => b'0',
                    b'L' | b'I' => b'1',
                    other => other,
                };
            }
            if iban_checksum(&compact) {
                return Some(end);
            }
        }
    }
    None
}

fn iban_checksum(compact: &[u8]) -> bool {
    let mut remainder = 0u32;
    for &byte in compact[4..].iter().chain(compact[..4].iter()) {
        if byte.is_ascii_digit() {
            remainder = (remainder * 10 + u32::from(byte - b'0')) % 97;
        } else if byte.is_ascii_uppercase() {
            remainder = (remainder * 100 + u32::from(byte - b'A' + 10)) % 97;
        } else {
            return false;
        }
    }
    remainder == 1
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

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

include!("ffi.rs");
#[cfg(test)]
mod tests;
