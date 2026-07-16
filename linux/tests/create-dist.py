#!/usr/bin/env python3
"""Create the deterministic Linux source archive used by releases and packaging."""

from __future__ import annotations

import argparse
import gzip
import io
import os
from pathlib import Path
import re
import tarfile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--epoch", required=True, type=int)
    return parser.parse_args()


def collect_files(repository_root: Path) -> dict[Path, bytes]:
    linux_root = repository_root / "linux"
    files: dict[Path, bytes] = {}

    for relative in [Path("LICENSE"), Path("VERSION")]:
        source = repository_root / relative
        if not source.is_file() or source.is_symlink():
            raise SystemExit(f"required distribution input is not a regular file: {source}")
        files[relative] = source.read_bytes()

    fixed_linux_files = ["Cargo.toml", "Cargo.lock", "Makefile", "README.md"]
    for name in fixed_linux_files:
        source = linux_root / name
        if not source.is_file() or source.is_symlink():
            raise SystemExit(f"required distribution input is not a regular file: {source}")
        files[Path("linux") / name] = source.read_bytes()

    for directory in [repository_root / "Fixtures", linux_root / "src", linux_root / "data", linux_root / "tests"]:
        if not directory.is_dir() or directory.is_symlink():
            raise SystemExit(f"required distribution input is not a directory: {directory}")
        for source in sorted(directory.rglob("*")):
            if source.is_symlink():
                raise SystemExit(f"distribution input must not be a symlink: {source}")
            if source.is_dir():
                continue
            if not source.is_file():
                raise SystemExit(f"distribution input must be a regular file: {source}")
            if "__pycache__" in source.parts or source.suffix in {".pyc", ".pyo"}:
                continue
            files[source.relative_to(repository_root)] = source.read_bytes()

    return files


def add_directory(archive: tarfile.TarFile, name: str, epoch: int) -> None:
    info = tarfile.TarInfo(name.rstrip("/") + "/")
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = epoch
    archive.addfile(info)


def add_file(archive: tarfile.TarFile, name: str, content: bytes, epoch: int) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = 0o644
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = epoch
    archive.addfile(info, io.BytesIO(content))


def main() -> None:
    args = parse_args()
    if args.epoch < 0:
        raise SystemExit("SOURCE_DATE_EPOCH must be nonnegative")

    linux_root = Path(__file__).resolve().parents[1]
    repository_root = linux_root.parent
    version_lines = (repository_root / "VERSION").read_text(encoding="utf-8").splitlines()
    if len(version_lines) != 1 or re.fullmatch(
        r"[0-9]+\.[0-9]+\.[0-9]+", version_lines[0]
    ) is None:
        raise SystemExit("VERSION must contain exactly one stable x.y.z line")
    version = version_lines[0]

    archive_root = f"codex-usage-bar-{version}"
    files = collect_files(repository_root)
    files[Path(".source-date-epoch")] = f"{args.epoch}\n".encode()

    directories = {Path(".")}
    for relative in files:
        directories.update(relative.parents)

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp.{os.getpid()}")
    try:
        with temporary.open("wb") as raw_output:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw_output, compresslevel=9, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                    add_directory(archive, archive_root, args.epoch)
                    for directory in sorted(path for path in directories if path != Path(".")):
                        add_directory(archive, f"{archive_root}/{directory.as_posix()}", args.epoch)
                    for relative, content in sorted(files.items()):
                        add_file(archive, f"{archive_root}/{relative.as_posix()}", content, args.epoch)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
