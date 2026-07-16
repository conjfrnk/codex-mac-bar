.PHONY: build test strict-concurrency macos-smoke-check coverage visual-test \
	run app install check-version verify verify-macos verify-linux clean distclean

build:
	swift build

check-version:
	@/bin/bash scripts/check-version.sh

verify:
	@set -e; case "$$(uname -s)" in \
		Darwin) $(MAKE) verify-macos ;; \
		Linux) $(MAKE) verify-linux ;; \
		*) echo "verify is supported on macOS and Linux" >&2; exit 1 ;; \
	esac

verify-macos: check-version
	$(MAKE) test
	$(MAKE) strict-concurrency
	$(MAKE) macos-smoke-check
	$(MAKE) visual-test

verify-linux: check-version
	$(MAKE) -C linux verify

test:
	@set -e; if [ "$$(uname -s)" = Darwin ]; then \
		developer_dir="$$(xcode-select -p)"; \
		export DEVELOPER_DIR="$$developer_dir"; \
		xcrun swift build --build-tests --disable-xctest --enable-swift-testing; \
		swiftc_path="$$(xcrun --find swiftc)"; \
		swiftc_bin_dir="$$(dirname "$$swiftc_path")"; \
		testing_framework_dir="$$swiftc_bin_dir/../../Library/Developer/Frameworks"; \
		testing_library_dir="$$swiftc_bin_dir/../lib/swift/macosx/testing"; \
		if [ -d "$$testing_framework_dir/Testing.framework" ]; then \
			xcrun swiftc -parse-as-library scripts/run-swift-tests.swift \
				-F "$$testing_framework_dir" \
				-framework Testing \
				-Xlinker -rpath \
				-Xlinker "$$testing_framework_dir" \
				-Xlinker -rpath \
				-Xlinker "$$developer_dir/Library/Developer/usr/lib" \
				-o .build/run-swift-tests; \
		elif [ -d "$$testing_library_dir/Testing.swiftmodule" ] \
			&& [ -f "$$testing_library_dir/libTesting.dylib" ]; then \
			xcrun swiftc -parse-as-library scripts/run-swift-tests.swift \
				-I "$$testing_library_dir" \
				-L "$$testing_library_dir" \
				-lTesting \
				-Xlinker -rpath \
				-Xlinker "$$testing_library_dir" \
				-o .build/run-swift-tests; \
		elif platform_path="$$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null)" \
			&& [ -d "$$platform_path/Developer/Library/Frameworks/Testing.framework" ]; then \
			platform_framework_dir="$$platform_path/Developer/Library/Frameworks"; \
			xcrun swiftc -parse-as-library scripts/run-swift-tests.swift \
				-F "$$platform_framework_dir" \
				-framework Testing \
				-Xlinker -rpath \
				-Xlinker "$$platform_framework_dir" \
				-Xlinker -rpath \
				-Xlinker "$$platform_path/Developer/usr/lib" \
				-o .build/run-swift-tests; \
		else \
			echo "could not locate the Swift Testing runtime" >&2; \
			exit 1; \
		fi; \
		test_binary=".build/debug/CodexUsageBarPackageTests.xctest/Contents/MacOS/CodexUsageBarPackageTests"; \
		if output="$$(.build/run-swift-tests "$$test_binary" 2>&1)"; then \
			status=0; \
		else \
			status=$$?; \
		fi; \
		printf '%s\n' "$$output"; \
		if [ "$$status" -ne 0 ]; then exit "$$status"; fi; \
		printf '%s\n' "$$output" | /bin/bash scripts/verify-swift-test-output.sh; \
	else \
		swift test --disable-xctest --enable-swift-testing; \
	fi
	@if [ "$$(uname -s)" = Darwin ]; then \
		xcrun swift run CodexUsageChecks; \
	else \
		swift run CodexUsageChecks; \
	fi
	@exit_code=0; .build/debug/CodexUsageChecks --unknown-check-option >/dev/null 2>&1 || exit_code=$$?; \
		test "$$exit_code" -eq 64

