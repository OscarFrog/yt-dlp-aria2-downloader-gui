# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: scripts/check-push-version.py.

Check development versions before validation and in the Git pre-push hook.
Read version declarations as data; never execute a candidate or remote tree.
This check neither edits versions nor fetches objects, pushes refs or makes tags.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys


VERSION = re.compile(rb"^readonly VERSION=([\"'])([0-9]+\.[0-9]+\.[0-9]+)\1$", re.M)
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
OID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")
MAX_BYTES = 1024 * 1024
GIT_TIMEOUT = 20
DEVELOPMENT_MARKERS = {
    "README.md": "development version is **{version}**.",
    "README.fr.md": "développement actuelle est la **{version}**.",
}
RELEASE_ARGUMENTS = ("--ref v", "-f tag=v")
RPM_PATH = "packaging/rpm/yt-dlp-aria2-downloader-gui.spec"

# Reuse the maintained published-reference contract from this trusted checkout.
# Candidate trees are read as blobs below; their Python or Bash is never loaded.
PUBLISHED_SPEC = importlib.util.spec_from_file_location(
    "published_version", Path(__file__).with_name("update-published-version.py")
)
PUBLISHED = importlib.util.module_from_spec(PUBLISHED_SPEC)
PUBLISHED_SPEC.loader.exec_module(PUBLISHED)


class CheckError(Exception):
    """An actionable, sanitized refusal to validate a push."""


class Interrupted(Exception):
    """A handled signal must stop the active Git process group."""

    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def interrupt(signum, _frame):
    raise Interrupted(signum)


def git(*arguments):
    """Bound Git operations and suppress stderr, which can contain remote secrets."""
    environment = os.environ.copy()
    environment.update(
        GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0",
        GIT_NO_REPLACE_OBJECTS="1", LC_ALL="C",
    )
    process = subprocess.Popen(
        ["git", *arguments], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=environment, start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=GIT_TIMEOUT)
    except BaseException:
        # Cleanup also covers KeyboardInterrupt and handled HUP/TERM. The
        # original exception is re-raised, never converted into success.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    finally:
        process.stdout.close()
        process.stderr.close()
    if process.returncode:
        raise CheckError(
            "Git could not read the version baseline. Check the remote connection "
            "and fetch its main/target branch objects before retrying."
        )
    if len(output) > MAX_BYTES:
        raise CheckError("Git version metadata exceeds the supported size.")
    return output


def version_tuple(value):
    if not SEMVER.fullmatch(value) or any(len(part) > 9 for part in value.split(".")):
        raise CheckError("Expected a bounded numeric MAJOR.MINOR.PATCH version.")
    return tuple(int(part) for part in value.split("."))


def version_text(value):
    return ".".join(map(str, value))


def next_patch(value):
    return version_tuple(version_text((*value[:2], value[2] + 1)))


def release_argument_pattern(prefix):
    return re.compile(re.escape(prefix) + r"([0-9]+\.[0-9]+\.[0-9]+)(?=\s|$)")


def extract_version(data):
    matches = list(VERSION.finditer(data))
    if len(matches) != 1:
        raise CheckError("The engine must contain one literal readonly VERSION declaration.")
    return version_tuple(matches[0].group(2).decode("ascii"))


def object_version(oid):
    return extract_version(object_source(oid, "download-video.sh"))


def worktree_source(root, relative_path):
    path = root / relative_path
    if not stat.S_ISREG(path.lstat().st_mode):
        raise CheckError(f"{relative_path} must be a regular file, not a symbolic link.")
    with path.open("rb") as source:
        data = source.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise CheckError(f"{relative_path} exceeds the supported size.")
    return data


def object_source(oid, relative_path):
    if not OID.fullmatch(oid):
        raise CheckError("Invalid Git object identity in version metadata.")
    entry = git("ls-tree", oid, "--", relative_path).split(b"\t", 1)
    if (len(entry) != 2 or entry[0].split()[:2] not in
            ([b"100644", b"blob"], [b"100755", b"blob"]) or
            entry[1] != relative_path.encode("ascii") + b"\n"):
        raise CheckError(f"Committed {relative_path} must be a regular file.")
    object_path = f"{oid}:{relative_path}"
    size = git("cat-file", "-s", object_path).strip()
    if not size.isdigit() or len(size) > 9 or int(size) > MAX_BYTES:
        raise CheckError(f"Committed {relative_path} exceeds the supported size.")
    return git("cat-file", "blob", object_path)


