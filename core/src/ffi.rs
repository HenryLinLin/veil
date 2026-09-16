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
    if value.len() > 16_777_216 { return Err("input exceeds 16 MiB".into()); }
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

