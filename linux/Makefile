PREFIX ?= /usr/local
DESTDIR ?=
APP_ID := io.github.conjfrnk.CodexUsageBar
VERSION := 0.1.0
DIST_NAME := codex-usage-bar-$(VERSION)
LICENSE_FILE := $(if $(wildcard LICENSE),LICENSE,../LICENSE)

.PHONY: build check test visual-test run install uninstall dist arch-package clean

build:
	cargo build --release --locked

check:
	cargo fmt --check
	cargo check --all-targets --locked
	cargo clippy --all-targets --locked -- -D warnings

test:
	cargo test --all-targets --locked

visual-test: build
	rm -rf target/parity-snapshots
	mkdir -p target/parity-snapshots
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-light-narrow.png --appearance light --width 260 --height 1400
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-dark.png --appearance dark --width 300 --height 1400
	G_DEBUG=fatal-warnings target/release/codex-usage-bar --render-popover target/parity-snapshots/popover-live-size.png --appearance light --width 300 --height 560

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
