#!/usr/bin/env bash
set -euo pipefail

LINUX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$LINUX_ROOT/../VERSION")"
ARCHIVE_NAME="codex-usage-bar-$VERSION.tar.gz"
ARCHIVE="$LINUX_ROOT/target/dist/$ARCHIVE_NAME"

mkdir -p "$LINUX_ROOT/target"
work_dir="$(mktemp -d "$LINUX_ROOT/target/package-smoke.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

stage="$work_dir/stage"
make -C "$LINUX_ROOT" install PREFIX=/usr DESTDIR="$stage" >/dev/null
binary="$stage/usr/bin/codex-usage-bar"

expected_files=(
    "$binary"
    "$stage/usr/share/applications/io.github.conjfrnk.CodexUsageBar.desktop"
    "$stage/usr/share/icons/hicolor/scalable/apps/codex-usage-bar.svg"
    "$stage/usr/share/doc/codex-usage-bar/waybar-module.jsonc"
    "$stage/usr/share/doc/codex-usage-bar/waybar-style.css"
    "$stage/usr/share/licenses/codex-usage-bar/LICENSE"
)
for path in "${expected_files[@]}"; do
    test -f "$path" || { printf 'staged install is missing %s\n' "$path" >&2; exit 1; }
done
test -x "$binary"
test "$(find "$stage" -type f | wc -l | tr -d ' ')" -eq "${#expected_files[@]}"
test "$(stat -c '%a' "$binary")" = 755
for path in "${expected_files[@]:1}"; do
    test "$(stat -c '%a' "$path")" = 644
done
cmp "$stage/usr/share/licenses/codex-usage-bar/LICENSE" "$LINUX_ROOT/../LICENSE"
desktop-file-validate \
    "$stage/usr/share/applications/io.github.conjfrnk.CodexUsageBar.desktop"
python3 - "$stage/usr/share/icons/hicolor/scalable/apps/codex-usage-bar.svg" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
if root.tag != "{http://www.w3.org/2000/svg}svg" or root.attrib.get("viewBox") != "0 0 256 256":
    raise SystemExit("staged icon is not the validated canonical SVG")
PY

"$binary" --help | grep -Fq 'Usage: codex-usage-bar'
test "$("$binary" --version)" = "codex-usage-bar $VERSION"
set +e
invalid_output="$("$binary" --definitely-invalid 2>&1)"
invalid_status=$?
set -e
test "$invalid_status" -eq 64
grep -Fq 'unknown argument' <<<"$invalid_output"

today="$(date -u +%F)"
fake_codex="$work_dir/codex"
cat > "$fake_codex" <<EOF
#!/bin/sh
set -eu
while IFS= read -r line; do
  case "\$line" in
    *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"id":2'*) printf '%s\n' '{"id":2,"result":{"summary":{"lifetimeTokens":7,"peakDailyTokens":7,"currentStreakDays":1,"longestStreakDays":1},"dailyUsageBuckets":[{"startDate":"$today","tokens":7}]}}' ;;
    *'"id":3'*) printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42}}}}' ;;
  esac
done
EOF
chmod 700 "$fake_codex"
mkdir -p "$work_dir/home" "$work_dir/config"

common_environment=(
    HOME="$work_dir/home"
    XDG_CONFIG_HOME="$work_dir/config"
    CODEX_USAGE_BAR_CODEX_PATH="$fake_codex"
)
check_output="$(env "${common_environment[@]}" "$binary" --check)"
grep -Fq 'Codex app-server connection OK' <<<"$check_output"

waybar_output="$(env "${common_environment[@]}" "$binary" --waybar)"
python3 - "$waybar_output" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
if value.get("class") != "ready":
    raise SystemExit(f"unexpected Waybar class: {value!r}")
if "7" not in value.get("text", ""):
    raise SystemExit(f"Waybar text does not include fake-server usage: {value!r}")
if value.get("percentage") != 100:
    raise SystemExit(f"unexpected Waybar percentage: {value!r}")
PY

if [[ "${CODEX_USAGE_BAR_NESTED_ARCHIVE_SMOKE:-0}" == 1 \
    && -f "$LINUX_ROOT/../.source-date-epoch" ]]; then
    printf 'Installed source-archive package smoke checks passed for %s.\n' "$VERSION"
    exit 0
fi

mkdir -p "$work_dir/archive"
tar -xzf "$ARCHIVE" -C "$work_dir/archive"
archive_root="$work_dir/archive/codex-usage-bar-$VERSION"
archive_linux="$archive_root/linux"
test -f "$archive_root/Fixtures/Protocol/rate-limit-contracts.json"
CODEX_USAGE_BAR_NESTED_ARCHIVE_SMOKE=1 \
    make -C "$archive_linux" test package-test
archive_binary="$archive_linux/target/release/codex-usage-bar"
"$archive_binary" --help | grep -Fq 'Usage: codex-usage-bar'
test "$("$archive_binary" --version)" = "codex-usage-bar $VERSION"

printf 'Installed and archived Linux package smoke checks passed for %s.\n' "$VERSION"
