# SPDX-License-Identifier: MIT
"""Discover and freeze admissible ARTE tracks for yt-dlp-aria2-downloader-gui.

Repository path: private-arte-tracks.py

The managed extractor remains responsible for video quality and transfer. This
helper reads rendition metadata, applies the hearing-impaired exclusion before
selection, and binds one immutable selection to the native transfer plan.
It is deliberately non-executable; invoke it with python3.
"""

from __future__ import annotations

import argparse
import copy
import ctypes
import hashlib
import json
import math
import os
import re
import secrets
import stat
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


POLICY = "arte-no-hearing-impaired-v1"
CATALOGUE_POLICY = "reliable-subtitle-language-v1"
MAX_JSON = 16 * 1024 * 1024
MAX_MANIFEST = 2 * 1024 * 1024
MAX_SUBTITLE = 8 * 1024 * 1024
MAX_NETWORK = 32 * 1024 * 1024
MAX_TRACKS = 32
KEY_RE = re.compile(r"^[a-z][a-z0-9-]{0,95}$")
FORMAT_RE = re.compile(r"^[\w.:-]{1,128}$")
ATTR_RE = re.compile(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)(?:,|$)')
LANGUAGES = {"fr": "French", "de": "German", "ja": "Japanese", "en": "English",
             "es": "Spanish", "it": "Italian", "pl": "Polish", "pt": "Portuguese",
             "ar": "Arabic", "ru": "Russian", "zh": "Chinese", "ko": "Korean",
             "und": "Undetermined language", "mul": "Multiple languages"}
LANG_CODES = {"fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "all": "de",
              "jpn": "ja", "jap": "ja", "eng": "en", "spa": "es", "ita": "it",
              "pol": "pl", "por": "pt", "ara": "ar", "zho": "zh", "kor": "ko"}
ACCESS_TOKEN = re.compile(r"(?:^|[\s_.()/,:-])(sdh|stsm|sme|mal|hearing[_ -]impaired)(?:$|[\s_.()/,:-])", re.I)
ACCESS_NAME = re.compile(r"\b(?:sourds? et malentendants?|malentendants?|hörgeschädigte|hoergeschaedigte|hörgeschädigten|hearing impaired|hard of hearing)\b", re.I)
COMFORT_NAME = re.compile(r"\b(?:confort audio|audio comfort|clear speech|klare sprache|hörkomfort|hoerkomfort)\b", re.I)
SELECTION_MESSAGES = frozenset(("original_audio_unknown", "original_audio_ambiguous",
                                "audio_language_unknown", "french_full_unavailable",
                                "french_full_ambiguous"))
QUARANTINE_REASONS = ("conflicting_language", "unidentified_language", "unreliable_language")
MESSAGE_TEXT = {
    "original_audio_unknown": "Original audio could not be identified; a deterministic available audio was selected.",
    "original_audio_ambiguous": "Original audio metadata is ambiguous; a deterministic available audio was selected.",
    "audio_language_unknown": "The selected audio language is undetermined; automatic subtitles are disabled.",
    "french_full_unavailable": "Full French subtitles are unavailable; automatic subtitles are disabled. Forced subtitles are not a replacement.",
    "french_full_ambiguous": "Full French subtitle metadata is ambiguous; automatic subtitles are disabled.",
}


class ArteError(Exception):
    """A controlled diagnostic, never containing a private source URL."""


def canonical_digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False, allow_nan=False).encode()).hexdigest()


def private_parent(path: Path) -> int:
    """Return an anchored private parent; callers own the returned descriptor."""
    parent = path.absolute().parent
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for index, component in enumerate((None, *parent.parts[1:])):
            if component is not None:
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
            metadata = os.fstat(descriptor)
            if metadata.st_uid not in (0, os.getuid()):
                raise ArteError("ARTE private file directory is unsafe")
            if metadata.st_mode & 0o022 and not metadata.st_mode & stat.S_ISVTX:
                raise ArteError("ARTE private file directory is writable by another user")
            if index == len(parent.parts) - 1 and (metadata.st_uid != os.getuid() or metadata.st_mode & 0o077):
                raise ArteError("ARTE files require an owner-only directory")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read_json(path: str | Path) -> dict:
    path = Path(path)
    parent = private_parent(path)
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or metadata.st_mode & 0o077 or metadata.st_nlink != 1
                or metadata.st_size > MAX_JSON):
            raise ArteError("ARTE input must be a bounded private regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            payload = source.read(MAX_JSON + 1)
        if len(payload) > MAX_JSON:
            raise ArteError("ARTE input exceeds the size limit")
    finally:
        os.close(descriptor)
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ArteError("ARTE input contains duplicate object keys")
            result[key] = value
        return result
    try:
        value = json.loads(payload, object_pairs_hook=pairs,
                           parse_constant=lambda _value: (_ for _ in ()).throw(ArteError("ARTE input contains a nonfinite number")))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ArteError("ARTE input is not valid bounded JSON") from error
    if not isinstance(value, dict):
        raise ArteError("ARTE input must be a JSON object")
    return value


def write_json(path: str | Path, value: dict | list) -> None:
    path = Path(path)
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode() + b"\n"
    if len(payload) > MAX_JSON:
        raise ArteError("ARTE output exceeds the size limit")
    parent = private_parent(path)
    stage = ".arte-state-" + secrets.token_hex(16)
    created = False
    try:
        descriptor = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
        created = True
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        # The GUI waits for the public catalogue pathname. Linux's no-replace
        # rename publishes one complete inode without a transient second link.
        rename = getattr(ctypes.CDLL(None, use_errno=True), "renameat2", None)
        if rename is None:
            raise ArteError("ARTE private state requires atomic no-overwrite publication")
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(parent, os.fsencode(stage), parent, os.fsencode(path.name), 1) != 0:
            raise OSError(ctypes.get_errno(), "ARTE private state publication failed")
        created = False
    finally:
        if created:
            os.unlink(stage, dir_fd=parent)
        os.close(parent)


def text_value(value: object, *, limit: int = 512) -> str:
    if not isinstance(value, str) or len(value) > limit or any(unicodedata.category(c).startswith("C") for c in value):
        raise ArteError("ARTE track metadata contains invalid text")
    return value


def source_url(value: object) -> str:
    value = text_value(value, limit=8192)
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        raise ArteError("ARTE source requires an HTTP(S) URL without user information")
    return value


def headers(value: object) -> dict:
    if value is None:
        return {}
    if not isinstance(value, dict) or len(value) > 64:
        raise ArteError("ARTE request headers are invalid")
    result = {}
    for key, item in value.items():
        key = text_value(key, limit=128)
        if not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", key):
            raise ArteError("ARTE request header name is invalid")
        result[key] = text_value(item, limit=8192)
    return result


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, response_headers, newurl):
        source_url(newurl)
        old = urllib.parse.urlsplit(request.full_url)
        new = urllib.parse.urlsplit(newurl)
        safe = {"user-agent", "accept", "accept-language", "sec-fetch-mode"}
        if (old.scheme, old.netloc) != (new.scheme, new.netloc) and any(key.lower() not in safe for key, _value in request.header_items()):
            raise ArteError("ARTE refused a cross-origin redirect carrying private headers")
        return super().redirect_request(request, response, code, message, response_headers, newurl)


