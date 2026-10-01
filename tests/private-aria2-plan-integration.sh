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
PRIVATE_DIR=''
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
    PRIVATE_DIR="${CASE_ROOT}/private"
    PLAN_FILE="${PRIVATE_DIR}/plan.json"
    ARIA2_INPUT="${PRIVATE_DIR}/aria2.input"
    MANIFEST="${PRIVATE_DIR}/manifest.json"

    mkdir -p -- "${STAGING_DIR}" "${PRIVATE_DIR}"
    chmod 700 -- "${STAGING_DIR}"
}

write_single_plan() {
    local url=$1
    local filename=$2
    local header_value=$3

    python3 -I -B - \
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
    python3 -I -B - \
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
    python3 -I -B - \
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
        --private-dir "${PRIVATE_DIR}" \
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
        --private-dir "${PRIVATE_DIR}" \
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

    python3 -I -B - "${MANIFEST}" "${OUTPUT_DIR}" <<'PY'
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
    python3 -I -B - "${PLAN_FILE}" "${OUTPUT_DIR}" <<'PY_UNREPRESENTABLE'
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
    python3 -I -B - "${PLAN_FILE}" "${OUTPUT_DIR}" <<'PY_SURROGATE'
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
    python3 -I -B - "${PLAN_FILE}" "${OUTPUT_DIR}" <<'PY_HEADER_TYPE'
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

    # An existing assembled output must not be passed back to yt-dlp, whose
    # metadata postprocessor can rewrite it even with no-overwrite options.
    new_case 'preexisting-assembled-output'
    write_double_plan
    printf 'existing assembled bytes\n' >"${OUTPUT_DIR}/merged.mkv"
    assert_status 1 'existing assembled output is rejected before its components' run_build
    [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
        || fail 'Existing assembled output caused transfer artifacts.'
    assert_file_has_line "${OUTPUT_DIR}/merged.mkv" 'existing assembled bytes' \
        'building component transfers preserves the assembled output'
}

test_private_plan_final_destination_preflight() {
    local scenario final_dir final_identity expected_status

    for scenario in absent regular symlink directory replaced-directory directory-symlink; do
        new_case "final-preflight-${scenario}"
        write_double_plan
        final_dir="${CASE_ROOT}/final"
        mkdir -m 777 -- "${final_dir}"
        final_identity=$(stat -c '%d:%i' -- "${final_dir}")
        expected_status=1
        case ${scenario} in
            absent) expected_status=0 ;;
            regular) printf 'existing final media\n' >"${final_dir}/merged.mkv" ;;
            symlink) ln -s -- absent-target "${final_dir}/merged.mkv" ;;
            directory) mkdir -- "${final_dir}/merged.mkv" ;;
            replaced-directory)
                mv -- "${final_dir}" "${CASE_ROOT}/original-final"
                mkdir -- "${final_dir}"
                expected_status=65
                ;;
            directory-symlink)
                mv -- "${final_dir}" "${CASE_ROOT}/original-final"
                ln -s -- "${CASE_ROOT}/original-final" "${final_dir}"
                expected_status=70
                ;;
            *) fail "Unknown final-preflight scenario: ${scenario}" ;;
        esac
        assert_status "${expected_status}" "actual final destination preflight: ${scenario}" \
            python3 "${HELPER}" build --allow-https-direct \
            --plan "${PLAN_FILE}" --output-dir "${OUTPUT_DIR}" \
            --staging-dir "${STAGING_DIR}" --private-dir "${PRIVATE_DIR}" \
            --aria2-input "${ARIA2_INPUT}" --manifest "${MANIFEST}" \
            --final-output-dir "${final_dir}" --final-output-identity "${final_identity}" \
            --final-extension mkv
        if ((expected_status != 0)); then
            [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
                || fail "${scenario} final collision created transfer artifacts."
        fi
        case ${scenario} in
            regular)
                assert_file_has_line "${final_dir}/merged.mkv" 'existing final media' \
                    'preflight preserves a final file outside the processing directory'
                ;;
            symlink)
                [[ -L ${final_dir}/merged.mkv && ! -e ${final_dir}/absent-target ]] \
                    || fail 'Final preflight followed a destination symlink.'
                ;;
            *) ;;
        esac
    done

    new_case final-remux-preflight
    write_single_plan 'https://example.invalid/media.mp4' \
        "${OUTPUT_DIR}/final.mp4" 'qualification-agent'
    printf 'existing remux\n' >"${OUTPUT_DIR}/final.mkv"
    final_identity=$(stat -c '%d:%i' -- "${OUTPUT_DIR}")
    assert_status 1 'single-stream remux checks its MKV result before transfer' \
        python3 "${HELPER}" build --allow-https-direct \
        --plan "${PLAN_FILE}" --output-dir "${OUTPUT_DIR}" \
        --staging-dir "${STAGING_DIR}" --private-dir "${PRIVATE_DIR}" \
        --aria2-input "${ARIA2_INPUT}" --manifest "${MANIFEST}" \
        --final-output-dir "${OUTPUT_DIR}" --final-output-identity "${final_identity}" \
        --final-extension mkv
    [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
        || fail 'Existing remux caused transfer artifacts.'
    assert_file_has_line "${OUTPUT_DIR}/final.mkv" 'existing remux' \
        'single-stream final remux remains unchanged'

    new_case incomplete-final-preflight
    write_double_plan
    for final_dir in '' "${OUTPUT_DIR}"; do
        assert_status 65 'partial or empty final preflight arguments fail closed' \
            python3 "${HELPER}" build --allow-https-direct \
            --plan "${PLAN_FILE}" --output-dir "${OUTPUT_DIR}" \
            --staging-dir "${STAGING_DIR}" --private-dir "${PRIVATE_DIR}" \
            --aria2-input "${ARIA2_INPUT}" --manifest "${MANIFEST}" \
            --final-output-dir "${final_dir}"
        [[ ! -e ${ARIA2_INPUT} && ! -e ${MANIFEST} ]] \
            || fail 'Incomplete final preflight created transfer artifacts.'
    done
}

test_native_final_destination_preflight() {
    local scenario final_dir final_identity expected_status before='' after=''

    for scenario in absent regular symlink directory replaced-directory directory-symlink escaped-filename; do
        new_case "native-final-${scenario}"
        final_dir="${CASE_ROOT}/final 'quoted' % directory"
        mkdir -- "${final_dir}"
        final_identity=$(stat -c '%d:%i' -- "${final_dir}")
        expected_status=1
        case ${scenario} in
            absent) expected_status=0 ;;
            regular)
                printf 'existing final media\n' >"${final_dir}/native.mkv"
                before=$(stat -c '%d:%i:%s:%y:%z' -- "${final_dir}/native.mkv")
                ;;
            symlink) ln -s -- absent-target "${final_dir}/native.mkv" ;;
            directory) mkdir -- "${final_dir}/native.mkv" ;;
            replaced-directory)
                mv -- "${final_dir}" "${CASE_ROOT}/original-final"
                mkdir -- "${final_dir}"
                expected_status=65
                ;;
            directory-symlink)
                mv -- "${final_dir}" "${CASE_ROOT}/original-final"
                ln -s -- "${CASE_ROOT}/original-final" "${final_dir}"
                expected_status=70
                ;;
            escaped-filename) expected_status=65 ;;
            *) fail "Unknown native final-preflight scenario: ${scenario}" ;;
        esac
        local filename="${OUTPUT_DIR}/native.mp4"
        if [[ ${scenario} == escaped-filename ]]; then
            filename="${CASE_ROOT}/native.mp4"
        fi
        write_single_plan 'https://example.invalid/native.mp4' \
            "${filename}" 'qualification-native'
        assert_status "${expected_status}" "native final destination preflight: ${scenario}" \
            python3 "${HELPER}" check-native-final \
            --output-dir "${OUTPUT_DIR}" --plan "${PLAN_FILE}" \
            --final-output-dir "${final_dir}" --final-output-identity "${final_identity}"
        if [[ ${scenario} == regular ]]; then
            after=$(stat -c '%d:%i:%s:%y:%z' -- "${final_dir}/native.mkv")
            assert_equals "${before}" "${after}" \
                'native preflight preserves final metadata and identity'
            assert_file_has_line "${final_dir}/native.mkv" 'existing final media' \
                'native preflight preserves final bytes'
        elif [[ ${scenario} == symlink ]]; then
            [[ -L ${final_dir}/native.mkv && ! -e ${final_dir}/absent-target ]] \
                || fail 'Native preflight followed a destination symlink.'
        fi
    done
}

