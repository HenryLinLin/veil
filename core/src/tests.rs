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

fn configured(json: &str) -> Matcher {
    Matcher::new(Config::from_json(json).unwrap(), [7; 32]).unwrap()
}

#[test]
fn valid_cards_only_and_ocr_keeps_original_ranges() {
    let engine = matcher();
    assert_eq!(
        engine.scan("4111 1111 1111 1111", &Context::default())[0].rule,
        "credit-card"
    );
    for value in [
        "4111 1111 1111 1112",
        "0000000000000000",
        "41111111111111111",
    ] {
        assert!(
            engine.scan(value, &Context::default()).is_empty(),
            "{value}"
        );
    }
    let text = "秘密 4lll llll llll llll";
    assert!(engine.scan(text, &Context::default()).is_empty());
    let mut context = Context::default();
    context.ocr = true;
    let result = engine.scan(text, &context);
    assert_eq!(result.len(), 1);
    assert_eq!(&text[result[0].start..result[0].end], "4lll llll llll llll");
    assert_eq!(result[0].hash, engine.hash("4lll llll llll llll"));
}

#[test]
fn iban_country_length_checksum_and_text_boundaries() {
    let engine = matcher();
    for value in [
        "GB82 WEST 1234 5698 7654 32",
        "DE89 3704 0044 0532 0130 00",
        "NO9386011117947",
        "FK88SC123456789012",
        "HN88CABF00000000000250005469",
    ] {
        let result = engine.scan(value, &Context::default());
        assert_eq!(result.len(), 1, "{value}");
        assert_eq!(result[0].rule, "iban");
        assert_eq!(result[0].end, value.len());
    }
    for value in [
        "GB83 WEST 1234 5698 7654 32",
        "DE8937040044053201300",
        "GB82WEST123456987654321",
        "ZZ82WEST12345698765432",
    ] {
        assert!(
            engine.scan(value, &Context::default()).is_empty(),
            "{value}"
        );
    }
    let text = "Transfer to GB82 WEST 1234 5698 7654 32 TODAY";
    let result = engine.scan(text, &Context::default());
    assert_eq!(
        &text[result[0].start..result[0].end],
        "GB82 WEST 1234 5698 7654 32"
    );
}

#[test]
fn social_security_excludes_invalid_components() {
    let engine = matcher();
    assert_eq!(
        engine.scan("123-45-6789", &Context::default())[0].rule,
        "ssn"
    );
    for value in [
        "000-45-6789",
        "666-45-6789",
        "900-45-6789",
        "123-00-6789",
        "123-45-0000",
    ] {
        assert!(
            engine.scan(value, &Context::default()).is_empty(),
            "{value}"
        );
    }
}

#[test]
fn contact_data_is_opt_in() {
    let text = "hello@example.com +1 212 555 0199";
    assert!(matcher().scan(text, &Context::default()).is_empty());
    let result = configured(r#"{"emails":true,"phones":true}"#).scan(text, &Context::default());
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].rule, "email");
    assert_eq!(result[1].rule, "phone");
}

