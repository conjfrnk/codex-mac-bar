#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

output="$(cat)"
expected_count="$({
    awk '
        /^[[:space:]]*@Test([[:space:]]*\(|[[:space:]]*$)/ { count += 1 }
        END { print count + 0 }
    ' Tests/*Tests/*.swift
} 2>/dev/null)"

if [[ ! "$expected_count" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Could not derive a nonzero Swift test count from Tests/.\n' >&2
    exit 1
fi

for suite in DataAndChartTests TransportTests UIStateTests RendererTests; do
    if ! grep -Fq "Suite $suite passed" <<<"$output"; then
        printf 'Swift Testing did not report a passing %s suite.\n' "$suite" >&2
        exit 1
    fi
done

if ! grep -Eq "Test run with ${expected_count} tests in 4 suites passed" <<<"$output"; then
    printf 'Swift Testing summary did not match all %s declared tests in four suites.\n' \
        "$expected_count" >&2
    exit 1
fi
