"""Verify the actual release archive and reject tampering and a mismatched key."""
import base64
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
ARCHIVE = pathlib.Path(sys.argv.pop(1)).resolve()


class UpdateSignatureTests(unittest.TestCase):
    def test_signature_binds_key_and_exact_bytes(self):
        with zipfile.ZipFile(ARCHIVE) as archive:
            info = plistlib.loads(archive.read("AgentChirp.app/Contents/Info.plist"))
        enclosure = ET.parse(ARCHIVE.parent / "appcast.xml").find("./channel/item/enclosure")
        signature = enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
        def verify(key, file):
            return subprocess.run(["swift", str(ROOT / "scripts/verify_update.swift"), key, signature, str(file)], capture_output=True).returncode
        self.assertEqual(verify(info["SUPublicEDKey"], ARCHIVE), 0)
        self.assertNotEqual(verify(base64.b64encode(bytes(32)).decode(), ARCHIVE), 0)
        with tempfile.TemporaryDirectory() as directory:
            changed = pathlib.Path(directory) / "changed.zip"
            changed.write_bytes(ARCHIVE.read_bytes() + b"tampered")
            self.assertNotEqual(verify(info["SUPublicEDKey"], changed), 0)


if __name__ == "__main__":
    unittest.main()