#[test]
fn tiers_disabled_rules_and_threshold() {
    assert!(configured(r#"{"known":false}"#)
        .scan("ghp_", &Context::default())
        .is_empty());
    assert!(configured(r#"{"generic":false}"#)
        .scan("TOKEN=AbCdEfGh1234_XyZ98qR", &Context::default())
        .is_empty());
    assert!(configured(r#"{"personal":false}"#)
        .scan("123-45-6789", &Context::default())
        .is_empty());
    assert!(configured(r#"{"disabled_rules":["github-token"]}"#)
        .scan("ghp_", &Context::default())
        .is_empty());
    let engine = configured(r#"{"threshold":0.8}"#);
    let text = "TOKEN=AbCdEfGh1234_XyZ98qR";
    assert!(engine.scan(text, &Context::default()).is_empty());
    let mut context = Context::default();
    context.title = "secrets.env".into();
    assert_eq!(engine.scan(text, &context).len(), 1);
}

#[test]
fn allowlists_are_exact_and_install_specific() {
    let value = "ghp_token";
    let hash = matcher().hash(value);
    let engine = configured(
        &serde_json::json!({"allowed_hashes":[hash],"allowed_paths":["/tmp/example.env"]})
            .to_string(),
    );
    assert!(engine.scan(value, &Context::default()).is_empty());
    assert_eq!(engine.scan("ghp_other", &Context::default()).len(), 1);
    let mut context = Context::default();
    context.path = "/tmp/example.env".into();
    assert!(engine.scan("ghp_other", &context).is_empty());
    context.path.push_str(".backup");
    assert_eq!(engine.scan("ghp_other", &context).len(), 1);
    let changed_key = Matcher::new(
        Config::from_json(
            &serde_json::json!({"allowed_hashes":[matcher().hash(value)]}).to_string(),
        )
        .unwrap(),
        [9; 32],
    )
    .unwrap();
    assert_eq!(changed_key.scan(value, &Context::default()).len(), 1);
}

#[test]
fn custom_rules_support_value_capture_and_confidence() {
    let engine = configured(
        r#"{"custom_rules":[{"id":"internal-id","pattern":"INTERNAL=(?P<value>ABC[0-9]{5})","score":0.91}]}"#,
    );
    let text = "INTERNAL=ABC12345";
    let result = engine.scan(text, &Context::default());
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].rule, "internal-id");
    assert_eq!(&text[result[0].start..result[0].end], "ABC12345");
    assert_eq!(result[0].score, 0.91);
}

#[test]
fn configuration_rejects_mistakes_and_unsafe_patterns() {
    for json in [
        r#"{"known":1}"#,
        r#"{"threshold":2}"#,
        r#"{"threshold":"high"}"#,
        r#"{"unknown":true}"#,
        r#"{"allowed_hashes":["secret"]}"#,
        r#"{"allowed_paths":["relative"]}"#,
        r#"{"disabled_rules":["does-not-exist"]}"#,
        r#"{"custom_rules":[{"id":"github-token","pattern":"abc"}]}"#,
        r#"{"custom_rules":[{"id":"bad","pattern":"a*"}]}"#,
        r#"{"custom_rules":[{"id":"bad","pattern":"(?<=x)y"}]}"#,
        r#"{"custom_rules":[{"id":"bad","pattern":"(x)\\1"}]}"#,
        r#"{"custom_rules":[{"id":"bad","pattern":"abc","score":-1}]}"#,
    ] {
        assert!(
            Config::from_json(json)
                .and_then(|c| Matcher::new(c, [7; 32]))
                .is_err(),
            "{json}"
        );
    }
    let too_long = serde_json::json!({"custom_rules":[{"id":"long","pattern":"x".repeat(16_385)}]});
    assert!(Config::from_json(&too_long.to_string()).is_err());
    let too_many = serde_json::json!({"custom_rules":(0..129).map(|i| serde_json::json!({"id":format!("rule-{i}"),"pattern":"abc"})).collect::<Vec<_>>()});
    assert!(Config::from_json(&too_many.to_string()).is_err());
}

#[test]
fn unfinished_pem_block_is_covered_immediately() {
    let text = "before\n-----BEGIN PRIVATE KEY-----\nsecret\n";
    let result = matcher().scan(text, &Context::default());
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].start, 7);
    assert_eq!(result[0].end, text.len());
    let text = "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----\npublic";
    let result = matcher().scan(text, &Context::default());
    assert_eq!(
        &text[result[0].start..result[0].end],
        text.trim_end_matches("\npublic")
    );
}

#[test]
fn generic_json_values_and_common_false_positives() {
    let engine = matcher();
    assert_eq!(
        engine
            .scan(r#"{"API_KEY":"AbCdEfGh1234_XyZ98qR"}"#, &Context::default())
            .len(),
        1
    );
    for value in [
        "KEY=550e8400-e29b-41d4-a716-446655440000",
        "TOKEN=0123456789abcdef0123456789abcdef01234567",
        "KEY=aaaaaaaaaaaaaaaaaaaa",
        "PASSWORD=short",
    ] {
        assert!(
            engine.scan(value, &Context::default()).is_empty(),
            "{value}"
        );
    }
}

#[test]
fn aws_ocr_body_tolerance_does_not_change_prefixes() {
    let engine = matcher();
    let text = "AKIAIOSFODNN7EXAMPlE";
    assert!(engine.scan(text, &Context::default()).is_empty());
    let mut context = Context::default();
    context.ocr = true;
    assert_eq!(engine.scan(text, &context).len(), 1);
    assert!(engine.scan("AKlAIOSFODNN7EXAMPLE", &context).is_empty());
    assert_eq!(engine.scan("ABIAIOSFODNN7EXAMPLE", &context).len(), 1);
}

#[test]
fn ffi_handles_null_and_invalid_utf8_without_raw_text() {
    unsafe {
        let config = CString::new("{}").unwrap();
        let engine = veil_engine_new(config.as_ptr(), [1; 32].as_ptr());
        for (text, context) in [
            (ptr::null(), ptr::null()),
            ([0xff_u8, 0].as_ptr().cast(), ptr::null()),
            (config.as_ptr(), [b'[', 0].as_ptr().cast()),
        ] {
            let result = veil_engine_scan(engine, text, context);
            let json: Value =
                serde_json::from_str(CStr::from_ptr(result).to_str().unwrap()).unwrap();
            assert!(json.get("error").is_some());
            assert_eq!(json["matches"], serde_json::json!([]));
            veil_string_free(result);
        }
        assert!(veil_engine_new(config.as_ptr(), ptr::null()).is_null());
        let result = veil_config_validate(ptr::null());
        assert!(CStr::from_ptr(result).to_str().unwrap().contains("false"));
        veil_string_free(result);
        veil_engine_free(engine);
        veil_engine_free(ptr::null_mut());
        veil_string_free(ptr::null_mut());
    }
}

#[test]
fn iban_ocr_repairs_numeric_body_only() {
    let engine = matcher();
    let text = "DE89 37O4 OO44 O532 O13O OO";
    assert!(engine.scan(text, &Context::default()).is_empty());
    let mut context = Context::default();
    context.ocr = true;
    let result = engine.scan(text, &context);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].rule, "iban");
    assert_eq!(result[0].hash, engine.hash(text));
    assert_eq!(result[0].end, text.len());
}

