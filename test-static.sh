#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : test-static.sh
# Purpose     : Validate static project invariants and release-version coherence.
# ==============================================================================

set -euo pipefail
umask 077

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
# Contract: every canonical shell file uses the standard Bash header.
readonly STANDARD_HEADER_PROJECT='yt-dlp-aria2-downloader-gui'
# The development tree can lead the latest installable GitHub release. Keep the
# two contracts explicit so README package names never advertise absent assets.
readonly EXPECTED_VERSION='2.3.5'
readonly EXPECTED_PUBLISHED_VERSION='2.3.4'
readonly STANDARD_HEADER_SEPARATOR='# =============================================================================='
SHELL_INVENTORY_FILE=''

assert_forbidden_source_name_absent() {
    local forbidden_name=''
    local matched_path=''
    local project_path=''

    forbidden_name=$(printf '\170\150\141\155\163\164\145\162')
    while IFS= read -r -d '' project_path; do
        if LC_ALL=C grep -I -i -q -- "${forbidden_name}" "${project_path}"; then
            matched_path=${project_path#"${SCRIPT_DIR}/"}
            break
        fi
    done < <(
        # The process substitution is consumed completely by the loop.
        # shellcheck disable=SC2312
        find "${SCRIPT_DIR}" \
            -path "${SCRIPT_DIR}/.git" -prune -o \
            -type f -print0
    )
    [[ -z ${matched_path} ]] || {
        printf 'FAIL: forbidden source name is present in %s.\n' \
            "${matched_path}" >&2
        return 65
    }
}

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
    local -a header_lines=()

    if ! mapfile -t -n 8 header_lines <"${absolute_path}"; then
        printf 'FAIL: unable to read canonical shell file: %s.\n' \
            "${relative_path}" >&2
        return 65
    fi
    if ((${#header_lines[@]} != 8)); then
        printf 'FAIL: canonical shell header is truncated in %s; expected 8 lines, found %d.\n' \
            "${relative_path}" "${#header_lines[@]}" >&2
        return 65
    fi

    shebang=${header_lines[0]}
    spdx=${header_lines[1]}
    separator_open=${header_lines[2]}
    project_line=${header_lines[3]}
    file_line=${header_lines[4]}
    purpose_line=${header_lines[5]}
    separator_close=${header_lines[6]}
    spacer=${header_lines[7]}

    [[ ${shebang} == '#!/usr/bin/env bash' ]] || {
        printf 'FAIL: non-standard Bash shebang in %s.\n' "${relative_path}" >&2
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
        printf 'FAIL: missing blank line after standard header in %s.\n' \
            "${relative_path}" >&2
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
    local historical_regex='^[[:space:]]*#[[:space:]]*(((P[A]TCH|A[U]D)-[0-9]+)|(Regression[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?)|.*[Aa][Uu][Dd][Ii][Tt]([[:space:].,:;]|$))'
    local matches=''
    local status=0

    matches=$(grep -En -- "${historical_regex}" "${absolute_path}") || status=$?
    case ${status} in
        0)
            printf 'FAIL: historical patch/audit label found in %s.\n' \
                "${relative_path}" >&2
            printf '%s\n' "${matches}" >&2
            return 65
            ;;
        1)
            return 0
            ;;
        *)
            printf 'FAIL: unable to scan comments in %s (grep status %d).\n' \
                "${relative_path}" "${status}" >&2
            return 65
            ;;
    esac
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
        if ! git -c "safe.directory=${SCRIPT_DIR}" -C "${SCRIPT_DIR}" \
            rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            cleanup_static_test
            printf 'FAIL: unable to validate the project Git worktree.\n' >&2
            return 65
        fi
        if ! git -c "safe.directory=${SCRIPT_DIR}" -C "${SCRIPT_DIR}" \
            ls-files -co --exclude-standard -z >"${SHELL_INVENTORY_FILE}"; then
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
            if [[ ${candidate} == /* ]]; then
                printf 'FAIL: Git-free inventory path escaped project root: %s\n' \
                    "${candidate}" >&2
                inventory_status=65
                continue
            fi
        fi
        [[ -f ${SCRIPT_DIR}/${candidate} ]] || continue

        first_line=''
        IFS= read -r first_line <"${SCRIPT_DIR}/${candidate}" || true
        is_shell_candidate=false

        if [[ ${candidate} == *.sh ]]; then
            is_shell_candidate=true
        elif [[ ${first_line} =~ ^\#![[:space:]]*/(usr/)?bin/(sh|bash|dash|ash|ksh|zsh)([[:space:]].*)?$ ||
            ${first_line} =~ ^\#![[:space:]]*/usr/bin/env([[:space:]]+-S)?[[:space:]]+(sh|bash|dash|ash|ksh|zsh)([[:space:]].*)?$ ]]; then
            is_shell_candidate=true
        fi

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

job_permissions_block() {
    local job_block=$1

    awk '
        /^    permissions:[[:space:]]*$/ {
            in_permissions = 1
            print
            next
        }
        in_permissions && /^      [[:alnum:]_-]+:[[:space:]]*[^[:space:]].*$/ {
            line = $0
            sub(/[[:space:]]+#.*$/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            next
        }
        in_permissions {
            exit
        }
    ' <<<"${job_block}"
}

mutation_must_change() {
    local original=$1
    local mutated=$2
    local label=$3

    [[ ${mutated} != "${original}" ]] || {
        printf 'FAIL: negative-control mutation no longer matches: %s\n' \
            "${label}" >&2
        return 65
    }
    return 0
}

docker_run_blocks_are_hardened() {
    local job_block=$1
    local line=''
    local in_docker_run=false
    local has_network_none=false
    local has_read_only=false
    local has_cap_drop=false
    local has_no_new_privileges=false
    local accepts_docker_options=false
    local docker_run_count=0
    local hardened_docker_run_count=0

    while IFS= read -r line; do
        if [[ ${in_docker_run} == false ]]; then
            if [[ ${line} =~ ^[[:space:]]*docker[[:space:]]+run[[:space:]]+\\[[:space:]]*$ ]]; then
                in_docker_run=true
                has_network_none=false
                has_read_only=false
                has_cap_drop=false
                has_no_new_privileges=false
                accepts_docker_options=true
                docker_run_count=$((docker_run_count + 1))
            fi
            continue
        fi

        if [[ ${accepts_docker_options} == true &&
            ${line} =~ ^[[:space:]]+--network=none[[:space:]]+\\[[:space:]]*$ ]]; then
            has_network_none=true
        elif [[ ${accepts_docker_options} == true &&
            ${line} =~ ^[[:space:]]+--read-only[[:space:]]+\\[[:space:]]*$ ]]; then
            has_read_only=true
        elif [[ ${accepts_docker_options} == true &&
            ${line} =~ ^[[:space:]]+--cap-drop=ALL[[:space:]]+\\[[:space:]]*$ ]]; then
            has_cap_drop=true
        elif [[ ${accepts_docker_options} == true &&
            ${line} =~ ^[[:space:]]+--security-opt=no-new-privileges[[:space:]]+\\[[:space:]]*$ ]]; then
            has_no_new_privileges=true
        elif [[ ${accepts_docker_options} == true &&
            ! ${line} =~ ^[[:space:]]+--[^[:space:]]+([[:space:]]+.*)?\\[[:space:]]*$ ]]; then
            # Docker options stop at the image argument. Matching option-like
            # text after that point would validate container arguments instead.
            accepts_docker_options=false
        fi

        if [[ ! ${line} =~ \\[[:space:]]*$ ]]; then
            if [[ ${has_network_none} == true &&
                ${has_read_only} == true &&
                ${has_cap_drop} == true &&
                ${has_no_new_privileges} == true ]]; then
                hardened_docker_run_count=$((hardened_docker_run_count + 1))
            fi
            in_docker_run=false
        fi
    done <<<"${job_block}"

    [[ ${in_docker_run} == false ]] || return 65
    ((docker_run_count == 2 && hardened_docker_run_count == 2))
}

publisher_job_executes_repo_shell() {
    local job_block=$1
    local line=''
    local command_name=''
    local script_path=''
    local word=''
    local index=0
    local word_count=0
    local -a words=()

    while IFS= read -r line; do
        words=()
        read -r -a words <<<"${line}"
        word_count=${#words[@]}
        ((word_count > 0)) || continue
        index=0

        while ((index < word_count)); do
            word=${words[index]}
            case ${word} in
                command)
                    index=$((index + 1))
                    ;;
                env)
                    index=$((index + 1))
                    while ((index < word_count)); do
                        word=${words[index]}
                        if [[ ${word} == -* || ${word} == *=* ]]; then
                            index=$((index + 1))
                        else
                            break
                        fi
                    done
                    ;;
                timeout)
                    index=$((index + 1))
                    while ((index < word_count)) && [[ ${words[index]} == -* ]]; do
                        index=$((index + 1))
                    done
                    ((index < word_count)) && index=$((index + 1))
                    ;;
                sudo)
                    index=$((index + 1))
                    while ((index < word_count)) && [[ ${words[index]} == -* ]]; do
                        index=$((index + 1))
                    done
                    ;;
                *)
                    break
                    ;;
            esac
        done

        ((index < word_count)) || continue
        command_name=${words[index]}
        script_path=${command_name}
        case ${command_name} in
            bash | sh)
                index=$((index + 1))
                while ((index < word_count)) && [[ ${words[index]} == -* ]]; do
                    if [[ ${words[index]} == -- ]]; then
                        index=$((index + 1))
                        break
                    fi
                    index=$((index + 1))
                done
                ((index < word_count)) || continue
                script_path=${words[index]}
                ;;
            source | .)
                index=$((index + 1))
                ((index < word_count)) || continue
                script_path=${words[index]}
                ;;
            *)
                ;;
        esac

        script_path=${script_path#\"}
        script_path=${script_path%\"}
        script_path=${script_path#\'}
        script_path=${script_path%\'}
        script_path=${script_path%;}
        script_path=${script_path%\\}
        if [[ ${script_path} != /* && ${script_path} == *.sh ]]; then
            return 0
        fi
    done <<<"${job_block}"

    return 1
}

shfmt_candidate_job_policy() {
    local job_block=$1

    local permissions=''

    permissions=$(job_permissions_block "${job_block}")
    [[ ${permissions} == $'    permissions:\n      contents: read' ]] || return 65
    # shellcheck disable=SC2016 # Literal GitHub Actions expression, not shell expansion.
    [[ ${job_block} != *'${{ secrets.'* ]] || return 65
    [[ ${job_block} == *"if: github.ref == 'refs/heads/main'"* ]] || return 65
    [[ ${job_block} == *'Reformat with candidate shfmt in a no-network sandbox'* ]] || return 65
    [[ ${job_block} == *$'          docker build \\\n            --network=none \\\n            --tag '* ]] || return 65
    # Predicate failure rejects a candidate job whose Docker commands are not
    # each individually hardened.
    # shellcheck disable=SC2310
    docker_run_blocks_are_hardened "${job_block}" || return 65
    # shellcheck disable=SC2016 # Literal workflow shell expression, not local expansion.
    [[ ${job_block} == *'"${GITHUB_WORKSPACE}/.git:/workspace/.git:ro"'* ]] || return 65
    [[ ${job_block} == *'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'* ]] || return 65
    [[ ${job_block} == *"if: steps.detect.outputs.update == 'true'"* ]] || return 65
    [[ ${job_block} != *'bash ./scripts/format-shell.sh'* ]] || return 65
    [[ ${job_block} != *'bash ./tests/run-all.sh'* ]] || return 65
    [[ ${job_block} != *'actions/cache@'* ]] || return 65
    return 0
}

shfmt_verifier_job_policy() {
    local job_block=$1

    local permissions=''

    permissions=$(job_permissions_block "${job_block}")
    [[ ${permissions} == $'    permissions:\n      contents: read' ]] || return 65
    # shellcheck disable=SC2016 # Literal GitHub Actions expression, not shell expansion.
    [[ ${job_block} != *'${{ secrets.'* ]] || return 65
    [[ ${job_block} == *"if: github.ref == 'refs/heads/main' && needs.prepare-shfmt-update.outputs.update == 'true'"* ]] || return 65
    [[ ${job_block} == *'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'* ]] || return 65
    # shellcheck disable=SC2016 # Literal GitHub Actions expression, not shell expansion.
    [[ ${job_block} == *'EXPECTED_BASE_SHA: ${{ github.sha }}'* ]] || return 65
    # shellcheck disable=SC2016 # Dynamic checkout refs are forbidden in the verifier.
    [[ ${job_block} != *'ref: ${{'* ]] || return 65
    [[ ${job_block} == *'actions/download-artifact@70fc10c6e5e1ce46ad2ea6f2b72d43f7d47b13c3'* ]] || return 65
    # shellcheck disable=SC2016 # Literal GitHub Actions expression, not shell expansion.
    [[ ${job_block} == *'shfmt-candidate-${{ github.run_id }}-${{ github.run_attempt }}'* ]] || return 65
    [[ ${job_block} == *"trusted_shfmt=\$(bash ./scripts/dev-tools/ensure-shfmt.sh)"* ]] || return 65
    [[ ${job_block} == *"canonical_manifest \"\${baseline}\""* ]] || return 65
    [[ ${job_block} == *"canonical_manifest \"\${after}\""* ]] || return 65
    [[ ${job_block} == *"cmp -s -- \"\${baseline}\" \"\${after}\""* ]] || return 65
    [[ ${job_block} == *'candidate shfmt pin file differs from the exact data-only schema'* ]] || return 65
    [[ ${job_block} == *'verifier rejected upstream shfmt tag provenance'* ]] || return 65
    [[ ${job_block} == *'Validate verified formatter and project'* ]] || return 65
    [[ ${job_block} == *'bash ./tests/run-all.sh'* ]] || return 65
    [[ ${job_block} == *'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'* ]] || return 65
    # shellcheck disable=SC2016 # Literal GitHub Actions expression, not shell expansion.
    [[ ${job_block} == *'shfmt-verified-${{ github.run_id }}-${{ github.run_attempt }}'* ]] || return 65
    [[ ${job_block} != *'bash ./scripts/format-shell.sh'* ]] || return 65
    [[ ${job_block} != *'actions/cache@'* ]] || return 65
    return 0
}

shfmt_publish_job_policy() {
    local job_block=$1

    local permissions=''

    permissions=$(job_permissions_block "${job_block}")
    [[ ${permissions} == $'    permissions:\n      contents: write\n      pull-requests: write' ]] || return 65
    [[ ${job_block} == *"if: github.ref == 'refs/heads/main' && needs.prepare-shfmt-update.outputs.update == 'true'"* ]] || return 65
    [[ ${job_block} == *'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'* ]] || return 65
    # shellcheck disable=SC2016 # Literal GitHub Actions expression, not shell expansion.
    [[ ${job_block} == *'EXPECTED_BASE_SHA: ${{ github.sha }}'* ]] || return 65
    # shellcheck disable=SC2016 # Dynamic checkout refs are forbidden in the privileged publisher.
    [[ ${job_block} != *'ref: ${{'* ]] || return 65
    [[ ${job_block} == *'actions/download-artifact@70fc10c6e5e1ce46ad2ea6f2b72d43f7d47b13c3'* ]] || return 65
    # shellcheck disable=SC2016 # Literal GitHub Actions expression, not shell expansion.
    [[ ${job_block} == *'shfmt-verified-${{ github.run_id }}-${{ github.run_attempt }}'* ]] || return 65
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
    [[ ${job_block} != *'actions/cache@'* ]] || return 65
    # Predicate success identifies forbidden repository-controlled execution.
    # shellcheck disable=SC2310
    if publisher_job_executes_repo_shell "${job_block}"; then
        return 65
    fi
    return 0
}

assert_shfmt_update_workflow_policy() {
    local workflow="${SCRIPT_DIR}/.github/workflows/shfmt-update.yml"
    local candidate_block=''
    local verifier_block=''
    local publish_block=''
    local mutated=''
    local unsafe_publisher_command=''
    local read_only_line=$'              --read-only \\'
    local -a unsafe_publisher_commands=(
        './download-video.sh'
        'bash ./runtime-manager.sh'
        './install-gui.sh'
        'timeout 10s bash ./tests/foo.sh'
        'command bash ./scripts/foo.sh'
    )

    candidate_block=$(workflow_job_block "${workflow}" prepare-shfmt-update)
    verifier_block=$(workflow_job_block "${workflow}" verify-shfmt-update)
    publish_block=$(workflow_job_block "${workflow}" publish-shfmt-pr)

    [[ -n ${candidate_block} ]] \
        || fail 'shfmt updater read-only candidate job is missing.'
    [[ -n ${verifier_block} ]] \
        || fail 'shfmt updater fresh verifier job is missing.'
    [[ -n ${publish_block} ]] \
        || fail 'shfmt updater privileged publication job is missing.'

    # Policy helpers are explicit-status predicates and intentionally do not rely
    # on errexit inside their bodies.
    # shellcheck disable=SC2310
    shfmt_candidate_job_policy "${candidate_block}" \
        || fail 'shfmt updater candidate job violates the sandboxed read-only trust boundary.'
    # shellcheck disable=SC2310
    shfmt_verifier_job_policy "${verifier_block}" \
        || fail 'shfmt updater verifier job violates the fresh read-only trust boundary.'
    # shellcheck disable=SC2310
    shfmt_publish_job_policy "${publish_block}" \
        || fail 'shfmt updater publication job violates the privileged trust boundary.'

    mutated=${candidate_block//contents: read/contents: write}
    mutation_must_change "${candidate_block}" "${mutated}" 'candidate contents write'
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_candidate_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject candidate repository write permission.'
    fi

    mutated=${candidate_block/$'    permissions:\n      contents: read'/$'    permissions: write-all'}
    mutation_must_change "${candidate_block}" "${mutated}" 'candidate write-all'
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_candidate_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject candidate write-all permission.'
    fi

    mutated=${candidate_block/"${read_only_line}"/}
    mutated+=$'\n          cat <<\x27DECOY\x27\n              --read-only \\\n          DECOY'
    mutation_must_change \
        "${candidate_block}" \
        "${mutated}" \
        'candidate Docker read-only relocation'
    # Predicate failure is expected when an option is moved outside its
    # contiguous docker run command even if the raw line count stays unchanged.
    # shellcheck disable=SC2310
    if shfmt_candidate_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not bind read-only to both Docker runs.'
    fi

    mutated="${candidate_block}"$'
''      bash ./scripts/format-shell.sh'
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_candidate_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject direct project execution after candidate formatting.'
    fi

    mutated=${verifier_block//bash .\/tests\/run-all.sh/true}
    mutation_must_change "${verifier_block}" "${mutated}" 'verifier test removal'
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_verifier_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject removal of post-verification project tests.'
    fi

    # shellcheck disable=SC2016 # Deliberate unsafe dynamic checkout mutation.
    mutated="${verifier_block}"$'
''          ref: ${{ needs.prepare-shfmt-update.outputs.base_sha }}'
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_verifier_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject a dynamic verifier checkout ref.'
    fi

    mutated="${publish_block}"$'
''      bash ./scripts/format-shell.sh'
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_publish_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject candidate-code execution in publication.'
    fi

    for unsafe_publisher_command in "${unsafe_publisher_commands[@]}"; do
        mutated="${publish_block}"$'\n'"      ${unsafe_publisher_command}"
        # Predicate failure is expected for every form of repository-controlled
        # shell execution in the privileged publisher.
        # shellcheck disable=SC2310
        if shfmt_publish_job_policy "${mutated}"; then
            fail "shfmt updater policy allowed publisher command: ${unsafe_publisher_command}"
        fi
    done

    mutated=${publish_block//git apply --check/git apply}
    mutation_must_change "${publish_block}" "${mutated}" 'publisher git apply check removal'
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_publish_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject removal of git apply --check.'
    fi

    mutated=${publish_block//comm -23/comm -13}
    mutation_must_change "${publish_block}" "${mutated}" 'publisher allowlist mutation'
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_publish_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject removal of the patch path allowlist.'
    fi

    mutated=${publish_block//core.hooksPath=\/dev\/null/core.hooksPath=.git\/hooks}
    mutation_must_change "${publish_block}" "${mutated}" 'publisher hooks mutation'
    # Predicate failure is expected for this negative-control mutation.
    # shellcheck disable=SC2310
    if shfmt_publish_job_policy "${mutated}"; then
        fail 'shfmt updater policy did not reject privileged Git hooks.'
    fi
}

test_static_tooling_contracts() {
    local engine_phase gui_phase mock_engine_group mock_engine_suite
    local mock_gui_group mock_gui_suite mock_phase
    local mock_runtime_group mock_runtime_suite
    local runtime_phase scheduler_phase shfmt_phase signal_phase static_phase
    local workflow_file

    assert_shell_inventory_is_canonical
    assert_shfmt_update_workflow_policy
    assert_file_contains "${SCRIPT_DIR}/tests/lib/assert.sh" \
        'assert_path_mode() {' \
        'shared permission-mode assertion'
    for static_phase in \
        test_static_tooling_contracts \
        test_static_shell_interface_contracts \
        test_static_release_contracts \
        test_static_cleanup_and_qualification_contracts \
        test_static_packaging_signing_contracts \
        test_static_application_contracts \
        test_static_package_contracts \
        test_static_runtime_regression_contracts \
        test_static_upgrade_and_supply_chain_contracts; do
        assert_file_contains "${SCRIPT_DIR}/test-static.sh" \
            "${static_phase}() {" \
            "static validation phase ${static_phase}"
    done
    assert_status 65 'shfmt bootstrap rejects a relative cache root' \
        env SHFMT_TOOL_ROOT=relative \
        "${SCRIPT_DIR}/scripts/dev-tools/ensure-shfmt.sh"
    for shfmt_phase in \
        require_shfmt_commands \
        load_shfmt_pin \
        select_shfmt_platform \
        resolve_shfmt_cache \
        prepare_shfmt_cache \
        download_shfmt_asset \
        publish_shfmt_binary; do
        assert_file_contains "${SCRIPT_DIR}/scripts/dev-tools/ensure-shfmt.sh" \
            "${shfmt_phase}() {" \
            "shfmt bootstrap phase ${shfmt_phase}"
    done
    assert_file_contains "${SCRIPT_DIR}/scripts/dev-tools/ensure-shfmt.sh" \
        "local resolved_version_dir=''" \
        'shfmt cache directory does not shadow its caller output variable'

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
    for workflow_file in \
        .github/workflows/shell.yml \
        .github/workflows/packages.yml \
        .github/workflows/release.yml \
        .github/workflows/shfmt-update.yml; do
        assert_file_contains "${SCRIPT_DIR}/${workflow_file}" \
            'tests/run-all.sh --jobs 4' \
            "${workflow_file} enables bounded parallel validation"
    done
    assert_status 0 'run-all lists its canonical integration suites' \
        "${SCRIPT_DIR}/tests/run-all.sh" --list
    assert_text_contains "${ASSERT_OUTPUT}" 'runtime-manager-hardening' \
        'run-all suite list includes runtime hardening'
    for mock_engine_suite in \
        mock-engine-core \
        mock-engine-hls \
        mock-engine-staging; do
        assert_text_contains "${ASSERT_OUTPUT}" "${mock_engine_suite}" \
            "run-all suite list includes ${mock_engine_suite} coverage"
    done
    for mock_gui_suite in mock-gui-progress mock-gui-state; do
        assert_text_contains "${ASSERT_OUTPUT}" "${mock_gui_suite}" \
            "run-all suite list includes ${mock_gui_suite} coverage"
    done
    assert_text_contains "${ASSERT_OUTPUT}" 'mock-signals' \
        'run-all suite list includes mock signal coverage'
    for mock_runtime_suite in mock-runtime-compat mock-runtime-validation; do
        assert_text_contains "${ASSERT_OUTPUT}" "${mock_runtime_suite}" \
            "run-all suite list includes ${mock_runtime_suite} coverage"
    done
    assert_status 2 'run-all rejects conflicting validation profiles' \
        "${SCRIPT_DIR}/tests/run-all.sh" --fast --full
    assert_status 2 'run-all rejects zero integration concurrency' \
        "${SCRIPT_DIR}/tests/run-all.sh" --jobs 0 --list
    assert_status 0 'mock integration lists its parallel-safe groups' \
        "${SCRIPT_DIR}/tests/mock-integration.sh" --list-groups
    assert_text_contains "${ASSERT_OUTPUT}" 'engine' \
        'mock integration group list includes engine coverage'
    for mock_engine_group in engine-core engine-hls engine-staging; do
        assert_text_contains "${ASSERT_OUTPUT}" "${mock_engine_group}" \
            "mock integration group list includes ${mock_engine_group} coverage"
    done
    assert_text_contains "${ASSERT_OUTPUT}" 'gui' \
        'mock integration group list includes GUI coverage'
    for mock_gui_group in gui-progress gui-state; do
        assert_text_contains "${ASSERT_OUTPUT}" "${mock_gui_group}" \
            "mock integration group list includes ${mock_gui_group} coverage"
    done
    assert_text_contains "${ASSERT_OUTPUT}" 'signals' \
        'mock integration group list includes signal coverage'
    assert_text_contains "${ASSERT_OUTPUT}" 'runtime' \
        'mock integration group list includes runtime coverage'
    for mock_runtime_group in runtime-compat runtime-validation; do
        assert_text_contains "${ASSERT_OUTPUT}" "${mock_runtime_group}" \
            "mock integration group list includes ${mock_runtime_group} coverage"
    done
    assert_status 2 'mock integration rejects an unknown group' \
        "${SCRIPT_DIR}/tests/mock-integration.sh" --group unknown
    for mock_phase in \
        initialize_mock_integration \
        run_mock_engine_group \
        run_mock_engine_core_group \
        run_mock_engine_hls_group \
        run_mock_engine_staging_group \
        run_selected_mock_engine_group \
        run_mock_gui_progress_group \
        run_mock_gui_state_group \
        run_mock_gui_group \
        run_selected_mock_gui_group \
        run_mock_signal_group \
        run_mock_runtime_compat_group \
        run_mock_runtime_validation_group \
        run_mock_runtime_group \
        run_selected_mock_runtime_group \
        report_mock_integration_completion; do
        assert_file_contains "${SCRIPT_DIR}/tests/mock-integration.sh" \
            "${mock_phase}() {" \
            "mock integration phase ${mock_phase}"
    done
    for engine_phase in \
        test_mock_cleanup_owner_guard \
        test_mock_engine_log_retention \
        test_mock_engine_audio_downloads \
        test_mock_engine_video_downloads \
        test_mock_engine_youtube_hls \
        test_mock_engine_failure_paths \
        test_mock_engine_private_staging; do
        assert_file_contains "${SCRIPT_DIR}/tests/mock-integration.sh" \
            "${engine_phase}() {" \
            "mock engine phase ${engine_phase}"
    done
    for gui_phase in \
        test_mock_gui_aria_progress \
        test_mock_gui_profiles \
        test_mock_gui_progress_completion \
        test_mock_gui_config_recovery \
        test_mock_gui_file_selection \
        test_mock_gui_diagnostic_logs \
        test_mock_gui_state_initialization; do
        assert_file_contains "${SCRIPT_DIR}/tests/mock-integration.sh" \
            "${gui_phase}() {" \
            "mock GUI phase ${gui_phase}"
    done
    for signal_phase in \
        test_mock_signal_cli_download \
        test_mock_signal_cli_ffmpeg \
        test_mock_signal_gui_session \
        test_mock_signal_gui_cancellation \
        test_mock_signal_gui_startup_error \
        test_mock_signal_zenity_status; do
        assert_file_contains "${SCRIPT_DIR}/tests/mock-integration.sh" \
            "${signal_phase}() {" \
            "mock signal phase ${signal_phase}"
    done
    for runtime_phase in \
        test_mock_runtime_version_formats \
        test_mock_runtime_worker_failure \
        test_mock_runtime_version_overflow \
        test_mock_runtime_media_validation \
        test_mock_runtime_dependencies \
        test_mock_runtime_progress_errors \
        test_mock_runtime_missing_zenity; do
        assert_file_contains "${SCRIPT_DIR}/tests/mock-integration.sh" \
            "${runtime_phase}() {" \
            "mock runtime phase ${runtime_phase}"
    done
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shell.yml" \
        'bash ./tests/run-all.sh --jobs 4' \
        'shell CI enables bounded integration-suite concurrency'
    assert_file_contains "${SCRIPT_DIR}/tests/lib/test-runner.sh" \
        'test_runner_wait_any() {' \
        'test runner exposes completion-driven child collection'
    # shellcheck disable=SC2016 # Literal library default assertion.
    assert_file_contains "${SCRIPT_DIR}/tests/lib/test-runner.sh" \
        'YTDLP_ARIA2_TEST_RUNNER_TERMINATION_POLL_ATTEMPTS:-50' \
        'test runner retains a five-second production termination grace period'
    assert_file_contains "${SCRIPT_DIR}/tests/run-all-signal-integration.sh" \
        '"YTDLP_ARIA2_TEST_RUNNER_TERMINATION_POLL_ATTEMPTS": "10"' \
        'signal integration bounds its deliberate escalation wait'
    assert_file_contains "${SCRIPT_DIR}/tests/lib/project-files.sh" \
        'tests/repeat-qualification.sh' \
        'parallel repeat runner belongs to the canonical shell inventory'
    for scheduler_phase in \
        initialize_static_validation_schedule \
        start_static_validation \
        collect_completed_static_validation \
        report_static_validations \
        run_static_validations \
        initialize_integration_schedule \
        start_integration_suite \
        collect_completed_integration_suite \
        report_integration_suites \
        run_integration_suites; do
        assert_file_contains "${SCRIPT_DIR}/tests/run-all.sh" \
            "${scheduler_phase}() {" \
            "integration scheduler phase ${scheduler_phase}"
    done
    assert_file_not_contains "${SCRIPT_DIR}/tests/run-all.sh" \
        'run_suite_batch() {' \
        'integration scheduler has no fixed-batch barrier'
    for repeat_workflow in real-tools release packages stress; do
        assert_file_contains \
            "${SCRIPT_DIR}/.github/workflows/${repeat_workflow}.yml" \
            'bash ./tests/repeat-qualification.sh' \
            "${repeat_workflow} workflow parallelizes independent repetitions"
    done
    assert_file_contains "${SCRIPT_DIR}/tests/test-runner-integration.sh" \
        "assert_equals '23' \"\${status}\"" \
        'wait-any qualification preserves failed child status'

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
        'Reformat with candidate shfmt in a no-network sandbox' \
        'automation reformats with the candidate shfmt inside an isolated sandbox'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'Validate verified formatter and project' \
        'automation validates the formatter update only after fresh verification'
}

test_static_shell_interface_contracts() {
    local file installer_phase installer_test_phase required_probe
    local -a engine_locale_probes

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
    for installer_phase in \
        validate_install_environment \
        require_installer_commands \
        validate_install_arguments \
        initialize_install_paths \
        install_launcher \
        uninstall_launcher \
        dispatch_install_action; do
        assert_file_contains "${SCRIPT_DIR}/install-gui.sh" \
            "${installer_phase}() {" \
            "desktop installer phase ${installer_phase}"
    done
    for installer_test_phase in \
        test_installer_initial_installation \
        test_installer_reinstallation \
        test_installer_failure_modes \
        test_installer_uninstall_lifecycle; do
        assert_file_contains "${SCRIPT_DIR}/tests/installer-integration.sh" \
            "${installer_test_phase}() {" \
            "installer integration phase ${installer_test_phase}"
    done

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
}

test_static_release_contracts() {
    local engine_reported_version evidence_phase preflight_phase readme_path
    local release_workflow

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
        "development version is **${EXPECTED_VERSION}**." \
        'English README development version'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "développement actuelle est la **${EXPECTED_VERSION}**." \
        'French README development version'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "latest published package release is **${EXPECTED_PUBLISHED_VERSION}**." \
        'English README published version'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "dernière release de paquets publiée est la **${EXPECTED_PUBLISHED_VERSION}**." \
        'French README published version'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "yt-dlp-aria2-downloader-gui-${EXPECTED_PUBLISHED_VERSION}-1.fc44.noarch.rpm" \
        'English README published RPM asset'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "yt-dlp-aria2-downloader-gui-${EXPECTED_PUBLISHED_VERSION}-1.fc44.noarch.rpm" \
        'French README published RPM asset'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "yt-dlp-aria2-downloader-gui_${EXPECTED_PUBLISHED_VERSION}-1_all.deb" \
        'English README published DEB asset'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "yt-dlp-aria2-downloader-gui_${EXPECTED_PUBLISHED_VERSION}-1_all.deb" \
        'French README published DEB asset'
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "cd yt-dlp-aria2-downloader-gui-${EXPECTED_PUBLISHED_VERSION}" \
        'English README published portable archive directory'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "cd yt-dlp-aria2-downloader-gui-${EXPECTED_PUBLISHED_VERSION}" \
        'French README published portable archive directory'
    if [[ ${EXPECTED_PUBLISHED_VERSION} != "${EXPECTED_VERSION}" ]]; then
        for readme_path in \
            "${SCRIPT_DIR}/README.md" \
            "${SCRIPT_DIR}/README.fr.md"; do
            assert_file_not_contains "${readme_path}" \
                "yt-dlp-aria2-downloader-gui-${EXPECTED_VERSION}-1.fc44.noarch.rpm" \
                'README does not advertise an unpublished RPM asset'
            assert_file_not_contains "${readme_path}" \
                "yt-dlp-aria2-downloader-gui_${EXPECTED_VERSION}-1_all.deb" \
                'README does not advertise an unpublished DEB asset'
            assert_file_not_contains "${readme_path}" \
                "yt-dlp-aria2-downloader-gui-${EXPECTED_VERSION}.zip" \
                'README does not advertise an unpublished ZIP asset'
        done
    fi
    assert_file_contains "${SCRIPT_DIR}/README.md" \
        "gh release verify v${EXPECTED_PUBLISHED_VERSION} -R OscarFrog/yt-dlp-aria2-downloader-gui" \
        'English README published release verification tag'
    assert_file_contains "${SCRIPT_DIR}/README.fr.md" \
        "gh release verify v${EXPECTED_PUBLISHED_VERSION} -R OscarFrog/yt-dlp-aria2-downloader-gui" \
        'French README published release verification tag'
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
        'expected_reported_version="download-video.sh version ${version}"' \
        'release binds the exact executable version output to the release tag'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'grep -Fqx "readonly VERSION=\"${version}\"" download-video.sh' \
        'release validates engine version constant'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'grep -Fqx "readonly APP_VERSION='\''${version}'\''" install-fedora.sh' \
        'release validates Fedora bootstrap version constant'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'grep -Fq "development version is **${version}**." README.md' \
        'release validates English README development version'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'grep -Fq "développement actuelle est la **${version}**." README.fr.md' \
        'release validates French README development version'
    for release_workflow in \
        "${SCRIPT_DIR}/.github/workflows/packages.yml" \
        "${SCRIPT_DIR}/.github/workflows/release.yml"; do
        # shellcheck disable=SC2016
        assert_file_contains "${release_workflow}" \
            'repos/${GITHUB_REPOSITORY}/releases?per_page=100' \
            'previous-release resolution uses published GitHub Releases'
        assert_file_contains "${release_workflow}" \
            'select(.draft == false and .prerelease == false and .published_at != null)' \
            'previous-release resolution excludes unpublished and prerelease records'
        # shellcheck disable=SC2016
        assert_file_contains "${release_workflow}" \
            'printf '\''%s\n'\'' "${published_release_tags}"' \
            'previous-release candidates come from published release tags'
    done
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

    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/stress.yml" \
        'RUNTIME_STRESS_RESULT: ${{ needs.runtime-hardening-stress.result }}' \
        'required stress gate includes runtime-manager stress'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/stress.yml" \
        'PACKAGE_STRESS_RESULT: ${{ needs.package-cleanup-stress.result }}' \
        'required stress gate includes package-cleanup stress'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/qualification.yml" \
        'readonly rpmfusion_fingerprint=E9A491A3DE247814E7E067EAE06F8ECDD651FF2E' \
        'Fedora qualification pins the RPM Fusion bootstrap signer'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/qualification.yml" \
        'rpmfusion-free-release-44-3.noarch' \
        'Fedora qualification pins the reviewed RPM Fusion bootstrap NEVRA'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'verify-shfmt-update:' \
        'shfmt updater uses a separate fresh read-only verifier job'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'canonical equivalence under the previously trusted shfmt' \
        'shfmt updater documents the independent semantic boundary'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'shfmt-tested-tree.sha256' \
        'shfmt updater binds the privileged tree to the verified read-only tree'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'shfmt automation may not modify its canonical inventory controller' \
        'shfmt updater protects its canonical inventory controller'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'candidate shfmt pin file differs from the exact data-only schema' \
        'shfmt updater enforces an exact data-only pin schema'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        "if: github.ref == 'refs/heads/main'" \
        'scheduled/manual shfmt updater is bound to main'
    # shellcheck disable=SC2016 # Literal GitHub Actions expression assertion.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'EXPECTED_BASE_SHA: ${{ github.sha }}' \
        'shfmt verifier/publisher bind to the immutable workflow event SHA'
    assert_file_not_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'needs.prepare-shfmt-update.outputs.base_sha' \
        'shfmt updater never selects code or artifacts from a propagated job SHA'
    # shellcheck disable=SC2016 # Literal GitHub Actions expression assertion.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'shfmt-candidate-${{ github.run_id }}-${{ github.run_attempt }}' \
        'candidate shfmt handoff is scoped to the workflow run attempt'
    # shellcheck disable=SC2016 # Literal GitHub Actions expression assertion.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'shfmt-verified-${{ github.run_id }}-${{ github.run_attempt }}' \
        'verified shfmt handoff is scoped to the workflow run attempt'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        '--network=none' \
        'candidate shfmt executes without network access'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        '"${GITHUB_WORKSPACE}/.git:/workspace/.git:ro"' \
        'candidate shfmt cannot modify repository metadata'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/shfmt-update.yml" \
        'Validate verified formatter and project' \
        'project tests run only after fresh formatter verification'

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
        'RELEASE_TAG_SIGNING_FINGERPRINT: 43E5361414863738F0324F2B047B26057E612CDC' \
        'release workflow pins the authorized tag signer'
    # shellcheck disable=SC2016 # Literal workflow source.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'git verify-tag --raw "${RELEASE_TAG}"' \
        'release workflow performs isolated local tag verification'
    # shellcheck disable=SC2016 # Literal workflow source.
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        '${signer_fingerprint} != "${RELEASE_TAG_SIGNING_FINGERPRINT}"' \
        'release workflow rejects any other valid tag signer'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'public asset differs byte-for-byte from tested artifact' \
        'public release assets are compared byte-for-byte with tested artifacts'

    assert_file_contains "${SCRIPT_DIR}/.github/workflows/release.yml" \
        'manual release recovery must run from a tag ref' \
        'manual release recovery is bound to an exact tag ref'
    assert_status 2 'release preflight requires confirmations and a tag' \
        "${SCRIPT_DIR}/scripts/release-preflight.sh"
    assert_status 77 'release preflight rejects missing operator confirmations' \
        "${SCRIPT_DIR}/scripts/release-preflight.sh" "v${EXPECTED_VERSION}"
    for preflight_phase in \
        parse_preflight_arguments \
        require_preflight_commands \
        resolve_preflight_repository \
        verify_release_tag \
        verify_release_tree_and_version \
        verify_immutable_releases \
        verify_signing_environment \
        verify_signing_secret_scope \
        inspect_preflight_rpm_certificate \
        check_preflight_rpm_signing_expiry \
        validate_preflight_rpm_certificate \
        verify_rpm_signing_certificate \
        report_release_preflight; do
        assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
            "${preflight_phase}() {" \
            "release preflight phase ${preflight_phase}"
    done
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        "local resolved_tag_commit=''" \
        'release preflight tag commit does not shadow its caller output variable'
    assert_status 0 'release evidence qualification exposes help' \
        "${SCRIPT_DIR}/scripts/release-evidence-qualification.sh" --help
    assert_status 65 'release evidence qualification rejects an invalid tag' \
        "${SCRIPT_DIR}/scripts/release-evidence-qualification.sh" \
        invalid-tag 0000000000000000000000000000000000000000
    for evidence_phase in \
        retry_qualification_capture \
        retry_qualification_command \
        parse_qualification_arguments \
        require_qualification_commands \
        initialize_qualification_workspace \
        resolve_release_identity \
        download_and_verify_release_assets \
        collect_exact_sha_runs \
        collect_scheduled_runs \
        resolve_qualification_report \
        write_exact_sha_run_line \
        write_scheduled_run_line \
        write_qualification_report; do
        assert_file_contains "${SCRIPT_DIR}/scripts/release-evidence-qualification.sh" \
            "${evidence_phase}() {" \
            "release evidence phase ${evidence_phase}"
    done
    # shellcheck disable=SC2016 # Literal pagination source.
    assert_file_contains \
        "${SCRIPT_DIR}/scripts/release-evidence-qualification.sh" \
        'runs?per_page=100&page=${page}' \
        'release evidence paginates exact-SHA lookup until a match or final page'
    assert_file_not_contains \
        "${SCRIPT_DIR}/scripts/release-evidence-qualification.sh" \
        '--limit 100 ' \
        'release evidence no longer stops exact-SHA lookup at 100 runs'
    for evidence_output_local in \
        workspace_public_dir \
        workspace_inventory_file \
        workspace_actual_inventory_file \
        resolved_repo \
        resolved_release_url \
        resolved_release_immutable \
        resolved_release_published_at; do
        assert_file_contains \
            "${SCRIPT_DIR}/scripts/release-evidence-qualification.sh" \
            "local ${evidence_output_local}=" \
            "release evidence output local ${evidence_output_local}"
    done
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        '--confirm-single-maintainer-self-review' \
        'release preflight requires explicit single-maintainer self-review acknowledgement'
    assert_file_not_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        '--confirm-admin-bypass-disabled' \
        'release preflight no longer substitutes an operator claim for API state'
    assert_file_not_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        '--confirm-tag-policy' \
        'release preflight obtains deployment policy type from the API'
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        '.can_admins_bypass' \
        'release preflight reads administrator bypass state'
    assert_file_contains "${SCRIPT_DIR}/scripts/release-preflight.sh" \
        'deployment_policy_type} == tag' \
        'release preflight requires an exact tag deployment policy'
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
}

test_static_cleanup_and_qualification_contracts() {
    local aria2_behavior_phase cleanup_phase cleanup_scenario real_tools_phase

    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/packaging/package-user-cleanup.sh" \
        '${path} != *[[:cntrl:]]*' \
        'package cleanup rejects marker path control characters'
    assert_file_contains "${SCRIPT_DIR}/packaging/package-user-cleanup.sh" \
        'unable to enumerate users from /etc/passwd or getent; skipping all-user cleanup' \
        'package cleanup diagnoses unavailable enumeration sources'
    assert_status 2 'package cleanup requires an explicit mode' \
        "${SCRIPT_DIR}/packaging/package-user-cleanup.sh"
    assert_status 64 'package cleanup rejects an unsafe user HOME' \
        "${SCRIPT_DIR}/packaging/package-user-cleanup.sh" --user-home /
    for cleanup_phase in \
        initialize_cleanup_helper_path \
        discover_cleanup_data_homes \
        cleanup_registered_data_home \
        cleanup_standard_user_paths \
        cleanup_one_home \
        run_as_user \
        enumerate_users \
        run_all_users_mode \
        run_user_home_mode \
        run_numeric_home_mode; do
        assert_file_contains "${SCRIPT_DIR}/packaging/package-user-cleanup.sh" \
            "${cleanup_phase}() {" \
            "package cleanup phase ${cleanup_phase}"
    done
    for cleanup_scenario in \
        test_valid_custom_xdg_cleanup \
        test_forged_marker_preservation \
        test_multiline_marker_rejection \
        test_symlinked_sentinel_rejection \
        test_terminal_runtime_symlink \
        test_control_character_marker \
        test_unavailable_home \
        test_oversized_marker \
        test_foreign_owned_home_rejection \
        test_symlinked_foreign_home_rejection; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/package-user-cleanup-integration.sh" \
            "${cleanup_scenario}() {" \
            "package cleanup integration scenario ${cleanup_scenario}"
    done

    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'hls_duration_loss_us <= hls_duration_tolerance_us' \
        'HLS post-remux duration loss is bounded before publication'
    assert_file_contains "${SCRIPT_DIR}/tests/real-tools-integration.sh" \
        "--downloader 'dash,m3u8:native'" \
        'real-tool qualification defends native DASH/HLS routing'
    for real_tools_phase in \
        prepare_real_tool_fixtures \
        test_real_direct_audio_scenarios \
        test_real_media_validation_mutations \
        test_real_fragment_routing_and_mutations; do
        assert_file_contains "${SCRIPT_DIR}/tests/real-tools-integration.sh" \
            "${real_tools_phase}() {" \
            "real-tool integration phase ${real_tools_phase}"
    done
    for aria2_behavior_phase in \
        prepare_aria2_behavior_fixtures \
        test_aria2_server_quiescence \
        test_aria2_transport_behavior \
        test_aria2_cancel_clean_restart; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/aria2-real-behavior-integration.sh" \
            "${aria2_behavior_phase}() {" \
            "real aria2 behavior phase ${aria2_behavior_phase}"
    done
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
}

test_static_packaging_signing_contracts() {
    local fedora_phase rpm6_phase rpm_changelog

    assert_file_contains \
        "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh" \
        '--define "_rpmformat 4"' \
        'RPM package format is explicitly pinned to v4'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains \
        "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh" \
        'if [[ ${package_format} != 4 ]]; then' \
        'generated RPM package format is independently verified'
    for rpm6_phase in \
        validate_rpm6_environment \
        prepare_rpm6_workspace \
        prepare_rpm6_signers \
        test_rpm_v4_legacy_signature \
        test_rpm_v4_v6_multisig \
        test_rpm_v6_multisig_semantics; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/rpm6-multisig-integration.sh" \
            "${rpm6_phase}() {" \
            "RPM 6 qualification phase ${rpm6_phase}"
    done

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
    [[ ! -e ${SCRIPT_DIR}/packaging/deb/postinst &&
        ! -e ${SCRIPT_DIR}/packaging/deb/prerm &&
        ! -e ${SCRIPT_DIR}/packaging/deb/postrm ]] \
        || fail 'DEB package source still contains unnecessary maintainer scripts.'
    assert_file_contains "${SCRIPT_DIR}/packaging/install-tree.sh" \
        'packaging/package-user-cleanup.sh' \
        'package tree ships user cleanup helper'

    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        "readonly RPM_SIGNING_FINGERPRINT='7B54065FE061E78ED2C96252E3BE996196ABEA7F'" \
        'Fedora bootstrap pins the RPM signing fingerprint'
    assert_status 2 'Fedora bootstrap requires one RPM argument' \
        "${SCRIPT_DIR}/install-fedora.sh"
    for fedora_phase in \
        root_stage_path_is_safe \
        create_root_stage \
        remove_root_stage \
        stage_root_file \
        cleanup \
        parse_fedora_arguments \
        require_fedora_installer_commands \
        initialize_fedora_paths \
        validate_rpm_identity \
        inspect_rpm_signature \
        resolve_rpm_signing_key \
        detect_supported_fedora \
        ensure_rpm_verification_gpg \
        inspect_rpm_signing_certificate \
        validate_rpm_signing_certificate \
        verify_rpm_with_pinned_keyring \
        verify_signed_rpm \
        authenticate_signed_rpm \
        prepare_application_rpm \
        release_application_stage \
        ensure_rpm_fusion_bootstrap_tools \
        validate_rpm_fusion_certificate \
        validate_rpm_fusion_release_identity \
        enable_rpm_fusion \
        install_media_dependencies \
        install_application_rpm \
        validate_installed_system \
        update_managed_runtimes \
        report_fedora_installation; do
        assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
            "${fedora_phase}() {" \
            "Fedora bootstrap phase ${fedora_phase}"
    done
    for fedora_output_local in \
        parsed_allow_unsigned_dev \
        parsed_rpm_argument \
        detected_ffmpeg_vendor; do
        assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
            "local ${fedora_output_local}=" \
            "Fedora bootstrap output local ${fedora_output_local}"
    done
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        "readonly RPM_SIGNING_SUBKEY_FINGERPRINT='1F5B769CE48A08AAC0A7D9DDECC9894B41830245'" \
        'Fedora bootstrap pins the dedicated RPM signing subkey'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        "readonly RPM_FUSION_SIGNING_FINGERPRINT='E9A491A3DE247814E7E067EAE06F8ECDD651FF2E'" \
        'Fedora bootstrap pins the RPM Fusion signing fingerprint'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        "readonly RPM_FUSION_RELEASE_NEVRA='rpmfusion-free-release-44-3.noarch'" \
        'Fedora bootstrap pins the reviewed RPM Fusion NEVRA'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '--proto '\''=https'\''' \
        'Fedora bootstrap constrains RPM Fusion transport to HTTPS'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        '--connect-timeout 15 --max-time 120' \
        'Fedora bootstrap downloads have bounded connection and transfer timeouts'
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
    assert_file_not_contains "${SCRIPT_DIR}/install-fedora.sh" \
        'dnf install --assumeyes "https://' \
        'Fedora bootstrap never gives an unauthenticated URL to privileged DNF'
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
    # The Fedora bootstrap captures complete GPG output from the privileged,
    # protected staging area before parsing primary and subkey records.
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        'certificate_output=$(LC_ALL=C run_root gpg' \
        'Fedora installer captures the complete public-key listing before parsing'
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
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        'resolved_stage_path=$(run_root mktemp -d --tmpdir=/tmp' \
        'Fedora installer creates staging through the privileged boundary'
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        'run_root install -m 0600' \
        'Fedora installer copies authorization inputs into root-owned staging'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        'validate_rpm_identity "${STAGED_APPLICATION_RPM}"' \
        'Fedora installer revalidates application identity inside root staging'
    # shellcheck disable=SC2016
    assert_file_contains "${SCRIPT_DIR}/install-fedora.sh" \
        'install_application_rpm "${STAGED_APPLICATION_RPM}"' \
        'Fedora installer gives DNF only the staged application RPM'
    assert_file_contains \
        "${SCRIPT_DIR}/tests/install-fedora-authentication-integration.sh" \
        'root staging remains bound to verified bytes after source mutation' \
        'Fedora root-staging TOCTOU has a mutation regression test'
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
}

test_static_application_contracts() {
    local aria2_header_test_phase engine_phase gui_phase monitor_phase
    local ffmpeg_progress_test_phase ffmpeg_real_test_phase monitor_test_phase
    local hls_remux_test_phase private_plan_test_phase

    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'umask 077' \
        'engine restrictive umask'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'ARIA2_HTTPS_DIRECT_SAFE=false' \
        'affected aria2 GnuTLS HTTPS is forced to native transport'
    assert_file_contains "${SCRIPT_DIR}/private-aria2-plan.py" \
        'if url_scheme == "https" and not args.allow_https_direct:' \
        'private plan helper fails closed without HTTPS direct opt-in'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'the URL file must not be accessible by group or other users.' \
        'private URL-file permissions are enforced'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'Media validation reason: %s' \
        'final media failure exposes a bounded diagnostic reason'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'run_supervised_ytdlp() {' \
        'yt-dlp diagnostics pass through the source-label redactor'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        '[REDACTED_SOURCE]' \
        'retained GUI logs apply defense-in-depth source-label redaction'
    assert_file_contains "${SCRIPT_DIR}/tests/lib/test-runner.sh" \
        'TEST_RUNNER_STARTING_CHILD=true' \
        'test runner marks the launch/registration critical section'
    # shellcheck disable=SC2016 # Literal library source.
    assert_file_contains "${SCRIPT_DIR}/tests/lib/test-runner.sh" \
        'TEST_RUNNER_DEFERRED_SIGNAL=${signal_name}' \
        'test runner preserves a signal delivered before registration'
    assert_file_contains "${SCRIPT_DIR}/tests/test-runner-integration.sh" \
        'for iteration in range(30):' \
        'test runner repeats startup-signal registration stress'
    assert_file_contains "${SCRIPT_DIR}/tests/test-runner-integration.sh" \
        'YTDLP_ARIA2_TEST_CHILD_TOKEN' \
        'test runner stress binds PID checks to fixture identity'
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
        'run_supervised_ytdlp "${YTDLP_BIN}"' \
        'yt-dlp uses its redacting supervisor'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'ARIA2_SUPPORTS_NO_NETRC=false' \
        'aria2 netrc support is detected as an optional capability'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'if [[ ${ARIA2_SUPPORTS_NO_NETRC} == true ]]; then' \
        'aria2 receives no-netrc only when the build advertises it'
    for engine_phase in \
        check_ytdlp_runtime \
        check_deno_runtime \
        check_ytdlp_capabilities \
        check_aria2_runtime \
        check_aria2_capabilities \
        check_setsid_capabilities \
        check_runtime_compatibility \
        parse_arguments \
        resolve_requested_url \
        validate_mode_selection \
        initialize_runtime_dependencies \
        prepare_output_directory \
        prepare_private_work_files \
        configure_download_options \
        plan_selected_transport \
        configure_download_reporting \
        execute_selected_transport \
        normalize_successful_path_record \
        validate_hls_duration_parity \
        publish_hls_remux_result \
        remux_hls_result \
        validate_and_publish_result \
        finalize_download; do
        assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
            "${engine_phase}() {" \
            "engine phase ${engine_phase}"
    done
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'validate_final_media_file() {' \
        'final media FFprobe validation'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'probe_media_summary() {' \
        'combined FFprobe media summary'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'stream_disposition=attached_pic' \
        'combined FFprobe summary distinguishes attached cover art'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        'mv -nT -- "${HLS_REMUX_TMP}" "${final_path}"' \
        'HLS publication never treats the target as a directory'
    assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
        'YTDLP_ARIA2_SUPERVISED_SESSION=true' \
        'GUI requests reuse of its single process session without a public option'
    for gui_phase in \
        initialize_gui_paths \
        initialize_gui_environment \
        collect_download_request \
        prepare_gui_session \
        start_download_worker \
        run_progress_dialog \
        resolve_confirmed_final_path \
        show_success_dialog \
        handle_worker_result; do
        assert_file_contains "${SCRIPT_DIR}/download-video-gui.sh" \
            "${gui_phase}() {" \
            "GUI phase ${gui_phase}"
    done
    for monitor_phase in \
        initialize_progress_inputs \
        initialize_progress_state \
        open_progress_log \
        drain_progress_log \
        monitor_worker_progress \
        report_progress_completion; do
        assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
            "${monitor_phase}() {" \
            "progress monitor phase ${monitor_phase}"
    done
    for monitor_test_phase in \
        test_monitor_reader_lifecycle \
        test_monitor_planning_progress \
        test_monitor_direct_transfer_progress \
        test_monitor_native_transfer_progress \
        test_monitor_composite_and_postprocess_progress \
        test_monitor_failure_and_input_hardening; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/progress-monitor-integration.sh" \
            "${monitor_test_phase}() {" \
            "progress monitor integration phase ${monitor_test_phase}"
    done
    for private_plan_test_phase in \
        test_private_plan_classification \
        test_private_plan_input_validation \
        test_private_plan_publication_safety \
        test_private_plan_rollback_safety; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/private-aria2-plan-integration.sh" \
            "${private_plan_test_phase}() {" \
            "private aria2 plan phase ${private_plan_test_phase}"
    done
    for aria2_header_test_phase in \
        prepare_aria2_header_servers \
        test_replay_safe_aria2_headers \
        test_unsafe_aria2_header_policy; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/aria2-auth-headers-integration.sh" \
            "${aria2_header_test_phase}() {" \
            "aria2 header integration phase ${aria2_header_test_phase}"
    done
    for ffmpeg_progress_test_phase in \
        test_measured_ffmpeg_progress \
        test_oversized_ffmpeg_counters; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/ffmpeg-progress-integration.sh" \
            "${ffmpeg_progress_test_phase}() {" \
            "simulated FFmpeg progress phase ${ffmpeg_progress_test_phase}"
    done
    for ffmpeg_real_test_phase in \
        create_real_ffmpeg_fixture \
        run_real_ffmpeg_worker \
        wait_for_worker_barrier \
        wait_for_prepublication_progress \
        assert_real_progress_history \
        test_real_ffmpeg_progress_run; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/ffmpeg-real-progress-integration.sh" \
            "${ffmpeg_real_test_phase}() {" \
            "real FFmpeg progress phase ${ffmpeg_real_test_phase}"
    done
    for hls_remux_test_phase in \
        prepare_hls_media_fixtures \
        prepare_hls_runtime_mocks \
        test_hls_remux_duration_cases; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/hls-remux-duration-integration.sh" \
            "${hls_remux_test_phase}() {" \
            "HLS remux duration phase ${hls_remux_test_phase}"
    done
    assert_file_contains "${SCRIPT_DIR}/progress-monitor.sh" \
        'PROFILE OUTPUT_DIR' \
        'progress monitor receives the canonical destination'
}

test_static_package_contracts() {
    local README_EN_TEXT README_FR_TEXT
    local deb_build_phase deb_lifecycle_phase install_tree_phase
    local lifecycle_assertion packaging_test_phase rpm_build_phase rpm_lifecycle_phase

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
    for packaging_test_phase in \
        test_rejected_private_directories \
        test_alternate_private_directory \
        assert_packaged_executables \
        assert_packaged_entrypoints \
        assert_packaged_desktop_entry \
        assert_packaged_assets \
        test_packaged_install_tree; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/packaging-integration.sh" \
            "${packaging_test_phase}() {" \
            "packaging integration phase ${packaging_test_phase}"
    done
    assert_file_contains "${SCRIPT_DIR}/packaging/deb/build-deb.sh" \
        'dpkg-deb --root-owner-group --build' 'native DEB construction'
    assert_file_contains "${SCRIPT_DIR}/packaging/deb/build-deb.sh" \
        'local built_package_path=' \
        'DEB output path does not shadow its caller output variable'
    # shellcheck disable=SC2016 # Literal shadowed output-path declaration.
    assert_file_not_contains "${SCRIPT_DIR}/packaging/deb/build-deb.sh" \
        'local package_path="${RESOLVED_OUTPUT_DIR}/' \
        'DEB builder does not shadow its caller package path'
    assert_status 2 'DEB builder requires a semantic version' \
        "${SCRIPT_DIR}/packaging/deb/build-deb.sh"
    assert_status 2 'DEB builder rejects a malformed version' \
        "${SCRIPT_DIR}/packaging/deb/build-deb.sh" malformed-version
    for deb_build_phase in \
        parse_deb_build_arguments \
        require_deb_build_commands \
        initialize_deb_build_paths \
        validate_deb_source_tree \
        initialize_deb_output_directory \
        initialize_deb_workspace \
        resolve_deb_build_timestamp \
        stage_deb_payload \
        write_deb_documentation \
        write_deb_control_metadata \
        write_deb_checksums \
        build_deb_package \
        validate_deb_package; do
        assert_file_contains "${SCRIPT_DIR}/packaging/deb/build-deb.sh" \
            "${deb_build_phase}() {" \
            "DEB build phase ${deb_build_phase}"
    done
    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh" \
        'rpmbuild -bb' 'native RPM construction'
    assert_status 2 'RPM builder requires a semantic version' \
        "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh"
    assert_status 2 'RPM builder rejects a malformed version' \
        "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh" malformed-version
    for rpm_build_phase in \
        parse_rpm_build_arguments \
        require_rpm_build_commands \
        initialize_rpm_build_paths \
        validate_rpm_source_tree \
        initialize_rpm_output_directory \
        initialize_rpm_workspace \
        prepare_rpmbuild_tree \
        build_rpm_payload \
        publish_rpm_artifact \
        validate_rpm_artifact; do
        assert_file_contains "${SCRIPT_DIR}/packaging/rpm/build-rpm.sh" \
            "${rpm_build_phase}() {" \
            "RPM build phase ${rpm_build_phase}"
    done
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
    assert_status 2 'package-tree installer requires three arguments' \
        "${SCRIPT_DIR}/packaging/install-tree.sh"
    assert_status 2 'package-tree installer rejects a malformed version' \
        "${SCRIPT_DIR}/packaging/install-tree.sh" \
        '/tmp/package-tree-static-test' malformed-version \
        '/usr/lib/yt-dlp-aria2-downloader'
    for install_tree_phase in \
        parse_install_tree_arguments \
        validate_install_tree_arguments \
        require_install_tree_commands \
        initialize_install_tree_paths \
        validate_packaging_inputs \
        install_private_payload \
        install_shared_payload \
        install_package_launchers; do
        assert_file_contains "${SCRIPT_DIR}/packaging/install-tree.sh" \
            "${install_tree_phase}() {" \
            "package-tree installation phase ${install_tree_phase}"
    done
    for lifecycle_assertion in \
        assert_package_cli_version \
        assert_common_package_payload \
        assert_package_paths_absent; do
        assert_file_contains "${SCRIPT_DIR}/tests/lib/package-lifecycle.sh" \
            "${lifecycle_assertion}() {" \
            "shared package lifecycle assertion ${lifecycle_assertion}"
    done
    assert_status 2 'DEB lifecycle test requires package and version' \
        "${SCRIPT_DIR}/packaging/deb/test-package-lifecycle.sh"
    assert_status 2 'DEB lifecycle test rejects a malformed version' \
        "${SCRIPT_DIR}/packaging/deb/test-package-lifecycle.sh" \
        missing.deb malformed-version
    for deb_lifecycle_phase in \
        parse_deb_lifecycle_arguments \
        require_deb_lifecycle_environment \
        initialize_deb_lifecycle_paths \
        validate_deb_dependencies \
        validate_deb_initial_state \
        initialize_deb_lifecycle_workspace \
        inspect_deb_payload \
        install_initial_deb \
        remove_and_purge_deb \
        reinstall_and_purge_deb; do
        assert_file_contains \
            "${SCRIPT_DIR}/packaging/deb/test-package-lifecycle.sh" \
            "${deb_lifecycle_phase}() {" \
            "DEB lifecycle phase ${deb_lifecycle_phase}"
    done
    assert_status 2 'RPM lifecycle test requires package and version' \
        "${SCRIPT_DIR}/packaging/rpm/test-package-lifecycle.sh"
    assert_status 2 'RPM lifecycle test rejects a malformed version' \
        "${SCRIPT_DIR}/packaging/rpm/test-package-lifecycle.sh" \
        missing.rpm malformed-version
    for rpm_lifecycle_phase in \
        parse_rpm_lifecycle_arguments \
        require_rpm_lifecycle_environment \
        initialize_rpm_lifecycle_paths \
        validate_rpm_dependencies \
        validate_rpm_initial_state \
        initialize_rpm_lifecycle_workspace \
        inspect_rpm_payload \
        install_initial_rpm \
        remove_rpm \
        reinstall_and_remove_rpm; do
        assert_file_contains \
            "${SCRIPT_DIR}/packaging/rpm/test-package-lifecycle.sh" \
            "${rpm_lifecycle_phase}() {" \
            "RPM lifecycle phase ${rpm_lifecycle_phase}"
    done
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
}

test_static_runtime_regression_contracts() {
    local hardening_phase runtime_manager_test_phase runtime_phase

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
        "if [[ \${video_present} != true ]]; then" 'complete-video content-video stream validation'
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        "if [[ \${audio_present} != true ]]; then" 'complete-video audio stream validation'
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
    for runtime_phase in \
        initialize_runtime_layout \
        initialize_runtime_policy \
        initialize_runtime_platform \
        prepare_runtime_storage \
        print_runtime_versions \
        print_engine_runtime_attestation \
        dispatch_runtime_command; do
        assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
            "${runtime_phase}() {" \
            "runtime manager phase ${runtime_phase}"
    done
    for runtime_manager_test_phase in \
        prepare_runtime_manager_fixture \
        test_runtime_paths_and_locking \
        test_runtime_offline_and_rollback \
        test_runtime_bootstrap_and_architecture; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/runtime-manager-integration.sh" \
            "${runtime_manager_test_phase}() {" \
            "runtime manager integration phase ${runtime_manager_test_phase}"
    done
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
    # shellcheck disable=SC2016 # Literal managed-runtime contract assertion.
    assert_file_contains "${SCRIPT_DIR}/download-video.sh" \
        '"${runtime_manager}" prepare "${runtime_action}"' \
        'engine consumes one attested managed-runtime preparation'
    assert_file_contains "${SCRIPT_DIR}/runtime-manager.sh" \
        "readonly ENGINE_RUNTIME_CONTRACT_VERSION='1'" \
        'managed-runtime attestation contract is explicitly versioned'

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
    for hardening_phase in \
        initialize_runtime_hardening_workspace \
        write_runtime_hardening_mocks \
        initialize_runtime_hardening_fixtures \
        test_runtime_setting_bounds \
        test_oversized_deno_versions \
        test_invalid_runtime_path \
        test_mismatched_ytdlp_candidate \
        test_signature_failure_bootstrap \
        test_fresh_runtime_bootstrap \
        test_no_network_require \
        test_invalid_active_runtime_recovery \
        test_runtime_updates \
        test_repeated_rollbacks \
        test_invalid_rollback_targets \
        test_activation_journal_recovery \
        test_runtime_lock_hardening; do
        assert_file_contains \
            "${SCRIPT_DIR}/tests/runtime-manager-hardening-integration.sh" \
            "${hardening_phase}() {" \
            "runtime hardening phase ${hardening_phase}"
    done
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains \
        "${SCRIPT_DIR}/tests/runtime-manager-hardening-integration.sh" \
        'ROLLBACK_RUNS=${RUNTIME_HARDENING_ROLLBACK_RUNS:-3}' \
        'runtime hardening uses a bounded ordinary rollback repetition count'
    # shellcheck disable=SC2016 # Literal shell-source assertion.
    assert_file_contains \
        "${SCRIPT_DIR}/tests/runtime-manager-hardening-integration.sh" \
        'CONTENTION_RUNS=${RUNTIME_HARDENING_CONTENTION_RUNS:-3}' \
        'runtime hardening uses a bounded ordinary contention repetition count'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/stress.yml" \
        'RUNTIME_HARDENING_ROLLBACK_RUNS: 10' \
        'runtime hardening stress restores ten rollback cycles per run'
    assert_file_contains "${SCRIPT_DIR}/.github/workflows/stress.yml" \
        'RUNTIME_HARDENING_CONTENTION_RUNS: 10' \
        'runtime hardening stress restores ten contention cycles per run'
    assert_status 64 'runtime hardening rejects zero rollback repetitions' \
        env RUNTIME_HARDENING_ROLLBACK_RUNS=0 \
        "${SCRIPT_DIR}/tests/runtime-manager-hardening-integration.sh"
    assert_text_contains "${ASSERT_OUTPUT}" \
        'RUNTIME_HARDENING_ROLLBACK_RUNS must be between 1 and 100.' \
        'runtime hardening rollback repetition diagnostic'
    assert_status 64 'runtime hardening rejects excessive contention repetitions' \
        env RUNTIME_HARDENING_CONTENTION_RUNS=101 \
        "${SCRIPT_DIR}/tests/runtime-manager-hardening-integration.sh"
    assert_text_contains "${ASSERT_OUTPUT}" \
        'RUNTIME_HARDENING_CONTENTION_RUNS must be between 1 and 100.' \
        'runtime hardening contention repetition diagnostic'
}

test_static_upgrade_and_supply_chain_contracts() {
    local deb_upgrade_phase rpm_upgrade_phase

    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh" \
        'RPM upgrade passed:' 'RPM previous-to-current upgrade test'
    assert_file_contains "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
        'DEB upgrade passed with user-runtime preservation:' \
        'DEB previous-to-current upgrade test'
    assert_status 2 'DEB upgrade test requires two packages and two versions' \
        "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh"
    assert_status 2 'DEB upgrade test rejects a malformed version' \
        "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
        missing-old.deb missing-new.deb malformed-version "${EXPECTED_VERSION}"
    for deb_upgrade_phase in \
        parse_deb_upgrade_arguments \
        require_deb_upgrade_environment \
        initialize_deb_upgrade_paths \
        validate_deb_upgrade_initial_state \
        initialize_deb_upgrade_cleanup \
        assert_installed_deb_version \
        install_previous_deb \
        upgrade_deb_package \
        remove_upgraded_deb; do
        assert_file_contains \
            "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
            "${deb_upgrade_phase}() {" \
            "DEB upgrade phase ${deb_upgrade_phase}"
    done
    assert_status 2 'RPM upgrade test requires two packages and two versions' \
        "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh"
    assert_status 2 'RPM upgrade test rejects a malformed version' \
        "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh" \
        missing-old.rpm missing-new.rpm malformed-version "${EXPECTED_VERSION}"
    for rpm_upgrade_phase in \
        parse_rpm_upgrade_arguments \
        require_rpm_upgrade_environment \
        initialize_rpm_upgrade_paths \
        validate_rpm_upgrade_initial_state \
        initialize_rpm_upgrade_cleanup \
        assert_installed_rpm_version \
        install_previous_rpm \
        upgrade_rpm_package \
        remove_upgraded_rpm; do
        assert_file_contains \
            "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh" \
            "${rpm_upgrade_phase}() {" \
            "RPM upgrade phase ${rpm_upgrade_phase}"
    done

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

    assert_file_contains "${SCRIPT_DIR}/tests/lib/package-runtime-preservation.sh" \
        'runtime_tree_snapshot() {' \
        'shared package-upgrade helper snapshots the complete managed-runtime tree'
    assert_file_contains "${SCRIPT_DIR}/packaging/rpm/test-package-upgrade.sh" \
        "source \"\${PROJECT_DIR}/tests/lib/package-runtime-preservation.sh\"" \
        'RPM upgrade reuses the shared runtime-preservation helper'
    assert_file_contains "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
        "source \"\${PROJECT_DIR}/tests/lib/package-runtime-preservation.sh\"" \
        'DEB upgrade reuses the shared runtime-preservation helper'

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
        "assert_runtime_preserved 'final DEB package removal'" \
        'DEB final package removal preserves managed user runtime data'
    assert_file_contains "${SCRIPT_DIR}/packaging/deb/test-package-upgrade.sh" \
        "assert_runtime_preserved 'DEB remove-to-purge transition'" \
        'DEB remove-to-purge transition preserves managed user runtime data'

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

    assert_file_contains "${SCRIPT_DIR}/tests/lib/package-runtime-preservation.sh" \
        'refusing to clean package runtime probe through unsafe runtime root' \
        'shared package-runtime cleanup refuses an unsafe runtime root'

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
}

main() {
    trap cleanup_static_test EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    assert_forbidden_source_name_absent
    test_static_tooling_contracts
    test_static_shell_interface_contracts
    test_static_release_contracts
    test_static_cleanup_and_qualification_contracts
    test_static_packaging_signing_contracts
    test_static_application_contracts
    test_static_package_contracts
    test_static_runtime_regression_contracts
    test_static_upgrade_and_supply_chain_contracts
    printf '%s\n' 'Static tests passed.'
}

main "$@"
