# Checks and limits

- Build, signature, launch, 23 Rust tests, 519 geometry checks, feed queue tests passed.
- GPU pixel tests were skipped. 
- Overlay requires full-display sharing. Auto-arm is heuristic; small or unreadable secrets can escape detection.
- Clean Feed pauses during window-layout changes. Native Swift handles the UI; Rust handles matching.
- No raw text or frame logs. Value exceptions use keyed hashes; complete memory erasure isn't guaranteed.
