.PHONY: build test run app

build:
	swift build

test:
	swift run CodexUsageChecks

run:
	swift run CodexUsageBar

app:
	./scripts/build-app.sh
