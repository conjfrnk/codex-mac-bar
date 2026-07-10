.PHONY: build test visual-test run app

build:
	swift build

test:
	swift run CodexUsageChecks

visual-test:
	swift build --product CodexUsageBar
	swift run CodexUsageVisualChecks
	mkdir -p .build/popover-snapshots
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/popover-light-narrow.png" --appearance light --width 260 --height 1400
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/popover-dark.png" --appearance dark --width 300 --height 1400

run:
	swift run CodexUsageBar

app:
	./scripts/build-app.sh
