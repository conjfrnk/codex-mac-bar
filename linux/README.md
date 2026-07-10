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
sudo pacman -S --needed base-devel rust gtk4 dbus
```

GTK 4.10 or newer is required. The Codex CLI must also be installed and signed in.
The executable is discovered from `PATH`, `~/.local/bin`, `~/.npm-global/bin`, or
`CODEX_USAGE_BAR_CODEX_PATH`.

Build and run from this directory:

```sh
make test
make visual-test
make build
./target/release/codex-usage-bar
```

Create and install a native Arch package:

```sh
make arch-package
sudo pacman -U packaging/arch/codex-usage-bar-0.1.0-1-*.pkg.tar.zst
```

The included PKGBUILD consumes the source archive made from the current checkout, so it is usable before the project has tagged Linux releases.

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

The main window remains available from the desktop launcher even if the current panel does not provide a tray host. A left click on the tray icon opens the window, a second left click or Escape dismisses it, a middle click refreshes it, and the context menu provides timeframe, refresh, autostart, and quit actions. The window deliberately remains open when pointer-driven focus moves elsewhere, which keeps it usable on focus-follows-mouse Wayland compositors.

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
```

Preferences are stored in `${XDG_CONFIG_HOME:-~/.config}/codex-usage-bar/config.json`. Enabling “Open at login” creates `${XDG_CONFIG_HOME:-~/.config}/autostart/io.github.conjfrnk.CodexUsageBar.desktop` using the installed executable's absolute path.

The app starts `codex app-server --stdio` for each refresh. That interface is experimental and may change between Codex CLI versions. If auto-discovery fails:

```sh
CODEX_USAGE_BAR_CODEX_PATH=/path/to/codex codex-usage-bar --check
```

## Development

```sh
make check
make test
cargo fmt --check
```

`make check` treats Clippy warnings as errors. The tray service talks to the session D-Bus; the pure calculation and decoding tests do not require a graphical session.
`make visual-test` mirrors the macOS visual-check workflow by rendering opaque light,
dark, narrow, full-content, and live-size parity fixtures under
`target/parity-snapshots/` without reading account data.
