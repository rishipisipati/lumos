#!/usr/bin/env python3
"""Create or remove the Lumos million-file stress folder.

Usage:
  python3 scripts/stress_files.py generate [--workers 8]
  python3 scripts/stress_files.py status
  python3 scripts/stress_files.py delete [--workers 8]

Default folder: ~/Documents/Stress Test Lumos
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

DEFAULT_FOLDER_NAME = "Stress Test Lumos"
FILE_COUNT = 1_000_000
BUCKET_COUNT = 1000
LARGE_FILE_COUNT = 4
LARGE_FILE_BYTES = 11 * 1024 * 1024
PROGRESS_EVERY = 20_000
PATTERNS = (
    "report-{stem}.txt",
    "foo-{stem}.dat",
    "bar-{stem}.dat",
    "note-{stem}.pdf",
    "img-{stem}.png",
    "pic-{stem}.jpg",
    "hex-{stem}.bin",
)


def documents_folder() -> Path:
    return Path.home() / "Documents"


def default_target() -> Path:
    return documents_folder() / DEFAULT_FOLDER_NAME


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create or remove the Lumos million-file stress folder."
    )
    parser.add_argument(
        "command",
        choices=("generate", "delete", "status"),
        help="generate files, delete the folder, or print counts",
    )
    parser.add_argument(
        "--folder",
        dest="folder",
        help="Destination folder (default: ~/Documents/Stress Test Lumos)",
    )
    parser.add_argument(
        "--count",
        dest="count",
        type=int,
        help=f"How many tiny files to create (default: {FILE_COUNT})",
    )
    parser.add_argument(
        "--workers",
        dest="workers",
        type=int,
        default=1,
        help="Processes used to create or delete buckets in parallel (default: 1)",
    )
    parsed = parser.parse_args(argv)
    if parsed.folder is None:
        parsed.folder = str(default_target())
    if parsed.count is None:
        parsed.count = FILE_COUNT
    if parsed.count <= 0:
        parser.error("--count must be greater than 0")
    return parsed


def count_files(folder: Path) -> int:
    if not folder.exists():
        return 0
    total = 0
    for _root, _dirs, files in os.walk(folder):
        total += len(files)
    return total


def print_status(folder: Path) -> None:
    if not folder.exists():
        print(f"missing\t{folder}")
        return
    files = count_files(folder)
    size = 0
    for root, _dirs, names in os.walk(folder):
        for name in names:
            size += (Path(root) / name).stat().st_size
    print(f"folder\t{folder}")
    print(f"files\t{files}")
    print(f"bytes\t{size}")


def write_tiny(path: Path, payload: bytes) -> None:
    path.write_bytes(payload)


def write_large(path: Path, size: int) -> None:
    chunk = b"\0" * (1024 * 1024)
    remaining = size
    with path.open("wb") as handle:
        while remaining > 0:
            n = min(len(chunk), remaining)
            handle.write(chunk[:n])
            remaining -= n


def bucket_sizes(count: int) -> list[int]:
    bucket_size, extra = divmod(count, BUCKET_COUNT)
    return [bucket_size + (1 if index < extra else 0) for index in range(BUCKET_COUNT)]


def fill_bucket(task: tuple[str, int, int]) -> int:
    folder, bucket_index, n = task
    bucket = Path(folder) / f"b{bucket_index:04d}"
    bucket.mkdir(exist_ok=True)
    for item in range(n):
        stem = f"{bucket_index:04d}-{item:04d}"
        name = PATTERNS[item % len(PATTERNS)].format(stem=stem)
        write_tiny(bucket / name, name.encode("utf-8") + b"\n")
    return n


def generate(folder: Path, count: int, workers: int) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    started = time.time()
    created = 0
    specials = [
        folder / "report-root.txt",
        folder / "foo-root.dat",
        folder / "bar-root.dat",
        folder / "sample.pdf",
        folder / "sample.png",
        folder / "sample.jpg",
    ]
    for path in specials:
        write_tiny(path, path.name.encode("utf-8") + b"\n")
        created += 1
    large_dir = folder / "large"
    large_dir.mkdir(exist_ok=True)
    for index in range(LARGE_FILE_COUNT):
        write_large(large_dir / f"blob-{index:02d}.bin", LARGE_FILE_BYTES)
        created += 1
    tasks = [(str(folder), index, n) for index, n in enumerate(bucket_sizes(count))]
    if workers <= 1:
        results = map(fill_bucket, tasks)
        for n in results:
            created += n
            if created % PROGRESS_EVERY < n:
                print(f"created {created} files in {time.time() - started:.1f}s", flush=True)
    else:
        with ProcessPoolExecutor(max_workers=workers) as pool:
            for n in pool.map(fill_bucket, tasks, chunksize=8):
                created += n
                if created % PROGRESS_EVERY < n:
                    print(f"created {created} files in {time.time() - started:.1f}s", flush=True)
    elapsed = time.time() - started
    print(f"done {created} files in {folder} ({elapsed:.1f}s)")


def remove_tree(path: str) -> None:
    shutil.rmtree(path, ignore_errors=False)


def delete_folder(folder: Path, workers: int) -> None:
    if not folder.exists():
        print(f"already gone\t{folder}")
        return
    started = time.time()
    if workers > 1:
        buckets = [str(child) for child in folder.iterdir() if child.is_dir()]
        with ProcessPoolExecutor(max_workers=workers) as pool:
            list(pool.map(remove_tree, buckets, chunksize=8))
    shutil.rmtree(folder)
    print(f"deleted\t{folder} ({time.time() - started:.1f}s)")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    folder = Path(args.folder).expanduser()
    if args.command == "status":
        print_status(folder)
        return 0
    if args.command == "delete":
        delete_folder(folder, args.workers)
        return 0
    generate(folder, args.count, args.workers)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
