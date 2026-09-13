#!/usr/bin/env python3
"""Build the actual app bundle. Python is a build tool, never a user dependency."""
import argparse
import base64
import os
import pathlib
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True, **kwargs)


def version():
    return re.search(r'public let appVersion = "([0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[1-9][0-9]*)?)"',
                     (ROOT / "Sources/AgentChirpCore/Version.swift").read_text())[1]


def package(development, identity, output):
    template = plistlib.loads((ROOT / "Packaging/Info.plist").read_bytes())
    key = os.environ.get("SPARKLE_PUBLIC_KEY") or template.get("SUPublicEDKey", "")
    if not development:
        if not identity or identity == "-":
            raise SystemExit("Release packaging requires --identity with a Developer ID Application identity.")
        try:
            if len(base64.b64decode(key, validate=True)) != 32:
                raise ValueError()
        except ValueError:
            raise SystemExit("Set SPARKLE_PUBLIC_KEY to the public key from Sparkle generate_keys.")
    identity = identity or "-"
    architectures = [platform.machine()] if development else ["arm64", "x86_64"]
    bins = []
    for arch in architectures:
        # SwiftPM 5.10 reuses an incompatible build plan when switching --arch in
        # one scratch directory. Keep each architecture independent across runs.
        scratch = ROOT / (".build/package-" + arch)
        for product in ["agentchirp", "agentchirp-hook"]:
            run("swift", "build", "-c", "release", "--scratch-path", scratch, "--arch", arch, "--product", product)
        result = run("swift", "build", "-c", "release", "--scratch-path", scratch, "--arch", arch, "--show-bin-path", capture_output=True, text=True)
        bins.append(pathlib.Path(result.stdout.strip()))
    output.mkdir(parents=True, exist_ok=True)
    destination = output / "AgentChirp.app"
    # Construct privately, so a failed build never destroys the previous artifact.
    with tempfile.TemporaryDirectory(prefix="agentchirp-package-", dir=output) as temporary:
        temp = pathlib.Path(temporary)
        app = temp / "AgentChirp.app"
        contents = app / "Contents"
        macos = contents / "MacOS"
        resources = contents / "Resources"
        frameworks = contents / "Frameworks"
        for folder in [macos, resources, frameworks]:
            folder.mkdir(parents=True)
        for product in ["agentchirp", "agentchirp-hook"]:
            if development:
                shutil.copy2(bins[0] / product, macos / product)
            else:
                run("lipo", "-create", *(b / product for b in bins), "-output", macos / product)
            (macos / product).chmod(0o755)
        for name in ["agentchirp.sh", "codex-chirp"]:
            shutil.copy2(ROOT / name, resources / name)
        # Keep the signed helper under MacOS; bundledResource finds it there.
        for name in ["LICENSE"]:
            if (ROOT / name).exists():
                shutil.copy2(ROOT / name, resources / name)
        sparkle = ROOT / (".build/package-" + architectures[0]) / "artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        framework = frameworks / "Sparkle.framework"
        run("ditto", sparkle, framework)
        # This app is not sandboxed, so Sparkle's optional XPC services are unused.
        shutil.rmtree(framework / "Versions/B/XPCServices")
        if (framework / "XPCServices").is_symlink():
            (framework / "XPCServices").unlink()
        info = dict(template)
        if os.environ.get("GITHUB_REPOSITORY"):
            info["SUFeedURL"] = "https://github.com/" + os.environ["GITHUB_REPOSITORY"] + "/releases/latest/download/appcast.xml"
        release_version = version()
        short_version = release_version.split("-rc.")[0]
        build_version = release_version.replace("-rc.", "fc")
        info.update(CFBundleShortVersionString=short_version, CFBundleVersion=build_version,
                    AgentChirpVersion=release_version, AgentChirpDevelopment=development)
        if key:
            info["SUPublicEDKey"] = key
        if development:
            info["SUEnableAutomaticChecks"] = False
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        (contents / "PkgInfo").write_bytes(b"APPL????")
        iconset = temp / "AgentChirp.iconset"
        # Export from the native host build before applying hardened-runtime signing.
        host = bins[architectures.index(platform.machine())] / "agentchirp"
        run(host, "--export-icon", iconset)
        run("iconutil", "-c", "icns", iconset, "-o", resources / "AgentChirp.icns")
        signature = ["codesign", "--force", "--sign", identity]
        if identity != "-":
            signature += ["--options", "runtime", "--timestamp"]
        # Ad-hoc previews have no Team ID for hardened library validation.
        # Clear inherited runtime flags when re-signing Sparkle for local use.
        else:
            signature += ["--options", "0"]
        for target in [framework / "Versions/B/Autoupdate", framework / "Versions/B/Updater.app", framework,
                       macos / "agentchirp-hook"]:
            run(*signature, target)
        run(*signature, "--entitlements", ROOT / "Packaging/AgentChirp.entitlements", app)
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(app), destination)
    print(destination)
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--development", action="store_true", help="Native-architecture preview; no login registration or updater traffic")
    parser.add_argument("--identity", default=os.environ.get("DEVELOPER_ID_APPLICATION"))
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "dist")
    args = parser.parse_args()
    package(args.development, args.identity, args.output.resolve())