#[test]
fn phone_parentheses_and_country_prefix() {
    let engine = configured(r#"{"phones":true}"#);
    for value in ["+1 (212) 555-0199", "212-555-0199", "+44 20 7946 0958"] {
        assert_eq!(engine.scan(value, &Context::default()).len(), 1, "{value}");
    }
}

#[test]
fn concurrent_ffi_calls_use_the_worker_safely() {
    unsafe {
        let config = CString::new("{}").unwrap();
        let engine = veil_engine_new(config.as_ptr(), [7; 32].as_ptr());
        let address = engine as usize;
        let workers: Vec<_> = (0..8)
            .map(|_| {
                std::thread::spawn(move || {
                    let text = CString::new("ghp_example").unwrap();
                    let result =
                        veil_engine_scan(address as *const Engine, text.as_ptr(), ptr::null());
                    let json: Value =
                        serde_json::from_str(CStr::from_ptr(result).to_str().unwrap()).unwrap();
                    assert_eq!(json["matches"][0]["rule"], "github-token");
                    veil_string_free(result);
                })
            })
            .collect();
        for worker in workers {
            worker.join().unwrap();
        }
        veil_engine_free(engine);
    }
}

#[test]
fn adjacent_ibans_are_both_masked() {
    let text = "GB82 WEST 1234 5698 7654 32 DE89 3704 0044 0532 0130 00";
    let result = matcher().scan(text, &Context::default());
    let values: Vec<_> = result
        .iter()
        .filter(|m| m.rule == "iban")
        .map(|m| &text[m.start..m.end])
        .collect();
    assert_eq!(
        values,
        ["GB82 WEST 1234 5698 7654 32", "DE89 3704 0044 0532 0130 00"]
    );
}

#[test]
fn invalid_iban_does_not_hide_a_later_valid_iban() {
    let text = "GB83 WEST 1234 5698 7654 32 DE89 3704 0044 0532 0130 00";
    let result = matcher().scan(text, &Context::default());
    let values: Vec<_> = result
        .iter()
        .filter(|m| m.rule == "iban")
        .map(|m| &text[m.start..m.end])
        .collect();
    assert_eq!(values, ["DE89 3704 0044 0532 0130 00"]);
}
