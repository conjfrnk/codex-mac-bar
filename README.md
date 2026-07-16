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
make verify
make test
make visual-test
make install
```

`make verify` is the authoritative local and CI entry point. On macOS it runs the
guarded Swift Testing runner (which rejects zero-test discovery), executable checks,
complete strict-concurrency diagnostics as errors, and deterministic visual checks.
On Linux it delegates to the Rust verification and packaging workflow under
[`linux/`](linux/README.md). Plain `swift test` is not an equivalent check on the
standalone Apple Command Line Tools because that toolchain can report success after
discovering zero Swift Testing tests.

`make install` builds and ad-hoc signs the app, copies the verified bundle to
`~/Applications/Codex Usage Bar.app`, and opens that durable copy. No Apple
Developer account or signing certificate is required. Use `make run` for a
development build or `make app` to create only the staging bundle under `.build/`.
`make visual-test` renders light/dark chart edge cases plus normal and narrow full-popover fixtures under `.build/` for layout inspection.
Quit any already-running copy before `make run` or `make install`; macOS may
otherwise reuse the existing process instead of starting the rebuilt executable.

For an opt-in live authentication and connectivity diagnostic, run
`.build/debug/CodexUsageBar --check` after building the app. This contacts the
signed-in local Codex CLI and prints only capability status, not account totals or
rate-limit values. It is deliberately not run by automated verification; CI uses
an isolated fake app-server instead.

### Manual macOS verification

Before a release, verify the installed app with VoiceOver and keyboard navigation:
confirm the status item label/value/help, the popover's reading order, and that all
controls can be reached and activated without a pointer. Increase macOS text size
through the accessibility settings and inspect the complete popover for readable,
unclipped content. Finally, use Instruments or an equivalent energy/profile check
to confirm presentation ticks stop after the menu closes and resume only while it
is presented.

Because local builds use an ad-hoc signature, changing the rebuilt code or
resources changes the app's code identity. If macOS no longer recognizes a
previously enabled login item after an upgrade, disable and re-enable **Open at Login** from the newly installed copy.
Developer ID signing and notarization are required for a stable distributed
identity.

The repository-root [`VERSION`](VERSION) file is the release version authority.
`make check-version` rejects drift in Cargo, Cargo.lock, Arch packaging, and macOS
bundle inputs. The generated macOS bundle records that version in both its Info.plist
and resources. Cleanup is always explicit: `make clean` removes SwiftPM products and
`make distclean` additionally removes local Swift and Rust build/package state;
neither target is part of verification or CI. On Linux, root `make clean` delegates
to the Rust target instead.

The app runs `codex app-server --stdio`; authentication remains with the Codex CLI, and the app does not persist auth or usage data. It remembers the selected timeframe in macOS user defaults and, only if enabled, registers the installed app as a login item. The app-server interface is experimental and may change between Codex CLI versions.

This is an unofficial project and is not affiliated with or endorsed by OpenAI.
