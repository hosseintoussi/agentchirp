#!/usr/bin/env python3
"""Fetch the pinned release tools matching Package.swift, verifying their digest."""
import hashlib
import pathlib
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = "2.9.6"
SHA256 = "52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"


def fetch():
    base = ROOT / ".build/tools"
    base.mkdir(parents=True, exist_ok=True)
    archive = base / f"Sparkle-{VERSION}.tar.xz"
    if not archive.exists():
        urllib.request.urlretrieve(f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/{archive.name}", archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit("Sparkle tools checksum mismatch. Remove the cached archive and retry.")
    destination = base / f"sparkle-{VERSION}"
    destination.mkdir(exist_ok=True)
    subprocess.run(["tar", "-xf", str(archive), "-C", str(destination)], check=True)
    return destination / "bin"


if __name__ == "__main__":
    print(fetch())
