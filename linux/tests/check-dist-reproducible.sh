#!/usr/bin/env bash
set -euo pipefail

LINUX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$LINUX_ROOT/../VERSION")"
ARCHIVE_NAME="codex-usage-bar-$VERSION.tar.gz"
ARCHIVE="$LINUX_ROOT/target/dist/$ARCHIVE_NAME"

mkdir -p "$LINUX_ROOT/target"
work_dir="$(mktemp -d "$LINUX_ROOT/target/dist-check.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

make -C "$LINUX_ROOT" dist >/dev/null
cp "$ARCHIVE" "$work_dir/first.tar.gz"
make -C "$LINUX_ROOT" dist >/dev/null
cmp "$work_dir/first.tar.gz" "$ARCHIVE"

(
    cd "$LINUX_ROOT/target/dist"
    b2sum -c "$ARCHIVE_NAME.b2"
)

mkdir -p "$work_dir/unpacked"
tar -xzf "$work_dir/first.tar.gz" -C "$work_dir/unpacked"
unpacked_root="$work_dir/unpacked/codex-usage-bar-$VERSION"
test -f "$unpacked_root/.source-date-epoch"
test -f "$unpacked_root/Fixtures/Protocol/rate-limit-contracts.json"
test -f "$unpacked_root/linux/Cargo.toml"

recorded_epoch="$(tr -d '\r\n' < "$unpacked_root/.source-date-epoch")"
[[ "$recorded_epoch" =~ ^[0-9]+$ ]]
make -C "$unpacked_root/linux" dist \
    SOURCE_DATE_EPOCH="$recorded_epoch" >/dev/null
cmp "$work_dir/first.tar.gz" \
    "$unpacked_root/linux/target/dist/$ARCHIVE_NAME"

printf 'Reproducible archive verified: %s\n' "$ARCHIVE_NAME"