test_native_audio_final_destination_preflight() {
    local extension scenario final_dir final_identity target expected_status
    local before='' after='' before_bytes='' after_bytes='' expected_template=''
    local stem="native \$HOME 50% [planned]"

    for extension in m4a mp3; do
        for scenario in absent regular symlink hardlink directory; do
            new_case "native-audio-${extension}-${scenario}"
            final_dir="${CASE_ROOT}/final \$HOME % directory"
            mkdir -- "${final_dir}"
            final_identity=$(stat -c '%d:%i' -- "${final_dir}")
            target="${final_dir}/${stem}.${extension}"
            expected_status=1
            case ${scenario} in
                absent) expected_status=0 ;;
                regular) printf 'existing native audio\n' >"${target}" ;;
                symlink | hardlink)
                    printf 'foreign native audio\n' >"${CASE_ROOT}/foreign-audio"
                    if [[ ${scenario} == symlink ]]; then
                        ln -s -- "${CASE_ROOT}/foreign-audio" "${target}"
                    else
                        ln -- "${CASE_ROOT}/foreign-audio" "${target}"
                    fi
                    ;;
                directory) mkdir -- "${target}" ;;
                *) fail "Unknown native audio-preflight scenario: ${scenario}" ;;
            esac
            if [[ ${scenario} != absent ]]; then
                before=$(stat -c '%d:%i:%s:%h:%y:%z' -- "${target}")
                if [[ ${scenario} != directory ]]; then
                    before_bytes=$(sha256sum <"${target}")
                fi
            fi
            write_single_plan 'https://example.invalid/native-audio' \
                "${OUTPUT_DIR}/${stem}.${extension}" 'qualification-native'
            assert_status_split "${expected_status}" "native audio destination: ${extension}/${scenario}" \
                python3 "${HELPER}" check-native-final --mode audio \
                --output-dir "${OUTPUT_DIR}" --plan "${PLAN_FILE}" \
                --final-output-dir "${final_dir}" --final-output-identity "${final_identity}"
            if [[ ${scenario} == absent ]]; then
                expected_template="${OUTPUT_DIR}/native %(id&\$|\$)sHOME 50%% [planned].${extension}"
                assert_equals "${expected_template}" "${ASSERT_STDOUT}" \
                    'audio template preserves literal dollar/percent and the checked input extension'
                [[ ! -e ${target} && ! -L ${target} ]] \
                    || fail 'Audio preflight created the requested final file.'
            else
                assert_text_contains "${ASSERT_STDERR}" 'final media destination already exists' \
                    'audio collision is rejected by the no-overwrite guard'
                assert_equals '' "${ASSERT_STDOUT}" 'refused audio preflight emits no template'
                after=$(stat -c '%d:%i:%s:%h:%y:%z' -- "${target}")
                assert_equals "${before}" "${after}" 'audio collision preserves inode and metadata'
                if [[ ${scenario} != directory ]]; then
                    after_bytes=$(sha256sum <"${target}")
                    assert_equals "${before_bytes}" "${after_bytes}" \
                        'audio collision preserves existing bytes'
                fi
                if [[ ${scenario} == symlink ]]; then
                    [[ -L ${target} ]] || fail 'Audio preflight replaced a symlink.'
                fi
            fi
        done
    done

    new_case 'native-audio-invalid-extension'
    final_identity=$(stat -c '%d:%i' -- "${OUTPUT_DIR}")
    write_single_plan 'https://example.invalid/native-audio' \
        "${OUTPUT_DIR}/native.m4a][ext=mp3" 'qualification-native'
    assert_status_split 65 'audio extension cannot inject a yt-dlp format selector' \
        python3 "${HELPER}" check-native-final --mode audio \
        --output-dir "${OUTPUT_DIR}" --plan "${PLAN_FILE}" \
        --final-output-dir "${OUTPUT_DIR}" --final-output-identity "${final_identity}"
    assert_equals '' "${ASSERT_STDOUT}" 'invalid audio extension emits no usable template'
}

