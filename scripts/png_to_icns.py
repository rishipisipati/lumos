#!/usr/bin/env python3
import struct
import sys
from pathlib import Path


def png_to_icns(png_path: Path, icns_path: Path) -> None:
    png = png_path.read_bytes()
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{png_path} is not a PNG file")
    chunk_len = 8 + len(png)
    total = 8 + chunk_len
    payload = b"icns" + struct.pack(">I", total) + b"ic10" + struct.pack(">I", chunk_len) + png
    icns_path.parent.mkdir(parents=True, exist_ok=True)
    icns_path.write_bytes(payload)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: png_to_icns.py input.png output.icns")
    png_to_icns(Path(sys.argv[1]), Path(sys.argv[2]))
