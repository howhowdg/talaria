#!/usr/bin/env python3
"""Prepare Talaria privately; publish a ZIP only after Developer ID notarization."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


class PackagingError(Exception):
    pass


MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
BUNDLE_SUFFIXES = {".app", ".bundle", ".framework", ".xpc", ".appex", ".plugin"}
COPY_OPTIONS = ["--norsrc", "--noextattr", "--noqtn", "--noacl"]
ARCHITECTURES = {"arm64", "x86_64"}
DEBUG_MARKERS = (
    b"Open Hierarchy Design Fixture",
    b"/tmp/talaria-hierarchy-design-fixture.json",
    b"synthetic-mobile-design-only",
)


def run(label: str, *arguments: str | Path) -> subprocess.CompletedProcess[str]:
    """Never echo command arguments, signing details, or potentially private paths."""
    result = subprocess.run(
        [str(argument) for argument in arguments],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if result.returncode:
        raise PackagingError(
            f"{label} failed (exit {result.returncode}). "
            "Tool output was withheld because it can contain private paths or account details."
        )
    return result


def macho_files(app: Path) -> list[Path]:
    result = []
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    result.append(path)
    return result


def code_targets(app: Path) -> list[Path]:
    targets = set(macho_files(app))
    targets.update(
        path for path in app.rglob("*")
        if path.is_dir() and not path.is_symlink() and path.suffix in BUNDLE_SUFFIXES
    )
    targets.add(app)
    return sorted(targets, key=lambda path: (-len(path.parts), str(path)))


def architectures(binary: Path) -> set[str]:
    return set(run("Reading binary architectures", "/usr/bin/lipo", "-archs", binary).stdout.split())


def validate_contents(app: Path) -> tuple[dict, Path]:
    root = app.resolve()
    for path in app.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(root):
            raise PackagingError("The app contains a symlink outside its bundle; refusing to package it.")
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if not isinstance(info, dict):
            raise ValueError("The property list must be a dictionary.")
        executable_name = info["CFBundleExecutable"]
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        raise PackagingError("The input app has no readable executable declaration.") from error
    if not isinstance(executable_name, str) or Path(executable_name).name != executable_name:
        raise PackagingError("The executable declaration must be a single filename.")
    binary = app / "Contents/MacOS" / executable_name
    if info.get("CFBundlePackageType") != "APPL" or not binary.is_file():
        raise PackagingError("The input must be a built macOS application bundle.")
    if architectures(binary) != ARCHITECTURES:
        raise PackagingError("The main executable must contain exactly arm64 and x86_64 slices.")
    for filename in ("LICENSE", "ThirdPartyNotices.md"):
        notice = app / "Contents/Resources" / filename
        if not notice.is_file() or not notice.read_bytes().strip():
            raise PackagingError(f"The built app must already include a nonempty {filename}.")
    if any(path.name.endswith(".debug.dylib") for path in app.rglob("*")):
        raise PackagingError("A Debug companion library was found. Supply a Release app.")
    data = binary.read_bytes()
    if any(marker in data for marker in DEBUG_MARKERS):
        raise PackagingError("Design-fixture code was found. Supply a Release app.")
    return info, binary


def validate_no_private_paths(app: Path) -> None:
    # Check all bundle bytes, not just printable strings or the main architecture.
    count = 0
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                tail = b""
                while chunk := stream.read(1024 * 1024):
                    data = tail + chunk
                    if b"/Users/" in data:
                        count += 1
                        break
                    tail = data[-6:]
    if count:
        raise PackagingError(
            f"Private home-directory path markers remain in {count} bundle file(s). "
            "Rebuild from a neutral source location before packaging; matching strings are not printed."
        )


def remove_signatures_and_strip(app: Path) -> None:
    binaries = macho_files(app)
    before = {binary: architectures(binary) for binary in binaries}
    for binary in binaries:
        probe = subprocess.run(
            ["/usr/bin/codesign", "--display", str(binary)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if probe.returncode == 0:
            run("Removing an old binary signature", "/usr/bin/codesign", "--remove-signature", binary)
        run("Stripping source debug symbols", "/usr/bin/xcrun", "strip", "-S", binary)
        if architectures(binary) != before[binary]:
            raise PackagingError("Debug stripping unexpectedly changed binary architectures.")
    for directory in sorted(app.rglob("_CodeSignature"), key=lambda path: -len(path.parts)):
        if directory.is_dir() and not directory.is_symlink():
            shutil.rmtree(directory)


def make_zip(app: Path, destination: Path) -> None:
    run("Creating clean ZIP", "/usr/bin/ditto", *COPY_OPTIONS,
        "-c", "-k", "--keepParent", app, destination)
    with zipfile.ZipFile(destination) as archive:
        names = archive.namelist()
        if any(name.startswith("__MACOSX/") or "/._" in name for name in names):
            raise PackagingError("The ZIP unexpectedly contains filesystem metadata.")
        if any(not name.startswith("Talaria.app/") for name in names):
            raise PackagingError("The ZIP must contain only Talaria.app.")


def validate_distribution(app: Path) -> None:
    run("Verifying all code signatures", "/usr/bin/codesign", "--verify", "--deep",
        "--strict", "--all-architectures", app)
    for architecture in sorted(ARCHITECTURES):
        details = run("Inspecting Developer ID signature", "/usr/bin/codesign", "--display",
                      "--arch", architecture, "--verbose=4", app)
        text = details.stdout + details.stderr
        if "Authority=Developer ID Application:" not in text or "Signature=adhoc" in text:
            raise PackagingError("Public output requires a Developer ID Application signature.")
        if "Timestamp=" not in text or "(runtime)" not in text:
            raise PackagingError("Public output requires secure timestamps and hardened runtime.")
    run("Validating the stapled notarization ticket", "/usr/bin/xcrun", "stapler", "validate", app)
    assessment = run("Gatekeeper assessment", "/usr/sbin/spctl", "--assess", "--type",
                     "execute", "--verbose=4", app)
    text = assessment.stdout + assessment.stderr
    if "accepted" not in text or "source=Notarized Developer ID" not in text:
        raise PackagingError("Gatekeeper did not explicitly accept a notarized Developer ID app.")
    validate_no_private_paths(app)


def publish_directory(staged: Path, output: Path) -> None:
    # mkdir is exclusive: a second invocation cannot replace an existing release.
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        output.mkdir(mode=0o755)
    except FileExistsError as error:
        raise PackagingError("Output already exists; refusing to overwrite it.") from error
    for item in staged.iterdir():
        target = output / item.name
        if item.is_dir():
            run("Copying unsigned staging app", "/usr/bin/ditto", *COPY_OPTIONS, item, target)
        else:
            with item.open("rb") as source, target.open("xb") as destination:
                shutil.copyfileobj(source, destination)


def validate_release(app: Path, version: str, build: str) -> None:
    info, _ = validate_contents(app)
    if info.get("CFBundleShortVersionString") != version or info.get("CFBundleVersion") != build:
        raise PackagingError(
            "The app's existing version and build must exactly match --version and --build. "
            "An already signed app will not be modified."
        )
    validate_distribution(app)


def package_verified_app(app: Path, private: Path, output: Path, version: str, build: str) -> None:
    # Verify the original app before copying or archiving any of its bytes. In the
    # Xcode-export path, neither the bundle nor its notarization ticket is changed.
    validate_release(app, version, build)
    staged_output = private / "public-output"
    staged_output.mkdir(mode=0o700)
    archive = staged_output / f"Talaria-{version}-macOS-universal.zip"
    make_zip(app, archive)
    extracted = private / "archive-verification"
    run("Extracting final archive for verification", "/usr/bin/ditto", "-x", "-k", archive, extracted)
    validate_release(extracted / "Talaria.app", version, build)
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    (staged_output / "SHA256SUMS").write_text(f"{digest.hexdigest()}  {archive.name}\n", encoding="ascii")
    publish_directory(staged_output, output)
    print(f"Verified public release: {output}")
    print("The ZIP and SHA256SUMS are ready for a release upload. Nothing was uploaded to a hosting service.")


def package(arguments: argparse.Namespace) -> None:
    if sys.platform != "darwin":
        raise PackagingError("This script requires macOS and Xcode command-line tools.")
    source = arguments.app.expanduser().resolve()
    requested_output = arguments.output_dir.expanduser()
    if requested_output.exists() or requested_output.is_symlink():
        raise PackagingError("Output already exists; choose a new --output-dir.")
    output = requested_output.resolve()
    if not source.is_dir() or source.suffix != ".app":
        raise PackagingError("--app must identify an existing Release .app directory.")
    if output.exists() or output.is_symlink():
        raise PackagingError("Output already exists; choose a new --output-dir.")
    if output.is_relative_to(source):
        raise PackagingError("The output directory cannot be inside the input app.")
    if arguments.prepare_only or arguments.package_verified:
        if arguments.identity is not None or arguments.notary_profile is not None:
            raise PackagingError("--prepare-only and --package-verified do not accept signing or notarization options.")
    else:
        if not arguments.identity or not arguments.identity.startswith("Developer ID Application: "):
            raise PackagingError("Supply the exact Developer ID Application identity using --identity.")
        if not arguments.notary_profile:
            raise PackagingError("Supply an existing notarytool Keychain profile using --notary-profile.")
    if arguments.package_verified and source.name != "Talaria.app":
        raise PackagingError("--package-verified requires the exported app to be named Talaria.app.")

    with tempfile.TemporaryDirectory(prefix="talaria-release-") as temporary:
        private = Path(temporary)
        os.chmod(private, 0o700)
        if arguments.package_verified:
            print("Checking the existing exported app without modifying or signing it.", flush=True)
            package_verified_app(source, private, output, arguments.version, arguments.build)
            return
        app = private / "Talaria.app"
        run("Copying input into private staging", "/usr/bin/ditto", *COPY_OPTIONS, source, app)
        info, _ = validate_contents(app)
        remove_signatures_and_strip(app)
        info["CFBundleShortVersionString"] = arguments.version
        info["CFBundleVersion"] = arguments.build
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        validate_contents(app)
        validate_no_private_paths(app)
        print("Prepared universal Release app: notices present, debug symbols stripped, no /Users/ markers.", flush=True)

        staged_output = private / "output"
        staged_output.mkdir(mode=0o700)
        if arguments.prepare_only:
            app.rename(staged_output / f"Talaria-{arguments.version}-UNSIGNED-STAGING.app")
            (staged_output / "UNSIGNED-STAGING.txt").write_text(
                f"Talaria {arguments.version} ({arguments.build}) — UNSIGNED STAGING ONLY\n"
                "This app has no distribution signature or notarization ticket.\n"
                "Do not upload it or link it from the landing page.\n"
                "Run the packaging script again with Developer ID and a notarytool Keychain profile.\n",
                encoding="utf-8",
            )
            publish_directory(staged_output, output)
            print(f"Unsigned staging only: {output}")
            return

        print("Signing with the supplied Developer ID identity.", flush=True)
        for target in code_targets(app):
            run("Developer ID signing", "/usr/bin/codesign", "--force", "--sign", arguments.identity,
                "--options", "runtime", "--timestamp", target)
        run("Verifying signatures before submission", "/usr/bin/codesign", "--verify", "--deep",
            "--strict", "--all-architectures", app)
        upload = private / "notarization-input.zip"
        make_zip(app, upload)
        print("Submitting to Apple and waiting for notarization; no public output exists yet.", flush=True)
        submission = run("Apple notarization", "/usr/bin/xcrun", "notarytool", "submit", upload,
                         "--keychain-profile", arguments.notary_profile, "--wait", "--output-format", "json")
        try:
            result = json.loads(submission.stdout)
        except (ValueError, TypeError) as error:
            raise PackagingError("Apple returned an unreadable notarization response; no release was emitted.") from error
        if result.get("status") != "Accepted":
            raise PackagingError("Apple did not accept this submission; inspect notarytool history and logs.")
        run("Stapling the accepted ticket", "/usr/bin/xcrun", "stapler", "staple", app)
        package_verified_app(app, private, output, arguments.version, arguments.build)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Existing universal macOS Release .app")
    parser.add_argument("--version", required=True, help="Explicit three-part marketing version, for example 0.1.2")
    parser.add_argument("--build", required=True, help="Explicit positive integer build number")
    parser.add_argument("--output-dir", required=True, type=Path, help="New directory; never overwritten")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare-only", action="store_true", help="Emit clearly named unsigned staging, never public ZIPs")
    mode.add_argument("--package-verified", action="store_true",
                      help="Package an already signed, notarized, stapled Talaria.app without modifying or signing it")
    parser.add_argument("--identity", help="Exact Developer ID Application certificate identity")
    parser.add_argument("--notary-profile", help="Existing notarytool Keychain profile name; never a password or API key")
    arguments = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", arguments.version):
        parser.error("--version must contain three numeric components")
    if not re.fullmatch(r"[1-9][0-9]*", arguments.build):
        parser.error("--build must be a positive integer")
    try:
        package(arguments)
    except (PackagingError, OSError, ValueError, zipfile.BadZipFile) as error:
        # OSError filenames can expose a private source path; keep unexpected errors generic.
        detail = str(error) if isinstance(error, PackagingError) else type(error).__name__
        print(f"Packaging stopped: {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
