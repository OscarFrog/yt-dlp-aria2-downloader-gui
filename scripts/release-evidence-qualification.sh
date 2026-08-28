#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : scripts/release-evidence-qualification.sh
# Purpose     : Verify published release identity and recent scheduled-run evidence.
# ==============================================================================

set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_DIR
readonly DEFAULT_MAX_SCHEDULE_AGE_DAYS=14

WORK_DIR=''

fail_qualification() {
    printf 'FAIL: %s\n' "$1" >&2
    return 65
}

usage() {
    cat <<'EOF_USAGE'
Usage: scripts/release-evidence-qualification.sh TAG EXPECTED_SHA [REPORT_FILE]

Example:
  scripts/release-evidence-qualification.sh \
    v2.1.35 \
    4d94f95a3ab170cc25b27885f90325b70ba3bd40 \
    qualification-evidence/release-v2.1.35.md

The script verifies the public release assets, SHA256SUMS, GitHub artifact
attestations, source digest, signer workflow, exact-SHA validation workflow
runs, and recent successful scheduled runs for real-tools.yml and
shfmt-update.yml.

Environment controls:
  MAX_SCHEDULE_AGE_DAYS=14
  REQUIRE_EXTENDED_QUALIFICATION=false

Set REQUIRE_EXTENDED_QUALIFICATION=true for final release qualification when
qualification.yml must also be required on the exact release SHA.
EOF_USAGE
}

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${WORK_DIR} ]]; then
        rm -rf -- "${WORK_DIR}" || true
    fi
}

# Retry read-only GitHub operations with a small total budget. Captured commands
# publish stdout only from a successful attempt so partial JSON can never be
# mistaken for evidence.
retry_qualification_capture() {
    local description=$1
    shift
    local attempt=0
    local output=''

    for attempt in 1 2 3; do
        if output=$("$@"); then
            printf '%s' "${output}"
            return 0
        fi
        if ((attempt < 3)); then
            printf 'Warning: %s; retrying (%d/3).\n' \
                "${description}" "$((attempt + 1))" >&2
            sleep "${attempt}"
        fi
    done
    fail_qualification "${description} after three attempts."
}

retry_qualification_command() {
    local description=$1
    shift
    local attempt=0

    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        if ((attempt < 3)); then
            printf 'Warning: %s; retrying (%d/3).\n' \
                "${description}" "$((attempt + 1))" >&2
            sleep "${attempt}"
        fi
    done
    fail_qualification "${description} after three attempts."
}

select_latest_successful_schedule() {
    set -e
    local runs_json=$1

    jq -c '
        [
            .[]
            | select(
                .event == "schedule" and
                .status == "completed" and
                .conclusion == "success"
            )
        ][0] // empty
    ' <<<"${runs_json}"
}

