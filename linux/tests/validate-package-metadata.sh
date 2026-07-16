#!/usr/bin/env bash
set -euo pipefail

LINUX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$LINUX_ROOT/../VERSION")"
ARCHIVE="${1:-$LINUX_ROOT/target/dist/codex-usage-bar-$VERSION.tar.gz}"
PKGBUILD="$LINUX_ROOT/packaging/arch/PKGBUILD"
ARCHIVE_MARKER="$LINUX_ROOT/../.source-date-epoch"

for command in b2sum desktop-file-validate python3; do
    command -v "$command" >/dev/null || {
        printf 'package metadata validation requires %s\n' "$command" >&2
        exit 1
    }
done

test -f "$ARCHIVE"
test -f "$ARCHIVE.b2"
(
    cd "$(dirname "$ARCHIVE")"
    b2sum -c "$(basename "$ARCHIVE").b2"
)

if [[ -f "$PKGBUILD" ]]; then
    bash -n "$PKGBUILD"
    pkgver="$(sed -n 's/^pkgver=//p' "$PKGBUILD")"
    test "$pkgver" = "$VERSION"
    expected_sum="$(b2sum "$ARCHIVE" | awk '{ print $1 }')"
    declared_sum="$(sed -n "s/^b2sums=('\([^']*\)').*/\1/p" "$PKGBUILD")"
    if [[ "$declared_sum" != "$expected_sum" ]]; then
        printf 'PKGBUILD checksum drift: expected %s, found %s\n' \
            "$expected_sum" "${declared_sum:-<missing>}" >&2
        exit 1
    fi

    grep -Fq 'releases/download/v$pkgver/$pkgname-$pkgver.tar.gz' "$PKGBUILD"
    grep -Fq 'cd "$pkgname-$pkgver/linux"' "$PKGBUILD"
elif [[ -f "$ARCHIVE_MARKER" ]]; then
    printf 'Source archive mode: skipping repository-only PKGBUILD checks.\n'
else
    printf 'Missing repository PKGBUILD: %s\n' "$PKGBUILD" >&2
    exit 1
fi
desktop-file-validate "$LINUX_ROOT/data/io.github.conjfrnk.CodexUsageBar.desktop"

python3 - "$LINUX_ROOT/data/codex-usage-bar.svg" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

path = Path(sys.argv[1])
root = ET.parse(path).getroot()
if root.tag != "{http://www.w3.org/2000/svg}svg":
    raise SystemExit("icon root is not an SVG element")
if root.attrib.get("viewBox") != "0 0 256 256":
    raise SystemExit("icon must retain its canonical 256x256 viewBox")
PY

printf 'Available package metadata and checksum verified for %s.\n' "$VERSION"
