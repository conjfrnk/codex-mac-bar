# Codex Usage Bar for Linux

A Wayland-friendly GTK4 status application for account-wide Codex token usage and rate limits. It uses the locally installed and authenticated Codex CLI; it does not store authentication or usage data.

The Linux app is independent of the macOS Swift target in the repository root. It provides:

- Week, Month, Quarter, and All-time usage ranges
- The same date-aware, monotone-smoothed activity chart as macOS, including hover,
  click-to-pin, arrow-key inspection, and bounded tooltips
- Primary and secondary rate-limit windows
- A variable-width StatusNotifierItem combining the gauge and compact token total
- XDG login autostart
- An explicitly opaque GTK popover matching the macOS 300×560 layout while
  following the active GTK light or dark palette, with hidden-indicator wheel,
  touchpad, touch, and keyboard scrolling
- A headless connection check for troubleshooting
- An optional custom Waybar fallback for panels that force tray icons to be square

## Arch Linux

Install build dependencies:

```sh
sudo pacman -S --needed base-devel rust gtk4 dbus desktop-file-utils python \
  xorg-server-xvfb namcap
```

GTK 4.10 or newer is required. The Codex CLI must also be installed and signed in.
The executable is discovered from `PATH`, `~/.local/bin`, `~/.npm-global/bin`, or
`CODEX_USAGE_BAR_CODEX_PATH`.

Build and run from this directory:

```sh
make verify
make test
make visual-test
make build
./target/release/codex-usage-bar
```

`make verify` is the authoritative Linux check: formatting, Cargo check, Clippy with
warnings denied, tests, installed/archive package smoke tests, reproducible source
archives, metadata validation, and Xvfb visual checks. Package smoke tests require
`desktop-file-validate`, Python 3, `b2sum`, and the normal Rust/GTK build tools.

Create and install a native Arch package:

```sh
make arch-package
sudo pacman -U packaging/arch/codex-usage-bar-*-*.pkg.tar.zst
```

The PKGBUILD names the versioned GitHub release archive and pins its BLAKE2 checksum.
`make arch-package` first creates that same deterministic archive in the current
checkout and places it in makepkg's source cache, so local packaging remains usable
before a tag is published and does not silently bypass checksum verification.

To inspect the release inputs without building an Arch package:

```sh
make dist
b2sum -c target/dist/codex-usage-bar-*.tar.gz.b2
make dist-reproducible
make package-test
```

The archive preserves the repository-relative `linux/` and `Fixtures/` layout,
rebuilds byte-for-byte with a recorded `SOURCE_DATE_EPOCH`, and is rebuilt and tested
from its extracted contents by `make package-test`. In source-archive mode the same
target validates the archive checksum, desktop metadata, SVG, staged install, and
executables while clearly skipping only the repository-owned PKGBUILD, which cannot
be embedded in the archive it checksums. These targets only prepare and verify
artifacts; they do not publish a release.
The default archive epoch is the commit-independent value `0`; release automation
may set `SOURCE_DATE_EPOCH` explicitly, and that chosen value is recorded inside the
archive so an extracted tree can reproduce the same bytes.

## Gentoo and other source-based distributions

On Gentoo, install Rust, GTK4, and D-Bus using the appropriate USE flags for your desktop, then use the standard Makefile:

```sh
make build
sudo make install PREFIX=/usr
```

For a staged package install, set `DESTDIR`:

```sh
make install PREFIX=/usr DESTDIR=/tmp/codex-usage-package
```

No X11-specific library is used. GTK selects its Wayland backend automatically in a Wayland session and can also use X11 when needed.

## Desktop integration

KDE Plasma and many wlroots-based panels support StatusNotifierItem directly. Stock GNOME Shell requires AppIndicator support; on Arch:

```sh
sudo pacman -S gnome-shell-extension-appindicator
gnome-extensions enable $(gnome-extensions list | grep -m1 appindicatorsupport)
```

The main window remains available from the desktop launcher even if the current panel does not provide a tray host. A left click on the tray icon opens the window, a second left click or Escape dismisses it, a middle click refreshes it, and the context menu provides timeframe, refresh, autostart, and quit actions. When the chart has keyboard focus, the first Escape clears its pinned point; a subsequent Escape dismisses the window. The window deliberately remains open when pointer-driven focus moves elsewhere, which keeps it usable on focus-follows-mouse Wayland compositors.

