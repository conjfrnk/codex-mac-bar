#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

[[ -f "$VERSION_FILE" ]] || {
    printf 'Missing canonical VERSION file.\n' >&2
    exit 1
}

version="$(tr -d '\r\n' < "$VERSION_FILE")"
line_count="$(awk 'END { print NR + 0 }' "$VERSION_FILE")"
if [[ "$line_count" -ne 1 || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'VERSION must contain exactly one stable x.y.z version.\n' >&2
    exit 1
fi

cargo_version="$(awk '
    /^\[package\]$/ { in_package = 1; next }
    /^\[/ { in_package = 0 }
    in_package && /^version[[:space:]]*=/ {
        value = $0
        sub(/^[^=]*=[[:space:]]*"/, "", value)
        sub(/"[[:space:]]*$/, "", value)
        print value
        exit
    }
' "$ROOT_DIR/linux/Cargo.toml")"

lock_version="$(awk '
    $0 == "name = \"codex-usage-bar-linux\"" { found = 1; next }
    found && /^version = / {
        value = $0
        sub(/^version = "/, "", value)
        sub(/"$/, "", value)
        print value
        exit
    }
' "$ROOT_DIR/linux/Cargo.lock")"

pkgbuild_version="$(sed -n 's/^pkgver=//p' "$ROOT_DIR/linux/packaging/arch/PKGBUILD")"

check_copy() {
    local label="$1"
    local actual="$2"
    if [[ "$actual" != "$version" ]]; then
        printf '%s version drift: expected %s, found %s\n' \
            "$label" "$version" "${actual:-<missing>}" >&2
        exit 1
    fi
}

check_copy 'linux/Cargo.toml' "$cargo_version"
check_copy 'linux/Cargo.lock' "$lock_version"
check_copy 'linux/packaging/arch/PKGBUILD' "$pkgbuild_version"

grep -Fq 'VERSION_FILE' "$ROOT_DIR/linux/Makefile" || {
    printf 'linux/Makefile must derive its version from VERSION_FILE.\n' >&2
    exit 1
}
grep -Fq 'APP_VERSION="$(< "$ROOT_DIR/VERSION")"' \
    "$ROOT_DIR/scripts/build-app.sh" || {
    printf 'scripts/build-app.sh must derive bundle metadata from APP_VERSION.\n' >&2
    exit 1
}
for bundle_key in CFBundleVersion CFBundleShortVersionString; do
    grep -Fq "$bundle_key string \$APP_VERSION" "$ROOT_DIR/scripts/build-app.sh" || {
        printf 'scripts/build-app.sh must set %s from APP_VERSION.\n' "$bundle_key" >&2
        exit 1
    }
done

printf 'Version metadata agrees on %s.\n' "$version"
