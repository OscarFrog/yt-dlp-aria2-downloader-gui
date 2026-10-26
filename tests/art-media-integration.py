# SPDX-License-Identifier: MIT
"""yt-dlp-aria2-downloader-gui: tests/art-media-integration.py.

Exercise ARTE stream validation and opt-in real native HLS assembly through the
production engine. All network media are synthetic and served on loopback.
"""

from __future__ import annotations

import copy
import functools
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("art_media", PROJECT / "private-art-media.py")
MEDIA = importlib.util.module_from_spec(spec)
spec.loader.exec_module(MEDIA)
track_spec = importlib.util.spec_from_file_location("art_tracks_media_test", PROJECT / "private-art-tracks.py")
TRACKS = importlib.util.module_from_spec(track_spec)
track_spec.loader.exec_module(TRACKS)
REAL_TOOLS = "--real-tools" in sys.argv
if REAL_TOOLS:
    sys.argv.remove("--real-tools")


def expected_fixture() -> dict:
    return {
        "version": 1, "policy": MEDIA.POLICY,
        "video": {"format_id": "video", "duration": 20},
        "audio": [{"id": "ja", "format_id": "audio-日本語", "language": "ja", "role": "main",
                   "title": "Japanese original", "default": True, "duration": 20}],
        "subtitles": [{"id": "fr", "language": "fr", "role": "full",
                       "title": "French full", "default": True, "forced": False}],
    }


def probe_fixture() -> dict:
    return {
        "streams": [
            {"index": 0, "codec_type": "video", "disposition": {"default": 1}},
            {"index": 1, "codec_type": "audio", "tags": {"language": "jpn", "title": "Japanese original"},
             "disposition": {"default": 1}},
            {"index": 2, "codec_type": "subtitle", "tags": {"language": "fra", "title": "French full"},
             "disposition": {"default": 1, "forced": 0}},
        ],
        "format": {"duration": "200", "tags": {"ENCODER": "Lavf"}},
        "packet_evidence": {
            "0": {"duration": "20", "start": "0", "target": "19", "end": "20", "count": 10, "tail_complete": True},
            "1": {"duration": "20", "start": "0", "target": "19", "end": "20", "count": 10, "tail_complete": True},
            "2": {"count": 1},
        },
        "subtitle_cues": {"fr": [{"start_ms": 1080, "end_ms": 2000, "text": "Complete dialogue"}]},
    }


def aac_declared_end_matches_packets(before: dict, after: dict, packet_pts: list[MEDIA.Decimal], allowance: MEDIA.Decimal) -> bool:
    end = MEDIA.Decimal(after["end"])
    candidates = [MEDIA.Decimal(before["declared_end"]), end]
    # With preserved partial frames, a muxer may describe the packet span,
    # including negative AAC priming, instead of the final presentation time.
    # This interpretation requires observed packets and never widens the clock
    # allowance or the separate nominal-duration exception.
    if packet_pts and min(packet_pts) < 0 and abs(end - MEDIA.Decimal(before["end"])) <= allowance:
        candidates.append(end - min(packet_pts))
    declared = MEDIA.Decimal(after["declared_end"])
    return any(abs(declared - candidate) <= allowance for candidate in candidates)


class MediaValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        # Provenance is exercised through the real catalogue in the end-to-end
        # qualification. These controls isolate final media validation decisions.
        self.patch = mock.patch.object(MEDIA, "validate_provenance", lambda plan, expected: MEDIA.checked_expected(expected))
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.reference_patch = mock.patch.object(MEDIA, "read_subtitle_reference", lambda path, expected: {
            "tracks": [{"id": track["id"], "path": "/private/" + track["id"] + ".srt",
                        "cues": [{"start_ms": 1080, "end_ms": 2000, "text": "Complete dialogue"}]}
                       for track in expected["subtitles"]]})
        self.reference_patch.start()
        self.addCleanup(self.reference_patch.stop)
        self.expected = expected_fixture()
        self.probe = probe_fixture()

    def test_complete_selected_streams_accept_long_subtitle_container(self) -> None:
        MEDIA.validate_media(self.probe, self.expected, {})

    def test_each_audio_tail_is_required(self) -> None:
        self.expected["audio"].append(dict(self.expected["audio"][0], id="fr", default=False, language="fr"))
        self.probe["streams"].insert(2, {"index": 3, "codec_type": "audio", "tags": {"language": "fra"}})
        self.probe["streams"].pop()
        self.probe["packet_evidence"]["3"] = dict(self.probe["packet_evidence"]["1"], end="2")
        with self.assertRaisesRegex(MEDIA.MediaError, "packets end"):
            MEDIA.validate_media(self.probe, self.expected, {}, source=True)

    def test_video_truncation_is_not_masked_by_subtitle_duration(self) -> None:
        self.probe["packet_evidence"]["0"]["end"] = "2"
        with self.assertRaisesRegex(MEDIA.MediaError, "packets end"):
            MEDIA.validate_media(self.probe, self.expected, {})

    def test_audio_duration_must_match_selected_source(self) -> None:
        self.probe["packet_evidence"]["1"]["duration"] = "4"
        with self.assertRaisesRegex(MEDIA.MediaError, "duration differs"):
            MEDIA.validate_media(self.probe, self.expected, {})

    def test_track_count_prevents_silent_loss_and_extra_streams(self) -> None:
        self.probe["streams"].pop()
        with self.assertRaisesRegex(MEDIA.MediaError, "track count"):
            MEDIA.validate_media(self.probe, self.expected, {})

    def test_language_default_forced_and_title_are_checked(self) -> None:
        for field, value in (("language", "deu"), ("title", "wrong")):
            with self.subTest(field=field):
                candidate = copy.deepcopy(self.probe)
                candidate["streams"][2]["tags"][field] = value
                with self.assertRaises(MEDIA.MediaError):
                    MEDIA.validate_media(candidate, self.expected, {})
        for field in ("default", "forced"):
            with self.subTest(field=field):
                candidate = copy.deepcopy(self.probe)
                candidate["streams"][2]["disposition"][field] ^= 1
                with self.assertRaises(MEDIA.MediaError):
                    MEDIA.validate_media(candidate, self.expected, {})

    def test_source_language_mismatch_cannot_be_relabelled(self) -> None:
        self.probe["streams"][1]["tags"]["language"] = "deu"
        self.probe["streams"].pop()
        with self.assertRaisesRegex(MEDIA.MediaError, "language differs"):
            MEDIA.validate_media(self.probe, self.expected, {}, source=True)

    def test_excluded_role_and_hearing_disposition_are_rejected(self) -> None:
        self.expected["audio"][0]["role"] = "hearing_impaired"
        with self.assertRaisesRegex(MEDIA.MediaError, "excluded"):
            MEDIA.validate_media(self.probe, self.expected, {})
        self.expected["audio"][0]["role"] = "main"
        self.probe["streams"][2]["disposition"]["hearing_impaired"] = 1
        with self.assertRaisesRegex(MEDIA.MediaError, "excluded"):
            MEDIA.validate_media(self.probe, self.expected, {})

    def test_description_is_a_distinct_allowed_audio_role(self) -> None:
        self.expected["audio"][0]["role"] = "description"
        self.probe["streams"][1]["disposition"]["visual_impaired"] = 1
        MEDIA.validate_media(self.probe, self.expected, {})
        arguments = MEDIA.remux_arguments(self.expected, {})
        self.assertIn("default+visual_impaired", arguments)

    def test_empty_subtitle_and_extraction_metadata_are_rejected(self) -> None:
        self.probe["packet_evidence"]["2"]["count"] = 0
        with self.assertRaisesRegex(MEDIA.MediaError, "no packets"):
            MEDIA.validate_media(self.probe, self.expected, {})
        self.probe["packet_evidence"]["2"]["count"] = 1
        self.probe["format"]["tags"]["comment"] = "private metadata must disappear"
        with self.assertRaisesRegex(MEDIA.MediaError, "extraction metadata"):
            MEDIA.validate_media(self.probe, self.expected, {})

    def test_remux_copies_every_stream_and_strips_metadata(self) -> None:
        arguments = MEDIA.remux_arguments(self.expected, {})
        self.assertEqual(arguments[:3], ["-copyts", "-i", "/private/fr.srt"])
        self.assertEqual(arguments[arguments.index("-c") + 1], "copy")
        self.assertIn("-map_metadata:s", arguments)
        self.assertIn("language=jpn", arguments)
        self.assertIn("language=fra", arguments)
        self.assertNotIn("-vf", arguments)

    def test_subtitle_final_cues_require_exact_count_text_and_milliseconds(self) -> None:
        for change in ("missing", "empty", "text", "start", "end"):
            with self.subTest(change=change):
                probe = copy.deepcopy(self.probe)
                cue = probe["subtitle_cues"]["fr"][0]
                if change in ("missing", "empty"):
                    probe["subtitle_cues"]["fr"] = []
                elif change == "text":
                    cue["text"] = "wrong dialogue"
                else:
                    cue[change + "_ms"] += 1
                with self.assertRaisesRegex(MEDIA.MediaError, "subtitle cues"):
                    MEDIA.validate_media(probe, self.expected, {})

    def test_nonzero_matroska_duration_tag_is_an_endpoint(self) -> None:
        stream = {"start_time": "5.020", "tags": {"DURATION": "00:00:09.052000000"}}
        self.assertEqual(MEDIA.duration_from_stream(stream), MEDIA.Decimal("4.032"))

    def test_original_packet_clock_cannot_be_rebased_or_stretched(self) -> None:
        stream = {"index": 0, "codec_name": "aac", "time_base": "1/1000"}
        evidence = {"0": {"first_pts_time": "5.020", "first_dts_time": "5.020", "end": "9.052", "tail_complete": True,
                           "terminal_packet": {"pts": "9.031", "dts": "9.031"},
                           "head_timestamps": [{"pts": "5.020", "dts": "5.020"}]}}
        MEDIA.compare_clocks([stream], evidence, [stream], copy.deepcopy(evidence))
        for key in ("first_pts_time", "end"):
            altered = copy.deepcopy(evidence)
            altered["0"][key] = str(MEDIA.Decimal(altered["0"][key]) - MEDIA.Decimal("0.020"))
            with self.assertRaisesRegex(MEDIA.MediaError, "timestamps changed"):
                MEDIA.compare_clocks([stream], altered, [stream], evidence)
        altered = copy.deepcopy(evidence)
        altered["0"]["head_timestamps"][0]["dts"] = "5.000"
        with self.assertRaisesRegex(MEDIA.MediaError, "decode timestamps"):
            MEDIA.compare_clocks([stream], altered, [stream], evidence)

    def test_b_frames_compare_dts_for_corresponding_pts(self) -> None:
        current = {"index": 0, "codec_name": "h264", "time_base": "1/1000"}
        original = dict(current, time_base="1/90000")
        before = {"0": {"first_pts_time": "5", "first_dts_time": "4.92", "end": "9", "tail_complete": True,
                        "terminal_packet": {"pts": "8.96", "dts": "8.88"},
                        "head_timestamps": [{"pts": "5.00", "dts": "4.92"},
                                            {"pts": "5.04", "dts": "4.96"},
                                            {"pts": "5.08", "dts": "5.00"}]}}
        after = copy.deepcopy(before)
        after["0"]["first_dts_time"] = "5"
        after["0"]["head_timestamps"][0]["dts"] = None
        after["0"]["head_timestamps"][1]["dts"] = None
        MEDIA.compare_clocks([current], after, [original], before)
        after["0"]["head_timestamps"][2]["dts"] = "5.08"
        with self.assertRaisesRegex(MEDIA.MediaError, "decode timestamps"):
            MEDIA.compare_clocks([current], after, [original], before)

    def test_incomplete_tail_observation_cannot_prove_eof(self) -> None:
        self.probe["packet_evidence"]["0"]["tail_complete"] = False
        with self.assertRaisesRegex(MEDIA.MediaError, "end-of-stream"):
            MEDIA.validate_media(self.probe, self.expected, {})

    def test_clock_error_identifies_stream_boundary_without_private_data(self) -> None:
        stream = {"index": 0, "codec_type": "audio", "codec_name": "aac", "time_base": "1/1000"}
        before = {"0": {"first_pts_time": "5", "end": "96", "tail_complete": True,
                        "terminal_packet": {"pts": "95.98", "dts": "95.98"}}}
        after = {"0": dict(before["0"], end="84.7")}
        with self.assertRaisesRegex(MEDIA.MediaError, "ARTE audio timestamps changed at the end \\(11300.000 ms"):
            MEDIA.compare_clocks([stream], after, [stream], before)

    def test_aac_partial_terminal_frame_requires_identity_and_bounded_duration(self) -> None:
        original = {"index": 0, "codec_type": "audio", "codec_name": "aac", "sample_rate": "44100", "time_base": "1/44100"}
        current = dict(original, time_base="1/1000")
        digest = "SHA256:" + "a" * 64
        before = {"0": {"first_pts_time": "0", "end": "1", "tail_complete": True,
                        "declared_end": "1", "nominal_packet_duration": "0.023220", "duration_packet_count": 40,
                        "head_timestamps": [{"pts": "0", "dts": "0"}],
                        "terminal_packet": {"pts": "0.998458", "dts": "0.998458", "duration": "0.001542",
                                            "size": "50", "data_hash": digest}}}
        after = copy.deepcopy(before)
        after["0"].update(end="1.021", nominal_packet_duration="0.023")
        after["0"]["terminal_packet"].update(pts="0.998", dts="0.998", duration="0.023")
        for declared_end in ("1", "1.021"):
            after["0"]["declared_end"] = declared_end
            self.assertTrue(MEDIA.aac_partial_terminal_frame(original, current, before["0"], after["0"],
                                                            MEDIA.clock_tolerance(current, original)))
            MEDIA.compare_clocks([current], after, [original], before)
        for field, value in (("pts", "1.000458"), ("dts", "1.000458"), ("dts", None), ("size", "49"),
                             ("data_hash", "SHA256:" + "b" * 64), ("duration", "1")):
            candidate = copy.deepcopy(after)
            candidate["0"]["terminal_packet"][field] = value
            with self.subTest(field=field), self.assertRaises(MEDIA.MediaError):
                MEDIA.compare_clocks([current], candidate, [original], before)
        candidate = copy.deepcopy(after)
        candidate["0"]["declared_end"] = "1.010"
        with self.assertRaisesRegex(MEDIA.MediaError, "at the end"):
            MEDIA.compare_clocks([current], candidate, [original], before)
        with self.assertRaises(MEDIA.MediaError):
            MEDIA.compare_clocks([dict(current, sample_rate="48000")], after, [original], before)

    def test_aac_partial_terminal_duration_can_remain_unchanged(self) -> None:
        original = {"index": 0, "codec_type": "audio", "codec_name": "aac", "sample_rate": "44100", "time_base": "1/44100"}
        current = dict(original, time_base="1/1000")
        before = {"0": {"first_pts_time": "0", "end": "1", "tail_complete": True,
                        "declared_end": "1", "nominal_packet_duration": "0.023220", "duration_packet_count": 40,
                        "head_timestamps": [{"pts": "0", "dts": "0"}],
                        "terminal_packet": {"pts": "0.998458", "dts": "0.998458", "duration": "0.001542",
                                            "size": "50", "data_hash": "SHA256:" + "a" * 64}}}
        after = copy.deepcopy(before)
        after["0"].update(nominal_packet_duration="0.023")
        after["0"]["terminal_packet"].update(pts="0.998", dts="0.998", duration="0.002")
        self.assertFalse(MEDIA.aac_partial_terminal_frame(original, current, before["0"], after["0"],
                                                         MEDIA.clock_tolerance(current, original)))
        # Exact preservation already satisfies the clock contract; recognizing
        # a nominal-duration replacement must not be a prerequisite for it.
        with mock.patch.object(MEDIA, "aac_partial_terminal_frame", side_effect=AssertionError("Unexpected AAC exception")):
            MEDIA.compare_clocks([current], after, [original], before)
        for field, value in (("pts", "1.000458"), ("dts", "1.000458")):
            candidate = copy.deepcopy(after)
            candidate["0"]["terminal_packet"][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(MEDIA.MediaError, "terminal packet"):
                MEDIA.compare_clocks([current], candidate, [original], before)

    def test_aac_duration_tag_can_describe_the_preserved_packet_span(self) -> None:
        before = {"end": "1", "declared_end": "1"}
        after = {"end": "1", "declared_end": "1.023"}
        timestamps = [MEDIA.Decimal("-0.023"), MEDIA.Decimal("0.998")]
        allowance = MEDIA.Decimal("0.001")
        for declared_end in ("1", "1.023"):
            self.assertTrue(aac_declared_end_matches_packets(before, dict(after, declared_end=declared_end), timestamps, allowance))
        for declared_end in ("1.010", "1.025", "2"):
            self.assertFalse(aac_declared_end_matches_packets(before, dict(after, declared_end=declared_end), timestamps, allowance))
        self.assertFalse(aac_declared_end_matches_packets(before, after, [], allowance))
        self.assertFalse(aac_declared_end_matches_packets(before, after, [MEDIA.Decimal("0"), timestamps[1]], allowance))
        # The nominal-frame exception permits only its original or new end;
        # a changed packet end cannot borrow the preserved-frame span rule.
        normalized = dict(after, end="1.021", declared_end="1.044")
        self.assertFalse(aac_declared_end_matches_packets(before, normalized, timestamps, allowance))
        for declared_end in ("1", "1.021"):
            self.assertTrue(aac_declared_end_matches_packets(before, dict(normalized, declared_end=declared_end), timestamps, allowance))

    def test_private_json_refuses_symlinks_and_public_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data.json"
            data.write_text("{}")
            data.chmod(0o644)
            with self.assertRaises(MEDIA.MediaError):
                MEDIA.read_private_json(data)
            data.chmod(0o600)
            self.assertEqual(MEDIA.read_private_json(data), {})
            alias = root / "alias.json"
            alias.symlink_to(data)
            with self.assertRaises(OSError):
                MEDIA.read_private_json(alias)
            fifo = root / "fifo"
            os.mkfifo(fifo, 0o600)
            with self.assertRaises(MEDIA.MediaError):
                MEDIA.read_private_json(fifo)

    def test_component_cleanup_preserves_replaced_or_symbolic_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = [root / "video.mp4", root / "audio-日本語.mp4"]
            parent = root.stat()
            records = {"files": []}
            for path in paths:
                path.write_bytes(b"owned component")
                records["files"].append({"identity": MEDIA.file_identity(path.stat()),
                                          "parent_identity": [parent.st_dev, parent.st_ino]})
            paths[1].unlink()
            paths[1].symlink_to(paths[0])
            with mock.patch.object(MEDIA, "validate_component_records", return_value=paths):
                with self.assertRaisesRegex(MEDIA.MediaError, "identity changed"):
                    MEDIA.cleanup_components(records, self.expected, {})
            self.assertTrue(paths[0].is_file())
            self.assertTrue(paths[1].is_symlink())

    def test_component_cleanup_removes_only_the_bound_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selected = root / "video.mp4"
            external = root / "unrelated.txt"
            selected.write_bytes(b"owned component")
            external.write_text("preserve")
            parent = root.stat()
            records = {"files": [{"identity": MEDIA.file_identity(selected.stat()),
                                    "parent_identity": [parent.st_dev, parent.st_ino]}]}
            with mock.patch.object(MEDIA, "validate_component_records", return_value=[selected]):
                MEDIA.cleanup_components(records, self.expected, {})
            self.assertFalse(selected.exists())
            self.assertEqual(external.read_text(), "preserve")

    def test_no_subtitles_skips_workspace_acquisition_and_reference_builder(self) -> None:
        source = (PROJECT / "download-video.sh").read_text().rsplit('\nmain "$@"', 1)[0]
        program = r'''
PRIVATE_ARIA2_METADATA=$1/metadata
PRIVATE_ARIA2_PLAN=plan
OUTPUT_DIR=$1/output
FINAL_OUTPUT_DIR=$1/output
FINAL_OUTPUT_IDENTITY=identity
RESOURCE_STATE_FILE=ownership
MODE=video
ARTE_EXPECTATION=expected
ARTE_TRACKS_HELPER=tracks
PRIVATE_ARIA2_HELPER=resource
MACHINE_PROGRESS=true
python3() {
    case "$1 $2" in
        'tracks check-replay' | 'resource check-native-final' | 'tracks subtitle-languages') return 0 ;;
        *) return 99 ;;
    esac
}
mkdir() { exit 98; }
run_supervised_ytdlp() { exit 97; }
run_supervised_command() { exit 96; }
prepare_arte_subtitles
[[ -z ${ARTE_SUBTITLE_REFERENCE} && ! -e ${PRIVATE_ARIA2_METADATA} ]]
'''
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["bash", "-s", "--", directory], input=source + program,
                                    text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_track_cli_modes_are_independent_and_reject_conflicting_intent(self) -> None:
        source = (PROJECT / "download-video.sh").read_text().rsplit('\nmain "$@"', 1)[0]
        program = r'''
parse_arguments "$@"
URL_HOST=arte.tv
validate_mode_selection
printf '%s|%s|%s\n' "${ARTE_PRESET}" "${ARTE_NO_SUBTITLES}" "${ARTE_ENABLED}"
'''
        cases = [
            (["--tracks-auto"], 0, "auto|false|true"),
            (["--no-subtitles"], 0, "auto|true|true"),
            (["--all-tracks", "--no-subtitles"], 0, "all|true|true"),
            (["--no-subtitles", "--all-tracks"], 0, "all|true|true"),
            (["--arte-all"], 0, "all|false|true"),
            (["--arte-original-fr"], 0, "original-fr|false|true"),
            (["--no-subtitles", "--arte-original-fr"], 64, ""),
            (["--tracks-auto", "--all-tracks"], 64, ""),
            (["--no-subtitles", "--track-selection", "selection.json"], 64, ""),
            (["--mode", "audio", "--no-subtitles"], 64, ""),
            (["--mode", "audio"], 0, "|false|false"),
            ([], 0, "|false|false"),
        ]
        for arguments, status, output in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run(["bash", "-s", "--", *arguments, "https://www.arte.tv/video"],
                                        input=source + program, text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(result.stdout.strip(), output)


def command(arguments: list[str], *, timeout: int = 30, **kwargs) -> subprocess.CompletedProcess:
    completed = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=timeout, **kwargs)
    if completed.returncode:
        raise AssertionError(f"Local media tool failed ({completed.returncode}): "
                             + completed.stderr.decode(errors="replace")[-4000:])
    return completed


class RequestHandler(SimpleHTTPRequestHandler):
    requests: list[str] = []
    request_hosts: list[str] = []

    def log_message(self, _format: str, *args: object) -> None:
        pass

    def do_GET(self) -> None:
        self.requests.append(self.path)
        self.request_hosts.append(self.headers.get("Host", ""))
        super().do_GET()


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    path.chmod(0o600)


def create_hls_fixture(web: Path, base: str, *, duration: int = 4, gop: int = 10) -> dict:
    video = web / "video"
    video.mkdir()
    command(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi",
             "-i", f"testsrc=size=160x90:rate=10:duration={duration}", "-an", "-c:v", "libx264",
             "-pix_fmt", "yuv420p", "-preset", "ultrafast", "-g", str(gop), "-bf", "3", "-sc_threshold", "0",
             "-output_ts_offset", "5", "-muxdelay", "0", "-f", "hls",
             "-hls_time", "1", "-hls_playlist_type", "vod", str(video / "index.m3u8")])
    formats = []
    renditions = []
    for number, (lang, name, role) in enumerate((
            ("ja", "japonais (VO)", "main"), ("fr", "français", "main"),
            ("de", "allemand", "main"), ("de", "Deutsch confort audio", "hearing_impaired"))):
        stem = "comfort" if role != "main" else lang
        audio = web / stem
        audio.mkdir()
        command(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi",
                 "-i", f"sine=frequency={440 + 110 * number}:sample_rate=48000:duration={duration}",
                 "-vn", "-c:a", "aac", "-b:a", "64k", "-output_ts_offset",
                 f"{5 + 0.02 * (number + 1) + 1024 / 48000:.9f}", "-muxdelay", "0",
                 "-f", "hls", "-hls_time", "1",
                 "-hls_playlist_type", "vod", str(audio / "index.m3u8")])
        attributes = (',CHARACTERISTICS="public.accessibility.describes-music-and-sound"'
                      if role != "main" else "")
        renditions.append(f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="{name}",LANGUAGE="{lang}",'
                          f'AUTOSELECT=YES,DEFAULT={"YES" if lang == "ja" else "NO"},URI="{stem}/index.m3u8"{attributes}')
        formats.append({
            "format_id": "VF-STF-audio_0-japonais__VO_" if lang == "ja" else f"VF-STF-audio_{number}-{name.replace(' ', '_')}",
            "url": base + f"/{stem}/index.m3u8", "manifest_url": base + "/master.m3u8",
            "protocol": "m3u8_native", "ext": "mp4", "vcodec": "none", "acodec": "mp4a.40.2",
            "language": lang, "format_note": "Français [VF]", "abr": 64,
            "audio_channels": 1, "duration": duration,
        })
    subtitles: dict[str, list[dict]] = {}
    for stem, lang, name, forced, raw_key, text in (
            ("fr", "fr", "Français", False, "fr", "FRENCH COMPLETE DIALOGUE"),
            ("fr-forced", "fr", "Français forcés", True, "fr-forced", "FRENCH FORCED SIGN"),
            ("de", "de", "Deutsch", False, "de", "GERMAN COMPLETE DIALOGUE"),
            ("de-forced", "de", "Deutsch erzwungen", True, "de-forced", "GERMAN FORCED SIGN"),
            ("program_st_VA-MAL_fixture", "de", "Deutsch Hoerbehinderte", False, "de-forced", "EXCLUDED SDH SOUNDS"),
            ("ja-alias", "ja", "VO (Forced)", True, "ja-forced", "FRENCH COMPLETE DIALOGUE")):
        (web / f"{stem}.vtt").write_text(
            "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:450000\n\n"
            "STYLE\n::cue(.unused) { color: #ffffff; }\n\n"
            "first-cue\n00:01.080 --> 00:02.000\n<i>" + text + " &amp; café</i>\nSecond line\n\n"
            "last-cue\n00:03.000 --> 00:03.800\n" + text + " END\n",
            encoding="utf-8")
        (web / f"{stem}.m3u8").write_text(
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n"
            f"#EXTINF:4.0,\n{stem}.vtt\n#EXT-X-ENDLIST\n", encoding="utf-8")
        characteristics = "public.accessibility.describes-music-and-sound" if "MAL" in stem else "public.accessibility.transcribes-spoken-dialog"
        if stem in ("fr", "ja-alias"):
            # The raw alias contradicts its LANGUAGE attribute. Discovery must
            # withhold it without acquiring its payload, including for None.
            characteristics += ",tv.arte.subtitle.version.vo-fra"
        # Match the observed ambiguity: the same resource path on a second
        # origin is only a candidate until both complete VTT contents agree.
        resource = base.replace("127.0.0.1", "localhost") + "/fr.m3u8" if stem == "ja-alias" else base + f"/{stem}.m3u8"
        renditions.append(f'#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="{name}",LANGUAGE="{lang}",'
                          f'FORCED={"YES" if forced else "NO"},AUTOSELECT=YES,CHARACTERISTICS="{characteristics}",URI="{resource}"')
        subtitles.setdefault(raw_key, []).append({"url": resource, "ext": "vtt",
                                                 "protocol": "m3u8_native", "name": name})
    (web / "master.m3u8").write_text("#EXTM3U\n" + "\n".join(renditions)
                                    + '\n#EXT-X-STREAM-INF:BANDWIDTH=250000,RESOLUTION=160x90,CODECS="avc1.42c00b,mp4a.40.2",AUDIO="audio",SUBTITLES="subs"\nvideo/index.m3u8\n', encoding="utf-8")
    formats.append({"format_id": "VF-STF-vidéo", "url": base + "/video/index.m3u8",
                    "manifest_url": base + "/master.m3u8", "protocol": "m3u8_native", "ext": "mp4",
                    "vcodec": "avc1.42c00b", "acodec": "none", "height": 90, "width": 160,
                    "tbr": 250, "duration": duration})
    return {"id": "133131-synthetic", "title": "ARTE synthétique 日本語", "extractor": "ArteTV",
            "extractor_key": "ArteTV", "webpage_url": "https://www.arte.tv/fr/videos/133131-synthetic/",
            "duration": duration, "formats": formats, "subtitles": subtitles,
            "description": "PRIVATE EXTRACTION METADATA MUST NOT REACH MKV"}


