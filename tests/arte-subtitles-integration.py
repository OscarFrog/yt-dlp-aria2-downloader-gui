# SPDX-License-Identifier: MIT
"""Verify ARTE subtitle fidelity for yt-dlp-aria2-downloader-gui.

Repository path: tests/arte-subtitles-integration.py

Independent cue parsing, HLS mapping, conversion refusal/fallback and actual
local FFmpeg round trips protect the source-to-MKV text and timestamp contract.
"""

from __future__ import annotations

import copy
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("arte_subtitles", ROOT / "private-arte-subtitles.py")
SUBS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUBS)
TRACKS = SUBS.TRACKS
VTT = ("\ufeffWEBVTT\r\n\r\nSTYLE\r\n::cue(.unused) { color: red; }\r\n\r\n"
       "REGION\r\nid:unused\r\nwidth:40%\r\n\r\nNOTE ordinary metadata\r\nnot a cue\r\n\r\n"
       "id-é-一\r\n00:00:46.080 --> 00:00:47.125 align:start position:10%\r\n"
       "Bonjour &amp; <i>日本語</i>\r\nune deuxième ligne\r\n\r\n"
       "second\r\n00:00:47.000 --> 00:00:48.001\r\nChevauchement\r\n").encode()


def sample_plan(*, with_subtitles=True):
    video = {"format_id": "video", "url": "https://example.invalid/video.m3u8", "ext": "mp4",
             "vcodec": "avc1", "acodec": "none", "protocol": "m3u8_native"}
    audio = {"format_id": "日本語", "url": "https://example.invalid/audio.m3u8", "ext": "mp4",
             "vcodec": "none", "acodec": "aac", "language": "ja", "role": "original", "protocol": "m3u8_native"}
    raw = {"id": "subtitles-test", "extractor_key": "ArteTV", "duration": 60,
           "formats": [video, audio], "subtitles": {"fr": [{"url": "https://example.invalid/full.vtt", "ext": "vtt", "protocol": "https"}]},
           "requested_downloads": [{"requested_formats": [video, audio], "filename": "/tmp/subtitles-test.mkv"}]}
    catalogue = TRACKS.build_catalogue(raw, lambda *_args: (_ for _ in ()).throw(AssertionError("unexpected network")))
    selection = TRACKS.choose(catalogue, "all") if with_subtitles else TRACKS.choose(catalogue, "custom", ["ja"], [])
    plan, expected, _options = TRACKS.apply_selection(raw, catalogue, selection)
    return plan, expected


def rewrite_expected(plan, expected):
    expected["plan_digest"] = TRACKS.canonical_digest(plan)


def mapped_vtt(local: str, ticks: int, cue_start: str, cue_end: str, text="mapped") -> bytes:
    return (f"WEBVTT\nX-TIMESTAMP-MAP=LOCAL:{local},MPEGTS:{ticks}\n\n"
            f"{cue_start} --> {cue_end}\n{text}\n").encode()