If a refresh fails after valid data has loaded, the app keeps that snapshot visible and marks it stale instead of replacing it with an empty error screen. Relative refresh and rate-limit labels update while the popover is open, and an unexpected wall-clock change forces a fresh fetch.

The tray pixmap itself contains both the gauge and the current compact total, so
Waybar and other panels that preserve a StatusNotifierItem's aspect ratio show the
same variable-width `gauge + total` item as macOS without additional configuration.
It changes to `Codex ...` while initially loading and `Codex ?` on failure, and
updates immediately after a refresh or timeframe change.

If a panel forces every tray pixmap to be square, use the custom Waybar fallback:
merge [`data/waybar-module.jsonc`](data/waybar-module.jsonc) into the top level of
your Waybar config, add `"custom/codex-usage"` to the desired modules list, and
remove `"tray"` if it would duplicate the status item. Optional styles are in
[`data/waybar-style.css`](data/waybar-style.css). Clicking the custom module opens
the opaque popover without starting another tray item.

## Commands and configuration

```sh
codex-usage-bar                 # start the status item without opening the popover
codex-usage-bar --show          # start and open the usage popover
codex-usage-bar --background    # explicitly start hidden, as used by autostart
codex-usage-bar --no-tray       # popover only; quit when dismissed
codex-usage-bar --check         # test app-server access without GTK/display
codex-usage-bar --waybar        # one JSON status update for Waybar
codex-usage-bar --help          # print command help
codex-usage-bar --version       # print the canonical package version
```

Preferences are stored in `${XDG_CONFIG_HOME:-~/.config}/codex-usage-bar/config.json`. Enabling “Open at login” creates `${XDG_CONFIG_HOME:-~/.config}/autostart/io.github.conjfrnk.CodexUsageBar.desktop` using the installed executable's absolute path. If neither `XDG_CONFIG_HOME` nor `HOME` identifies an absolute directory, the app safely leaves persistence and autostart unavailable instead of reading or writing a working-directory-relative `.config`.

The app starts `codex app-server --stdio` for each refresh. That interface is experimental and may change between Codex CLI versions. If auto-discovery fails:

```sh
CODEX_USAGE_BAR_CODEX_PATH=/path/to/codex codex-usage-bar --check
```

## Development

```sh
make verify
make check
make test
cargo fmt --check
```

`make check` treats Clippy warnings as errors. The tray service talks to the session D-Bus; the pure calculation and decoding tests do not require a graphical session.
The repository-root `VERSION` file is authoritative; root `make check-version`
rejects drift in Cargo, Cargo.lock, PKGBUILD, and bundle metadata. GitHub Actions runs
the Rust 1.92 MSRV and stable toolchains, performs dependency license/source and
RustSec advisory checks, and runs `makepkg` plus `namcap` in an Arch Linux container
as an unprivileged package builder. CI uploads logs plus render artifacts only when
verification fails. `make clean` and `make distclean` are explicit destructive
maintenance targets and are never prerequisites of verification or CI.
`make visual-test` mirrors the macOS visual-check workflow by rendering opaque light,
dark, narrow, tall, live-size, every timeframe, loading, stale, error, maximum-token, and
long-unbroken-diagnostic parity fixtures under
`target/parity-snapshots/` without reading account data. The fixture clock and dates
are fixed; the target uses an explicit 2560×2160 Xvfb display so the compositor cannot
cap and stretch tall fixtures. It also exercises the accepted 220-pixel minimum,
the former 288/289-pixel chart boundary, 559/560-pixel viewport boundary, and the
2,000-pixel maximum width and height (both separately and together). The check renders one case with autostart both absent and
present in isolated configuration homes and requires byte-identical PNGs, then validates
opacity and exact allocation dimensions. Its semantic oracle
scrolls each expected header, state message, tabs, summary, chart, history, rate-limit,
and action widget into view and verifies distinct allocation order and visible pixels.
The header logo, title, and value have separate non-overlapping ink probes, and error
fixtures reject an initially focused/preselected selectable diagnostic; one visible
element therefore cannot accidentally satisfy an adjacent semantic check.
