PREFIX ?= /usr/local
DESTDIR ?=
APP_ID := io.github.conjfrnk.CodexUsageBar
VERSION := 0.1.0
DIST_NAME := codex-usage-bar-$(VERSION)
LICENSE_FILE := $(if $(wildcard LICENSE),LICENSE,../LICENSE)

.PHONY: build check test visual-test visual-test-display run install uninstall dist arch-package clean

build:
	cargo build --release --locked

check:
	cargo fmt --check
	cargo check --all-targets --locked
	cargo clippy --all-targets --locked -- -D warnings

test:
	cargo test --all-targets --locked

visual-test: build
	@command -v xvfb-run >/dev/null || { \
		echo "visual-test requires xvfb-run (Arch package: xorg-server-xvfb)" >&2; \
		exit 1; \
	}
	xvfb-run -a -s '-screen 0 2560x2160x24 -nolisten tcp' env GDK_BACKEND=x11 GSK_RENDERER=cairo $(MAKE) visual-test-display

visual-test-display:
	@test -x target/release/codex-usage-bar || { \
		echo "visual-test-display requires the release binary; run make visual-test" >&2; \
		exit 1; \
	}
	rm -rf target/parity-snapshots
	mkdir -p target/parity-snapshots
	rm -rf target/parity-config-off target/parity-config-on
	mkdir -p target/parity-config-off target/parity-config-on/autostart
	printf '%s\n' '[Desktop Entry]' > target/parity-config-on/autostart/io.github.conjfrnk.CodexUsageBar.desktop
	XDG_CONFIG_HOME="$(CURDIR)/target/parity-config-off" G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-light-narrow.png --appearance light --width 260 --height 1400
	XDG_CONFIG_HOME="$(CURDIR)/target/parity-config-on" G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-light-narrow-repeat.png --appearance light --width 260 --height 1400
	cmp target/parity-snapshots/popover-light-narrow.png target/parity-snapshots/popover-light-narrow-repeat.png
	rm -f target/parity-snapshots/popover-light-narrow-repeat.png
	rm -rf target/parity-config-off target/parity-config-on
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-dark.png --appearance dark --width 300 --height 1400
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-live-size.png --appearance light --width 300 --height 560
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-week.png --appearance light --timeframe seven --width 300 --height 560
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-quarter.png --appearance light --timeframe ninety --width 300 --height 560
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-all-time.png --appearance dark --timeframe all --width 300 --height 560
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-min-height.png --appearance light --width 300 --height 220
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-stale.png --appearance light --width 300 --height 560 --state stale
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-loading.png --appearance light --width 300 --height 560 --state loading
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-error.png --appearance light --width 300 --height 560 --state error
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-maximum-220.png --appearance light --timeframe all --width 220 --height 560 --state maximum
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-long-stale-220.png --appearance light --width 220 --height 560 --state long-stale
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-long-error-220.png --appearance light --width 220 --height 560 --state long-error
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-boundary-220x220.png --appearance light --width 220 --height 220
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-boundary-220x288.png --appearance light --width 220 --height 288
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-boundary-220x289.png --appearance light --width 220 --height 289
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-boundary-220x300.png --appearance light --width 220 --height 300
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-boundary-220x559.png --appearance light --width 220 --height 559
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-boundary-220x560.png --appearance light --width 220 --height 560
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-boundary-220x2000.png --appearance light --width 220 --height 2000
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-boundary-2000x220.png --appearance light --width 2000 --height 220
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-boundary-2000x2000.png --appearance dark --width 2000 --height 2000
	@if cmp -s target/parity-snapshots/popover-live-size.png target/parity-snapshots/popover-stale.png; then \
		echo "stale fixture did not visibly differ from the healthy fixture" >&2; \
		exit 1; \
	fi
	@if cmp -s target/parity-snapshots/popover-live-size.png target/parity-snapshots/popover-loading.png \
		|| cmp -s target/parity-snapshots/popover-live-size.png target/parity-snapshots/popover-error.png \
		|| cmp -s target/parity-snapshots/popover-loading.png target/parity-snapshots/popover-error.png; then \
		echo "normal, loading, and error fixtures must be visibly distinct" >&2; \
		exit 1; \
	fi

run:
	cargo run --locked -- --show

install: build
	install -Dm755 target/release/codex-usage-bar "$(DESTDIR)$(PREFIX)/bin/codex-usage-bar"
	install -Dm644 data/$(APP_ID).desktop "$(DESTDIR)$(PREFIX)/share/applications/$(APP_ID).desktop"
	install -Dm644 data/codex-usage-bar.svg "$(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/codex-usage-bar.svg"
	install -Dm644 data/waybar-module.jsonc "$(DESTDIR)$(PREFIX)/share/doc/codex-usage-bar/waybar-module.jsonc"
	install -Dm644 data/waybar-style.css "$(DESTDIR)$(PREFIX)/share/doc/codex-usage-bar/waybar-style.css"
	install -Dm644 "$(LICENSE_FILE)" "$(DESTDIR)$(PREFIX)/share/licenses/codex-usage-bar/LICENSE"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/codex-usage-bar"
	rm -f "$(DESTDIR)$(PREFIX)/share/applications/$(APP_ID).desktop"
	rm -f "$(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/codex-usage-bar.svg"
	rm -f "$(DESTDIR)$(PREFIX)/share/doc/codex-usage-bar/waybar-module.jsonc"
	rm -f "$(DESTDIR)$(PREFIX)/share/doc/codex-usage-bar/waybar-style.css"
	rm -f "$(DESTDIR)$(PREFIX)/share/licenses/codex-usage-bar/LICENSE"

dist:
	rm -rf "target/dist/$(DIST_NAME)"
	mkdir -p "target/dist/$(DIST_NAME)"
	cp Cargo.toml Cargo.lock Makefile README.md "target/dist/$(DIST_NAME)/"
	cp "$(LICENSE_FILE)" "target/dist/$(DIST_NAME)/LICENSE"
	cp -R src data "target/dist/$(DIST_NAME)/"
	tar -C target/dist -czf "target/dist/$(DIST_NAME).tar.gz" "$(DIST_NAME)"

arch-package: dist
	cp "target/dist/$(DIST_NAME).tar.gz" packaging/arch/
	cd packaging/arch && makepkg -f
	rm -f "packaging/arch/$(DIST_NAME).tar.gz"

clean:
	cargo clean
