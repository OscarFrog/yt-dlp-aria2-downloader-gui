#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : test-static.sh
# Purpose     : Validate static project invariants and release-version coherence.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/tests/lib/assert.sh"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/tests/lib/project-files.sh"

if ((${#ALL_SHELL_FILES[@]} == 0)); then
    printf 'Error: ALL_SHELL_FILES is empty.\n' >&2
    exit 65
fi
# Contract: every canonical shell file uses the standard header.
readonly STANDARD_HEADER_PROJECT='yt-dlp-aria2-downloader-gui'
readonly STANDARD_HEADER_SEPARATOR='# =============================================================================='
SHELL_INVENTORY_FILE=''

assert_standard_shell_header() {
    local relative_path=$1
    local absolute_path="${SCRIPT_DIR}/${relative_path}"
    local shebang=''
    local spdx=''
    local separator_open=''
    local project_line=''
    local file_line=''
    local purpose_line=''
    local separator_close=''
    local spacer='nonempty'

    if ! {
        IFS= read -r shebang || true
        IFS= read -r spdx || true
        IFS= read -r separator_open || true
        IFS= read -r project_line || true
        IFS= read -r file_line || true
        IFS= read -r purpose_line || true
        IFS= read -r separator_close || true
        IFS= read -r spacer || true
    } <"${absolute_path}"; then
        printf 'FAIL: unable to read canonical shell file: %s.\n' \
            "${relative_path}" >&2
        return 65
    fi

    [[ ${shebang} == '#!'* ]] || {
        printf 'FAIL: missing shebang in %s.\n' "${relative_path}" >&2
        return 65
    }
    [[ ${spdx} == '# SPDX-License-Identifier: MIT' ]] || {
        printf 'FAIL: non-standard SPDX header in %s.\n' "${relative_path}" >&2
        return 65
    }
    [[ ${separator_open} == "${STANDARD_HEADER_SEPARATOR}" &&
        ${separator_close} == "${STANDARD_HEADER_SEPARATOR}" ]] || {
        printf 'FAIL: non-standard header separator in %s.\n' "${relative_path}" >&2
        return 65
    }
    [[ ${project_line} == "# Project     : ${STANDARD_HEADER_PROJECT}" ]] || {
        printf 'FAIL: non-standard project header in %s.\n' "${relative_path}" >&2
        return 65
    }
    [[ ${file_line} == "# File        : ${relative_path}" ]] || {
        printf 'FAIL: non-standard file header in %s.\n' "${relative_path}" >&2
        return 65
    }
    [[ ${purpose_line} == '# Purpose     : '* &&
        ${purpose_line} != '# Purpose     : ' ]] || {
        printf 'FAIL: missing purpose header in %s.\n' "${relative_path}" >&2
        return 65
    }
    [[ -z ${spacer} ]] || {
        printf 'FAIL: missing blank line after standard header in %s.\n' "${relative_path}" >&2
        return 65
    }
    return 0
}

is_main_exempt_shell_file() {
    local relative_path=$1
    local exempt_file

    for exempt_file in "${MAIN_EXEMPT_SHELL_FILES[@]}"; do
        if [[ ${relative_path} == "${exempt_file}" ]]; then
            return 0
        fi
    done
    return 1
}

assert_main_entry_structure() {
    local relative_path=$1
    local absolute_path="${SCRIPT_DIR}/${relative_path}"
    local main_count=''
    local last_nonblank=''

    # Predicate failure is the expected non-exempt path.
    # shellcheck disable=SC2310
    if is_main_exempt_shell_file "${relative_path}"; then
        return 0
    fi

    main_count=$(grep -Ec '^main\(\) \{$' "${absolute_path}" || true)
    if [[ ${main_count} != 1 ]]; then
        printf 'FAIL: expected exactly one top-level main() in %s; found %s.\n' \
            "${relative_path}" "${main_count}" >&2
        return 65
    fi

    last_nonblank=$(awk 'NF { last = $0 } END { print last }' "${absolute_path}")
    if [[ ${last_nonblank} != 'main "$@"' ]]; then
        printf 'FAIL: final executable entry point is not main "$@" in %s.\n' \
            "${relative_path}" >&2
        return 65
    fi
    return 0
}

# Permanent shell comments use durable terminology.
assert_no_historical_comment_labels() {
    local relative_path=$1
    local absolute_path="${SCRIPT_DIR}/${relative_path}"
    local historical_regex='^[[:space:]]*#[[:space:]]*((P[A]TCH|A[U]D)-[0-9]+|Version[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+)'

    if grep -En -- "${historical_regex}" "${absolute_path}" >/dev/null; then
        printf 'FAIL: historical patch/audit/version label found in %s.\n' \
            "${relative_path}" >&2
        grep -En -- "${historical_regex}" "${absolute_path}" >&2 || true
        return 65
    fi
    return 0
}

cleanup_static_test() {
    if [[ -n ${SHELL_INVENTORY_FILE} ]]; then
        rm -f -- "${SHELL_INVENTORY_FILE}" || true
        SHELL_INVENTORY_FILE=''
    fi
}

assert_shell_inventory_is_canonical() {
    local candidate=''
    local first_line=''
    local canonical=''
    local matched=false
    local is_shell_candidate=false
    local inventory_status=0
    local inventory_is_absolute=false

    if ! SHELL_INVENTORY_FILE=$(mktemp); then
        printf 'FAIL: unable to create the shell-inventory scratch file.\n' >&2
        return 70
    fi

    if [[ -e ${SCRIPT_DIR}/.git || -L ${SCRIPT_DIR}/.git ]]; then
        if ! git -c "safe.directory=${SCRIPT_DIR}" -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            cleanup_static_test
            printf 'FAIL: unable to validate the project Git worktree.\n' >&2
            return 65
        fi

        if ! git -c "safe.directory=${SCRIPT_DIR}" -C "${SCRIPT_DIR}" ls-files -co --exclude-standard -z >"${SHELL_INVENTORY_FILE}"; then
            cleanup_static_test
            printf 'FAIL: unable to enumerate tracked/non-ignored project files.\n' >&2
            return 65
        fi
    else
        inventory_is_absolute=true
        if ! find "${SCRIPT_DIR}" -type f -print0 >"${SHELL_INVENTORY_FILE}"; then
            cleanup_static_test
            printf 'FAIL: unable to enumerate Git-free source-archive files.\n' >&2
            return 65
        fi
    fi

    while IFS= read -r -d '' candidate; do
        if [[ ${inventory_is_absolute} == true ]]; then
            candidate=${candidate#"${SCRIPT_DIR}/"}
        fi
        [[ -f ${SCRIPT_DIR}/${candidate} ]] || continue

        first_line=''
        IFS= read -r first_line <"${SCRIPT_DIR}/${candidate}" || true
        is_shell_candidate=false

        if [[ ${candidate} == *.sh ]]; then
            is_shell_candidate=true
        fi

        case ${first_line} in
            '#!/usr/bin/env bash' | '#!/bin/bash' | '#!/bin/sh' | '#!/usr/bin/env sh')
                is_shell_candidate=true
                ;;
            *)
                ;;
        esac

        [[ ${is_shell_candidate} == true ]] || continue

        matched=false
        for canonical in "${ALL_SHELL_FILES[@]}"; do
            if [[ ${candidate} == "${canonical}" ]]; then
                matched=true
                break
            fi
        done

        if [[ ${matched} != true ]]; then
            printf 'FAIL: shell file is not in the canonical inventory: %s\n' \
                "${candidate}" >&2
            inventory_status=65
            break
        fi
    done <"${SHELL_INVENTORY_FILE}"

    cleanup_static_test
    return "${inventory_status}"
}

workflow_job_block() {
    local workflow=$1
    local job_id=$2

    awk -v job_id="${job_id}" '
        /^jobs:[[:space:]]*$/ {
            in_jobs = 1
            next
        }
        in_jobs && $0 ~ "^  " job_id ":[[:space:]]*$" {
            in_job = 1
            print
            next
        }
        in_job && $0 ~ /^  [[:alnum:]_-]+:[[:space:]]*$/ {
            exit
        }
        in_job {
            print
        }
    ' "${workflow}"
}

shfmt_candidate_job_policy() {
    local job_block=$1

    [[ ${job_block} == *'permissions:'* ]] || return 65
    [[ ${job_block} == *'contents: read'* ]] || return 65
    if grep -Eq '^[[:space:]]+[[:alnum:]_-]+:[[:space:]]+write[[:space:]]*$' \
        <<<"${job_block}"; then
        return 65
    fi
    # shellcheck disable=SC2016 # Literal GitHub Actions expression, not shell expansion.
    [[ ${job_block} != *'${{ secrets.'* ]] || return 65
    [[ ${job_block} == *'bash ./scripts/format-shell.sh'* ]] || return 65
    [[ ${job_block} == *'bash ./tests/run-all.sh'* ]] || return 65
    [[ ${job_block} == *'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'* ]] || return 65
    [[ ${job_block} == *"if: steps.detect.outputs.update == 'true'"* ]] || return 65
    return 0
}

shfmt_publish_job_policy() {
    local job_block=$1

    [[ ${job_block} == *'permissions:'* ]] || return 65
    [[ ${job_block} == *'contents: write'* ]] || return 65
    [[ ${job_block} == *'pull-requests: write'* ]] || return 65
    [[ ${job_block} == *"if: needs.prepare-shfmt-update.outputs.update == 'true'"* ]] || return 65
    [[ ${job_block} == *'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'* ]] || return 65
    # shellcheck disable=SC2016 # Literal GitHub Actions expression, not shell expansion.
    [[ ${job_block} == *'ref: ${{ needs.prepare-shfmt-update.outputs.base_sha }}'* ]] || return 65
    [[ ${job_block} == *'actions/download-artifact@70fc10c6e5e1ce46ad2ea6f2b72d43f7d47b13c3'* ]] || return 65
    [[ ${job_block} == *'git fetch --no-tags origin'* ]] || return 65
    [[ ${job_block} == *'python3 - tests/lib/project-files.sh'* ]] || return 65
    [[ ${job_block} != *'git ls-files -z'* ]] || return 65
    [[ ${job_block} == *'git apply --check'* ]] || return 65
    [[ ${job_block} == *'comm -23'* ]] || return 65
    [[ ${job_block} == *'git diff --summary'* ]] || return 65
    [[ ${job_block} == *'core.hooksPath=/dev/null'* ]] || return 65
    [[ ${job_block} != *'scripts/format-shell.sh'* ]] || return 65
    [[ ${job_block} != *'scripts/dev-tools/ensure-shfmt.sh'* ]] || return 65
    [[ ${job_block} != *'bash ./tests/run-all.sh'* ]] || return 65
    if grep -Eq '^[[:space:]]+(bash[[:space:]]+\./|source[[:space:]]+\./|\./(tests|scripts)/)' \
        <<<"${job_block}"; then
        return 65
    fi
    return 0
}

assert_shfmt_update_workflow_policy() {
    local workflow="${SCRIPT_DIR}/.github/workflows/shfmt-update.yml"
    local candidate_block=''
    local publish_block=''
    local mutated=''

    candidate_block=$(workflow_job_block "${workflow}" prepare-shfmt-update)
    publish_block=$(workflow_job_block "${workflow}" publish-shfmt-pr)

    [[ -n ${candidate_block} ]] \
        || fail 'shfmt updater read-only candidate job is missing.'
    [[ -n ${publish_block} ]] \
        || fail 'shfmt updater privileged publication job is missing.'

    # Policy helpers are explicit-status predicates and intentionally do not rely
    # on errexit inside their bodies.
    # shellcheck disable=SC2310
    shfmt_candidate_job_policy "${candidate_block}" \
        || fail 'shfmt updater candidate job violates the read-only trust boundary.'
    # shellcheck disable=SC2310
    shfmt_publish_job_policy "${publish_block}" \
        || fail 'shfmt updater publication job violates the privileged trust boundary.'

    mutated=${candidate_block//contents: read/contents: write}
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_candidate_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject candidate repository write permission.'
    fi

    mutated="${publish_block}"$'\n''      bash ./scripts/format-shell.sh'
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_publish_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject candidate-code execution in publication.'
    fi

    mutated=${publish_block//git apply --check/git apply}
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_publish_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject removal of git apply --check.'
    fi

    mutated=${publish_block//comm -23/comm -13}
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_publish_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject removal of the patch path allowlist.'
    fi

    mutated=${publish_block//core.hooksPath=\/dev\/null/core.hooksPath=.git\/hooks}
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_publish_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject privileged Git hooks.'
    fi
}

main() {
    trap cleanup_static_test EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    assert_shell_inventory_is_canonical
    assert_shfmt_update_workflow_policy

    assert_file_contains "${SCRIPT_DIR}/.editorconfig" \
        'indent_size = 4' \
        'EditorConfig keeps the four-space project indentation'
    assert_file_contains "${SCRIPT_DIR}/.editorconfig" \
        'binary_next_line = true' \
        'EditorConfig keeps binary operators on continuation lines'
    assert_file_contains "${SCRIPT_DIR}/.editorconfig" \
        'switch_case_indent = true' \
        'EditorConfig indents case bodies'
    assert_file_contains "${SCRIPT_DIR}/.editorconfig" \
        'simplify = false' \
        'EditorConfig disables shfmt simplification'
    assert_file_contains "${SCRIPT_DIR}/tests/run-all.sh" \
        'bash -- ./scripts/check-shell-format.sh' \
        'run-all enforces shfmt before behavioral validation'

    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--max-concurrent-downloads' \
        'download-video keeps the aria2 concurrent-download capability contract'
    assert_file_contains "${SCRIPT_DIR}/tests/hls-remux-duration-integration.sh" \
        '--max-concurrent-downloads=<N>' \
        'HLS aria2 mock advertises the required concurrent-download capability'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'repos/mvdan/sh/releases/latest' \
        'automation discovers the latest stable upstream shfmt release'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'bash ./scripts/format-shell.sh' \
        'automation reformats with the candidate shfmt release'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'bash ./tests/run-all.sh' \
        'automation validates the formatter update before PR creation'

    for file in "${ALL_SHELL_FILES[@]}"; do
        assert_standard_shell_header "${file}"
        assert_main_entry_structure "${file}"
    done

    for file in "${ALL_SHELL_FILES[@]}"; do
        assert_no_historical_comment_labels "${file}"
    done

    for file in "${ALL_SHELL_FILES[@]}"; do
        bash -n -- "${SCRIPT_DIR}/${file}"
    done

    assert_status 0 'download engine help' \
        "${SCRIPT_DIR}/download-video.sh" --help
    assert_status 0 'download engine version' \
        "${SCRIPT_DIR}/download-video.sh" --version

    assert_status_split 0 'help stream separation' \
        "${SCRIPT_DIR}/download-video.sh" --help
    assert_text_contains "${ASSERT_STDOUT}" 'Usage:' 'help is written to stdout'
    assert_equals '' "${ASSERT_STDERR}" 'help leaves stderr empty'

    assert_status_split 2 'error stream separation' \
        "${SCRIPT_DIR}/download-video.sh"
    assert_equals '' "${ASSERT_STDOUT}" 'missing URL leaves stdout empty'
    assert_text_contains "${ASSERT_STDERR}" 'a video URL is required.' \
        'missing URL is written to stderr'

    assert_status 2 'invalid mode is rejected' \
        "${SCRIPT_DIR}/download-video.sh" --mode invalid \
        'https://example.com/video'
    assert_text_contains "${ASSERT_OUTPUT}" '--mode must be video or audio.' \
        'invalid mode diagnostic'

    assert_status 2 'removed audio-format option is rejected' \
        "${SCRIPT_DIR}/download-video.sh" --audio-format mp3 \
        'https://example.com/video'
    assert_text_contains "${ASSERT_OUTPUT}" 'unknown option: --audio-format' \
        'audio-format rejection reason'

    assert_status 2 'removed audio-quality option is rejected' \
        "${SCRIPT_DIR}/download-video.sh" --audio-quality 0 \
        'https://example.com/video'
    assert_text_contains "${ASSERT_OUTPUT}" 'unknown option: --audio-quality' \
        'audio-quality rejection reason'

    assert_status 2 'URL line breaks are rejected' \
        "${SCRIPT_DIR}/download-video.sh" $'https://example.com/a\nb'
    assert_text_contains "${ASSERT_OUTPUT}" 'must not contain line breaks' \
        'URL line-break diagnostic'

    assert_status 2 'two positional URLs are rejected' \
        "${SCRIPT_DIR}/download-video.sh" \
        'https://example.com/a' 'https://example.com/b'
    assert_text_contains "${ASSERT_OUTPUT}" 'exactly one video URL is required.' \
        'multiple URL diagnostic'

    assert_status 2 'a second URL after -- is rejected' \
        "${SCRIPT_DIR}/download-video.sh" \
        'https://example.com/a' -- 'https://example.com/b'
    assert_text_contains "${ASSERT_OUTPUT}" 'exactly one video URL is required.' \
        'multiple URL after separator diagnostic'

    assert_status 2 'installer requires one command' \
        "${SCRIPT_DIR}/install-gui.sh"

    assert_file_contains \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        'LC_ALL=C setsid --fork --wait bash -c' \
        'GUI worker locale stabilization'

    # shellcheck disable=SC2016 # Literal source probes; do not expand variables here.
    engine_locale_probes=(
        'LC_ALL=C "${YTDLP_BIN}" --version'
        'LC_ALL=C "${YTDLP_BIN}" --help'
        'LC_ALL=C "${DENO_BIN}" --version'
        'LC_ALL=C aria2c --version'
        'LC_ALL=C aria2c --help=#all'
    )

    for required_probe in "${engine_locale_probes[@]}"; do
        assert_file_contains \
            "${SCRIPT_DIR}/download-video.sh" \
            "${required_probe}" \
            "locale-stabilized probe ${required_probe}"
    done

    assert_file_contains \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        'LC_ALL=C setsid --help' \
        'setsid capability probe locale stabilization'

    assert_file_contains \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        "pgid_temporary=\"\${pgid_file}.tmp\"" \
        'atomic PGID staging file'
    assert_file_contains \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        "mv -Tf -- \"\${pgid_temporary}\" \"\${pgid_file}\"" \
        'atomic PGID publication'
    assert_file_contains \
        "${SCRIPT_DIR}/download-video-gui.sh" \
        "trap '' HUP INT TERM" \
        'cleanup signal protection'
    assert_file_contains \
        "${SCRIPT_DIR}/progress-monitor.sh" \
        '^\[#([[:xdigit:]]+)[[:space:]]' \
        'aria2 progress without mandatory percentage'
    assert_file_contains \
        "${SCRIPT_DIR}/progress-monitor.sh" \
        'parse_aria_size() {' \
        'aria2 human-readable byte counters are parsed for weighted progress'
    assert_file_contains \
        "${SCRIPT_DIR}/install-gui.sh" \
        "readonly LAUNCHER_LINK=\"\${LAUNCHER_DIR}/launch\"" \
        'stable desktop launcher link'
    assert_file_contains \
        "${SCRIPT_DIR}/install-gui.sh" \
        "desktop-file-validate \\" \
        'desktop launcher validation'
    # shellcheck disable=SC2016 # Literal shell-source assertions.
    assert_file_contains "${SCRIPT_DIR}/tests/mock-integration.sh" \
        'readonly TEST_OWNER_BASHPID=${BASHPID}' \
        'mock-suite cleanup owner identity'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/tests/mock-integration.sh" \
        '[[ ${BASHPID} != "${TEST_OWNER_BASHPID}" ]]' \
        'non-owner test cleanup protection'
    readonly EXPECTED_VERSION='2.2.3'

    # Current-version coherence is intentionally checked only on authoritative
    # carriers. Historical versions used by regression/upgrade fixtures are valid
    # test data and must not be treated as stale release metadata.
    engine_reported_version=$("${SCRIPT_DIR}/download-video.sh" --version)
    assert_equals \
        "download-video.sh version ${EXPECTED_VERSION}" \
        "${engine_reported_version}" \
        'engine reported version'

    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        "readonly VERSION=\"${EXPECTED_VERSION}\"" \
        'engine version constant'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        "readonly APP_VERSION='${EXPECTED_VERSION}'" \
        'Fedora bootstrap application version'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "is **${EXPECTED_VERSION}**." \
        'English README version'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "version actuelle est la **${EXPECTED_VERSION}**." \
        'French README version'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "Release ${EXPECTED_VERSION} publishes an architecture-independent DEB" \
        'English README current DEB release prose'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "La release ${EXPECTED_VERSION} publie un DEB indépendant de l'architecture" \
        'French README current DEB release prose'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "cd yt-dlp-aria2-downloader-gui-${EXPECTED_VERSION}" \
        'English README portable archive directory'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "cd yt-dlp-aria2-downloader-gui-${EXPECTED_VERSION}" \
        'French README portable archive directory'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "gh release verify v${EXPECTED_VERSION} -R OscarFrog/yt-dlp-aria2-downloader-gui" \
        'English README current release verification tag'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "gh release verify v${EXPECTED_VERSION} -R OscarFrog/yt-dlp-aria2-downloader-gui" \
        'French README current release verification tag'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "-f tag=v${EXPECTED_VERSION}" \
        'English README manual release tag input'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "-f tag=v${EXPECTED_VERSION}" \
        'French README manual release tag input'
    assert_file_contains "${SCRIPT_DIR}/CHANGELOG.md" \
        "## ${EXPECTED_VERSION} - " \
        'changelog current-version heading'

    # The release workflow must derive the release version from the tag and compare
    # it with executable/constants-based project version carriers, never comments.
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'reported_version=$(./download-video.sh --version)' \
        'release validates executable-reported version'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        '[[ ${reported_version} == "${version}" ]]' \
        'release binds executable version to release tag'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'grep -Fqx "readonly VERSION=\"${version}\"" download-video.sh' \
        'release validates engine version constant'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'grep -Fqx "readonly APP_VERSION='\''${version}'\''" install-fedora.sh' \
        'release validates Fedora bootstrap version constant'
    # Header metadata is intentionally version-agnostic; release coherence is
    # verified through authoritative version carriers.
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'readonly LOG_RETENTION_DAYS=15' \
        'GUI retained-log lifetime'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        '--width=620' \
        'profile dialog width'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        '--height=305' \
        'profile dialog height'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'readonly PROGRESS_DIALOG_WIDTH=700' \
        'progress dialog width'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'process_is_running() {' \
        'zombie-aware worker liveness check'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        "bash \"\${PROGRESS_MONITOR}\"" \
        'GUI delegates progress parsing to the unified monitor'
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        'IFS= read -r -N 65536 chunk <&3' \
        'progress log is consumed incrementally without an asynchronous reader pipeline'
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        "pending_data+=\${chunk}" \
        'partial progress records are retained across reads'
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        "emit_progress 100 'Download complete.'" \
        '100 percent is emitted only by final result verification'
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        "trap 'exit 0' PIPE" \
        'closed Zenity pipe ends the monitor normally'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'normalize_path_record() {' \
        'final result path record normalization'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'normalize_path_record "${PATH_RECORD_TMP}" "${OUTPUT_DIR}"' \
        'final result path confinement to the destination directory'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'mv -nT -- "${RESULT_FILE_TMP}" "${RESULT_FILE}"' \
        'result-file no-clobber publication'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        'RESOLVED_KEY="native:$((seen_items + 1))"' \
        'progress uses opaque internal item keys'
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        'MAX_PENDING_CHARS=1048576' \
        'progress pending-record memory bound'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'acquire_output_lock "${OUTPUT_DIR}"' \
        'engine destination-directory lock'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'flock --exclusive --nonblock "${OUTPUT_LOCK_FD}"' \
        'nonblocking destination lock acquisition'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'kill -0 -- "-${WORKER_PGID}"' \
        'worker group remains tracked after supervisor exit'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'the result-file already exists; refusing to overwrite it.' \
        'existing result files are protected'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'the final MKV already exists; refusing to overwrite it:' \
        'existing HLS MKV files are protected'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        "monitor_status=\${pipeline_status[0]:-1}" \
        'technical progress-monitor status is checked'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'final media file could not be confirmed inside the selected destination folder' \
        'GUI result path is constrained to the selected destination'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        'strict semantic release tag validation'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shell.yml" \
        'cancel-in-progress: true' \
        'outdated validation runs are cancelled'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'Qualify RPM v4/v6 signature semantics (3x)' \
        'PR CI qualifies RPM v4/v6 signature semantics'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'Qualify release RPM v4/v6 signature semantics (3x)' \
        'release CI qualifies RPM v4/v6 signature semantics'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'unsigned release RPM uses unexpected package format' \
        'release signer requires RPM format v4 before signing'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        '--define "_keyring fs"' \
        'release signer verifies through an isolated RPM fs keyring'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'unset RPM_SIGNING_PRIVATE_KEY_B64 RPM_SIGNING_PASSPHRASE' \
        'release signing secrets are removed from the shell environment after materialization'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        "gpgconf --homedir \"\${signing_home}\" --kill gpg-agent" \
        'release signing agent is explicitly terminated'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'Fresh-download public release verification' \
        'release performs independent fresh-download verification'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'public asset differs byte-for-byte from tested artifact' \
        'public release assets are compared byte-for-byte with tested artifacts'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'manual release recovery must run from a tag ref' \
        'manual release recovery is bound to an exact tag ref'
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        '--confirm-single-maintainer-self-review' \
        'release preflight requires explicit single-maintainer self-review acknowledgement'
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        'single-maintainer rpm-signing must allow self-review.' \
        'release preflight verifies self-review remains enabled for the sole maintainer'
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        'sole rpm-signing reviewer must match the authenticated maintainer' \
        'release preflight binds the sole reviewer to the authenticated maintainer'
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        "readonly RELEASE_TAG_SIGNING_FINGERPRINT='43E5361414863738F0324F2B047B26057E612CDC'" \
        'release preflight pins the authorized Git tag signer'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        'git verify-tag --raw "${release_tag}"' \
        'release preflight obtains machine-readable tag verification status'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        '${tag_primary_fingerprint} == "${RELEASE_TAG_SIGNING_FINGERPRINT}"' \
        'release preflight authorizes the exact tag signer fingerprint'
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        'git rev-parse --show-toplevel' \
        'release preflight resolves the actual repository root'
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        'unable to query the project version.' \
        'release preflight diagnoses project-version lookup failure'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/packaging/package-user-cleanup.sh" \
        '${path} != *[[:cntrl:]]*' \
        'package cleanup rejects marker path control characters'
    assert_file_contains "${SCRIPT_DIR}/packaging/package-user-cleanup.sh" \
        'unable to enumerate users from /etc/passwd or getent; skipping all-user cleanup' \
        'package cleanup diagnoses unavailable enumeration sources'

    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'hls_duration_loss_us > hls_duration_tolerance_us' \
        'HLS post-remux duration loss is bounded before publication'
    assert_file_contains "${SCRIPT_DIR}/tests/real-tools-integration.sh" \
        "--downloader 'dash,m3u8:native'" \
        'real-tool qualification defends native DASH/HLS routing'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/real-tools.yml" \
        'schedule:' \
        'current stable yt-dlp is checked on a scheduled workflow'
    assert_file_contains "${SCRIPT_DIR}/tests/lib/project-files.sh" \
        'tests/aria2-real-behavior-integration.sh' \
        'real aria2 behavior test is part of canonical shell validation'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/real-tools.yml" \
        'Run aria2 direct-transfer behavior qualification' \
        'PR/current-stable CI gates real aria2 direct-transfer behavior'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'Run aria2 direct-transfer behavior qualification' \
        'release CI gates real aria2 direct-transfer behavior'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'Run HLS post-remux duration validation (3x)' \
        'release qualification gates HLS duration validation'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'Run real FFmpeg progress integration' \
        'release qualification gates real FFmpeg progress'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/stress.yml" \
        'Mock process/cancellation stress (20x deterministic jitter)' \
        'race-sensitive mock qualification uses twenty deterministic jitter passes'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/stress.yml" \
        'Package cleanup hardening stress (10x)' \
        'package cleanup safety is repeatedly stress-tested'

    assert_file_contains \
        "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh" \
        '--define "_rpmformat 4"' \
        'RPM package format is explicitly pinned to v4'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains \
        "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh" \
        'if [[ ${package_format} != 4 ]]; then' \
        'generated RPM package format is independently verified'

    rpm_changelog=$(
        awk '
            /^%changelog[[:space:]]*$/ { in_changelog=1; next }
            in_changelog { print }
        ' "${SCRIPT_DIR}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec"
    )
    assert_text_not_contains "${rpm_changelog}" '%{version}' \
        'RPM historical changelog does not use the current version macro'
    assert_text_not_contains "${rpm_changelog}" '%{project_version}' \
        'RPM historical changelog does not use the project version macro'
    assert_text_contains "${rpm_changelog}" ' - 2.1.20-1' \
        'RPM historical 2.1.20 version is stable'
    assert_text_contains "${rpm_changelog}" ' - 2.1.24-1' \
        'RPM historical 2.1.24 version is stable'
    assert_text_contains "${rpm_changelog}" ' - 2.1.25-1' \
        'RPM historical 2.1.25 version is stable'

    assert_file_contains "${SCRIPT_DIR}/QUALIFICATION_2.2.0.md" \
        '**Historical qualification document.**' \
        '2.2.0 qualification is explicitly historical'
    assert_file_contains "${SCRIPT_DIR}/QUALIFICATION_2.2.0.md" \
        '**Post-release verification — 2026-08-25.**' \
        '2.2.0 qualification contains a post-release verification note'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'recover_abandoned_private_aria2_staging' \
        'engine recovers validated abandoned private aria2 staging'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        "readonly PRIVATE_ARIA2_STAGING_MARKER='.yt-dlp-aria2-owner-v1'" \
        'new private aria2 staging carries a durable owner marker'
    assert_file_contains "${SCRIPT_DIR}/tests/aria2-auth-headers-integration.sh" \
        'unsafe mutant demonstrates real aria2 cross-origin replay' \
        'private aria2 cross-origin replay has a negative mutation control'

    assert_file_contains \
        "${SCRIPT_DIR}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
        '%dir %{_docdir}/%{name}' \
        'RPM owns its application documentation directory'
    assert_file_contains \
        "${SCRIPT_DIR}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
        "if [ \"\$1\" -eq 0 ]; then" \
        'RPM user cleanup runs only on final erase'
    assert_file_contains "${SCRIPT_DIR}/packaging/deb/prerm" \
        "if [ \"\$#\" -eq 1 ] && [ -x \"\${HELPER}\" ]; then" \
        'DEB user cleanup excludes remove-in-favour replacement'
    assert_file_contains "${SCRIPT_DIR}/packaging/install-tree.sh" \
        'packaging/package-user-cleanup.sh' \
        'package tree ships user cleanup helper'

    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        "readonly RPM_SIGNING_FINGERPRINT='7B54065FE061E78ED2C96252E3BE996196ABEA7F'" \
        'Fedora bootstrap pins the RPM signing fingerprint'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        "readonly RPM_SIGNING_SUBKEY_FINGERPRINT='1F5B769CE48A08AAC0A7D9DDECC9894B41830245'" \
        'Fedora bootstrap pins the dedicated RPM signing subkey'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '--define "_keyring fs"' \
        'Fedora bootstrap uses RPM 6 filesystem keyring isolation'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '--define "_keyringpath ${rpm_verify_keyring}"' \
        'Fedora bootstrap places trusted keys in its private verification keyring'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '--define "_rpmlock_path ${rpm_verify_keyring}/.rpm.lock"' \
        'Fedora bootstrap redirects the RPM transaction lock into its private verification root'
    assert_file_not_contains "${SCRIPT_DIR}/install-fedora.sh" \
        'OPENPGP:pgpsig' \
        'Fedora bootstrap does not use the display-only RPM Key ID as a full fingerprint'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        'signing_subkey_count=$(' \
        'Fedora bootstrap requires exactly one usable signing subkey in the pinned certificate'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        '--key-id "${RPM_SIGNING_SUBKEY_FINGERPRINT}"' \
        'release signing requests the dedicated signing subkey'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'signing_subkey_count=$(' \
        'release public certificate permits exactly one usable signing subkey'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'imported_signing_subkey_count=$(' \
        'release secret bundle permits exactly one usable signing subkey'
    # shellcheck disable=SC2016
    assert_file_not_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'signer_output=$(LC_ALL=C rpm -qp' \
        'release signing does not treat RPM display Key ID as a full fingerprint'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        '--define "_rpmlock_path ${wrong_verify_keyring}/.rpm.lock"' \
        'release wrong-signer proof uses an isolated writable RPM fs keyring'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'Reject a different globally trusted RPM signer' \
        'release CI reproduces and rejects the 2.1.28 wrong-signer scenario'
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        "readonly RUNTIME_OWNER_SENTINEL='.package-runtime-owner-v1'" \
        'runtime manager records a custom-XDG ownership sentinel'
    assert_file_contains "${SCRIPT_DIR}/packaging/package-user-cleanup.sh" \
        'custom runtime marker lacks a matching ownership sentinel' \
        'package cleanup refuses marker-only custom deletion'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        '## Contents' \
        'English README has a table of contents'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        '## Sommaire' \
        'French README has a table of contents'
    assert_file_contains "${SCRIPT_DIR}/TESTING.md" \
        '## Contents' \
        'testing documentation has a table of contents'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '--setopt=localpkg_gpgcheck=True' \
        'Fedora bootstrap enables local-package OpenPGP verification'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '--allow-unsigned-dev' \
        'unsigned RPM installation requires an explicit development opt-in'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'Confirm unsigned PR RPM is rejected by release bootstrap' \
        'PR package CI proves fail-closed unsigned behavior'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'Reject a different globally trusted RPM signer in PR CI' \
        'PR package CI proves a globally trusted wrong signer cannot authorize the RPM'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        '--define "_rpmlock_path ${wrong_verify_keyring}/.rpm.lock"' \
        'PR wrong-signer proof uses a fully isolated writable RPM fs keyring'

    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        '_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file ${wrong_passphrase}' \
        'PR wrong-signer RPM signing is explicitly noninteractive'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        '_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file ${wrong_passphrase}' \
        'release wrong-signer RPM signing is explicitly noninteractive'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        "printf 'Error: signing secret must contain exactly one primary certificate; found %s\\n'" \
        'release signing diagnostic keeps its newline escaped inside YAML'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'environment: rpm-signing' \
        'release RPM signing is isolated behind a GitHub Environment'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'name: unsigned-rpm' \
        'unsigned RPM artifact is distinct from the signed release artifact'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'rpmsign --addsign' \
        'release workflow applies an OpenPGP RPM signature'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'coreutils gawk gnupg2 rpm rpm-sign' \
        'isolated RPM signing job declares its awk dependency'
    # shellcheck disable=SC2016
    # The assertion deliberately checks that GPG output is materialized completely
    # before the release workflow parses primary/subkey records.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'secret_listing="${signing_home}/secret-keys.colons"' \
        'release signing key inspection uses a complete materialized GPG listing'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        '"${RPM_SIGNING_FINGERPRINT}" >"${secret_listing}"' \
        'release signing GPG listing is completed before fingerprint parsing'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'imported_signing_subkey=$(' \
        'release signing parser separately validates the dedicated signing subkey'

    # shellcheck disable=SC2016
    # The Fedora bootstrap follows the same complete-output-before-parsing model.
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '"${key_path}" >"${gpg_output}"' \
        'Fedora installer materializes the complete public-key listing before parsing'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        'signing_subkey_fingerprint=$(' \
        'Fedora installer separately validates the dedicated signing subkey'

    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        "--homedir \"\${gpg_home}\"" \
        'Fedora installer inspects the signing key in an ephemeral GnuPG home'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '--no-options' \
        'Fedora installer ignores personal GnuPG configuration during key inspection'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'name: release-rpm' \
        'signed RPM is the release artifact consumed by downstream tests'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'RPM-GPG-KEY-OscarFrog' \
        'release publishes the RPM signing public key'
    assert_file_contains "${SCRIPT_DIR}/packaging/keys/RPM-GPG-KEY-OscarFrog" \
        '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
        'repository contains only the public RPM signing certificate'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shell.yml" \
        '    branches:' \
        'push validation branch filter'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shell.yml" \
        '      - main' \
        'push validation main branch'
    # shellcheck disable=SC2016 # Literal workflow-source assertion.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'git merge-base --is-ancestor "${tag_commit}" origin/main' \
        'release tag ancestry validation'

    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'umask 077' \
        'engine restrictive umask'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'readonly YTDLP_NO_PLUGINS=1' \
        'yt-dlp plugins disabled by default'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--no-overwrites' \
        'yt-dlp final-file overwrite protection'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--no-post-overwrites' \
        'yt-dlp post-processing overwrite protection'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'LC_ALL=C setsid --fork --wait bash -c' \
        'CLI worker isolated for signal forwarding'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'signal_download_worker "${signal_name}"' \
        'CLI signals relayed to worker group'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'candidate="${XDG_RUNTIME_DIR}/yt-dlp-aria2-downloader"' \
        'XDG runtime lock location'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '%(title).160B [%(id).64B].%(ext)s' \
        'byte-bounded output filename'

    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'run_supervised_command() {' \
        'generic long-running command supervisor'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'run_supervised_command "${YTDLP_BIN}"' \
        'yt-dlp uses the generic supervisor'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'ARIA2_SUPPORTS_NO_NETRC=false' \
        'aria2 netrc support is detected as an optional capability'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'if [[ ${ARIA2_SUPPORTS_NO_NETRC} == true ]]; then' \
        'aria2 receives no-netrc only when the build advertises it'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'validate_final_media_file() {' \
        'final media FFprobe validation'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '-select_streams "${stream_selector}"' \
        'mode-specific FFprobe stream validation'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'mv -nT -- "${HLS_REMUX_TMP}" "${hls_final_path}"' \
        'HLS publication never treats the target as a directory'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'YTDLP_ARIA2_SUPERVISED_SESSION=true' \
        'GUI requests reuse of its single process session without a public option'
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        'PROFILE OUTPUT_DIR' \
        'progress monitor receives the canonical destination'
    README_EN_TEXT=$(<"${SCRIPT_DIR}/README.md")
    README_FR_TEXT=$(<"${SCRIPT_DIR}/README.fr.md")
    readonly README_EN_TEXT README_FR_TEXT

    assert_text_not_contains "${README_EN_TEXT}" \
        'docs/images/' 'English README has no embedded screenshots'
    assert_text_not_contains "${README_FR_TEXT}" \
        'docs/images/' 'French README has no embedded screenshots'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'name: Ubuntu 24.04 DEB' 'DEB package validation job'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'name: Fedora 44 RPM' 'RPM package validation job'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'dist/*.deb' 'release publishes a DEB payload'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'dist/*.rpm' 'release publishes an RPM payload'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'dist/*.zip' 'release preserves the portable ZIP payload'
    assert_file_contains "${SCRIPT_DIR}/packaging/yt-dlp-aria2-downloader.desktop" \
        'TryExec=/usr/bin/yt-dlp-aria2-downloader-gui' \
        'packaged desktop launcher command'
    assert_file_contains "${SCRIPT_DIR}/packaging/deb/build-deb.sh" \
        'dpkg-deb --root-owner-group --build' 'native DEB construction'
    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh" \
        'rpmbuild -bb' 'native RPM construction'
    [[ ! -e ${SCRIPT_DIR}/docs/images ]] \
        || fail 'Obsolete screenshot directory remains in the project.'

    # shellcheck disable=SC2016 # Literal workflow-source assertions.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'git config --global --add safe.directory "${GITHUB_WORKSPACE}"' \
        'Fedora package-validation container trusts only its checked-out workspace'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'git config --global --add safe.directory "${GITHUB_WORKSPACE}"' \
        'Fedora release container trusts only its checked-out workspace'

    assert_file_contains "${SCRIPT_DIR}/README.md" \
        '## Recommended installation' 'prominent English package installation'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        '## Installation recommandée' 'prominent French package installation'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        'are installed automatically in the desktop application menu.' \
        'English automatic package launcher installation'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "\`install-gui.sh\` after installing a package." \
        'English package installer exclusion'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        'installés automatiquement dans le menu des applications.' \
        'French automatic package launcher installation'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "\`install-gui.sh\` après l’installation d’un paquet." \
        'French package installer exclusion'
    assert_file_contains "${SCRIPT_DIR}/packaging/yt-dlp-aria2-downloader.desktop" \
        'Icon=yt-dlp-aria2-downloader' 'dedicated desktop icon name'
    [[ -f ${SCRIPT_DIR}/packaging/icons/yt-dlp-aria2-downloader.svg ]] \
        || fail 'Dedicated application icon is absent.'
    assert_file_contains "${SCRIPT_DIR}/packaging/install-tree.sh" \
        'usr/share/icons/hicolor/scalable/apps' \
        'Freedesktop hicolor icon installation'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'packaging/deb/test-package-lifecycle.sh' \
        'DEB installation and removal validation'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'packaging/rpm/test-package-lifecycle.sh' \
        'RPM installation and removal validation'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'packaging/deb/test-package-lifecycle.sh' \
        'release DEB installation and removal validation'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'packaging/rpm/test-package-lifecycle.sh' \
        'release RPM installation and removal validation'
    assert_file_not_contains "${SCRIPT_DIR}/packaging/deb/build-deb.sh" \
        'install-gui.sh' 'DEB does not run the per-user launcher installer'
    assert_file_not_contains "${SCRIPT_DIR}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
        'install-gui.sh' 'RPM does not run the per-user launcher installer'

    # Regression contracts for runtime, release, playlist, HLS, packaging, and supply-chain behavior.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--url-file FILE' 'private URL-file input'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        "--batch-file \"\${YTDLP_BATCH_FILE_TMP}\"" 'private yt-dlp batch file'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        "--url-file \"\${URL_FILE}\"" 'GUI private URL transfer'
    assert_file_not_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        "COMMAND+=(-- \"\${URL}\")" 'GUI URL is absent from process arguments'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'LOG_MAX_BYTES=8388608' 'retained diagnostic log size bound'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        '[REDACTED_URL]' 'retained diagnostic URL redaction'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'live-download-log.' 'live log remains in the private runtime directory'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        "probe_stream stream_present \"\${final_path}\" 'V:0'" 'complete-video content-video stream validation'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        "probe_stream stream_present \"\${final_path}\" 'a:0'" 'complete-video audio stream validation'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '-nostdin' 'FFmpeg standard-input isolation'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '-progress pipe:1' 'FFmpeg machine progress output'
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        'FFMPEG_PROGRESS_DURATION' 'measured FFmpeg progress parsing'
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        'MAX_SAFE_COUNTER=9000000000000000' 'bounded progress arithmetic'
    assert_file_contains "${SCRIPT_DIR}/packaging/deb/build-deb.sh" \
        'aria2 (>= 1.37.0), python3 (>= 3.10), ffmpeg, gnupg, unzip, zenity' \
        'DEB managed-runtime system dependencies'
    assert_file_not_contains "${SCRIPT_DIR}/download-video.sh" \
        '--downloader-args' \
        'obsolete yt-dlp external-downloader capability is not required'
    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
        'Requires:       python3 >= 3.10' 'RPM private-helper Python minimum'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        'Python **3.10 or newer**' 'English private-helper Python minimum'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        'Python **3.10 ou plus récent**' 'French private-helper Python minimum'
    assert_file_not_contains "${SCRIPT_DIR}/packaging/deb/build-deb.sh" \
        'yt-dlp (>= 2026.06.09)' \
        'DEB does not depend on distribution yt-dlp'
    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
        'Requires:       aria2 >= 1.37.0' 'RPM minimum aria2 dependency'
    assert_file_contains "${SCRIPT_DIR}/install-gui.sh" \
        'readonly ICON_FILE=' 'per-user dedicated icon installation'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'actions/attest@59d89421af93a897026c735860bf21b6eb4f7b26' \
        'release provenance attestation action'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/real-tools.yml" \
        'tests/real-tools-integration.sh' 'hermetic real-tool CI validation'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'tests/real-tools-integration.sh' 'release is gated by hermetic real-tool validation'
    assert_file_not_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'container: debian:13-slim' 'unsupported Debian package job is absent'
    assert_file_not_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'trixie-backports' 'package CI does not rely on insufficient Debian backports'
    assert_file_contains "${SCRIPT_DIR}/tests/run-all.sh" \
        'tests/ffmpeg-progress-integration.sh' 'measured FFmpeg progress regression suite'

    assert_status 2 'URL user information is rejected' \
        "${SCRIPT_DIR}/download-video.sh" \
        'https://user:password@example.com/video'
    assert_text_contains "${ASSERT_OUTPUT}" 'user information' \
        'URL user-information rejection reason'
    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
        '%dir %{_licensedir}/%{name}' \
        'RPM owns its private license directory'

    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        "--break-match-filters '!playlist_index'" \
        'collection entries are rejected before download'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--concurrent-fragments 1' \
        'native HLS/DASH fragment downloads are serialized for reliability'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--no-update' \
        'yt-dlp cannot self-update in the middle of a download'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '--js-runtimes "deno:${DENO_BIN}"' \
        'managed Deno path is passed explicitly to yt-dlp'
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        "readonly DEFAULT_YTDLP_CHANNEL='stable'" \
        'managed yt-dlp defaults to the stable channel'
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        "YTDLP_RELEASE_REPOSITORY='yt-dlp/yt-dlp'" \
        'managed yt-dlp stable release repository'
    # shellcheck disable=SC2016 # Literal source contract: do not expand runtime-manager variables here.
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        'flock --exclusive --wait "${RUNTIME_LOCK_WAIT_SECONDS}"' \
        'runtime update lock wait is bounded'
    # shellcheck disable=SC2016 # Literal source contract: do not expand runtime-manager variables here.
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        '--retry-max-time "${CURL_RETRY_MAX_TIME_SECONDS}"' \
        'runtime network retry time is bounded'
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        'rollback)' \
        'runtime manager exposes verified rollback'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        'latest_deno_version latest_version' \
        'managed Deno resolves the exact current stable release before download'
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        "releases/download/v\${version}" \
        'managed Deno downloads from an exact release tag'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        'parse_deno_version "${candidate}" version' \
        'managed Deno strips --version metadata before version-directory naming'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        '--verify "${work}/SHA2-256SUMS.sig"' \
        'yt-dlp checksum signature is passed to GPG'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        '"${work}/SHA2-256SUMS" 2>&1); then' \
        'yt-dlp signed SHA-256 manifest is verified with diagnostics preserved'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        'dnf swap --assumeyes --allowerasing ffmpeg-free ffmpeg' \
        'Fedora bootstrap replaces ffmpeg-free'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        "ffmpeg_vendor" \
        'Fedora bootstrap validates the FFmpeg vendor'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        "rpm -qp --qf '%{NAME}\n%{VERSION}\n%{ARCH}\n'" \
        'Fedora bootstrap validates RPM identity before installation'
    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
        'Requires:       gnupg2' \
        'RPM installs signature-verification tooling'
    assert_file_not_contains "${SCRIPT_DIR}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
        'Requires:       yt-dlp' \
        'RPM does not mix a system yt-dlp with the managed runtime'
    assert_file_not_contains "${SCRIPT_DIR}/packaging/rpm/yt-dlp-aria2-downloader-gui.spec" \
        'Recommends:     deno' \
        'Deno is managed explicitly instead of weakly recommended'

    # shellcheck disable=SC2016 # Literal shell-variable assertion.
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '"${runtime_manager}" update' \
        'Fedora installer delegates managed-runtime validation to runtime manager'
    assert_file_not_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '--list-impersonate-targets' \
        'Fedora installer does not duplicate yt-dlp impersonation parsing'
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        '--list-impersonate-targets' \
        'runtime manager owns yt-dlp impersonation validation'

    # shellcheck disable=SC2016
    # Workflow-level concurrency may use github/inputs/vars, but not matrix.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" 'group: packages-${{ github.workflow }}-${{ github.ref }}' 'package workflow uses valid workflow-level concurrency contexts'
    # shellcheck disable=SC2016 # Literal GitHub-expression assertion.
    assert_file_not_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" 'group: packages-${{ github.workflow }}-${{ github.ref }}-${{ matrix.scenario }}' 'package workflow does not use matrix at workflow-level concurrency'

    # Executable staging must not depend on an executable /tmp, while the
    # separate GnuPG homedir stays short enough for Unix-domain socket paths.
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        'work=$(mktemp -d --tmpdir="${RUNTIME_ROOT}"' \
        'yt-dlp executable bootstrap staging stays below RUNTIME_ROOT'
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        "gpg_home=\$(mktemp -d --tmpdir=/tmp '.yt-dlp-gpg.XXXXXXXX')" \
        'yt-dlp bootstrap keeps the GnuPG socket path short'
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        'require)' 'runtime manager exposes strict no-network require mode'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        "0) runtime_action='require'" 'managed update=0 never bootstraps runtimes'
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        '.activation-journal' 'runtime activation transaction journal'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'gh release verify-asset' 'release assets are verified against immutable release attestation'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        "gh release view \"\${RELEASE_TAG}\" --json assets" 'existing release asset inventory is exact'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'actions/download-artifact@70fc10c6e5e1ce46ad2ea6f2b72d43f7d47b13c3' \
        'RPM matrix downloads one shared artifact'
    assert_file_contains "${SCRIPT_DIR}/tests/run-all.sh" \
        'runtime-manager-hardening-integration.sh' 'runtime hardening suite is mandatory'
    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh" \
        'RPM upgrade passed:' 'RPM previous-to-current upgrade test'
    assert_file_contains "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
        'DEB upgrade passed:' 'DEB previous-to-current upgrade test'

    assert_file_contains \
        "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh" \
        'status --porcelain=v1 --untracked-files=normal' \
        'RPM build rejects a dirty package source tree'
    assert_file_contains \
        "${SCRIPT_DIR}/packaging/deb/build-deb.sh" \
        'status --porcelain=v1 --untracked-files=normal' \
        'DEB build rejects a dirty package source tree'
    assert_file_contains \
        "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh" \
        'source version does not match requested package version' \
        'RPM build validates its requested source version'
    assert_file_contains \
        "${SCRIPT_DIR}/packaging/deb/build-deb.sh" \
        'source version does not match requested package version' \
        'DEB build validates its requested source version'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'previous-release:' \
        'previous immutable release job'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'attestations: read' \
        'previous release attestation read permission'

    # shellcheck disable=SC2016
    # Literal workflow source: PREVIOUS_TAG must not expand in this test.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'gh release verify "${PREVIOUS_TAG}"' \
        'previous immutable release identity verification'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'gh release verify-asset' \
        'previous and current release assets use immutable release verification'

    # shellcheck disable=SC2016 # Literal GitHub-attestation policy source.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        '--source-digest "${PREVIOUS_COMMIT}"' \
        'previous package provenance is bound to its exact source commit'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'previous-release-packages' \
        'exact previous published packages are passed to upgrade jobs'

    assert_file_not_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'git worktree add' \
        'release qualification does not rebuild the previous release from source'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/stress.yml" \
        'runtime-hardening-stress:' \
        'runtime manager has a dedicated stress job'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/stress.yml" \
        'Runtime-manager hardening stress (10x)' \
        'runtime hardening stress count is documented in the job name'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/stress.yml" \
        'tests/runtime-manager-hardening-integration.sh' \
        'runtime hardening integration is executed by stress CI'

    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh" \
        'runtime_tree_snapshot() {' \
        'RPM upgrade snapshots the complete managed-runtime tree'

    assert_file_contains "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
        'runtime_tree_snapshot() {' \
        'DEB upgrade snapshots the complete managed-runtime tree'

    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh" \
        "assert_runtime_preserved 'installation of previous package'" \
        'RPM previous package installation preserves user runtime data'

    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh" \
        "assert_runtime_preserved 'package upgrade'" \
        'RPM package upgrade preserves user runtime data'

    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh" \
        "assert_runtime_removed 'final package removal'" \
        'RPM final package removal cleans managed user runtime data'

    assert_file_contains "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
        "assert_runtime_preserved 'installation of previous package'" \
        'DEB previous package installation preserves user runtime data'

    assert_file_contains "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
        "assert_runtime_preserved 'package upgrade'" \
        'DEB package upgrade preserves user runtime data'

    assert_file_contains "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
        "assert_runtime_removed 'final package removal'" \
        'DEB final package removal cleans managed user runtime data'

    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        '### Vidéo YouTube HLS authentifiée' \
        'French README documents authenticated YouTube HLS in detail'

    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        'youtube:player_client=web_safari' \
        'French authenticated HLS documentation names the selected player client'

    assert_file_contains "${SCRIPT_DIR}/TESTING.md" \
        'previous-immutable-release -> current upgrade' \
        'testing documentation requires exact previous immutable release upgrades'

    assert_file_contains "${SCRIPT_DIR}/TESTING.md" \
        '## Release maintainer preflight' \
        'testing documentation contains immutable-release maintainer preflight'

    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh" \
        'refusing to clean runtime probe through unsafe runtime root' \
        'RPM cleanup refuses an unsafe runtime root'

    assert_file_contains "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
        'refusing to clean runtime probe through unsafe runtime root' \
        'DEB cleanup refuses an unsafe runtime root'

    assert_file_contains "${SCRIPT_DIR}/CHANGELOG.md" \
        'deterministic archive snapshot of the per-user managed-runtime' \
        'changelog describes the measured runtime preservation guarantee precisely'

    assert_file_contains "${SCRIPT_DIR}/TESTING.md" \
        'deterministic archive snapshot of the per-user' \
        'testing documentation describes runtime preservation precisely'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'previous-release:' \
        'package CI resolves the previous immutable release'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'attestations: read' \
        'package CI can verify previous release attestations'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'sort -Vr -u' \
        'package CI resolves the previous semantic version dynamically'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        '--json isImmutable' \
        'package CI requires the previous release to be immutable'

    # shellcheck disable=SC2016
    # Literal workflow source: PREVIOUS_TAG must not expand in this test.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'gh release verify "${PREVIOUS_TAG}"' \
        'package CI verifies previous immutable release identity'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'gh release verify-asset' \
        'package CI verifies previous release assets'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'gh attestation verify' \
        'package CI verifies previous release provenance'

    # shellcheck disable=SC2016
    # Literal workflow source: PREVIOUS_COMMIT must not expand in this test.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        '--source-digest "${PREVIOUS_COMMIT}"' \
        'package CI binds provenance to the exact previous source commit'

    # shellcheck disable=SC2016 # Literal GitHub Actions expression.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'previous-release-packages-${{ github.sha }}' \
        'package CI transfers exact verified previous packages between jobs'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        '      - previous-release' \
        'RPM package CI depends on previous release verification'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        '    needs: previous-release' \
        'DEB package CI depends on previous release verification'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'previous/*.rpm' \
        'RPM upgrade consumes the published previous RPM'

    # shellcheck disable=SC2016 # Literal GitHub Actions runner-temp expression.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'PREVIOUS_DIR: ${{ runner.temp }}/previous-release' \
        'DEB upgrade keeps the published previous DEB outside the source worktree'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'sha256sum --check PREVIOUS_SHA256SUMS' \
        'package upgrade jobs recheck transferred previous package digests'

    assert_file_not_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'git worktree add' \
        'package CI never rebuilds a previous release from source'

    assert_file_not_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'v2.1.24' \
        'package CI does not hard-code a historical upgrade source version'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'PACKAGE_TEST_HOME: /root' \
        'package CI uses an NSS-discoverable Fedora package-test HOME'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        "HOME=\"\${PACKAGE_TEST_HOME}\" bash ./install-fedora.sh" \
        'package CI Fedora bootstrap uses the package-test HOME'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'PACKAGE_TEST_HOME: /root' \
        'release CI uses an NSS-discoverable Fedora package-test HOME'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        "HOME=\"\${PACKAGE_TEST_HOME}\" bash ./install-fedora.sh" \
        'release Fedora bootstrap uses the package-test HOME'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        'supported Fedora bootstrap runtime survived final RPM removal' \
        'package CI checks bootstrap runtime removal'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'supported Fedora bootstrap runtime survived final RPM removal' \
        'release CI checks bootstrap runtime removal'

    printf '%s\n' 'Static tests passed.'

}

main "$@"
