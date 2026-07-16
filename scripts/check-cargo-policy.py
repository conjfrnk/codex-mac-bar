#!/usr/bin/env python3
"""Validate Cargo dependency licenses and sources from `cargo metadata` JSON."""

from __future__ import annotations

import json
import re
import sys


ALLOWED_LICENSES = {
    "0BSD",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "BSL-1.0",
    "CC0-1.0",
    "ISC",
    "LGPL-2.1-or-later",
    "MIT",
    "MIT-0",
    "MPL-2.0",
    "Unicode-3.0",
    "Unicode-DFS-2016",
    "Unlicense",
    "Zlib",
}
ALLOWED_EXCEPTIONS = {"LLVM-exception"}
OPERATORS = {"AND", "OR", "WITH"}
CRATES_IO_SOURCE = "registry+https://github.com/rust-lang/crates.io-index"


def license_identifiers(expression: str) -> set[str]:
    tokens = set(re.findall(r"[A-Za-z0-9][A-Za-z0-9.+-]*", expression))
    return tokens - OPERATORS


def main() -> None:
    try:
        metadata = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeError) as error:
        raise SystemExit(f"could not parse cargo metadata JSON: {error}") from error

    workspace_members = set(metadata.get("workspace_members", []))
    problems: list[str] = []
    checked = 0
    for package in sorted(metadata.get("packages", []), key=lambda value: (value["name"], value["version"])):
        checked += 1
        label = f"{package['name']} {package['version']}"
        expression = package.get("license")
        if not expression:
            problems.append(f"{label}: missing SPDX license expression")
        else:
            identifiers = license_identifiers(expression)
            unsupported = identifiers - ALLOWED_LICENSES - ALLOWED_EXCEPTIONS
            if unsupported:
                problems.append(
                    f"{label}: license expression {expression!r} contains unapproved identifiers "
                    + ", ".join(sorted(unsupported))
                )

        source = package.get("source")
        if package["id"] in workspace_members:
            if source is not None:
                problems.append(f"{label}: workspace package unexpectedly has external source {source}")
        elif source != CRATES_IO_SOURCE:
            problems.append(f"{label}: dependency source is not crates.io: {source or '<path>'}")

    if checked == 0:
        problems.append("cargo metadata contained no packages")
    if problems:
        print("Cargo dependency policy failed:", file=sys.stderr)
        for problem in problems:
            print(f"- {problem}", file=sys.stderr)
        raise SystemExit(1)

    print(f"Cargo dependency license/source policy passed for {checked} packages.")


if __name__ == "__main__":
    main()