test_private_plan_duplicate_staging_names() {
    new_case 'duplicate-staging-names'
    write_double_plan
    assert_status 0 'duplicate staging fixture plan build' run_build
    printf 'first component\n' >"${STAGING_DIR}/item-000.download"
    printf 'second component\n' >"${STAGING_DIR}/item-001.download"

    # Mutating a private manifest must be rejected before publication starts,
    # not after moving a component and relying on filesystem rollback.
    python3 -I -B - "${HELPER}" "${MANIFEST}" <<'PY_DUPLICATE_STAGING'
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

test_network_media_permissions() {
    local source_identity=''
    local output_identity=''
    local file_count=''

    printf '%s\n' 'Private aria2 plan scenario: permissive media, private metadata'
    new_case 'permissive-media-private-metadata'
    mkdir -- "${CASE_ROOT}/network destination é"
    chmod 0777 -- "${CASE_ROOT}/network destination é"
    write_single_plan \
        'https://example.invalid/media.mp4?token=fictitious-signed-token' \
        "${OUTPUT_DIR}/final.mp4" 'fictitious-private-header'

    assert_status 0 'private plan remains accepted beside permissive media' run_classify
    assert_status 0 'media permissions do not impose metadata permissions' run_build
    assert_private_file "${ARIA2_INPUT}" 'separate private aria2 input'
    assert_private_file "${MANIFEST}" 'separate private manifest'
    printf 'downloaded media\n' >"${STAGING_DIR}/item-000.download"
    assert_status 0 'local staging component publication' run_commit
    source_identity=$(stat -c '%d:%i' -- "${OUTPUT_DIR}/final.mp4")
    output_identity=$(stat -c '%d:%i' -- "${CASE_ROOT}/network destination é")
    assert_status 0 'permissive final media publication' \
        python3 "${HELPER}" publish-media \
        --source "${OUTPUT_DIR}/final.mp4" \
        --source-identity "${source_identity}" \
        --output-dir "${CASE_ROOT}/network destination é" \
        --output-identity "${output_identity}"
    assert_file_has_line "${CASE_ROOT}/network destination é/final.mp4" 'downloaded media' \
        'permissive destination receives final media'
    file_count=$(find "${CASE_ROOT}/network destination é" -type f | wc -l)
    [[ ${file_count} == 1 ]] \
        || fail 'Private metadata was created in the media destination.'
    chmod 0777 -- "${STAGING_DIR}"
    assert_status 65 'private local media staging remains strict' run_commit
}

test_private_roots_and_media_faults() {
    printf '%s\n' 'Private aria2 plan scenario: private roots and publication fault boundaries'
    new_case 'network-publication-boundaries'
    python3 -I -B - "${HELPER}" "${CASE_ROOT}" <<'PY_NETWORK_BOUNDARIES'
import argparse
import ctypes
import errno
import importlib.util
import io
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("network_publication", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(sys.argv[2])


def identity(path):
    metadata = path.lstat()
    return f"{metadata.st_dev}:{metadata.st_ino}"


def mkdir(path, mode=0o700):
    path.mkdir(mode=mode)
    path.chmod(mode)
    return path


def prepare(name):
    case = mkdir(root / name)
    local = mkdir(case / "local")
    output = mkdir(case / "shared output é", 0o777)
    source = local / "media file é &.mp4"
    source.write_bytes(b"verified media bytes\n" * 65537)
    args = argparse.Namespace(source=str(source), source_identity=identity(source),
                              output_dir=str(output), output_identity=identity(output))
    return source, output, args


def fail_with(error_number):
    def injected(*args, **kwargs):
        raise OSError(error_number, "injected filesystem failure")
    return injected


def failure(args, expected=Exception):
    try:
        module.publish_media(args)
    except expected:
        return
    raise AssertionError("publication unexpectedly succeeded")


# Test candidate decisions and real exclusive creation. Only the filesystem
# identity of deliberately rejected candidates is simulated; permissions,
# ownership, directory descriptors and file creation remain real.
candidate = mkdir(root / "candidate")
fallback = mkdir(root / "fallback")
app = f"yt-dlp-aria2-downloader-{os.geteuid()}"

# Exercise the production fstatfs buffer decoding and local-storage decision
# on real directory descriptors. CIFS may report either CIFS_SUPER_MAGIC or
# SMB2_SUPER_MAGIC; Unix mode 0700 alone must never make either one local.
candidate_identity = candidate.stat()
for magic, local in (
    (0xEF53, True), (0x58465342, True), (0x9123683E, True),
    (0x2FC12FC1, True), (0x01021994, True),
    (0x517B, False), (0xFF534D42, False), (0xFE534D42, False),
    (0x6969, False), (0x65735546, False), (0xDEADBEEF, False),
):
    def injected_fstatfs(descriptor, buffer):
        opened = os.fstat(descriptor)
        assert (opened.st_dev, opened.st_ino) == (
            candidate_identity.st_dev, candidate_identity.st_ino)
        ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ulong))[0] = magic
        return 0

    probe = Mock(side_effect=injected_fstatfs)
    with patch.object(module.ctypes, "CDLL", return_value=SimpleNamespace(fstatfs=probe)):
        with module.directory_descriptor(candidate) as descriptor:
            assert module.filesystem_type(descriptor) == magic
            for disk in (False, True):
                accepted = local and (not disk or magic != 0x01021994)
                try:
                    module.require_local_filesystem(descriptor, disk=disk)
                except module.PlanError:
                    assert not accepted, hex(magic)
                else:
                    assert accepted, hex(magic)
        assert module.media_local_safe(argparse.Namespace(output_dir=str(candidate))) == (
            0 if local else 1)
    assert probe.call_count == 4

with patch.object(module.ctypes, "CDLL", return_value=SimpleNamespace(
        fstatfs=Mock(return_value=-1))), patch.object(module.ctypes, "get_errno", return_value=errno.EIO):
    assert module.media_local_safe(argparse.Namespace(output_dir=str(candidate))) == 1

for invalid in (Path("relative"), root / "absent"):
    with patch.object(module, "private_root_candidates", return_value=[(invalid, True), (fallback, False)]):
        assert module.select_private_root() == fallback / app
candidate.chmod(0o755)
with patch.object(module, "private_root_candidates", return_value=[(candidate, True), (fallback, False)]):
    assert module.select_private_root() == fallback / app
assert stat.S_IMODE(candidate.stat().st_mode) == 0o755
candidate.chmod(0o700)
with patch.object(module, "private_root_candidates", return_value=[(candidate, True)]):
    assert module.select_private_root() == candidate / app
    assert stat.S_IMODE((candidate / app).stat().st_mode) == 0o700
    assert not list((candidate / app).iterdir())
    (candidate / app).chmod(0o755)
    try:
        module.select_private_root()
    except module.PlanError:
        pass
    else:
        raise AssertionError("existing nonprivate application root was accepted")
    assert stat.S_IMODE((candidate / app).stat().st_mode) == 0o755
    (candidate / app).chmod(0o700)
    with patch.object(module, "filesystem_type", return_value=0xFF534D42):
        try:
            module.select_private_root()
        except module.PlanError:
            pass
        else:
            raise AssertionError("network-backed private root was accepted")
    with patch.object(module, "filesystem_type", return_value=0x01021994):
        try:
            module.select_private_root(disk=True)
        except module.PlanError:
            pass
        else:
            raise AssertionError("memory filesystem accepted for full-media disk fallback")
with patch.dict(os.environ, {"XDG_RUNTIME_DIR": "relative", "HOME": str(root)}, clear=True):
    assert module.private_root_candidates(disk=False, no_runtime=False)[0] == (Path("relative"), True)
    assert all(path != Path("relative") for path, _ in module.private_root_candidates(disk=False, no_runtime=True))
with patch.dict(os.environ, {}, clear=True):
    assert module.private_root_candidates(disk=False, no_runtime=False)[0] == (Path("/tmp"), False)

# Size estimates do not allocate real data. Simulate only the disk type and
# available capacity; parse a real private JSON file through the production API.
space_dir = mkdir(root / "space-estimates")
space_plan = space_dir / "plan.json"
space_args = argparse.Namespace(plan=str(space_plan), output_dir=str(space_dir))
floor = 64 * 1024 * 1024
known = {"requested_downloads": [{"requested_formats": [
    {"filesize": 10}, {"filesize_approx": 20},
]}]}
mixed = {"requested_downloads": [{"requested_formats": [{"filesize": 10}, {}]}]}
unknown = {"requested_downloads": [{}]}
for payload, available, succeeds, warns in (
    (known, floor + 89, False, False),
    (known, floor + 90, True, False),
    (mixed, floor + 29, False, False),
    (mixed, floor + 30, True, True),
    (unknown, floor - 1, False, False),
    (unknown, floor, True, True),
):
    space_plan.write_text(json.dumps(payload), encoding="utf-8")
    diagnostics = io.StringIO()
    with patch.object(module, "filesystem_type", return_value=0xEF53), \
            patch.object(module.os, "fstatvfs", return_value=SimpleNamespace(f_bavail=available, f_frsize=1)), \
            redirect_stderr(diagnostics):
        try:
            status = module.check_space(space_args)
        except module.PlanError as exc:
            assert not succeeds and "insufficient local disk space" in str(exc)
        else:
            assert succeeds and status == 0
    assert ("media size is unknown" in diagnostics.getvalue()) == warns
for payload in ([], {}, {"requested_downloads": []}, {"requested_downloads": ["invalid"]},
                {"requested_downloads": [{"requested_formats": "invalid"}]},
                {"requested_downloads": [{"requested_formats": ["invalid"]}]}):
    space_plan.write_text(json.dumps(payload), encoding="utf-8")
    try:
        module.check_space(space_args)
    except module.PlanError:
        pass
    else:
        raise AssertionError("space check accepted a malformed plan")
space_plan.write_text("{invalid JSON", encoding="utf-8")
try:
    module.check_space(space_args)
except module.PlanError:
    pass
else:
    raise AssertionError("space check accepted invalid JSON")

# A complete copy is never shown under its final name before finalization.
source, output, args = prepare("copy-phases")
real_write = module.os.write
seen_copy = False


def inspect_copy(descriptor, data):
    global seen_copy
    seen_copy = True
    assert source.exists() and not (output / source.name).exists()
    assert len(list(output.iterdir())) == 1
    assert list(output.iterdir())[0].name.endswith(".partial")
    return real_write(descriptor, data)


with patch.object(module.os, "write", inspect_copy):
    assert module.publish_media(args) == 0
assert seen_copy and source.read_bytes() == (output / source.name).read_bytes()
assert len(list(output.iterdir())) == 1

# Modify the opened source inode only after the first destination write.
# The constant-size case specifically needs the post-copy timestamp check;
# checking only the destination length cannot detect its mixed generation.
for change_size in (False, True):
    source, output, args = prepare(f"in-place-source-{change_size}")
    original_inode = identity(source)
    changed = False

    def mutate_during_copy(descriptor, data):
        global changed
        count = real_write(descriptor, data)
        if not changed:
            changed = True
            with source.open("r+b") as writer:
                writer.write(b"changed generation")
                if change_size:
                    writer.truncate(source.stat().st_size + 1024)
                writer.flush()
                os.fsync(writer.fileno())
        return count

    with patch.object(module.os, "write", mutate_during_copy):
        try:
            module.publish_media(args)
        except module.PlanError:
            pass
        else:
            raise AssertionError(f'in-place source mutation accepted: changed-size={change_size}')
    assert changed and identity(source) == original_inode
    assert source.read_bytes().startswith(b"changed generation")
    assert not list(output.iterdir()), "unstable source published or temporary leaked"

# Exercise an actual device boundary when the host offers one. This is a real
# filesystem copy qualification, not an SMB mount qualification.
source, output, args = prepare("cross-device")
cross_device_tested = False
for parent in ("/var/tmp", "/dev/shm"):
    try:
        directory = tempfile.TemporaryDirectory(prefix="yt-dlp-cross-device-", dir=parent)
    except OSError:
        continue
    with directory as directory_name:
        remote = Path(directory_name)
        if remote.stat().st_dev == source.stat().st_dev:
            continue
        args.output_dir = str(remote)
        args.output_identity = identity(remote)
        assert module.publish_media(args) == 0
        assert source.read_bytes() == (remote / source.name).read_bytes()
        cross_device_tested = True
        break
print("Real cross-device copy: passed" if cross_device_tested else "Real cross-device copy: NOT EXECUTED (one available filesystem)")

source_one, output, args_one = prepare("concurrent-one")
source_two, _, args_two = prepare("concurrent-two")
source_two.write_bytes(b"second complete media\n" * 65537)
args_two.output_dir, args_two.output_identity = args_one.output_dir, args_one.output_identity
workers = []
try:
    for args in (args_one, args_two):
        workers.append(subprocess.Popen(
            [sys.executable, sys.argv[1], "publish-media", "--source", args.source,
             "--source-identity", args.source_identity, "--output-dir", args.output_dir,
             "--output-identity", args.output_identity],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ))
    for worker in workers:
        worker.communicate(timeout=30)
    assert sorted(worker.returncode for worker in workers) == [0, 1]
finally:
    for worker in workers:
        if worker.poll() is None:
            worker.kill()
        worker.wait()
assert (output / source_one.name).read_bytes() in (source_one.read_bytes(), source_two.read_bytes())
assert len(list(output.iterdir())) == 1 and source_one.exists() and source_two.exists()

source, output, args = prepare("without-hard-links")
with patch.object(module.os, "link", fail_with(errno.EOPNOTSUPP)):
    assert module.publish_media(args) == 0
assert source.read_bytes() == (output / source.name).read_bytes()

source, output, args = prepare("without-rename-noreplace")
with patch.object(module, "rename_without_overwrite", fail_with(errno.EOPNOTSUPP)):
    assert module.publish_media(args) == 0
assert source.read_bytes() == (output / source.name).read_bytes()
assert len(list(output.iterdir())) == 1

source, output, args = prepare("no-atomic-primitive")
with patch.object(module, "rename_without_overwrite", fail_with(errno.EOPNOTSUPP)), \
        patch.object(module.os, "link", fail_with(errno.EOPNOTSUPP)):
    failure(args, module.PlanError)
assert source.exists() and not list(output.iterdir())

for operation, number in (("read", errno.EIO), ("write", errno.ENOSPC), ("fsync", errno.EIO)):
    source, output, args = prepare(f"copy-failure-{operation}")
    with patch.object(module.os, operation, fail_with(number)):
        failure(args, OSError)
    assert source.exists() and not list(output.iterdir())

source, output, args = prepare("copy-create-permission-denied")
unrelated = output / "preexisting user media.mp4"
unrelated.write_bytes(b"preexisting user data")
real_open = module.os.open
denied_creation = False


def deny_exclusive_copy(path, flags, *positional, **keywords):
    global denied_creation
    if str(path).startswith(".yt-dlp-publish.") and flags & os.O_EXCL:
        denied_creation = True
        raise PermissionError(errno.EACCES, "injected destination permission denial")
    return real_open(path, flags, *positional, **keywords)


with patch.object(module.os, "open", deny_exclusive_copy):
    failure(args, PermissionError)
assert denied_creation and source.exists() and not (output / source.name).exists()
assert list(output.iterdir()) == [unrelated] and unrelated.read_bytes() == b"preexisting user data"

source, output, args = prepare("late-collision")
original_rename = module.rename_without_overwrite


def collide(*positional, **keywords):
    (output / source.name).write_bytes(b"foreign existing media")
    original_rename(*positional, **keywords)


with patch.object(module, "rename_without_overwrite", collide):
    failure(args, module.DestinationExistsError)
assert (output / source.name).read_bytes() == b"foreign existing media"
assert len(list(output.iterdir())) == 1 and source.exists()

for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    source, output, args = prepare(f"copy-signal-{number}")
    signaled = False

    def interrupt_copy(descriptor, data):
        global signaled
        result = real_write(descriptor, data)
        if not signaled:
            signaled = True
            os.kill(os.getpid(), number)
        return result

    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
    with patch.object(module.os, "write", interrupt_copy):
        failure(args, module.PublicationInterrupted)
    assert all(signal.getsignal(sig) == handler for sig, handler in handlers.items())
    assert source.exists() and not list(output.iterdir())

# A simulated EIO after the server applied rename remains an uncertain error.
# It never triggers deletion of a possibly published file or of the valid source.
source, output, args = prepare("ambiguous-rename")


def ambiguous_rename(*positional, **keywords):
    original_rename(*positional, **keywords)
    raise OSError(errno.EIO, "simulated missing server acknowledgement")


with patch.object(module, "rename_without_overwrite", ambiguous_rename):
    failure(args, OSError)
assert source.read_bytes() == (output / source.name).read_bytes()

source, output, args = prepare("replaced-source")
source.rename(source.with_name("original retained inode"))
source.write_bytes(b"foreign replacement")
failure(args, module.PlanError)
assert source.read_bytes() == b"foreign replacement" and not list(output.iterdir())

source, output, args = prepare("destination-symlink")
other = mkdir(output.parent / "other")
output.rename(output.parent / "renamed destination")
output.symlink_to(other, target_is_directory=True)
failure(args, OSError)
assert not list(other.iterdir()) and source.exists()

# Same-filesystem component publication and rollback remain available when
# hard links are absent. Both operations use actual Linux RENAME_NOREPLACE.
source, output, args = prepare("component-no-hard-links")
destination = source.with_name("component-final")
moved = []
with patch.object(module.os, "link", fail_with(errno.EOPNOTSUPP)):
    module.publish_without_overwrite(source, destination, moved)
    assert destination.exists() and not source.exists()
    assert module.rollback_publication(moved) == []
assert source.exists() and not destination.exists()

# Cleanup authenticates the caller's root, retained files, and both tree passes.
workspace = mkdir(root / "cleanup")
media = workspace / "keep.mp4"
media.write_bytes(b"valid retained media")
(workspace / "resume.ytdl").write_text('{"downloader": {}}')
nested = mkdir(workspace / "temporary-cookies")
(nested / "copy.sqlite").write_bytes(b"fictitious browser copy")
cleanup_args = argparse.Namespace(path=str(workspace), identity=identity(workspace),
                                  keep=[str(media)], keep_identity=[identity(media)])
assert module.cleanup_workspace(cleanup_args) == 0
assert list(workspace.iterdir()) == [media]
(workspace / "foreign-link").symlink_to(root / "outside")
try:
    module.cleanup_workspace(cleanup_args)
except module.PlanError:
    pass
else:
    raise AssertionError("cleanup accepted a symbolic link")
assert (workspace / "foreign-link").is_symlink() and media.exists()
(workspace / "foreign-link").unlink()
changed = workspace / "changed"
changed.write_bytes(b"owned temporary")
real_listdir = module.os.listdir
calls = 0


def substitute_between_passes(descriptor):
    global calls
    calls += 1
    if calls == 2:
        changed.rename(root / "original temp inode")
        changed.write_bytes(b"foreign replacement")
    return real_listdir(descriptor)


with patch.object(module.os, "listdir", substitute_between_passes):
    try:
        module.cleanup_workspace(cleanup_args)
    except module.PlanError:
        pass
    else:
        raise AssertionError("cleanup removed a file replaced between inspection passes")
assert changed.read_bytes() == b"foreign replacement" and media.exists()
print("Private-root, copy-publication and cleanup boundaries passed.")
PY_NETWORK_BOUNDARIES
}