class Fetcher:
    """Bounded metadata requests in the engine's supervised process group."""

    def __init__(self):
        self.total = 0
        self.deadline = time.monotonic() + 120
        self.cache = {}
        self.opener = urllib.request.build_opener(SafeRedirect())

    def __call__(self, url: str, request_headers: dict, limit: int) -> bytes:
        key = (source_url(url), tuple(sorted(headers(request_headers).items())))
        if key in self.cache:
            return self.cache[key]
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ArteError("ARTE manifest analysis exceeded its deadline; retry the analysis")
        try:
            request = urllib.request.Request(url, headers=request_headers)
            with self.opener.open(request, timeout=min(20, remaining)) as response:
                payload = response.read(limit + 1)
        except (OSError, ValueError, urllib.error.URLError) as error:
            raise ArteError("ARTE rendition is unavailable during analysis; retry or select again") from error
        self.total += len(payload)
        if len(payload) > limit or self.total > MAX_NETWORK:
            raise ArteError("ARTE manifest or subtitle identity proof exceeds the size limit")
        self.cache[key] = payload
        return payload


def hls_text(payload: bytes) -> str:
    try:
        value = payload.decode("utf-8-sig")
    except UnicodeError as error:
        raise ArteError("ARTE manifest is not UTF-8") from error
    if not value.startswith("#EXTM3U") or len(value.splitlines()) > 32768:
        raise ArteError("ARTE source is not a bounded HLS manifest")
    return value


def attributes(line: str) -> dict:
    result = {}
    position = 0
    if len(line) > 16384:
        raise ArteError("ARTE rendition metadata exceeds the line limit")
    while position < len(line):
        match = ATTR_RE.match(line, position)
        if match is None or match[1] in result:
            raise ArteError("ARTE rendition attributes are malformed")
        result[match[1]] = match[2].strip('"')
        position = match.end()
    return result


def language(value: object) -> str:
    value = text_value(value or "und", limit=32).lower().replace("_", "-")
    value = LANG_CODES.get(value, value)
    if not re.fullmatch(r"[a-z]{2,3}(?:-[a-z0-9]{2,8})?", value):
        raise ArteError("ARTE track language is invalid")
    return value


def own_evidence(source: dict, rendition: dict | None = None) -> dict:
    # A format_note describes ARTE's *version*, not the selected audio. Only
    # rendition attributes and track-local fields may establish language/role.
    result = {key: source[key] for key in ("language", "name", "role", "roles", "default", "hearing_impaired", "audio_description", "audio_track") if key in source}
    if rendition:
        result["hls"] = {key: value for key, value in rendition.items() if key != "URI"}
    result["resource_path"] = urllib.parse.urlsplit(source_url(source["url"])).path
    return result


def role_of(evidence: dict, kind: str) -> tuple[str, bool]:
    hls = evidence.get("hls") or {}
    own = evidence.get("audio_track") or {}
    if not isinstance(hls, dict) or not isinstance(own, dict):
        raise ArteError("ARTE track role metadata is invalid")
    name = " ".join(str(item) for item in (hls.get("NAME", ""), evidence.get("name", ""), own.get("name", "")))
    role_values = []
    for value in (evidence.get("role", ""), evidence.get("roles", ""), own.get("role", ""), own.get("roles", "")):
        role_values.extend(value if isinstance(value, list) else [value])
    role = " ".join(str(item) for item in role_values).strip()
    characteristics = str(hls.get("CHARACTERISTICS", "")).lower()
    explicit_hearing = evidence.get("hearing_impaired") is True or own.get("hearing_impaired") is True
    if (explicit_hearing or ACCESS_TOKEN.search(role) or ACCESS_TOKEN.search(characteristics)
            or ACCESS_TOKEN.search(name) or ACCESS_NAME.search(name)):
        return "hearing_impaired", False
    if kind == "subtitle":
        # transcribes-spoken-dialog also appears on ordinary complete ARTE
        # translations. Sound descriptions are the distinguishing SDH role.
        if "public.accessibility.describes-music-and-sound" in characteristics:
            return "hearing_impaired", False
        # Compatibility for extractor versions which collapse VA-MAL into
        # de-forced: this is an ARTE subtitle resource token, not a whole-key
        # filter. Generic FORCED/NAME metadata does not disprove this role;
        # current MAL resources may lack explicit accessibility attributes.
        if re.search(r"(?:_st_[A-Z]{2}|[/-])[-_]MAL(?:_|[./-])", str(evidence.get("resource_path", "")), re.I):
            return "hearing_impaired", False
        forced = hls.get("FORCED") == "YES" or "tv.arte.subtitle.mandatory" in characteristics or role == "forced"
        return ("forced" if forced else "full"), False
    if (COMFORT_NAME.search(name) or COMFORT_NAME.search(role)
            or "enhanced-audio-intelligibility" in characteristics
            or "enhances-speech-intelligibility" in characteristics
            or role in ("comfort", "audio_comfort")):
        return "hearing_impaired", False
    described = (evidence.get("audio_description") is True or own.get("audio_description") is True
                 or "public.accessibility.describes-video" in characteristics
                 or role in ("description", "audio_description")
                 or re.search(r"\b(?:audiodescription|audio description|hörfilm)\b", name, re.I))
    original = bool(re.search(r"tv\.arte\.audio\.version\.vo(?:-|,|$)", characteristics)
                    or own.get("original") is True or role == "original"
                    or re.search(r"\bVO\b", name))
    return ("description" if described else "main"), original


def source_identity(source: dict, evidence: dict) -> str:
    # Retain the complete origin and query: different CDNs or authorization
    # scopes are never assumed to identify the same bytes. Signed-URL renewal
    # can conservatively refuse a resume, but cannot adopt unrelated media.
    return canonical_digest({"url": source_url(source["url"]), "headers": headers(source.get("http_headers")),
                             "format_id": source.get("format_id"), "evidence": evidence,
                             "hls_manifest": canonical_digest(source["hls_media_playlist_data"]) if source.get("hls_media_playlist_data") else None})


def track_title(lang: str, role: str, original: bool = False) -> str:
    suffix = {"main": "original audio" if original else "audio", "description": "audio description",
              "full": "full subtitles", "forced": "forced subtitles"}[role]
    return f"{LANGUAGES.get(lang, lang)} — {suffix}"


def subtitle_language_issue(entry: dict) -> str | None:
    """Reject unknown or contradictory track-local language evidence."""
    if entry.get("language_uncertain") or entry.get("quarantined") or entry.get("quarantine_reason"):
        return "unreliable_language"
    lang = language(entry.get("language"))
    if lang.partition("-")[0] in ("und", "mul", "zxx"):
        return "unidentified_language"
    evidence = entry.get("evidence") or {}
    hls = evidence.get("hls") or {}
    languages = {lang.partition("-")[0]}
    for declared in (evidence.get("language"), hls.get("LANGUAGE")):
        if declared:
            normalized = language(declared).partition("-")[0]
            if normalized != "und":
                languages.add(normalized)
    characteristics = str(hls.get("CHARACTERISTICS", ""))
    for declared in re.findall(r"(?:^|,)tv\.arte\.subtitle\.version\.[a-z]+-([a-z]{3})(?=,|$)", characteristics, re.I):
        if declared.lower() in LANG_CODES:
            languages.add(language(declared))
    return "conflicting_language" if len(languages) != 1 else None


