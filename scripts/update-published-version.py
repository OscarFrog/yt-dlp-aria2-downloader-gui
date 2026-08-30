# SPDX-License-Identifier: MIT
"""
Update the documented immutable release version after publication.

Project: yt-dlp-aria2-downloader-gui
Repository path: scripts/update-published-version.py

The helper changes only the known English/French release references and the
static published-version contract. Exact occurrence counts make documentation
drift fail closed instead of permitting a broad semantic-version replacement.

This file is intentionally non-executable. Invoke it explicitly with python3.
"""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
import tempfile
from pathlib import Path


EXIT_USAGE = 2
EXIT_VALIDATION = 65
EXIT_IO = 70
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
EXPECTED_VERSION_RE = re.compile(
    r"^readonly EXPECTED_VERSION='(?P<version>[0-9]+\.[0-9]+\.[0-9]+)'$",
    re.MULTILINE,
)
PUBLISHED_VERSION_RE = re.compile(
    r"^readonly EXPECTED_PUBLISHED_VERSION="
    r"'(?P<version>[0-9]+\.[0-9]+\.[0-9]+)'$",
    re.MULTILINE,
)
STATIC_CONTRACT_PATH = Path("test-static.sh")
README_REFERENCE_TEMPLATES = {
    Path("README.md"): (
        ("latest published package release is **{version}**.", 1),
        ("currently published v{version} release.", 1),
        ("latest published release, {version}, provides", 1),
        ("yt-dlp-aria2-downloader-gui-{version}", 7),
        ("yt-dlp-aria2-downloader-gui_{version}", 3),
        ("gh release verify v{version} -R", 1),
        ("gh release verify-asset v{version} ./ARTIFACT", 1),
    ),
    Path("README.fr.md"): (
        ("dernière release de paquets publiée est la **{version}**.", 1),
        ("release v{version} actuellement publiée.", 1),
        ("dernière release publiée, la {version}, fournit", 1),
        ("yt-dlp-aria2-downloader-gui-{version}", 7),
        ("yt-dlp-aria2-downloader-gui_{version}", 3),
        ("gh release verify v{version} -R", 1),
        ("gh release verify-asset v{version} ./ARTEFACT", 1),
    ),
}


class VersionUpdateError(Exception):
    """Expected documentation or version-contract validation failure."""


def parse_version(value: str) -> tuple[int, int, int]:
    """Validate and return one exact semantic version as integer fields."""

    if not VERSION_RE.fullmatch(value):
        raise VersionUpdateError(
            f"version must contain exactly three decimal fields: {value!r}"
        )
    return tuple(int(field) for field in value.split("."))  # type: ignore[return-value]


def read_regular_text(root: Path, relative_path: Path) -> str:
    """Read one required regular, non-symlink UTF-8 repository file."""

    path = root / relative_path
    try:
        path_stat = path.lstat()
    except OSError as exc:
        raise VersionUpdateError(f"unable to inspect {relative_path}: {exc}") from exc

    if stat.S_ISLNK(path_stat.st_mode) or not stat.S_ISREG(path_stat.st_mode):
        raise VersionUpdateError(
            f"required path must be a regular non-symlink file: {relative_path}"
        )

    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise VersionUpdateError(f"unable to read {relative_path}: {exc}") from exc


def require_single_version(
    pattern: re.Pattern[str], text: str, label: str
) -> str:
    """Extract exactly one version value from the static contract."""

    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise VersionUpdateError(
            f"expected exactly one {label} declaration; found {len(matches)}"
        )
    return matches[0].group("version")


def validate_reference_counts(
    relative_path: Path, text: str, version: str
) -> None:
    """Require every generated release-reference shape at its exact count."""

    for template, expected_count in README_REFERENCE_TEMPLATES[relative_path]:
        reference = template.format(version=version)
        actual_count = text.count(reference)
        if actual_count != expected_count:
            raise VersionUpdateError(
                f"{relative_path} contains {actual_count} occurrences of "
                f"{reference!r}; expected {expected_count}"
            )


def replace_reference_set(
    relative_path: Path, text: str, old_version: str, new_version: str
) -> str:
    """Replace only known published-release references in one README."""

    validate_reference_counts(relative_path, text, old_version)
    updated = text
    for template, _expected_count in README_REFERENCE_TEMPLATES[relative_path]:
        old_reference = template.format(version=old_version)
        new_reference = template.format(version=new_version)
        updated = updated.replace(old_reference, new_reference)
    validate_reference_counts(relative_path, updated, new_version)
    return updated