successful_workflow_run_for_sha() {
    set -e
    local repo=$1
    local workflow=$2
    local expected_sha=$3
    local page=1
    local page_count=0
    local page_json=''
    local run_json=''

    while ((page < 1000)); do
        page_json=$(retry_qualification_capture \
            "unable to list ${workflow} runs page ${page}" \
            gh api \
            "repos/${repo}/actions/workflows/${workflow}/runs?per_page=100&page=${page}")
        run_json=$(jq -c --arg sha "${expected_sha}" '
            [
                .workflow_runs[]
                | select(
                    .head_sha == $sha and
                    .status == "completed" and
                    .conclusion == "success"
                )
                | {
                    databaseId: .id,
                    workflowName: .name,
                    event: .event,
                    status: .status,
                    conclusion: .conclusion,
                    headSha: .head_sha,
                    createdAt: .created_at,
                    url: .html_url
                }
            ][0] // empty
        ' <<<"${page_json}")
        if [[ -n ${run_json} ]]; then
            printf '%s\n' "${run_json}"
            return 0
        fi

        page_count=$(jq '.workflow_runs | length' <<<"${page_json}")
        [[ ${page_count} =~ ^[0-9]+$ ]] \
            || fail_qualification "invalid ${workflow} run-page size."
        ((page_count == 100)) || break
        page=$((page + 1))
    done

    printf 'FAIL: no successful %s run found for source SHA %s.\n' \
        "${workflow}" "${expected_sha}" >&2
    return 65
}

assert_schedule_fresh() {
    local run_json=$1
    local workflow=$2
    local max_age_days=$3
    local created_at
    local created_epoch
    local now_epoch
    local age_seconds
    local max_age_seconds

    if [[ -z ${run_json} ]]; then
        fail_qualification "no successful scheduled run found for ${workflow}."
    fi

    created_at=$(jq -r '.createdAt' <<<"${run_json}")
    if ! created_epoch=$(date -d "${created_at}" +%s); then
        fail_qualification "invalid createdAt timestamp for ${workflow}: ${created_at}."
    fi
    now_epoch=$(date +%s)
    age_seconds=$((now_epoch - created_epoch))
    max_age_seconds=$((max_age_days * 24 * 60 * 60))

    if ((age_seconds < 0 || age_seconds > max_age_seconds)); then
        fail_qualification \
            "latest successful scheduled run for ${workflow} is older than ${max_age_days} days."
    fi
}

assert_asset_inventory() {
    local inventory_file=$1
    local count_zip
    local count_rpm
    local count_deb
    local count_total

    if ! grep -Fxq -- 'SHA256SUMS' "${inventory_file}"; then
        fail_qualification 'release has no SHA256SUMS asset.'
    fi
    if ! grep -Fxq -- 'install-fedora.sh' "${inventory_file}"; then
        fail_qualification 'release has no install-fedora.sh asset.'
    fi
    if ! grep -Fxq -- 'RPM-GPG-KEY-OscarFrog' "${inventory_file}"; then
        fail_qualification 'release has no pinned RPM public key asset.'
    fi

    count_zip=$(grep -Ec '\.zip$' "${inventory_file}" || true)
    count_rpm=$(grep -Ec '\.rpm$' "${inventory_file}" || true)
    count_deb=$(grep -Ec '\.deb$' "${inventory_file}" || true)
    count_total=$(wc -l <"${inventory_file}")

    if [[ ${count_zip} != 1 || ${count_rpm} != 1 || ${count_deb} != 1 || ${count_total} != 6 ]]; then
        fail_qualification \
            "release asset inventory is unexpected: total=${count_total}, zip=${count_zip}, rpm=${count_rpm}, deb=${count_deb}."
    fi
}

parse_qualification_arguments() {
    local tag_output_variable=$1
    local sha_output_variable=$2
    local report_output_variable=$3
    local age_output_variable=$4
    local extended_output_variable=$5
    local parsed_tag=${6:-}
    local parsed_sha=${7:-}
    local parsed_report=${8:-}
    local parsed_age=${MAX_SCHEDULE_AGE_DAYS:-${DEFAULT_MAX_SCHEDULE_AGE_DAYS}}
    local parsed_extended=${REQUIRE_EXTENDED_QUALIFICATION:-false}

    if [[ ${parsed_tag} == -h || ${parsed_tag} == --help ]]; then
        usage
        exit 0
    fi
    if [[ ! ${parsed_tag} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        usage >&2
        fail_qualification 'TAG must be an exact semantic-version tag such as v2.1.35.'
    fi
    if [[ ! ${parsed_sha} =~ ^[0-9a-f]{40}$ ]]; then
        fail_qualification 'EXPECTED_SHA must be a lowercase 40-character Git SHA.'
    fi
    if [[ ! ${parsed_age} =~ ^[1-9][0-9]*$ ]]; then
        fail_qualification 'MAX_SCHEDULE_AGE_DAYS must be a positive integer.'
    fi
    case ${parsed_extended} in
        true | false) ;;
        *) fail_qualification 'REQUIRE_EXTENDED_QUALIFICATION must be true or false.' ;;
    esac

    printf -v "${tag_output_variable}" '%s' "${parsed_tag}"
    printf -v "${sha_output_variable}" '%s' "${parsed_sha}"
    printf -v "${report_output_variable}" '%s' "${parsed_report}"
    printf -v "${age_output_variable}" '%s' "${parsed_age}"
    printf -v "${extended_output_variable}" '%s' "${parsed_extended}"
}

require_qualification_commands() {
    local command_name=''

    for command_name in cat cmp date diff dirname find gh git grep jq mkdir mktemp rm sha256sum sleep sort wc; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            fail_qualification "required command is absent: ${command_name}."
        fi
    done
}

initialize_qualification_workspace() {
    local public_output_variable=$1
    local inventory_output_variable=$2
    local actual_inventory_output_variable=$3
    local workspace_public_dir=''
    local workspace_inventory_file=''
    local workspace_actual_inventory_file=''

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    cd -- "${PROJECT_DIR}"
    WORK_DIR=$(mktemp -d)
    workspace_public_dir="${WORK_DIR}/public"
    workspace_inventory_file="${WORK_DIR}/expected-inventory.txt"
    workspace_actual_inventory_file="${WORK_DIR}/downloaded-inventory.txt"
    mkdir -p -- "${workspace_public_dir}"

    printf -v "${public_output_variable}" '%s' "${workspace_public_dir}"
    printf -v "${inventory_output_variable}" '%s' "${workspace_inventory_file}"
    printf -v "${actual_inventory_output_variable}" '%s' "${workspace_actual_inventory_file}"
}

resolve_release_identity() {
    local tag=$1
    local expected_sha=$2
    local output_variable=$3
    local resolved_repo=''
    local tag_sha=''

    resolved_repo=$(retry_qualification_capture \
        'unable to query the GitHub repository identity' \
        gh repo view --json nameWithOwner --jq '.nameWithOwner')
    if [[ ! ${resolved_repo} =~ ^[^/]+/[^/]+$ ]]; then
        fail_qualification 'unable to resolve GitHub repository nameWithOwner.'
    fi

    if ! tag_sha=$(git rev-parse "${tag}^{commit}"); then
        fail_qualification "unable to resolve local tag ${tag}."
    fi
    if [[ ${tag_sha} != "${expected_sha}" ]]; then
        fail_qualification \
            "tag ${tag} resolves to ${tag_sha}, expected ${expected_sha}."
    fi
    printf -v "${output_variable}" '%s' "${resolved_repo}"
}

download_and_verify_release_assets() {
    local tag=$1
    local expected_sha=$2
    local repo=$3
    local public_dir=$4
    local inventory_file=$5
    local actual_inventory_file=$6
    local url_output_variable=$7
    local immutable_output_variable=$8
    local published_output_variable=$9
    local release_json=''
    local release_tag=''
    local resolved_release_immutable=''
    local resolved_release_url=''
    local resolved_release_published_at=''
    local asset_name=''
    local signer_workflow=''

    release_json=$(retry_qualification_capture \
        'unable to query the public release' \
        gh release view "${tag}" -R "${repo}" \
        --json tagName,isImmutable,assets,url,publishedAt)
    release_tag=$(jq -r '.tagName' <<<"${release_json}")
    resolved_release_immutable=$(jq -r '.isImmutable' <<<"${release_json}")
    resolved_release_url=$(jq -r '.url' <<<"${release_json}")
    resolved_release_published_at=$(jq -r '.publishedAt' <<<"${release_json}")
    if [[ ${release_tag} != "${tag}" ]]; then
        fail_qualification 'GitHub release tag does not match the requested tag.'
    fi
    if [[ ${resolved_release_immutable} != true ]]; then
        fail_qualification 'GitHub release is not immutable.'
    fi

    jq -r '.assets[].name' <<<"${release_json}" | LC_ALL=C sort >"${inventory_file}"
    if [[ ! -s ${inventory_file} ]]; then
        fail_qualification 'GitHub release asset inventory is empty.'
    fi
    assert_asset_inventory "${inventory_file}"

    retry_qualification_command \
        'unable to download the public release assets' \
        gh release download "${tag}" -R "${repo}" \
        --dir "${public_dir}" --clobber
    find "${public_dir}" -maxdepth 1 -type f -printf '%f\n' \
        | LC_ALL=C sort >"${actual_inventory_file}"
    if ! cmp -s -- "${inventory_file}" "${actual_inventory_file}"; then
        diff -u -- "${inventory_file}" "${actual_inventory_file}" >&2 || true
        fail_qualification 'downloaded asset inventory differs from the public release inventory.'
    fi

    (
        cd -- "${public_dir}"
        sha256sum --check SHA256SUMS
    )

    signer_workflow="${repo}/.github/workflows/release.yml"
    while IFS= read -r asset_name; do
        [[ -n ${asset_name} ]] || continue
        retry_qualification_command \
            "unable to verify public asset ${asset_name}" \
            gh release verify-asset "${tag}" \
            "${public_dir}/${asset_name}" -R "${repo}"
        retry_qualification_command \
            "unable to verify attestation for ${asset_name}" \
            gh attestation verify "${public_dir}/${asset_name}" \
            --repo "${repo}" \
            --signer-workflow "${signer_workflow}" \
            --source-digest "${expected_sha}"
    done <"${inventory_file}"

    printf -v "${url_output_variable}" '%s' "${resolved_release_url}"
    printf -v "${immutable_output_variable}" '%s' "${resolved_release_immutable}"
    printf -v "${published_output_variable}" '%s' "${resolved_release_published_at}"
}

collect_exact_sha_runs() {
    local repo=$1
    local expected_sha=$2
    local require_extended=$3
    local release_output_variable=$4
    local shell_output_variable=$5
    local packages_output_variable=$6
    local real_tools_output_variable=$7
    local stress_output_variable=$8
    local qualification_output_variable=$9
    local release_result=''
    local shell_result=''
    local packages_result=''
    local real_tools_result=''
    local stress_result=''
    local qualification_result=''

    release_result=$(successful_workflow_run_for_sha "${repo}" release.yml "${expected_sha}")
    shell_result=$(successful_workflow_run_for_sha "${repo}" shell.yml "${expected_sha}")
    packages_result=$(successful_workflow_run_for_sha "${repo}" packages.yml "${expected_sha}")
    real_tools_result=$(successful_workflow_run_for_sha "${repo}" real-tools.yml "${expected_sha}")
    stress_result=$(successful_workflow_run_for_sha "${repo}" stress.yml "${expected_sha}")
    if [[ ${require_extended} == true ]]; then
        qualification_result=$(successful_workflow_run_for_sha \
            "${repo}" qualification.yml "${expected_sha}")
    fi

    printf -v "${release_output_variable}" '%s' "${release_result}"
    printf -v "${shell_output_variable}" '%s' "${shell_result}"
    printf -v "${packages_output_variable}" '%s' "${packages_result}"
    printf -v "${real_tools_output_variable}" '%s' "${real_tools_result}"
    printf -v "${stress_output_variable}" '%s' "${stress_result}"
    printf -v "${qualification_output_variable}" '%s' "${qualification_result}"
}

collect_scheduled_runs() {
    local repo=$1
    local max_schedule_age_days=$2
    local real_tools_output_variable=$3
    local shfmt_output_variable=$4
    local real_tools_runs_json=''
    local real_tools_result=''
    local shfmt_runs_json=''
    local shfmt_result=''

    real_tools_runs_json=$(retry_qualification_capture \
        'unable to list scheduled real-tools runs' \
        gh run list -R "${repo}" \
        --workflow real-tools.yml \
        --event schedule \
        --limit 20 \
        --json databaseId,workflowName,event,status,conclusion,headSha,createdAt,url)
    real_tools_result=$(select_latest_successful_schedule "${real_tools_runs_json}")
    assert_schedule_fresh "${real_tools_result}" real-tools.yml "${max_schedule_age_days}"

    shfmt_runs_json=$(retry_qualification_capture \
        'unable to list scheduled shfmt runs' \
        gh run list -R "${repo}" \
        --workflow shfmt-update.yml \
        --event schedule \
        --limit 20 \
        --json databaseId,workflowName,event,status,conclusion,headSha,createdAt,url)
    shfmt_result=$(select_latest_successful_schedule "${shfmt_runs_json}")
    assert_schedule_fresh "${shfmt_result}" shfmt-update.yml "${max_schedule_age_days}"

    printf -v "${real_tools_output_variable}" '%s' "${real_tools_result}"
    printf -v "${shfmt_output_variable}" '%s' "${shfmt_result}"
}

resolve_qualification_report() {
    local requested_report=$1
    local tag=$2
    local output_variable=$3
    local resolved_report=${requested_report}
    local report_dir=''

    if [[ -z ${resolved_report} ]]; then
        resolved_report="${PROJECT_DIR}/qualification-evidence/release-${tag}.md"
    elif [[ ${resolved_report} != /* ]]; then
        resolved_report="${PROJECT_DIR}/${resolved_report}"
    fi
    report_dir=$(dirname -- "${resolved_report}")
    mkdir -p -- "${report_dir}"
    printf -v "${output_variable}" '%s' "${resolved_report}"
}

write_exact_sha_run_line() {
    local label=$1
    local run=$2
    local run_id run_url

    run_id=$(jq -r '.databaseId' <<<"${run}")
    run_url=$(jq -r '.url' <<<"${run}")
    printf -- "- %s: \`%s\` — %s\n" "${label}" "${run_id}" "${run_url}"
}

write_scheduled_run_line() {
    local label=$1
    local run=$2
    local run_id run_created run_url

    run_id=$(jq -r '.databaseId' <<<"${run}")
    run_created=$(jq -r '.createdAt' <<<"${run}")
    run_url=$(jq -r '.url' <<<"${run}")
    printf -- "- %s: \`%s\` — \`%s\` — %s\n" \
        "${label}" "${run_id}" "${run_created}" "${run_url}"
}

write_qualification_report() {
    local tag=$1
    local expected_sha=$2
    local repo=$3
    local release_url=$4
    local release_immutable=$5
    local release_published_at=$6
    local inventory_file=$7
    local public_dir=$8
    local report_file=$9
    local release_run=${10}
    local shell_run=${11}
    local packages_run=${12}
    local real_tools_exact_run=${13}
    local stress_run=${14}
    local qualification_run=${15}
    local real_tools_run=${16}
    local shfmt_run=${17}
    local verification_date=''

    verification_date=$(date --iso-8601=seconds)

    {
        printf '# Release qualification evidence — %s\n\n' "${tag}"
        printf -- "- Verification date: \`%s\`\n" "${verification_date}"
        printf -- "- Repository: \`%s\`\n" "${repo}"
        printf -- "- Source SHA: \`%s\`\n" "${expected_sha}"
        printf -- '- Release URL: %s\n' "${release_url}"
        printf -- "- Immutable: \`%s\`\n" "${release_immutable}"
        printf -- "- Published at: \`%s\`\n\n" "${release_published_at}"
        printf '## Exact-SHA workflow runs\n\n'
        write_exact_sha_run_line release.yml "${release_run}"
        write_exact_sha_run_line shell.yml "${shell_run}"
        write_exact_sha_run_line packages.yml "${packages_run}"
        write_exact_sha_run_line real-tools.yml "${real_tools_exact_run}"
        write_exact_sha_run_line stress.yml "${stress_run}"
        if [[ -n ${qualification_run} ]]; then
            write_exact_sha_run_line qualification.yml "${qualification_run}"
        fi
        printf '\n## Scheduled runs\n\n'
        write_scheduled_run_line 'Current-stable real-tools' "${real_tools_run}"
        write_scheduled_run_line 'shfmt updater' "${shfmt_run}"
        printf '\n'
        printf "## Asset inventory\n\n\`\`\`text\n"
        cat -- "${inventory_file}"
        printf "\`\`\`\n\n## SHA256SUMS\n\n\`\`\`text\n"
        cat -- "${public_dir}/SHA256SUMS"
        printf "\`\`\`\n\n"
        printf '%s\n' \
            'All downloaded assets matched the public inventory, SHA256SUMS passed,' \
            'GitHub release verify-asset passed, and GitHub attestations verified' \
            'against the release workflow and exact source digest.'
    } >"${report_file}"

    printf 'Release evidence qualification passed: %s\n' "${report_file}"
}

main() {
    local tag='' expected_sha='' report_file=''
    local max_schedule_age_days='' require_extended=''
    local public_dir='' inventory_file='' actual_inventory_file=''
    local repo='' release_url='' release_immutable='' release_published_at=''
    local release_run='' shell_run='' packages_run=''
    local real_tools_exact_run='' stress_run='' qualification_run=''
    local real_tools_run='' shfmt_run=''

    parse_qualification_arguments \
        tag expected_sha report_file max_schedule_age_days require_extended "$@"
    require_qualification_commands
    initialize_qualification_workspace \
        public_dir inventory_file actual_inventory_file
    resolve_release_identity "${tag}" "${expected_sha}" repo
    download_and_verify_release_assets \
        "${tag}" "${expected_sha}" "${repo}" \
        "${public_dir}" "${inventory_file}" "${actual_inventory_file}" \
        release_url release_immutable release_published_at
    collect_exact_sha_runs \
        "${repo}" "${expected_sha}" "${require_extended}" \
        release_run shell_run packages_run real_tools_exact_run stress_run qualification_run
    collect_scheduled_runs \
        "${repo}" "${max_schedule_age_days}" real_tools_run shfmt_run
    resolve_qualification_report "${report_file}" "${tag}" report_file
    write_qualification_report \
        "${tag}" "${expected_sha}" "${repo}" \
        "${release_url}" "${release_immutable}" "${release_published_at}" \
        "${inventory_file}" "${public_dir}" "${report_file}" \
        "${release_run}" "${shell_run}" "${packages_run}" \
        "${real_tools_exact_run}" "${stress_run}" "${qualification_run}" \
        "${real_tools_run}" "${shfmt_run}"
}

main "$@"
