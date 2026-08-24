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

Set REQUIRE_EXTENDED_QUALIFICATION=true for the final 2.2.0 release so the
new qualification.yml workflow is also required on the exact release SHA.
EOF_USAGE
}

cleanup() {
    trap - EXIT HUP INT TERM
    if [[ -n ${WORK_DIR} ]]; then
        rm -rf -- "${WORK_DIR}" || true
    fi
}

select_successful_run_for_sha() {
    set -e
    local runs_json=$1
    local expected_sha=$2

    jq -c --arg sha "${expected_sha}" '
        [
            .[]
            | select(
                .headSha == $sha and
                .status == "completed" and
                .conclusion == "success"
            )
        ][0] // empty
    ' <<<"${runs_json}"
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
    local runs_json
    local run_json

    runs_json=$(gh run list -R "${repo}" \
        --workflow "${workflow}" \
        --limit 100 \
        --json databaseId,workflowName,event,status,conclusion,headSha,createdAt,url)
    run_json=$(select_successful_run_for_sha "${runs_json}" "${expected_sha}")
    if [[ -z ${run_json} ]]; then
        printf 'FAIL: no successful %s run found for source SHA %s.\n' \
            "${workflow}" "${expected_sha}" >&2
        return 65
    fi

    printf '%s\n' "${run_json}"
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

main() {
    local tag=${1:-}
    local expected_sha=${2:-}
    local report_file=${3:-}
    local max_schedule_age_days=${MAX_SCHEDULE_AGE_DAYS:-${DEFAULT_MAX_SCHEDULE_AGE_DAYS}}
    local require_extended=${REQUIRE_EXTENDED_QUALIFICATION:-false}
    local command_name
    local repo
    local tag_sha
    local release_json
    local release_tag
    local release_immutable
    local release_url
    local release_published_at
    local public_dir
    local inventory_file
    local actual_inventory_file
    local asset_name
    local signer_workflow
    local release_run
    local shell_run
    local packages_run
    local real_tools_exact_run
    local stress_run
    local qualification_run=''
    local real_tools_runs_json
    local real_tools_run
    local shfmt_runs_json
    local shfmt_run
    local report_dir
    local verification_date
    local release_run_id
    local release_run_url
    local shell_run_id
    local shell_run_url
    local packages_run_id
    local packages_run_url
    local real_tools_exact_run_id
    local real_tools_exact_run_url
    local stress_run_id
    local stress_run_url
    local qualification_run_id=''
    local qualification_run_url=''
    local scheduled_real_tools_id
    local scheduled_real_tools_created
    local scheduled_real_tools_url
    local scheduled_shfmt_id
    local scheduled_shfmt_created
    local scheduled_shfmt_url

    if [[ ${tag} == -h || ${tag} == --help ]]; then
        usage
        return 0
    fi
    if [[ ! ${tag} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        usage >&2
        fail_qualification 'TAG must be an exact semantic-version tag such as v2.1.35.'
    fi
    if [[ ! ${expected_sha} =~ ^[0-9a-f]{40}$ ]]; then
        fail_qualification 'EXPECTED_SHA must be a lowercase 40-character Git SHA.'
    fi
    if [[ ! ${max_schedule_age_days} =~ ^[1-9][0-9]*$ ]]; then
        fail_qualification 'MAX_SCHEDULE_AGE_DAYS must be a positive integer.'
    fi
    case ${require_extended} in
        true | false) ;;
        *) fail_qualification 'REQUIRE_EXTENDED_QUALIFICATION must be true or false.' ;;
    esac

    for command_name in cat cmp date diff dirname find gh git grep jq mktemp sha256sum sort wc; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            fail_qualification "required command is absent: ${command_name}."
        fi
    done

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    cd -- "${PROJECT_DIR}"
    WORK_DIR=$(mktemp -d)
    public_dir="${WORK_DIR}/public"
    inventory_file="${WORK_DIR}/expected-inventory.txt"
    actual_inventory_file="${WORK_DIR}/downloaded-inventory.txt"
    mkdir -p -- "${public_dir}"

    repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
    if [[ ! ${repo} =~ ^[^/]+/[^/]+$ ]]; then
        fail_qualification 'unable to resolve GitHub repository nameWithOwner.'
    fi

    if ! tag_sha=$(git rev-parse "${tag}^{commit}"); then
        fail_qualification "unable to resolve local tag ${tag}."
    fi
    if [[ ${tag_sha} != "${expected_sha}" ]]; then
        fail_qualification \
            "tag ${tag} resolves to ${tag_sha}, expected ${expected_sha}."
    fi

    release_json=$(gh release view "${tag}" -R "${repo}" \
        --json tagName,isImmutable,assets,url,publishedAt,targetCommitish)
    release_tag=$(jq -r '.tagName' <<<"${release_json}")
    release_immutable=$(jq -r '.isImmutable' <<<"${release_json}")
    release_url=$(jq -r '.url' <<<"${release_json}")
    release_published_at=$(jq -r '.publishedAt' <<<"${release_json}")
    if [[ ${release_tag} != "${tag}" ]]; then
        fail_qualification 'GitHub release tag does not match the requested tag.'
    fi
    if [[ ${release_immutable} != true ]]; then
        fail_qualification 'GitHub release is not immutable.'
    fi

    jq -r '.assets[].name' <<<"${release_json}" | LC_ALL=C sort >"${inventory_file}"
    if [[ ! -s ${inventory_file} ]]; then
        fail_qualification 'GitHub release asset inventory is empty.'
    fi
    assert_asset_inventory "${inventory_file}"

    gh release download "${tag}" -R "${repo}" --dir "${public_dir}"
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
        gh release verify-asset "${tag}" "${public_dir}/${asset_name}" -R "${repo}"
        gh attestation verify "${public_dir}/${asset_name}" \
            --repo "${repo}" \
            --signer-workflow "${signer_workflow}" \
            --source-digest "${expected_sha}"
    done <"${inventory_file}"

    release_run=$(successful_workflow_run_for_sha "${repo}" release.yml "${expected_sha}")
    shell_run=$(successful_workflow_run_for_sha "${repo}" shell.yml "${expected_sha}")
    packages_run=$(successful_workflow_run_for_sha "${repo}" packages.yml "${expected_sha}")
    real_tools_exact_run=$(successful_workflow_run_for_sha "${repo}" real-tools.yml "${expected_sha}")
    stress_run=$(successful_workflow_run_for_sha "${repo}" stress.yml "${expected_sha}")
    if [[ ${require_extended} == true ]]; then
        qualification_run=$(successful_workflow_run_for_sha \
            "${repo}" qualification.yml "${expected_sha}")
    fi

    real_tools_runs_json=$(gh run list -R "${repo}" \
        --workflow real-tools.yml \
        --event schedule \
        --limit 20 \
        --json databaseId,workflowName,event,status,conclusion,headSha,createdAt,url)
    real_tools_run=$(select_latest_successful_schedule "${real_tools_runs_json}")
    assert_schedule_fresh "${real_tools_run}" real-tools.yml "${max_schedule_age_days}"

    shfmt_runs_json=$(gh run list -R "${repo}" \
        --workflow shfmt-update.yml \
        --event schedule \
        --limit 20 \
        --json databaseId,workflowName,event,status,conclusion,headSha,createdAt,url)
    shfmt_run=$(select_latest_successful_schedule "${shfmt_runs_json}")
    assert_schedule_fresh "${shfmt_run}" shfmt-update.yml "${max_schedule_age_days}"

    if [[ -z ${report_file} ]]; then
        report_file="${PROJECT_DIR}/qualification-evidence/release-${tag}.md"
    elif [[ ${report_file} != /* ]]; then
        report_file="${PROJECT_DIR}/${report_file}"
    fi
    report_dir=$(dirname -- "${report_file}")
    mkdir -p -- "${report_dir}"
    verification_date=$(date --iso-8601=seconds)

    release_run_id=$(jq -r '.databaseId' <<<"${release_run}")
    release_run_url=$(jq -r '.url' <<<"${release_run}")
    shell_run_id=$(jq -r '.databaseId' <<<"${shell_run}")
    shell_run_url=$(jq -r '.url' <<<"${shell_run}")
    packages_run_id=$(jq -r '.databaseId' <<<"${packages_run}")
    packages_run_url=$(jq -r '.url' <<<"${packages_run}")
    real_tools_exact_run_id=$(jq -r '.databaseId' <<<"${real_tools_exact_run}")
    real_tools_exact_run_url=$(jq -r '.url' <<<"${real_tools_exact_run}")
    stress_run_id=$(jq -r '.databaseId' <<<"${stress_run}")
    stress_run_url=$(jq -r '.url' <<<"${stress_run}")
    if [[ -n ${qualification_run} ]]; then
        qualification_run_id=$(jq -r '.databaseId' <<<"${qualification_run}")
        qualification_run_url=$(jq -r '.url' <<<"${qualification_run}")
    fi
    scheduled_real_tools_id=$(jq -r '.databaseId' <<<"${real_tools_run}")
    scheduled_real_tools_created=$(jq -r '.createdAt' <<<"${real_tools_run}")
    scheduled_real_tools_url=$(jq -r '.url' <<<"${real_tools_run}")
    scheduled_shfmt_id=$(jq -r '.databaseId' <<<"${shfmt_run}")
    scheduled_shfmt_created=$(jq -r '.createdAt' <<<"${shfmt_run}")
    scheduled_shfmt_url=$(jq -r '.url' <<<"${shfmt_run}")

    {
        printf '# Release qualification evidence — %s\n\n' "${tag}"
        printf -- "- Verification date: \`%s\`\n" "${verification_date}"
        printf -- "- Repository: \`%s\`\n" "${repo}"
        printf -- "- Source SHA: \`%s\`\n" "${expected_sha}"
        printf -- '- Release URL: %s\n' "${release_url}"
        printf -- "- Immutable: \`%s\`\n" "${release_immutable}"
        printf -- "- Published at: \`%s\`\n\n" "${release_published_at}"
        printf '## Exact-SHA workflow runs\n\n'
        printf -- "- release.yml: \`%s\` — %s\n" \
            "${release_run_id}" "${release_run_url}"
        printf -- "- shell.yml: \`%s\` — %s\n" \
            "${shell_run_id}" "${shell_run_url}"
        printf -- "- packages.yml: \`%s\` — %s\n" \
            "${packages_run_id}" "${packages_run_url}"
        printf -- "- real-tools.yml: \`%s\` — %s\n" \
            "${real_tools_exact_run_id}" "${real_tools_exact_run_url}"
        printf -- "- stress.yml: \`%s\` — %s\n" \
            "${stress_run_id}" "${stress_run_url}"
        if [[ -n ${qualification_run} ]]; then
            printf -- "- qualification.yml: \`%s\` — %s\n" \
                "${qualification_run_id}" "${qualification_run_url}"
        fi
        printf '\n## Scheduled runs\n\n'
        printf -- "- Current-stable real-tools: \`%s\` — \`%s\` — %s\n" \
            "${scheduled_real_tools_id}" \
            "${scheduled_real_tools_created}" \
            "${scheduled_real_tools_url}"
        printf -- "- shfmt updater: \`%s\` — \`%s\` — %s\n\n" \
            "${scheduled_shfmt_id}" \
            "${scheduled_shfmt_created}" \
            "${scheduled_shfmt_url}"
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

main "$@"