def atomic_write_text(path: Path, text: str) -> None:
    """Replace one existing file atomically while preserving its mode."""

    original_mode = stat.S_IMODE(path.stat().st_mode)
    temporary_path: Path | None = None

    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="",
            prefix=f".{path.name}.",
            dir=path.parent,
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            os.chmod(temporary_path, original_mode)
            temporary.write(text)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
        temporary_path = None
    except OSError as exc:
        raise VersionUpdateError(f"unable to publish {path.name}: {exc}") from exc
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def resolve_root(requested_root: Path | None) -> Path:
    """Resolve the repository root used by production or isolated tests."""

    candidate = requested_root or Path(__file__).resolve().parents[1]
    try:
        root = candidate.resolve(strict=True)
    except OSError as exc:
        raise VersionUpdateError(f"unable to resolve repository root: {exc}") from exc
    if not root.is_dir():
        raise VersionUpdateError(f"repository root is not a directory: {root}")
    return root


def check_published_version(root: Path, requested_version: str) -> None:
    """Verify that the static contract and both READMEs are aligned."""

    static_text = read_regular_text(root, STATIC_CONTRACT_PATH)
    published_version = require_single_version(
        PUBLISHED_VERSION_RE,
        static_text,
        "published-version",
    )
    if published_version != requested_version:
        raise VersionUpdateError(
            "published-version contract mismatch: "
            f"expected {requested_version}, found {published_version}"
        )

    for relative_path in README_REFERENCE_TEMPLATES:
        readme_text = read_regular_text(root, relative_path)
        validate_reference_counts(relative_path, readme_text, requested_version)


def update_published_version(root: Path, requested_version: str) -> bool:
    """Prepare the exact documentation and static-contract update."""

    static_text = read_regular_text(root, STATIC_CONTRACT_PATH)
    development_version = require_single_version(
        EXPECTED_VERSION_RE,
        static_text,
        "development-version",
    )
    published_version = require_single_version(
        PUBLISHED_VERSION_RE,
        static_text,
        "published-version",
    )

    if requested_version != development_version:
        raise VersionUpdateError(
            "release version does not match the checked-out development contract: "
            f"requested {requested_version}, found {development_version}"
        )
    if requested_version == published_version:
        check_published_version(root, requested_version)
        return False
    if parse_version(requested_version) <= parse_version(published_version):
        raise VersionUpdateError(
            "published release updates must increase monotonically: "
            f"{published_version} -> {requested_version}"
        )

    updated_files: dict[Path, str] = {}
    for relative_path in README_REFERENCE_TEMPLATES:
        readme_text = read_regular_text(root, relative_path)
        updated_files[relative_path] = replace_reference_set(
            relative_path,
            readme_text,
            published_version,
            requested_version,
        )

    updated_static, replacement_count = PUBLISHED_VERSION_RE.subn(
        f"readonly EXPECTED_PUBLISHED_VERSION='{requested_version}'",
        static_text,
        count=1,
    )
    if replacement_count != 1:
        raise VersionUpdateError("unable to update the published-version declaration")
    updated_files[STATIC_CONTRACT_PATH] = updated_static

    for relative_path, updated_text in updated_files.items():
        atomic_write_text(root / relative_path, updated_text)

    check_published_version(root, requested_version)
    return True


def parse_arguments() -> argparse.Namespace:
    """Parse the exact release version and optional verification controls."""

    parser = argparse.ArgumentParser(
        description="Update or verify published release references.",
    )
    parser.add_argument("version", help="published release version, without a v prefix")
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the current references without changing files",
    )
    parser.add_argument(
        "--root",
        type=Path,
        help="alternate repository root for isolated tests",
    )
    return parser.parse_args()


def main() -> int:
    """Run the requested update or non-mutating verification."""

    arguments = parse_arguments()
    try:
        parse_version(arguments.version)
        root = resolve_root(arguments.root)
        if arguments.check:
            check_published_version(root, arguments.version)
            print(f"Published documentation is aligned with {arguments.version}.")
        elif update_published_version(root, arguments.version):
            print(f"Updated published documentation to {arguments.version}.")
        else:
            print(f"Published documentation already targets {arguments.version}.")
    except VersionUpdateError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return EXIT_VALIDATION
    except OSError as exc:
        print(f"Error: unexpected filesystem failure: {exc}", file=sys.stderr)
        return EXIT_IO
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