class ParserTests(unittest.TestCase):
    def test_bom_crlf_ids_unicode_entities_markup_lines_and_settings(self):
        parsed = SUBS.parse_webvtt(VTT)
        self.assertEqual(len(parsed["cues"]), 2)
        first = parsed["cues"][0]
        self.assertEqual(first["id"], "id-é-一")
        self.assertEqual(first["start_ms"], 46080)
        self.assertEqual(first["end_ms"], 47125)
        self.assertEqual(first["text"], "Bonjour & 日本語\nune deuxième ligne")
        self.assertIn("<i>日本語</i>", first["markup"])
        self.assertEqual(first["settings"], {"align": "start", "position": "10%"})
        self.assertTrue(parsed["positioning_dropped"])

    def test_legal_overlapping_cues_are_preserved(self):
        cues = SUBS.parse_webvtt(VTT)["cues"]
        self.assertLess(cues[1]["start_ms"], cues[0]["end_ms"])
        self.assertEqual(SUBS.parse_srt(SUBS.serialize_srt(cues)), SUBS.normalized_cues(cues))

    def test_unused_style_and_region_are_understood_not_cues(self):
        parsed = SUBS.parse_webvtt(VTT)
        self.assertEqual(len(parsed["styles"]), 1)
        self.assertEqual(len(parsed["regions"]), 1)
        self.assertEqual(len(parsed["cues"]), 2)

    def test_active_css_is_explicitly_refused(self):
        active = VTT.replace(b"Bonjour &amp;", b"<c.unused>Bonjour</c> &amp;")
        with self.assertRaisesRegex(SUBS.SubtitleError, "active STYLE"):
            SUBS.parse_webvtt(active)

    def test_global_css_is_not_silently_removed(self):
        active = VTT.replace(b"::cue(.unused)", b"::cue")
        with self.assertRaisesRegex(SUBS.SubtitleError, "unsupported CSS"):
            SUBS.parse_webvtt(active)

    def test_active_region_is_explicitly_refused(self):
        active = VTT.replace(b"align:start position:10%", b"region:unused")
        with self.assertRaisesRegex(SUBS.SubtitleError, "active REGION"):
            SUBS.parse_webvtt(active)

    def test_annotation_wrappers_preserve_display_text(self):
        parsed = SUBS.parse_webvtt(b"WEBVTT\n\n00:01.000 --> 00:02.000\n<v Speaker><lang ja><c.annotation>one &amp; two</c></lang></v>\n")
        self.assertEqual(parsed["cues"][0]["text"], "one & two")

    def test_srt_emits_literal_ampersand_without_masking_encoded_entities(self):
        source = SUBS.parse_webvtt(b"WEBVTT\n\n00:01.000 --> 00:02.000\nA &amp; B\n")
        serialized = SUBS.serialize_srt(source["cues"])
        self.assertIn(b"A & B", serialized)
        self.assertNotIn(b"&amp;", serialized)
        wrong = serialized.replace(b"A & B", b"A &amp; B")
        self.assertNotEqual(SUBS.parse_srt(wrong), SUBS.normalized_cues(source["cues"]))

    def test_ambiguous_literal_angle_brackets_are_explicitly_refused(self):
        for text in ("A &lt; B", "&lt;b&gt;literal&lt;/b&gt;"):
            with self.subTest(text=text), self.assertRaisesRegex(SUBS.SubtitleError, "literal angle brackets"):
                SUBS.parse_webvtt(("WEBVTT\n\n00:01.000 --> 00:02.000\n" + text + "\n").encode())

    def test_builtin_color_is_active_even_without_style(self):
        with self.assertRaisesRegex(SUBS.SubtitleError, "active color"):
            SUBS.parse_webvtt(b"WEBVTT\n\n00:01.000 --> 00:02.000\n<c.red>red</c>\n")

    def test_karaoke_ruby_and_unknown_markup_refuse_loss(self):
        for text in ("word<00:01.500>more", "<ruby>字<rt>じ</rt></ruby>", "<unknown>text</unknown>"):
            with self.subTest(text=text), self.assertRaisesRegex(SUBS.SubtitleError, "unsupported active markup"):
                SUBS.parse_webvtt(("WEBVTT\n\n00:01.000 --> 00:02.000\n" + text + "\n").encode())

    def test_malformed_timing_or_unbalanced_markup_is_rejected(self):
        for cue in ("00:01.000 --> 00:00.000\ntext", "00:99.000 --> 01:00.000\ntext", "00:01.000 --> 00:02.000\n<i>open"):
            with self.subTest(cue=cue), self.assertRaises(SUBS.SubtitleError):
                SUBS.parse_webvtt(("WEBVTT\n\n" + cue + "\n").encode())

    def test_genuinely_empty_webvtt_has_zero_cues(self):
        self.assertEqual(SUBS.parse_webvtt(b"WEBVTT\n\nNOTE no dialogue\n")["cues"], [])
        self.assertEqual(SUBS.parse_srt(b""), [])

    def test_byte_and_cue_bounds(self):
        with self.assertRaisesRegex(SUBS.SubtitleError, "size limit"):
            SUBS.parse_webvtt(b"x" * (SUBS.MAX_BYTES + 1))
        with self.assertRaisesRegex(SUBS.SubtitleError, "zero byte"):
            SUBS.parse_webvtt(b"WEBVTT\n\n\0")

    def test_no_map_and_late_first_cue_are_not_shifted(self):
        cues, timeline = SUBS.normalize_fragments([SUBS.parse_webvtt(VTT)])
        self.assertEqual(cues[0]["start_ms"], 46080)
        self.assertEqual(timeline["first_offset_ticks"], 0)

    def test_nonzero_map_uses_common_clock_once(self):
        source = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 450000, "00:00:01.080", "00:00:02.001"))
        cues, timeline = SUBS.normalize_fragments([source])
        self.assertEqual(cues[0]["start_ms"], 6080)
        self.assertEqual(cues[0]["end_ms"], 7001)
        self.assertEqual(timeline["first_offset_ticks"], 450000)

    def test_nonzero_local_map_is_respected(self):
        source = SUBS.parse_webvtt(mapped_vtt("00:00:10.000", 450000, "00:00:11.080", "00:00:12.001"))
        self.assertEqual(SUBS.normalize_fragments([source])[0][0]["start_ms"], 6080)

    def test_multifragment_each_map_applies_once(self):
        first = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 450000, "00:00:01.080", "00:00:02.001", "first"))
        second = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 1350000, "00:00:01.080", "00:00:02.001", "second"))
        cues, _timeline = SUBS.normalize_fragments([first, second])
        self.assertEqual([cue["start_ms"] for cue in cues], [6080, 16080])

    def test_identical_boundary_repeat_is_deduplicated(self):
        first = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 0, "00:00:09.000", "00:00:11.000", "boundary"))
        second = copy.deepcopy(first)
        cues, _timeline = SUBS.normalize_fragments([first, second])
        self.assertEqual(len(cues), 1)

    def test_equal_text_at_different_times_is_not_deduplicated_or_hinged(self):
        first = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 0, "00:00:01.000", "00:00:02.000", "repeat"))
        second = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 0, "00:00:02.000", "00:00:03.000", "repeat"))
        cues, _timeline = SUBS.normalize_fragments([first, second])
        self.assertEqual(len(cues), 2)
        self.assertEqual([cue["start_ms"] for cue in cues], [1000, 2000])

    def test_duplicates_in_same_fragment_are_not_assumed_boundary_repetition(self):
        first = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 0, "00:00:01.000", "00:00:02.000"))
        first["cues"].append(dict(first["cues"][0]))
        self.assertEqual(len(SUBS.normalize_fragments([first])[0]), 2)

    def test_distinct_cue_ids_are_not_assumed_boundary_repetition(self):
        first = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 0, "00:00:01.000", "00:00:02.000"))
        second = copy.deepcopy(first)
        first["cues"][0]["id"] = "speaker-one"
        second["cues"][0]["id"] = "speaker-two"
        self.assertEqual(len(SUBS.normalize_fragments([first, second])[0]), 2)

    def test_boundary_dedup_preserves_occurrence_multiplicity(self):
        first = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 0, "00:00:01.000", "00:00:02.000"))
        second = copy.deepcopy(first)
        second["cues"].append(dict(second["cues"][0]))
        self.assertEqual(len(SUBS.normalize_fragments([first, second])[0]), 2)
        self.assertEqual(len(SUBS.normalize_fragments([second, first])[0]), 2)

    def test_shared_clock_discontinuity_is_supported(self):
        first = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 450000, "00:00:01.000", "00:00:02.000", "first"))
        second = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 1350000, "00:00:01.000", "00:00:02.000", "second"))
        cues, timeline = SUBS.normalize_fragments([first, second], [False, True])
        self.assertEqual([cue["start_ms"] for cue in cues], [6000, 16000])
        self.assertEqual(timeline["discontinuities"], 1)

    def test_reset_discontinuity_without_common_anchor_is_refused(self):
        first = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 450000, "00:00:01.000", "00:00:02.000"))
        second = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 0, "00:00:01.000", "00:00:02.000"))
        with self.assertRaisesRegex(SUBS.SubtitleError, "clock resets"):
            SUBS.normalize_fragments([first, second], [False, True])

    def test_missing_discontinuity_map_is_refused(self):
        first = SUBS.parse_webvtt(VTT)
        with self.assertRaisesRegex(SUBS.SubtitleError, "lacks an explicit"):
            SUBS.normalize_fragments([first, first], [False, True])

    def test_proven_33_bit_wrap(self):
        first = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", SUBS.MPEGTS_WRAP - 90000, "00:00:00.000", "00:00:00.500", "before"))
        second = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 90000, "00:00:00.000", "00:00:00.500", "after"))
        cues, timeline = SUBS.normalize_fragments([first, second])
        self.assertEqual(cues[1]["start_ms"] - cues[0]["start_ms"], 2000)
        self.assertEqual(timeline["wrap_ticks"], SUBS.MPEGTS_WRAP)

    def test_extinf_durations_do_not_shift_cues(self):
        manifest = "#EXTM3U\n#EXTINF:1.222,\na.vtt\n#EXTINF:1,\nb.vtt\n#EXT-X-ENDLIST\n"
        structure = SUBS.playlist_structure(manifest)
        first = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 0, "00:00:00.100", "00:00:00.900", "first"))
        second = SUBS.parse_webvtt(mapped_vtt("00:00:00.000", 90000, "00:00:00.100", "00:00:00.900", "second"))
        cues, _timeline = SUBS.normalize_fragments([first, second], structure["discontinuities"])
        self.assertEqual(cues[1]["start_ms"], 1100)


class ConversionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="arte-subtitles-test.")
        self.directory = Path(self.temp.name)
        self.plan, self.expected = sample_plan()
        SUBS.write_private_bytes(self.directory / "source.fr.vtt", VTT)

    def tearDown(self):
        self.temp.cleanup()

    def fake_ffmpeg(self, mode):
        path = self.directory / "ffmpeg-fixture"
        script = '''#!/usr/bin/env python3
import pathlib,sys
output=pathlib.Path(sys.argv[-1])
source=pathlib.Path(sys.argv[sys.argv.index('-i')+1]).read_bytes()
capability=b'NOTE capability probe' in source
mode=MODE
if mode=='empty':
    output.write_bytes(b'')
elif mode=='empty-after-probe' and not capability:
    output.write_bytes(b'')
elif mode=='partial' or not capability:
    output.write_bytes(b'1\\n00:00:46,080 --> 00:00:47,125\\npartial\\n\\n')
else:
    output.write_bytes(b'1\\n00:00:46,080 --> 00:00:47,125\\nHello & world\\nsecond line\\n\\n2\\n00:00:47,000 --> 00:00:48,001\\nOverlap\\n\\n')
'''.replace("MODE", repr(mode))
        path.write_text(script)
        path.chmod(0o700)
        return str(path)

    def test_zero_exit_empty_srt_is_not_success(self):
        reference = SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg=self.fake_ffmpeg("empty"))
        self.assertFalse(reference["ffmpeg_webvtt_capable"])
        self.assertEqual(reference["tracks"][0]["conversion"], "controlled-srt")
        self.assertEqual(len(reference["tracks"][0]["cues"]), 2)

    def test_zero_exit_partial_srt_is_not_success(self):
        reference = SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg=self.fake_ffmpeg("partial"))
        self.assertFalse(reference["ffmpeg_webvtt_capable"])
        self.assertEqual(len(reference["tracks"][0]["cues"]), 2)

    def test_real_source_comparison_is_required_even_after_capability_pass(self):
        with self.assertRaisesRegex(SUBS.SubtitleError, "empty, partial or changed"):
            SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg=self.fake_ffmpeg("capable-probe-only"))

    def test_capable_ffmpeg_returning_empty_real_conversion_is_fatal(self):
        with self.assertRaisesRegex(SUBS.SubtitleError, "empty, partial or changed"):
            SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg=self.fake_ffmpeg("empty-after-probe"))

    def test_original_vtt_is_retained_unchanged(self):
        SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg=self.fake_ffmpeg("empty"))
        self.assertEqual((self.directory / "source.fr.vtt").read_bytes(), VTT)

    def test_fifo_source_fails_without_blocking(self):
        path = self.directory / "fifo.vtt"
        os.mkfifo(path, 0o600)
        with self.assertRaisesRegex(SUBS.SubtitleError, "regular file"):
            SUBS.read_private_bytes(path)

    def test_genuinely_empty_source_is_reported_explicitly(self):
        path = self.directory / "source.fr.vtt"
        path.write_bytes(b"WEBVTT\n\n")
        with self.assertRaisesRegex(SUBS.SubtitleError, "genuinely empty"):
            SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg=self.fake_ffmpeg("empty"))

    def test_no_subtitle_selection_needs_no_ffmpeg(self):
        self.plan, self.expected = sample_plan(with_subtitles=False)
        reference = SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg="/nonexistent/ffmpeg")
        self.assertEqual(reference["tracks"], [])

    def prepare_hls(self, fragment_payloads, native_payload, manifest):
        source = self.plan["requested_subtitles"]["fr"]
        source["protocol"] = "m3u8_native"
        source["hls_media_playlist_data"] = manifest
        evidence = self.plan["_arte_sources"]["subtitles"][0]
        evidence["source"].update(source)
        identity = TRACKS.source_identity(source, evidence["evidence"])
        evidence["source_identity"] = identity
        self.expected["subtitles"][0]["source_identity"] = identity
        self.plan["arte_selection"]["sources"]["subtitles"] = [identity]
        (self.directory / "source.fr.vtt").write_bytes(native_payload)
        for index, payload in enumerate(fragment_payloads, 1):
            SUBS.write_private_bytes(self.directory / f"source.fr.vtt.part-Frag{index}", payload)
        rewrite_expected(self.plan, self.expected)

    def test_native_first_map_is_applied_exactly_once(self):
        first = mapped_vtt("00:00:00.000", 450000, "00:00:01.080", "00:00:02.001", "first")
        second = mapped_vtt("00:00:00.000", 1350000, "00:00:01.080", "00:00:02.001", "second")
        native = first + b"\n00:00:11.080 --> 00:00:12.001\nsecond\n"
        self.prepare_hls([first, second], native, "#EXTM3U\n#EXTINF:10,\na.vtt\n#EXTINF:10,\nb.vtt\n#EXT-X-ENDLIST\n")
        reference = SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg=self.fake_ffmpeg("empty"))
        track = reference["tracks"][0]
        self.assertTrue(track["native_cues_exact"])
        self.assertEqual([cue["start_ms"] for cue in track["cues"]], [6080, 16080])

    def test_native_hinge_does_not_destroy_distinct_raw_cues(self):
        first = mapped_vtt("00:00:00.000", 0, "00:00:01.000", "00:00:02.000", "repeat")
        second = mapped_vtt("00:00:00.000", 0, "00:00:02.000", "00:00:03.000", "repeat")
        native = mapped_vtt("00:00:00.000", 0, "00:00:01.000", "00:00:03.000", "repeat")
        self.prepare_hls([first, second], native, "#EXTM3U\n#EXTINF:2,\na.vtt\n#EXTINF:2,\nb.vtt\n#EXT-X-ENDLIST\n")
        reference = SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg=self.fake_ffmpeg("empty"))
        self.assertFalse(reference["tracks"][0]["native_cues_exact"])
        self.assertEqual(len(reference["tracks"][0]["cues"]), 2)

    def test_missing_raw_fragment_rejects_partial_source(self):
        first = mapped_vtt("00:00:00.000", 0, "00:00:01.000", "00:00:02.000")
        self.prepare_hls([first], first, "#EXTM3U\n#EXTINF:2,\na.vtt\n#EXTINF:2,\nb.vtt\n#EXT-X-ENDLIST\n")
        with self.assertRaises(FileNotFoundError):
            SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg=self.fake_ffmpeg("empty"))

    def test_aggregate_byte_limit_is_checked_before_parsing_next_fragment(self):
        first = mapped_vtt("00:00:00.000", 0, "00:00:01.000", "00:00:02.000")
        self.prepare_hls([first, first], first, "#EXTM3U\n#EXTINF:2,\na.vtt\n#EXTINF:2,\nb.vtt\n#EXT-X-ENDLIST\n")
        fake = self.fake_ffmpeg("empty")
        real_reader = SUBS.read_private_bytes
        with mock.patch.object(SUBS, "MAX_TOTAL", len(first) + 1), mock.patch.object(SUBS, "read_private_bytes", wraps=real_reader) as reader:
            with self.assertRaisesRegex(SUBS.SubtitleError, "total byte limit"):
                SUBS.build_reference(self.plan, self.expected, self.directory, ffmpeg=fake)
            self.assertFalse(any(str(call.args[0]).endswith("Frag2") for call in reader.call_args_list))

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg is unavailable; synthetic parser/fallback tests remain active")
    def test_actual_ffmpeg_capability_and_srt_mkv_roundtrip(self):
        reference = SUBS.build_reference(self.plan, self.expected, self.directory)
        track = reference["tracks"][0]
        mkv, extracted = self.directory / "subtitles.mkv", self.directory / "extracted.srt"
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "color=s=16x16:r=1:d=1", "-i", track["path"],
                        "-map", "0:v:0", "-map", "1:s:0", "-c:v", "ffv1", "-c:s", "srt", "-copyts", "-avoid_negative_ts", "disabled", str(mkv)], check=True, timeout=30)
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(mkv), "-map", "0:s:0", "-c:s", "srt", str(extracted)], check=True, timeout=30)
        self.assertEqual(SUBS.parse_srt(extracted.read_bytes()), track["cues"])
        self.assertEqual(track["cues"][0]["start_ms"], 46080)


if __name__ == "__main__":
    unittest.main()
