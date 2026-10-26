# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: private-arte-media.py.

Validate the selected ARTE streams before and after a lossless local remux.
Probe children inherit the engine's supervised process group. Private JSON
files contain the provenance contract; only controlled diagnostics are public.
This module is deliberately non-executable and is invoked with python3.
"""

from __future__ import annotations

import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import resource
import selectors
import stat
import subprocess
import sys
import tempfile
import time


MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_PROBE_BYTES = 2 * 1024 * 1024
MAX_SUBTITLE_BYTES = 8 * 1024 * 1024
MAX_STREAMS = 48
POLICY = "arte-no-hearing-impaired-v1"
LANGUAGES = {
    "ja": "jpn", "jpn": "jpn", "fr": "fra", "fra": "fra", "fre": "fra",
    "de": "deu", "deu": "deu", "ger": "deu", "en": "eng", "eng": "eng",
    "es": "spa", "spa": "spa", "it": "ita", "ita": "ita", "pl": "pol",
    "pol": "pol", "pt": "por", "por": "por", "nl": "nld", "nld": "nld",
    "dut": "nld", "ru": "rus", "rus": "rus", "zh": "zho", "zho": "zho",
    "chi": "zho", "ar": "ara", "ara": "ara", "ko": "kor", "kor": "kor",
    "tr": "tur", "tur": "tur", "uk": "ukr", "ukr": "ukr", "sv": "swe",
    "swe": "swe", "da": "dan", "dan": "dan", "no": "nor", "nor": "nor",
    "fi": "fin", "fin": "fin", "el": "ell", "ell": "ell", "gre": "ell",
    "cs": "ces", "ces": "ces", "cze": "ces", "hu": "hun", "hun": "hun",
    "ro": "ron", "ron": "ron", "rum": "ron", "he": "heb", "heb": "heb",
    "hi": "hin", "hin": "hin", "fa": "fas", "fas": "fas", "per": "fas",
}


class MediaError(Exception):
    """A public, controlled validation reason without media URLs or paths."""


def read_private_json(path: Path) -> dict:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(descriptor, "rb") as handle:
        metadata = os.fstat(handle.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or stat.S_IMODE(metadata.st_mode) & 0o077
                or metadata.st_size > MAX_JSON_BYTES):
            raise MediaError("ARTE validation input is not a bounded private regular file")
        raw = handle.read(MAX_JSON_BYTES + 1)
    if len(raw) > MAX_JSON_BYTES:
        raise MediaError("ARTE validation input exceeds the size limit")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise MediaError("ARTE validation input must be a JSON object")
    return value


def write_private_json(path: Path, value: dict) -> None:
    data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    if len(data) > MAX_JSON_BYTES:
        raise MediaError("ARTE probe result exceeds the size limit")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)


def decimal_value(value: object, *, positive: bool = False) -> Decimal | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None
    if not parsed.is_finite() or abs(parsed) > Decimal("9000000000"):
        return None
    if positive and parsed <= 0:
        return None
    return parsed


def language(value: object) -> str:
    if not isinstance(value, str) or not 2 <= len(value) <= 32:
        raise MediaError("ARTE track language is missing or invalid")
    normalized = value.lower().split("-", 1)[0]
    if not normalized.isascii() or not normalized.isalpha():
        raise MediaError("ARTE track language is invalid")
    # Keep an unrecognized language literal. Never silently label it undetermined.
    return LANGUAGES.get(normalized, normalized)


def checked_expected(expected: dict) -> None:
    if expected.get("version") != 1 or expected.get("policy") != POLICY:
        raise MediaError("ARTE selection policy changed; select the tracks again")
    video = expected.get("video")
    audio = expected.get("audio")
    subtitles = expected.get("subtitles")
    if (not isinstance(video, dict) or not isinstance(audio, list)
            or not 1 <= len(audio) <= 15 or not isinstance(subtitles, list)
            or len(subtitles) > 32):
        raise MediaError("ARTE expected track inventory is invalid")
    for kind, tracks in (("audio", audio), ("subtitle", subtitles)):
        for track in tracks:
            if not isinstance(track, dict):
                raise MediaError("ARTE expected track is invalid")
            language(track.get("language"))
            title = track.get("title")
            if (not isinstance(title, str) or not 1 <= len(title) <= 256
                    or any(ord(char) < 32 or ord(char) == 127 for char in title)):
                raise MediaError("ARTE track title is invalid")
            if type(track.get("default")) is not bool:
                raise MediaError("ARTE default disposition is invalid")
            allowed_roles = {"main", "description"} if kind == "audio" else {"full", "forced"}
            if track.get("role") not in allowed_roles:
                raise MediaError("ARTE excluded or unknown track role; select the tracks again")
            if kind == "subtitle" and (type(track.get("forced")) is not bool
                                       or track["forced"] != (track["role"] == "forced")):
                raise MediaError("ARTE forced subtitle disposition is invalid")
    if sum(track["default"] for track in audio) != 1:
        raise MediaError("ARTE selection requires exactly one default audio")
    if sum(track["default"] for track in subtitles) > 1:
        raise MediaError("ARTE selection contains several default subtitles")


def validate_provenance(plan: dict, expected: dict) -> None:
    checked_expected(expected)
    source = Path(__file__).with_name("private-arte-tracks.py")
    spec = importlib.util.spec_from_file_location("arte_tracks_validation", source)
    if spec is None or spec.loader is None:
        raise MediaError("ARTE provenance validator is unavailable")
    sys.dont_write_bytecode = True
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        module.validate_plan_provenance(plan, expected)
    except module.ArteError as exc:
        raise MediaError("ARTE executed plan no longer matches the admissible selection") from exc


def subtitle_parser():
    source = Path(__file__).with_name("private-arte-subtitles.py")
    spec = importlib.util.spec_from_file_location("arte_subtitles_validation", source)
    if spec is None or spec.loader is None:
        raise MediaError("ARTE subtitle reference parser is unavailable")
    sys.dont_write_bytecode = True
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_subtitle_cues(parser, payload: bytes) -> list[dict]:
    try:
        return parser.parse_srt(payload)
    except parser.SubtitleError as exc:
        raise MediaError(str(exc)) from exc


def read_subtitle_reference(path: Path | None, expected: dict) -> dict:
    if path is None:
        if expected["subtitles"]:
            raise MediaError("ARTE selected subtitles have no independent source reference")
        return {"tracks": []}
    reference = read_private_json(path)
    tracks = reference.get("tracks")
    if (reference.get("version") != 1 or reference.get("selection_digest") != expected.get("selection_digest")
            or reference.get("plan_digest") != expected.get("plan_digest") or not isinstance(tracks, list)
            or [entry.get("id") for entry in tracks if isinstance(entry, dict)]
            != [entry["id"] for entry in expected["subtitles"]]):
        raise MediaError("ARTE subtitle reference does not match the executed selection")
    parser = subtitle_parser()
    for entry, selected in zip(tracks, expected["subtitles"]):
        subtitle_path = entry.get("path")
        if (not isinstance(subtitle_path, str) or not Path(subtitle_path).is_absolute()
                or Path(subtitle_path) != path.parent / f"prepared.{selected['id']}.srt"
                or entry.get("source_identity") != selected.get("source_identity")):
            raise MediaError("ARTE prepared subtitle path is invalid")
        descriptor = os.open(subtitle_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        with os.fdopen(descriptor, "rb") as handle:
            metadata = os.fstat(handle.fileno())
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                    or stat.S_IMODE(metadata.st_mode) & 0o077 or metadata.st_size > MAX_JSON_BYTES):
                raise MediaError("ARTE prepared subtitle is not a bounded private file")
            payload = handle.read(MAX_JSON_BYTES + 1)
        if (len(payload) > MAX_JSON_BYTES or hashlib.sha256(payload).hexdigest() != entry.get("sha256")
                or not entry.get("cues") or parse_subtitle_cues(parser, payload) != entry["cues"]):
            raise MediaError("ARTE prepared subtitle differs from its independent source reference")
    return reference


def remux_arguments(expected: dict, plan: dict, reference: Path | None = None) -> list[str]:
    validate_provenance(plan, expected)
    prepared = read_subtitle_reference(reference, expected)
    # Map every source stream so an unexpected stream cannot disappear before
    # validation. Strip extraction metadata and chapters, retain encoded media.
    result = ["-copyts"]
    for track in prepared["tracks"]:
        result.extend(["-i", track["path"]])
    result.extend(["-map", "0"])
    for index in range(len(prepared["tracks"])):
        result.extend(["-map", f"{index + 1}:0"])
    result.extend(["-c", "copy", "-avoid_negative_ts", "disabled", "-map_metadata", "-1",
                   "-map_metadata:s", "-1", "-map_chapters", "-1", "-disposition:v:0", "default"])
    for kind, tracks in (("a", expected["audio"]), ("s", expected["subtitles"])):
        for index, track in enumerate(tracks):
            disposition = []
            if track["default"]:
                disposition.append("default")
            if track["role"] == "forced":
                disposition.append("forced")
            if track["role"] == "description":
                disposition.append("visual_impaired")
            result.extend([
                f"-metadata:s:{kind}:{index}", f"language={language(track['language'])}",
                f"-metadata:s:{kind}:{index}", f"title={track['title']}",
                f"-disposition:{kind}:{index}", "+".join(disposition) or "0",
            ])
    return result


def run_media_tool(executable: str, arguments: list[str], *, limit: int = MAX_PROBE_BYTES,
                   timeout: int = 15, output_file_limit: int | None = None,
                   watched_outputs: list[Path] | None = None) -> bytes:
    """Bound both output memory and child lifetime without creating a new group."""
    def limit_child_files() -> None:
        # This helper has no threads. Restrict only the child's regular-file
        # writes; the parent and its supervised process group keep their limits.
        resource.setrlimit(resource.RLIMIT_FSIZE, (output_file_limit, output_file_limit))

    process = subprocess.Popen([executable, "-v", "error", *arguments],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               preexec_fn=limit_child_files if output_file_limit is not None else None)
    data = bytearray()
    deadline = time.monotonic() + timeout

    def check_output_files() -> None:
        if watched_outputs is not None:
            total = 0
            for output in watched_outputs:
                metadata = output.lstat()
                if not stat.S_ISREG(metadata.st_mode):
                    raise MediaError("ARTE subtitle extraction output changed unexpectedly")
                total += metadata.st_size
            if total > 64 * 1024 * 1024:
                raise MediaError("ARTE extracted subtitles exceed the total size limit")

    try:
        if process.stdout is None:
            raise MediaError("ARTE media probe could not be opened")
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                check_output_files()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise MediaError("ARTE media probe timed out")
                events = selector.select(min(remaining, 0.5))
                for key, _ in events:
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    data.extend(chunk)
                    if len(data) > limit:
                        raise MediaError("ARTE media probe exceeds the size limit")
        try:
            status = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired as exc:
            raise MediaError("ARTE media probe timed out") from exc
        if status != 0:
            raise MediaError("ARTE media probe failed")
        check_output_files()
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        if process.stdout is not None:
            process.stdout.close()
    return bytes(data)


def run_probe(arguments: list[str]) -> dict:
    value = json.loads(run_media_tool("ffprobe", [*arguments, "-of", "json"]))
    if not isinstance(value, dict):
        raise MediaError("ARTE media probe returned an invalid object")
    return value


def duration_from_stream(stream: dict) -> Decimal | None:
    direct = decimal_value(stream.get("duration"), positive=True)
    if direct is not None:
        return direct
    tags = stream.get("tags") or {}
    duration = tags.get("DURATION", tags.get("duration")) if isinstance(tags, dict) else None
    if isinstance(duration, str) and len(duration) <= 32:
        fields = duration.split(":")
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            seconds = decimal_value(fields[2])
            if seconds is not None and 0 <= seconds < 60 and int(fields[1]) < 60:
                end = Decimal(fields[0]) * 3600 + Decimal(fields[1]) * 60 + seconds
                start = decimal_value(stream.get("start_time")) or Decimal(0)
                return decimal_value(end - start, positive=True)
    return None


def tolerance(duration: Decimal) -> Decimal:
    # Per-stream packet evidence remains strict even for feature-length films.
    return min(Decimal(5), max(Decimal(1), duration / 50))


def content_streams(probe: dict) -> tuple[list[dict], list[dict], list[dict]]:
    streams = probe.get("streams")
    if not isinstance(streams, list) or not 2 <= len(streams) <= MAX_STREAMS:
        raise MediaError("ARTE output has an invalid stream inventory")
    categories: dict[str, list[dict]] = {"video": [], "audio": [], "subtitle": []}
    indices = set()
    for stream in streams:
        if not isinstance(stream, dict) or type(stream.get("index")) is not int:
            raise MediaError("ARTE output contains an invalid stream")
        index = stream["index"]
        if not 0 <= index < MAX_STREAMS or index in indices:
            raise MediaError("ARTE output contains duplicate or invalid stream indices")
        indices.add(index)
        kind = stream.get("codec_type")
        disposition = stream.get("disposition") or {}
        if not isinstance(disposition, dict):
            raise MediaError("ARTE output contains an invalid disposition")
        if kind not in categories or disposition.get("attached_pic", 0):
            raise MediaError("ARTE output contains an unexpected stream or attachment")
        categories[kind].append(stream)
    return categories["video"], categories["audio"], categories["subtitle"]


def check_counts(probe: dict, expected: dict, *, source: bool = False) -> tuple[list[dict], list[dict], list[dict]]:
    video, audio, subtitles = content_streams(probe)
    if len(video) != 1 or len(audio) != len(expected["audio"]) or len(subtitles) != (0 if source else len(expected["subtitles"])):
        raise MediaError("ARTE output track count differs from the selected tracks")
    return video, audio, subtitles


def stream_evidence(path: Path, stream: dict, selected: dict, video_duration: Decimal) -> dict:
    duration = duration_from_stream(stream) or video_duration
    requested = decimal_value(selected.get("duration"), positive=True)
    target_duration = max(duration, requested or duration)
    start = decimal_value(stream.get("start_time")) or Decimal(0)
    threshold = start + target_duration - tolerance(target_duration)
    seek = max(Decimal(0), start + target_duration - 10)
    # FFprobe's seek can land on an earlier keyframe. A relative read duration
    # starts there, so a bounded media-time window need not reach the real end.
    # Read from the seek result through EOF; process/output limits still bound
    # the probe, and an interrupted or oversized observation produces no proof.
    packets = run_probe([
        "-select_streams", str(stream["index"]), "-read_intervals", f"{seek}%",
        "-show_packets", "-show_data_hash", "sha256", "-show_entries",
        "packet=pts_time,dts_time,duration_time,size,data_hash", str(path),
    ]).get("packets", [])
    end = None
    terminal = None
    packet_durations = []
    count = 0
    for packet in packets:
        if not isinstance(packet, dict):
            raise MediaError("ARTE packet probe returned an invalid packet")
        timestamp = decimal_value(packet.get("pts_time"))
        if timestamp is None:
            timestamp = decimal_value(packet.get("dts_time"))
        size = decimal_value(packet.get("size"), positive=True)
        if timestamp is None or size is None:
            continue
        packet_duration = decimal_value(packet.get("duration_time"), positive=True) or Decimal(0)
        if packet_duration > 0:
            packet_durations.append(packet_duration)
        packet_end = timestamp + packet_duration
        end = packet_end if end is None else max(end, packet_end)
        if terminal is None or timestamp > Decimal(terminal["pts"]):
            dts = decimal_value(packet.get("dts_time"))
            terminal = {"pts": str(timestamp), "dts": str(dts) if dts is not None else None,
                        "duration": str(packet_duration), "size": str(size), "data_hash": packet.get("data_hash")}
        count += 1
    evidence = {
        "duration": str(duration), "start": str(start), "target": str(threshold),
        "end": str(end) if end is not None else None, "count": count,
        "tail_complete": True, "tail_seek": str(seek),
        "terminal_packet": terminal, "declared_end": str(start + duration),
        "nominal_packet_duration": str(sorted(packet_durations)[len(packet_durations) // 2]) if packet_durations else None,
        "duration_packet_count": len(packet_durations),
    }
    head = run_probe([
        "-select_streams", str(stream["index"]), "-read_intervals", "%+5",
        "-show_packets", "-show_entries", "packet=pts_time,dts_time,size", str(path),
    ]).get("packets", [])
    for field in ("pts_time", "dts_time"):
        values = [decimal_value(packet.get(field)) for packet in head if isinstance(packet, dict)
                  and decimal_value(packet.get("size"), positive=True) is not None]
        values = [value for value in values if value is not None]
        if not values and field == "pts_time":
            raise MediaError("ARTE stream has no initial packet timestamp")
        evidence["first_" + field] = str(min(values)) if values else None
    evidence["head_timestamps"] = [
        {"pts": str(decimal_value(packet.get("pts_time"))),
         "dts": str(decimal_value(packet.get("dts_time"))) if decimal_value(packet.get("dts_time")) is not None else None}
        for packet in head if isinstance(packet, dict) and decimal_value(packet.get("pts_time")) is not None
    ]
    return evidence


def component_paths(plan: dict, expected: dict) -> list[Path]:
    validate_provenance(plan, expected)
    module_path = Path(__file__).with_name("private-aria2-plan.py")
    spec = importlib.util.spec_from_file_location("arte_component_paths", module_path)
    if spec is None or spec.loader is None:
        raise MediaError("ARTE component path validator is unavailable")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    try:
        selected = helper.selected_download(plan)
        destination = Path(selected.get("filename") or selected.get("_filename"))
        if not destination.is_absolute() or destination.parent.resolve(strict=True) != destination.parent:
            raise MediaError("ARTE component directory is not canonical")
        paths = [helper.component_destination(destination, item) for item in selected["requested_formats"]]
        if len(paths) != len(expected["audio"]) + 1 or any(path.parent != destination.parent for path in paths):
            raise MediaError("ARTE component paths do not match the executed plan")
        return paths
    except helper.PlanError as exc:
        raise MediaError("ARTE component paths failed the engine ownership contract") from exc


def file_identity(metadata: os.stat_result) -> list[int]:
    return [metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns]


def probe_components(plan: dict, expected: dict) -> dict:
    paths = component_paths(plan, expected)
    result = {"version": 1, "plan_digest": expected["plan_digest"],
              "selection_digest": expected["selection_digest"], "streams": [], "packet_evidence": {}, "files": []}
    for index, (path, selected) in enumerate(zip(paths, [expected["video"], *expected["audio"]])):
        metadata = path.lstat()
        parent = path.parent.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_size <= 0:
            raise MediaError("ARTE retained source component is missing or unsafe")
        identity = file_identity(metadata)
        probe = run_probe(["-show_streams", "-show_entries",
                           "stream=index,codec_type,codec_name,start_time,duration,time_base,sample_rate:stream_tags:stream_disposition", str(path)])
        streams = probe.get("streams")
        kind = "video" if index == 0 else "audio"
        if not isinstance(streams, list) or len(streams) != 1 or streams[0].get("codec_type") != kind:
            raise MediaError("ARTE source component contains unexpected streams")
        stream = streams[0]
        duration = duration_from_stream(stream) or decimal_value(selected.get("duration"), positive=True)
        if duration is None:
            raise MediaError("ARTE source component duration is unavailable")
        evidence = stream_evidence(path, stream, selected, duration)
        stream["index"] = index
        result["streams"].append(stream)
        result["packet_evidence"][str(index)] = evidence
        if file_identity(path.lstat()) != identity:
            raise MediaError("ARTE source component changed during the timing probe")
        result["files"].append({"path": str(path), "identity": identity,
                                "parent_identity": [parent.st_dev, parent.st_ino],
                                "source_identity": selected["source_identity"]})
    return result


def validate_component_records(records: dict, expected: dict, plan: dict) -> list[Path]:
    paths = component_paths(plan, expected)
    if (records.get("version") != 1 or records.get("plan_digest") != expected["plan_digest"]
            or records.get("selection_digest") != expected["selection_digest"]
            or not isinstance(records.get("files"), list) or len(records["files"]) != len(paths)):
        raise MediaError("ARTE source timing evidence does not match the executed plan")
    for path, entry, selected in zip(paths, records["files"], [expected["video"], *expected["audio"]]):
        if entry.get("path") != str(path) or entry.get("source_identity") != selected["source_identity"]:
            raise MediaError("ARTE source timing provenance changed")
    check_counts(records, expected, source=True)
    return paths


def cleanup_components(records: dict, expected: dict, plan: dict) -> None:
    paths = validate_component_records(records, expected, plan)
    parent = paths[0].parent
    descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        metadata = os.fstat(descriptor)
        parent_identity = [metadata.st_dev, metadata.st_ino]
        for path, entry in zip(paths, records["files"]):
            current = os.stat(path.name, dir_fd=descriptor, follow_symlinks=False)
            if (path.parent != parent or parent_identity != entry.get("parent_identity")
                    or not stat.S_ISREG(current.st_mode) or current.st_uid != os.geteuid()
                    or file_identity(current) != entry.get("identity")):
                raise MediaError("ARTE source component identity changed; retained for inspection")
        for path, entry in zip(paths, records["files"]):
            current = os.stat(path.name, dir_fd=descriptor, follow_symlinks=False)
            if not stat.S_ISREG(current.st_mode) or file_identity(current) != entry["identity"]:
                raise MediaError("ARTE source component changed during cleanup; retained for inspection")
            os.unlink(path.name, dir_fd=descriptor)
    finally:
        os.close(descriptor)


def probe_media(path: Path, expected: dict, *, source: bool = False, reference: Path | None = None) -> dict:
    checked_expected(expected)
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0:
        raise MediaError("ARTE output must be a nonempty regular media file")
    identity = [metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns]
    result = run_probe([
        "-show_streams", "-show_format", "-show_entries",
        "stream=index,codec_type,codec_name,start_time,duration,time_base,sample_rate:stream_tags:stream_disposition:"
        "format=start_time,duration:format_tags", str(path),
    ])
    video, audio, subtitles = check_counts(result, expected, source=source)
    video_duration = duration_from_stream(video[0])
    if video_duration is None:
        video_duration = decimal_value(expected["video"].get("duration"), positive=True)
    if video_duration is None:
        raise MediaError("ARTE video duration is unavailable for per-stream validation")
    result["packet_evidence"] = {}
    for stream, selected in zip([*video, *audio], [expected["video"], *expected["audio"]]):
        result["packet_evidence"][str(stream["index"])] = stream_evidence(path, stream, selected, video_duration)
    for stream in subtitles:
        packets = run_probe([
            "-select_streams", str(stream["index"]), "-read_intervals", "%+#1",
            "-show_packets", "-show_entries", "packet=pts_time,size", str(path),
        ]).get("packets", [])
        present = any(isinstance(packet, dict) and decimal_value(packet.get("size"), positive=True)
                      is not None for packet in packets)
        result["packet_evidence"][str(stream["index"])] = {"count": int(present)}
    if not source:
        prepared = read_subtitle_reference(reference, expected)
        parser = subtitle_parser() if subtitles else None
        result["subtitle_cues"] = {}
        if subtitles:
            if any(stream.get("codec_name") != "subrip" for stream in subtitles):
                raise MediaError("ARTE final subtitle is not the verified SubRip stream")
            # Read a feature-length container once for all subtitles. The input
            # size budgets a conservative local scan without a short-clip-only
            # deadline; output files remain bounded by the kernel and parser.
            extraction_timeout = min(1800, max(60, 60 + metadata.st_size // (4 * 1024 * 1024)))
            with tempfile.TemporaryDirectory(prefix=".arte-cues-", dir=reference.parent) as directory:
                outputs = [Path(directory) / f"{index}.srt" for index in range(len(subtitles))]
                arguments = ["-nostdin", "-y", "-copyts", "-i", str(path)]
                for index, output in enumerate(outputs):
                    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    os.close(descriptor)
                    arguments.extend(["-map", f"0:s:{index}", "-c:s", "copy", "-f", "srt", str(output)])
                run_media_tool("ffmpeg", arguments, timeout=extraction_timeout, output_file_limit=MAX_SUBTITLE_BYTES,
                               watched_outputs=outputs)
                total = 0
                for output, track in zip(outputs, prepared["tracks"]):
                    descriptor = os.open(output, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(descriptor, "rb") as handle:
                        observed = os.fstat(handle.fileno())
                        if (not stat.S_ISREG(observed.st_mode) or observed.st_uid != os.geteuid()
                                or stat.S_IMODE(observed.st_mode) & 0o077 or observed.st_size > MAX_SUBTITLE_BYTES):
                            raise MediaError("ARTE extracted subtitle is not a bounded private file")
                        payload = handle.read(MAX_SUBTITLE_BYTES + 1)
                    total += len(payload)
                    if len(payload) > MAX_SUBTITLE_BYTES or total > 64 * 1024 * 1024:
                        raise MediaError("ARTE extracted subtitles exceed the size limit")
                    result["subtitle_cues"][track["id"]] = parse_subtitle_cues(parser, payload)
    observed = path.lstat()
    if identity != [observed.st_dev, observed.st_ino, observed.st_size, observed.st_mtime_ns]:
        raise MediaError("ARTE output changed during validation")
    result["media_identity"] = identity
    return result


def validate_media(probe: dict, expected: dict, plan: dict, *, source: bool = False,
                   baseline: dict | None = None, reference: Path | None = None,
                   components: dict | None = None) -> None:
    validate_provenance(plan, expected)
    video, audio, subtitles = check_counts(probe, expected, source=source)
    evidence = probe.get("packet_evidence")
    if not isinstance(evidence, dict):
        raise MediaError("ARTE output has no per-stream packet evidence")
    if components is not None:
        validate_component_records(components, expected, plan)
        original_video, original_audio, _ = check_counts(components, expected, source=True)
        compare_clocks([*video, *audio], evidence, [*original_video, *original_audio], components["packet_evidence"])
    video_duration = decimal_value(evidence.get(str(video[0]["index"]), {}).get("duration"), positive=True)
    if video_duration is None:
        raise MediaError("ARTE output has no usable video duration")
    for stream, selected in zip([*video, *audio], [expected["video"], *expected["audio"]]):
        packet = evidence.get(str(stream["index"]), {})
        if packet.get("tail_complete") is not True:
            raise MediaError("ARTE stream has no complete end-of-stream packet evidence")
        actual = decimal_value(packet.get("duration"), positive=True)
        requested = decimal_value(selected.get("duration"), positive=True) or video_duration
        if actual is None or abs(actual - requested) > tolerance(requested):
            raise MediaError("ARTE video or audio duration differs from its selected source")
        if abs(actual - video_duration) > tolerance(video_duration):
            raise MediaError("ARTE audio and video durations are inconsistent")
        end = decimal_value(packet.get("end"))
        target = decimal_value(packet.get("target"))
        start = decimal_value(stream.get("start_time")) or Decimal(0)
        target_duration = max(actual, requested)
        required_target = start + target_duration - tolerance(target_duration)
        if target != required_target:
            raise MediaError("ARTE packet evidence does not match the requested stream duration")
        if type(packet.get("count")) is not int or packet["count"] <= 0 or end is None or target is None or end < target:
            raise MediaError("ARTE video or audio packets end before the required duration")
    for kind, streams, selected in (("audio", audio, expected["audio"]),
                                    ("subtitle", subtitles, expected["subtitles"])):
        for stream, track in zip(streams, selected):
            disposition = stream.get("disposition") or {}
            if not isinstance(disposition, dict) or disposition.get("hearing_impaired", 0):
                raise MediaError("ARTE output contains an excluded hearing-impaired track")
            tags = stream.get("tags") or {}
            if not isinstance(tags, dict):
                raise MediaError("ARTE output contains invalid track metadata")
            actual_language = tags.get("language")
            if source and actual_language in (None, "und"):
                pass
            elif language(actual_language) != language(track["language"]):
                raise MediaError("ARTE output language differs from the selected source")
            if kind == "subtitle" and evidence.get(str(stream["index"]), {}).get("count", 0) <= 0:
                raise MediaError("ARTE selected subtitle contains no packets")
            if source:
                continue
            if tags.get("title") != track["title"]:
                raise MediaError("ARTE output track title differs from the selection")
            if disposition.get("default", 0) != int(track["default"]):
                raise MediaError("ARTE output default track disposition differs from the selection")
            forced = track.get("forced", False)
            if disposition.get("forced", 0) != int(forced):
                raise MediaError("ARTE output forced subtitle disposition differs from the selection")
            if disposition.get("visual_impaired", 0) != int(track["role"] == "description"):
                raise MediaError("ARTE audio-description disposition differs from the selection")
    if not source:
        prepared = read_subtitle_reference(reference, expected)
        cues = probe.get("subtitle_cues") or {}
        if set(cues) != {track["id"] for track in prepared["tracks"]}:
            raise MediaError("ARTE final subtitle reference inventory changed")
        for track in prepared["tracks"]:
            if not cues.get(track["id"]) or cues[track["id"]] != track["cues"]:
                raise MediaError("ARTE final subtitle cues differ in count, text or exact millisecond timing")
        if baseline is not None:
            source_video, source_audio, _ = check_counts(baseline, expected, source=True)
            source_evidence = baseline.get("packet_evidence") or {}
            compare_clocks([*video, *audio], evidence, [*source_video, *source_audio], source_evidence)
        if (video[0].get("disposition") or {}).get("default", 0) != 1:
            raise MediaError("ARTE output video default disposition is invalid")
        format_tags = (probe.get("format") or {}).get("tags") or {}
        if not isinstance(format_tags, dict) or set(key.lower() for key in format_tags) - {"encoder"}:
            raise MediaError("ARTE output retains unexpected extraction metadata")
        for stream in [*video, *audio, *subtitles]:
            tags = stream.get("tags") or {}
            if set(key.lower() for key in tags) - {"language", "title", "duration", "encoder"}:
                raise MediaError("ARTE output retains unexpected stream metadata")


def compare_clocks(streams: list[dict], evidence: dict, originals: list[dict], source_evidence: dict) -> None:
    for stream, previous in zip(streams, originals):
        if stream.get("codec_name") != previous.get("codec_name"):
            raise MediaError("ARTE codec changed during the copy-only assembly")
        before = source_evidence.get(str(previous["index"]), {})
        after = evidence.get(str(stream["index"]), {})
        if before.get("tail_complete") is not True or after.get("tail_complete") is not True:
            raise MediaError("ARTE source or output has no complete end-of-stream packet evidence")
        allowance = clock_tolerance(stream, previous)
        old_terminal = before.get("terminal_packet") or {}
        new_terminal = after.get("terminal_packet") or {}
        old_pts, new_pts = decimal_value(old_terminal.get("pts")), decimal_value(new_terminal.get("pts"))
        if old_pts is None or new_pts is None or abs(old_pts - new_pts) > allowance:
            raise MediaError("ARTE terminal packet presentation timestamps changed or are unavailable")
        old_dts, new_dts = decimal_value(old_terminal.get("dts")), decimal_value(new_terminal.get("dts"))
        if old_dts is not None and new_dts is not None and abs(old_dts - new_dts) > allowance:
            raise MediaError("ARTE terminal packet decode timestamps changed")
        for key in ("first_pts_time", "end"):
            left, right = decimal_value(before.get(key)), decimal_value(after.get(key))
            kind = stream.get("codec_type") if stream.get("codec_type") in ("video", "audio") else "media"
            boundary = "beginning" if key == "first_pts_time" else "end"
            if left is None or right is None:
                raise MediaError(f"ARTE {kind} {boundary} timestamp is unavailable")
            if abs(left - right) > allowance:
                if key == "end" and aac_partial_terminal_frame(previous, stream, before, after, allowance):
                    continue
                delta = abs(left - right) * 1000
                difference = f"{delta:.3f}" if delta <= 1000000 else "more than 1000000"
                raise MediaError(f"ARTE {kind} timestamps changed at the {boundary} ({difference} ms difference from the source clock)")
        old = sorted(before.get("head_timestamps") or [], key=lambda item: Decimal(item["pts"]))
        new = sorted(after.get("head_timestamps") or [], key=lambda item: Decimal(item["pts"]))
        if not old or not new:
            raise MediaError("ARTE initial packet clock evidence is unavailable")
        position = 0
        matches = set()
        dts_comparisons = 0
        common_start = max(Decimal(old[0]["pts"]), Decimal(new[0]["pts"]))
        common_end = min(Decimal(old[-1]["pts"]), Decimal(new[-1]["pts"]))
        for packet in new:
            pts = Decimal(packet["pts"])
            while position < len(old) and Decimal(old[position]["pts"]) < pts - allowance:
                position += 1
            if position >= len(old) or abs(Decimal(old[position]["pts"]) - pts) > allowance:
                if common_start + allowance < pts < common_end - allowance:
                    raise MediaError("ARTE presentation timestamps changed within the initial packet window")
                continue
            matches.add(position)
            # Matroska can omit initial DTS for reordered B-frames. Compare
            # known DTS for the same PTS, never the first available DTS values.
            left, right = decimal_value(old[position].get("dts")), decimal_value(packet.get("dts"))
            if left is not None and right is not None:
                dts_comparisons += 1
                if abs(left - right) > allowance:
                    raise MediaError("ARTE decode timestamps changed for corresponding packets")
        if not matches or any(index not in matches and common_start + allowance < Decimal(packet["pts"]) < common_end - allowance
                              for index, packet in enumerate(old)):
            raise MediaError("ARTE source packet timestamps have no complete corresponding window")
        if (any(packet.get("dts") is not None for packet in old)
                and any(packet.get("dts") is not None for packet in new) and dts_comparisons == 0):
            raise MediaError("ARTE known decode timestamps could not be compared")


def aac_partial_terminal_frame(original: dict, current: dict, before: dict, after: dict, allowance: Decimal) -> bool:
    """Recognize an unchanged AAC frame whose final MP4 duration was partial.

    Matroska can infer a full nominal duration for this same encoded frame. A
    second copy can regenerate its DURATION tag from that nominal value. This
    does not prove identical decoder padding/trimming, and is never authority
    to change presentation/decode timestamps or accept a missing final packet.
    """
    if (original.get("codec_name") != "aac" or current.get("codec_name") != "aac"
            or not original.get("sample_rate") or original["sample_rate"] != current.get("sample_rate")):
        return False
    old = before.get("terminal_packet") or {}
    new = after.get("terminal_packet") or {}
    digest = old.get("data_hash")
    if (not isinstance(digest, str) or not digest.startswith("SHA256:") or len(digest) != 71
            or any(character not in "0123456789abcdefABCDEF" for character in digest[7:])
            or digest != new.get("data_hash") or old.get("size") != new.get("size")
            or decimal_value(old.get("size"), positive=True) is None):
        return False
    old_duration = decimal_value(old.get("duration"), positive=True)
    new_duration = decimal_value(new.get("duration"), positive=True)
    nominal = decimal_value(before.get("nominal_packet_duration"), positive=True)
    new_nominal = decimal_value(after.get("nominal_packet_duration"), positive=True)
    old_end, new_end = decimal_value(before.get("end")), decimal_value(after.get("end"))
    old_declared, new_declared = decimal_value(before.get("declared_end")), decimal_value(after.get("declared_end"))
    old_pts, new_pts = decimal_value(old.get("pts")), decimal_value(new.get("pts"))
    old_dts, new_dts = decimal_value(old.get("dts")), decimal_value(new.get("dts"))
    values = (old_duration, new_duration, nominal, new_nominal, old_end, new_end,
              old_declared, new_declared, old_pts, new_pts, old_dts, new_dts)
    if any(value is None for value in values):
        return False
    if (type(before.get("duration_packet_count")) is not int or before["duration_packet_count"] < 3
            or type(after.get("duration_packet_count")) is not int or after["duration_packet_count"] < 3):
        return False
    return (
        old_duration < nominal - allowance
        and abs(old_pts - new_pts) <= allowance
        and abs(old_dts - new_dts) <= allowance
        and abs(nominal - new_nominal) <= allowance
        and abs(new_duration - nominal) <= allowance
        and abs(old_end - (old_pts + old_duration)) <= allowance
        and abs(new_end - (new_pts + new_duration)) <= allowance
        and abs(old_declared - old_end) <= allowance
        and old_declared >= new_pts - allowance
        and old_declared <= new_end + allowance
        and (abs(new_declared - old_declared) <= allowance or abs(new_declared - new_end) <= allowance)
    )


def clock_tolerance(current: dict, original: dict) -> Decimal:
    ticks = []
    for stream in (current, original):
        value = stream.get("time_base")
        fields = value.split("/") if isinstance(value, str) else []
        if len(fields) != 2 or any(not part.isdigit() or len(part) > 12 for part in fields):
            raise MediaError("ARTE stream time base is unavailable")
        numerator, denominator = map(Decimal, fields)
        if numerator <= 0 or denominator <= 0 or numerator / denominator > Decimal("0.001"):
            raise MediaError("ARTE stream time base is too coarse for millisecond verification")
        ticks.append(numerator / denominator)
    # Endpoint calculation can quantize PTS and packet duration separately.
    # One tick of the coarser clock bounds their combined rounding error.
    return max(ticks)


def main() -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Validate private ARTE media assembly")
    commands = parser.add_subparsers(dest="command", required=True)
    options = commands.add_parser("remux-arguments")
    options.add_argument("--expected", type=Path, required=True)
    options.add_argument("--plan", type=Path, required=True)
    options.add_argument("--reference", type=Path)
    probe = commands.add_parser("probe")
    probe.add_argument("--expected", type=Path, required=True)
    probe.add_argument("--input", type=Path, required=True)
    probe.add_argument("--output", type=Path, required=True)
    probe.add_argument("--source", action="store_true")
    probe.add_argument("--reference", type=Path)
    validate = commands.add_parser("validate")
    validate.add_argument("--expected", type=Path, required=True)
    validate.add_argument("--plan", type=Path, required=True)
    validate.add_argument("--probe", type=Path, required=True)
    validate.add_argument("--source", action="store_true")
    validate.add_argument("--baseline", type=Path)
    validate.add_argument("--reference", type=Path)
    validate.add_argument("--components", type=Path)
    components = commands.add_parser("probe-components")
    components.add_argument("--expected", type=Path, required=True)
    components.add_argument("--plan", type=Path, required=True)
    components.add_argument("--output", type=Path, required=True)
    cleanup = commands.add_parser("cleanup-components")
    cleanup.add_argument("--expected", type=Path, required=True)
    cleanup.add_argument("--plan", type=Path, required=True)
    cleanup.add_argument("--records", type=Path, required=True)
    args = parser.parse_args()
    try:
        expected = read_private_json(args.expected)
        if args.command == "probe-components":
            write_private_json(args.output, probe_components(read_private_json(args.plan), expected))
        elif args.command == "cleanup-components":
            cleanup_components(read_private_json(args.records), expected, read_private_json(args.plan))
        elif args.command == "probe":
            write_private_json(args.output, probe_media(args.input, expected, source=args.source, reference=args.reference))
        elif args.command == "remux-arguments":
            arguments = remux_arguments(expected, read_private_json(args.plan), args.reference)
            sys.stdout.buffer.write(b"\0".join(argument.encode() for argument in arguments) + b"\0")
        else:
            validate_media(read_private_json(args.probe), expected, read_private_json(args.plan), source=args.source,
                           baseline=read_private_json(args.baseline) if args.baseline else None, reference=args.reference,
                           components=read_private_json(args.components) if args.components else None)
    except (MediaError, OSError, ValueError, RecursionError, KeyError, TypeError, AttributeError, IndexError) as exc:
        message = str(exc) if isinstance(exc, MediaError) else "ARTE media validation could not read valid private data"
        print(f"Error [ARTE_MEDIA]: {message}.", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