def audio_language_reliable(lang: str, evidence: dict) -> bool:
    """Unknown and contradictory spoken languages cannot trigger translation."""
    base = language(lang).partition("-")[0]
    if base in ("und", "mul", "zxx"):
        return False
    hls = evidence.get("hls") or {}
    own = evidence.get("audio_track") or {}
    return all(not declared or language(declared).partition("-")[0] == base
               for declared in (evidence.get("language"), hls.get("LANGUAGE"), own.get("language")))


def quarantine_diagnostic(entries: list) -> str:
    """Expose only bounded counts and fixed reason codes, never source data."""
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_TRACKS * (MAX_TRACKS + 4):
        raise ArteError("ARTE quarantine diagnostic requires a bounded source count")
    counts = {reason: 0 for reason in QUARANTINE_REASONS}
    for entry in entries:
        reason = entry.get("quarantine_reason") if isinstance(entry, dict) else None
        if not isinstance(reason, str) or reason not in counts:
            raise ArteError("ARTE quarantine diagnostic contains an invalid reason")
        counts[reason] += 1
    reasons = "; ".join(f"{reason}={count}" for reason, count in counts.items() if count)
    return (f"[TRACK_CATALOGUE] Withheld {len(entries)} subtitle source(s): {reasons}; "
            "details retained in private session state.")


def subtitle_content(source: dict, fetch) -> str:
    url = source_url(source["url"])
    request_headers = headers(source.get("http_headers"))
    frozen = source.get("hls_media_playlist_data")
    payload = frozen.encode() if isinstance(frozen, str) else fetch(url, request_headers, MAX_SUBTITLE)
    if not payload.startswith(b"#EXTM3U"):
        if not payload.lstrip(b"\xef\xbb\xbf").startswith(b"WEBVTT"):
            raise ArteError("ARTE subtitle alias identity is not a WebVTT resource")
        return hashlib.sha256(payload).hexdigest()
    manifest = hls_text(payload)
    if "#EXT-X-ENDLIST" not in manifest or "#EXT-X-KEY" in manifest:
        raise ArteError("ARTE subtitle alias requires a finite unencrypted rendition")
    segments = [line.strip() for line in manifest.splitlines() if line.strip() and not line.startswith("#")]
    if not 1 <= len(segments) <= 128:
        raise ArteError("ARTE subtitle alias has an unsupported segment count")
    digest = hashlib.sha256()
    size = 0
    for segment in segments:
        payload = fetch(urllib.parse.urljoin(url, segment), request_headers, MAX_SUBTITLE)
        size += len(payload)
        if size > MAX_SUBTITLE or not payload.lstrip(b"\xef\xbb\xbf").startswith(b"WEBVTT"):
            raise ArteError("ARTE subtitle alias identity cannot be established")
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def selected_root(plan: dict) -> dict:
    downloads = plan.get("requested_downloads")
    if not isinstance(downloads, list) or len(downloads) != 1 or not isinstance(downloads[0], dict):
        raise ArteError("ARTE planning requires exactly one selected download")
    root = {key: value for key, value in plan.items() if key not in ("formats", "requested_downloads")}
    root.update(downloads[0])
    return root