strict-concurrency:
	@set -e; test "$$(uname -s)" = Darwin || { \
		echo "strict-concurrency requires the macOS Swift targets" >&2; exit 1; \
	}; \
	developer_dir="$$(xcode-select -p)"; \
	export DEVELOPER_DIR="$$developer_dir"; \
	xcrun swift build --scratch-path .build/strict-concurrency --build-tests \
		--disable-xctest --enable-swift-testing \
		-Xswiftc -strict-concurrency=complete \
		-Xswiftc -warnings-as-errors

macos-smoke-check:
	@set -e; test "$$(uname -s)" = Darwin || { \
		echo "macos-smoke-check requires macOS" >&2; exit 1; \
	}
	swift build --product CodexUsageBar
	@/bin/bash scripts/smoke-macos-check.sh

coverage:
	$(MAKE) test
	mkdir -p .build/coverage/profiles
	rm -f .build/coverage/profiles/*.profraw .build/coverage/tests.profdata .build/coverage/coverage.json
	@set -e; if [ "$$(uname -s)" = Darwin ]; then \
		developer_dir="$$(xcode-select -p)"; \
		export DEVELOPER_DIR="$$developer_dir"; \
		xcrun swift build --scratch-path .build/coverage --build-tests \
			--disable-xctest --enable-swift-testing --enable-code-coverage; \
		xcrun swift build --scratch-path .build/coverage \
			--product CodexUsageChecks --enable-code-coverage; \
		xcrun swift build --scratch-path .build/coverage \
			--product CodexUsageVisualChecks --enable-code-coverage; \
		test_binary=".build/coverage/debug/CodexUsageBarPackageTests.xctest/Contents/MacOS/CodexUsageBarPackageTests"; \
		if output="$$(LLVM_PROFILE_FILE="$$PWD/.build/coverage/profiles/tests-%p.profraw" \
			.build/run-swift-tests "$$test_binary" 2>&1)"; then \
			status=0; \
		else \
			status=$$?; \
		fi; \
		printf '%s\n' "$$output"; \
		if [ "$$status" -ne 0 ]; then exit "$$status"; fi; \
		printf '%s\n' "$$output" | /bin/bash scripts/verify-swift-test-output.sh; \
		mkdir -p .build/coverage/popover-snapshots; \
		LLVM_PROFILE_FILE="$$PWD/.build/coverage/profiles/checks-%p.profraw" \
			.build/coverage/debug/CodexUsageChecks; \
		LLVM_PROFILE_FILE="$$PWD/.build/coverage/profiles/visual-%p.profraw" \
			.build/coverage/debug/CodexUsageVisualChecks; \
		for timeframe in seven thirty ninety all; do \
			LLVM_PROFILE_FILE="$$PWD/.build/coverage/profiles/app-success-$$timeframe-%p.profraw" \
				.build/coverage/debug/CodexUsageBar \
				--render-popover "$$PWD/.build/coverage/popover-snapshots/success-$$timeframe.png" \
				--appearance light --timeframe "$$timeframe" --fixture success \
				--width 300 --height 1400; \
		done; \
		for fixture in loading error stale missing-daily empty-daily zero overflow partial malformed-rate login-approval; do \
			LLVM_PROFILE_FILE="$$PWD/.build/coverage/profiles/app-$$fixture-%p.profraw" \
				.build/coverage/debug/CodexUsageBar \
				--render-popover "$$PWD/.build/coverage/popover-snapshots/$$fixture.png" \
				--appearance light --timeframe all --fixture "$$fixture" \
				--width 300 --height 1400; \
		done; \
		LLVM_PROFILE_FILE="$$PWD/.build/coverage/profiles/app-dark-%p.profraw" \
			.build/coverage/debug/CodexUsageBar \
			--render-popover "$$PWD/.build/coverage/popover-snapshots/success-dark.png" \
			--appearance dark --timeframe all --fixture success \
			--width 300 --height 1400; \
		xcrun llvm-profdata merge -sparse .build/coverage/profiles/*.profraw \
			-o .build/coverage/tests.profdata; \
		xcrun llvm-cov export "$$test_binary" \
			-object=.build/coverage/debug/CodexUsageChecks \
			-object=.build/coverage/debug/CodexUsageVisualChecks \
			-object=.build/coverage/debug/CodexUsageBar \
			-instr-profile=.build/coverage/tests.profdata \
			-format=text > .build/coverage/coverage.json; \
		xcrun llvm-cov report "$$test_binary" \
			-object=.build/coverage/debug/CodexUsageChecks \
			-object=.build/coverage/debug/CodexUsageVisualChecks \
			-object=.build/coverage/debug/CodexUsageBar \
			-instr-profile=.build/coverage/tests.profdata \
			"$$PWD/Sources"; \
	else \
		swift test --scratch-path .build/coverage --disable-xctest \
			--enable-swift-testing --enable-code-coverage; \
	fi

visual-test:
	swift build --product CodexUsageBar
	swift run CodexUsageVisualChecks
	mkdir -p .build/popover-snapshots
	rm -f .build/popover-snapshots/popover-light.png \
		.build/popover-snapshots/popover-light-repeat.png \
		.build/popover-snapshots/popover-light-narrow.png \
		.build/popover-snapshots/popover-dark.png \
		.build/popover-snapshots/popover-height-560.png \
		.build/popover-snapshots/popover-height-999.png \
		.build/popover-snapshots/popover-height-1000.png \
		.build/popover-snapshots/popover-height-1200.png \
		.build/popover-snapshots/state-loading.png \
		.build/popover-snapshots/state-error.png \
		.build/popover-snapshots/state-stale.png \
		.build/popover-snapshots/state-missing-daily.png \
		.build/popover-snapshots/state-empty-daily.png \
		.build/popover-snapshots/state-zero.png \
		.build/popover-snapshots/state-overflow.png \
		.build/popover-snapshots/state-partial.png \
		.build/popover-snapshots/state-malformed-rate.png \
		.build/popover-snapshots/state-login-approval.png \
		.build/popover-snapshots/state-accessibility-text.png \
		.build/popover-snapshots/state-success-all.png \
		.build/popover-snapshots/state-success-all-tall.png \
		.build/popover-snapshots/state-success-thirty-tall.png \
		.build/popover-snapshots/invalid.png
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/popover-light.png" --appearance light --timeframe thirty --width 300 --height 560
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/popover-light-repeat.png" --appearance light --timeframe thirty --width 300 --height 560
	cmp ".build/popover-snapshots/popover-light.png" ".build/popover-snapshots/popover-light-repeat.png"
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/popover-light-narrow.png" --appearance light --timeframe thirty --width 260 --height 1400
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/popover-dark.png" --appearance dark --timeframe all --width 300 --height 1400
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/popover-height-560.png" --appearance light --timeframe thirty --width 260 --height 560
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/popover-height-999.png" --appearance light --timeframe thirty --width 260 --height 999
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/popover-height-1000.png" --appearance light --timeframe thirty --width 260 --height 1000
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/popover-height-1200.png" --appearance light --timeframe thirty --width 260 --height 1200
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-loading.png" --appearance light --timeframe thirty --fixture loading --width 300 --height 560
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-error.png" --appearance light --timeframe thirty --fixture error --width 300 --height 560
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-stale.png" --appearance light --timeframe thirty --fixture stale --width 300 --height 560
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-success-all.png" --appearance light --timeframe all --fixture success --width 300 --height 560
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-missing-daily.png" --appearance light --timeframe all --fixture missing-daily --width 300 --height 560
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-empty-daily.png" --appearance light --timeframe all --fixture empty-daily --width 300 --height 560
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-zero.png" --appearance light --timeframe thirty --fixture zero --width 300 --height 560
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-overflow.png" --appearance light --timeframe all --fixture overflow --width 300 --height 560
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-success-all-tall.png" --appearance light --timeframe all --fixture success --width 300 --height 1400
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-partial.png" --appearance light --timeframe all --fixture partial --width 300 --height 1400
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-success-thirty-tall.png" --appearance light --timeframe thirty --fixture success --width 300 --height 1400
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-malformed-rate.png" --appearance light --timeframe thirty --fixture malformed-rate --width 300 --height 1400
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-login-approval.png" --appearance light --timeframe thirty --fixture login-approval --width 300 --height 1400
	.build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/state-accessibility-text.png" --appearance light --timeframe thirty --fixture success --text-size accessibility --width 300 --height 560
	@if cmp -s ".build/popover-snapshots/popover-light.png" ".build/popover-snapshots/state-loading.png"; then echo "FAIL loading fixture matches success"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/popover-light.png" ".build/popover-snapshots/state-error.png"; then echo "FAIL error fixture matches success"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/popover-light.png" ".build/popover-snapshots/state-stale.png"; then echo "FAIL stale fixture matches success"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/popover-light.png" ".build/popover-snapshots/state-zero.png"; then echo "FAIL zero fixture matches success"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/state-success-all.png" ".build/popover-snapshots/state-overflow.png"; then echo "FAIL overflow fixture matches success"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/state-missing-daily.png" ".build/popover-snapshots/state-overflow.png"; then echo "FAIL overflow and missing-daily fixtures match"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/state-loading.png" ".build/popover-snapshots/state-error.png"; then echo "FAIL loading and error fixtures match"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/state-success-all.png" ".build/popover-snapshots/state-missing-daily.png"; then echo "FAIL missing-daily fixture matches success"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/state-empty-daily.png" ".build/popover-snapshots/state-missing-daily.png"; then echo "FAIL empty-daily fixture matches unavailable daily data"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/state-empty-daily.png" ".build/popover-snapshots/state-zero.png"; then echo "FAIL empty-daily fixture matches populated zero history"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/state-success-all-tall.png" ".build/popover-snapshots/state-partial.png"; then echo "FAIL partial fixture matches success"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/state-success-thirty-tall.png" ".build/popover-snapshots/state-malformed-rate.png"; then echo "FAIL malformed-rate fixture matches success"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/state-success-thirty-tall.png" ".build/popover-snapshots/state-login-approval.png"; then echo "FAIL login-approval fixture matches success"; exit 1; fi
	@if cmp -s ".build/popover-snapshots/popover-light.png" ".build/popover-snapshots/state-accessibility-text.png"; then echo "FAIL accessibility text fixture matches standard text"; exit 1; fi
	@exit_code=0; .build/debug/CodexUsageBar --render-popover --appearance dark >/dev/null 2>&1 || exit_code=$$?; \
		test "$$exit_code" -eq 1
	@exit_code=0; .build/debug/CodexUsageBar --render-popover ".build/popover-snapshots/invalid.png" --width 260.5 >/dev/null 2>&1 || exit_code=$$?; \
		test "$$exit_code" -eq 1
	@exit_code=0; .build/debug/CodexUsageVisualChecks --unknown-visual-option >/dev/null 2>&1 || exit_code=$$?; \
		test "$$exit_code" -eq 64

run: app
	open ".build/Codex Usage Bar.app"

app: check-version
	./scripts/build-app.sh

install: check-version
	@set -e; home="$${HOME:?HOME must be set and nonempty for make install}"; \
		APP_OUTPUT_DIR="$$home/Applications" ./scripts/build-app.sh; \
		/usr/bin/open "$$home/Applications/Codex Usage Bar.app"

# Cleanup is intentionally explicit and is never part of verify or CI.
clean:
	@set -e; case "$$(uname -s)" in \
		Darwin) swift package clean ;; \
		Linux) $(MAKE) -C linux clean ;; \
		*) echo "clean is supported on macOS and Linux" >&2; exit 1 ;; \
	esac

distclean:
	rm -rf .build .swiftpm linux/target \
		linux/packaging/arch/src linux/packaging/arch/pkg
	rm -f linux/packaging/arch/codex-usage-bar-*.tar.gz \
		linux/packaging/arch/codex-usage-bar-*.pkg.tar.*
