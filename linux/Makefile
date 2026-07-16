PREFIX ?= /usr/local
DESTDIR ?=
PYTHON ?= python3
APP_ID := io.github.conjfrnk.CodexUsageBar
VERSION_FILE ?= ../VERSION
VERSION := $(strip $(shell cat "$(VERSION_FILE)" 2>/dev/null))
DIST_NAME := codex-usage-bar-$(VERSION)
LICENSE_FILE := ../LICENSE
SOURCE_DATE_EPOCH ?= 0

.PHONY: build check test verify version-check visual-test visual-test-display run \
	install uninstall dist dist-reproducible package-metadata-check package-test \
	arch-package clean distclean

build:
	cargo build --release --locked

check:
	cargo fmt --check
	cargo check --all-targets --locked
	cargo clippy --all-targets --locked -- -D warnings

test:
	cargo test --all-targets --locked

version-check:
	@if test -f ../scripts/check-version.sh; then \
		/bin/bash ../scripts/check-version.sh; \
	else \
		version_lines="$$(awk 'END { print NR + 0 }' ../VERSION)"; \
		canonical_version="$$(cat ../VERSION)"; \
		manifest_version="$$(awk -F '"' '/^version = / { print $$2; exit }' Cargo.toml)"; \
		test "$$version_lines" -eq 1 \
			&& printf '%s\n' "$$canonical_version" \
				| grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' \
			&& test "$$manifest_version" = "$$canonical_version" || { \
			echo "Cargo.toml does not match ../VERSION" >&2; exit 1; \
		}; \
	fi

verify: version-check
	$(MAKE) check
	$(MAKE) test
	$(MAKE) package-test
	$(MAKE) visual-test

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

dist: version-check
	@test -n "$(VERSION)" || { echo "VERSION is empty" >&2; exit 1; }
	@mkdir -p target/dist
	$(PYTHON) tests/create-dist.py \
		--output "target/dist/$(DIST_NAME).tar.gz" \
		--epoch "$(SOURCE_DATE_EPOCH)"
	@cd target/dist && b2sum "$(DIST_NAME).tar.gz" > "$(DIST_NAME).tar.gz.b2"

dist-reproducible:
	@/bin/bash tests/check-dist-reproducible.sh

package-metadata-check: dist
	@/bin/bash tests/validate-package-metadata.sh "target/dist/$(DIST_NAME).tar.gz"

package-test: build
	@$(MAKE) dist-reproducible
	@$(MAKE) package-metadata-check
	@/bin/bash tests/package-smoke.sh

arch-package: version-check dist
	cp "target/dist/$(DIST_NAME).tar.gz" packaging/arch/
	cd packaging/arch && makepkg --cleanbuild --force --noconfirm
	rm -f "packaging/arch/$(DIST_NAME).tar.gz"

# Cleanup is intentionally explicit and is never part of verify or CI.
clean:
	cargo clean

distclean:
	rm -rf target packaging/arch/src packaging/arch/pkg
	rm -f packaging/arch/codex-usage-bar-*.tar.gz \
		packaging/arch/codex-usage-bar-*.pkg.tar.*