def build_catalogue(plan: dict, fetch=None) -> dict:
    if plan.get("extractor_key") not in ("ArteTV", "ArteTVEmbed") and plan.get("extractor") not in ("ArteTV", "arte:tv", "arte"):
        raise ArteError("ARTE track selection requires an ARTE video")
    formats = plan.get("formats")
    if not isinstance(formats, list) or not 1 <= len(formats) <= 512 or any(not isinstance(item, dict) for item in formats):
        raise ArteError("ARTE format inventory is invalid")
    fetch = fetch or Fetcher()
    request_headers = headers(plan.get("http_headers"))
    manifest_urls = list(dict.fromkeys(source_url(item["manifest_url"]) for item in formats if item.get("manifest_url")))
    if len(manifest_urls) > 16:
        raise ArteError("ARTE has too many master manifests")
    renditions = {"audio": [], "subtitle": []}
    for url in manifest_urls:
        for line in hls_text(fetch(url, request_headers, MAX_MANIFEST)).splitlines():
            if not line.startswith("#EXT-X-MEDIA:"):
                continue
            attrs = attributes(line.partition(":")[2])
            kind = {"AUDIO": "audio", "SUBTITLES": "subtitle"}.get(attrs.get("TYPE"))
            if kind and attrs.get("URI"):
                attrs["URI"] = source_url(urllib.parse.urljoin(url, attrs["URI"]))
                if attrs not in renditions[kind]:
                    renditions[kind].append(attrs)
    if any(len(items) > MAX_TRACKS * 4 for items in renditions.values()):
        raise ArteError("ARTE rendition inventory exceeds its limit")

    audio = []
    excluded = []
    groups = {}
    for item in formats:
        if item.get("vcodec") != "none":
            continue
        fmt_id = item.get("format_id")
        if not isinstance(fmt_id, str) or not FORMAT_RE.fullmatch(fmt_id):
            raise ArteError("ARTE audio format identifier is not representable")
        source = copy.deepcopy(item)
        source["http_headers"] = headers(source.get("http_headers") or request_headers)
        matches = [entry for entry in renditions["audio"] if entry["URI"] == source.get("url")]
        if len(matches) > 1:
            # Multiple groups may offer the same rendition; conflicting roles
            # on one exact source must not be guessed away.
            identities = {canonical_digest({k: v for k, v in entry.items() if k != "GROUP-ID"}) for entry in matches}
            if len(identities) != 1:
                raise ArteError("ARTE audio has conflicting rendition metadata")
        rendition = matches[0] if matches else None
        evidence = own_evidence(source, rendition)
        role, original = role_of(evidence, "audio")
        lang = language(source.get("language") or (rendition or {}).get("LANGUAGE"))
        if role == "hearing_impaired":
            excluded.append({"kind": "audio", "id": fmt_id, "role": role})
            continue
        # Group only explicit track identity. Language alone would silently
        # collapse distinct mixes, commentary or alternate admissible roles.
        own = source.get("audio_track") or {}
        semantic = (rendition or {}).get("CHARACTERISTICS") or own.get("id")
        name = (rendition or {}).get("NAME") or own.get("name") or source.get("name")
        group = (lang, role, original, semantic, name) if semantic or name else (source_identity(source, evidence),)
        explicit_default = ((rendition or {}).get("DEFAULT") == "YES" or own.get("default") is True
                            or source.get("default") is True)
        value = {"language": lang, "language_reliable": audio_language_reliable(lang, evidence),
                 "role": role, "original": original, "default": explicit_default, "source": source,
                 "evidence": evidence, "source_identity": source_identity(source, evidence)}
        # yt-dlp's sorted inventory is authoritative for technical quality.
        groups[group] = value
    audio = list(groups.values())

    raw_subtitles = plan.get("subtitles") or {}
    if not isinstance(raw_subtitles, dict) or len(raw_subtitles) > MAX_TRACKS:
        raise ArteError("ARTE subtitle inventory is invalid")
    raw_sources = []
    for raw_key, entries in raw_subtitles.items():
        text_value(raw_key, limit=96)
        if not isinstance(entries, list) or len(entries) > MAX_TRACKS:
            raise ArteError("ARTE subtitle variants are invalid")
        for entry in entries:
            if not isinstance(entry, dict):
                raise ArteError("ARTE subtitle variant is invalid")
            raw_sources.append((raw_key, entry))
    subtitle_entries = []
    if renditions["subtitle"]:
        represented = set()
        for rendition in renditions["subtitle"]:
            matches = [(key, entry) for key, entry in raw_sources if entry.get("url") == rendition["URI"]]
            if matches:
                raw_key, raw_source = matches[-1]
                source = copy.deepcopy(raw_source)
            else:
                raw_key = rendition.get("LANGUAGE", "und")
                source = {"url": rendition["URI"], "ext": "vtt", "protocol": "m3u8_native"}
            subtitle_entries.append((raw_key, source, rendition))
            represented.add(rendition["URI"])
        # A future extractor may expose another admissible subtitle outside
        # these masters. Preserve it with its own metadata, rather than silently
        # dropping a distinct source merely because it lacks an HLS match.
        subtitle_entries.extend((key, copy.deepcopy(source), None) for key, source in raw_sources
                                if source.get("url") not in represented)
    else:
        subtitle_entries = [(key, copy.deepcopy(source), None) for key, source in raw_sources]
    subtitles = []
    seen = set()
    for raw_key, source, rendition in subtitle_entries:
        source["http_headers"] = headers(source.get("http_headers") or request_headers)
        evidence = own_evidence(source, rendition)
        if not rendition and raw_key.endswith("-forced"):
            evidence.setdefault("role", "forced")
        if not rendition and re.search(r"-(?:acc|sdh|stsm|sme|mal)$", raw_key, re.I):
            evidence["role"] = "hearing_impaired"
        role, _original = role_of(evidence, "subtitle")
        lang = language((rendition or {}).get("LANGUAGE") or source.get("language") or raw_key.split("-")[0])
        if role == "hearing_impaired":
            excluded.append({"kind": "subtitle", "id": f"{lang}-acc", "role": role})
            continue
        identity = source_identity(source, evidence)
        if identity in seen:
            continue
        seen.add(identity)
        subtitles.append({"language": lang, "role": role, "forced": role == "forced", "source": source,
                          "evidence": evidence, "source_identity": identity})
    # Discovery is metadata-only: a provisional automatic subtitle choice may
    # still be disabled before confirmation. Equal URLs and headers establish
    # exact resource aliases without downloading any subtitle body. Similar
    # paths on different origins provide no proof and cannot merge resources.
    by_path = {}
    for item in subtitles:
        by_path.setdefault(item["evidence"]["resource_path"], []).append(item)
    remove = set()
    for candidates in by_path.values():
        if len(candidates) < 2:
            continue
        exact_sources = {}
        for item in candidates:
            identity = canonical_digest({"url": item["source"]["url"], "headers": item["source"]["http_headers"]})
            exact_sources.setdefault(identity, []).append(item)
        for identical in exact_sources.values():
            if len(identical) < 2:
                continue
            # A full translation wins over its misleading forced alias, but
            # genuinely different full/forced resources remain separate.
            canonical = min(identical, key=lambda item: (subtitle_language_issue(item) is not None,
                                                       item["role"] != "full", item["language"]))
            for item in identical:
                if item is not canonical:
                    remove.add(id(item))
    subtitles = [item for item in subtitles if id(item) not in remove]
    quarantined = []
    for item in subtitles:
        issue = subtitle_language_issue(item)
        if issue:
            item["quarantine_reason"] = issue
            quarantined.append(item)
    subtitles = [item for item in subtitles if not item.get("quarantine_reason")]
    if not 1 <= len(audio) <= 15 or len(subtitles) > MAX_TRACKS:
        raise ArteError("ARTE requires between one and fifteen admissible audios and bounded subtitles")
    private = {"audio": {}, "subtitles": {}, "excluded": excluded, "quarantined": quarantined,
               "catalogue_policy": CATALOGUE_POLICY, "raw_plan_digest": canonical_digest(plan)}
    public = {"version": 1, "policy": POLICY, "audio": [], "subtitles": []}
    for kind, items in (("audio", audio), ("subtitles", subtitles)):
        counts = {}
        for item in items:
            base = item["language"]
            if item["role"] == "description":
                base += "-description"
            elif item["role"] == "forced":
                base += "-forced"
            counts[base] = counts.get(base, 0) + 1
            item["base"] = base
        for item in items:
            key = item.pop("base")
            title = track_title(item["language"], item["role"], item.get("original", False))
            if counts[key] > 1:
                suffix = item["source_identity"][:10]
                key += "-" + suffix
                title += f" (variant {suffix})"
            if not KEY_RE.fullmatch(key):
                raise ArteError("ARTE normalized track identifier is invalid")
            item["id"] = key
            item["label"] = title
            private[kind][key] = item
            public[kind].append({field: item[field] for field in ("id", "label", "language", "language_reliable", "role", "original", "forced", "default") if field in item})
    for items in (public["audio"], public["subtitles"]):
        items.sort(key=lambda item: (not item.get("original", False), item["language"], item["role"], item["id"]))
    public["id"] = canonical_digest({"catalogue_policy": CATALOGUE_POLICY,
                                     "media": {key: plan.get(key) for key in ("id", "extractor", "extractor_key")},
                                     "tracks": public,
                                     "sources": {kind: {key: value["source_identity"] for key, value in private[kind].items()} for kind in ("audio", "subtitles")}})
    public["_private"] = private
    return public


def public_catalogue(catalogue: dict) -> dict:
    validate_catalogue(catalogue)
    return {key: copy.deepcopy(catalogue[key]) for key in ("version", "policy", "id", "audio", "subtitles")}


def validate_catalogue(catalogue: dict) -> None:
    if catalogue.get("version") != 1 or catalogue.get("policy") != POLICY or not re.fullmatch(r"[0-9a-f]{64}", str(catalogue.get("id", ""))):
        raise ArteError("ARTE catalogue is obsolete or invalid; analyse the URL again")
    for kind in ("audio", "subtitles"):
        entries = catalogue.get(kind)
        if not isinstance(entries, list) or len(entries) > MAX_TRACKS:
            raise ArteError("ARTE catalogue has invalid track arrays")
        seen = set()
        for item in entries:
            if not isinstance(item, dict) or not KEY_RE.fullmatch(str(item.get("id", ""))) or item["id"] in seen:
                raise ArteError("ARTE catalogue has invalid track identifiers")
            seen.add(item["id"])
            if item.get("role") not in (("main", "description") if kind == "audio" else ("full", "forced")):
                raise ArteError("ARTE hearing-impaired tracks are excluded; analyse and select again")
            language(item.get("language"))
            text_value(item.get("label"), limit=256)
            if any(field in item for field in ("language_uncertain", "possible_alias", "alias_group", "quarantined", "quarantine_reason")):
                raise ArteError("ARTE catalogue contains obsolete or unreliable subtitle choices; analyse again")
            if kind == "subtitles" and subtitle_language_issue(item):
                raise ArteError("ARTE subtitle language is not reliably identified; analyse and select again")
            if any(field in item and not isinstance(item[field], bool) for field in ("original", "forced", "default", "language_reliable")):
                raise ArteError("ARTE catalogue track flags are invalid")
    if not catalogue["audio"]:
        raise ArteError("ARTE has no admissible audio")


