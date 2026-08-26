# SPDX-License-Identifier: MIT
"""
Build and publish private aria2 direct-transfer plans.

The helper deliberately keeps media URLs and HTTP headers out of process
arguments. It accepts only direct HTTP(S) formats selected by yt-dlp, writes an
aria2 input file with mode 0600, and later publishes successfully downloaded
staging files under the exact filenames expected by yt-dlp.

This file is intentionally non-executable. Invoke it explicitly with python3.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from pathlib import Path
from urllib.parse import urlsplit


EXIT_USAGE = 2
EXIT_VALIDATION = 65
EXIT_IO = 70

HEADER_NAME_RE = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")
DIRECT_REPLAY_SAFE_HEADERS = frozenset(
    {
        "accept",
        "accept-language",
        "sec-fetch-mode",
        "user-agent",
    }
)
FORMAT_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
EXTENSION_RE = re.compile(r"^[A-Za-z0-9]+$")
STAGING_NAME_RE = re.compile(r"^item-[0-9]{3}\.download$")


class PlanError(Exception):
    """Expected validation failure."""

class DestinationExistsError(PlanError):
    """A final destination already exists and must not be overwritten."""



def reject_controls(value: str, label: str, *, reject_whitespace: bool) -> None:
    for character in value:
        codepoint = ord(character)

        if (
            codepoint < 0x20
            or codepoint == 0x7F
            or (reject_whitespace and character.isspace())
        ):
            raise PlanError(f"{label} contains an unsafe control/whitespace character")


def require_private_regular_file(path: Path, label: str) -> None:
    try:
        file_stat = path.lstat()
    except FileNotFoundError as exc:
        raise PlanError(f"{label} does not exist") from exc

    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        raise PlanError(f"{label} must be a regular non-symlink file")

    if stat.S_IMODE(file_stat.st_mode) & 0o077:
        raise PlanError(f"{label} must not be accessible by group or other users")


def resolve_output_directory(raw_path: str) -> Path:
    path = Path(raw_path)

    if not path.is_absolute():
        raise PlanError("output directory must be absolute")

    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise PlanError("unable to resolve output directory") from exc

    if not resolved.is_dir():
        raise PlanError("output directory is not a directory")

    return resolved


def resolve_staging_directory(raw_path: str, output_dir: Path) -> Path:
    path = Path(raw_path)

    if not path.is_absolute():
        raise PlanError("staging directory must be absolute")

    try:
        staging_stat = path.lstat()
    except FileNotFoundError as exc:
        raise PlanError("staging directory does not exist") from exc

    if stat.S_ISLNK(staging_stat.st_mode) or not stat.S_ISDIR(staging_stat.st_mode):
        raise PlanError("staging directory must be a non-symlink directory")

    if stat.S_IMODE(staging_stat.st_mode) != 0o700:
        raise PlanError("staging directory must have mode 0700")

    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise PlanError("unable to resolve staging directory") from exc

    if resolved.parent != output_dir:
        raise PlanError("staging directory must be a direct child of output directory")

    return resolved


def resolve_private_output_path(raw_path: str, staging_dir: Path, label: str) -> Path:
    path = Path(raw_path)

    if not path.is_absolute():
        raise PlanError(f"{label} must be absolute")

    if path.name in {"", ".", ".."}:
        raise PlanError(f"{label} has an invalid basename")

    try:
        resolved_parent = path.parent.resolve(strict=True)
    except OSError as exc:
        raise PlanError(f"unable to resolve parent directory for {label}") from exc

    if resolved_parent != staging_dir:
        raise PlanError(f"{label} must be created inside the staging directory")

    resolved = resolved_parent / path.name

    if os.path.lexists(resolved):
        raise PlanError(f"{label} already exists")

    return resolved


def read_json(path: Path, label: str) -> object:
    require_private_regular_file(path, label)

    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PlanError(f"unable to read valid JSON from {label}") from exc


def resolve_destination(
    filename: object,
    output_dir: Path,
    label: str,
) -> Path:
    if not isinstance(filename, str) or not filename:
        raise PlanError(f"{label} is absent")

    reject_controls(filename, label, reject_whitespace=False)

    candidate = Path(filename)

    if not candidate.is_absolute():
        candidate = output_dir / candidate

    if candidate.name in {"", ".", ".."}:
        raise PlanError(f"{label} has an invalid basename")

    reject_controls(candidate.name, f"{label} basename", reject_whitespace=False)

    try:
        resolved_parent = candidate.parent.resolve(strict=True)
    except OSError as exc:
        raise PlanError(f"unable to resolve parent directory for {label}") from exc

    if resolved_parent != output_dir:
        raise PlanError(f"{label} escapes the output directory")

    # Preserve the final path component verbatim. Resolving the complete path
    # here would follow a pre-existing final symlink and could silently change
    # the filename that yt-dlp selected.
    return resolved_parent / candidate.name


def validate_url(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise PlanError("requested format has no URL")

    reject_controls(value, "URL", reject_whitespace=True)

    try:
        parsed = urlsplit(value)
    except ValueError as exc:
        raise PlanError("requested format has an invalid URL") from exc

    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise PlanError("only absolute HTTP(S) format URLs are accepted")

    return value


def validate_headers(value: object) -> dict[str, str]:
    if value is None:
        return {}

    if not isinstance(value, dict):
        raise PlanError("http_headers must be a JSON object")

    headers: dict[str, str] = {}

    for raw_name, raw_value in value.items():
        if not isinstance(raw_name, str) or not HEADER_NAME_RE.fullmatch(raw_name):
            raise PlanError("unsafe HTTP header name in yt-dlp plan")

        if not isinstance(raw_value, str):
            raise PlanError(f"HTTP header {raw_name} value must be a string")

        header_value = raw_value
        reject_controls(
            header_value,
            f"HTTP header {raw_name}",
            reject_whitespace=False,
        )
        headers[raw_name] = header_value

    return headers


def direct_headers_are_replay_safe(headers: dict[str, str]) -> bool:
    return all(
        header_name.lower() in DIRECT_REPLAY_SAFE_HEADERS
        for header_name in headers
    )


def format_id_is_representable(value: object) -> bool:
    return (
        isinstance(value, str)
        and FORMAT_ID_RE.fullmatch(value) is not None
    )


def extension_is_representable(value: object) -> bool:
    return (
        isinstance(value, str)
        and EXTENSION_RE.fullmatch(value) is not None
    )


def component_destination(
    root_destination: Path,
    format_info: dict[str, object],
) -> Path:
    format_id = format_info.get("format_id")
    extension = format_info.get("ext")

    if not format_id_is_representable(format_id):
        raise PlanError("requested format has an unsafe format_id")

    if not extension_is_representable(extension):
        raise PlanError("requested format has an unsafe extension")

    base = root_destination.with_suffix(f".{extension}")
    component = base.with_name(
        f"{base.stem}.f{format_id}{base.suffix}"
    )

    if component.parent != root_destination.parent:
        raise PlanError("calculated component path escapes output directory")

    return component


def write_private_new(path: Path, payload: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL

    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as exc:
        raise PlanError(f"unable to create private file: {path.name}") from exc

    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        try:
            path.unlink(missing_ok=True)
        finally:
            raise


def build_plan(args: argparse.Namespace) -> int:
    output_dir = resolve_output_directory(args.output_dir)
    staging_dir = resolve_staging_directory(args.staging_dir, output_dir)

    plan_path = Path(args.plan)
    plan = read_json(plan_path, "yt-dlp plan")

    if not isinstance(plan, dict):
        raise PlanError("yt-dlp plan root must be a JSON object")

    downloads = plan.get("requested_downloads")

    if not isinstance(downloads, list) or len(downloads) != 1:
        raise PlanError("yt-dlp plan must contain exactly one requested download")

    root = downloads[0]

    if not isinstance(root, dict):
        raise PlanError("requested download is not a JSON object")

    root_destination = resolve_destination(
        root.get("filename") or root.get("_filename"),
        output_dir,
        "yt-dlp requested filename",
    )

    requested_formats = root.get("requested_formats")

    if requested_formats is None:
        transfers: list[dict[str, object]] = [root]
        destinations = [root_destination]
    else:
        if not isinstance(requested_formats, list) or not requested_formats:
            raise PlanError("requested_formats must be a non-empty JSON array")

        if len(requested_formats) > 16:
            raise PlanError("too many requested formats")

        transfers = []
        destinations = []

        for raw_format in requested_formats:
            if not isinstance(raw_format, dict):
                raise PlanError("requested format is not a JSON object")

            transfers.append(raw_format)
            destinations.append(
                component_destination(root_destination, raw_format)
            )

    if len(set(destinations)) != len(destinations):
        raise PlanError("multiple requested formats resolve to the same destination")

    aria2_input_path = resolve_private_output_path(
        args.aria2_input,
        staging_dir,
        "aria2 input file",
    )
    manifest_path = resolve_private_output_path(
        args.manifest,
        staging_dir,
        "transfer manifest",
    )

    input_lines: list[str] = []
    manifest_items: list[dict[str, str]] = []

    for index, (transfer, destination) in enumerate(
        zip(transfers, destinations, strict=True)
    ):
        url = validate_url(transfer.get("url"))

        protocol = transfer.get("protocol")
        if protocol not in {"http", "https"}:
            raise PlanError(
                f"unsupported direct-transfer protocol: {protocol!r}"
            )

        headers = validate_headers(transfer.get("http_headers"))
        if not direct_headers_are_replay_safe(headers):
            raise PlanError(
                "HTTP headers require native yt-dlp transport"
            )

        staging_name = f"item-{index:03d}.download"

        input_lines.append(url)
        input_lines.append(f"  out={staging_name}")

        for header_name in sorted(headers):
            input_lines.append(
                f"  header={header_name}: {headers[header_name]}"
            )

        manifest_items.append(
            {
                "staging_name": staging_name,
                "destination": str(destination),
            }
        )

    manifest = {
        "version": 1,
        "output_dir": str(output_dir),
        "staging_dir": str(staging_dir),
        "items": manifest_items,
    }

    try:
        write_private_new(
            aria2_input_path,
            "\n".join(input_lines) + "\n",
        )

        write_private_new(
            manifest_path,
            json.dumps(
                manifest,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            + "\n",
        )
    except Exception:
        aria2_input_path.unlink(missing_ok=True)
        manifest_path.unlink(missing_ok=True)
        raise

    print(f"transfer_count={len(manifest_items)}")
    return 0


def classify_plan(args: argparse.Namespace) -> int:
    plan = read_json(Path(args.plan), "yt-dlp plan")

    if not isinstance(plan, dict):
        raise PlanError("yt-dlp plan root must be a JSON object")

    downloads = plan.get("requested_downloads")

    if not isinstance(downloads, list) or len(downloads) != 1:
        raise PlanError(
            "yt-dlp plan must contain exactly one requested download"
        )

    root = downloads[0]

    if not isinstance(root, dict):
        raise PlanError("requested download is not a JSON object")

    requested_formats = root.get("requested_formats")

    if requested_formats is None:
        transfers: list[dict[str, object]] = [root]
    else:
        if not isinstance(requested_formats, list) or not requested_formats:
            raise PlanError(
                "requested_formats must be a non-empty JSON array"
            )

        if len(requested_formats) > 16:
            raise PlanError("too many requested formats")

        transfers = []

        for raw_format in requested_formats:
            if not isinstance(raw_format, dict):
                raise PlanError(
                    "requested format is not a JSON object"
                )

            if (
                not format_id_is_representable(raw_format.get("format_id"))
                or not extension_is_representable(raw_format.get("ext"))
            ):
                print("transport=native")
                print(f"transfer_count={len(requested_formats)}")
                return 0

            transfers.append(raw_format)

    for transfer in transfers:
        protocol = transfer.get("protocol")

        if protocol not in {"http", "https"}:
            print("transport=native")
            print(f"transfer_count={len(transfers)}")
            return 0

        validate_url(transfer.get("url"))
        headers = validate_headers(transfer.get("http_headers"))
        if not direct_headers_are_replay_safe(headers):
            print("transport=native")
            print(f"transfer_count={len(transfers)}")
            return 0

    print("transport=direct")
    print(f"transfer_count={len(transfers)}")
    return 0


def load_manifest(path: Path) -> dict[str, object]:
    manifest = read_json(path, "transfer manifest")

    if not isinstance(manifest, dict):
        raise PlanError("transfer manifest root must be a JSON object")

    if manifest.get("version") != 1:
        raise PlanError("unsupported transfer manifest version")

    return manifest


def path_matches_identity(path: Path, identity: tuple[int, int]) -> bool:
    try:
        path_stat = path.lstat()
    except FileNotFoundError:
        return False

    return (
        stat.S_ISREG(path_stat.st_mode)
        and (path_stat.st_dev, path_stat.st_ino) == identity
    )


def publish_without_overwrite(
    source: Path,
    destination: Path,
) -> tuple[int, int]:
    try:
        source_stat = source.lstat()
    except OSError as exc:
        raise PlanError(
            f"unable to inspect downloaded component: {source.name}"
        ) from exc

    source_identity = (source_stat.st_dev, source_stat.st_ino)

    try:
        os.link(source, destination, follow_symlinks=False)
    except FileExistsError as exc:
        raise DestinationExistsError(
            f"destination already exists: {destination.name}"
        ) from exc
    except OSError as exc:
        raise PlanError(
            f"unable to publish downloaded component: {destination.name}"
        ) from exc

    if not path_matches_identity(destination, source_identity):
        raise PlanError(
            f"published destination changed unexpectedly: {destination.name}"
        )

    try:
        source.unlink()
    except OSError:
        # Never remove a path that another process replaced after publication.
        if path_matches_identity(destination, source_identity):
            destination.unlink(missing_ok=True)
        raise

    return source_identity


def rollback_publication(
    moved: list[tuple[Path, Path, tuple[int, int]]],
) -> None:
    for source, destination, identity in reversed(moved):
        try:
            if source.exists() or not path_matches_identity(destination, identity):
                continue

            os.link(destination, source, follow_symlinks=False)

            # Rollback is conservative: never remove a path whose inode changed.
            if path_matches_identity(destination, identity):
                destination.unlink()
        except OSError:
            pass


def commit_plan(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest)
    manifest = load_manifest(manifest_path)

    raw_output_dir = manifest.get("output_dir")
    raw_staging_dir = manifest.get("staging_dir")
    raw_items = manifest.get("items")

    if not isinstance(raw_output_dir, str):
        raise PlanError("manifest output_dir is invalid")

    if not isinstance(raw_staging_dir, str):
        raise PlanError("manifest staging_dir is invalid")

    output_dir = resolve_output_directory(raw_output_dir)
    staging_dir = resolve_staging_directory(raw_staging_dir, output_dir)

    if not isinstance(raw_items, list) or not raw_items:
        raise PlanError("manifest contains no transfer items")

    if len(raw_items) > 16:
        raise PlanError("manifest contains too many transfer items")

    publications: list[tuple[Path, Path]] = []
    seen_destinations: set[Path] = set()

    for raw_item in raw_items:
        if not isinstance(raw_item, dict):
            raise PlanError("manifest transfer item is invalid")

        staging_name = raw_item.get("staging_name")
        raw_destination = raw_item.get("destination")

        if (
            not isinstance(staging_name, str)
            or not STAGING_NAME_RE.fullmatch(staging_name)
        ):
            raise PlanError("manifest staging filename is invalid")

        destination = resolve_destination(
            raw_destination,
            output_dir,
            "manifest destination",
        )

        if destination in seen_destinations:
            raise PlanError("manifest contains duplicate destinations")
        seen_destinations.add(destination)

        source = staging_dir / staging_name

        try:
            source_stat = source.lstat()
        except FileNotFoundError as exc:
            raise PlanError(
                f"downloaded staging file is missing: {staging_name}"
            ) from exc

        if stat.S_ISLNK(source_stat.st_mode) or not stat.S_ISREG(source_stat.st_mode):
            raise PlanError(
                f"downloaded staging entry is unsafe: {staging_name}"
            )

        if source_stat.st_size <= 0:
            raise PlanError(
                f"downloaded staging file is empty: {staging_name}"
            )

        aria2_control = Path(f"{source}.aria2")
        if os.path.lexists(aria2_control):
            raise PlanError(
                f"aria2 transfer is incomplete: {staging_name}"
            )

        if os.path.lexists(destination):
            raise DestinationExistsError(
                f"destination already exists: {destination.name}"
            )

        publications.append((source, destination))

    moved: list[tuple[Path, Path, tuple[int, int]]] = []

    try:
        for source, destination in publications:
            identity = publish_without_overwrite(source, destination)
            moved.append((source, destination, identity))
    except Exception:
        rollback_publication(moved)
        raise

    print(f"published_count={len(moved)}")
    return 0


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build or publish a private aria2 direct-transfer plan."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    classify = subparsers.add_parser(
        "classify",
        help="classify the selected yt-dlp transport as direct or native",
    )
    classify.add_argument("--plan", required=True)
    classify.set_defaults(handler=classify_plan)

    build = subparsers.add_parser(
        "build",
        help="convert a private yt-dlp plan into a private aria2 input file",
    )
    build.add_argument("--plan", required=True)
    build.add_argument("--output-dir", required=True)
    build.add_argument("--staging-dir", required=True)
    build.add_argument("--aria2-input", required=True)
    build.add_argument("--manifest", required=True)
    build.set_defaults(handler=build_plan)

    commit = subparsers.add_parser(
        "commit",
        help="publish completed staging files under yt-dlp's expected names",
    )
    commit.add_argument("--manifest", required=True)
    commit.set_defaults(handler=commit_plan)

    return parser


def main() -> int:
    if sys.version_info < (3, 10):
        print(
            "Error: private aria2 planning requires Python 3.10 or newer",
            file=sys.stderr,
        )
        return EXIT_VALIDATION

    parser = create_parser()
    args = parser.parse_args()

    try:
        return int(args.handler(args))
    except DestinationExistsError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except PlanError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return EXIT_VALIDATION
    except OSError as exc:
        print(f"Error: operating-system failure: {exc}", file=sys.stderr)
        return EXIT_IO


if __name__ == "__main__":
    sys.exit(main())
