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
        --plan "${PLAN_FILE}"
}

run_build() {
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
    local mode

    [[ -f ${path} && ! -L ${path} ]] \
        || fail "${label} is not a regular non-symlink file."

    mode=$(stat -c '%a' -- "${path}")
    assert_equals '600' "${mode}" "${label} permissions"
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

    ln -s -- 'redirected.mp4' "${OUTPUT_DIR}/final.mp4"
    assert_status 0 'destination symlink plan build' run_build
    printf '%s\n' 'downloaded-media' \
        >"${STAGING_DIR}/item-000.download"

    assert_status 1 'destination symlink is rejected as an existing path' run_commit
    [[ -L ${OUTPUT_DIR}/final.mp4 ]] \
        || fail 'Destination symlink was removed or replaced.'
    [[ ! -e ${OUTPUT_DIR}/redirected.mp4 ]] \
        || fail 'Destination symlink target was unexpectedly published.'
    [[ -f ${STAGING_DIR}/item-000.download ]] \
        || fail 'Destination symlink refusal removed the staging source.'

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

    printf '%s\n' 'Private aria2 plan integration tests passed.'
}

main "$@"