def preferred_audio(entries: list[dict]) -> dict:
    """Choose deterministically using track-local original/default evidence."""
    originals = [item["id"] for item in entries if item["role"] == "main" and item.get("original") is True]
    original = originals[0] if len(originals) == 1 else None
    return min(entries, key=lambda item: (item["role"] != "main", item["id"] != original,
                                          item["language"].partition("-")[0] != "fr", not item.get("default", False),
                                          item["language"], item["id"]))


def choose(catalogue: dict, preset: str | None = None, audios=None, subtitles=None, *,
           audio_mode: str | None = None, subtitle_mode: str | None = None,
           default_audio: str | None = None, default_subtitle: str | None = None) -> dict:
    validate_catalogue(catalogue)
    if default_audio is not None and (not isinstance(default_audio, str)
                                      or default_audio not in {item["id"] for item in catalogue["audio"]}):
        raise ArteError("ARTE requested default audio is unavailable or excluded; select again")
    if preset is not None and (audio_mode is not None or subtitle_mode is not None):
        raise ArteError("ARTE presets and independent selection modes cannot be combined")
    if preset is not None and preset != "custom" and (audios or subtitles):
        raise ArteError("ARTE explicit track choices cannot be combined with a preset")
    messages = []
    if preset == "all":
        audio_mode, subtitle_mode = "all", "all"
    elif preset == "original-fr":
        audio_mode, subtitle_mode = "custom", "custom"
        audios = [item["id"] for item in catalogue["audio"] if item.get("original") is True and item["role"] == "main"]
        subtitles = [item["id"] for item in catalogue["subtitles"] if item["language"].partition("-")[0] == "fr" and item["role"] == "full"]
        if len(audios) != 1 or len(subtitles) != 1:
            raise ArteError("ARTE original audio and full French subtitles are unavailable or ambiguous; forced subtitles are not a replacement")
    elif preset == "custom":
        audio_mode, subtitle_mode = "custom", "custom"
    elif preset is not None:
        raise ArteError("ARTE selection preset is invalid")
    audio_mode, subtitle_mode = audio_mode or "auto", subtitle_mode or "auto"
    if audio_mode not in ("auto", "all", "custom") or subtitle_mode not in ("auto", "none", "all", "custom"):
        raise ArteError("ARTE independent selection mode is invalid")
    if (audio_mode != "custom" and audios) or (subtitle_mode != "custom" and subtitles):
        raise ArteError("ARTE explicit track choices require custom selection mode")
    if audio_mode == "all":
        audios = [item["id"] for item in catalogue["audio"]]
    elif audio_mode == "auto":
        originals = [item for item in catalogue["audio"] if item["role"] == "main" and item.get("original") is True]
        if len(originals) != 1:
            messages.append("original_audio_ambiguous" if originals else "original_audio_unknown")
        audios = [preferred_audio(catalogue["audio"])["id"]]
    audios = list(audios or [])
    selected_audio = [item for item in catalogue["audio"] if item["id"] in audios]
    originals = [item["id"] for item in selected_audio if item["role"] == "main" and item.get("original") is True]
    if len(originals) == 1:
        default_audio = originals[0]
    elif selected_audio and default_audio not in audios:
        default_audio = preferred_audio(selected_audio)["id"]
    if subtitle_mode == "all":
        subtitles = [item["id"] for item in catalogue["subtitles"]]
    elif subtitle_mode == "none":
        subtitles = []
    elif subtitle_mode == "auto":
        subtitles = []
        primary = next((item for item in selected_audio if item["id"] == default_audio), {})
        spoken = primary.get("language", "und")
        if spoken.partition("-")[0] in ("und", "mul", "zxx") or primary.get("language_reliable") is False:
            messages.append("audio_language_unknown")
        elif spoken.partition("-")[0] != "fr":
            full_french = [item for item in catalogue["subtitles"] if item["language"].partition("-")[0] == "fr" and item["role"] == "full"]
            if len(full_french) == 1:
                subtitles = [full_french[0]["id"]]
            else:
                messages.append("french_full_ambiguous" if full_french else "french_full_unavailable")
    subtitles = list(subtitles or [])
    if default_subtitle is None:
        default_subtitle = next((item["id"] for item in catalogue["subtitles"] if item["id"] in subtitles and item["role"] == "full"), subtitles[0] if subtitles else None)
    result = {"version": 2, "catalogue_id": catalogue["id"], "audio_mode": audio_mode, "subtitle_mode": subtitle_mode,
              "audio": audios, "subtitles": subtitles, "default_audio": default_audio,
              "default_subtitle": default_subtitle, "messages": messages}
    validate_selection(catalogue, result)
    return result


def validate_selection(catalogue: dict, selection: dict) -> None:
    validate_catalogue(catalogue)
    if set(selection) != {"version", "catalogue_id", "audio_mode", "subtitle_mode", "audio", "subtitles", "default_audio", "default_subtitle", "messages"} or selection.get("version") != 2:
        raise ArteError("ARTE selection schema is invalid or obsolete; select the tracks again")
    if selection["audio_mode"] not in ("auto", "all", "custom") or selection["subtitle_mode"] not in ("auto", "none", "all", "custom"):
        raise ArteError("ARTE independent selection mode is invalid")
    messages = selection["messages"]
    if (not isinstance(messages, list) or len(messages) > len(SELECTION_MESSAGES)
            or any(not isinstance(item, str) or item not in SELECTION_MESSAGES for item in messages)
            or len(messages) != len(set(messages))):
        raise ArteError("ARTE selection messages are invalid")
    if selection.get("catalogue_id") != catalogue["id"]:
        raise ArteError("ARTE inventory changed; analyse and select the tracks again")
    for kind in ("audio", "subtitles"):
        choices = selection.get(kind)
        available = {item["id"] for item in catalogue[kind]}
        if not isinstance(choices, list) or len(choices) > MAX_TRACKS or any(not isinstance(item, str) for item in choices) or len(choices) != len(set(choices)):
            raise ArteError("ARTE selection must contain distinct track identifiers")
        if any(item not in available for item in choices):
            raise ArteError("ARTE requested track is unavailable or excluded, or its language could not be reliably identified; select again")
    if not 1 <= len(selection["audio"]) <= 15 or selection["default_audio"] not in selection["audio"]:
        raise ArteError("ARTE requires an admissible audio and a selected default audio")
    default = selection["default_subtitle"]
    if default is not None and default not in selection["subtitles"]:
        raise ArteError("ARTE default subtitle must belong to the selection")
    if selection["subtitle_mode"] == "none" and (selection["subtitles"] or default is not None):
        raise ArteError("ARTE disabled subtitles must have an empty selection")


