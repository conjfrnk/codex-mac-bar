#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$REPOSITORY_ROOT/.build/debug/CodexUsageBar"

test "$(uname -s)" = Darwin || {
    printf 'macOS executable smoke check requires macOS\n' >&2
    exit 1
}
test -x "$BINARY" || {
    printf 'missing executable: %s (run swift build --product CodexUsageBar)\n' "$BINARY" >&2
    exit 1
}

temporary_root="${TMPDIR:-/tmp}"
work_dir="$(mktemp -d "${temporary_root%/}/CodexUsageBar-smoke.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$work_dir/home" "$work_dir/tmp"
today="$(date -u +%F)"
fake_codex="$work_dir/codex"

apply_fake_server() {
    sed "s/__TODAY__/$today/g" > "$fake_codex" <<'EOF'
#!/bin/sh
set -eu
test "$#" -eq 2
test "$1" = app-server
test "$2" = --stdio
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"id":2'*) printf '%s\n' '{"id":2,"result":{"summary":{"lifetimeTokens":7,"peakDailyTokens":7,"currentStreakDays":1,"longestStreakDays":1},"dailyUsageBuckets":[{"startDate":"__TODAY__","tokens":7}]}}' ;;
    *'"id":3'*) printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42}}}}' ;;
  esac
done
EOF
}

apply_fake_server
chmod 700 "$fake_codex"

isolated_environment=(
    HOME="$work_dir/home"
    CFFIXED_USER_HOME="$work_dir/home"
    TMPDIR="$work_dir/tmp"
    PATH=/usr/bin:/bin
    CODEX_USAGE_BAR_CODEX_PATH="$fake_codex"
)

output="$(env -i "${isolated_environment[@]}" "$BINARY" --check)"
expected='PASS Codex app-server connection; usage available; rate limits available'
test "$output" = "$expected" || {
    printf 'unexpected --check output: %s\n' "$output" >&2
    exit 1
}
if [[ "$output" == *7* ]]; then
    printf '%s\n' '--check leaked the fake account usage value' >&2
    exit 1
fi

set +e
invalid_output="$(env -i "${isolated_environment[@]}" \
    "$BINARY" --check --unknown-check-option 2>&1)"
invalid_status=$?
set -e
test "$invalid_status" -eq 1
grep -Fq 'FAIL --check must be used by itself' <<<"$invalid_output"

printf 'Hermetic macOS executable check passed.\n'
