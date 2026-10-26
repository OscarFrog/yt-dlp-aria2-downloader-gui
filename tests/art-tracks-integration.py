# SPDX-License-Identifier: MIT
"""Test ARTE catalogue policy for yt-dlp-aria2-downloader-gui.

Repository path: tests/art-tracks-integration.py

Raw synthetic manifests preserve the observed extractor ambiguities: Japanese
audio under a French global label, mixed de-forced subtitles, and a Japanese
alias on a second origin. No external network or media tools are needed.
"""

from __future__ import annotations

import copy
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("art_tracks", ROOT / "private-art-tracks.py")
ARTE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ARTE)
MASTER = "https://first.example.invalid/program/master.m3u8"
BASE = "https://first.example.invalid/program/"
OTHER = "https://second.example.invalid/program/"


def raw_fixture():
    """Return extractor data and unnormalized HLS evidence, including exclusions."""
    video = {"format_id": "VF-STF-1080", "vcodec": "avc1.640028", "acodec": "none",
             "height": 1080, "width": 1920, "ext": "mp4", "protocol": "m3u8_native",
             "url": BASE + "video.m3u8", "manifest_url": MASTER}
    low_video = dict(video, format_id="VF-STF-720", height=720, url=BASE + "video720.m3u8")
    alternative_video = dict(video, format_id="VF-STF-1080-hevc", vcodec="hvc1", url=BASE + "video-hevc.m3u8")
    formats = [low_video, alternative_video, video]
    lines = ["#EXTM3U"]
    for lang, name, code in (("de", "allemand", "va-deu"), ("ja", "japonais (VO)", "vo-jpn"), ("fr", "français", "vf-fra")):
        identifier = "VF-STF-audio_0-" + name.replace(" ", "_").replace("(", "_").replace(")", "_")
        formats.append({"format_id": identifier, "format_note": "Français [VF]", "language": lang,
                        "vcodec": "none", "acodec": "aac", "ext": "mp4", "protocol": "m3u8_native",
                        "url": BASE + "audio-" + lang + ".m3u8", "manifest_url": MASTER})
        lines.append(f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio_0",LANGUAGE="{lang}",NAME="{name}",CHARACTERISTICS="tv.arte.audio.version.{code}",URI="audio-{lang}.m3u8"')
    subtitles = {}
    definitions = [
        ("fr-forced", "fr", "français (forcé)", "YES", "tv.arte.subtitle.version.vf-fra,tv.arte.subtitle.mandatory", "film_st_VF-FRA_id.m3u8"),
        ("fr", "fr", "français", "NO", "tv.arte.subtitle.version.vo-fra,public.accessibility.transcribes-spoken-dialog", "film_st_VO-FRA_id.m3u8"),
        ("de-forced", "de", "allemand (forcé)", "YES", "tv.arte.subtitle.version.va-all,tv.arte.subtitle.mandatory", "film_st_VA-ALL_id.m3u8"),
        ("de", "de", "allemand", "NO", "tv.arte.subtitle.version.vo-all,public.accessibility.transcribes-spoken-dialog", "film_st_VO-ALL_id.m3u8"),
        ("de-forced", "de", "allemand (sourds et malentendants)", "NO", "tv.arte.subtitle.version.va-mal,public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound", "film_st_VA-MAL_id.m3u8"),
        ("ja", "ja", "VO (Forced)", "YES", "tv.arte.subtitle.version.vo-fra,tv.arte.subtitle.mandatory", OTHER + "film_st_VO-FRA_id.m3u8"),
    ]
    resources = {}
    for key, lang, name, forced, characteristics, uri in definitions:
        url = uri if uri.startswith("https:") else BASE + uri
        subtitles.setdefault(key, []).append({"url": url, "ext": "vtt", "protocol": "m3u8_native"})
        lines.append(f'#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitle_0",LANGUAGE="{lang}",NAME="{name}",FORCED={forced},CHARACTERISTICS="{characteristics}",URI="{uri}"')
        resources[url] = b"#EXTM3U\n#EXT-X-TARGETDURATION:18\n#EXTINF:18,\ntext.vtt\n#EXT-X-ENDLIST\n"
    resources[BASE + "text.vtt"] = resources[OTHER + "text.vtt"] = b"WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nOrdinary French dialogue\n"
    resources[MASTER] = ("\n".join(lines) + "\n").encode()
    plan = {"id": "synthetic-ring", "extractor_key": "ArteTV", "extractor": "arte:tv", "title": "Synthetic Ring",
            "duration": 18, "mainQuality": "720p", "formats": formats, "subtitles": subtitles,
            "requested_downloads": [{"requested_formats": [video, formats[-1]], "format_id": video["format_id"] + "+" + formats[-1]["format_id"],
                                     "filename": "/tmp/synthetic-ring.mkv", "ext": "mkv"}]}
    return plan, resources


class FakeFetch:
    def __init__(self, resources):
        self.resources = resources
        self.calls = []

    def __call__(self, url, _headers, limit):
        self.calls.append(url)
        if url not in self.resources:
            raise ARTE.ArteError("ARTE rendition is unavailable during analysis; retry or select again")
        value = self.resources[url]
        if len(value) > limit:
            raise ARTE.ArteError("ARTE metadata is too large")
        return value


class CatalogueTests(unittest.TestCase):
    def setUp(self):
        self.plan, self.resources = raw_fixture()
        self.fetch = FakeFetch(self.resources)

    def catalogue(self):
        return ARTE.build_catalogue(self.plan, self.fetch)

    def apply(self, catalogue, selection):
        return ARTE.apply_selection(self.plan, catalogue, selection, fetch=self.fetch)

    def coherent_alias_catalogue(self):
        # This separate synthetic case has reliable Japanese metadata. A
        # shared path on another host must still be proved by content.
        lines = self.resources[MASTER].decode().splitlines()
        lines = [line.replace("subtitle.version.vo-fra", "subtitle.version.vo-jpn") if OTHER in line else line for line in lines]
        self.resources[MASTER] = ("\n".join(lines) + "\n").encode()
        return self.catalogue()

    def test_raw_fixture_retains_extractor_ambiguities(self):
        self.assertEqual(len(self.plan["subtitles"]["de-forced"]), 2)
        self.assertIn("ja", self.plan["subtitles"])
        japanese = next(item for item in self.plan["formats"] if item.get("language") == "ja")
        self.assertEqual(japanese["format_note"], "Français [VF]")

    def test_ring_original_french_full(self):
        catalogue = self.catalogue()
        choice = ARTE.choose(catalogue, "original-fr")
        self.assertEqual(choice["audio"], ["ja"])
        self.assertEqual(choice["subtitles"], ["fr"])
        self.assertEqual(choice["default_audio"], "ja")
        self.assertEqual(choice["default_subtitle"], "fr")

    def test_automatic_original_audio_and_french_full(self):
        choice = ARTE.choose(self.catalogue())
        self.assertEqual(choice["version"], 2)
        self.assertEqual((choice["audio_mode"], choice["subtitle_mode"]), ("auto", "auto"))
        self.assertEqual((choice["audio"], choice["subtitles"]), (["ja"], ["fr"]))
        self.assertEqual(choice["messages"], [])

    def test_automatic_french_original_needs_no_subtitles(self):
        catalogue = self.catalogue()
        for item in catalogue["audio"]:
            item["original"] = item["language"] == "fr"
        choice = ARTE.choose(catalogue)
        self.assertEqual((choice["audio"], choice["subtitles"]), (["fr"], []))
        self.assertIsNone(choice["default_subtitle"])

    def test_regional_french_original_also_needs_no_subtitles(self):
        catalogue = self.catalogue()
        for item in catalogue["audio"]:
            item["original"] = item["language"] == "fr"
            if item["original"]:
                item["language"] = "fr-ca"
        choice = ARTE.choose(catalogue)
        self.assertEqual((choice["audio"], choice["subtitles"]), (["fr"], []))

    def test_unknown_original_prefers_french_without_claiming_original(self):
        catalogue = self.catalogue()
        for item in catalogue["audio"]:
            item["original"] = False
            item["default"] = item["language"] == "de"
        choice = ARTE.choose(catalogue)
        self.assertEqual((choice["audio"], choice["subtitles"]), (["fr"], []))
        self.assertIn("original_audio_unknown", choice["messages"])
        self.assertFalse(next(item for item in catalogue["audio"] if item["id"] == "fr")["original"])

    def test_unknown_original_uses_explicit_default_without_french(self):
        catalogue = self.catalogue()
        catalogue["audio"] = [item for item in catalogue["audio"] if item["language"] != "fr"]
        for item in catalogue["audio"]:
            item["original"] = False
            item["default"] = item["language"] == "ja"
        self.assertEqual(ARTE.choose(catalogue)["audio"], ["ja"])
        catalogue["audio"].reverse()
        self.assertEqual(ARTE.choose(catalogue)["audio"], ["ja"])

    def test_hls_default_is_preserved_as_track_local_evidence(self):
        self.resources[MASTER] = self.resources[MASTER].replace(b'NAME="allemand",', b'NAME="allemand",DEFAULT=YES,')
        catalogue = self.catalogue()
        self.assertTrue(next(item for item in catalogue["audio"] if item["language"] == "de")["default"])
        self.assertFalse(next(item for item in catalogue["audio"] if item["language"] == "ja")["default"])

    def test_global_original_label_cannot_establish_track_origin(self):
        self.resources[MASTER] = self.resources[MASTER].replace(b'japonais (VO)', b'japonais').replace(b'audio.version.vo-jpn', b'audio.version.other-jpn')
        for item in self.plan["formats"]:
            item["format_note"] = "Version originale japonaise [VO]"
        choice = ARTE.choose(self.catalogue())
        self.assertEqual(choice["audio"], ["fr"])
        self.assertIn("original_audio_unknown", choice["messages"])

    def test_ambiguous_original_is_reported_and_deterministic(self):
        catalogue = self.catalogue()
        for item in catalogue["audio"]:
            item["original"] = item["language"] in ("ja", "de")
        first = ARTE.choose(catalogue)
        catalogue["audio"].reverse()
        second = ARTE.choose(catalogue)
        self.assertEqual(first, second)
        self.assertEqual(first["audio"], ["fr"])
        self.assertIn("original_audio_ambiguous", first["messages"])

    def test_automatic_translation_missing_never_uses_forced(self):
        catalogue = self.catalogue()
        catalogue["subtitles"] = [item for item in catalogue["subtitles"] if item["id"] != "fr"]
        choice = ARTE.choose(catalogue)
        self.assertEqual(choice["subtitles"], [])
        self.assertIn("french_full_unavailable", choice["messages"])

    def test_automatic_translation_ambiguity_is_reported(self):
        catalogue = self.catalogue()
        catalogue["subtitles"].append(dict(next(item for item in catalogue["subtitles"] if item["id"] == "fr"), id="fr-alt"))
        choice = ARTE.choose(catalogue)
        self.assertEqual(choice["subtitles"], [])
        self.assertIn("french_full_ambiguous", choice["messages"])

    def test_unknown_spoken_language_does_not_imply_foreign_translation(self):
        catalogue = self.catalogue()
        japanese = next(item for item in catalogue["audio"] if item["id"] == "ja")
        japanese["language"] = "und"
        choice = ARTE.choose(catalogue)
        self.assertEqual(choice["subtitles"], [])
        self.assertIn("audio_language_unknown", choice["messages"])

    def test_multiple_spoken_languages_do_not_imply_foreign_translation(self):
        catalogue = self.catalogue()
        next(item for item in catalogue["audio"] if item["id"] == "ja")["language"] = "mul"
        choice = ARTE.choose(catalogue)
        self.assertEqual(choice["audio"], ["ja"])
        self.assertEqual(choice["subtitles"], [])
        self.assertIn("audio_language_unknown", choice["messages"])

    def test_conflicting_spoken_language_metadata_disables_automatic_translation(self):
        self.resources[MASTER] = self.resources[MASTER].replace(b'LANGUAGE="ja",NAME="japonais (VO)"', b'LANGUAGE="en",NAME="japonais (VO)"')
        catalogue = self.catalogue()
        japanese = next(item for item in catalogue["audio"] if item["id"] == "ja")
        self.assertFalse(japanese["language_reliable"])
        self.assertEqual(ARTE.choose(catalogue)["subtitles"], [])
        self.assertIn("audio_language_unknown", ARTE.choose(catalogue)["messages"])

    def test_audio_change_keeps_retained_default_then_uses_stable_fallback(self):
        catalogue = self.catalogue()
        retained = ARTE.choose(catalogue, audio_mode="custom", audios=["fr", "de"], subtitle_mode="auto", default_audio="de")
        self.assertEqual(retained["default_audio"], "de")
        self.assertEqual(retained["subtitles"], ["fr"])
        removed = ARTE.choose(catalogue, audio_mode="custom", audios=["fr"], subtitle_mode="auto", default_audio="de")
        self.assertEqual(removed["default_audio"], "fr")
        self.assertEqual(removed["subtitles"], [])
        original = ARTE.choose(catalogue, audio_mode="custom", audios=["fr", "de", "ja"], subtitle_mode="auto", default_audio="de")
        self.assertEqual(original["default_audio"], "ja")
        self.assertEqual(original["subtitles"], ["fr"])

    def test_unknown_explicit_default_audio_is_not_replaced_by_original(self):
        catalogue = self.catalogue()
        for key in ("missing", "fr-comfort", "de-acc"):
            with self.subTest(key=key), self.assertRaisesRegex(ARTE.ArteError, "default audio is unavailable or excluded"):
                ARTE.choose(catalogue, audio_mode="custom", audios=["ja", "fr"], subtitle_mode="auto", default_audio=key)

    def test_audio_and_subtitle_modes_are_independent(self):
        catalogue = self.catalogue()
        all_audio = ARTE.choose(catalogue, audio_mode="all", subtitle_mode="none")
        self.assertEqual(set(all_audio["audio"]), {"ja", "fr", "de"})
        self.assertEqual(all_audio["default_audio"], "ja")
        self.assertEqual(all_audio["subtitles"], [])
        all_subtitles = ARTE.choose(catalogue, audio_mode="custom", audios=["fr"], subtitle_mode="all")
        self.assertEqual(all_subtitles["audio"], ["fr"])
        self.assertEqual(len(all_subtitles["subtitles"]), 4)
        _plan, expected, _options = self.apply(catalogue, all_subtitles)
        self.assertEqual(len(expected["subtitles"]), 4)

    def test_custom_choices_and_explicit_subtitle_default_are_preserved(self):
        catalogue = self.catalogue()
        choice = ARTE.choose(catalogue, audio_mode="custom", audios=["fr", "ja"], subtitle_mode="custom",
                             subtitles=["de-forced", "fr"], default_audio="fr", default_subtitle="de-forced")
        self.assertEqual(choice["audio"], ["fr", "ja"])
        self.assertEqual(choice["subtitles"], ["de-forced", "fr"])
        self.assertEqual(choice["default_audio"], "ja")
        self.assertEqual(choice["default_subtitle"], "de-forced")
        ARTE.validate_selection(catalogue, choice)

    def test_multiple_custom_audio_defaults_to_original_not_first_item(self):
        choice = ARTE.choose(self.catalogue(), audio_mode="custom", audios=["fr", "ja"], subtitle_mode="auto")
        self.assertEqual(choice["default_audio"], "ja")
        self.assertEqual(choice["subtitles"], ["fr"])

    def test_automatic_subtitles_follow_selected_audio_default(self):
        choice = ARTE.choose(self.catalogue(), audio_mode="custom", audios=["fr", "ja"], subtitle_mode="auto", default_audio="fr")
        self.assertEqual(choice["default_audio"], "ja")
        self.assertEqual(choice["subtitles"], ["fr"])

    def test_explicit_choices_cannot_be_discarded_by_independent_modes(self):
        with self.assertRaisesRegex(ARTE.ArteError, "require custom"):
            ARTE.choose(self.catalogue(), audio_mode="all", audios=["ja"], subtitle_mode="none")
        with self.assertRaisesRegex(ARTE.ArteError, "require custom"):
            ARTE.choose(self.catalogue(), subtitle_mode="none", subtitles=["de-acc"])

    def test_selection_v1_and_disabled_nonempty_selection_fail_closed(self):
        catalogue = self.catalogue()
        choice = ARTE.choose(catalogue)
        old = {key: value for key, value in choice.items() if key not in ("audio_mode", "subtitle_mode", "messages")}
        old["version"] = 1
        with self.assertRaisesRegex(ARTE.ArteError, "obsolete"):
            ARTE.validate_selection(catalogue, old)
        choice["subtitle_mode"] = "none"
        with self.assertRaisesRegex(ARTE.ArteError, "disabled subtitles"):
            ARTE.validate_selection(catalogue, choice)

    def test_ring_all_exact_admissible_inventory(self):
        catalogue = self.catalogue()
        selection = ARTE.choose(catalogue, "all")
        self.assertEqual(set(selection["audio"]), {"ja", "fr", "de"})
        self.assertEqual(set(selection["subtitles"]), {"fr", "fr-forced", "de", "de-forced"})
        self.assertNotIn("subtitle_aliases_pending", selection["messages"])
        selected, expected, _options = self.apply(catalogue, selection)
        self.assertEqual({item["id"] for item in expected["subtitles"]}, {"fr", "fr-forced", "de", "de-forced"})
        self.assertEqual(selected["arte_selection"]["requested_selection"], selection)
        self.assertEqual(selected["arte_selection"]["subtitle_aliases"], {})
        self.assertEqual(len(catalogue["_private"]["quarantined"]), 1)
        self.assertEqual(catalogue["_private"]["quarantined"][0]["quarantine_reason"], "conflicting_language")
        self.assertFalse(any(url.startswith(OTHER) for url in self.fetch.calls))
        ARTE.validate_plan_provenance(selected, expected)
        self.assertEqual(catalogue["_private"]["excluded"], [{"kind": "subtitle", "id": "de-acc", "role": "hearing_impaired"}])
        self.assertFalse(any("VA-MAL" in url for url in self.fetch.calls))

    def test_generic_dialogue_accessibility_is_not_sdh(self):
        catalogue = self.catalogue()
        self.assertIn("fr", [item["id"] for item in catalogue["subtitles"]])

    def test_full_and_forced_are_distinct(self):
        catalogue = self.catalogue()
        self.assertEqual({item["role"] for item in catalogue["subtitles"] if item["language"] == "fr"}, {"full", "forced"})

    def test_missing_audio_fails_without_fallback(self):
        with self.assertRaisesRegex(ARTE.ArteError, "unavailable or excluded"):
            ARTE.choose(self.catalogue(), "custom", ["en"], ["fr"])

    def test_full_missing_does_not_use_forced(self):
        catalogue = self.catalogue()
        catalogue["subtitles"] = [item for item in catalogue["subtitles"] if item["id"] != "fr"]
        with self.assertRaisesRegex(ARTE.ArteError, "forced subtitles are not a replacement"):
            ARTE.choose(catalogue, "original-fr")

    def test_no_subtitles(self):
        catalogue = self.catalogue()
        selection = ARTE.choose(catalogue, "custom", ["ja"], [])
        selected, expected, options = self.apply(catalogue, selection)
        self.assertEqual(expected["subtitles"], [])
        self.assertEqual(selected["subtitles"], {})
        self.assertIn("--no-embed-subs", options["argv"])

    def test_explicit_excluded_selection_fails(self):
        with self.assertRaisesRegex(ARTE.ArteError, "excluded"):
            ARTE.choose(self.catalogue(), "custom", ["ja"], ["de-acc"])

    def test_preset_does_not_ignore_explicit_excluded_request(self):
        with self.assertRaisesRegex(ARTE.ArteError, "cannot be combined"):
            ARTE.choose(self.catalogue(), "all", [], ["de-acc"])

    def test_mal_fallback_also_applies_to_generic_hls_metadata(self):
        self.resources[MASTER] = self.resources[MASTER].replace(
            b'NAME="allemand (sourds et malentendants)"', b'NAME="allemand"').replace(
            b'CHARACTERISTICS="tv.arte.subtitle.version.va-mal,public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound"',
            b'CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog"')
        catalogue = self.catalogue()
        self.assertNotIn("de-acc", [item["id"] for item in catalogue["subtitles"]])
        _plan, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        self.assertEqual(len(expected["subtitles"]), 4)

    def test_alias_requires_content_proof(self):
        self.resources[OTHER + "text.vtt"] = b"WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nDifferent Japanese text\n"
        catalogue = self.coherent_alias_catalogue()
        self.assertIn("ja-forced", [item["id"] for item in catalogue["subtitles"]])
        self.assertEqual(len(catalogue["subtitles"]), 5)
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        self.assertEqual(len(expected["subtitles"]), 5)
        self.assertEqual(selected["arte_selection"]["subtitle_aliases"], {})
        self.assertEqual(next(item for item in expected["subtitles"] if item["id"] == "ja-forced")["language"], "ja")
        ARTE.validate_plan_provenance(selected, expected)

    def test_alias_order_does_not_replace_full_translation(self):
        manifest = self.resources[MASTER].decode().splitlines()
        alias = manifest.pop()
        manifest.insert(1, alias)
        self.resources[MASTER] = ("\n".join(manifest) + "\n").encode()
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        self.assertEqual({item["id"] for item in expected["subtitles"]}, {"fr", "fr-forced", "de", "de-forced"})
        self.assertEqual(selected["arte_selection"]["subtitle_aliases"], {})

    def test_exact_uri_alias_needs_no_subtitle_download(self):
        self.resources[MASTER] = self.resources[MASTER].replace(OTHER.encode(), BASE.encode())
        self.plan["subtitles"]["ja"][0]["url"] = BASE + "film_st_VO-FRA_id.m3u8"
        catalogue = self.catalogue()
        self.assertIn("fr", [item["id"] for item in catalogue["subtitles"]])
        self.assertNotIn("ja-forced", [item["id"] for item in catalogue["subtitles"]])
        self.assertEqual(len(catalogue["subtitles"]), 4)
        self.assertEqual(self.fetch.calls, [MASTER])
        self.assertFalse(any(url.endswith("text.vtt") for url in self.fetch.calls))

    def test_catalogue_public_choices_have_reliable_languages_and_no_pending_notes(self):
        catalogue = self.catalogue()
        public = ARTE.public_catalogue(catalogue)
        payload = json.dumps(public)
        for forbidden in ("language_uncertain", "quarantined", "quarantine_reason", "possible_alias", "alias_group",
                          "conflicting language", "possible duplicate", "verification pending", "https:"):
            self.assertNotIn(forbidden, payload)
        self.assertEqual({item["id"] for item in public["subtitles"]}, {"fr", "fr-forced", "de", "de-forced"})
        self.assertEqual(self.fetch.calls, [MASTER])
        quarantined = catalogue["_private"]["quarantined"][0]
        self.assertEqual(quarantined["source"]["url"], self.plan["subtitles"]["ja"][0]["url"])
        self.assertNotIn("content_identity", quarantined)

    def test_unknown_subtitle_language_is_private_and_never_selected(self):
        self.plan["subtitles"]["und"] = [{"url": BASE + "unknown-language.m3u8", "ext": "vtt", "protocol": "m3u8_native"}]
        catalogue = self.catalogue()
        self.assertNotIn("und", [item["id"] for item in catalogue["subtitles"]])
        self.assertIn("unidentified_language", [item["quarantine_reason"] for item in catalogue["_private"]["quarantined"]])
        self.assertEqual(len(ARTE.choose(catalogue, "all")["subtitles"]), 4)
        self.assertEqual(self.fetch.calls, [MASTER])

    def test_unknown_subtitle_key_can_use_reliable_manifest_language(self):
        self.plan["subtitles"]["und"] = self.plan["subtitles"].pop("fr")
        catalogue = self.catalogue()
        self.assertIn("fr", [item["id"] for item in catalogue["subtitles"]])
        self.assertEqual(ARTE.choose(catalogue)["subtitles"], ["fr"])

    def test_exact_uri_with_different_headers_does_not_prove_alias(self):
        item = copy.deepcopy(self.plan["subtitles"]["fr"][0])
        item.update(language="fr", http_headers={"X-Test-Scope": "other"})
        # The raw-only branch preserves both requests and their credentials.
        for source in self.plan["formats"]:
            source.pop("manifest_url", None)
        self.plan["subtitles"] = {"fr": [self.plan["subtitles"]["fr"][0], item]}
        catalogue = self.catalogue()
        self.assertEqual(len(catalogue["subtitles"]), 2)
        self.assertEqual(self.fetch.calls, [])

    def test_quarantine_cli_diagnostic_is_bounded_and_does_not_expose_sources(self):
        self.plan["subtitles"]["und"] = [{"url": BASE + "private-unknown.m3u8?token=private-token",
                                          "name": "private-title", "http_headers": {"X-Secret": "private-header"},
                                          "ext": "vtt", "protocol": "m3u8_native"}]
        with tempfile.TemporaryDirectory(prefix="arte-quarantine-test.") as directory:
            plan_path, output_path = Path(directory) / "plan.json", Path(directory) / "catalogue.json"
            ARTE.write_json(plan_path, self.plan)
            diagnostic = io.StringIO()
            previous_umask = os.umask(0o077)
            try:
                with mock.patch.object(ARTE, "Fetcher", return_value=self.fetch), mock.patch.object(sys, "argv", [
                        "private-art-tracks.py", "catalogue", "--plan", str(plan_path), "--output", str(output_path)
                ]), contextlib.redirect_stderr(diagnostic):
                    self.assertEqual(ARTE.main(), 0)
            finally:
                os.umask(previous_umask)
            self.assertEqual(len(ARTE.read_json(output_path)["_private"]["quarantined"]), 2)
        self.assertIn("[TRACK_CATALOGUE]", diagnostic.getvalue())
        self.assertIn("Withheld 2 subtitle source(s)", diagnostic.getvalue())
        self.assertIn("conflicting_language=1; unidentified_language=1", diagnostic.getvalue())
        self.assertLess(len(diagnostic.getvalue()), 256)
        self.assertNotIn("https:", diagnostic.getvalue())
        self.assertNotIn("film_st", diagnostic.getvalue())
        for secret in ("private-unknown", "private-token", "private-title", "private-header", "X-Secret"):
            self.assertNotIn(secret, diagnostic.getvalue())
        self.assertEqual(self.fetch.calls, [MASTER])

    def test_quarantine_diagnostic_accepts_only_bounded_reason_counts(self):
        entries = [{"quarantine_reason": reason, "source": {"url": "private-source"}} for reason in ARTE.QUARANTINE_REASONS]
        diagnostic = ARTE.quarantine_diagnostic(entries)
        self.assertIn("Withheld 3 subtitle source(s)", diagnostic)
        for reason in ARTE.QUARANTINE_REASONS:
            self.assertIn(reason + "=1", diagnostic)
        self.assertNotIn("private-source", diagnostic)
        self.assertLess(len(diagnostic), 256)
        with self.assertRaisesRegex(ARTE.ArteError, "invalid reason") as failure:
            ARTE.quarantine_diagnostic([{"quarantine_reason": "private-injected-reason"}])
        self.assertNotIn("private-injected-reason", str(failure.exception))
        with self.assertRaisesRegex(ARTE.ArteError, "bounded source count"):
            ARTE.quarantine_diagnostic(entries[:1] * (ARTE.MAX_TRACKS * (ARTE.MAX_TRACKS + 4) + 1))

    def test_alias_unavailable_is_clear_failure(self):
        del self.resources[OTHER + "text.vtt"]
        catalogue = self.coherent_alias_catalogue()
        with self.assertRaisesRegex(ARTE.ArteError, "unavailable"):
            self.apply(catalogue, ARTE.choose(catalogue, "all"))

    def test_discovery_and_changing_auto_to_none_never_fetch_subtitle_payload(self):
        catalogue = self.catalogue()
        initial = ARTE.choose(catalogue)
        self.assertEqual(initial["subtitles"], ["fr"])
        all_tracks = ARTE.choose(catalogue, audio_mode="all", subtitle_mode="all")
        self.assertEqual(len(all_tracks["subtitles"]), 4)
        none = ARTE.choose(catalogue, audio_mode="all", subtitle_mode="none")
        selected, expected, _options = self.apply(catalogue, none)
        self.assertEqual(self.fetch.calls, [MASTER])
        self.assertEqual(selected["subtitles"], {})
        self.assertEqual(selected["requested_subtitles"], {})
        self.assertEqual(selected["_arte_sources"]["subtitle_aliases"], [])
        self.assertEqual(expected["subtitles"], [])
        ARTE.validate_plan_provenance(selected, expected)

    def test_none_also_skips_possible_aliases_with_reliable_language(self):
        catalogue = self.coherent_alias_catalogue()
        self.assertEqual(len(ARTE.choose(catalogue, "all")["subtitles"]), 5)
        selection = ARTE.choose(catalogue, audio_mode="all", subtitle_mode="none")
        self.apply(catalogue, selection)
        self.assertEqual(self.fetch.calls, [MASTER])

    def test_selected_full_french_never_fetches_unselected_alias_or_forced(self):
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue))
        self.assertEqual(self.fetch.calls, [MASTER, BASE + "film_st_VO-FRA_id.m3u8"])
        self.assertEqual([item["id"] for item in expected["subtitles"]], ["fr"])
        self.assertIn("hls_media_playlist_data", selected["requested_subtitles"]["fr"])
        self.assertNotIn("hls_media_playlist_data", catalogue["_private"]["subtitles"]["fr"]["source"])

    def test_explicit_uncertain_alias_selection_is_refused(self):
        catalogue = self.catalogue()
        for key in ("und-forced", "ja-forced"):
            with self.subTest(key=key), self.assertRaisesRegex(ARTE.ArteError, "reliably identified"):
                ARTE.choose(catalogue, "custom", ["ja"], [key])
        self.assertEqual(self.fetch.calls, [MASTER])

    def test_alias_default_moves_only_after_proven_identity(self):
        catalogue = self.coherent_alias_catalogue()
        selection = ARTE.choose(catalogue, audio_mode="auto", subtitle_mode="custom",
                                subtitles=["ja-forced", "fr"], default_subtitle="ja-forced")
        selected, expected, _options = self.apply(catalogue, selection)
        self.assertEqual(selected["arte_selection"]["selection"]["default_subtitle"], "fr")
        self.assertEqual(expected["subtitles"][0]["id"], "fr")
        self.assertTrue(expected["subtitles"][0]["default"])
        ARTE.validate_plan_provenance(selected, expected)

    def test_alias_proof_and_original_intent_are_bound(self):
        catalogue = self.coherent_alias_catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        selected["_arte_sources"]["subtitle_aliases"][0]["content_identity"] = "0" * 64
        expected["plan_digest"] = ARTE.canonical_digest(selected)
        with self.assertRaisesRegex(ARTE.ArteError, "identity proof changed"):
            ARTE.validate_plan_provenance(selected, expected)

    def test_requested_subtitle_cannot_be_removed_without_alias_proof(self):
        catalogue = self.coherent_alias_catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        selected["arte_selection"]["subtitle_aliases"] = {}
        selected["_arte_sources"]["subtitle_aliases"] = []
        expected["plan_digest"] = ARTE.canonical_digest(selected)
        with self.assertRaisesRegex(ARTE.ArteError, "resolved subtitles differ"):
            ARTE.validate_plan_provenance(selected, expected)

    def test_excluded_source_cannot_be_admitted_as_removed_alias(self):
        catalogue = self.coherent_alias_catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        selected["_arte_sources"]["subtitle_aliases"][0]["evidence"]["hearing_impaired"] = True
        expected["plan_digest"] = ARTE.canonical_digest(selected)
        with self.assertRaisesRegex(ARTE.ArteError, "hearing-impaired track is forbidden"):
            ARTE.validate_plan_provenance(selected, expected)

    def test_obsolete_catalogue_policy_cannot_authorize_apply_or_resume(self):
        catalogue = self.catalogue()
        selection = ARTE.choose(catalogue)
        selected, expected, _options = self.apply(catalogue, selection)
        catalogue["_private"].pop("catalogue_policy")
        with self.assertRaisesRegex(ARTE.ArteError, "admission policy is obsolete"):
            self.apply(catalogue, selection)
        selected["arte_selection"].pop("catalogue_policy")
        expected["plan_digest"] = ARTE.canonical_digest(selected)
        with self.assertRaisesRegex(ARTE.ArteError, "admission policy is obsolete"):
            ARTE.validate_plan_provenance(selected, expected)

    def test_ambiguous_removed_alias_cannot_reenter_with_consistent_digests(self):
        catalogue = self.coherent_alias_catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        for mutation in ("language_uncertain", "quarantined", "und", "contradiction"):
            with self.subTest(mutation=mutation):
                changed, target = copy.deepcopy(selected), copy.deepcopy(expected)
                entry = changed["_arte_sources"]["subtitle_aliases"][0]
                if mutation == "und":
                    entry["language"] = "und"
                elif mutation == "contradiction":
                    entry["evidence"]["hls"]["LANGUAGE"] = "de"
                    entry["source_identity"] = ARTE.source_identity(entry["source"], entry["evidence"])
                else:
                    entry[mutation] = True
                target["plan_digest"] = ARTE.canonical_digest(changed)
                with self.assertRaisesRegex(ARTE.ArteError, "language is not reliably identified"):
                    ARTE.validate_plan_provenance(changed, target)

    def test_quarantined_track_cannot_reenter_active_selection(self):
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue))
        selected["_arte_sources"]["subtitles"][0]["quarantine_reason"] = "conflicting_language"
        expected["plan_digest"] = ARTE.canonical_digest(selected)
        with self.assertRaisesRegex(ARTE.ArteError, "unreliable subtitle choices"):
            ARTE.validate_plan_provenance(selected, expected)

    def test_old_public_ambiguous_catalogue_is_refused_before_selection(self):
        public = ARTE.public_catalogue(self.catalogue())
        public["subtitles"][0]["language_uncertain"] = True
        with self.assertRaisesRegex(ARTE.ArteError, "unreliable subtitle choices"):
            ARTE.choose(public, "all")

    def test_consistent_checkpoint_digests_cannot_revive_disabled_subtitles(self):
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue))
        for field, digest in (("selection", "selection_digest"), ("requested_selection", "requested_selection_digest")):
            selected["arte_selection"][field]["subtitle_mode"] = "none"
            expected[digest] = ARTE.canonical_digest(selected["arte_selection"][field])
        expected["plan_digest"] = ARTE.canonical_digest(selected)
        with self.assertRaisesRegex(ARTE.ArteError, "disabled subtitles"):
            ARTE.validate_plan_provenance(selected, expected)

    def test_consistent_checkpoint_digests_cannot_revive_selection_v1(self):
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue))
        for field, digest in (("selection", "selection_digest"), ("requested_selection", "requested_selection_digest")):
            selected["arte_selection"][field]["version"] = 1
            expected[digest] = ARTE.canonical_digest(selected["arte_selection"][field])
        expected["plan_digest"] = ARTE.canonical_digest(selected)
        with self.assertRaisesRegex(ARTE.ArteError, "schema is invalid or obsolete"):
            ARTE.validate_plan_provenance(selected, expected)

    def test_verified_summary_reports_resolved_counts_without_private_sources(self):
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        with tempfile.TemporaryDirectory(prefix="arte-summary-test.") as directory:
            plan_path, expected_path = Path(directory) / "plan.json", Path(directory) / "expected.json"
            ARTE.write_json(plan_path, selected)
            ARTE.write_json(expected_path, expected)
            result = subprocess.run([sys.executable, "-B", str(ROOT / "private-art-tracks.py"), "verified-summary",
                                     "--plan", str(plan_path), "--expectation", str(expected_path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("3 audio(s); 4 subtitle(s)", result.stdout)
        self.assertNotIn("https:", result.stdout + result.stderr)
        self.assertNotIn("verification pending", result.stdout)

    def test_different_modes_and_defaults_bind_resume_even_with_same_tracks(self):
        catalogue = self.catalogue()
        automatic = ARTE.choose(catalogue)
        custom = ARTE.choose(catalogue, "custom", ["ja"], ["fr"])
        one, _expected, _opts = self.apply(catalogue, automatic)
        two, _expected, _opts = self.apply(catalogue, custom)
        self.assertNotEqual(ARTE.canonical_digest(one["arte_selection"]), ARTE.canonical_digest(two["arte_selection"]))

    def test_track_language_wins_over_global_version_label(self):
        catalogue = self.catalogue()
        japanese = next(item for item in catalogue["audio"] if item["id"] == "ja")
        self.assertEqual(japanese["language"], "ja")
        self.assertTrue(japanese["original"])

    def test_unicode_ids_are_preserved_in_exact_selector(self):
        catalogue = self.catalogue()
        selected, expected, options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        self.assertIn("VF-STF-audio_0-français", selected["format_id"])
        self.assertEqual(options["argv"][1], selected["format_id"])
        self.assertEqual([item["format_id"] for item in expected["audio"]], [item["format_id"] for item in selected["requested_formats"][1:]])

    def test_existing_video_quality_and_codec_are_preserved(self):
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        self.assertEqual(selected["formats"][0]["height"], 1080)
        self.assertEqual(selected["formats"][0]["vcodec"], "avc1.640028")
        self.assertEqual(expected["video"]["format_id"], "VF-STF-1080")

    def test_technical_audio_variants_collapse_by_own_track_identity(self):
        original = next(item for item in self.plan["formats"] if item.get("language") == "ja")
        self.plan["formats"].append(dict(original, format_id="VO-japonais-haut", abr=256))
        catalogue = self.catalogue()
        self.assertEqual(len(catalogue["audio"]), 3)
        self.assertEqual(catalogue["_private"]["audio"]["ja"]["source"]["format_id"], "VO-japonais-haut")

    def add_audio(self, name, characteristic, suffix):
        item = dict(next(item for item in self.plan["formats"] if item.get("language") == "fr"),
                    format_id="VF-audio-" + suffix, url=BASE + suffix + ".m3u8")
        self.plan["formats"].append(item)
        self.resources[MASTER] += (f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio_0",LANGUAGE="fr",NAME="{name}",CHARACTERISTICS="{characteristic}",URI="{suffix}.m3u8"\n').encode()

    def test_comfort_audio_excluded_but_description_preserved(self):
        self.add_audio("français (confort audio)", "public.accessibility.enhances-speech-intelligibility", "comfort")
        self.add_audio("français (audiodescription)", "public.accessibility.describes-video", "description")
        catalogue = self.catalogue()
        self.assertEqual(len(catalogue["audio"]), 4)
        self.assertIn("fr-description", ARTE.choose(catalogue, "all")["audio"])
        self.assertEqual(len(catalogue["_private"]["excluded"]), 2)

    def test_ambiguous_ordinary_audio_mixes_remain_distinct(self):
        self.add_audio("français (mix cinéma)", "tv.arte.audio.version.vf-fra", "cinema")
        catalogue = self.catalogue()
        french = [item for item in catalogue["audio"] if item["language"] == "fr"]
        self.assertEqual(len(french), 2)
        self.assertTrue(all("variant" in item["label"] for item in french))

    def test_explicit_hearing_role_metadata(self):
        item = next(item for item in self.plan["formats"] if item.get("language") == "de")
        item["roles"] = ["hearing_impaired"]
        self.assertNotIn("de", [item["id"] for item in self.catalogue()["audio"]])

    def test_legacy_raw_subtitle_names_and_mal_path_fallback(self):
        for item in self.plan["formats"]:
            item.pop("manifest_url", None)
        self.plan["subtitles"]["en-SDH"] = [{"url": BASE + "english.vtt", "ext": "vtt"}]
        catalogue = self.catalogue()
        self.assertIn("de-forced", [item["id"] for item in catalogue["subtitles"]])
        self.assertNotIn("en", [item["id"] for item in catalogue["subtitles"]])
        self.assertEqual({item["id"] for item in catalogue["_private"]["excluded"]}, {"de-acc", "en-acc"})

    def test_public_catalogue_contains_no_sources(self):
        public = ARTE.public_catalogue(self.catalogue())
        self.assertNotIn("https:", json.dumps(public))
        self.assertNotIn("_private", public)
        self.assertEqual(ARTE.choose(public, "original-fr")["audio"], ["ja"])

    def test_unmatched_extra_subtitle_is_not_silently_dropped(self):
        self.plan["subtitles"]["en"] = [{"url": BASE + "english.vtt", "ext": "vtt"}]
        self.assertIn("en", [item["id"] for item in self.catalogue()["subtitles"]])

    def test_old_selection_rejected_after_inventory_change(self):
        catalogue = self.catalogue()
        selection = ARTE.choose(catalogue, "all")
        selection["catalogue_id"] = "0" * 64
        with self.assertRaisesRegex(ARTE.ArteError, "inventory changed"):
            self.apply(catalogue, selection)

    def test_unavailable_format_between_catalogue_and_execution(self):
        catalogue = self.catalogue()
        self.plan["formats"].pop()
        with self.assertRaisesRegex(ARTE.ArteError, "source plan changed"):
            self.apply(catalogue, ARTE.choose(catalogue, "all"))

    def test_final_provenance_is_bound_to_exact_plan(self):
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        ARTE.validate_plan_provenance(selected, expected)
        selected["requested_formats"][1]["url"] += "?different-source=1"
        with self.assertRaisesRegex(ARTE.ArteError, "does not match"):
            ARTE.validate_plan_provenance(selected, expected)

    def test_expected_labels_cannot_relabel_frozen_sources(self):
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        for kind in ("audio", "subtitles"):
            for field, replacement in (("language", "it"), ("title", "Unrelated track")):
                with self.subTest(kind=kind, field=field):
                    altered = copy.deepcopy(expected)
                    altered[kind][0][field] = replacement
                    self.assertEqual(altered["plan_digest"], expected["plan_digest"])
                    with self.assertRaisesRegex(ARTE.ArteError, "labels differ from frozen source"):
                        ARTE.validate_plan_provenance(selected, altered)

    def test_consistent_digest_cannot_hide_missing_selected_subtitle(self):
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "original-fr"))
        selected["_arte_sources"]["subtitles"] = []
        selected["requested_subtitles"] = {}
        selected["requested_downloads"][0]["requested_subtitles"] = {}
        expected["subtitles"] = []
        expected["plan_digest"] = ARTE.canonical_digest(selected)
        with self.assertRaisesRegex(ARTE.ArteError, "differ from the explicit selection"):
            ARTE.validate_plan_provenance(selected, expected)

    def test_old_resume_cannot_reintroduce_excluded_source(self):
        catalogue = self.catalogue()
        selected, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        selected["_arte_sources"]["subtitles"][0]["evidence"]["hearing_impaired"] = True
        expected["plan_digest"] = ARTE.canonical_digest(selected)
        with self.assertRaisesRegex(ARTE.ArteError, "forbidden"):
            ARTE.validate_plan_provenance(selected, expected)

    def test_selection_changes_resume_binding(self):
        catalogue = self.catalogue()
        one, _expected, _opts = self.apply(catalogue, ARTE.choose(catalogue, "original-fr"))
        all_tracks, _expected, _opts = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        none, _expected, _opts = self.apply(catalogue, ARTE.choose(catalogue, "custom", ["ja"], []))
        self.assertEqual(len({ARTE.canonical_digest(item["arte_selection"]) for item in (one, all_tracks, none)}), 3)

    def test_selector_metacharacters_rejected_without_rewriting(self):
        self.plan["formats"][-1]["format_id"] = "français+all"
        with self.assertRaisesRegex(ARTE.ArteError, "identifier"):
            self.catalogue()

    def test_resource_replay_has_exact_selected_sources(self):
        catalogue = self.catalogue()
        plan, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        replay = copy.deepcopy(plan)
        replay.pop("webpage_url", None)
        replay.pop("original_url", None)
        replay["formats"] = [{key: value for key, value in item.items() if key not in ("webpage_url", "original_url")}
                             for item in plan["requested_formats"]]
        ARTE.check_replay(plan, replay, expected)
        replay["formats"][1]["url"] = BASE + "forbidden-comfort-audio.m3u8"
        with self.assertRaisesRegex(ARTE.ArteError, "inventory differs"):
            ARTE.check_replay(plan, replay, expected)

    def test_replay_cannot_restore_subtitle_or_extraction_fallback(self):
        catalogue = self.catalogue()
        plan, expected, _options = self.apply(catalogue, ARTE.choose(catalogue, "all"))
        replay = copy.deepcopy(plan)
        replay["webpage_url"] = "https://www.arte.tv/fr/videos/synthetic"
        with self.assertRaisesRegex(ARTE.ArteError, "must not re-extract"):
            ARTE.check_replay(plan, replay, expected)
        replay.pop("webpage_url")
        replay["requested_downloads"][0]["requested_subtitles"]["de-acc"] = {"url": BASE + "film_st_VA-MAL_id.m3u8"}
        with self.assertRaisesRegex(ARTE.ArteError, "provenance changed"):
            ARTE.check_replay(plan, replay, expected)


class PrivateHandoffTests(unittest.TestCase):
    def test_private_json_atomic_no_overwrite_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory(prefix="arte-tracks-test.") as directory:
            path = Path(directory) / "state.json"
            ARTE.write_json(path, {"version": 1})
            self.assertEqual(ARTE.read_json(path), {"version": 1})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(OSError):
                ARTE.write_json(path, {"version": 2})
            self.assertEqual(ARTE.read_json(path), {"version": 1})
            alias = Path(directory) / "alias.json"
            alias.symlink_to(path)
            with self.assertRaises(OSError):
                ARTE.read_json(alias)
            self.assertFalse(list(Path(directory).glob(".arte-state-*")))

    def test_duplicate_json_fields_rejected(self):
        with tempfile.TemporaryDirectory(prefix="arte-tracks-test.") as directory:
            path = Path(directory) / "state.json"
            path.write_text('{"version":1,"version":2}')
            path.chmod(0o600)
            with self.assertRaisesRegex(ARTE.ArteError, "duplicate"):
                ARTE.read_json(path)

    def test_options_reject_free_shell_or_yt_dlp_commands(self):
        with tempfile.TemporaryDirectory(prefix="arte-tracks-test.") as directory:
            path = Path(directory) / "options.json"
            ARTE.write_json(path, {"version": 1, "argv": ["--exec", "touch /tmp/forbidden", "--audio-multistreams", "--no-write-auto-subs"]})
            result = subprocess.run([sys.executable, "-B", str(ROOT / "private-art-tracks.py"), "options", "--options", str(path)], capture_output=True)
            self.assertEqual(result.returncode, 65)
            self.assertEqual(result.stdout, b"")

    def test_cross_origin_redirect_does_not_forward_private_headers(self):
        handler = ARTE.SafeRedirect()
        request = urllib.request.Request(BASE + "master.m3u8", headers={"Authorization": "private-value"})
        with self.assertRaisesRegex(ARTE.ArteError, "private headers"):
            handler.redirect_request(request, None, 302, "Found", {}, OTHER + "master.m3u8")
        public = urllib.request.Request(BASE + "master.m3u8", headers={"User-Agent": "test"})
        redirected = handler.redirect_request(public, None, 302, "Found", {}, OTHER + "master.m3u8")
        self.assertEqual(redirected.full_url, OTHER + "master.m3u8")


if __name__ == "__main__":
    unittest.main()