def duration(value: object) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0:
        return float(value)
    return None


def resolve_subtitles(private: dict, selection: dict, fetch) -> tuple[dict, dict, list, dict]:
    """Freeze and compare only finally selected, admissible subtitle sources."""
    resolved = {}
    for key in selection["subtitles"]:
        entry = copy.deepcopy(private["subtitles"][key])
        if subtitle_language_issue(entry):
            raise ArteError("ARTE subtitle language is not reliably identified; analyse and select again")
        source = entry["source"]
        role, _original = role_of(entry["evidence"], "subtitle")
        if role == "hearing_impaired" or role != entry["role"] or source_identity(source, entry["evidence"]) != entry["source_identity"]:
            raise ArteError("ARTE selected source is excluded or changed; analyse and select again")
        if source.get("protocol") in ("m3u8", "m3u8_native"):
            # Native HlsFD later consumes this frozen playlist. In particular,
            # none/empty selections never enter this branch or fetch a body.
            source["hls_media_playlist_data"] = hls_text(fetch(source["url"], source["http_headers"], MAX_MANIFEST))
            entry["source_identity"] = source_identity(source, entry["evidence"])
        resolved[key] = entry
    groups = {}
    for entry in resolved.values():
        groups.setdefault(entry["evidence"]["resource_path"], []).append(entry)
    aliases = {}
    removed = []
    for candidates in groups.values():
        if len(candidates) < 2:
            continue
        contents = {}
        for entry in candidates:
            entry["content_identity"] = subtitle_content(entry["source"], fetch)
            contents.setdefault(entry["content_identity"], []).append(entry)
        for identical in contents.values():
            canonical = min(identical, key=lambda item: (item["role"] != "full", item["language"], item["id"]))
            for entry in identical:
                if entry is not canonical:
                    aliases[entry["id"]] = canonical["id"]
                    removed.append(entry)
                    del resolved[entry["id"]]
    effective = copy.deepcopy(selection)
    effective["subtitles"] = [key for key in selection["subtitles"] if key not in aliases]
    effective["default_subtitle"] = aliases.get(selection["default_subtitle"], selection["default_subtitle"])
    return resolved, effective, removed, aliases


def apply_selection(plan: dict, catalogue: dict, selection: dict, fetch=None) -> tuple[dict, dict, dict]:
    validate_selection(catalogue, selection)
    private = catalogue.get("_private")
    if not isinstance(private, dict) or private.get("raw_plan_digest") != canonical_digest(plan):
        raise ArteError("ARTE source plan changed after discovery; analyse and select again")
    if private.get("catalogue_policy") != CATALOGUE_POLICY:
        raise ArteError("ARTE catalogue admission policy is obsolete; analyse and select again")
    requested_selection = copy.deepcopy(selection)
    private = copy.deepcopy(private)
    for kind in ("audio", "subtitles"):
        for key in selection[kind]:
            entry = private[kind][key]
            if kind == "subtitles" and subtitle_language_issue(entry):
                raise ArteError("ARTE subtitle language is not reliably identified; analyse and select again")
            role, _original = role_of(entry["evidence"], "audio" if kind == "audio" else "subtitle")
            if (role == "hearing_impaired" or role != entry["role"]
                    or source_identity(entry["source"], entry["evidence"]) != entry["source_identity"]):
                raise ArteError("ARTE selected source is excluded or changed; analyse and select again")
    resolved, selection, removed, aliases = resolve_subtitles(private, selection, fetch or Fetcher())
    private["subtitles"] = resolved
    root = selected_root(plan)
    original_formats = root.get("requested_formats") or [root]
    videos = [item for item in original_formats if item.get("vcodec") not in (None, "none")]
    if len(videos) != 1 or videos[0].get("acodec") not in (None, "none"):
        raise ArteError("ARTE selection requires one separately selectable main video")
    video = copy.deepcopy(videos[0])
    if not FORMAT_RE.fullmatch(str(video.get("format_id", ""))):
        raise ArteError("ARTE video format identifier is not representable")
    video_evidence = own_evidence(video)
    selected_formats = [video]
    selected_subs = {}
    sources = {"video": {"source": video, "evidence": video_evidence}, "audio": [], "subtitles": [], "subtitle_aliases": removed}
    expected = {"version": 1, "policy": POLICY, "video": {"format_id": video["format_id"], "source_identity": source_identity(video, video_evidence),
                "duration": duration(video.get("duration")) or duration(plan.get("duration"))}, "audio": [], "subtitles": [],
                "selection_digest": canonical_digest(selection), "requested_selection_digest": canonical_digest(requested_selection)}
    for kind in ("audio", "subtitles"):
        for key in selection[kind]:
            entry = copy.deepcopy(private[kind][key])
            source = entry["source"]
            role, original = role_of(entry["evidence"], "audio" if kind == "audio" else "subtitle")
            if role == "hearing_impaired" or role != entry["role"] or source_identity(source, entry["evidence"]) != entry["source_identity"]:
                raise ArteError("ARTE selected source is excluded or changed; analyse and select again")
            target = {"id": key, "language": entry["language"], "role": role, "title": entry["label"],
                      "default": selection["default_audio" if kind == "audio" else "default_subtitle"] == key,
                      "source_identity": entry["source_identity"]}
            if kind == "audio":
                target.update(format_id=source["format_id"], original=original,
                              duration=duration(source.get("duration")) or duration(plan.get("duration")))
                selected_formats.append(source)
            else:
                target["forced"] = role == "forced"
                source["name"] = entry["label"]
                selected_subs[key] = [source]
            expected[kind].append(target)
            sources[kind].append(entry)
    if len({item["format_id"] for item in selected_formats}) != len(selected_formats):
        raise ArteError("ARTE selected formats do not have distinct identifiers")
    # Build one complete root: stale selected-download delta fields must not
    # override this selection during replay. The video remains exactly the
    # extractor's original best-video choice, without a codec/resolution cap.
    result = copy.deepcopy(plan)
    result.update(root)
    result["formats"] = selected_formats
    result["requested_formats"] = selected_formats
    result["format_id"] = "+".join(item["format_id"] for item in selected_formats)
    result["ext"] = "mkv"
    result["protocol"] = "+".join(str(item.get("protocol", "")) for item in selected_formats)
    result["subtitles"] = selected_subs
    result["requested_subtitles"] = {key: values[0] for key, values in selected_subs.items()}
    result["automatic_captions"] = {}
    result["_arte_sources"] = sources
    result["arte_selection"] = {"version": 2, "policy": POLICY, "selection": selection,
                                "catalogue_policy": CATALOGUE_POLICY,
                                "requested_selection": requested_selection, "subtitle_aliases": aliases,
                                "sources": {"video": expected["video"]["source_identity"],
                                            "audio": [item["source_identity"] for item in expected["audio"]],
                                            "subtitles": [item["source_identity"] for item in expected["subtitles"]]},
                                "postprocess": "srt-reference-copyts-mkv-v2",
                                "subtitle_policy": "webvtt-source-cues-mpegts-v1"}
    result["requested_downloads"] = [{"format_id": result["format_id"], "requested_formats": selected_formats,
                                     "ext": "mkv", "protocol": result["protocol"],
                                     "requested_subtitles": result["requested_subtitles"]}]
    expected["plan_digest"] = canonical_digest(result)
    # mergeall reverses the sorted format order in yt-dlp. Exact discovered
    # identifiers preserve the selected audio order, which the media validator
    # binds to stream order. FORMAT_RE excludes every selector metacharacter.
    args = ["--format", result["format_id"], "--audio-multistreams", "--no-write-auto-subs"]
    # Native subtitles are acquired and verified in a separate private stage
    # under the same engine supervision. The media pass must never redownload
    # or convert them through yt-dlp's unchecked FFmpeg subtitle processor.
    args += ["--no-write-subs", "--no-embed-subs"]
    return result, expected, {"version": 1, "argv": args}