def coherent_version(read_source):
    """Check linked source and published metadata without running candidate code."""
    candidate = extract_version(read_source("download-video.sh"))
    version = version_text(candidate)
    static_text = read_source("test-static.sh").decode("utf-8")
    try:
        expected = PUBLISHED.require_single_version(
            PUBLISHED.EXPECTED_VERSION_RE, static_text, "development-version"
        )
        published = PUBLISHED.require_single_version(
            PUBLISHED.PUBLISHED_VERSION_RE, static_text, "published-version"
        )
    except PUBLISHED.VersionUpdateError:
        raise CheckError("test-static.sh must declare exactly one source and published version.") from None
    if expected != version:
        raise CheckError(f"test-static.sh development version must match engine {version}.")
    if version_tuple(published) > candidate:
        raise CheckError("The published version cannot exceed the development version.")

    bootstrap = read_source("install-fedora.sh").decode("utf-8")
    declarations = re.findall(r"^readonly APP_VERSION='([^']*)'$", bootstrap, re.M)
    if declarations != [version]:
        raise CheckError(f"install-fedora.sh APP_VERSION must match engine {version}.")

    for relative_path, marker in DEVELOPMENT_MARKERS.items():
        text = read_source(relative_path).decode("utf-8")
        prefix, suffix = marker.split("{version}")
        declarations = re.findall(
            re.escape(prefix) + r"([^*\r\n]+)" + re.escape(suffix), text
        )
        if declarations != [version]:
            raise CheckError(f"{relative_path} must describe development version {version} exactly once.")
        for prefix in RELEASE_ARGUMENTS:
            if release_argument_pattern(prefix).findall(text) != [version]:
                raise CheckError(f"{relative_path} manual release example must use v{version}.")
        try:
            PUBLISHED.validate_reference_counts(Path(relative_path), text, published)
        except PUBLISHED.VersionUpdateError:
            # Updater details can include candidate text: name the carrier only.
            raise CheckError(f"{relative_path} published references must match {published}.") from None
        if published != version:
            unpublished_assets = (
                f"yt-dlp-aria2-downloader-gui-{version}-1.fc44.noarch.rpm",
                f"yt-dlp-aria2-downloader-gui_{version}-1_all.deb",
                f"yt-dlp-aria2-downloader-gui-{version}.zip",
            )
            if any(asset in text for asset in unpublished_assets):
                raise CheckError(f"{relative_path} advertises an unpublished development artifact.")

    changelog = read_source("CHANGELOG.md").decode("utf-8")
    headings = re.findall(r"^## ([0-9]+\.[0-9]+\.[0-9]+) - .+$", changelog, re.M)
    if not headings or headings[0] != version or headings.count(version) != 1:
        raise CheckError(f"CHANGELOG.md must begin with one unique version heading for {version}.")
    rpm = read_source(RPM_PATH).decode("utf-8").split("%changelog\n")
    if len(rpm) != 2:
        raise CheckError("The RPM spec must contain one changelog section.")
    entry_pattern = r"\* .+ - ([0-9]+\.[0-9]+\.[0-9]+)-[0-9]+"
    section = rpm[1].lstrip("\n").splitlines()
    first_entry = re.fullmatch(entry_pattern, section[0]) if section else None
    entries = re.findall("^" + entry_pattern + "$", rpm[1], re.M)
    if first_entry is None or first_entry[1] != version or entries.count(version) != 1:
        raise CheckError(f"The RPM changelog must begin with one unique entry for {version}.")
    return candidate


def worktree_version(root=None):
    # Offline mode works in source archives too, without a Git executable.
    root = root or Path(__file__).resolve().parents[1]
    return coherent_version(lambda path: worktree_source(root, path))


