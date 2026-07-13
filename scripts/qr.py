#!/usr/bin/env python3
"""Render the bridge's most recent terminal QR code as a PNG.

The bridge prints the pairing QR to stdout as Unicode half-block art, which
lands in the service log. This script finds the last QR block in that log,
reconstructs the module matrix, and writes it as a scannable PNG — useful
when the bridge runs as a background service and you cannot see its terminal.

Usage:
    uv run --with pillow python qr.py [--log PATH] [--out PATH] [--invert]

Defaults: --log $WHATSAPP_MCP_DIR/bridge.log (or ~/.whatsapp-mcp/bridge.log),
--out ./whatsapp-qr.png. Reads stdin if --log is "-".
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Half-block characters -> (top module dark?, bottom module dark?).
# qrterminal's half-block mode uses exactly these four glyphs.
GLYPHS = {
    "█": (True, True),   # full block
    "▀": (True, False),  # upper half block
    "▄": (False, True),  # lower half block
    " ": (False, False),
}


def find_last_qr_block(lines: list[str]) -> list[str]:
    """Return the last contiguous run of lines that look like half-block QR art."""
    blocks: list[list[str]] = []
    current: list[str] = []
    for raw in lines:
        line = raw.rstrip("\n")
        stripped = line.strip()
        is_qr = (
            len(stripped) >= 20
            and all(ch in GLYPHS for ch in stripped)
        )
        if is_qr:
            current.append(stripped)
        else:
            if len(current) >= 10:
                blocks.append(current)
            current = []
    if len(current) >= 10:
        blocks.append(current)
    if not blocks:
        raise SystemExit(
            "No QR block found in the log. Run scripts/pair.sh in a terminal instead, "
            "or restart the bridge service to emit a fresh QR."
        )
    return blocks[-1]


def to_matrix(block: list[str]) -> list[list[bool]]:
    width = max(len(line) for line in block)
    matrix: list[list[bool]] = []
    for line in block:
        padded = line.ljust(width)
        top = [GLYPHS[ch][0] for ch in padded]
        bottom = [GLYPHS[ch][1] for ch in padded]
        matrix.append(top)
        matrix.append(bottom)
    return matrix


def write_png(matrix: list[list[bool]], out: Path, invert: bool, scale: int = 8) -> None:
    from PIL import Image

    rows = len(matrix)
    cols = len(matrix[0])
    quiet = 4  # quiet-zone modules on each side
    img = Image.new("1", ((cols + 2 * quiet) * scale, (rows + 2 * quiet) * scale), 1)
    px = img.load()
    for r, row in enumerate(matrix):
        for c, dark in enumerate(row):
            value = dark if not invert else not dark
            if value:
                for dy in range(scale):
                    for dx in range(scale):
                        px[(c + quiet) * scale + dx, (r + quiet) * scale + dy] = 0
    img.save(out)


def main() -> None:
    default_log = Path(os.environ.get("WHATSAPP_MCP_DIR", str(Path.home() / ".whatsapp-mcp")))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", default=str(default_log / "bridge.log"))
    parser.add_argument("--out", default="whatsapp-qr.png")
    parser.add_argument(
        "--invert",
        action="store_true",
        help="Invert dark/light. Terminal QRs are light-on-dark; the default "
        "rendering already flips them — use this only if the first PNG won't scan.",
    )
    args = parser.parse_args()

    if args.log == "-":
        lines = sys.stdin.readlines()
    else:
        lines = Path(args.log).read_text(encoding="utf-8", errors="replace").splitlines()

    block = find_last_qr_block(lines)
    matrix = to_matrix(block)
    # Terminals render the QR light-on-dark: the "block" glyphs are the LIGHT
    # modules. Invert by default so the PNG is standard dark-on-light.
    write_png(matrix, Path(args.out), invert=not args.invert)
    print(f"Wrote {args.out} ({len(matrix)}x{len(matrix[0])} modules). "
          "If it will not scan, re-run with --invert.")


if __name__ == "__main__":
    main()
