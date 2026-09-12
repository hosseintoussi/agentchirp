#!/usr/bin/env python3
"""Arrange a conventional app → Applications window without automating Finder."""
import pathlib
import sys
import subprocess
import tempfile
import dmgbuild

app = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()

def build(background):
    dmgbuild.build_dmg(str(output), "AgentChirp", settings={
        "files": [str(app)],
        "symlinks": {"Applications": "/Applications"},
        "icon": str(app / "Contents/Resources/AgentChirp.icns"),
        "background": str(background),
        "window_rect": ((240, 240), (640, 280)),
        "icon_locations": {"AgentChirp.app": (160, 130), "Applications": (480, 130)},
        "icon_size": 96,
        "text_size": 13,
        "default_view": "icon-view",
        "show_status_bar": False,
        "show_tab_view": False,
        "show_toolbar": False,
        "show_pathbar": False,
        "show_sidebar": False,
        "format": "UDZO",
    })


with tempfile.TemporaryDirectory(prefix="agentchirp-dmg-art-") as temporary:
    background = pathlib.Path(temporary) / "background.tiff"
    subprocess.run(["swift", str(pathlib.Path(__file__).with_name("dmg_background.swift")), str(background)], check=True)
    build(background)