def remote_catalog(remote, branches):
    # A named remote avoids repeating credential-bearing URLs in subprocess
    # arguments. Refuse split fetch/push URLs rather than checking another repo.
    if (not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", remote) or
            remote not in git("remote").decode("utf-8").splitlines()):
        raise CheckError("Use a configured, named remote for version-checked pushes.")
    fetch_urls = git("remote", "get-url", "--all", remote).decode("utf-8").splitlines()
    push_urls = git("remote", "get-url", "--push", "--all", remote).decode("utf-8").splitlines()
    if len(fetch_urls) != 1 or fetch_urls != push_urls:
        raise CheckError("Version checking requires one identical fetch/push URL on the named remote.")
    output = git("ls-remote", "--refs", remote, "refs/heads/main", *sorted(branches), "refs/tags/v*")
    refs = {}
    tags = []
    for line in output.decode("utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) != 2 or not OID.fullmatch(fields[0]):
            raise CheckError("Malformed remote reference metadata.")
        oid, ref = fields
        if ref in refs:
            raise CheckError("Duplicate remote reference metadata.")
        refs[ref] = oid
        if ref.startswith("refs/tags/v") and SEMVER.fullmatch(ref[11:]):
            tags.append(version_tuple(ref[11:]))
    if "refs/heads/main" not in refs:
        raise CheckError("The destination remote must have a main branch to establish its version.")
    baseline = max([object_version(refs["refs/heads/main"]), *tags])
    return refs, baseline


def next_version_metadata(remote, branch):
    """Bind the next PATCH to one fresh main/target/tag advertisement."""
    ref = f"refs/heads/{branch}"
    git("check-ref-format", ref)
    refs, floor = remote_catalog(remote, {ref})
    if ref in refs:
        floor = max(floor, object_version(refs[ref]))
    catalog = b"".join(sorted(
        f"{oid}\t{name}\n".encode("utf-8") for name, oid in refs.items()
    ))
    return {
        "schema_version": 1,
        "remote": remote,
        "branch": branch,
        "main_sha": refs["refs/heads/main"],
        "target_sha": refs.get(ref, "0" * len(refs["refs/heads/main"])),
        "floor_version": version_text(floor),
        "next_version": version_text(next_patch(floor)),
        "refs_sha256": hashlib.sha256(catalog).hexdigest(),
    }


def require_increase(candidate, baseline):
    if candidate <= baseline:
        raise CheckError(
            f"Source push refused: version {version_text(candidate)} must be newer than "
            f"{version_text(baseline)}. Prepare {version_text(next_patch(baseline))} (or the requested "
            "higher version), update all linked metadata, validate and commit before pushing."
        )


def parse_updates(data):
    updates = []
    if len(data) > MAX_BYTES:
        raise CheckError("Too much pre-push reference metadata.")
    for line in data.decode("utf-8").splitlines():
        fields = line.split()
        if len(fields) != 4 or not OID.fullmatch(fields[1]) or not OID.fullmatch(fields[3]):
            raise CheckError("Malformed pre-push reference metadata.")
        _, local_oid, remote_ref, remote_oid = fields
        if (remote_ref.startswith("refs/heads/") and
                set(local_oid) != {"0"} and local_oid != remote_oid):
            git("check-ref-format", remote_ref)
            updates.append((local_oid, remote_ref, remote_oid))
    return updates


def check_hook(remote, data):
    updates = parse_updates(data)
    if not updates:
        return  # Deletions, tags and no-op pushes do not publish new source commits.
    candidates = {
        oid: coherent_version(lambda path, oid=oid: object_source(oid, path))
        for oid in {oid for oid, _, _ in updates}
    }
    refs, baseline = remote_catalog(remote, {ref for _, ref, _ in updates})
    versions = {}
    for local_oid, remote_ref, remote_oid in updates:
        advertised = refs.get(remote_ref, "0" * len(remote_oid))
        if advertised != remote_oid:
            raise CheckError("The destination branch changed during the check; retry against its fresh state.")
        floor = baseline
        if set(remote_oid) != {"0"}:
            if remote_oid not in versions:
                versions[remote_oid] = object_version(remote_oid)
            floor = max(floor, versions[remote_oid])
        require_increase(candidates[local_oid], floor)
    print("Pre-push version check passed for all source updates.", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    coherence = commands.add_parser("coherence", help="check all linked version metadata offline")
    coherence.add_argument("--root", type=Path, help="alternate source tree for isolated qualification")
    check = commands.add_parser("check", help="check the working version before running validation")
    check.add_argument("--remote", default="origin")
    check.add_argument("--branch", help="destination branch; defaults to the current local branch")
    next_version = commands.add_parser("next-version", help="read a fresh automation version baseline as JSON")
    next_version.add_argument("--remote", default="origin")
    next_version.add_argument("--branch", required=True, help="destination automation branch")
    hook = commands.add_parser("hook", help="Git pre-push protocol; validates committed objects")
    hook.add_argument("remote")
    args = parser.parse_args(argv)
    try:
        if args.command == "coherence":
            version = worktree_version(args.root)
            print(f"Source and published version metadata are coherent (development {version_text(version)}).")
        elif args.command == "hook":
            check_hook(args.remote, sys.stdin.buffer.read(MAX_BYTES + 1))
        elif args.command == "next-version":
            print(json.dumps(next_version_metadata(args.remote, args.branch), sort_keys=True))
        else:
            root = Path(git("rev-parse", "--show-toplevel").decode("utf-8").removesuffix("\n"))
            candidate = worktree_version(root)
            branch = args.branch
            if branch is None:
                branch = git("symbolic-ref", "--quiet", "--short", "HEAD").decode("utf-8").strip()
            ref = f"refs/heads/{branch}"
            git("check-ref-format", ref)
            refs, floor = remote_catalog(args.remote, {ref})
            if ref in refs:
                floor = max(floor, object_version(refs[ref]))
            require_increase(candidate, floor)
            print("Working version passes; validate and commit this tree before pushing.")
        return 0
    except CheckError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 65
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        print("Error: version check unavailable or interrupted by a Git timeout; push refused.", file=sys.stderr)
        return 69
    except Interrupted as error:
        print("Error: version check interrupted; push refused.", file=sys.stderr)
        return 128 + error.signum
    except KeyboardInterrupt:
        print("Error: version check interrupted; push refused.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    for handled_signal in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(handled_signal, interrupt)
    raise SystemExit(main())
