#!/usr/bin/env python3
"""Download an ONNX classifier from the ONNX Model Zoo into models/.

The weights are not committed: they are large binaries with a reproducible
download path and a SHA256 check instead. Run prepare_model.py afterwards --
a downloaded model is not necessarily batchable, and Loom's entire premise is
that it is.

Usage:
    ./scripts/fetch_model.py                    # fetch the default model
    ./scripts/fetch_model.py --model resnet18
    ./scripts/fetch_model.py --print-sha        # hash without pinning
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = REPO_ROOT / "models"

ZOO = "https://github.com/onnx/models/raw/main/validated/vision/classification"

# SHA256 of the downloaded .onnx. Empty means unpinned: the script still works
# but warns and prints the hash it saw so you can pin it here.
MODELS: dict[str, dict[str, str]] = {
    "mobilenetv2": {
        "url": f"{ZOO}/mobilenet/model/mobilenetv2-12.onnx",
        "filename": "mobilenetv2-12.onnx",
        "sha256": "",
    },
    "resnet18": {
        "url": f"{ZOO}/resnet/model/resnet18-v1-7.onnx",
        "filename": "resnet18-v1-7.onnx",
        "sha256": "",
    },
}

DEFAULT_MODEL = "mobilenetv2"


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, dest: Path) -> None:
    print(f"Downloading {url}")
    # GitHub serves Git LFS objects through a redirect to media.githubusercontent.com;
    # urllib follows it. A "version https://git-lfs..." body means we got the
    # pointer file instead of the object, which the size check below catches.
    with urllib.request.urlopen(url) as response, dest.open("wb") as out:
        shutil.copyfileobj(response, out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=sorted(MODELS), default=DEFAULT_MODEL)
    parser.add_argument(
        "--print-sha",
        action="store_true",
        help="download, print the SHA256, and exit without pinning",
    )
    parser.add_argument("--force", action="store_true", help="re-download if present")
    args = parser.parse_args()

    spec = MODELS[args.model]
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    dest = MODELS_DIR / spec["filename"]

    if dest.exists() and not args.force and not args.print_sha:
        print(f"{dest.relative_to(REPO_ROOT)} already present (use --force to re-download)")
        return 0

    download(spec["url"], dest)

    size = dest.stat().st_size
    if size < 1_000_000:
        head = dest.read_bytes()[:120]
        print(f"ERROR: downloaded only {size} bytes -- this is not a model.", file=sys.stderr)
        print(f"       First bytes: {head!r}", file=sys.stderr)
        print("       A Git LFS pointer means the redirect was not followed.", file=sys.stderr)
        dest.unlink()
        return 1

    actual = sha256_of(dest)
    expected = spec["sha256"]

    if args.print_sha:
        print(f"{args.model} {actual}")
        return 0

    if not expected:
        print(f"WARNING: no SHA256 pinned for '{args.model}'.", file=sys.stderr)
        print(f"         Downloaded artifact hashes to:\n           {actual}", file=sys.stderr)
        print("         Add it to MODELS in fetch_model.py to pin.", file=sys.stderr)
    elif expected != actual:
        print(f"ERROR: SHA256 mismatch for {spec['filename']}", file=sys.stderr)
        print(f"  expected {expected}\n  actual   {actual}", file=sys.stderr)
        dest.unlink()
        return 1
    else:
        print(f"SHA256 verified: {actual}")

    mib = size / (1024 * 1024)
    print(f"Wrote {dest.relative_to(REPO_ROOT)} ({mib:.1f} MiB)")
    print("\nNext: ./scripts/prepare_model.py --model", args.model)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