def capture_engine(arguments: list[str], environment: dict[str, str], root: Path,
                   on_tick=None) -> subprocess.CompletedProcess:
    """Let the engine retire its separately supervised workers before cleanup."""
    preservation = root / "preserve-active-engine"
    preservation.touch(mode=0o600)
    process = None
    requested = None
    previous = {}

    def interrupted(number: int, _frame: object) -> None:
        nonlocal requested
        requested = requested or number

    try:
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.signal(number, interrupted)
        process = subprocess.Popen(arguments, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 90
        while True:
            if requested:
                raise SystemExit(128 + requested)
            if on_tick is not None:
                on_tick()
            try:
                stdout, stderr = process.communicate(timeout=0.2)
            except subprocess.TimeoutExpired:
                if time.monotonic() >= deadline:
                    raise AssertionError("ARTE engine qualification exceeded its deadline")
                continue
            preservation.unlink()
            return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
    finally:
        for number in previous:
            signal.signal(number, signal.SIG_IGN)
        if process is not None and process.poll() is None:
            for _ in range(2):
                process.send_signal(requested or signal.SIGTERM)
                try:
                    process.communicate(timeout=20)
                    preservation.unlink(missing_ok=True)
                    break
                except subprocess.TimeoutExpired:
                    pass
        for number, handler in previous.items():
            signal.signal(number, handler)


if REAL_TOOLS:
    class RealHlsEngineTests(unittest.TestCase):
        @classmethod
        def setUpClass(cls) -> None:
            for name in ("ffmpeg", "ffprobe", "yt-dlp", "aria2c"):
                if shutil.which(name) is None:
                    raise RuntimeError(f"Required ARTE real-media qualification tool is unavailable: {name}")
            cls.root = Path(tempfile.mkdtemp(prefix="arte-media-qualification-"))
            cls.addClassCleanup(cls.cleanup_fixture)
            cls.web = cls.root / "web"
            cls.web.mkdir(mode=0o700)
            cls.server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(RequestHandler, directory=str(cls.web)))
            cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
            cls.thread.start()
            cls.base = f"http://127.0.0.1:{cls.server.server_port}"
            cls.seed = cls.root / "seed.json"
            write_json(cls.seed, create_hls_fixture(cls.web, cls.base))
            shim = cls.root / "yt-dlp-adapter"
            shim.write_text(
                "#!/usr/bin/python3\nimport os, sys\nargs = sys.argv[1:]\n"
                "if '--batch-file' in args:\n"
                "    index = args.index('--batch-file'); del args[index:index + 2]\n"
                "    args += ['--load-info-json', os.environ['ARTE_FIXTURE_SEED']]\n"
                "os.execv(os.environ['ARTE_FIXTURE_REAL_YTDLP'], [os.environ['ARTE_FIXTURE_REAL_YTDLP'], *args])\n", encoding="utf-8")
            shim.chmod(0o700)
            home = cls.root / "home"
            home.mkdir(mode=0o700)
            cls.environment = dict(os.environ, HOME=str(home), XDG_CACHE_HOME=str(home / "cache"),
                                   XDG_CONFIG_HOME=str(home / "config"), XDG_STATE_HOME=str(home / "state"),
                                   YTDLP_ARIA2_SKIP_RUNTIME_UPDATE="1", YTDLP_ARIA2_YTDLP_BIN=str(shim),
                                   ARTE_FIXTURE_SEED=str(cls.seed), ARTE_FIXTURE_REAL_YTDLP=shutil.which("yt-dlp"))

        @classmethod
        def cleanup_fixture(cls) -> None:
            if hasattr(cls, "server"):
                if hasattr(cls, "thread") and cls.thread.is_alive():
                    cls.server.shutdown()
                    cls.thread.join(timeout=5)
                cls.server.server_close()
            if (cls.root / "preserve-active-engine").exists():
                print("ARTE qualification fixtures retained after unconfirmed shutdown: " + str(cls.root), file=sys.stderr)
            else:
                shutil.rmtree(cls.root)

        def run_scenario(self, preset: str, audio_count: int, texts: list[str]) -> Path:
            directory = self.root / preset
            directory.mkdir(mode=0o700)
            result = self.root / f"{preset}.result"
            start_requests = len(RequestHandler.requests)
            selection_arguments = ["--all-tracks" if preset == "all" else "--tracks-auto"]
            on_tick = None
            if preset == "all-none":
                selection_arguments = ["--all-tracks", "--no-subtitles"]
            elif preset == "auto-none":
                selection_arguments = ["--no-subtitles"]
            if preset == "custom-none":
                catalogue = self.root / "custom-none.catalogue.json"
                selection = self.root / "custom-none.selection.json"
                selection_arguments = ["--track-catalog", str(catalogue), "--track-selection", str(selection)]

                def select_without_subtitles() -> None:
                    if not catalogue.exists() or selection.exists():
                        return
                    choices = json.loads(catalogue.read_text())
                    original = next(track["id"] for track in choices["audio"] if track["language"] == "ja")
                    pending = selection.with_suffix(".tmp")
                    write_json(pending, TRACKS.choose(choices, audio_mode="custom", subtitle_mode="none",
                                                     audios=[original]))
                    pending.replace(selection)

                on_tick = select_without_subtitles
            completed = capture_engine([
                "bash", str(PROJECT / "download-video.sh"), "--mode", "video", "--output-dir", str(directory),
                "--result-file", str(result), "--machine-progress", *selection_arguments,
                "https://www.arte.tv/fr/videos/133131-synthetic/"], self.environment, self.root, on_tick)
            self.assertEqual(completed.returncode, 0, (completed.stdout + completed.stderr).decode(errors="replace")[-10000:])
            final = Path(result.read_text().strip())
            self.assertEqual(final.parent, directory)
            self.assertTrue(final.is_file())
            self.assertEqual(list(directory.iterdir()), [final], "Successful assembly left source components in the destination")
            probe = json.loads(command(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(final)]).stdout)
            videos, audios, subtitles = MEDIA.content_streams(probe)
            self.assertEqual((len(videos), len(audios), len(subtitles)), (1, audio_count, len(texts)))
            self.assertEqual(videos[0]["codec_name"], "h264")
            self.assertEqual(MEDIA.Decimal(videos[0]["start_time"]), MEDIA.Decimal("5.000"))
            self.assertTrue(all(stream["codec_name"] == "aac" for stream in audios))
            def encoded_hash(path: Path, mapping: str, *, video: bool = False) -> bytes:
                bitstream = ["-bsf:v", "h264_mp4toannexb"] if video else []
                if not video:
                    payload = command(["ffmpeg", "-v", "error", "-nostdin", "-i", str(path), "-map", mapping,
                                       "-c", "copy", "-f", "adts", "-"]).stdout
                    frames = []
                    position = 0
                    while position < len(payload):
                        header = payload[position:position + 7]
                        self.assertEqual((header[0], header[1] & 0xF0), (0xFF, 0xF0))
                        length = ((header[3] & 3) << 11) | (header[4] << 3) | (header[5] >> 5)
                        header_length = 7 if header[1] & 1 else 9
                        self.assertGreater(length, header_length)
                        self.assertLessEqual(position + length, len(payload))
                        frames.append(payload[position + header_length:position + length])
                        position += length
                    return hashlib.sha256(b"".join(len(frame).to_bytes(4, "big") + frame for frame in frames)).digest()
                payload = command(["ffmpeg", "-v", "error", "-nostdin", "-i", str(path), "-map", mapping,
                                   "-c", "copy", *bitstream, "-f", "h264", "-"]).stdout
                # Annex-B/AVC remuxes change separators and repeat parameter
                # sets; compare the encoded slices and distinct parameters.
                units = [unit for unit in re.split(b"\x00\x00\x00?\x01", payload) if unit]
                slices = [unit for unit in units if unit[0] & 31 in (1, 5)]
                parameters = sorted(set(unit for unit in units if unit[0] & 31 in (7, 8)))
                self.assertTrue(slices and parameters)
                return hashlib.sha256(b"".join(len(unit).to_bytes(4, "big") + unit
                                               for unit in [*parameters, *slices])).digest()

            self.assertEqual(encoded_hash(final, "0:v:0", video=True),
                             encoded_hash(self.web / "video" / "index.m3u8", "0:v:0", video=True),
                             "The video encoded packets changed during assembly")
            frequencies = {"jpn": 440, "fra": 550, "deu": 660}
            for index, stream in enumerate(audios):
                source_language = {"jpn": "ja", "fra": "fr", "deu": "de"}[stream["tags"]["language"]]
                source_probe = json.loads(command(["ffprobe", "-v", "error", "-show_streams", "-show_entries",
                                                   "stream=start_time", "-of", "json",
                                                   str(self.web / source_language / "index.m3u8")]).stdout)
                source_start = MEDIA.Decimal(source_probe["streams"][0]["start_time"])
                self.assertLessEqual(abs(MEDIA.Decimal(stream["start_time"]) - source_start), MEDIA.Decimal("0.001"))
                self.assertGreater(MEDIA.Decimal(stream["start_time"]), MEDIA.Decimal("5.0"))
                self.assertEqual(encoded_hash(final, f"0:a:{index}"),
                                 encoded_hash(self.web / source_language / "index.m3u8", "0:a:0"),
                                 "The audio encoded packets changed during assembly")
                raw = command(["ffmpeg", "-v", "error", "-nostdin", "-ss", "1", "-i", str(final),
                               "-map", f"0:a:{index}", "-t", "0.25", "-ar", "4800", "-ac", "1",
                               "-f", "s16le", "-"]).stdout
                samples = struct.unpack("<" + "h" * (len(raw) // 2), raw)
                powers = {}
                for frequency in (440, 550, 660, 770):
                    real = sum(value * math.cos(2 * math.pi * frequency * i / 4800)
                               for i, value in enumerate(samples))
                    imaginary = sum(value * math.sin(2 * math.pi * frequency * i / 4800)
                                    for i, value in enumerate(samples))
                    powers[frequency] = real * real + imaginary * imaginary
                self.assertEqual(max(powers, key=powers.get), frequencies[stream["tags"]["language"]],
                                 "Encoded audio content was associated with the wrong language")
            observed_texts = []
            for index, stream in enumerate(subtitles):
                text = command(["ffmpeg", "-v", "error", "-nostdin", "-copyts", "-i", str(final), "-map", f"0:s:{index}",
                                "-c:s", "copy", "-f", "srt", "-"]).stdout.decode()
                observed_texts.append(text)
                self.assertNotIn("EXCLUDED", text)
                self.assertNotIn("&amp;", text)
                self.assertIn(" & café", text)
                self.assertEqual(stream["disposition"].get("hearing_impaired", 0), 0)
                label = next(value for value in texts if value in text)
                self.assertEqual(MEDIA.subtitle_parser().parse_srt(text), [
                    {"start_ms": 6080, "end_ms": 7000, "text": label + " & café\nSecond line"},
                    {"start_ms": 8000, "end_ms": 8800, "text": label + " END"},
                ])
            for text in texts:
                self.assertEqual(sum(text in value for value in observed_texts), 1, (text, observed_texts))
            self.assertEqual(sum(stream["disposition"].get("default", 0) for stream in audios), 1)
            self.assertNotIn("PRIVATE EXTRACTION", json.dumps(probe))
            requests = RequestHandler.requests[start_requests:]
            self.assertFalse(any(host.startswith("localhost:")
                                 for host in RequestHandler.request_hosts[start_requests:]),
                             "An unresolved subtitle alias was acquired")
            if not texts:
                self.assertFalse(any(path.endswith(".vtt") or path in {
                    "/fr.m3u8", "/fr-forced.m3u8", "/de.m3u8", "/de-forced.m3u8",
                    "/program_st_VA-MAL_fixture.m3u8", "/ja-alias.m3u8"} for path in requests), requests)
                output = completed.stdout + completed.stderr
                for forbidden in (b"YTDLP_PREPARE|subtitles", b"Downloading subtitles:",
                                  b"[ARTE_SUBTITLES]", b"arte-subtitles/", b"SubtitleConvertor"):
                    self.assertNotIn(forbidden, output)
            prefix = getattr(self, "source_prefix", "")
            self.assertFalse(any(path.startswith(prefix + "/comfort/") for path in requests), requests)
            self.assertFalse(any("VA-MAL" in path for path in requests if path.endswith(".vtt")), requests)
            self.assertTrue(any(path.startswith(prefix + "/video/") and path.endswith(".ts") for path in requests))
            self.assertTrue(any(path.startswith(prefix + "/ja/") and path.endswith(".ts") for path in requests))
            return final

        def video_observation(self, path: Path, duration: int) -> tuple[dict, dict]:
            probe = json.loads(command(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)]).stdout)
            stream = next(item for item in probe["streams"] if item["codec_type"] == "video")
            evidence = MEDIA.stream_evidence(path, stream, {"duration": duration}, MEDIA.Decimal(duration))
            self.assertTrue(evidence["tail_complete"])
            return stream, evidence

        def full_video_end(self, path: Path) -> MEDIA.Decimal:
            packets = json.loads(command(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_packets",
                                          "-show_entries", "packet=pts_time,duration_time", "-of", "json", str(path)]).stdout)["packets"]
            return max(MEDIA.Decimal(packet["pts_time"]) + MEDIA.Decimal(packet.get("duration_time", "0"))
                       for packet in packets)

        def test_long_gop_native_engine_reaches_the_real_end(self) -> None:
            original_seed = self.seed.read_bytes()
            long_web = self.web / "long-gop"
            long_web.mkdir(mode=0o700)
            metadata = create_hls_fixture(long_web, self.base + "/long-gop", duration=91, gop=300)
            self.web = long_web
            self.source_prefix = "/long-gop"
            try:
                write_json(self.seed, metadata)
                final = self.run_scenario("long-gop", 1, ["FRENCH COMPLETE DIALOGUE"])
            finally:
                self.seed.write_bytes(original_seed)
            source = long_web / "video" / "index.m3u8"
            source_stream, source_evidence = self.video_observation(source, 91)
            final_stream, final_evidence = self.video_observation(final, 91)
            actual_end = self.full_video_end(final)
            self.assertEqual(actual_end, MEDIA.Decimal("96"))
            self.assertEqual(self.full_video_end(source), actual_end)
            self.assertEqual(MEDIA.Decimal(source_evidence["end"]), actual_end)
            self.assertEqual(MEDIA.Decimal(final_evidence["end"]), actual_end)
            MEDIA.compare_clocks([final_stream], {str(final_stream["index"]): final_evidence},
                                 [source_stream], {str(source_stream["index"]): source_evidence})
            # Negative control for the former probe: its 20 s duration begins
            # at the earlier keyframe returned by seek, not the requested time.
            old_seek = MEDIA.Decimal(final_evidence["target"]) - 10
            old_packets = json.loads(command(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                               "-read_intervals", f"{old_seek}%+20", "-show_packets",
                                               "-show_entries", "packet=pts_time,duration_time", "-of", "json", str(final)]).stdout)["packets"]
            old_end = max(MEDIA.Decimal(packet["pts_time"]) + MEDIA.Decimal(packet.get("duration_time", "0"))
                          for packet in old_packets)
            self.assertLess(old_end, actual_end - 5, "The long-GOP fixture must expose the former incomplete window")
            shifted = self.root / "shifted-clock.mkv"
            command(["ffmpeg", "-v", "error", "-nostdin", "-copyts", "-itsoffset", "0.25", "-i", str(final),
                     "-map", "0:v:0", "-c", "copy", "-avoid_negative_ts", "disabled", str(shifted)])
            shifted_stream, shifted_evidence = self.video_observation(shifted, 91)
            with self.assertRaisesRegex(MEDIA.MediaError, "terminal packet presentation timestamps changed"):
                MEDIA.compare_clocks([shifted_stream], {str(shifted_stream["index"]): shifted_evidence},
                                     [source_stream], {str(source_stream["index"]): source_evidence})
            truncated = self.root / "truncated-clock.mkv"
            command(["ffmpeg", "-v", "error", "-nostdin", "-copyts", "-i", str(final), "-t", "50",
                     "-map", "0:v:0", "-c", "copy", "-avoid_negative_ts", "disabled", str(truncated)])
            self.assertLess(self.full_video_end(truncated), actual_end - 20)
            with self.assertRaises(MEDIA.MediaError):
                truncated_stream, truncated_evidence = self.video_observation(truncated, 91)
                MEDIA.compare_clocks([truncated_stream], {str(truncated_stream["index"]): truncated_evidence},
                                     [source_stream], {str(source_stream["index"]): source_evidence})

        def test_longer_duration_capped_tolerance_still_observes_eof(self) -> None:
            source = self.root / "longer-source.ts"
            final = self.root / "longer-copy.mkv"
            command(["ffmpeg", "-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc2=size=64x36:rate=10:duration=301",
                     "-an", "-c:v", "libx264", "-preset", "ultrafast", "-g", "300", "-bf", "3", "-sc_threshold", "0",
                     "-output_ts_offset", "5", "-muxdelay", "0", "-f", "mpegts", str(source)])
            command(["ffmpeg", "-v", "error", "-nostdin", "-copyts", "-i", str(source), "-map", "0",
                     "-c", "copy", "-avoid_negative_ts", "disabled", str(final)])
            original, before = self.video_observation(source, 301)
            current, after = self.video_observation(final, 301)
            self.assertEqual(MEDIA.Decimal(before["end"]), self.full_video_end(source))
            self.assertEqual(MEDIA.Decimal(after["end"]), self.full_video_end(final))
            self.assertEqual(MEDIA.Decimal(after["target"]), MEDIA.Decimal("301"))
            self.assertEqual(MEDIA.Decimal(after["tail_seek"]), MEDIA.Decimal("296"))
            MEDIA.compare_clocks([current], {str(current["index"]): after}, [original], {str(original["index"]): before})

        def test_partial_terminal_aac_frame_survives_two_copy_remuxes(self) -> None:
            source = self.root / "partial-frame.m4a"
            first = self.root / "partial-first.mkv"
            second = self.root / "partial-second.mkv"
            command(["ffmpeg", "-v", "error", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1",
                     "-c:a", "aac", "-b:a", "128k", str(source)])

            def observation(path: Path) -> tuple[dict, dict]:
                probe = json.loads(command(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)]).stdout)
                stream = probe["streams"][0]
                return stream, MEDIA.stream_evidence(path, stream, {"duration": 1}, MEDIA.Decimal(1))

            def packets(path: Path) -> list[dict]:
                return json.loads(command(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_packets",
                                           "-show_data_hash", "sha256", "-show_entries", "packet=pts_time,dts_time,size,data_hash",
                                           "-of", "json", str(path)]).stdout)["packets"]

            original, before = observation(source)
            source_packets = packets(source)
            self.assertGreater(len(source_packets), 3)
            self.assertLess(MEDIA.Decimal(before["terminal_packet"]["duration"]),
                            MEDIA.Decimal(before["nominal_packet_duration"]) - MEDIA.Decimal("0.001"))
            previous_stream, previous_evidence = original, before
            for previous, output in ((source, first), (first, second)):
                command(["ffmpeg", "-v", "error", "-nostdin", "-copyts", "-i", str(previous), "-map", "0",
                         "-c", "copy", "-map_metadata", "-1", "-map_metadata:s", "-1", "-avoid_negative_ts", "disabled", str(output)])
                current, after = observation(output)
                output_packets = packets(output)
                allowance = MEDIA.clock_tolerance(current, original)
                self.assertEqual(len(output_packets), len(source_packets))
                for index, (old, new) in enumerate(zip(source_packets, output_packets)):
                    with self.subTest(copy=output.name, packet=index):
                        self.assertRegex(old["data_hash"], r"^SHA256:[0-9a-fA-F]{64}$")
                        self.assertGreater(int(old["size"]), 0)
                        self.assertEqual(new["data_hash"], old["data_hash"])
                        self.assertEqual(new["size"], old["size"])
                        for field in ("pts_time", "dts_time"):
                            self.assertLessEqual(abs(MEDIA.Decimal(new[field]) - MEDIA.Decimal(old[field])), allowance)
                self.assertEqual(after["terminal_packet"]["data_hash"], before["terminal_packet"]["data_hash"])
                self.assertEqual(after["terminal_packet"]["size"], before["terminal_packet"]["size"])
                # Either retain the partial duration or prove the bounded AAC
                # nominal-duration representation. Both preserve the packets;
                # neither requires a remuxer to change the end or DURATION tag.
                end_preserved = abs(MEDIA.Decimal(after["end"]) - MEDIA.Decimal(before["end"])) <= allowance
                self.assertTrue(end_preserved or MEDIA.aac_partial_terminal_frame(original, current, before, after, allowance))
                self.assertTrue(aac_declared_end_matches_packets(
                    before, after, [MEDIA.Decimal(packet["pts_time"]) for packet in output_packets], allowance))
                MEDIA.compare_clocks([current], {str(current["index"]): after}, [original], {str(original["index"]): before})
                MEDIA.compare_clocks([current], {str(current["index"]): after},
                                     [previous_stream], {str(previous_stream["index"]): previous_evidence})
                previous_stream, previous_evidence = current, after
            for label, options in (("missing-terminal", ["-t", "0.98"]), ("shifted-terminal", ["-itsoffset", "0.002"]),
                                   ("truncated", ["-t", "0.5"])):
                output = self.root / f"aac-{label}.mkv"
                before_input = options if label == "shifted-terminal" else []
                after_input = options if label != "shifted-terminal" else []
                command(["ffmpeg", "-v", "error", "-nostdin", "-copyts", *before_input, "-i", str(source), *after_input,
                         "-map", "0", "-c", "copy", "-avoid_negative_ts", "disabled", str(output)])
                current, invalid = observation(output)
                invalid_packets = packets(output)
                if label == "shifted-terminal":
                    self.assertEqual([(item["size"], item["data_hash"]) for item in invalid_packets],
                                     [(item["size"], item["data_hash"]) for item in source_packets])
                else:
                    self.assertLess(len(invalid_packets), len(source_packets))
                if label == "truncated":
                    self.assertLess(MEDIA.Decimal(invalid["end"]), MEDIA.Decimal(before["end"]) - MEDIA.Decimal("0.25"))
                self.assertGreater(abs(MEDIA.Decimal(invalid["terminal_packet"]["pts"])
                                       - MEDIA.Decimal(before["terminal_packet"]["pts"])), MEDIA.Decimal("0.001"))
                with self.assertRaisesRegex(MEDIA.MediaError, "terminal packet presentation timestamps changed"):
                    MEDIA.compare_clocks([current], {str(current["index"]): invalid}, [original], {str(original["index"]): before})

        def test_original_with_complete_french(self) -> None:
            final = self.run_scenario("original-fr", 1, ["FRENCH COMPLETE DIALOGUE"])
            probe = json.loads(command(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(final)]).stdout)
            _, audio, subtitles = MEDIA.content_streams(probe)
            self.assertEqual(audio[0]["tags"]["language"], "jpn")
            self.assertEqual(subtitles[0]["tags"]["language"], "fra")
            self.assertEqual(subtitles[0]["disposition"]["default"], 1)
            self.assertEqual(subtitles[0]["disposition"]["forced"], 0)

        def test_all_admissible_tracks(self) -> None:
            final = self.run_scenario("all", 3, ["FRENCH COMPLETE DIALOGUE", "FRENCH FORCED SIGN",
                                                   "GERMAN COMPLETE DIALOGUE", "GERMAN FORCED SIGN"])
            probe = json.loads(command(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(final)]).stdout)
            _, audio, subtitles = MEDIA.content_streams(probe)
            self.assertEqual({stream["tags"]["language"] for stream in audio}, {"jpn", "fra", "deu"})
            self.assertEqual(sum(stream["disposition"]["forced"] for stream in subtitles), 2)
            digest = hashlib.sha256(final.read_bytes()).hexdigest()
            result = self.root / "collision.result"
            completed = capture_engine([
                "bash", str(PROJECT / "download-video.sh"), "--mode", "video", "--output-dir", str(final.parent),
                "--result-file", str(result), "--arte-original-fr",
                "https://www.arte.tv/fr/videos/133131-synthetic/"], self.environment, self.root)
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(result.exists())
            self.assertEqual(hashlib.sha256(final.read_bytes()).hexdigest(), digest)

        def test_audio_without_subtitles(self) -> None:
            self.run_scenario("custom-none", 1, [])

        def test_all_audio_without_subtitle_requests(self) -> None:
            self.run_scenario("all-none", 3, [])

        def test_automatic_audio_without_subtitle_requests(self) -> None:
            self.run_scenario("auto-none", 1, [])

        def test_selected_audio_unavailable_never_falls_back_to_excluded(self) -> None:
            directory = self.root / "unavailable"
            directory.mkdir(mode=0o700)
            catalogue = self.root / "unavailable.catalogue.json"
            selection = self.root / "unavailable.selection.json"
            result = self.root / "unavailable.result"
            manifest = self.web / "ja" / "index.m3u8"
            retained = manifest.with_suffix(".retained")
            start_requests = len(RequestHandler.requests)

            def select_and_withdraw() -> None:
                if not catalogue.exists() or selection.exists():
                    return
                choices = json.loads(catalogue.read_text())
                original = next(track["id"] for track in choices["audio"] if track["language"] == "ja")
                manifest.rename(retained)
                pending = selection.with_suffix(".tmp")
                write_json(pending, TRACKS.choose(choices, audio_mode="custom", subtitle_mode="none",
                                                 audios=[original]))
                pending.replace(selection)

            try:
                completed = capture_engine([
                    "bash", str(PROJECT / "download-video.sh"), "--mode", "video", "--output-dir", str(directory),
                    "--result-file", str(result), "--arte-catalog", str(catalogue), "--arte-selection", str(selection),
                    "https://www.arte.tv/fr/videos/133131-synthetic/"], self.environment, self.root, select_and_withdraw)
            finally:
                if retained.exists():
                    retained.rename(manifest)
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(result.exists())
            requests = RequestHandler.requests[start_requests:]
            self.assertIn("/ja/index.m3u8", requests)
            self.assertFalse(any(path.startswith(("/fr/", "/de/", "/comfort/")) for path in requests))


if __name__ == "__main__":
    unittest.main()
