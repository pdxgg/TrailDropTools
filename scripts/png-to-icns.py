"""Package PNG icon sizes into a modern macOS ICNS file (standard library only)."""

from pathlib import Path
import struct
import sys


def chunk(kind: bytes, data: bytes) -> bytes:
    return kind + struct.pack(">I", len(data) + 8) + data


def main(iconset: Path, output: Path) -> None:
    names = (
        (b"icp4", "icon_16x16.png"),
        (b"icp5", "icon_32x32.png"),
        (b"icp6", "icon_32x32@2x.png"),
        (b"ic07", "icon_128x128.png"),
        (b"ic08", "icon_256x256.png"),
        (b"ic09", "icon_512x512.png"),
        (b"ic10", "icon_512x512@2x.png"),
    )
    body = b"".join(chunk(kind, (iconset / name).read_bytes()) for kind, name in names)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
