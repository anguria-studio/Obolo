#!/usr/bin/env python3
"""Exercise release signing with a disposable app and signing key."""

import argparse
import base64
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

from build_direct_release import generate_release_assets, sparkle_tools, verify_release_assets


def fixture_dmg(work, dmg, key):
    """Make a minimal universal Mac app. Sparkle reads its metadata from the disk image."""
    key.write_bytes(base64.b64encode(os.urandom(32)))
    public_key = subprocess.check_output([
        "swift", "-e", """
        import CryptoKit
        import Foundation
        let seed = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: seed)!)
        print(key.publicKey.rawRepresentation.base64EncodedString())
        """, str(key),
    ], text=True).strip()

    contents = work / "image/Fixture.app/Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "org.example.OboloReleaseFixture",
        "CFBundleName": "Fixture",
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "Fixture",
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "42",
        "LSMinimumSystemVersion": "15.0",
        "SUFeedURL": "https://example.invalid/appcast.xml",
        "SUPublicEDKey": public_key,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
    }))
    source = work / "fixture.c"
    source.write_text("int main(void) { return 0; }\n")
    subprocess.run(["xcrun", "clang", "-arch", "arm64", "-arch", "x86_64",
                    "-mmacosx-version-min=15.0", source, "-o", contents / "MacOS/Fixture"], check=True)
    subprocess.run(["hdiutil", "create", "-srcfolder", work / "image", "-volname", "Fixture",
                    "-format", "UDZO", dmg], check=True)


def check_tampering(path, altered, verify):
    """Give the altered file a matching SHA-256 to exercise the signature check."""
    original = path.read_bytes()
    manifest = path.parent / "SHA256SUMS"
    checksums = manifest.read_bytes()
    before = hashlib.sha256(original).hexdigest().encode()
    after = hashlib.sha256(altered).hexdigest().encode()
    assert before in checksums and before != after
    path.write_bytes(altered)
    manifest.write_bytes(checksums.replace(before, after))
    try:
        verify()
    except (subprocess.CalledProcessError, ValueError, RuntimeError):
        pass
    else:
        raise AssertionError(f"Accepted altered {path.name}")
    finally:
        path.write_bytes(original)
        manifest.write_bytes(checksums)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packages", type=Path, help="resolved Xcode source packages directory")
    tools = sparkle_tools(parser.parse_args().packages.resolve())
    with tempfile.TemporaryDirectory(prefix="obolo-release-test-") as tmp:
        work = Path(tmp)
        assets = work / "assets"
        assets.mkdir()
        dmg = assets / "Obolo-1.2.3-42.dmg"
        key = work / "disposable.key"
        fixture_dmg(work, dmg, key)
        args = (assets, dmg.name, "1.2.3", "42", "15.0", "https://example.invalid/download/",
                tools, ("--ed-key-file", str(key)))
        generate_release_assets(*args)
        verify_release_assets(*args)
        data = dmg.read_bytes()
        check_tampering(dmg, bytes([data[0] ^ 1]) + data[1:], lambda: verify_release_assets(*args))
        feed = assets / "appcast.xml"
        altered = feed.read_bytes().replace(b"</channel>", b"<!-- changed --></channel>", 1)
        check_tampering(feed, altered, lambda: verify_release_assets(*args))
        print("Verified the signed update and rejected both altered files.")


if __name__ == "__main__":
    main()
