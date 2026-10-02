# Veil
Local macOS screen-share masking and a delayed Clean Feed.
Covers secrets on your screen while screensharing, so an API key, password, 
credit card, or other private content never reaches the other side.
Requires macOS 14+, Xcode Command Line Tools, Rust, and Metal for Clean Feed.
Run `./scripts/build.sh`, then open `build/Veil.app`.
Grant Accessibility and Screen Recording in Permissions & Test.
Cmd-Shift-P toggles protection; hold Cmd-Shift-V to peek.
Share your display in Overlay mode, or the Veil Feed window in Clean Feed mode.
Tests: `./scripts/test.sh`. See [limits](docs/verification.md).
