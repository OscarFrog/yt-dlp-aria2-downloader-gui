#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/private-aria2-plan-integration.sh
# Purpose     : Validate private aria2 plan construction and atomic publication.
# ==============================================================================

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly SCRIPT_DIR PROJECT_DIR

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

readonly HELPER="${PROJECT_DIR}/private-aria2-plan.py"

TEST_ROOT=''
CASE_ROOT=''
OUTPUT_DIR=''
STAGING_DIR=''
PLAN_FILE=''
ARIA2_INPUT=''
MANIFEST=''

cleanup() {
    if [[ -n ${TEST_ROOT} ]]; then
        rm -rf -- "${TEST_ROOT}" || true
    fi
}

new_case() {
    local name=$1

    CASE_ROOT="${TEST_ROOT}/${name}"
    OUTPUT_DIR="${CASE_ROOT}/output"
    STAGING_DIR="${OUTPUT_DIR}/.yt-dlp-aria2-test"
    PLAN_FILE="${CASE_ROOT}/plan.json"
    ARIA2_INPUT="${STAGING_DIR}/aria2.input"
    MANIFEST="${STAGING_DIR}/manifest.json"

    mkdir -p -- "${STAGING_DIR}"
    chmod 700 -- "${STAGING_DIR}"
}

write_single_plan() {
    local url=$1
    local filename=$2
    local header_value=$3

    python3 - \
        "${PLAN_FILE}" \
        "${url}" \
        "${filename}" \
        "${header_value}" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
url = sys.argv[2]
filename = sys.argv[3]
header_value = sys.argv[4]

payload = {
    "requested_downloads": [
        {
            "filename": filename,
            "url": url,
            "protocol": "https",
            "http_headers": {
                "User-Agent": header_value,
            },
        }
    ]
}

path.write_text(
    json.dumps(payload, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
os.chmod(path, 0o600)
PY
}

write_double_plan() {
    python3 - \
        "${PLAN_FILE}" \
        "${OUTPUT_DIR}" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])

payload = {
    "requested_downloads": [
        {
            "filename": str(output_dir / "merged.mkv"),
            "requested_formats": [
                {
                    "format_id": "v1",
                    "ext": "mp4",
                    "url": "https://example.invalid/video.mp4",
                    "protocol": "https",
                    "http_headers": {
                        "User-Agent": "qualification-video",
                    },
                },
                {
                    "format_id": "a1",
                    "ext": "m4a",
                    "url": "https://example.invalid/audio.m4a",
                    "protocol": "https",
                    "http_headers": {
                        "User-Agent": "qualification-audio",
                    },
                },
            ],
        }
    ]
}

path.write_text(
    json.dumps(payload, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
os.chmod(path, 0o600)
PY
}

write_native_plan() {
    python3 - \
        "${PLAN_FILE}" \
        "${OUTPUT_DIR}" <<'PY_INNER'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])

payload = {
    "requested_downloads": [
        {
            "filename": str(output_dir / "native.ts"),
            "url": "https://example.invalid/manifest.m3u8",
            "protocol": "m3u8_native",
            "http_headers": {
                "User-Agent": "qualification-native",
            },
        }
    ]
}

path.write_text(
    json.dumps(payload, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
os.chmod(path, 0o600)
PY_INNER
}

run_classify() {
    python3 "${HELPER}" classify \
        --allow-https-direct \
        --plan "${PLAN_FILE}"
}

run_build() {
    python3 "${HELPER}" build \
        --allow-https-direct \
        --plan "${PLAN_FILE}" \
        --output-dir "${OUTPUT_DIR}" \
        --staging-dir "${STAGING_DIR}" \
        --aria2-input "${ARIA2_INPUT}" \
        --manifest "${MANIFEST}"
}

run_classify_without_https_opt_in() {
    python3 "${HELPER}" classify --plan "${PLAN_FILE}"
}

run_build_without_https_opt_in() {
    python3 "${HELPER}" build \
        --plan "${PLAN_FILE}" \
        --output-dir "${OUTPUT_DIR}" \
        --staging-dir "${STAGING_DIR}" \
        --aria2-input "${ARIA2_INPUT}" \
        --manifest "${MANIFEST}"
}

run_commit() {
    python3 "${HELPER}" commit \
        --manifest "${MANIFEST}"
}

assert_private_file() {
    local path=$1
    local label=$2

    [[ -f ${path} && ! -L ${path} ]] \
        || fail "${label} is not a regular non-symlink file."

    assert_path_mode "${path}" 600 "${label} permissions"
}

test_private_plan_classification() {
    local uri_count

    # Single direct transfer.
    printf '%s\n' 'Private aria2 plan scenario: single-stream'
    new_case 'single-stream'
    write_single_plan \
        'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'

    assert_status 0 'single-stream classification' run_classify
    assert_text_contains \
        "${ASSERT_OUTPUT}" 'transport=direct' \
        'single-stream direct classification'
    assert_text_contains \
        "${ASSERT_OUTPUT}" 'transfer_count=1' \
        'single-stream classified transfer count'

    assert_status 0 'single-stream plan build' run_build
    assert_text_contains \
        "${ASSERT_OUTPUT}" 'transfer_count=1' \
        'single-stream transfer count'

    assert_private_file "${ARIA2_INPUT}" 'single-stream aria2 input'
    assert_private_file "${MANIFEST}" 'single-stream manifest'

    assert_file_has_line \
        "${ARIA2_INPUT}" \
        'https://example.invalid/media.mp4' \
        'single-stream private URI'
    assert_file_has_line \
        "${ARIA2_INPUT}" \
        '  out=item-000.download' \
        'single-stream staging filename'

    printf '%s\n' 'downloaded-media' \
        >"${STAGING_DIR}/item-000.download"

    assert_status 0 'single-stream commit' run_commit
    assert_text_contains \
        "${ASSERT_OUTPUT}" 'published_count=1' \
        'single-stream published count'

    [[ -f ${OUTPUT_DIR}/final.mp4 ]] \
        || fail 'Single-stream destination was not published.'
    [[ ! -e ${STAGING_DIR}/item-000.download ]] \
        || fail 'Single-stream staging file remained after commit.'

    # Two selected formats.
    printf '%s\n' 'Private aria2 plan scenario: two-stream'
    new_case 'two-stream'
    write_double_plan

    assert_status 0 'two-stream classification' run_classify
    assert_text_contains \
        "${ASSERT_OUTPUT}" 'transport=direct' \
        'two-stream direct classification'
    assert_text_contains \
        "${ASSERT_OUTPUT}" 'transfer_count=2' \
        'two-stream classified transfer count'

    assert_status 0 'two-stream plan build' run_build
    assert_text_contains \
        "${ASSERT_OUTPUT}" 'transfer_count=2' \
        'two-stream transfer count'

    assert_private_file "${ARIA2_INPUT}" 'two-stream aria2 input'
    assert_private_file "${MANIFEST}" 'two-stream manifest'

    uri_count=$(grep -cE '^https://' "${ARIA2_INPUT}")
    assert_equals '2' "${uri_count}" 'two-stream URI count'

    python3 - "${MANIFEST}" "${OUTPUT_DIR}" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
output_dir = Path(sys.argv[2])

items = manifest.get("items")
assert isinstance(items, list)
assert len(items) == 2

expected = [
    output_dir / "merged.fv1.mp4",
    output_dir / "merged.fa1.m4a",
]

actual = [Path(item["destination"]) for item in items]
assert actual == expected
PY

    printf '%s\n' 'video-component' \
        >"${STAGING_DIR}/item-000.download"
    printf '%s\n' 'audio-component' \
        >"${STAGING_DIR}/item-001.download"

    assert_status 0 'two-stream commit' run_commit
    assert_text_contains \
        "${ASSERT_OUTPUT}" 'published_count=2' \
        'two-stream published count'

    [[ -f ${OUTPUT_DIR}/merged.fv1.mp4 ]] \
        || fail 'Video component was not published.'
    [[ -f ${OUTPUT_DIR}/merged.fa1.m4a ]] \
        || fail 'Audio component was not published.'

    # Replay-safe HTTP transfers whose component metadata cannot be represented
    # by the private direct builder must fall back to native yt-dlp.
    printf '%s\n' 'Private aria2 plan scenario: unrepresentable direct metadata'
    new_case 'unrepresentable-direct-metadata'
    python3 - "${PLAN_FILE}" "${OUTPUT_DIR}" <<'PY_UNREPRESENTABLE'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])

payload = {
    "requested_downloads": [
        {
            "filename": str(output_dir / "merged.mkv"),
            "requested_formats": [
                {
                    "format_id": "video",
                    "ext": "unknown_video",
                    "url": "https://example.invalid/video",
                    "protocol": "https",
                    "http_headers": {
                        "User-Agent": "qualification-agent",
                    },
                },
            ],
        }
    ]
}

path.write_text(
    json.dumps(payload, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
os.chmod(path, 0o600)
PY_UNREPRESENTABLE

    assert_status 0 'unrepresentable direct metadata classification' run_classify
    assert_text_contains "${ASSERT_OUTPUT}" 'transport=native' 'unrepresentable component metadata falls back to native'
    assert_text_contains "${ASSERT_OUTPUT}" 'transfer_count=1' 'unrepresentable component metadata transfer count'

    assert_status 65 'unrepresentable metadata remains rejected by direct build' run_build
    assert_text_contains "${ASSERT_OUTPUT}" 'unsafe extension' 'unrepresentable component metadata direct-build diagnostic'
    [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] || fail 'Unrepresentable component metadata created aria2 artifacts.'

    # Fragmented transports remain native yt-dlp downloads.
    printf '%s\n' 'Private aria2 plan scenario: native transport classification'
    new_case 'native-transport'
    write_native_plan

    assert_status 0 'native transport classification' run_classify
    assert_text_contains \
        "${ASSERT_OUTPUT}" 'transport=native' \
        'fragmented transport remains native'
    assert_text_contains \
        "${ASSERT_OUTPUT}" 'transfer_count=1' \
        'native classified transfer count'

    [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
        || fail 'Native classification unexpectedly created aria2 artifacts.'
}

test_private_plan_input_validation() {
    local userinfo_index userinfo_url

    # URL TAB injection.
    printf '%s\n' 'Private aria2 plan scenario: URL TAB rejection'
    new_case 'url-tab'
    write_single_plan \
        $'https://example.invalid/media.mp4\tout=escape' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'

    assert_status 65 'URL TAB injection is rejected' run_build
    [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
        || fail 'TAB rejection left private plan artifacts.'

    # URL LF injection.
    printf '%s\n' 'Private aria2 plan scenario: URL LF rejection'
    new_case 'url-lf'
    write_single_plan \
        $'https://example.invalid/media.mp4\n  out=escape' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'

    assert_status 65 'URL LF injection is rejected' run_build
    [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
        || fail 'LF rejection left private plan artifacts.'

    # URL CR injection.
    printf '%s\n' 'Private aria2 plan scenario: URL CR rejection'
    new_case 'url-cr'
    write_single_plan \
        $'https://example.invalid/media.mp4\rout=escape' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'

    assert_status 65 'URL CR injection is rejected' run_build
    [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
        || fail 'CR rejection left private plan artifacts.'

    # URL parser failures must be converted into a controlled validation error.
    printf '%s\n' 'Private aria2 plan scenario: malformed URL rejection'
    new_case 'url-malformed'
    write_single_plan \
        'https://[::1' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'

    assert_status 65 'malformed URL is rejected without a traceback' run_build
    assert_text_not_contains "${ASSERT_OUTPUT}" 'Traceback (most recent call last)' \
        'malformed URL controlled diagnostic'

    # Credential-bearing userinfo in media URLs must never be replayed by the
    # wrapper-managed aria2 path. Classification falls back to native yt-dlp;
    # a forced direct build remains fail-closed.
    printf '%s\n' 'Private aria2 plan scenario: URL userinfo native fallback'
    userinfo_index=0
    for userinfo_url in \
        'https://user:pass@example.invalid/media.mp4' \
        'https://user@example.invalid/media.mp4'; do
        ((userinfo_index += 1))
        new_case "userinfo-${userinfo_index}"
        write_single_plan \
            "${userinfo_url}" \
            "${OUTPUT_DIR}/final.mp4" \
            'qualification-agent'

        assert_status 0 'userinfo URL classification' run_classify
        assert_text_contains "${ASSERT_OUTPUT}" 'transport=native' \
            'userinfo URL stays on native yt-dlp'
        assert_text_contains "${ASSERT_OUTPUT}" 'transfer_count=1' \
            'userinfo URL transfer count'
        assert_status 65 'forced userinfo direct build is rejected' run_build
        assert_text_contains "${ASSERT_OUTPUT}" \
            'URL user information requires native yt-dlp transport' \
            'userinfo direct-build diagnostic'
        [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
            || fail 'Userinfo URL created private aria2 artifacts.'
    done

    # Python's JSON parser accepts isolated UTF-16 surrogate escapes. The helper
    # must reject them as validation data before UTF-8 serialization can emit a
    # raw traceback or an ambiguous exit status.
    printf '%s\n' 'Private aria2 plan scenario: isolated Unicode surrogate rejection'
    new_case 'unicode-surrogate'
    python3 - "${PLAN_FILE}" "${OUTPUT_DIR}" <<'PY_SURROGATE'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
payload = {
    "requested_downloads": [
        {
            "filename": str(output_dir) + "/bad\ud800.mp4",
            "url": "https://example.invalid/media.mp4",
            "protocol": "https",
            "http_headers": {"User-Agent": "qualification-agent"},
        }
    ]
}
path.write_text(json.dumps(payload, ensure_ascii=True) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY_SURROGATE
    assert_status 65 'isolated Unicode surrogate is rejected cleanly' run_build
    assert_text_not_contains "${ASSERT_OUTPUT}" 'Traceback (most recent call last)' \
        'isolated surrogate does not produce a traceback'
    [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
        || fail 'Isolated surrogate rejection left private artifacts.'

    # Header values are a strict JSON string boundary; do not coerce arrays,
    # numbers, booleans, or objects into aria2 input syntax.
    printf '%s\n' 'Private aria2 plan scenario: non-string header rejection'
    new_case 'header-type'
    python3 - "${PLAN_FILE}" "${OUTPUT_DIR}" <<'PY_HEADER_TYPE'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
payload = {
    "requested_downloads": [
        {
            "filename": str(output_dir / "final.mp4"),
            "url": "https://example.invalid/media.mp4",
            "protocol": "https",
            "http_headers": {"User-Agent": ["not", "a", "string"]},
        }
    ]
}
path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY_HEADER_TYPE

    assert_status 65 'non-string HTTP header value is rejected' run_build
    assert_text_contains "${ASSERT_OUTPUT}" 'value must be a string' \
        'non-string header diagnostic'

    # Header injection.
    printf '%s\n' 'Private aria2 plan scenario: header injection rejection'
    new_case 'header-injection'
    write_single_plan \
        'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/final.mp4" \
        $'qualification-agent\n  out=escape'

    assert_status 65 'HTTP header line injection is rejected' run_build
    [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
        || fail 'Header rejection left private plan artifacts.'

    # Destination traversal.
    printf '%s\n' 'Private aria2 plan scenario: path traversal rejection'
    new_case 'path-traversal'
    write_single_plan \
        'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/../escape.mp4" \
        'qualification-agent'

    assert_status 65 'destination traversal is rejected' run_build
    [[ ! -e ${CASE_ROOT}/escape.mp4 ]] \
        || fail 'Path traversal created an outside destination.'

    # A final destination symlink must be treated as an existing destination,
    # never resolved into a different filename selected by the symlink target.
    printf '%s\n' 'Private aria2 plan scenario: destination symlink rejection'
    new_case 'destination-symlink'
    write_single_plan \
        'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'

    assert_status 0 'destination symlink plan build' run_build
    # The final name can become occupied after the early build check.
    ln -s -- 'redirected.mp4' "${OUTPUT_DIR}/final.mp4"
    printf '%s\n' 'downloaded-media' \
        >"${STAGING_DIR}/item-000.download"

    assert_status 1 'destination symlink is rejected as an existing path' run_commit
    [[ -L ${OUTPUT_DIR}/final.mp4 ]] \
        || fail 'Destination symlink was removed or replaced.'
    [[ ! -e ${OUTPUT_DIR}/redirected.mp4 ]] \
        || fail 'Destination symlink target was unexpectedly published.'
    [[ -f ${STAGING_DIR}/item-000.download ]] \
        || fail 'Destination symlink refusal removed the staging source.'
}

test_private_plan_existing_destinations() {
    local collision_kind=''
    local destination=''

    for collision_kind in single component symlink; do
        new_case "preexisting-${collision_kind}"
        if [[ ${collision_kind} == component ]]; then
            write_double_plan
            destination="${OUTPUT_DIR}/merged.fa1.m4a"
        else
            write_single_plan \
                'https://example.invalid/media.mp4' \
                "${OUTPUT_DIR}/final.mp4" 'qualification-agent'
            destination="${OUTPUT_DIR}/final.mp4"
        fi
        if [[ ${collision_kind} == symlink ]]; then
            ln -s -- 'absent-target.mp4' "${destination}"
        else
            printf 'existing destination bytes\n' >"${destination}"
        fi

        assert_status 1 "${collision_kind} collision is rejected before transfer" run_build
        assert_text_contains "${ASSERT_OUTPUT}" 'destination already exists:' \
            "${collision_kind} early collision diagnostic"
        [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
            || fail "${collision_kind} early collision created transfer artifacts."
        if [[ ${collision_kind} == symlink ]]; then
            [[ -L ${destination} && ! -e ${OUTPUT_DIR}/absent-target.mp4 ]] \
                || fail 'Early collision followed or replaced the destination symlink.'
        else
            assert_file_has_line "${destination}" 'existing destination bytes' \
                "${collision_kind} collision preserves existing data"
        fi
    done

    # The helper publishes the component destinations; yt-dlp owns the separate
    # assembled filename and its post-processing behavior remains unchanged.
    new_case 'preexisting-assembled-output'
    write_double_plan
    printf 'existing assembled bytes\n' >"${OUTPUT_DIR}/merged.mkv"
    assert_status 0 'distinct assembled name does not collide with components' run_build
    assert_file_has_line "${OUTPUT_DIR}/merged.mkv" 'existing assembled bytes' \
        'building component transfers preserves the assembled output'
}

test_private_plan_duplicate_staging_names() {
    new_case 'duplicate-staging-names'
    write_double_plan
    assert_status 0 'duplicate staging fixture plan build' run_build
    printf 'first component\n' >"${STAGING_DIR}/item-000.download"
    printf 'second component\n' >"${STAGING_DIR}/item-001.download"

    # Mutating a private manifest must be rejected before publication starts,
    # not after moving a component and relying on filesystem rollback.
    PYTHONDONTWRITEBYTECODE=1 python3 - "${HELPER}" "${MANIFEST}" <<'PY_DUPLICATE_STAGING'
import argparse
import importlib.util
import json
import sys
from pathlib import Path

helper_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("private_aria2_duplicate_staging", helper_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["items"][1]["staging_name"] = manifest["items"][0]["staging_name"]
manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")


def unexpected_publication(*_args):
    raise SystemExit("duplicate staging source reached publication")


module.publish_without_overwrite = unexpected_publication
try:
    module.commit_plan(argparse.Namespace(manifest=str(manifest_path)))
except module.PlanError as exc:
    assert "duplicate staging filenames" in str(exc), exc
else:
    raise SystemExit("duplicate staging source was accepted")

for item in manifest["items"]:
    assert not Path(item["destination"]).exists()
staging = Path(manifest["staging_dir"])
assert (staging / "item-000.download").read_text() == "first component\n"
assert (staging / "item-001.download").read_text() == "second component\n"
PY_DUPLICATE_STAGING
}

test_private_plan_publication_safety() {
    local existing_content

    # Plan must itself be private.
    printf '%s\n' 'Private aria2 plan scenario: plan permissions'
    new_case 'plan-permissions'
    write_single_plan \
        'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'
    chmod 0644 -- "${PLAN_FILE}"

    assert_status 65 'world-readable plan is rejected' run_build
    [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
        || fail 'Unsafe-plan rejection left private artifacts.'

    # Symlink staging entries must never be published.
    printf '%s\n' 'Private aria2 plan scenario: symlink rejection'
    new_case 'symlink'
    write_single_plan \
        'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'

    assert_status 0 'symlink scenario plan build' run_build
    printf '%s\n' 'outside-data' >"${CASE_ROOT}/outside"
    ln -s -- "${CASE_ROOT}/outside" \
        "${STAGING_DIR}/item-000.download"

    assert_status 65 'staging symlink is rejected' run_commit
    [[ ! -e ${OUTPUT_DIR}/final.mp4 ]] \
        || fail 'Symlink staging entry was published.'

    # Presence of aria2 control file means the transfer is incomplete.
    printf '%s\n' 'Private aria2 plan scenario: incomplete transfer rejection'
    new_case 'incomplete'
    write_single_plan \
        'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'

    assert_status 0 'incomplete scenario plan build' run_build
    printf '%s\n' 'partial-data' \
        >"${STAGING_DIR}/item-000.download"
    : >"${STAGING_DIR}/item-000.download.aria2"

    assert_status 65 'aria2 incomplete transfer is rejected' run_commit
    [[ ! -e ${OUTPUT_DIR}/final.mp4 ]] \
        || fail 'Incomplete aria2 transfer was published.'

    # Existing destinations must be preserved.
    printf '%s\n' 'Private aria2 plan scenario: overwrite refusal'
    new_case 'overwrite'
    write_single_plan \
        'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'

    assert_status 0 'overwrite scenario plan build' run_build
    printf '%s\n' 'new-data' \
        >"${STAGING_DIR}/item-000.download"
    printf '%s\n' 'existing-data' \
        >"${OUTPUT_DIR}/final.mp4"

    assert_status 1 'existing destination is rejected' run_commit

    existing_content=$(<"${OUTPUT_DIR}/final.mp4")
    assert_equals \
        'existing-data' "${existing_content}" \
        'existing destination preservation'

    [[ -f ${STAGING_DIR}/item-000.download ]] \
        || fail 'Overwrite refusal removed the staging source.'
}

test_private_plan_signal_rollback() {
    local checkpoint signal_number

    for checkpoint in link component; do
        for signal_number in 1 2 15; do
            new_case "signal-${checkpoint}-${signal_number}"
            write_double_plan
            assert_status 0 'signal rollback fixture plan build' run_build
            printf 'video component\n' >"${STAGING_DIR}/item-000.download"
            printf 'audio component\n' >"${STAGING_DIR}/item-001.download"

            # Use real catchable signals at both transaction boundaries. In
            # particular, os.link has already created the destination when
            # the first checkpoint runs, before rollback registration.
            assert_status "$((128 + signal_number))" \
                "signal rollback at ${checkpoint}, signal ${signal_number}" \
                env PYTHONDONTWRITEBYTECODE=1 python3 - \
                "${HELPER}" "${MANIFEST}" "${checkpoint}" "${signal_number}" <<'PY_SIGNAL_ROLLBACK'
import importlib.util
import os
import signal
import sys
from pathlib import Path

helper = Path(sys.argv[1])
manifest = sys.argv[2]
checkpoint = sys.argv[3]
signal_number = int(sys.argv[4])
spec = importlib.util.spec_from_file_location("private_aria2_signal", helper)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original = module.os.link if checkpoint == "link" else module.publish_without_overwrite
armed = True
previous_handlers = {
    sig: signal.getsignal(sig) for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
}


def inject_signal(*args, **kwargs):
    global armed
    result = original(*args, **kwargs)
    if armed:
        armed = False
        os.kill(os.getpid(), signal_number)
    return result


if checkpoint == "link":
    module.os.link = inject_signal
else:
    module.publish_without_overwrite = inject_signal
sys.argv = [str(helper), "commit", "--manifest", manifest]
status = module.main()
assert all(signal.getsignal(sig) == old for sig, old in previous_handlers.items())
sys.exit(status)
PY_SIGNAL_ROLLBACK
            [[ ! -e ${OUTPUT_DIR}/merged.fv1.mp4 &&
                ! -e ${OUTPUT_DIR}/merged.fa1.m4a ]] \
                || fail 'Interrupted publication left a final component.'
            assert_equals 'video component' \
                "$(<"${STAGING_DIR}/item-000.download")" \
                'interrupted publication restores the video source'
            assert_equals 'audio component' \
                "$(<"${STAGING_DIR}/item-001.download")" \
                'interrupted publication preserves the audio source'
        done
    done
}

test_private_plan_rollback_safety() {
    # Rollback must never delete a destination that no longer has the inode
    # originally published by this transaction.
    printf '%s\n' 'Private aria2 plan scenario: conservative rollback identity'
    new_case 'rollback-identity'
    PYTHONDONTWRITEBYTECODE=1 python3 - "${HELPER}" "${CASE_ROOT}" <<'PY_ROLLBACK'
import importlib.util
import sys
from pathlib import Path

helper_path = Path(sys.argv[1])
case_root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("private_aria2_plan", helper_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

published = case_root / "published-original"
published.write_text("original\n", encoding="utf-8")
st = published.lstat()
identity = (st.st_dev, st.st_ino)

source = case_root / "rollback-source"
destination = case_root / "rollback-destination"
destination.write_text("foreign\n", encoding="utf-8")

module.rollback_publication([(source, destination, identity)])

assert destination.read_text(encoding="utf-8") == "foreign\n"
assert not source.exists()
PY_ROLLBACK

    # A destination is registered for rollback immediately after os.link(). If
    # post-link verification itself raises, rollback must still remove only the
    # helper-owned hardlink and leave the original staging inode available.
    printf '%s\n' 'Private aria2 plan scenario: post-link verification rollback'
    new_case 'post-link-verification-rollback'
    PYTHONDONTWRITEBYTECODE=1 python3 - "${HELPER}" "${CASE_ROOT}" <<'PY_POST_LINK'
import importlib.util
import os
import sys
from pathlib import Path

helper_path = Path(sys.argv[1])
case_root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("private_aria2_plan_post_link", helper_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

source = case_root / "source"
destination = case_root / "destination"
source.write_text("payload\n", encoding="utf-8")
original_identity = (source.lstat().st_dev, source.lstat().st_ino)
moved = []
real_match = module.path_matches_identity
raised = False

def injected_match(path, identity):
    global raised
    if path == destination and not raised:
        raised = True
        raise OSError("injected post-link verification failure")
    return real_match(path, identity)

module.path_matches_identity = injected_match
try:
    module.publish_without_overwrite(source, destination, moved)
except OSError:
    pass
else:
    raise SystemExit("post-link fault injection did not fail")
finally:
    module.path_matches_identity = real_match

assert len(moved) == 1, moved
failures = module.rollback_publication(moved)
assert failures == [], failures
assert source.exists()
assert (source.lstat().st_dev, source.lstat().st_ino) == original_identity
assert not os.path.lexists(destination)
PY_POST_LINK

    # Rollback failure is no longer silent: callers receive the list of final
    # names that could not be restored, without deleting an identity-mismatched
    # foreign destination.
    printf '%s\n' 'Private aria2 plan scenario: rollback failure reporting'
    new_case 'rollback-failure-reporting'
    PYTHONDONTWRITEBYTECODE=1 python3 - "${HELPER}" "${CASE_ROOT}" <<'PY_ROLLBACK_FAILURE'
import importlib.util
import sys
from pathlib import Path

helper_path = Path(sys.argv[1])
case_root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("private_aria2_plan_rollback_failure", helper_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

source = case_root / "occupied-source"
destination = case_root / "published"
destination.write_text("published\n", encoding="utf-8")
st = destination.lstat()
identity = (st.st_dev, st.st_ino)
source.write_text("foreign\n", encoding="utf-8")

failures = module.rollback_publication([(source, destination, identity)])
assert failures == [destination.name], failures
assert source.read_text(encoding="utf-8") == "foreign\n"
assert destination.read_text(encoding="utf-8") == "published\n"
PY_ROLLBACK_FAILURE

    # An I/O failure while writing a private file remains an I/O failure. Invalid
    # Unicode is validation data, but fsync/write failures must not be collapsed
    # into PlanError/EX_DATAERR.
    printf '%s\n' 'Private aria2 plan scenario: private-file I/O error class'
    new_case 'private-file-io-error'
    PYTHONDONTWRITEBYTECODE=1 python3 - "${HELPER}" "${CASE_ROOT}" <<'PY_PRIVATE_IO'
import importlib.util
import os
import sys
from pathlib import Path

helper_path = Path(sys.argv[1])
case_root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("private_aria2_plan_io_error", helper_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

target = case_root / "private-output"
real_fsync = module.os.fsync


def injected_fsync(_fd):
    raise OSError("injected fsync failure")


module.os.fsync = injected_fsync
try:
    module.write_private_new(target, "payload\n")
except OSError:
    pass
except module.PlanError as exc:
    raise SystemExit("private-file I/O failure was collapsed into PlanError") from exc
else:
    raise SystemExit("private-file I/O fault injection did not fail")
finally:
    module.os.fsync = real_fsync

assert not os.path.lexists(target)
PY_PRIVATE_IO

    # If a previously published destination is replaced before a later item
    # fails, and the staging source is already gone, rollback cannot claim that
    # the original component was restored. Preserve the foreign destination and
    # report the incomplete rollback.
    printf '%s\n' 'Private aria2 plan scenario: replaced-destination rollback reporting'
    new_case 'replaced-destination-rollback'
    PYTHONDONTWRITEBYTECODE=1 python3 - "${HELPER}" "${CASE_ROOT}" <<'PY_REPLACED_DEST'
import importlib.util
import os
import sys
from pathlib import Path

helper_path = Path(sys.argv[1])
case_root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("private_aria2_plan_replaced_dest", helper_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

source = case_root / "source"
destination = case_root / "destination"
anchor = case_root / "original-inode-anchor"

source.write_text("original\n", encoding="utf-8")
identity = (source.lstat().st_dev, source.lstat().st_ino)
os.link(source, destination, follow_symlinks=False)
os.link(source, anchor, follow_symlinks=False)
source.unlink()

destination.unlink()
destination.write_text("foreign\n", encoding="utf-8")

failures = module.rollback_publication([(source, destination, identity)])
assert failures == [destination.name], failures
assert not os.path.lexists(source)
assert destination.read_text(encoding="utf-8") == "foreign\n"
assert anchor.read_text(encoding="utf-8") == "original\n"
PY_REPLACED_DEST
}

test_private_plan_ownership() {
    printf '%s\n' 'Private aria2 plan scenario: ownership of private state'
    new_case 'private-state-ownership'
    write_single_plan \
        'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'
    PYTHONDONTWRITEBYTECODE=1 python3 - \
        "${HELPER}" "${PLAN_FILE}" "${OUTPUT_DIR}" "${STAGING_DIR}" \
        "${ARIA2_INPUT}" "${MANIFEST}" <<'PY_PRIVATE_OWNERSHIP'
import argparse
import importlib.util
import os
import sys
from pathlib import Path
from unittest.mock import patch

helper_path, plan, output, staging, aria2_input, manifest = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("private_plan_ownership", helper_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
args = argparse.Namespace(
    plan=str(plan), output_dir=str(output), staging_dir=str(staging),
    aria2_input=str(aria2_input), manifest=str(manifest), allow_https_direct=True,
)
real_lstat = Path.lstat
foreign_path = None

# Model a foreign UID without requiring chown privileges. All file operations,
# permission bits, and the build/commit validation paths remain real.
def foreign_owner(path, *positional, **keywords):
    metadata = real_lstat(path, *positional, **keywords)
    if path == foreign_path:
        fields = list(metadata)
        fields[4] = os.geteuid() + 1
        return os.stat_result(fields)
    return metadata

for target in (plan, staging):
    foreign_path = target
    with patch.object(Path, "lstat", foreign_owner):
        try:
            module.build_plan(args)
        except module.PlanError as exc:
            assert "owned by the current user" in str(exc), str(exc)
        else:
            raise AssertionError(f"foreign private state accepted: {target.name}")
    assert not aria2_input.exists() and not manifest.exists()
    assert not (output / "final.mp4").exists()

# Current-user state still builds. A foreign manifest cannot publish its source.
assert module.build_plan(args) == 0
source = staging / "item-000.download"
source.write_bytes(b"downloaded media\n")
foreign_path = manifest
with patch.object(Path, "lstat", foreign_owner):
    try:
        module.commit_plan(args)
    except module.PlanError as exc:
        assert "owned by the current user" in str(exc), str(exc)
    else:
        raise AssertionError("foreign manifest was accepted")
assert source.read_bytes() == b"downloaded media\n"
assert not (output / "final.mp4").exists()

assert module.commit_plan(args) == 0
assert (output / "final.mp4").read_bytes() == b"downloaded media\n"
assert not source.exists()
PY_PRIVATE_OWNERSHIP
}

test_https_direct_requires_explicit_opt_in() {
    printf '%s\n' 'Private aria2 plan scenario: HTTPS direct opt-in'
    new_case 'https-direct-opt-in'
    write_single_plan \
        'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/final.mp4" \
        'qualification-agent'

    assert_status 0 'HTTPS classification without opt-in' \
        run_classify_without_https_opt_in
    assert_text_contains "${ASSERT_OUTPUT}" 'transport=native' \
        'HTTPS defaults to native transport'
    assert_status 65 'HTTPS direct build without opt-in is rejected' \
        run_build_without_https_opt_in
    assert_text_contains "${ASSERT_OUTPUT}" \
        'HTTPS requires native yt-dlp transport on this aria2 build' \
        'HTTPS build rejection explains the transport policy'

    assert_status 0 'reviewed HTTPS classification opt-in' run_classify
    assert_text_contains "${ASSERT_OUTPUT}" 'transport=direct' \
        'reviewed HTTPS opt-in permits direct transport'
}

test_private_plan_protocol_metadata() {
    local scenario=''

    for scenario in secret-protocol list-protocol object-protocol; do
        printf 'Private aria2 plan scenario: %s\n' "${scenario}"
        new_case "${scenario}"
        python3 - "${PLAN_FILE}" "${OUTPUT_DIR}" "${scenario}" <<'PY_PROTOCOL_METADATA'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
protocols = {
    "secret-protocol": "https://private.example/protocol-secret-token/" + "x" * 32768,
    "list-protocol": ["https"],
    "object-protocol": {"protocol": "https"},
}
payload = {
    "requested_downloads": [{
        "filename": str(output_dir / "final.mp4"),
        "url": "https://example.invalid/media.mp4",
        "protocol": protocols[sys.argv[3]],
        "http_headers": {"User-Agent": "qualification-agent"},
    }],
}
path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY_PROTOCOL_METADATA
        assert_status 0 "${scenario} classification selects a safe transport" run_classify
        assert_text_contains "${ASSERT_OUTPUT}" 'transport=native' \
            "${scenario} stays on native transport"
        assert_text_not_contains "${ASSERT_OUTPUT}" 'protocol-secret-token' \
            'classification never prints raw protocol metadata'

        assert_status 65 "${scenario} direct build is rejected" run_build
        assert_text_contains "${ASSERT_OUTPUT}" 'unsupported direct-transfer protocol' \
            'protocol rejection retains useful error context'
        assert_text_not_contains "${ASSERT_OUTPUT}" 'protocol-secret-token' \
            'protocol rejection never prints private metadata'
        assert_text_not_contains "${ASSERT_OUTPUT}" 'Traceback' \
            'non-string protocol metadata never produces a traceback'
        ((${#ASSERT_OUTPUT} < 256)) \
            || fail 'Protocol rejection emitted an unbounded diagnostic.'
        [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
            || fail 'Invalid protocol metadata left private plan artifacts.'
    done
}

test_private_plan_duplicate_headers() {
    local scenario=''

    # Duplicate field names have case-insensitive HTTP semantics. Preserve the
    # native downloader's handling instead of replaying ambiguous aria2 fields.
    for scenario in different-values identical-values; do
        printf 'Private aria2 plan scenario: duplicate headers %s\n' "${scenario}"
        new_case "duplicate-headers-${scenario}"
        python3 - "${PLAN_FILE}" "${OUTPUT_DIR}" "${scenario}" <<'PY_DUPLICATE_HEADERS'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
second_value = "application/json" if sys.argv[3] == "different-values" else "text/plain"
payload = {
    "requested_downloads": [{
        "filename": str(output_dir / "final.mp4"),
        "url": "https://example.invalid/media.mp4",
        "protocol": "https",
        "http_headers": {"Accept": "text/plain", "accept": second_value},
    }],
}
path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY_DUPLICATE_HEADERS
        assert_status 0 'duplicate header names classify without failing extraction' run_classify
        assert_text_contains "${ASSERT_OUTPUT}" 'transport=native' \
            'duplicate header names use the native downloader'
        assert_status 65 'forced direct replay rejects duplicate header names' run_build
        assert_text_contains "${ASSERT_OUTPUT}" 'HTTP headers require native yt-dlp transport' \
            'duplicate header rejection explains the safe transport'
        [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
            || fail 'Duplicate header rejection left private plan artifacts.'
    done

    printf '%s\n' 'Private aria2 plan scenario: unique mixed-case header'
    new_case 'unique-mixed-case-header'
    python3 - "${PLAN_FILE}" "${OUTPUT_DIR}" <<'PY_UNIQUE_HEADER'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
payload = {
    "requested_downloads": [{
        "filename": str(output_dir / "final.mp4"),
        "url": "https://example.invalid/media.mp4",
        "protocol": "https",
        "http_headers": {"aCcEpT": "application/json"},
    }],
}
path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY_UNIQUE_HEADER
    assert_status 0 'unique mixed-case header classification' run_classify
    assert_text_contains "${ASSERT_OUTPUT}" 'transport=direct' \
        'unique allowlisted header remains direct regardless of case'
    assert_status 0 'unique mixed-case header direct build' run_build
    assert_file_has_line "${ARIA2_INPUT}" '  header=aCcEpT: application/json' \
        'unique field spelling and value remain unchanged'
}

main() {
    require_test_command python3
    require_test_command stat

    [[ -f ${HELPER} && ! -L ${HELPER} && ! -x ${HELPER} ]] \
        || fail 'Private aria2 helper must be a non-executable regular file.'

    TEST_ROOT=$(mktemp -d)
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    test_private_plan_classification
    test_private_plan_protocol_metadata
    test_private_plan_duplicate_headers
    test_private_plan_input_validation
    test_private_plan_existing_destinations
    test_private_plan_duplicate_staging_names
    test_private_plan_publication_safety
    test_private_plan_rollback_safety
    test_private_plan_signal_rollback
    test_private_plan_ownership
    test_https_direct_requires_explicit_opt_in
    printf '%s\n' 'Private aria2 plan integration tests passed.'
}

main "$@"