test_workspace_mount_boundaries() {
    printf '%s\n' 'Private aria2 plan scenario: descriptor-bound cleanup mount boundaries'
    new_case 'cleanup-mount-boundaries'
    python3 -I -B - "${HELPER}" "${CASE_ROOT}" <<'PY_CLEANUP_MOUNTS'
import argparse
import builtins
import errno
import importlib.util
import io
import os
from pathlib import Path
import re
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("private_cleanup_mounts", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(sys.argv[2])
real_open = builtins.open
real_listdir = os.listdir
real_unlink = os.unlink


def inode(path):
    metadata = path.stat()
    return metadata.st_dev, metadata.st_ino


def descriptor_inode(descriptor):
    metadata = os.fstat(descriptor)
    return metadata.st_dev, metadata.st_ino


for scenario in ("ordinary", "zero-id", "child-bind", "root-bind", "missing-id",
                 "malformed-id", "duplicate-id", "unreadable-id", "changed-id"):
    workspace = root / scenario
    workspace.mkdir(mode=0o700)
    nested = workspace / "nested"
    nested.mkdir(mode=0o700)
    protected = nested / "must-not-delete.bin"
    protected.write_bytes(b"private fixture payload behind a simulated mount")
    root_identity = inode(workspace)
    nested_identity = inode(nested)
    assert root_identity[0] == nested_identity[0] == inode(root)[0]
    original = protected.read_bytes()
    original_identity = inode(protected)
    traversals = []
    deletions = []
    observations = []

    def inspected_listdir(descriptor):
        if isinstance(descriptor, int):
            observed = descriptor_inode(descriptor)
            if observed == nested_identity:
                traversals.append(observed)
        return real_listdir(descriptor)

    def observed_unlink(filename, *args, **kwargs):
        descriptor = kwargs.get("dir_fd")
        if descriptor is not None and descriptor_inode(descriptor) == nested_identity:
            deletions.append(os.fspath(filename))
        return real_unlink(filename, *args, **kwargs)

    def fdinfo_open(filename, *args, **kwargs):
        pathname = os.fspath(filename) if not isinstance(filename, int) else ""
        match = re.fullmatch(r"/proc/self/fdinfo/([0-9]+)", pathname)
        if not match:
            return real_open(filename, *args, **kwargs)
        descriptor = int(match.group(1))
        observed = descriptor_inode(descriptor)
        observations.append(observed)
        affected = observed == (root_identity if scenario == "root-bind" else nested_identity)
        if affected and scenario == "unreadable-id":
            raise OSError(errno.EIO, "fixture unavailable mount identity")
        with real_open(filename, *args, **kwargs) as stream:
            content = stream.read()
        binary = isinstance(content, bytes)
        text = content.decode("ascii") if binary else content
        mount = re.search(r"^mnt_id:\s*([0-9]+)$", text, re.MULTILINE)
        assert mount is not None, "Linux fixture fdinfo lacks a mount ID"
        replacement = mount.group(0)
        if scenario == "zero-id":
            replacement = "mnt_id:\t0"
        elif affected:
            if scenario in {"child-bind", "root-bind"} or (scenario == "changed-id" and traversals):
                replacement = f"mnt_id:\t{int(mount.group(1)) + 1000000}"
            elif scenario == "missing-id":
                replacement = ""
            elif scenario == "malformed-id":
                replacement = "mnt_id:\tnot-a-number"
            elif scenario == "duplicate-id":
                replacement = f"{mount.group(0)}\n{mount.group(0)}"
        text = text[:mount.start()] + replacement + text[mount.end():]
        return io.BytesIO(text.encode("ascii")) if binary else io.StringIO(text)

    arguments = argparse.Namespace(
        path=str(workspace), identity=f"{root_identity[0]}:{root_identity[1]}",
        keep=[], keep_identity=[],
    )
    refused = False
    with patch("builtins.open", fdinfo_open), patch("io.open", fdinfo_open), \
         patch.object(module.os, "listdir", inspected_listdir), \
         patch.object(module.os, "unlink", observed_unlink):
        try:
            result = module.cleanup_workspace(arguments)
        except (module.PlanError, OSError):
            refused = True
        else:
            assert result == 0
    if scenario in {"ordinary", "zero-id"}:
        assert not refused and not workspace.exists(), "ordinary same-mount cleanup failed"
        continue
    assert refused, (scenario, "cleanup crossed an unresolved mount boundary",
                     "nested traversals", len(traversals), "deleted names", deletions)
    assert not deletions, (scenario, "cleanup deleted behind an unresolved mount boundary")
    assert protected.read_bytes() == original and inode(protected) == original_identity
    assert workspace.is_dir() and nested.is_dir()
    assert observations, "mount-boundary refusal did not observe real descriptor fdinfo"
    if scenario == "changed-id":
        assert len(traversals) == 1, "mount change was not rejected between inspection and removal"
    else:
        assert not traversals, "cleanup traversed a foreign or unauthenticated mounted subtree"
print("Workspace mount-boundary and uncertain-identity preservation checks passed.")
PY_CLEANUP_MOUNTS
}

test_workspace_mount_oracle_ignores_optimization() {
    printf '%s\n' 'Private aria2 plan scenario: optimized environment retains cleanup assertions'
    new_case 'cleanup-oracle-optimization'
    python3 -I -B - "${BASH_SOURCE[0]}" "${HELPER}" "${CASE_ROOT}" <<'PY_CLEANUP_ORACLE'
import os
from pathlib import Path
import re
import subprocess
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r"^    ([^\n]+ <<'PY_CLEANUP_MOUNTS')\n(.*?)^PY_CLEANUP_MOUNTS$",
    source, re.MULTILINE | re.DOTALL,
)
if match is None:
    raise AssertionError("the actual cleanup mount oracle was not found")
command, driver = match.groups()
anchor = "spec.loader.exec_module(module)\n"
if driver.count(anchor) != 1:
    raise AssertionError("cleanup oracle helper import is ambiguous")
# Change the helper only inside the child: the real oracle must detect a
# cleanup that discards its mount boundary even in an optimized environment.
mutant = driver.replace(anchor, anchor + '''
import shutil
def unsafe_cleanup(arguments):
    shutil.rmtree(arguments.path)
    return 0
module.cleanup_workspace = unsafe_cleanup
''')
for level in ("1", "2"):
    root = Path(sys.argv[3]) / level
    root.mkdir()
    environment = dict(os.environ, PYTHONOPTIMIZE=level,
                       HELPER=sys.argv[2], CASE_ROOT=str(root))
    result = subprocess.run(
        ["bash", "-c", command + "\n" + mutant + "\nPY_CLEANUP_MOUNTS\n"],
        env=environment, text=True, capture_output=True, timeout=15,
    )
    if result.returncode == 0 or "AssertionError" not in result.stderr:
        raise AssertionError((level, "unsafe cleanup escaped the actual oracle",
                              result.returncode, result.stdout, result.stderr))
    if "cleanup crossed an unresolved mount boundary" not in result.stderr:
        raise AssertionError((level, "mutation failed for an unrelated reason", result.stderr))
print("Cleanup mount oracle rejects destructive mutations under PYTHONOPTIMIZE=1/2.")
PY_CLEANUP_ORACLE
}

