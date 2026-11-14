#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/mock-runtime.sh
# Purpose     : Qualify runtime admission, capabilities, and media validation errors.
# ==============================================================================

# Caller-owned globals: declare names without assigning values or changing
# their existing readonly/export/array attributes, including function sourcing.
declare -g \
    TEST_ROOT OUTPUT_DIR MOCK_RUNTIME_MANAGER_LOG \
    MANAGED_ENGINE_UNDER_TEST ASSERT_OUTPUT PROJECT_DIR \
    MOCK_ARIA2_ARG_LOG MOCK_ARG_LOG MOCK_NO_DENO_BIN \
    MOCK_BIN GUI_UNDER_TEST HOME_DIR \
    MOCK_GROUP

# Sourced by mock-integration.sh in the same Bash process. Helpers and tests
# share its PROJECT_DIR, private TEST_ROOT paths, command doubles and assertions;
# invocation remains under the entry point's options, traps and group dispatch.

test_mock_managed_runtime_attestation() {
    local deno_control_log="${TEST_ROOT}/managed-deno-control.log"
    local ytdlp_control_log="${TEST_ROOT}/managed-ytdlp-control.log"
    local -a runtime_manager_arguments=()

    # A managed launch consumes one runtime-manager attestation and must not
    # repeat the yt-dlp/Deno discovery commands already covered by that proof.
    prepare_argument_log 'managed-runtime-attestation'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    : >"${MOCK_RUNTIME_MANAGER_LOG}"
    : >"${ytdlp_control_log}"
    : >"${deno_control_log}"
    assert_status 0 'managed runtime attestation initializes the engine' \
        env -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
        -u YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE \
        MOCK_YTDLP_CONTROL_LOG="${ytdlp_control_log}" \
        MOCK_DENO_CONTROL_LOG="${deno_control_log}" \
        "${MANAGED_ENGINE_UNDER_TEST}" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://example.com/watch?v=managed-attestation'
    read_arguments "${MOCK_RUNTIME_MANAGER_LOG}" runtime_manager_arguments
    assert_equals '2' "${#runtime_manager_arguments[@]}" \
        'managed runtime preparation argument count'
    assert_equals 'prepare' "${runtime_manager_arguments[0]}" \
        'managed runtime preparation command'
    assert_equals 'update' "${runtime_manager_arguments[1]}" \
        'managed runtime preparation action'
    [[ ! -s ${ytdlp_control_log} ]] \
        || fail 'managed engine repeated yt-dlp version/help discovery after attestation'
    [[ ! -s ${deno_control_log} ]] \
        || fail 'managed engine repeated Deno version discovery after attestation'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'managed-runtime-old-version'
    assert_status 1 'managed attestation cannot bypass the engine minimum version' \
        env -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
        YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE=0 \
        MOCK_MANAGED_YTDLP_VERSION=2026.06.08 \
        "${MANAGED_ENGINE_UNDER_TEST}" \
        -- 'https://example.com/watch?v=managed-old-version'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'yt-dlp 2026.06.09 or later is required' \
        'managed runtime minimum-version diagnostic'

    prepare_argument_log 'managed-runtime-malformed-attestation'
    assert_status 69 'malformed managed runtime attestation is rejected' \
        env -u YTDLP_ARIA2_SKIP_RUNTIME_UPDATE \
        YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE=0 \
        MOCK_RUNTIME_ATTESTATION_MALFORMED=1 \
        "${MANAGED_ENGINE_UNDER_TEST}" \
        -- 'https://example.com/watch?v=managed-malformed-attestation'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'managed runtime attestation is malformed or unsupported' \
        'malformed managed runtime attestation diagnostic'
}