def validate_plan_provenance(plan: dict, expected: dict) -> None:
    clean = {key: value for key, value in plan.items() if key != "_arte_expected"}
    if expected.get("policy") != POLICY or expected.get("plan_digest") != canonical_digest(clean):
        raise ArteError("ARTE executed plan does not match the validation expectation")
    binding = plan.get("arte_selection") or {}
    sources = plan.get("_arte_sources") or {}
    if (binding.get("version") != 2 or binding.get("policy") != POLICY
            or canonical_digest(binding.get("selection")) != expected.get("selection_digest")
            or canonical_digest(binding.get("requested_selection")) != expected.get("requested_selection_digest")):
        raise ArteError("ARTE selection provenance is obsolete or invalid")
    if binding.get("catalogue_policy") != CATALOGUE_POLICY:
        raise ArteError("ARTE catalogue admission policy is obsolete; analyse and select again")
    if binding.get("postprocess") != "srt-reference-copyts-mkv-v2" or binding.get("subtitle_policy") != "webvtt-source-cues-mpegts-v1":
        raise ArteError("ARTE postprocessing provenance is obsolete; analyse and select again")
    selection = binding["selection"]
    requested = binding["requested_selection"]
    if not isinstance(selection, dict) or not isinstance(requested, dict):
        raise ArteError("ARTE selection provenance is invalid")
    aliases = binding.get("subtitle_aliases")
    removed = sources.get("subtitle_aliases")
    if (not isinstance(aliases, dict) or not isinstance(removed, list)
            or len(aliases) != len(removed) or len(aliases) > MAX_TRACKS):
        raise ArteError("ARTE subtitle alias proof is invalid")
    preserved = ("version", "catalogue_id", "audio_mode", "subtitle_mode", "audio", "default_audio")
    if any(selection.get(key) != requested.get(key) for key in preserved):
        raise ArteError("ARTE resolved selection changed the requested audio or intent")
    requested_subtitles = requested.get("subtitles")
    if (not isinstance(requested_subtitles, list) or len(requested_subtitles) > MAX_TRACKS
            or any(key not in requested_subtitles for key in aliases)
            or selection.get("subtitles") != [key for key in requested_subtitles if key not in aliases]
            or selection.get("default_subtitle") != aliases.get(requested.get("default_subtitle"), requested.get("default_subtitle"))):
        raise ArteError("ARTE resolved subtitles differ from the requested selection")
    retained = {item.get("id"): item for item in sources.get("subtitles", [])}
    if {item.get("id") for item in removed} != set(aliases):
        raise ArteError("ARTE subtitle aliases lack exact removed-source evidence")
    for entry in removed:
        if subtitle_language_issue(entry):
            raise ArteError("ARTE subtitle alias language is not reliably identified; analyse and select again")
        target = retained.get(aliases.get(entry.get("id")))
        role, _original = role_of(entry.get("evidence") or {}, "subtitle")
        if role == "hearing_impaired":
            raise ArteError("ARTE hearing-impaired track is forbidden by engine policy")
        if (not target or not re.fullmatch(r"[0-9a-f]{64}", str(entry.get("content_identity", "")))
                or entry["content_identity"] != target.get("content_identity")
                or source_identity(entry["source"], entry["evidence"]) != entry.get("source_identity")):
            raise ArteError("ARTE subtitle alias identity proof changed")
    # Revalidate both intent and resolved data even when a checkpoint has
    # internally consistent digests. In particular, none must never acquire a
    # nonempty track list, and an obsolete selection schema cannot be revived.
    selected_audio = sources.get("audio")
    selected_subtitles = sources.get("subtitles")
    if not isinstance(selected_audio, list) or not isinstance(selected_subtitles, list):
        raise ArteError("ARTE selected track provenance is invalid")
    projection = {"version": 1, "policy": POLICY, "id": selection.get("catalogue_id"),
                  "audio": selected_audio, "subtitles": selected_subtitles + removed}
    identities = {"video": expected.get("video", {}).get("source_identity")}
    for kind in ("audio", "subtitles"):
        targets = expected.get(kind)
        if not isinstance(targets, list) or [item.get("id") for item in targets] != selection.get(kind):
            raise ArteError("ARTE expected tracks differ from the explicit selection")
        default = selection.get("default_audio" if kind == "audio" else "default_subtitle")
        if any(item.get("default") is not (item.get("id") == default) for item in targets):
            raise ArteError("ARTE expected defaults differ from the explicit selection")
        identities[kind] = [item.get("source_identity") for item in targets]
    if binding.get("sources") != identities:
        raise ArteError("ARTE source identity binding differs from the expected tracks")
    validate_selection(projection, requested)
    validate_selection(projection, selection)
    selected = selected_root(plan)
    formats = selected.get("requested_formats") or []
    if len(formats) != len(expected.get("audio", [])) + 1:
        raise ArteError("ARTE executed component count changed")
    video_source = sources.get("video") or {}
    if source_identity(formats[0], video_source.get("evidence") or {}) != expected["video"]["source_identity"]:
        raise ArteError("ARTE video provenance changed")
    for kind in ("audio", "subtitles"):
        originals = sources.get(kind)
        targets = expected.get(kind)
        if not isinstance(originals, list) or not isinstance(targets, list) or len(originals) != len(targets):
            raise ArteError("ARTE track provenance count changed")
        for index, (entry, target) in enumerate(zip(originals, targets)):
            if kind == "subtitles" and subtitle_language_issue(entry):
                raise ArteError("ARTE subtitle language is not reliably identified; analyse and select again")
            role, _original = role_of(entry["evidence"], "audio" if kind == "audio" else "subtitle")
            if role == "hearing_impaired" or role != target.get("role"):
                raise ArteError("ARTE hearing-impaired track is forbidden by engine policy")
            # Expectations are a separate private file. Their source digest
            # alone cannot authorize changing a frozen track's public labels.
            if target.get("language") != entry.get("language") or target.get("title") != entry.get("label"):
                raise ArteError("ARTE expected track labels differ from frozen source metadata")
            source = formats[index + 1] if kind == "audio" else selected.get("requested_subtitles", {}).get(target["id"], {})
            if source_identity(source, entry["evidence"]) != target.get("source_identity"):
                raise ArteError("ARTE requested track provenance changed")


