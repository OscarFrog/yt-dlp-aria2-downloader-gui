# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: scripts/prepare-source-version.py.

Prepare the seven development-version surfaces in an unprivileged source tree.
The caller supplies its verified remote floor, base-commit date and change reason;
this offline helper never fetches, commits, pushes or publishes release artifacts.
Publication workflows must independently verify the resulting bytes as data.
"""

import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys


SPEC = importlib.util.spec_from_file_location(
    "push_version", Path(__file__).with_name("check-push-version.py")
)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
RPM_PATH = CHECK.RPM_PATH
SOURCE_PATHS = (
    "download-video.sh", "install-fedora.sh", "test-static.sh",
    "README.md", "README.fr.md", "CHANGELOG.md", RPM_PATH,
)
REASON = re.compile(r"[A-Za-z0-9][A-Za-z0-9 .,:()/_-]{0,119}")
WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def replace_once(text, before, after, label):
    if text.count(before) != 1:
        raise CHECK.CheckError(f"Expected one exact {label} before preparing the source version.")
    return text.replace(before, after, 1)


def prepare_texts(originals, floor_version, reason, date):
    """Validate all transformations before staging or modifying any source file."""
    old = CHECK.coherent_version(lambda path: originals[path].encode("utf-8"))
    floor = CHECK.version_tuple(floor_version)
    new = CHECK.next_patch(max(old, floor))
    if not REASON.fullmatch(reason):
        raise CHECK.CheckError("The source-version reason must be bounded, single-line ASCII prose.")
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", date):
        raise CHECK.CheckError("The source-version date must use YYYY-MM-DD.")
    try:
        calendar_date = datetime.date.fromisoformat(date)
    except ValueError:
        raise CHECK.CheckError("The source-version date must be a valid calendar date.") from None
    old_text, new_text = CHECK.version_text(old), CHECK.version_text(new)
    updated = dict(originals)
    updated["download-video.sh"] = CHECK.VERSION.sub(
        lambda match: b"readonly VERSION=" + match[1] + new_text.encode("ascii") + match[1],
        originals["download-video.sh"].encode("utf-8"),
    ).decode("utf-8")
    for path, declaration in (
        ("install-fedora.sh", "readonly APP_VERSION"),
        ("test-static.sh", "readonly EXPECTED_VERSION"),
    ):
        updated[path] = replace_once(
            originals[path], f"{declaration}='{old_text}'", f"{declaration}='{new_text}'", path
        )
    for path, marker in CHECK.DEVELOPMENT_MARKERS.items():
        text = replace_once(originals[path], marker.format(version=old_text),
                            marker.format(version=new_text), f"{path} development announcement")
        for prefix in CHECK.RELEASE_ARGUMENTS:
            text, count = CHECK.release_argument_pattern(prefix).subn(prefix + new_text, text)
            if count != 1:
                raise CHECK.CheckError(f"Expected one manual release argument in {path}.")
        updated[path] = text
    if not originals["CHANGELOG.md"].startswith("# Changelog\n\n"):
        raise CHECK.CheckError("CHANGELOG.md must begin with the canonical title.")
    updated["CHANGELOG.md"] = replace_once(
        originals["CHANGELOG.md"], "# Changelog\n\n",
        f"# Changelog\n\n## {new_text} - Unreleased\n\n### Maintenance\n\n- {reason}\n\n",
        "CHANGELOG title",
    )
    rpm_date = (
        f"{WEEKDAYS[calendar_date.weekday()]} {MONTHS[calendar_date.month - 1]} "
        f"{calendar_date.day:02d} {calendar_date.year:04d}"
    )
    updated[RPM_PATH] = replace_once(
        originals[RPM_PATH], "%changelog\n",
        f"%changelog\n* {rpm_date} OscarFrog <151366285+OscarFrog@users.noreply.github.com> "
        f"- {new_text}-1\n- {reason}\n\n", "RPM changelog section",
    )
    CHECK.coherent_version(lambda path: updated[path].encode("utf-8"))
    return updated, {"old_version": old_text, "new_version": new_text, "date": date, "reason": reason}


def read_sources(root):
    originals = {}
    for relative in SOURCE_PATHS:
        path = Path(relative)
        for parent in path.parents:
            if not stat.S_ISDIR((root / parent).lstat().st_mode):
                raise CHECK.CheckError("Source-version directories must be real directories, not symlinks.")
        originals[relative] = CHECK.worktree_source(root, relative).decode("utf-8")
    return originals


def prepare_source_version(root, floor_version, reason, date):
    """Stage both generations and restore controlled partial failures safely.

    This is not a crash-atomic multi-file transaction. Callers own an isolated
    source tree; they must validate the complete tree before committing it.
    """
    root = root.resolve(strict=True)
    originals = read_sources(root)
    updated, metadata = prepare_texts(originals, floor_version, reason, date)
    staged, backups = {}, {}
    attempted, retained = [], set()
    try:
        for relative in SOURCE_PATHS:
            backups[relative] = CHECK.PUBLISHED.stage_text(root / relative, originals[relative])
            staged[relative] = CHECK.PUBLISHED.stage_text(root / relative, updated[relative])
        if read_sources(root) != originals:
            raise CHECK.CheckError("Source files changed while the version update was being prepared.")
        for relative in SOURCE_PATHS:
            if CHECK.worktree_source(root, relative).decode("utf-8") != originals[relative]:
                raise CHECK.CheckError("Source files changed during the version update.")
            attempted.append(relative)
            os.replace(staged[relative], root / relative)
        CHECK.worktree_version(root)
    except BaseException:
        for relative in reversed(attempted):
            backup = backups[relative]
            try:
                current = CHECK.worktree_source(root, relative).decode("utf-8")
                if current == originals[relative]:
                    continue
                if current != updated[relative]:
                    raise CHECK.CheckError("The source was replaced by another writer.")
                os.replace(backup, root / relative)
            except (OSError, UnicodeError, CHECK.CheckError):
                retained.add(backup)
                print(f"Warning: preserving original {relative} in {backup}; automatic rollback was unsafe.",
                      file=sys.stderr)
        raise
    finally:
        for temporary in (*staged.values(), *backups.values()):
            if temporary not in retained:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    print(f"Warning: unable to remove source-version temporary {temporary}.", file=sys.stderr)
    return metadata


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--floor-version", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--reason", required=True)
    args = parser.parse_args(argv)
    try:
        metadata = prepare_source_version(args.root, args.floor_version, args.reason, args.date)
        print(json.dumps(metadata, sort_keys=True))
        return 0
    except CHECK.CheckError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 65
    except (OSError, UnicodeError, CHECK.PUBLISHED.VersionUpdateError):
        print("Error: unable to write a coherent source version; inspect the isolated tree before retrying.",
              file=sys.stderr)
        return 70
    except CHECK.Interrupted as error:
        print("Error: source-version preparation interrupted.", file=sys.stderr)
        return 128 + error.signum
    except KeyboardInterrupt:
        print("Error: source-version preparation interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    for handled_signal in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(handled_signal, CHECK.interrupt)
    raise SystemExit(main())
