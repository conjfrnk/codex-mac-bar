# Codex Usage Bar

A macOS menu bar app for viewing account-wide Codex token usage and rate limits through the locally installed Codex CLI.

## Requirements

- macOS 13 or newer
- Swift 5.9 or newer
- Codex CLI installed and signed in

## Build

```sh
make test
make visual-test
make app
open ".build/Codex Usage Bar.app"
```

`make app` builds and ad-hoc signs the app locally; no Apple Developer account or signing certificate is required.
`make visual-test` renders light/dark chart edge cases plus normal and narrow full-popover fixtures under `.build/` for layout inspection.

The app runs `codex app-server --stdio`; authentication remains with the Codex CLI, and the app does not persist auth or usage data. It remembers the selected timeframe in macOS user defaults and, only if enabled, registers itself as a login item. The app-server interface is experimental and may change between Codex CLI versions.

This is an unofficial project and is not affiliated with or endorsed by OpenAI.