def check_replay(plan: dict, replay: dict, expected: dict) -> None:
    """Bind the resource helper's frozen native replay to validated provenance."""
    validate_plan_provenance(plan, expected)
    original = selected_root(plan)
    executed = selected_root(replay)
    forbidden = ("webpage_url", "original_url")
    if any(key in replay for key in forbidden):
        raise ArteError("ARTE native replay must not re-extract an unavailable source")
    clean_formats = [{key: value for key, value in item.items() if key not in forbidden}
                     for item in original.get("requested_formats", [])]
    if replay.get("formats") != clean_formats:
        raise ArteError("ARTE native replay format inventory differs from the selected plan")
    executed_formats = [{key: value for key, value in item.items() if key not in forbidden}
                        for item in executed.get("requested_formats", [])]
    if executed_formats != clean_formats:
        raise ArteError("ARTE native replay components differ from the selected plan")
    for key in ("subtitles", "requested_subtitles", "automatic_captions", "arte_selection", "_arte_sources"):
        if executed.get(key) != original.get(key):
            raise ArteError("ARTE native replay subtitle or selection provenance changed")


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Private ARTE track discovery and selection")
    commands = parser.add_subparsers(dest="command", required=True)
    catalogue = commands.add_parser("catalogue")
    catalogue.add_argument("--plan", required=True)
    catalogue.add_argument("--output", required=True)
    public = commands.add_parser("public")
    public.add_argument("--catalogue", required=True)
    public.add_argument("--output", required=True)
    select = commands.add_parser("select")
    select.add_argument("--catalogue", required=True)
    select.add_argument("--preset", choices=("all", "original-fr", "custom"))
    select.add_argument("--audio-mode", choices=("auto", "all", "custom"))
    select.add_argument("--subtitle-mode", choices=("auto", "none", "all", "custom"))
    select.add_argument("--audio", action="append", default=[])
    select.add_argument("--subtitle", action="append", default=[])
    select.add_argument("--default-audio")
    select.add_argument("--default-subtitle")
    select.add_argument("--output", required=True)
    apply = commands.add_parser("apply")
    for name in ("plan", "catalogue", "selection", "output", "expectation", "options"):
        apply.add_argument("--" + name, required=True)
    options = commands.add_parser("options")
    options.add_argument("--options", required=True)
    subtitle_languages = commands.add_parser("subtitle-languages")
    subtitle_languages.add_argument("--expected", required=True)
    replay = commands.add_parser("check-replay")
    for name in ("plan", "replay", "expectation"):
        replay.add_argument("--" + name, required=True)
    summary = commands.add_parser("summary")
    summary.add_argument("--catalogue", required=True)
    summary.add_argument("--selection", required=True)
    verified = commands.add_parser("verified-summary")
    verified.add_argument("--plan", required=True)
    verified.add_argument("--expectation", required=True)
    return parser


def main() -> int:
    os.umask(0o077)
    args = create_parser().parse_args()
    try:
        if args.command == "catalogue":
            catalogue = build_catalogue(read_json(args.plan))
            write_json(args.output, catalogue)
            if catalogue["_private"]["quarantined"]:
                print(quarantine_diagnostic(catalogue["_private"]["quarantined"]), file=sys.stderr)
        elif args.command == "public":
            write_json(args.output, public_catalogue(read_json(args.catalogue)))
        elif args.command == "select":
            write_json(args.output, choose(read_json(args.catalogue), args.preset, args.audio, args.subtitle,
                                          audio_mode=args.audio_mode, subtitle_mode=args.subtitle_mode,
                                          default_audio=args.default_audio, default_subtitle=args.default_subtitle))
        elif args.command == "apply":
            plan, expected, options = apply_selection(read_json(args.plan), read_json(args.catalogue), read_json(args.selection))
            write_json(args.output, plan)
            write_json(args.expectation, expected)
            write_json(args.options, options)
        elif args.command == "check-replay":
            check_replay(read_json(args.plan), read_json(args.replay), read_json(args.expectation))
        elif args.command == "subtitle-languages":
            expected = read_json(args.expected)
            subtitles = expected.get("subtitles")
            if expected.get("policy") != POLICY or not isinstance(subtitles, list) or len(subtitles) > MAX_TRACKS:
                raise ArteError("ARTE subtitle expectation is invalid")
            identifiers = [item.get("id") for item in subtitles if isinstance(item, dict)]
            if len(identifiers) != len(subtitles) or any(not isinstance(item, str) or not KEY_RE.fullmatch(item) for item in identifiers):
                raise ArteError("ARTE subtitle identifiers are invalid")
            print(",".join(identifiers))
        elif args.command == "options":
            options = read_json(args.options)
            argv = options.get("argv")
            if options.get("version") != 1 or not isinstance(argv, list) or not 4 <= len(argv) <= 16:
                raise ArteError("ARTE native transfer options are invalid")
            if (argv[0] != "--format" or not isinstance(argv[1], str)
                    or not 2 <= len(argv[1].split("+")) <= 16
                    or any(not FORMAT_RE.fullmatch(item) for item in argv[1].split("+"))
                    or argv[2:4] != ["--audio-multistreams", "--no-write-auto-subs"]):
                raise ArteError("ARTE native format options are invalid")
            remaining = argv[4:]
            if remaining != ["--no-write-subs", "--no-embed-subs"]:
                if (len(remaining) != 6 or remaining[:5] != ["--write-subs", "--embed-subs", "--convert-subs", "srt", "--sub-langs"]
                        or not isinstance(remaining[5], str) or not 1 <= len(remaining[5].split(",")) <= MAX_TRACKS
                        or any(not KEY_RE.fullmatch(item) for item in remaining[5].split(","))):
                    raise ArteError("ARTE native subtitle options are invalid")
            # This is a data handoff into a Bash array, never a shell command.
            for argument in argv:
                sys.stdout.buffer.write(text_value(argument, limit=8192).encode() + b"\0")
        elif args.command == "summary":
            catalogue, selection = read_json(args.catalogue), read_json(args.selection)
            validate_selection(catalogue, selection)
            print("MKV: one video; " + str(len(selection["audio"])) + " audio(s); " + str(len(selection["subtitles"])) + " subtitle(s)")
            for kind in ("audio", "subtitles"):
                print("\n".join(item["label"] for item in catalogue[kind] if item["id"] in selection[kind]))
            for message in selection["messages"]:
                print(MESSAGE_TEXT[message])
        elif args.command == "verified-summary":
            plan, expected = read_json(args.plan), read_json(args.expectation)
            validate_plan_provenance(plan, expected)
            print("MKV selected: one video; " + str(len(expected["audio"])) + " audio(s); " + str(len(expected["subtitles"])) + " subtitle(s)")
            for kind in ("audio", "subtitles"):
                for item in expected[kind]:
                    print(text_value(item["title"], limit=256))
            for message in plan["arte_selection"]["selection"]["messages"]:
                if message not in MESSAGE_TEXT:
                    raise ArteError("ARTE selection messages are invalid")
                print(MESSAGE_TEXT[message])
        return 0
    except ArteError as error:
        print(f"[ARTE_TRACKS] {error}", file=sys.stderr)
        return 65
    except (OSError, ValueError, KeyError, TypeError, OverflowError, RecursionError):
        print("[ARTE_TRACKS] Unable to read or create private ARTE track state; analyse and select again.", file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
