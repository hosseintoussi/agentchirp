"""Verify the final volume, including signatures after Finder layout metadata."""
import pathlib
import plistlib
import subprocess
import sys

image = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "dist/AgentChirp.dmg").resolve()
result = subprocess.check_output(["hdiutil", "attach", "-nobrowse", "-readonly", "-plist", str(image)])
mount = pathlib.Path(next(e["mount-point"] for e in plistlib.loads(result)["system-entities"] if "mount-point" in e))
try:
    assert (mount / "AgentChirp.app").is_dir()
    assert (mount / "Applications").is_symlink()
    assert (mount / "Applications").readlink() == pathlib.Path("/Applications")
    assert (mount / ".DS_Store").is_file(), "Finder layout is missing"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(mount / "AgentChirp.app")], check=True)
    print("DMG layout, Applications shortcut and contained app signature verified")
finally:
    subprocess.run(["hdiutil", "detach", str(mount)], check=True)