test_mock_locale_contracts() {
    # Run the actual protocol functions under the caller's locale; a localized
    # collation must neither admit Unicode digits nor widen cleanup authority.
    python3 - "${PROJECT_DIR}" "${BASH}" <<'PY_LOCALE_PROTOCOLS'
from pathlib import Path
import importlib.util
import os
import subprocess
import sys
import tempfile

project, shell = Path(sys.argv[1]), sys.argv[2]

def run(path, statements, arguments=(), executable=True):
    source = (project / path).read_text(encoding="utf-8")
    if executable:
        if source.count('\nmain "$@"') != 1:
            raise AssertionError("unexpected executable entrypoint")
        source = source.rsplit('\nmain "$@"', 1)[0]
    result = subprocess.run(
        [shell, "-s", "--", *arguments], input=source + "\n" + statements,
        capture_output=True, text=True, encoding="utf-8", timeout=10,
    )
    if result.returncode != 0 or result.stdout != "locale-protocols-ok\n":
        raise AssertionError(f"locale protocol verdict failed: {path}: {result.returncode}: {result.stderr}")

# Invalid public numeric settings must keep their documented refusal statuses,
# rather than reaching locale-sensitive Bash arithmetic.
for entry, arguments, expected_status, diagnostic in (
    ("tests/run-all.sh", ["--list", "--jobs", "١"], 2, "test concurrency must be an integer"),
    ("tests/repeat-qualification.sh", ["--runs", "١", "--", "true"], 2, "repetition count must be an integer"),
):
    result = subprocess.run(
        [shell, str(project / entry), *arguments], capture_output=True,
        text=True, encoding="utf-8", timeout=10,
    )
    if result.returncode != expected_status or diagnostic not in result.stderr or "10#" in result.stderr:
        raise AssertionError(f"locale-dependent numeric refusal: {entry}: {result.returncode}: {result.stderr}")
# Exercise the installer's actual admission block without launching a desktop.
installer_source = (project / "tests/installer-integration.sh").read_text(encoding="utf-8")
gio_block = installer_source.split('        gio_timeout=${GIO_LAUNCH_TIMEOUT:-20}\n', 1)[1]
gio_block = 'gio_timeout=${GIO_LAUNCH_TIMEOUT:-20}\n' + gio_block.split('        rm -f -- "${EXEC_MARKER}"', 1)[0]
for value, expected_status in (("20", 0), ("١", 1), ("１", 1), ("0", 1)):
    result = subprocess.run(
        [shell, "-s"], input='set -eu\nfail() { printf "%s\\n" "$*" >&2; exit 1; }\n' + gio_block,
        env=dict(os.environ, GIO_LAUNCH_TIMEOUT=value), capture_output=True,
        text=True, encoding="utf-8", timeout=10,
    )
    if (result.returncode != expected_status or "10#" in result.stderr
            or (expected_status and "GIO_LAUNCH_TIMEOUT must be a positive integer" not in result.stderr)):
        raise AssertionError(f"locale-dependent installer setting refusal: {value}: {result.stderr}")
# No test tools can start even if a broken validator accidentally continues.
for name in ("ARIA2_BEHAVIOR_BASIC_RUNS", "ARIA2_BEHAVIOR_CANCEL_RESTART_RUNS",
             "ARIA2_BEHAVIOR_QUIESCENCE_RUNS", "ARIA2_BEHAVIOR_WAIT_SECONDS"):
    environment = dict(os.environ, PROJECT_DIR=str(project), PATH="/nonexistent")
    environment[name] = "١"
    result = subprocess.run(
        [shell, str(project / "tests/aria2-real-behavior-integration.sh")],
        env=environment, capture_output=True, text=True, encoding="utf-8", timeout=10,
    )
    if (result.returncode != 64 or f"{name} must be a decimal integer" not in result.stderr
            or "10#" in result.stderr):
        raise AssertionError(f"locale-dependent aria2 setting refusal: {name}: {result.stderr}")
run("tests/lib/test-runner.sh", r'''
set -eu
original_locale=${LC_ALL-}
TEST_RUNNER_TERMINATION_POLL_ATTEMPTS=050
test_runner_validate_termination_poll_attempts
[[ $TEST_RUNNER_TERMINATION_POLL_ATTEMPTS == 50 ]]
TEST_RUNNER_TERMINATION_POLL_ATTEMPTS=١
status=0
test_runner_validate_termination_poll_attempts 2>/dev/null || status=$?
[[ $status == 64 ]]
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''', executable=False)
run("tests/lib/assert.sh", r'''
set -eu
original_locale=${LC_ALL-}
validate_expected_status 023 witness result
[[ $result == 23 ]]
status=0
errors=$(validate_expected_status '١' witness result 2>&1) || status=$?
[[ $status == 2 && $errors == 'TEST ERROR: witness: expected status is not an integer: ١' ]]
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''', executable=False)
run("download-video.sh", r'''
original_locale=${LC_ALL-}
compare_versions '2026.06.09' '2026.06.09'
[[ $VERSION_PARSE_VALID == true && $VERSION_AT_LEAST == true ]]
for value in '١.2.3' '１.2.3' '2026.０６.09'; do
    compare_versions "$value" '2.0.0'
    [[ $VERSION_PARSE_VALID == false && $VERSION_AT_LEAST == false ]]
done
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''')
run("download-video.sh", r'''
original_locale=${LC_ALL-}
URL_HOST=YOUTUBE-NOCOOKIE.COM
normalize_url_host
[[ $URL_HOST == youtube-nocookie.com ]]
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''')
run("install-fedora.sh", r'''
original_locale=${LC_ALL-}
root_stage_path_is_safe '/tmp/yt-dlp-aria2-downloader-application.a1234567'
if root_stage_path_is_safe '/tmp/yt-dlp-aria2-downloader-application.éééééééé'; then exit 99; fi
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''')
run("download-video-gui.sh", r'''
original_locale=${LC_ALL-}
url_is_youtube 'https://YOUTUBE-NOCOOKIE.COM/watch'
url_is_youtube 'https://WWW.YOUTUBE.COM/watch'
if url_is_youtube 'https://YOUTUBE-NOCOOKIE.COM.example.invalid/watch'; then exit 99; fi
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''')
run("runtime-manager.sh", r'''
# This executable intentionally avoids errexit; the witness must assert failures.
set -e
original_locale=${LC_ALL-}
is_valid_ytdlp_version '2026.06.09'
for value in '２０２６.06.09' '2026.٠٦.09'; do
    if is_valid_ytdlp_version "$value"; then exit 99; fi
done
validate_bounded_uint timeout 15 1 300
for value in '١' '１'; do
    if validate_bounded_uint timeout "$value" 1 300 2>/dev/null; then exit 99; fi
done
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''')
with tempfile.TemporaryDirectory(prefix="locale-staging-") as temporary:
    root = Path(temporary)
    # Exercise the bootstrap's actual parser: translated collation must not
    # admit non-ASCII version components or cryptographic digest characters.
    pin = root / "shfmt-pin.env"
    for version, digest, expected in (("3.14.1", "a" * 64, 0),
                                      ("3.14.1", "é" * 64, 65),
                                      ("3.14.1", "١" * 64, 65),
                                      ("３.14.1", "a" * 64, 65)):
        pin.write_text(f"SHFMT_VERSION={version}\nSHFMT_LINUX_AMD64_SHA256={digest}\n"
                       f"SHFMT_LINUX_ARM64_SHA256={'b' * 64}\n", encoding="utf-8")
        run("scripts/dev-tools/ensure-shfmt.sh", r'''
original_locale=${LC_ALL-}
status=0
read_pin "$1" version amd64 arm64 2>/dev/null || status=$?
[[ $status == "$2" ]]
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''', (str(pin), str(expected)))

    spec = importlib.util.spec_from_file_location("locale_format_helper", project / "private-aria2-plan.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    identifiers = root / "identifiers.bin"
    cases = ["ascii-1_2.3:4", "français", "carré²", "中", "𐐀", "١", "Ⅰ",
             "é" * 128, "é" * 129, "𐐀" * 128, "𐐀" * 129,
             "", "é/slash", "e\u0301", "\u0345", "\u05b0", "\u093e", "$()"]
    records = [(value.encode("utf-8"), helper.format_id_is_representable(value) and len(value) <= 128)
               for value in cases]
    # Combined IDs are a monitor-only extension; malformed UTF-8 is never data.
    records.extend((("vidéo+音声".encode("utf-8"), True), (b"invalid-\xff", False),
                    (b"truncated-\xc3", False), (b"overlong-\xc0\xaf", False)))
    identifiers.write_bytes(b"".join(value + b"\0" + (b"1" if valid else b"0") + b"\0"
                                     for value, valid in records))
    monitor_log = root / "monitor.log"
    monitor_log.write_bytes(b"")
    run("progress-monitor.sh", r'''
initialize_progress_inputs "$1/monitor.log" "$$" "$1/result" video "$1"
initialize_progress_state
while IFS= read -r -d '' value && IFS= read -r -d '' expected; do
    sanitize_identifier "$value"
    if [[ $expected == 1 ]]; then
        [[ $SANITIZED_IDENTIFIER == "$value" ]]
    else
        [[ -z $SANITIZED_IDENTIFIER ]]
    fi
done <"$1/identifiers.bin"
# Each new Unicode ID is checked once; known plan/native IDs reuse exact bytes.
probe_log=$1/python-probes
python3() {
    printf 'probe\n' >>"$probe_log"
    command python3 "$@"
}
set_multistream_plan 2 'vidéo' 'carré²'
[[ ${#PLANNED_FORMAT_IDS[@]} == 2 && ${PLANNED_FORMAT_IDS[1]} == 'carré²' ]]
[[ $(wc -l <"$probe_log") == 2 ]]
: >"$probe_log"
for ((record = 0; record < 1000; record++)); do
    resolve_native_key 'carré²'
    [[ $RESOLVED_KEY == plan:2 ]]
done
[[ ! -s $probe_log ]]
initialize_progress_state
resolve_native_key 'carré²'
[[ $RESOLVED_KEY == native:1 && ${NATIVE_FORMAT_IDS[0]} == 'carré²' ]]
[[ $(wc -l <"$probe_log") == 1 ]]
: >"$probe_log"
for ((record = 0; record < 1000; record++)); do
    resolve_native_key 'carré²'
    [[ $RESOLVED_KEY == native:1 ]]
done
[[ ! -s $probe_log ]]
printf '%s\n' locale-protocols-ok
''', (str(root),))
    duration = root / "durée média.txt"
    duration.write_text("12.5\n", encoding="utf-8")
    run("download-video.sh", r'''
original_locale=${LC_ALL-}
PROBE_OUTPUT_FILE=$1
capture_media_probe() { return 0; }
probe_duration_microseconds actual 'synthetic media'
[[ $actual == 12500000 ]]
for value in '١.5' '１.5' '12,5'; do
    printf '%s\n' "$value" >"$PROBE_OUTPUT_FILE"
    probe_duration_microseconds actual 'synthetic media'
    [[ -z $actual ]]
done
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''', (str(duration),))
    for name in (".yt-dlp-aria2.a1234567", ".yt-dlp-aria2.é1234567"):
        directory = root / name
        directory.mkdir(mode=0o700)
        marker = directory / ".yt-dlp-aria2-owner-v1"
        marker.write_text("yt-dlp-aria2-private-staging-v1\n", encoding="ascii")
        marker.chmod(0o600)
    run("download-video.sh", r'''
original_locale=${LC_ALL-}
OUTPUT_DIR=$1
entries=()
private_aria2_staging_candidate_is_safe "$1/.yt-dlp-aria2.a1234567" entries
if private_aria2_staging_candidate_is_safe "$1/.yt-dlp-aria2.é1234567" entries; then exit 99; fi
[[ -f $1/.yt-dlp-aria2.é1234567/.yt-dlp-aria2-owner-v1 ]]
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''', (str(root),))
    state = root / "état privé"
    state.mkdir(mode=0o700)
    for suffix in ("a1234567", "é1234567"):
        log = state / f".download-20250101-010101-{suffix}.log.part"
        log.write_bytes(b"synthetic retained data\n")
        log.chmod(0o600)
        os.utime(log, (1, 1))
    run("download-video-gui.sh", r'''
original_locale=${LC_ALL-}
STATE_DIR=$1
prune_old_logs
[[ ! -e $1/.download-20250101-010101-a1234567.log.part ]]
[[ -f $1/.download-20250101-010101-é1234567.log.part ]]
[[ ${LC_ALL-} == "$original_locale" ]]
printf '%s\n' locale-protocols-ok
''', (str(state),))
    if (state / ".download-20250101-010101-é1234567.log.part").read_bytes() != b"synthetic retained data\n":
        raise AssertionError("ambiguous retained log bytes changed")
print("Locale protocols: ASCII versions/numbers, cleanup names and caller environment preserved.")
PY_LOCALE_PROTOCOLS
}

test_mock_runtime_version_formats() {
    local compatible_ytdlp_version

    # Scenario group: runtime version and capability handling.
    for compatible_ytdlp_version in \
        '2026.06.09.20260727' \
        '2026.06.09-1.fc44' \
        '2026.06.09+custom'; do
        rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
        prepare_argument_log "version-${compatible_ytdlp_version//[^[:alnum:]]/_}"
        assert_status 0 "compatible yt-dlp version ${compatible_ytdlp_version}" \
            env MOCK_YTDLP_VERSION="${compatible_ytdlp_version}" \
            "${PROJECT_DIR}/download-video.sh" \
            --output-dir "${OUTPUT_DIR}" \
            -- 'https://example.com/watch?v=version-suffix'
    done
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    assert_status 1 'unparseable yt-dlp version is rejected clearly' \
        env MOCK_YTDLP_VERSION=not-a-version \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://example.com/watch?v=bad-version'
    assert_text_contains "${ASSERT_OUTPUT}" 'unable to parse the yt-dlp version' \
        'unparseable yt-dlp diagnostic'
}

test_mock_runtime_worker_failure() {
    local escalated_timeout_probe_result forbidden_source_name=''
    local invalid_probe_result timeout_probe_result

    forbidden_source_name=$(printf '\170\150\141\155\163\164\145\162')
    prepare_argument_log 'forbidden-external-diagnostic-redaction'
    assert_status 1 'forbidden external diagnostic is redacted' \
        env MOCK_PLAN_EXIT_STATUS=1 MOCK_FORBIDDEN_EXTERNAL_ERROR=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=redacted-external-diagnostic'
    assert_text_not_contains "${ASSERT_OUTPUT}" "${forbidden_source_name}" \
        'forbidden external source label is absent from engine diagnostics'
    assert_text_contains "${ASSERT_OUTPUT}" '[YTDLP_DIAGNOSTIC]' \
        'external diagnostic is replaced by a controlled privacy category'
    assert_text_contains "${ASSERT_OUTPUT}" '[ENGINE_PLAN] Format planning failed.' \
        'planning failure identifies its operation'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'does not distinguish access, network or format-selection problems' \
        'planning status is not treated as a specific external cause'
    assert_text_contains "${ASSERT_OUTPUT}" 'Review the diagnostic output before retrying.' \
        'planning failure requests inspection before another attempt'

    prepare_argument_log 'immediate-worker-failure'
    assert_status 23 'an immediate yt-dlp failure preserves its real status' \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_YTDLP_EXIT_STATUS=23 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=immediate-worker-failure'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Download failed with exit code 23.' \
        'immediate worker status diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" '[ENGINE_DOWNLOAD] Media transfer failed.' \
        'transfer failure identifies its operation'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'does not distinguish access, network or format-selection problems' \
        'transfer status is not treated as a specific external cause'
    assert_text_contains "${ASSERT_OUTPUT}" 'Review the diagnostic output before retrying.' \
        'transfer failure requests inspection before another attempt'

    prepare_argument_log 'ffprobe-validation-failure'
    invalid_probe_result="${TEST_ROOT}/invalid-probe-result.txt"
    assert_status 65 'a media file rejected by FFprobe is not published as success' \
        env MOCK_FFPROBE_EXIT_STATUS=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${invalid_probe_result}" \
        -- 'https://example.com/watch?v=invalid-probe'
    [[ ! -e ${invalid_probe_result} ]] \
        || fail 'A result file was published after FFprobe validation failed.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'final media file failed FFprobe validation' \
        'FFprobe failure diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Media validation reason: probe-error' \
        'FFprobe failure bounded reason'
    assert_text_contains "${ASSERT_OUTPUT}" \
        '[MEDIA_VALIDATION] FFprobe could not validate the media contents.' \
        'FFprobe failure advice follows the verified reason'
    assert_text_contains "${ASSERT_OUTPUT}" 'Inspect the retained media before retrying.' \
        'FFprobe failure preserves the need for inspection'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'ffprobe-validation-timeout'
    timeout_probe_result="${TEST_ROOT}/timeout-probe-result.txt"
    assert_status 65 'an FFprobe timeout has a distinct validation reason' \
        env MOCK_FFPROBE_EXIT_STATUS=124 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${timeout_probe_result}" \
        -- 'https://example.com/watch?v=timeout-probe'
    [[ ! -e ${timeout_probe_result} ]] \
        || fail 'A result file was published after an FFprobe timeout.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Media validation reason: probe-timeout' \
        'FFprobe timeout bounded reason'
    assert_text_contains "${ASSERT_OUTPUT}" \
        '[MEDIA_VALIDATION] FFprobe validation exceeded its time limit.' \
        'FFprobe timeout advice follows the verified reason'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'ffprobe-validation-escalated-timeout'
    escalated_timeout_probe_result="${TEST_ROOT}/escalated-timeout-probe-result.txt"
    assert_status 65 'an escalated FFprobe timeout keeps the timeout reason' \
        env MOCK_FFPROBE_EXIT_STATUS=137 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        --result-file "${escalated_timeout_probe_result}" \
        -- 'https://example.com/watch?v=escalated-timeout-probe'
    [[ ! -e ${escalated_timeout_probe_result} ]] \
        || fail 'A result file was published after an escalated FFprobe timeout.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Media validation reason: probe-timeout' \
        'FFprobe escalated-timeout bounded reason'
    assert_text_contains "${ASSERT_OUTPUT}" \
        '[MEDIA_VALIDATION] FFprobe validation exceeded its time limit.' \
        'escalated FFprobe timeout retains the same explanation'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    # Exercise diagnostic boundaries without launching another media engine.
    # Existing scenarios above cover actual transport and FFprobe failures.
    python3 -I -B - "${PROJECT_DIR}/download-video.sh" "${TEST_ROOT}" \
        "${PROJECT_DIR}/private-aria2-plan.py" <<'PY_ENGINE_DIAGNOSTICS'
import json
from pathlib import Path
import subprocess
import sys

source = Path(sys.argv[1]).read_text().rsplit('\nmain "$@"', 1)[0]
root = Path(sys.argv[2]) / 'engine-diagnostic-boundaries'
root.mkdir(mode=0o700)

def run(program, *arguments):
    return subprocess.run(['bash', '-s', '--', str(root), *map(str, arguments)],
                          input=source + program, text=True, capture_output=True, timeout=5)

terminal = r'''
fixture_status=$2
DOWNLOAD_STATUS=$2
SHUTDOWN_REQUESTED=$4
MACHINE_PROGRESS=true
URL='https://example.invalid/PRIVATE_ENGINE_DIAGNOSTIC'
PRIVATE_ARIA2_PLAN=$1/plan.json
YT_DLP_OPTIONS=()
YTDLP_BIN=unused
YTDLP_BATCH_FILE_TMP=$1/url
run_supervised_ytdlp() { DOWNLOAD_STATUS=${fixture_status}; }
normalize_successful_path_record() { exit 99; }
if [[ $3 == plan ]]; then plan_selected_transport; else finalize_download; fi
'''
for phase, identifier, legacy in (
    ('plan', '[ENGINE_PLAN]', 'Download failed during format planning with exit code'),
    ('transfer', '[ENGINE_DOWNLOAD]', 'Download failed with exit code'),
):
    for status, requested in ((23, 'false'), (129, 'false'), (130, 'false'),
                              (143, 'false'), (23, 'true')):
        result = run(terminal, status, phase, requested)
        assert result.returncode == status, 'diagnostic changed the failure status'
        assert not result.stdout, 'human diagnostic contaminated machine stdout'
        assert f'{legacy} {status}.' in result.stderr, 'legacy status line changed'
        assert 'PRIVATE_ENGINE_DIAGNOSTIC' not in result.stderr, 'diagnostic leaked request data'
        if status == 23 and requested == 'false':
            assert identifier in result.stderr, 'missing diagnostic operation ID'
            assert 'does not distinguish access, network or format-selection problems' in result.stderr
            assert 'Review the diagnostic output before retrying.' in result.stderr
        else:
            assert identifier not in result.stderr, 'cancellation received new failure advice'
        assert 'Download completed successfully.' not in result.stderr, 'failure claimed success'

media = root / 'retained.media'
media.write_bytes(b'unchanged retained fixture')
(root / 'path-record').write_text(str(media) + '\n')
# The real supervisor's signal delivery/quiescence is covered separately.
# At this boundary its completed cancellation must escape the caller's ordinary
# validation-refusal handler, including source, remux and final validation.
arte_cancellation = r'''
fixture_status=$2
PRIVATE_ARIA2_METADATA=$1
PROCESS_SUPERVISOR=unused
ARTE_MEDIA_HELPER=$1/must-not-run
ARTE_COMPONENT_RECORDS=$1/components
ARTE_SUBTITLE_REFERENCE=$1/reference
ARTE_EXPECTATION=$1/expected
PRIVATE_ARIA2_PLAN=$1/plan.json
fixture_requested=$4
run_supervised_command() {
    DOWNLOAD_STATUS=${fixture_status}
    SHUTDOWN_REQUESTED=${fixture_requested}
    REQUESTED_EXIT_STATUS=${fixture_status}
}
validate_arte_media_file "$1/retained.media" "$3" || {
    printf 'validation refusal\n' >&2
    exit 65
}
exit 99
'''
for phase in ('source', 'remux', 'final'):
    for status in (130, 143):
        result = run(arte_cancellation, status, phase, 'true')
        assert result.returncode == status, ('ARTE validation lost cancellation', phase, status, result.stderr)
        assert not result.stdout and not result.stderr, 'ARTE cancellation became a media validation failure'
        assert media.read_bytes() == b'unchanged retained fixture', 'ARTE cancellation changed retained media'
    result = run(arte_cancellation, 23, phase, 'false')
    assert result.returncode == 65 and result.stderr == 'validation refusal\n', 'ARTE non-signal failure no longer refuses validation'

validation = r'''
fixture_reason=$2
PATH_RECORD_FD_PATH=$1/path-record
MODE=video
MACHINE_PROGRESS=true
HLS_SOURCE_TO_CLEAN=''
validate_final_media_file() { FINAL_MEDIA_VALIDATION_REASON=${fixture_reason}; return 1; }
validate_and_publish_result
'''
for reason, explanation in (
    ('missing-or-empty-file', 'the file is missing or empty'),
    ('missing-audio', 'no audio stream'),
    ('missing-content-video', 'no content video stream'),
    ('unexpected-content-video', 'audio validation found a content video stream'),
    ('probe-timeout', 'exceeded its time limit'),
    ('probe-error', 'could not validate the media contents'),
    ('probe-tail-error', 'could not validate the media contents'),
    ('tail-inconsistent', 'could not confirm the declared end'),
    ('unknown', 'could not confirm a usable result'),
):
    result = run(validation, reason)
    assert result.returncode == 65, 'validation diagnostic changed the refusal status'
    assert result.stdout.splitlines() == ['YTDLP_POSTPROCESS|started|MediaValidation',
                                        'YTDLP_POSTPROCESS|error|MediaValidation'], 'validation protocol changed'
    assert f'Media validation reason: {reason}\n' in result.stderr
    assert '[MEDIA_VALIDATION]' in result.stderr and explanation in result.stderr
    inspection = 'Inspect the reported media location' if reason == 'missing-or-empty-file' else 'Inspect the retained media'
    assert inspection in result.stderr, 'missing media inspection advice'
    assert media.read_bytes() == b'unchanged retained fixture', 'diagnostic changed retained media'

snapshot_code = '''
def snapshot(directory):
    result = {}
    for path in sorted(directory.rglob('*')):
        if path.name == 'mutation-snapshot.json':
            continue
        info = path.lstat()
        result[str(path.relative_to(directory))] = [
            info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns,
            path.read_bytes().hex() if path.is_file() else None,
        ]
    return result
'''
exec(snapshot_code)

# A missing path must not be described as a retained recovery copy. This case
# invokes the real validation function, whose missing-file check precedes FFprobe.
missing = root / 'absent.media'
(root / 'path-record').write_text(str(missing) + '\n')
before_missing = snapshot(root)
missing_validation = r'''
PATH_RECORD_FD_PATH=$1/path-record
MODE=video
MACHINE_PROGRESS=true
HLS_SOURCE_TO_CLEAN=''
validate_and_publish_result
'''
result = run(missing_validation)
assert result.returncode == 65, 'missing-file diagnostic changed the refusal status'
assert result.stdout.splitlines() == ['YTDLP_POSTPROCESS|started|MediaValidation',
                                    'YTDLP_POSTPROCESS|error|MediaValidation'], 'missing-file protocol changed'
assert 'Media validation reason: missing-or-empty-file\n' in result.stderr
assert 'Inspect the reported media location' in result.stderr
assert 'The media file was retained' not in result.stderr, 'missing file was advertised as retained'
assert 'Inspect the media location and any remaining files' in result.stderr
assert 'no successful result was published' in result.stderr
assert not missing.exists(), 'validation created an absent file'
assert media.read_bytes() == b'unchanged retained fixture', 'missing-file diagnostic changed other media'
assert snapshot(root) == before_missing, 'missing-file diagnostic changed filesystem state'

# Mutate only the fixture, after both Bash identity checks and before the real
# helper opens the source. Snapshot actual filesystem state at that boundary.
mutator = root / 'publication-race.py'
mutator.write_text('import json, os, sys\nfrom pathlib import Path\n' + snapshot_code + '''
directory = Path(sys.argv[1])
source = directory / 'local' / 'validated.media'
source.rename(source.with_name('previous.media'))
if sys.argv[2] == 'replaced':
    source.write_bytes(b'foreign replacement media')
(directory / 'mutation-snapshot.json').write_text(json.dumps(snapshot(directory)))
os.execvp(sys.argv[3], sys.argv[3:])
''')
publication = r'''
fixture_directory=$2
fixture_mutator=$3
fixture_scenario=$4
PRIVATE_ARIA2_HELPER=$5
PATH_RECORD_FD_PATH=${fixture_directory}/path-record
PRIVATE_ARIA2_METADATA=${fixture_directory}/metadata
MEDIA_WORKSPACE=${fixture_directory}/local
FINAL_OUTPUT_DIR=${fixture_directory}/output
get_path_identity FINAL_OUTPUT_IDENTITY "${FINAL_OUTPUT_DIR}" directory
MODE=video
MACHINE_PROGRESS=true
validate_final_media_file() { return 0; }
run_supervised_command() {
    if python3 -I -B "${fixture_mutator}" "${fixture_directory}" "${fixture_scenario}" "$@"; then
        DOWNLOAD_STATUS=0
    else
        DOWNLOAD_STATUS=$?
    fi
}
validate_and_publish_result
'''
for scenario, status, stage in (('missing', 70, 'source-open'), ('replaced', 65, 'source-validation')):
    directory = root / ('publication-' + scenario)
    directory.mkdir(mode=0o700)
    for name in ('local', 'metadata', 'output'):
        (directory / name).mkdir(mode=0o700)
    candidate = directory / 'local' / 'validated.media'
    candidate.write_bytes(b'previously validated fixture')
    (directory / 'path-record').write_text(str(candidate) + '\n')
    (directory / 'output' / 'existing.media').write_bytes(b'existing destination media')
    result = run(publication, directory, mutator, scenario, sys.argv[3])
    assert result.returncode == status, ('source-race diagnostic changed the helper status',
                                        result.returncode, result.stderr)
    assert result.stdout.splitlines() == [
        'YTDLP_POSTPROCESS|started|MediaValidation',
        'YTDLP_POSTPROCESS|finished|MediaValidation',
        'YTDLP_POSTPROCESS|started|MediaPublication',
        'YTDLP_POSTPROCESS|error|MediaPublication',
    ], 'source-race publication protocol changed'
    assert f'stage={stage}' in result.stderr and 'source has not been verified' in result.stderr
    assert 'Validated local media retained at:' not in result.stderr, 'unverified source was advertised as retained'
    assert 'Media passed validation before publication.' in result.stderr
    assert 'Recheck the local recovery location before use: ' + str(candidate) in result.stderr
    assert 'Download completed successfully.' not in result.stderr
    assert snapshot(directory) == json.loads((directory / 'mutation-snapshot.json').read_text()), \
        'failed publication changed filesystem state after the fixture mutation'

dependency = r'''
command() { [[ $1 != -v || $2 != aria2c ]] && builtin command "$@"; }
initialize_runtime_dependencies
'''
result = run(dependency)
assert result.returncode == 127 and not result.stdout, 'dependency admission contract changed'
assert 'required command "aria2c" was not found.' in result.stderr
assert '[DEPENDENCY_MISSING]' in result.stderr
assert 'Install the package providing the command named above, then retry.' in result.stderr
PY_ENGINE_DIAGNOSTICS
}

test_mock_runtime_version_overflow() {
    local oversized_version_case

    # Fixed-width Bash arithmetic must never see unbounded external version
    # components. 2^64+1 wraps to 1 on common 64-bit Bash builds, so these
    # cases are a deterministic negative control for conversion-before-bound.
    for oversized_version_case in \
        '18446744073709551617.0.0' \
        '0000000000000000000018446744073709551617.0.0'; do
        rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
        prepare_argument_log "yt-version-overflow-${oversized_version_case//[^[:alnum:]]/_}"
        assert_status 0 "mathematically newer huge yt-dlp version ${oversized_version_case}" \
            env MOCK_YTDLP_VERSION="${oversized_version_case}" \
            "${PROJECT_DIR}/download-video.sh" \
            --output-dir "${OUTPUT_DIR}" \
            -- 'https://example.com/watch?v=huge-version'
    done
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'aria2-version-overflow'
    assert_status 0 'mathematically newer huge aria2 version is accepted safely' \
        env MOCK_ARIA2_VERSION='18446744073709551617.0.0' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://example.com/watch?v=huge-aria2-version'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'deno-version-overflow'
    assert_status 0 'mathematically newer huge Deno version is accepted safely' \
        env MOCK_DENO_VERSION='18446744073709551617.0.0' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://www.youtube.com/watch?v=huge-deno-version'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_runtime_media_validation() {
    local truncated_tail_result valid_tail_skew_result

    prepare_argument_log 'ffprobe-valid-av-tail-skew'
    valid_tail_skew_result="${TEST_ROOT}/valid-tail-skew-result.txt"
    rm -f -- "${valid_tail_skew_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm"
    assert_status 0 \
        'video remains valid when audio reaches the declared tail after content video ends' \
        env MOCK_FFPROBE_VIDEO_TAIL_PTS='90.000000' \
        MOCK_FFPROBE_VIDEO_TAIL_DURATION='0.000000' \
        MOCK_FFPROBE_AUDIO_TAIL_PTS='119.500000' \
        MOCK_FFPROBE_AUDIO_TAIL_DURATION='0.500000' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --result-file "${valid_tail_skew_result}" \
        -- 'https://example.com/watch?v=valid-av-tail-skew'
    [[ -s ${valid_tail_skew_result} ]] \
        || fail 'Valid A/V tail-skew media did not publish a result file.'
    rm -f -- "${valid_tail_skew_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'ffprobe-tail-truncation'
    truncated_tail_result="${TEST_ROOT}/truncated-tail-result.txt"
    rm -f -- "${truncated_tail_result}" \
        "${OUTPUT_DIR}/Mock media [abc123].webm"
    assert_status 65 \
        'metadata-parseable media whose primary stream ends far before the declared duration is rejected' \
        env MOCK_FFPROBE_TAIL_PTS='90.000000' \
        MOCK_FFPROBE_TAIL_DURATION='0.000000' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode video \
        --result-file "${truncated_tail_result}" \
        -- 'https://example.com/watch?v=truncated-tail'
    [[ ! -e ${truncated_tail_result} ]] \
        || fail 'Tail-truncated media published a result file.'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'final media file failed FFprobe validation' \
        'tail-truncation validation diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Media validation reason: tail-inconsistent' \
        'tail-truncation bounded reason'
    assert_text_contains "${ASSERT_OUTPUT}" \
        '[MEDIA_VALIDATION] Final media validation could not confirm the declared end of the media.' \
        'tail-truncation advice follows the verified reason'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
}

test_mock_runtime_dependencies() {
    local managed_deno_args managed_deno_output
    local -a managed_deno_arguments tls_transport_arguments

    prepare_argument_log 'aria2-gnutls-https-native-fallback'
    assert_status 0 'affected aria2 GnuTLS HTTPS uses native transport' \
        env MOCK_ARIA2_TLS_LIBRARY='GnuTLS/3.8.11' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=gnutls-native-fallback'
    [[ ! -s ${MOCK_ARIA2_ARG_LOG} ]] \
        || fail 'Affected aria2 GnuTLS build received a direct HTTPS transfer.'
    # shellcheck disable=SC2034 # Read through nameref assertion helpers.
    tls_transport_arguments=()
    read_arguments "${MOCK_ARG_LOG}" tls_transport_arguments
    assert_array_contains tls_transport_arguments '--load-info-json' \
        'affected aria2 GnuTLS build uses the frozen native yt-dlp plan'
    assert_array_not_contains tls_transport_arguments '--skip-download' \
        'affected aria2 GnuTLS build retains native yt-dlp transfer'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'aria2-fixed-gnutls-https-direct'
    assert_status 0 'fixed-generation aria2 GnuTLS permits direct HTTPS' \
        env MOCK_ARIA2_VERSION='1.38.0' \
        MOCK_ARIA2_TLS_LIBRARY='GnuTLS/3.8.11' \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=gnutls-direct-fixed'
    [[ -s ${MOCK_ARIA2_ARG_LOG} ]] \
        || fail 'Fixed-generation aria2 GnuTLS build did not use direct HTTPS.'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"

    prepare_argument_log 'missing-required-ytdlp-capability'
    assert_status 1 'yt-dlp builds missing a consumed option fail early' \
        env MOCK_YTDLP_MISSING_AUDIO_QUALITY=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=missing-ytdlp-capability'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'this yt-dlp build does not support --audio-quality.' \
        'missing consumed yt-dlp capability diagnostic'

    prepare_argument_log 'missing-fragment-abort-capability'
    assert_status 1 'yt-dlp without fragment abort fails before transfer' \
        env MOCK_YTDLP_MISSING_FRAGMENT_ABORT=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" --mode audio \
        -- 'https://example.com/watch?v=missing-fragment-abort'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'this yt-dlp build does not support --abort-on-unavailable-fragments.' \
        'missing fragment abort capability diagnostic'
    [[ ! -s ${MOCK_ARG_LOG} && ! -s ${MOCK_ARIA2_ARG_LOG} ]] \
        || fail 'Missing fragment abort capability reached the transfer.'

    assert_status 1 'old yt-dlp version is rejected' \
        env MOCK_YTDLP_VERSION=2026.06.08 \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://example.com/watch?v=old-yt-dlp'
    managed_deno_output="${TEST_ROOT}/managed-deno-output"
    managed_deno_args="${TEST_ROOT}/managed-deno-args.bin"
    mkdir -p -- "${managed_deno_output}"
    : >"${managed_deno_args}"
    assert_status 0 'YouTube accepts managed Deno outside PATH' \
        env PATH="${MOCK_NO_DENO_BIN}:/usr/bin:/bin" \
        YTDLP_ARIA2_DENO_BIN="${MOCK_BIN}/deno" \
        MOCK_ARG_LOG="${managed_deno_args}" \
        MOCK_OUTPUT_DIR="${managed_deno_output}" \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${managed_deno_output}" \
        -- 'https://www.youtube.com/watch?v=managed-deno-outside-path'
    # shellcheck disable=SC2034 # Accessed indirectly by name through read/assert helper APIs.
    managed_deno_arguments=()
    read_arguments "${managed_deno_args}" managed_deno_arguments
    assert_option_value managed_deno_arguments '--js-runtimes' \
        "deno:${MOCK_BIN}/deno" 'managed Deno absolute path outside PATH'
    assert_status 0 'generic extraction remains usable without Deno' \
        env MOCK_DENO_UNAVAILABLE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://example.com/watch?v=no-deno-generic'
    rm -f -- "${OUTPUT_DIR}/Mock media [abc123].webm"
    assert_status 1 'YouTube extraction requires Deno' \
        env MOCK_DENO_UNAVAILABLE=1 \
        "${PROJECT_DIR}/download-video.sh" \
        --output-dir "${OUTPUT_DIR}" \
        -- 'https://www.youtube.com/watch?v=no-deno-youtube'
    assert_status 1 'old Deno version is rejected' \
        env MOCK_DENO_VERSION=2.2.9 \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://www.youtube.com/watch?v=old-deno'
    assert_status 1 'old aria2c version is rejected' \
        env MOCK_ARIA2_VERSION=1.36.0 \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://example.com/watch?v=old-aria2'
    assert_status 1 'minimum Deno prerelease is rejected' \
        env MOCK_DENO_VERSION=2.3.0-beta \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://www.youtube.com/watch?v=prerelease-deno'
    assert_status 1 'minimum aria2 prerelease is rejected' \
        env MOCK_ARIA2_VERSION=1.37.0-beta \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://example.com/watch?v=prerelease-aria2'
    assert_status 1 'missing aria2c capability is rejected' \
        env MOCK_ARIA2_DESCRIPTION_ONLY=1 \
        "${PROJECT_DIR}/download-video.sh" \
        -- 'https://example.com/watch?v=missing-aria2-option'
}

test_mock_runtime_progress_errors() {
    local monitor_bundle monitor_question_log monitor_text_info_log
    local progress_error_marker progress_error_question_log progress_error_started
    local progress_error_text_info_log progress_timeout_marker
    local progress_timeout_question_log progress_timeout_started
    local progress_timeout_text_info_log
    local previous_media previous_media_identity previous_media_sha256
    local previous_media_final_identity previous_media_final_sha256
    local progress_timeout_output progress_error_output monitor_output

    # Regression guard: a completed download in the shared destination must
    # neither prevent these workers from starting nor be removed by their tests.
    previous_media="${OUTPUT_DIR}/Mock media [abc123].webm"
    if [[ ! -e ${previous_media} && ! -L ${previous_media} ]]; then
        printf '%s\n' 'Earlier completed media' >"${previous_media}"
    fi
    [[ -f ${previous_media} && ! -L ${previous_media} ]] \
        || fail 'Progress error fixture requires a regular previous media file.'
    previous_media_identity=$(stat -c '%d:%i:%s:%y:%z' -- "${previous_media}")
    previous_media_sha256=$(sha256sum -- "${previous_media}")

    # Each failure is injected after startup, so give it a fresh destination
    # independently of completed media from earlier scenarios in this group.
    progress_timeout_output="${TEST_ROOT}/progress-timeout-output"
    progress_error_output="${TEST_ROOT}/progress-error-output"
    monitor_output="${TEST_ROOT}/progress-monitor-output"
    mkdir -- "${progress_timeout_output}" "${progress_error_output}" \
        "${monitor_output}"

    # Progress-dialog timeout and unexpected error terminate the worker group.
    # Synchronize the injected Zenity failure with a worker-start marker so the
    # termination assertion proves signal delivery, not scheduler ordering.
    progress_timeout_started="${TEST_ROOT}/progress-timeout-started"
    progress_timeout_marker="${TEST_ROOT}/progress-timeout-terminated"
    progress_timeout_question_log="${TEST_ROOT}/progress-timeout-question.bin"
    progress_timeout_text_info_log="${TEST_ROOT}/progress-timeout-text-info.bin"
    rm -f -- "${progress_timeout_question_log}" \
        "${progress_timeout_text_info_log}"
    prepare_argument_log 'progress-timeout'
    assert_status 1 'progress dialog timeout is propagated' \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_OUTPUT_DIR="${progress_timeout_output}" \
        MOCK_LONG_DOWNLOAD=1 MOCK_ZENITY_PROGRESS_STATUS=5 \
        MOCK_ZENITY_WAIT_FOR_WORKER_START=1 \
        MOCK_STARTED_MARKER="${progress_timeout_started}" \
        MOCK_TERMINATION_MARKER="${progress_timeout_marker}" \
        MOCK_QUESTION_ARGS_LOG="${progress_timeout_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${progress_timeout_text_info_log}" \
        "${GUI_UNDER_TEST}"
    wait_for_file "${progress_timeout_started}" 10 \
        'progress-timeout worker started before injected timeout'
    wait_for_file "${progress_timeout_marker}" 10 \
        'progress-timeout worker receives TERM'
    assert_diagnostic_question "${progress_timeout_question_log}" \
        'progress dialog timed out' \
        'progress-timeout diagnostic'
    [[ ! -s ${progress_timeout_text_info_log} ]] \
        || fail 'Close unexpectedly opened the progress-timeout diagnostic log.'

    progress_error_started="${TEST_ROOT}/progress-error-started"
    progress_error_marker="${TEST_ROOT}/progress-error-terminated"
    progress_error_question_log="${TEST_ROOT}/progress-error-question.bin"
    progress_error_text_info_log="${TEST_ROOT}/progress-error-text-info.bin"
    rm -f -- "${progress_error_question_log}" \
        "${progress_error_text_info_log}"
    prepare_argument_log 'progress-error'
    assert_status 1 'unexpected progress dialog status is reported' \
        env MOCK_PLAN_PROTOCOL='m3u8_native' \
        MOCK_OUTPUT_DIR="${progress_error_output}" \
        MOCK_LONG_DOWNLOAD=1 MOCK_ZENITY_PROGRESS_STATUS=42 \
        MOCK_ZENITY_WAIT_FOR_WORKER_START=1 \
        MOCK_STARTED_MARKER="${progress_error_started}" \
        MOCK_TERMINATION_MARKER="${progress_error_marker}" \
        MOCK_QUESTION_ARGS_LOG="${progress_error_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${progress_error_text_info_log}" \
        "${GUI_UNDER_TEST}"
    wait_for_file "${progress_error_started}" 10 \
        'progress-error worker started before injected error'
    wait_for_file "${progress_error_marker}" 10 \
        'progress-error worker receives TERM'
    assert_diagnostic_question "${progress_error_question_log}" \
        'status 42' \
        'unexpected progress status diagnostic'
    [[ ! -s ${progress_error_text_info_log} ]] \
        || fail 'Close unexpectedly opened the progress-error diagnostic log.'

    monitor_bundle="${TEST_ROOT}/progress-monitor-failure-bundle"
    mkdir -p -- "${monitor_bundle}"
    install -m 0755 -- "${PROJECT_DIR}/download-video-gui.sh" \
        "${PROJECT_DIR}/download-video.sh" "${monitor_bundle}/"
    install -m 0644 -- "${PROJECT_DIR}/private-aria2-plan.py" \
        "${monitor_bundle}/private-aria2-plan.py"
    install -m 0644 -- "${PROJECT_DIR}/private-process-supervisor.py" \
        "${monitor_bundle}/private-process-supervisor.py"
    cat >"${monitor_bundle}/progress-monitor.sh" <<'EOF_PROGRESS_MONITOR_FAILURE'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : progress-monitor.sh
# Purpose     : Fail deterministically for GUI diagnostic integration coverage.
# ==============================================================================

set -euo pipefail

printf '%s\n' 'Simulated progress monitor diagnostic.' >&2
exit 42
EOF_PROGRESS_MONITOR_FAILURE
    chmod 0755 -- "${monitor_bundle}/progress-monitor.sh"
    monitor_question_log="${TEST_ROOT}/progress-monitor-question.bin"
    monitor_text_info_log="${TEST_ROOT}/progress-monitor-text-info.bin"
    rm -f -- "${monitor_question_log}" "${monitor_text_info_log}"
    prepare_argument_log 'progress-monitor-failure'
    assert_status 1 'progress monitor failure exposes its diagnostic' \
        env MOCK_GUI_REAL="${monitor_bundle}/download-video-gui.sh" \
        MOCK_OUTPUT_DIR="${monitor_output}" \
        MOCK_QUESTION_ARGS_LOG="${monitor_question_log}" \
        MOCK_TEXT_INFO_ARGS_LOG="${monitor_text_info_log}" \
        "${GUI_UNDER_TEST}"
    assert_diagnostic_question "${monitor_question_log}" \
        'The progress monitor failed with status 42.' \
        'progress-monitor failure diagnostic'
    [[ ! -s ${monitor_text_info_log} ]] \
        || fail 'Close unexpectedly opened the progress-monitor diagnostic log.'
    assert_no_test_processes 'progress-monitor failure left GUI descendants'
    previous_media_final_identity=$(stat -c '%d:%i:%s:%y:%z' -- "${previous_media}")
    previous_media_final_sha256=$(sha256sum -- "${previous_media}")
    assert_equals "${previous_media_identity}" \
        "${previous_media_final_identity}" \
        'progress errors preserve previous completed media identity'
    assert_equals "${previous_media_sha256}" \
        "${previous_media_final_sha256}" \
        'progress errors preserve previous completed media contents'
}

test_mock_runtime_missing_zenity() {
    local no_zenity_bin required_command required_command_path

    # Scenario: missing Zenity is a dependency error, not a graphical crash.
    no_zenity_bin="${TEST_ROOT}/no-zenity-bin"
    mkdir -p -- "${no_zenity_bin}"
    for required_command in \
        bash chmod date dirname grep mkdir mkfifo mktemp mv python3 realpath rm sed setsid sleep \
        stat tail timeout flock sha256sum; do
        required_command_path=$(command -v "${required_command}") \
            || fail "Required host command was not found: ${required_command}"
        ln -s -- "${required_command_path}" \
            "${no_zenity_bin}/${required_command}"
    done
    assert_status 127 'missing Zenity is reported before GUI startup' \
        env PATH="${no_zenity_bin}" HOME="${HOME_DIR}" \
        "${GUI_UNDER_TEST}"
    assert_text_contains "${ASSERT_OUTPUT}" 'required command "zenity" was not found' \
        'missing Zenity diagnostic'
    assert_text_contains "${ASSERT_OUTPUT}" \
        '[DEPENDENCY_MISSING] Dependency check failed.' \
        'missing Zenity identifies dependency admission'
    assert_text_contains "${ASSERT_OUTPUT}" \
        'Install the package providing the command named above, then retry.' \
        'missing dependency gives a bounded corrective action'
}

run_mock_runtime_compat_group() {
    test_mock_locale_contracts
    test_mock_managed_runtime_attestation
    test_mock_runtime_version_formats
    test_mock_runtime_version_overflow
    test_mock_runtime_dependencies
}

run_mock_runtime_validation_group() {
    test_mock_runtime_worker_failure
    test_mock_runtime_media_validation
    test_mock_runtime_progress_errors
    test_mock_runtime_missing_zenity
}

run_mock_runtime_group() {
    test_mock_locale_contracts
    test_mock_managed_runtime_attestation
    test_mock_runtime_version_formats
    test_mock_runtime_worker_failure
    test_mock_runtime_version_overflow
    test_mock_runtime_media_validation
    test_mock_runtime_dependencies
    test_mock_runtime_progress_errors
    test_mock_runtime_missing_zenity
}

run_selected_mock_runtime_group() {
    case ${MOCK_GROUP} in
        all | runtime) run_mock_runtime_group ;;
        runtime-compat) run_mock_runtime_compat_group ;;
        locale) test_mock_locale_contracts ;;
        runtime-validation) run_mock_runtime_validation_group ;;
        *) ;;
    esac
}
