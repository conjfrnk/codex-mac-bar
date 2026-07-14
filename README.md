# Codex Usage Bar

A macOS menu bar app for viewing account-wide Codex token usage and rate limits through the locally installed Codex CLI.

A separate Rust/GTK4 implementation for Wayland-oriented Linux desktops lives in [`linux/`](linux/README.md), with Arch packaging and source-based installation support.

## Requirements

- macOS 13 or newer
- Apple Swift 5.9 or newer for the app; an Apple Swift 6 toolchain for the native test suite
- Codex CLI installed and signed in

The app, native Swift Testing suite, executable checks, visual checks, and code
coverage all run with Apple Command Line Tools; full Xcode is not required. The
current Command Line Tools testing runtime requires macOS 14 or newer to execute
the development test bundle, while the production app itself remains built and
validated for its declared macOS 13 deployment target.

## Build

```sh
make test
make visual-test
make install
```

`make install` builds and ad-hoc signs the app, copies the verified bundle to
`~/Applications/Codex Usage Bar.app`, and opens that durable copy. No Apple
Developer account or signing certificate is required. Use `make run` for a
development build or `make app` to create only the staging bundle under `.build/`.
`make visual-test` renders light/dark chart edge cases plus normal and narrow full-popover fixtures under `.build/` for layout inspection.
Quit any already-running copy before `make run` or `make install`; macOS may
otherwise reuse the existing process instead of starting the rebuilt executable.

Because local builds use an ad-hoc signature, changing the rebuilt code or
resources changes the app's code identity. If macOS no longer recognizes a
previously enabled login item after an upgrade, disable and re-enable **Open at Login** from the newly installed copy.
Developer ID signing and notarization are required for a stable distributed
identity.

The app runs `codex app-server --stdio`; authentication remains with the Codex CLI, and the app does not persist auth or usage data. It remembers the selected timeframe in macOS user defaults and, only if enabled, registers the installed app as a login item. The app-server interface is experimental and may change between Codex CLI versions.

This is an unofficial project and is not affiliated with or endorsed by OpenAI.