test_private_plan_signal_rollback() {
    local checkpoint signal_number

    for checkpoint in link rename component; do
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
                python3 -I -B - \
                "${HELPER}" "${MANIFEST}" "${checkpoint}" "${signal_number}" <<'PY_SIGNAL_ROLLBACK'
import importlib.util
import errno
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
original = (module.os.link if checkpoint == "link" else
            module.rename_without_overwrite if checkpoint == "rename" else
            module.publish_without_overwrite)
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
elif checkpoint == "rename":
    def unavailable_link(*args, **kwargs):
        raise OSError(errno.EOPNOTSUPP, "injected unavailable hard links")
    module.os.link = unavailable_link
    module.rename_without_overwrite = inject_signal
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
    python3 -I -B - "${HELPER}" "${CASE_ROOT}" <<'PY_ROLLBACK'
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
    python3 -I -B - "${HELPER}" "${CASE_ROOT}" <<'PY_POST_LINK'
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
    python3 -I -B - "${HELPER}" "${CASE_ROOT}" <<'PY_ROLLBACK_FAILURE'
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
    python3 -I -B - "${HELPER}" "${CASE_ROOT}" <<'PY_PRIVATE_IO'
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
    python3 -I -B - "${HELPER}" "${CASE_ROOT}" <<'PY_REPLACED_DEST'
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
    python3 -I -B - \
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
    private_dir=str(plan.parent),
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
        python3 -I -B - "${PLAN_FILE}" "${OUTPUT_DIR}" "${scenario}" <<'PY_PROTOCOL_METADATA'
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
        python3 -I -B - "${PLAN_FILE}" "${OUTPUT_DIR}" "${scenario}" <<'PY_DUPLICATE_HEADERS'
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
    python3 -I -B - "${PLAN_FILE}" "${OUTPUT_DIR}" <<'PY_UNIQUE_HEADER'
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

test_resource_directory_incarnation() {
    new_case 'resource-directory-incarnation'
    python3 -I -B - "${HELPER}" "${CASE_ROOT}" <<'PY_DIRECTORY_INCARNATION'
import argparse
import contextlib
import copy
import ctypes
import errno
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('incarnations', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(sys.argv[2])
output = root / 'output'
identity = (output.stat().st_dev, output.stat().st_ino)

# Real optional capability: never turn its absence into a claimed real PASS.
actual = module.directory_incarnation(output, identity)
if actual is None:
    print('Real directory file-handle capability unavailable; conservative fallback tested below.')
else:
    alias = root / 'alias'
    alias.symlink_to(output, target_is_directory=True)
    assert module.directory_incarnation(alias.resolve(), identity) == actual
    moved = root / 'renamed-output'
    output.rename(moved)
    try:
        assert module.directory_incarnation(moved, identity) == actual, 'rename changed incarnation'
        content = moved / 'unrelated-content'
        content.write_bytes(b'content is not a directory incarnation')
        assert module.directory_incarnation(moved, identity) == actual, 'directory contents changed incarnation'
        content.unlink()
    finally:
        moved.rename(output)
    print('Real file handle remains stable across symlink alias, rename and directory content changes.')

class Header(ctypes.Structure):
    _fields_ = [('size', ctypes.c_uint32), ('kind', ctypes.c_int32),
                ('data', ctypes.c_ubyte * 128)]

assert ctypes.sizeof(Header) == 136 and Header.data.offset == 8
real_fstat = module.os.fstat
observations = []

class Provider:
    def __init__(self, error=0, size=8, kind=1):
        self.error, self.size, self.kind = error, size, kind

    def __call__(self, descriptor, name, buffer, mount_id, flags):
        info = real_fstat(descriptor)
        assert (info.st_dev, info.st_ino) == identity
        assert name == b'' and flags == 0x1000
        header = ctypes.cast(buffer, ctypes.POINTER(Header)).contents
        assert header.size == 128, 'unbounded provider allocation'
        header.size, header.kind = self.size, self.kind
        for index in range(min(self.size, 128)):
            header.data[index] = index + 1
        # Different mount IDs must never distinguish aliases of one directory.
        ctypes.cast(mount_id, ctypes.POINTER(ctypes.c_int)).contents.value = 123 + len(observations)
        observations.append(descriptor)
        ctypes.set_errno(self.error)
        return -1 if self.error else 0

for error in (errno.ENOSYS, errno.EOPNOTSUPP, errno.EPERM, errno.EACCES, errno.EIO, errno.EOVERFLOW):
    with patch.object(module.ctypes, 'CDLL', return_value=SimpleNamespace(name_to_handle_at=Provider(error))):
        assert module.directory_incarnation(output, identity) is None, ('provider error became proof', error)
for size, kind in ((0, 1), (129, 1), (8, -1)):
    with patch.object(module.ctypes, 'CDLL', return_value=SimpleNamespace(name_to_handle_at=Provider(size=size, kind=kind))):
        assert module.directory_incarnation(output, identity) is None, 'malformed provider result became proof'
with patch.object(module.ctypes, 'CDLL', return_value=SimpleNamespace()):
    assert module.directory_incarnation(output, identity) is None
with patch.object(module.ctypes, 'CDLL', side_effect=OSError(errno.EIO, 'provider unavailable')):
    assert module.directory_incarnation(output, identity) is None
with patch.object(module.ctypes, 'CDLL', return_value=SimpleNamespace(name_to_handle_at=Provider())):
    first = module.directory_incarnation(output, identity)
    assert first == module.directory_incarnation(output, identity), 'mount ID entered the incarnation token'
    assert first['handle'] == '0102030405060708'
    calls = []
    def changed_fstat(descriptor):
        info = real_fstat(descriptor)
        calls.append(descriptor)
        if len(calls) == 2:
            return SimpleNamespace(st_dev=info.st_dev, st_ino=info.st_ino + 1, st_mode=info.st_mode)
        return info
    with patch.object(module.os, 'fstat', changed_fstat):
        try:
            module.directory_incarnation(output, identity)
        except module.PlanError:
            pass
        else:
            raise AssertionError('post-provider FD identity change was ignored')
    assert len(calls) == 2
    try:
        module.directory_incarnation(output, (identity[0], identity[1] + 1))
    except module.PlanError:
        pass
    else:
        raise AssertionError('provider accepted a descriptor of another destination')

token_a = {'provider': 'linux-file-handle', 'schema': 1, 'type': 1, 'handle': '01' * 8}
token_b = {**token_a, 'handle': '02' * 8}
# Fresh token-B admission below is the discriminating positive oracle.
for unknown in (None, {}, {**token_a, 'schema': 2}, {**token_a, 'provider': 'future'},
                {**token_a, 'type': 2}, {**token_a, 'handle': '02' * 12},
                {**token_a, 'handle': 'not-hex'}, {**token_a, 'schema': True}):
    assert not module.different_directory_incarnations(unknown, token_b)
    assert not module.different_directory_incarnations(token_b, unknown)

# The state-machine oracle injects only the provider token. Actual inode reuse
# is qualified separately on a filesystem that demonstrably reuses an inode.
current = None
sequence = 0
registry = root / 'registry'
registry.mkdir(mode=0o700)

def plan(name, request='same-request'):
    global sequence
    sequence += 1
    private = root / ('plan-' + str(sequence))
    private.mkdir(mode=0o700)
    info = {'id': 'fixture', 'extractor_key': 'Generic', 'format_id': 'audio',
            'ext': 'webm', 'protocol': 'http', 'filename': str(output / (name + '.webm'))}
    source = private / 'plan.json'
    source.write_text(json.dumps({**info, 'requested_downloads': [dict(info)]}))
    url = private / 'request'
    url.write_text('https://example.invalid/' + request)
    args = argparse.Namespace(plan=str(source), state=str(private / 'resources.json'),
                              output_dir=str(output), final_output_dir=str(output),
                              final_output_identity=f'{identity[0]}:{identity[1]}',
                              url_file=str(url), mode='audio', hls=False)
    captured = io.StringIO()
    with contextlib.redirect_stdout(captured):
        module.resource_plan(args)
    return args, captured.getvalue()

def action(args, name):
    return module.resource_state(argparse.Namespace(state=args.state, registry=str(registry), action=name))

def record(args):
    name = module.resource_record_name(json.loads(Path(args.state).read_text()))
    records = list(registry.glob('resources-*/' + name))
    assert len(records) == 1, ('checkpoint path is not unique', records)
    return records[0]

def refused(error, function, *args):
    try:
        function(*args)
    except error:
        return
    raise AssertionError('missing expected refusal: ' + error.__name__)

with patch.object(module, 'directory_incarnation', side_effect=lambda *args: copy.deepcopy(current)):
    current = token_a
    owner, old_keys = plan('incarnation')
    action(owner, 'admit')
    old_record = record(owner)
    preserved = old_record.read_bytes()
    same, same_keys = plan('incarnation')
    assert same_keys == old_keys
    refused(module.ResourceBusyError, action, same, 'admit')
    current = token_b
    fresh, new_keys = plan('incarnation')
    assert old_keys == new_keys, 'incarnation split the flock namespace'
    assert json.loads(Path(owner.state).read_text())['binding'] != json.loads(Path(fresh.state).read_text())['binding']
    action(fresh, 'admit')
    assert record(fresh) != old_record
    assert record(fresh).parent == old_record.parent, 'incarnation split the dev/ino bucket'
    assert old_record.read_bytes() == preserved, 'new incarnation changed the prior active checkpoint'
    action(same, 'save')
    assert old_record.read_bytes() == preserved, 'refused transaction released the active old incarnation'
    refused(module.PlanError, action, owner, 'save')
    assert old_record.read_bytes() == preserved, 'old owner checkpointed another directory incarnation'
    action(fresh, 'save')

    for label, old_token, new_token in (('old-unknown', None, token_b),
                                        ('new-unknown', token_a, None),
                                        ('both-unknown', None, None)):
        current = old_token
        owner, _ = plan(label)
        action(owner, 'admit')
        saved = record(owner).read_bytes()
        current = new_token
        retry, _ = plan(label)
        refused(module.ResourceBusyError, action, retry, 'admit')
        action(retry, 'save')
        assert record(owner).read_bytes() == saved, 'unknown incarnation lost its active protection'

    current = None
    ordinary_unknown, _ = plan('ordinary-without-provider')
    action(ordinary_unknown, 'admit')
    action(ordinary_unknown, 'save')
    assert json.loads(record(ordinary_unknown).read_text())['active'] is False

    current = token_a
    lost_owner, _ = plan('provider-lost-with-active-owner')
    action(lost_owner, 'admit')
    lost_record = record(lost_owner).read_bytes()
    lost_retry, _ = plan('provider-lost-with-active-owner')
    current = None
    refused(module.ResourceBusyError, action, lost_retry, 'admit')
    refused(module.PlanError, action, lost_owner, 'save')
    assert record(lost_owner).read_bytes() == lost_record

    # A v1 active record remains authoritative; a valid new token supplies no
    # missing historic generation and cannot grant an inspection-free reset.
    current = None
    legacy_active, _ = plan('legacy-active')
    action(legacy_active, 'admit')
    legacy_path = record(legacy_active)
    legacy = json.loads(legacy_path.read_text())
    legacy['version'] = 1
    del legacy['incarnation']
    legacy_path.write_text(json.dumps(legacy))
    legacy_active_bytes = legacy_path.read_bytes()
    current = token_b
    retry, _ = plan('legacy-active')
    refused(module.ResourceBusyError, action, retry, 'admit')
    assert legacy_path.read_bytes() == legacy_active_bytes

    # Migrate a demonstrably quiescent v1 resume without replacing that record.
    current = None
    legacy_owner, _ = plan('legacy-resume')
    action(legacy_owner, 'admit')
    partial = output / 'legacy-resume.webm.part'
    partial.write_bytes(b'owned legacy partial')
    action(legacy_owner, 'save')
    legacy_path = record(legacy_owner)
    legacy = json.loads(legacy_path.read_text())
    legacy['version'] = 1
    del legacy['incarnation']
    legacy_path.write_text(json.dumps(legacy))
    legacy_bytes = legacy_path.read_bytes()
    current = token_b
    foreign, _ = plan('legacy-resume', 'foreign-request')
    refused(module.DestinationExistsError, action, foreign, 'admit')
    retry, _ = plan('legacy-resume')
    action(retry, 'admit')
    assert legacy_path.read_bytes() == legacy_bytes
    assert record(retry) != legacy_path
    assert json.loads(Path(retry.state).read_text())['owned']
    action(retry, 'save')
    partial.write_bytes(b'foreign bytes after the valid checkpoint')
    altered, _ = plan('legacy-resume')
    refused(module.DestinationExistsError, action, altered, 'admit')
    assert partial.read_bytes() == b'foreign bytes after the valid checkpoint'

    current = token_a
    unstable, _ = plan('provider-lost-before-admit')
    current = None
    refused(module.PlanError, action, unstable, 'admit')
    assert not list(registry.glob('resources-*/' + module.resource_record_name(json.loads(Path(unstable.state).read_text()))))

    # A generation observation must remain anchored through the decision.
    # At the provider->snapshot barrier, replace only this fixture's directory;
    # verify an authenticated FD still pins the old inode and the current path
    # fails validation before a new checkpoint can be published.
    current = token_a
    pinned_owner, _ = plan('pin-barrier')
    action(pinned_owner, 'admit')
    pinned_record = record(pinned_owner)
    pinned_bytes = pinned_record.read_bytes()
    current = token_b
    replaced, _ = plan('pin-barrier')
    real_descriptor = module.directory_descriptor
    real_snapshot = module.resource_snapshot
    open_destination_descriptors = []
    barrier = []

    @contextlib.contextmanager
    def tracked_descriptor(path, **kwargs):
        with real_descriptor(path, **kwargs) as descriptor:
            relevant = path == output
            if relevant:
                open_destination_descriptors.append(descriptor)
            try:
                yield descriptor
            finally:
                if relevant:
                    open_destination_descriptors.remove(descriptor)

    def replaced_snapshot(state):
        assert open_destination_descriptors, 'incarnation FD no longer pinned at snapshot'
        descriptor = open_destination_descriptors[-1]
        before = os.fstat(descriptor)
        assert (before.st_dev, before.st_ino) == identity
        moved = root / 'moved-before-snapshot'
        output.rename(moved)
        output.mkdir(mode=0o700)
        protected = output / 'pin-barrier.webm.part'
        protected.write_bytes(b'foreign replacement must remain untouched')
        after = os.fstat(descriptor)
        assert (after.st_dev, after.st_ino) == identity, 'old inode lost its FD anchor'
        assert (output.stat().st_dev, output.stat().st_ino) != identity
        barrier.append((descriptor, identity))
        return real_snapshot(state)

    with patch.object(module, 'directory_descriptor', tracked_descriptor), \
            patch.object(module, 'resource_snapshot', replaced_snapshot):
        refused(module.PlanError, action, replaced, 'admit')
    assert len(barrier) == 1 and not open_destination_descriptors
    assert pinned_record.read_bytes() == pinned_bytes
    assert (output / 'pin-barrier.webm.part').read_bytes() == b'foreign replacement must remain untouched'
    assert not list(registry.glob('resources-*/' + module.resource_record_name(json.loads(Path(replaced.state).read_text()))))

print('Incarnation provider, conservative fallback, independent checkpoints and authenticated legacy resume passed.')
PY_DIRECTORY_INCARNATION
}

test_frozen_replay_contract() {
    new_case 'frozen-replay'
    python3 -I -B - "${PROJECT_DIR}" "${CASE_ROOT}" <<'PY_FROZEN_REPLAY'
import argparse
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import shlex
import subprocess
import sys

project, case = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('helper', project / 'private-aria2-plan.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
output = case / 'output'
identity = output.stat()
source = (project / 'download-video.sh').read_text().rsplit('main "$@"', 1)[0]
common = {'id': 'fixture', 'extractor': 'generic', 'extractor_key': 'Generic'}
original_template = str(output / '%(title).160B [%(id).64B].%(ext)s')
for label, plan in (
        ('inherited', {**common, 'title': 'Inherited', 'format_id': 'av', 'ext': 'mp4',
            'url': 'http://example.invalid/media.mp4', 'protocol': 'http',
            'requested_downloads': [{'filename': str(output / 'Inherited [fixture].mp4')}]}),
        ('live', {**common, 'title': 'Live 2026-09-30 13:51', 'is_live': True,
            'webpage_url': 'http://example.invalid/do-not-reextract',
            'formats': [{'format_id': 'unselected', 'url': 'http://example.invalid/other'}],
            'requested_downloads': [{'filename': str(output / 'Live 2026-09-30 13_51 [fixture].mkv'),
                'requested_formats': [
                    {'format_id': 'v', 'ext': 'mp4', 'protocol': 'http',
                     'vcodec': 'h264', 'acodec': 'none', 'url': 'http://example.invalid/v.mp4'},
                    {'format_id': 'a', 'ext': 'm4a', 'protocol': 'http',
                     'vcodec': 'none', 'acodec': 'aac', 'url': 'http://example.invalid/a.m4a'}]}]})):
    root = case / label
    root.mkdir(mode=0o700)
    (root / 'registry').mkdir(mode=0o700)
    (root / 'private').mkdir(mode=0o700)
    plan_file = root / 'private/plan.json'
    plan_file.write_text(json.dumps(plan))
    request = root / 'private/request'
    request.write_text('http://example.invalid/request\n')
    engine = root / 'engine.sh'
    engine.write_text(source + '\n' + f'''
PRIVATE_ARIA2_HELPER={shlex.quote(str(project / 'private-aria2-plan.py'))}
PRIVATE_ARIA2_METADATA={shlex.quote(str(root / 'private'))}
PRIVATE_ARIA2_PLAN="${{PRIVATE_ARIA2_METADATA}}/plan.json"
YTDLP_BATCH_FILE_TMP="${{PRIVATE_ARIA2_METADATA}}/request"
OUTPUT_DIR={shlex.quote(str(output))}
FINAL_OUTPUT_DIR=${{OUTPUT_DIR}}
FINAL_OUTPUT_IDENTITY={shlex.quote(f'{identity.st_dev}:{identity.st_ino}')}
MODE=video
YOUTUBE_HLS_FIREFOX=false
YT_DLP_OPTIONS=(--output {shlex.quote(original_template)})
resolve_lock_root() {{ printf -v "${{1:-OUTPUT_LOCK_ROOT}}" '%s' {shlex.quote(str(root / 'registry'))}; }}
trap cleanup EXIT
acquire_output_lock "${{OUTPUT_DIR}}"
acquire_resource_reservations
printf '%s\\0' "${{YT_DLP_OPTIONS[@]}}"
''')
    result = subprocess.run(['bash', str(engine)], capture_output=True, check=True)
    options = result.stdout.decode().rstrip('\0').split('\0')
    template = options[-1]
    planned = plan['requested_downloads'][0]['filename']
    expected = str(Path(planned).with_suffix('')).replace('%', '%%').replace('$', '%(id&$|$)s') + '.%(ext)s'
    assert options[-2] == '--output' and template == expected, 'engine replay did not freeze its admitted basename'
    frozen = json.loads((root / 'private/transfer-plan.json').read_text())
    assert 'webpage_url' not in frozen
    assert all('webpage_url' not in f and 'original_url' not in f for f in frozen['formats'])
    if label == 'inherited':
        actual = frozen['formats'][0]
        assert tuple(actual.get(key) for key in ('format_id', 'ext', 'protocol', 'url')) == (
            'av', 'mp4', 'http', plan['url']), 'inherited format was lost during replay freezing'
        # Classification and component publication must agree with the same
        # effective selected format, not merely the requested_downloads delta.
        capture = io.StringIO()
        with contextlib.redirect_stdout(capture):
            module.classify_plan(argparse.Namespace(plan=str(plan_file), allow_https_direct=True))
        assert 'transport=direct' in capture.getvalue()
        ownership = root / 'private/resources.json'
        state_args = argparse.Namespace(state=str(ownership), registry=str(root / 'registry'), action='admit')
        module.resource_state(state_args)
        partial = Path(planned + '.part')
        partial.write_bytes(b'owned partial of the inherited format')
        state_args.action = 'save'
        module.resource_state(state_args)
        for field, value in (('format_id', 'different'), ('ext', 'webm'), ('protocol', 'https')):
            changed = {**plan, field: value}
            candidate = root / ('changed-' + field)
            candidate.mkdir(mode=0o700)
            (candidate / 'plan.json').write_text(json.dumps(changed))
            (candidate / 'request').write_text('http://example.invalid/request\n')
            args = argparse.Namespace(plan=str(candidate / 'plan.json'),
                state=str(candidate / 'resources.json'), url_file=str(candidate / 'request'),
                output_dir=str(output), final_output_dir=str(output),
                final_output_identity=f'{identity.st_dev}:{identity.st_ino}', mode='video', hls=False)
            with contextlib.redirect_stdout(io.StringIO()):
                module.resource_plan(args)
            try:
                module.resource_state(argparse.Namespace(state=args.state,
                    registry=str(root / 'registry'), action='admit'))
            except module.DestinationExistsError:
                pass
            else:
                raise AssertionError('changed inherited format was adopted for resume: ' + field)
        partial.unlink()
    else:
        assert [f['format_id'] for f in frozen['formats']] == ['v', 'a']
    # The full contract stays hermetic without the optional yt-dlp package.
    # When available, also execute its real template/format processing without
    # transfer, network access, postprocessing or cache writes.
    try:
        from yt_dlp import YoutubeDL
    except ImportError:
        print('Optional real yt-dlp replay check unavailable; engine/helper contract checked.')
    else:
        options = dict(quiet=True, simulate=True, skip_download=True, cachedir=False,
                       format='bv*+ba/b', merge_output_format='mkv', outtmpl=template)
        with YoutubeDL(options) as downloader:
            replayed = downloader.process_ie_result(copy.deepcopy(frozen), download=True)
        assert replayed['requested_downloads'][0]['filename'] == planned, 'real replay escaped the admitted name'
        if label == 'live':
            with YoutubeDL({**options, 'outtmpl': original_template}) as downloader:
                unbound = downloader.process_ie_result(copy.deepcopy(frozen), download=True)
            assert unbound['requested_downloads'][0]['filename'] != planned, 'live naming negative control was not discriminating'
print('Frozen direct/native replay and inherited-format contract passed.')
PY_FROZEN_REPLAY
}

test_resource_activation_signal_handoff() {
    new_case 'resource-activation-signal'
    python3 -I -B - "${PROJECT_DIR}" "${CASE_ROOT}" <<'PY_RESOURCE_SIGNAL'
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

project, root = map(Path, sys.argv[1:])
engine_source = (project / 'download-video.sh').read_text().rsplit('main "$@"', 1)[0]
gui_source = (project / 'download-video-gui.sh').read_text().rsplit('main "$@"', 1)[0]
events = []
for phase in ('before-activation', 'after-activation'):
    case = root / phase
    case.mkdir(mode=0o700)
    for name in ('output', 'private', 'registry'):
        (case / name).mkdir(mode=0o700)
    output = case / 'output'
    plan = {'id': 'fixture', 'extractor_key': 'Generic', 'requested_downloads': [{
        'filename': str(output / 'fixture.mp4'), 'format_id': 'av', 'ext': 'mp4',
        'protocol': 'http', 'url': 'http://example.invalid/media'}]}
    (case / 'private/plan.json').write_text(json.dumps(plan))
    (case / 'private/request').write_text('http://example.invalid/request\n')
    helper = case / 'helper.py'
    helper.write_text('''import importlib.util, json, os, signal, sys, time
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('helper', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
case = Path(sys.argv[2]); phase = sys.argv[3]
sys.argv = [sys.argv[1], *sys.argv[4:]]
real_replace = m.os.replace
def replace(source, target, *args, **kwargs):
    admission = ('admit' in sys.argv and str(target).endswith('.resume.json'))
    if not admission or phase == 'after-activation':
        result = real_replace(source, target, *args, **kwargs)
    if admission:
        assert signal.getsignal(signal.SIGTERM) == signal.SIG_DFL
        (case / 'ready').write_text(str(os.getpid()))
        while True:
            signal.pause()
    return result
m.os.replace = replace
raise SystemExit(m.main())
''')
    # Keep the command interface real; instrumentation only gates its atomic
    # replacement. The signal comes from the actual GUI worker-group path.
    shim = case / 'helper-shim.py'
    shim.write_text('import os,sys\nos.execv(sys.executable, [sys.executable, ' +
                    repr(str(helper)) + ', ' + repr(str(project / 'private-aria2-plan.py')) +
                    ', ' + repr(str(case)) + ', ' + repr(phase) + ', *sys.argv[1:]])\n')
    engine = case / 'engine.sh'
    engine.write_text(engine_source + '\n' + f'''
PRIVATE_ARIA2_HELPER={shlex.quote(str(shim))}
PRIVATE_ARIA2_METADATA={shlex.quote(str(case / 'private'))}
PRIVATE_ARIA2_PLAN="${{PRIVATE_ARIA2_METADATA}}/plan.json"
YTDLP_BATCH_FILE_TMP="${{PRIVATE_ARIA2_METADATA}}/request"
OUTPUT_DIR={shlex.quote(str(output))}
FINAL_OUTPUT_DIR=${{OUTPUT_DIR}}
FINAL_OUTPUT_IDENTITY=$(stat -c '%d:%i' -- "${{OUTPUT_DIR}}")
MODE=video
YOUTUBE_HLS_FIREFOX=false
YT_DLP_OPTIONS=()
resolve_lock_root() {{ printf -v "${{1:-OUTPUT_LOCK_ROOT}}" '%s' {shlex.quote(str(case / 'registry'))}; }}
trap cleanup EXIT
trap 'request_shutdown TERM 143' TERM
acquire_output_lock "${{OUTPUT_DIR}}"
acquire_resource_reservations
exit 91
''')
    gui = case / 'gui.sh'
    token = os.urandom(24).hex()
    gui.write_text(gui_source + '\n' + f'''
PGID_FILE={shlex.quote(str(case / 'pgid'))}
LOG_FILE={shlex.quote(str(case / 'engine.log'))}
WORKER_IDENTITY_TOKEN={shlex.quote(token)}
COMMAND=(bash {shlex.quote(str(engine))})
start_download_worker
IFS= read -r action
[[ ${{action}} == cancel ]] || exit 92
signal_worker_tree TERM
status=0
wait "${{WORKER_PID}}" || status=$?
exit "${{status}}"
''')
    process = subprocess.Popen(['bash', str(gui)], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 5
        while not (case / 'ready').exists():
            assert process.poll() is None, ('GUI exited before admission barrier', process.communicate())
            assert time.monotonic() < deadline, 'activation barrier was not reached'
            time.sleep(.01)
        events.append((time.monotonic_ns(), phase, 'activation-barrier'))
        events.append((time.monotonic_ns(), phase, 'gui-cancel-request'))
        stdout, stderr = process.communicate(b'cancel\n', timeout=8)
        events.append((time.monotonic_ns(), phase, 'gui-and-worker-exited'))
        assert process.returncode == 143, (phase, process.returncode, stdout, stderr)
        live = []
        for entry in Path('/proc').glob('[0-9]*'):
            try:
                fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
                if (fields[0] not in ('Z', 'X') and
                        ('YTDLP_ARIA2_GUI_WORKER_TOKEN=' + token).encode() in
                        (entry / 'environ').read_bytes().split(b'\0')):
                    live.append(entry.name)
            except (FileNotFoundError, ProcessLookupError):
                continue
            except PermissionError:
                continue
        assert not live, ('live admission consumers before rescue', live)
        records = [json.loads(p.read_text()) for p in (case / 'registry').glob('resources-*/*.resume.json')]
        (case / 'before-rescue.json').write_text(json.dumps({'status': process.returncode,
                                                         'live': live, 'records': records}))
        assert all(not item['active'] for item in records), 'GUI cancellation left an active admission checkpoint'
        assert not list(output.iterdir()), 'admission unexpectedly modified media'
        # Exercise actual new admission, not merely absence of a live process.
        retry = case / 'retry'
        retry.mkdir(mode=0o700)
        info = output.stat()
        state = retry / 'resources.json'
        common = [sys.executable, str(project / 'private-aria2-plan.py')]
        request = retry / 'request'
        request.write_text('http://example.invalid/request\n')
        subprocess.run([*common, 'resource-plan', '--plan', str(case / 'private/plan.json'),
            '--state', str(state), '--url-file', str(request), '--mode', 'video',
            '--output-dir', str(output), '--final-output-dir', str(output),
            '--final-output-identity', f'{info.st_dev}:{info.st_ino}'], check=True,
            stdout=subprocess.PIPE)
        subprocess.run([*common, 'resource-state', '--action', 'admit', '--state', str(state),
                        '--registry', str(case / 'registry')], check=True)
        subprocess.run([*common, 'resource-state', '--action', 'save', '--state', str(state),
                        '--registry', str(case / 'registry')], check=True)
        events.append((time.monotonic_ns(), phase, 'new-admission-succeeded'))
    finally:
        (root / 'events.json').write_text(json.dumps(events))
        # Record/assert first. Rescue only this fixture's direct GUI process and
        # its published, still-authenticated group; rescue never creates PASS.
        if process.poll() is None:
            for entry in Path('/proc').glob('[0-9]*'):
                try:
                    if ('YTDLP_ARIA2_GUI_WORKER_TOKEN=' + token).encode() not in (entry / 'environ').read_bytes().split(b'\0'):
                        continue
                    descriptor = os.pidfd_open(int(entry.name))
                    try:
                        if ('YTDLP_ARIA2_GUI_WORKER_TOKEN=' + token).encode() in (entry / 'environ').read_bytes().split(b'\0'):
                            signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                    finally:
                        os.close(descriptor)
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    continue
            process.terminate()
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=2)
print('GUI admission signal handoff before/after activation passed.')
PY_RESOURCE_SIGNAL
}

test_resource_reservations_and_resume() {
    new_case 'resource-reservations'
    python3 -I -B - "${HELPER}" "${CASE_ROOT}" <<'PY_RESOURCES'
import argparse
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('resources', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(sys.argv[2])
output = root / 'output'
registry = root / 'registry'
registry.mkdir(mode=0o700)
alias = root / 'alias'
alias.symlink_to(output, target_is_directory=True)
sequence = 0

def plan(name, request='one', directory=output, formats=None, mode='video', *,
         identity=None, download_identity=None, media_url='https://example.invalid/media?signature=one'):
    global sequence
    sequence += 1
    private = root / str(sequence)
    private.mkdir(mode=0o700)
    source = private / 'plan.json'
    url = private / 'request'
    url.write_text('https://example.invalid/' + request)
    if identity is None:
        identity = {'id': 'fixture-media', 'extractor': 'generic', 'extractor_key': 'Generic'}
    source.write_text(json.dumps({**identity, 'webpage_url': 'https://example.invalid/reextract',
        'requested_downloads': [{'filename': str(directory / name),
            'format_id': 'av', 'ext': Path(name).suffix[1:], 'protocol': 'http',
            'url': media_url, **(download_identity or {}),
            **({'requested_formats': formats} if formats else {})}]}))
    info = output.stat()
    args = argparse.Namespace(output_dir=str(directory), final_output_dir=str(directory),
        final_output_identity=f'{info.st_dev}:{info.st_ino}', plan=str(source),
        state=str(private / 'resources.json'), url_file=str(url), mode=mode, hls=False)
    captured = io.StringIO()
    with contextlib.redirect_stdout(captured):
        module.resource_plan(args)
    frozen = json.loads((private / 'transfer-plan.json').read_text())
    assert 'webpage_url' not in frozen, 'replay can reextract outside its plan'
    return args, [line.split() for line in captured.getvalue().splitlines()]

def acquire(keys):
    opened = []
    try:
        for mode, key in keys:
            fd = os.open(registry / (key + '.lock'), os.O_CREAT | os.O_RDWR, 0o600)
            opened.append(fd)
            fcntl.flock(fd, fcntl.LOCK_NB | (fcntl.LOCK_SH if mode == 'shared' else fcntl.LOCK_EX))
        return opened
    except BlockingIOError:
        for fd in opened:
            os.close(fd)
        return None

def release(opened):
    for fd in opened:
        os.close(fd)

def state(args, action):
    return module.resource_state(argparse.Namespace(state=args.state, registry=str(registry), action=action))

def rejected(error, function, *arguments):
    try:
        function(*arguments)
    except error:
        return
    raise AssertionError(f'{error.__name__} was not raised')

# Equal paths, aliases, Unicode normalization/case, different URLs, and an
# overlapping component with a different final basename all exclude each other.
for left, right in [('Film.mp4', 'Film.webm'), ('café.mp4', 'CAFE\u0301.webm'),
                    ('a.mkv', 'a.f137.webm'), ('x % $.mp4', 'x % $.webm')]:
    _, keys = plan(left)
    first = acquire(keys)
    assert first is not None
    _, keys2 = plan(right, 'other-url', alias)
    assert acquire(keys2) is None, (left, right)
    independent, independent_keys = plan('independent.mp4')
    other = acquire(independent_keys)
    assert other is not None
    release(other)
    release(first)
    next_owner = acquire(keys2)
    assert next_owner is not None
    release(next_owner)

args, _ = plan('resume.mp4')
part = output / 'resume.mp4.part'
part.write_bytes(b'ambiguous legacy state')
before = part.stat()
rejected(module.DestinationExistsError, state, args, 'admit')
assert part.read_bytes() == b'ambiguous legacy state' and part.stat() == before
part.unlink()
state(args, 'admit')
part.write_bytes(b'owned partial transfer')
# An uncertain stop cannot release protection, even when no FD survives.
same, _ = plan('resume.mp4')
rejected(module.ResourceBusyError, state, same, 'admit')
records = list(registry.rglob(module.resource_record_name(json.loads(Path(args.state).read_text()))))
assert len(records) == 1, 'admitted resource checkpoint is not unique'
record = records[0]
active_record = record.read_bytes()
# Cleanup was prudently registered before attempted admission. It must neither
# release somebody else's active record nor invent ownership after a refusal.
state(same, 'save')
assert record.read_bytes() == active_record, 'failed admission cleared another transaction'
overlap, _ = plan('resume.mp4.f137.mp4')
rejected(module.ResourceBusyError, state, overlap, 'admit')
state(args, 'save')
state(same, 'admit')
state(same, 'save')
foreign_request, _ = plan('resume.mp4', 'different-request')
rejected(module.DestinationExistsError, state, foreign_request, 'admit')
passive_record = record.read_bytes()
state(foreign_request, 'save')
assert record.read_bytes() == passive_record, 'failed admission adopted foreign resources'
with part.open('r+b') as handle:
    handle.write(b'foreign modification')
changed, _ = plan('resume.mp4')
rejected(module.DestinationExistsError, state, changed, 'admit')

# Full media IDs can differ beyond the output template's 64-byte truncation.
# The same request, filename and formats must not adopt another media's bytes.
prefix = 'i' * 64
identity = {'id': prefix + '-first', 'extractor': 'generic', 'extractor_key': 'Generic'}
name = f'identity [{prefix}].mp4'
owner, _ = plan(name, identity=identity)
state(owner, 'admit')
partial = output / (name + '.part')
partial.write_bytes(b'partial bytes belonging only to the first media')
before = partial.stat()
state(owner, 'save')
for field, value in (('id', prefix + '-second'), ('extractor', 'other'), ('extractor_key', 'Other')):
    changed_identity = {**identity, field: value}
    for metadata in ({'identity': changed_identity},
                     {'identity': identity, 'download_identity': {field: value}}):
        candidate, _ = plan(name, **metadata)
        rejected(module.DestinationExistsError, state, candidate, 'admit')
assert partial.read_bytes() == b'partial bytes belonging only to the first media'
after = partial.stat()
assert (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (
    after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)

# Moving inherited identity to the download and refreshing a signed transfer URL
# does not change the media. The unchanged owned partial remains resumable.
refreshed, _ = plan(name, identity={}, download_identity=identity,
                    media_url='https://example.invalid/media?signature=refreshed')
state(refreshed, 'admit')
state(refreshed, 'save')

# Either extractor identity field is sufficient when the other is unavailable.
for field in ('extractor', 'extractor_key'):
    available = {'id': identity['id'], field: identity[field]}
    available_name = f'available-{field}.mp4'
    owner, _ = plan(available_name, identity=available)
    state(owner, 'admit')
    (output / (available_name + '.part')).write_bytes(b'owned with one extractor identity')
    state(owner, 'save')
    retry, _ = plan(available_name, identity=available,
                    media_url='https://example.invalid/media?signature=refreshed')
    state(retry, 'admit')
    state(retry, 'save')

# Missing/malformed identity permits a fresh transfer, never a later adoption.
for index, metadata in enumerate((
        {'identity': {}},
        {'identity': {'id': 'only-id'}},
        {'identity': {'extractor_key': 'Generic'}},
        {'identity': {**identity, 'id': ''}},
        {'identity': {**identity, 'id': 123}},
        {'identity': {**identity, 'extractor_key': []}},
        {'identity': identity, 'download_identity': {'id': None}})):
    missing_name = f'missing-identity-{index}.mp4'
    unidentified, _ = plan(missing_name, **metadata)
    state(unidentified, 'admit')
    missing_partial = output / (missing_name + '.part')
    missing_partial.write_bytes(b'partial without a stable extracted identity')
    state(unidentified, 'save')
    retry, _ = plan(missing_name, **metadata)
    rejected(module.DestinationExistsError, state, retry, 'admit')
    assert missing_partial.read_bytes() == b'partial without a stable extracted identity'

# Final and native entries remain passive user data; they are not lock errors.
for extension in ('mkv', 'mp4', 'webm'):
    witness = output / ('external.' + extension)
    witness.write_bytes(b'another media')
    before = witness.stat()
    candidate, _ = plan('external.' + ('mp4' if extension == 'mkv' else extension))
    rejected(module.DestinationExistsError, state, candidate, 'admit')
    assert witness.stat() == before and witness.read_bytes() == b'another media'
    witness.unlink()
rejected(module.PlanError, plan, 'x' * 240 + '.mp4')
rejected(module.PlanError, plan, 'ordinary.mkv', 'one', output,
         [{'format_id': '../escape', 'ext': 'mp4'}])
converted, _ = plan('converted.webm', mode='audio')
state(converted, 'admit')
final = output / 'converted.opus'
final.write_bytes(b'completed native audio in its extracted container')
module.resource_state(argparse.Namespace(state=converted.state, registry=str(registry),
                                        action='save', completed_path=str(final)))
repeated, _ = plan('converted.webm', mode='audio')
rejected(module.DestinationExistsError, state, repeated, 'admit')
print('Resource families, alias exclusion, independent locks, uncertain-stop protection and authenticated resume passed.')
PY_RESOURCES
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

    test_resource_directory_incarnation
    test_frozen_replay_contract
    test_resource_activation_signal_handoff
    test_resource_reservations_and_resume
    test_workspace_mount_oracle_ignores_optimization
    test_workspace_mount_boundaries
    test_network_media_permissions
    test_private_roots_and_media_faults
    test_private_plan_classification
    test_private_plan_protocol_metadata
    test_private_plan_duplicate_headers
    test_private_plan_input_validation
    test_private_plan_existing_destinations
    test_private_plan_final_destination_preflight
    test_native_final_destination_preflight
    test_native_audio_final_destination_preflight
    test_private_plan_duplicate_staging_names
    test_private_plan_publication_safety
    test_private_plan_rollback_safety
    test_private_plan_signal_rollback
    test_private_plan_ownership
    test_https_direct_requires_explicit_opt_in
    printf '%s\n' 'Private aria2 plan integration tests passed.'
}

main "$@"
