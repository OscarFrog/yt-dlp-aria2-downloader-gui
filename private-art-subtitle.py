# SPDX-License-Identifier: MIT
"""Verify and prepare ARTE subtitles for yt-dlp-aria2-downloader-gui.

Repository path: private-art-subtitle.py

Preserved native HLS fragments are parsed independently of FFmpeg. Their
absolute media-clock cues form the reference for conversion and final MKV
verification. Unsupported presentation or clock changes fail explicitly.
This module is deliberately non-executable; invoke it with python3.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import html
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path


SPEC = importlib.util.spec_from_file_location("art_tracks", Path(__file__).with_name("private-art-tracks.py"))
TRACKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRACKS)
MAX_BYTES = 8 * 1024 * 1024
MAX_CUES = 100000
MAX_FRAGMENTS = 4096
MAX_TOTAL = 64 * 1024 * 1024
MPEGTS_WRAP = 1 << 33
TIMESTAMP = re.compile(r"(?:(\d{2,4}):)?([0-5]\d):([0-5]\d)([.,])(\d{3})\Z")
CUE_TIMING = re.compile(r"([^ \t]+)[ \t]+-->[ \t]+([^ \t]+)(?:[ \t]+(.*))?\Z")
TAG = re.compile(r"<([^<>]*)>")
CLASS_STYLE = re.compile(r"::cue\(\.(?P<class>[A-Za-z_][A-Za-z0-9_-]*)\)\s*\{[^{}]*\}\s*", re.S)
SETTINGS = frozenset(("vertical", "line", "position", "size", "align", "region"))


class SubtitleError(Exception):
    """A controlled subtitle diagnostic without source contents or URLs."""


def timestamp_ms(value: str, *, srt: bool = False) -> int:
    match = TIMESTAMP.fullmatch(value)
    if match is None or (not srt and match[4] != "."):
        raise SubtitleError("ARTE subtitle timestamp is invalid")
    return ((int(match[1] or 0) * 60 + int(match[2])) * 60 + int(match[3])) * 1000 + int(match[5])


def timestamp_string(value: int) -> str:
    if not isinstance(value, int) or not 0 <= value <= 9999 * 3600 * 1000:
        raise SubtitleError("ARTE subtitle time is outside the supported range")
    hours, remaining = divmod(value, 3600000)
    minutes, remaining = divmod(remaining, 60000)
    seconds, milliseconds = divmod(remaining, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{milliseconds:03d}"


def normalized_input(payload: bytes | str) -> str:
    if isinstance(payload, bytes):
        if len(payload) > MAX_BYTES:
            raise SubtitleError("ARTE subtitle exceeds the size limit")
        try:
            payload = payload.decode("utf-8-sig")
        except UnicodeError as error:
            raise SubtitleError("ARTE subtitle is not UTF-8") from error
    if not isinstance(payload, str) or len(payload.encode("utf-8")) > MAX_BYTES:
        raise SubtitleError("ARTE subtitle exceeds the size limit")
    payload = payload.removeprefix("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    if "\0" in payload:
        raise SubtitleError("ARTE subtitle contains an invalid zero byte")
    if any(len(line) > 65536 for line in payload.split("\n")):
        raise SubtitleError("ARTE subtitle line exceeds the size limit")
    return payload


def cue_text(value: str, *, srt: bool = False) -> tuple[str, str, set[str]]:
    """Return display text, SRT-safe useful markup and referenced CSS classes."""
    plain, styled, classes, stack = [], [], set(), []
    position = 0
    if srt:
        # SubRip can carry an alignment override emitted by FFmpeg. Position
        # is outside the standard-text contract; the actual words remain.
        value = re.sub(r"\{\\an[1-9]\}", "", value)
    def literal(piece):
        # WebVTT character references are decoded once. SubRip players do not
        # consistently decode HTML entities: '&amp;' can literally display as
        # six characters, so SRT comparison and emission preserve literal '&'.
        decoded = piece if srt else html.unescape(piece)
        if "<" in decoded or ">" in decoded:
            raise SubtitleError("ARTE subtitle contains literal angle brackets that standard SRT cannot preserve consistently; this text presentation is unsupported")
        return decoded
    for match in TAG.finditer(value):
        piece = literal(value[position:match.start()])
        plain.append(piece)
        styled.append(piece)
        token = match[1]
        closing = token.startswith("/")
        token = token[1:] if closing else token
        if token in ("b", "i", "u"):
            kind = token
            if closing:
                if not stack or stack.pop() != kind:
                    raise SubtitleError("ARTE subtitle has unbalanced text markup")
            else:
                stack.append(kind)
            styled.append("<" + ("/" if closing else "") + kind + ">")
        elif token == "c" or token.startswith("c.") or token == "v" or token.startswith("v ") or token == "lang" or token.startswith("lang "):
            kind = token.split(" ", 1)[0].split(".", 1)[0]
            if closing:
                if not stack or stack.pop() != kind:
                    raise SubtitleError("ARTE subtitle has unbalanced annotation markup")
            else:
                stack.append(kind)
                if kind == "c":
                    found = token.split(".")[1:]
                    if any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", item) for item in found):
                        raise SubtitleError("ARTE subtitle class annotation is invalid")
                    classes.update(found)
        elif srt and (token.startswith("font ") or token == "font"):
            # FFmpeg may use font tags for ordinary text styling. Comparison
            # concerns displayed text; source active CSS is rejected earlier.
            pass
        else:
            raise SubtitleError("ARTE subtitle uses unsupported active markup (ruby, karaoke or another tag); select a standard text track")
        position = match.end()
    piece = literal(value[position:])
    plain.append(piece)
    styled.append(piece)
    if stack:
        raise SubtitleError("ARTE subtitle has unclosed text markup")
    return "".join(plain), "".join(styled), classes


def parse_settings(value: str) -> dict:
    result = {}
    for item in value.split():
        key, separator, content = item.partition(":")
        if not separator or key not in SETTINGS or key in result or not content or len(content) > 128:
            raise SubtitleError("ARTE subtitle cue settings are invalid or unsupported")
        result[key] = content
    return result


def parse_webvtt(payload: bytes | str) -> dict:
    value = normalized_input(payload)
    blocks = re.split(r"\n[ \t]*\n", value.rstrip("\n"))
    if not blocks or not re.fullmatch(r"WEBVTT(?:[ \t].*)?", blocks[0].split("\n")[0]):
        raise SubtitleError("ARTE source is not a WebVTT file")
    mapping = None
    for line in blocks[0].split("\n")[1:]:
        if line.startswith("X-TIMESTAMP-MAP="):
            if mapping is not None:
                raise SubtitleError("ARTE subtitle repeats its timestamp map")
            fields = line.partition("=")[2].split(",")
            entries = {}
            for field in fields:
                key, separator, data = field.strip().partition(":")
                if not separator or key in entries:
                    raise SubtitleError("ARTE subtitle timestamp map is invalid")
                entries[key] = data
            if set(entries) != {"LOCAL", "MPEGTS"} or not re.fullmatch(r"\d{1,10}", entries["MPEGTS"]):
                raise SubtitleError("ARTE subtitle timestamp map is invalid")
            ticks = int(entries["MPEGTS"])
            if ticks >= MPEGTS_WRAP:
                raise SubtitleError("ARTE subtitle MPEGTS exceeds its 33-bit range")
            mapping = {"local_ms": timestamp_ms(entries["LOCAL"]), "mpegts": ticks}
        elif "-->" in line or ":" not in line:
            raise SubtitleError("ARTE WebVTT header is malformed")
    cues, styles, regions, used_classes = [], [], [], set()
    for block in blocks[1:]:
        if not block.strip():
            continue
        lines = block.split("\n")
        first = lines[0].strip()
        if first == "NOTE" or first.startswith("NOTE ") or first.startswith("NOTE\t"):
            continue
        if first in ("STYLE", "REGION"):
            if cues:
                raise SubtitleError("ARTE WebVTT presentation block appears after a cue")
            (styles if first == "STYLE" else regions).append("\n".join(lines[1:]))
            continue
        cue_id = None
        if "-->" not in lines[0]:
            cue_id = lines.pop(0)
        if not lines:
            raise SubtitleError("ARTE WebVTT cue has no timing line")
        match = CUE_TIMING.fullmatch(lines.pop(0))
        if match is None:
            raise SubtitleError("ARTE WebVTT cue timing is malformed")
        start, end = timestamp_ms(match[1]), timestamp_ms(match[2])
        if end <= start:
            raise SubtitleError("ARTE WebVTT cue duration is invalid")
        settings = parse_settings(match[3] or "")
        if "region" in settings:
            raise SubtitleError("ARTE subtitle uses an active REGION; standard SRT cannot preserve it")
        text, styled, classes = cue_text("\n".join(lines))
        used_classes.update(classes)
        cues.append({"start_ms": start, "end_ms": end, "text": text, "markup": styled,
                     "id": cue_id, "settings": settings})
        if len(cues) > MAX_CUES:
            raise SubtitleError("ARTE subtitle has too many cues")
    for style in styles:
        position = 0
        while position < len(style):
            if not style[position:].strip():
                break
            match = CLASS_STYLE.match(style, position)
            if match is None:
                raise SubtitleError("ARTE subtitle uses active or unsupported CSS; standard SRT cannot preserve it")
            if match["class"] in used_classes:
                raise SubtitleError("ARTE subtitle references an active STYLE class; standard SRT cannot preserve it")
            position = match.end()
    # WebVTT also defines built-in color classes without an explicit STYLE.
    if used_classes & {"white", "lime", "cyan", "red", "yellow", "magenta", "blue", "black",
                       "bg_white", "bg_lime", "bg_cyan", "bg_red", "bg_yellow", "bg_magenta", "bg_blue", "bg_black"}:
        raise SubtitleError("ARTE subtitle uses an active color class; standard SRT cannot preserve it")
    return {"cues": cues, "timestamp_map": mapping, "styles": styles, "regions": regions,
            "positioning_dropped": any(cue["settings"] for cue in cues)}


def normalized_cues(cues: list[dict]) -> list[dict]:
    result = [{key: cue[key] for key in ("start_ms", "end_ms", "text")} for cue in cues]
    return sorted(result, key=lambda cue: (cue["start_ms"], cue["end_ms"], cue["text"]))


def parse_srt(payload: bytes | str) -> list[dict]:
    value = normalized_input(payload)
    if not value.strip():
        return []
    result = []
    for block in re.split(r"\n[ \t]*\n", value.rstrip("\n")):
        if not block.strip():
            continue
        lines = block.split("\n")
        if re.fullmatch(r"\d{1,9}", lines[0].strip()):
            lines.pop(0)
        if not lines:
            raise SubtitleError("ARTE SRT cue has no timing")
        match = CUE_TIMING.fullmatch(lines.pop(0))
        if match is None:
            raise SubtitleError("ARTE SRT cue timing is malformed")
        start, end = timestamp_ms(match[1], srt=True), timestamp_ms(match[2], srt=True)
        if end <= start:
            raise SubtitleError("ARTE SRT cue duration is invalid")
        text, _markup, _classes = cue_text("\n".join(lines), srt=True)
        result.append({"start_ms": start, "end_ms": end, "text": text})
        if len(result) > MAX_CUES:
            raise SubtitleError("ARTE SRT exceeds the cue limit")
    return normalized_cues(result)


def serialize_srt(cues: list[dict]) -> bytes:
    blocks = []
    for index, cue in enumerate(sorted(cues, key=lambda item: (item["start_ms"], item["end_ms"], item["text"])), 1):
        blocks.append(f'{index}\n{timestamp_string(cue["start_ms"])} --> {timestamp_string(cue["end_ms"])}\n{cue.get("markup", cue["text"])}')
    return ("\n\n".join(blocks) + ("\n\n" if blocks else "")).encode()


def playlist_structure(manifest: str) -> dict:
    if not manifest.startswith("#EXTM3U") or len(manifest.encode()) > TRACKS.MAX_MANIFEST or "#EXT-X-ENDLIST" not in manifest:
        raise SubtitleError("ARTE subtitle requires a frozen finite HLS playlist")
    unsupported = ("#EXT-X-KEY", "#EXT-X-MAP", "#EXT-X-BYTERANGE", "#EXT-X-GAP")
    if any(marker in manifest for marker in unsupported):
        raise SubtitleError("ARTE subtitle playlist uses an unsupported encrypted, mapped, ranged or missing segment")
    segments, discontinuities, discontinuity = [], [], False
    for line in manifest.splitlines():
        line = line.strip()
        if line == "#EXT-X-DISCONTINUITY":
            discontinuity = True
        elif line and not line.startswith("#"):
            segments.append(line)
            discontinuities.append(discontinuity)
            discontinuity = False
    if not 1 <= len(segments) <= MAX_FRAGMENTS:
        raise SubtitleError("ARTE subtitle fragment count is unsupported")
    return {"count": len(segments), "discontinuities": discontinuities}


def normalize_fragments(fragments: list[dict], discontinuities=None) -> tuple[list[dict], dict]:
    """Map raw local cues to the common 90 kHz media clock exactly once."""
    if not fragments or len(fragments) > MAX_FRAGMENTS:
        raise SubtitleError("ARTE subtitle raw fragments are missing or excessive")
    discontinuities = discontinuities or [False] * len(fragments)
    if len(discontinuities) != len(fragments):
        raise SubtitleError("ARTE subtitle discontinuity inventory is inconsistent")
    result, previous_keys, previous_mpegts, wrap, first_offset = [], Counter(), None, 0, None
    for index, fragment in enumerate(fragments):
        mapping = fragment["timestamp_map"] or {"local_ms": 0, "mpegts": 0}
        mpegts = mapping["mpegts"]
        if previous_mpegts is not None and mpegts < previous_mpegts:
            if previous_mpegts - mpegts > MPEGTS_WRAP // 2:
                wrap += MPEGTS_WRAP
            else:
                raise SubtitleError("ARTE subtitle clock resets without a common anchor; this discontinuity is unsupported")
        if discontinuities[index] and index and (fragment["timestamp_map"] is None or fragments[index - 1]["timestamp_map"] is None):
            raise SubtitleError("ARTE subtitle discontinuity lacks an explicit shared timestamp map")
        previous_mpegts = mpegts
        offset = mpegts + wrap - mapping["local_ms"] * 90
        if first_offset is None:
            first_offset = offset
        current_keys = Counter()
        for original in fragment["cues"]:
            cue = dict(original)
            start_ticks, end_ticks = original["start_ms"] * 90 + offset, original["end_ms"] * 90 + offset
            if start_ticks < 0 or end_ticks <= start_ticks:
                raise SubtitleError("ARTE subtitle maps outside the supported common media clock")
            cue["start_ms"], cue["end_ms"] = (start_ticks + 45) // 90, (end_ticks + 45) // 90
            key = (cue["id"], cue["start_ms"], cue["end_ms"], cue["text"], cue["markup"], json.dumps(cue["settings"], sort_keys=True))
            # Only the same full interval/content in immediately neighbouring
            # HLS segments proves repetition. Equal words at another time, or
            # repeated cues within one fragment, remain independent cues.
            current_keys[key] += 1
            if current_keys[key] > previous_keys[key]:
                result.append(cue)
        previous_keys = current_keys
        if len(result) > MAX_CUES:
            raise SubtitleError("ARTE subtitle assembled cue count exceeds the limit")
    return result, {"clock": "mpegts-90000", "first_offset_ticks": first_offset,
                    "wrap_ticks": wrap, "fragments": len(fragments),
                    "mapping_applied": "raw-fragment-once", "discontinuities": sum(bool(item) for item in discontinuities)}


def read_private_bytes(path: Path) -> bytes:
    parent = TRACKS.private_parent(path)
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077 or metadata.st_nlink != 1 or metadata.st_size > MAX_BYTES:
            raise SubtitleError("ARTE subtitle source must be a bounded private regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            payload = source.read(MAX_BYTES + 1)
        if len(payload) > MAX_BYTES:
            raise SubtitleError("ARTE subtitle source exceeds the byte limit")
        return payload
    finally:
        os.close(descriptor)


def write_private_bytes(path: Path, payload: bytes) -> None:
    if len(payload) > MAX_BYTES:
        raise SubtitleError("ARTE prepared subtitle exceeds the byte limit")
    parent = TRACKS.private_parent(path)
    try:
        descriptor = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
    finally:
        os.close(parent)


def ffmpeg_convert(binary: str, source: Path, destination: Path) -> bool:
    """Run a bounded local conversion in the engine's existing process group."""
    source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    output_fd = -1
    try:
        metadata = os.fstat(source_fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077 or metadata.st_size > MAX_BYTES:
            raise SubtitleError("ARTE conversion source is no longer a private regular file")
        output_fd = os.open(destination, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        result = subprocess.run([binary, "-nostdin", "-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file,pipe",
                                 "-f", "webvtt", "-i", f"/proc/self/fd/{source_fd}", "-map", "0:s:0", "-c:s", "srt", "-f", "srt", "-y", f"/proc/self/fd/{output_fd}"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                pass_fds=(source_fd, output_fd), timeout=30, check=False)
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        raise SubtitleError("ARTE subtitle conversion exceeded its deadline") from None
    finally:
        os.close(source_fd)
        if output_fd >= 0:
            os.close(output_fd)


def ffmpeg_capability(binary: str, directory: Path) -> bool:
    # Test the installed binary's behavior; version strings cannot establish
    # whether its WebVTT decoder stops at STYLE and returns a zero-byte SRT.
    fixture = b"WEBVTT\n\nSTYLE\n::cue(.unused) { color: red; }\n\nREGION\nid:unused\nwidth:40%\n\nNOTE capability probe\n\nprobe-one\n00:00:46.080 --> 00:00:47.125\nHello &amp; <i>world</i>\nsecond line\n\nprobe-two\n00:00:47.000 --> 00:00:48.001\nOverlap\n"
    source, output = directory / "capability.vtt", directory / "capability.srt"
    write_private_bytes(source, fixture)
    expected = normalized_cues(parse_webvtt(fixture)["cues"])
    try:
        if not ffmpeg_convert(binary, source, output):
            return False
        return parse_srt(read_private_bytes(output)) == expected
    except SubtitleError:
        return False


def build_reference(plan: dict, expected: dict, directory: Path, *, ffmpeg: str = "ffmpeg") -> dict:
    TRACKS.validate_plan_provenance(plan, expected)
    descriptor = TRACKS.private_parent(directory / "reference.json")
    os.close(descriptor)
    reference = {"version": 1, "selection_digest": expected["selection_digest"], "plan_digest": expected["plan_digest"],
                 "tracks": [], "mode": "standard-srt-display-text", "positioning": "not-preserved"}
    if not expected["subtitles"]:
        return reference
    capable = ffmpeg_capability(ffmpeg, directory)
    reference["ffmpeg_webvtt_capable"] = capable
    total_bytes = 0
    for target in expected["subtitles"]:
        key = target["id"]
        if not TRACKS.KEY_RE.fullmatch(key):
            raise SubtitleError("ARTE subtitle identifier is invalid")
        source = plan["requested_subtitles"][key]
        source_path = directory / f"source.{key}.vtt"
        native_bytes = read_private_bytes(source_path)
        total_bytes += len(native_bytes)
        if total_bytes > MAX_TOTAL:
            raise SubtitleError("ARTE original subtitle evidence exceeds the total byte limit")
        native = parse_webvtt(native_bytes)
        raw_hashes = []
        if source.get("protocol") in ("m3u8", "m3u8_native"):
            structure = playlist_structure(source.get("hls_media_playlist_data", ""))
            fragments = []
            for index in range(1, structure["count"] + 1):
                raw = read_private_bytes(directory / f"source.{key}.vtt.part-Frag{index}")
                total_bytes += len(raw)
                if total_bytes > MAX_TOTAL:
                    raise SubtitleError("ARTE original subtitle evidence exceeds the total byte limit")
                raw_hashes.append(hashlib.sha256(raw).hexdigest())
                fragments.append(parse_webvtt(raw))
            # Unplanned fragment files could otherwise hide an incomplete or
            # different native transfer under a superficially valid filename.
            present = list(directory.glob(f"source.{key}.vtt.part-Frag*"))
            if len(present) != structure["count"]:
                raise SubtitleError("ARTE preserved subtitle fragments differ from the frozen playlist")
            cues, timeline = normalize_fragments(fragments, structure["discontinuities"])
        else:
            raw_hashes.append(hashlib.sha256(native_bytes).hexdigest())
            cues, timeline = normalize_fragments([native])
        if total_bytes > MAX_TOTAL:
            raise SubtitleError("ARTE original subtitle evidence exceeds the total byte limit")
        if not cues:
            raise SubtitleError("ARTE selected subtitle source is genuinely empty; select another track or disable subtitles")
        expected_cues = normalized_cues(cues)
        # Native HlsFD expresses merged cues relative to its first map. Apply
        # that first offset once for comparison, while the raw reference uses
        # each segment's original map independently. A native dedup/hinge
        # transformation never becomes the independent source reference.
        native_mapped = []
        for cue in native["cues"]:
            mapped = dict(cue)
            mapped["start_ms"] = (cue["start_ms"] * 90 + timeline["first_offset_ticks"] + 45) // 90
            mapped["end_ms"] = (cue["end_ms"] * 90 + timeline["first_offset_ticks"] + 45) // 90
            native_mapped.append(mapped)
        native_exact = normalized_cues(native_mapped) == expected_cues
        if not native_exact:
            print("[ARTE_SUBTITLES] Native WebVTT transformed source cues; preserving every independently parsed raw cue in controlled SRT.", file=sys.stderr)
        candidate = directory / f"candidate.{key}.srt"
        prepared = directory / f"prepared.{key}.srt"
        conversion = "controlled-srt"
        # FFmpeg does not apply WebVTT's HLS timestamp map. Any nonzero offset
        # therefore uses the controlled writer, even on a capable decoder.
        if capable and native_exact and timeline["first_offset_ticks"] == 0:
            if not ffmpeg_convert(ffmpeg, source_path, candidate):
                raise SubtitleError("ARTE FFmpeg subtitle conversion failed; no final media was published")
            candidate_bytes = read_private_bytes(candidate)
            if parse_srt(candidate_bytes) != expected_cues:
                raise SubtitleError("ARTE FFmpeg subtitle conversion is empty, partial or changed source text/timing despite its exit status")
            write_private_bytes(prepared, candidate_bytes)
            conversion = "ffmpeg-validated"
        if not prepared.exists():
            controlled = serialize_srt(cues)
            if parse_srt(controlled) != expected_cues:
                raise SubtitleError("ARTE controlled SRT conversion changed a source cue")
            write_private_bytes(prepared, controlled)
        payload = read_private_bytes(prepared)
        reference["tracks"].append({"id": key, "path": str(prepared), "sha256": hashlib.sha256(payload).hexdigest(),
                                    "source_sha256": hashlib.sha256(native_bytes).hexdigest(), "raw_fragment_sha256": raw_hashes,
                                    "source_identity": target["source_identity"], "cues": expected_cues,
                                    "source_cues": cues, "timeline": timeline, "native_cues_exact": native_exact,
                                    "conversion": conversion})
    return reference


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Private independent ARTE subtitle reference and conversion")
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build")
    for name in ("expected", "plan", "directory", "output"):
        build.add_argument("--" + name, required=True)
    build.add_argument("--ffmpeg", default="ffmpeg")
    return parser


def main() -> int:
    os.umask(0o077)
    args = create_parser().parse_args()
    try:
        reference = build_reference(TRACKS.read_json(args.plan), TRACKS.read_json(args.expected), Path(args.directory), ffmpeg=args.ffmpeg)
        TRACKS.write_json(args.output, reference)
        print(f'[ARTE_SUBTITLES] Verified {len(reference["tracks"])} source subtitle track(s); original WebVTT retained privately.')
        return 0
    except (SubtitleError, TRACKS.ArteError) as error:
        print(f"[ARTE_SUBTITLES] {error}", file=sys.stderr)
        return 65
    except (OSError, ValueError, KeyError, TypeError, OverflowError, RecursionError):
        print("[ARTE_SUBTITLES] Unable to verify private subtitle sources or conversion; analyse and select again.", file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
