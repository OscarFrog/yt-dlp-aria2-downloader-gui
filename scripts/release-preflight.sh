#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : scripts/release-preflight.sh
# Purpose     : Validate maintainer-side release and signing controls before publication.
# ==============================================================================

# Rationale: some repository and environment controls cannot be proven from
# workflow YAML alone and therefore require maintainer-side verification.

set -Eeuo pipefail
umask 077

readonly DEFAULT_REPOSITORY='OscarFrog/yt-dlp-aria2-downloader-gui'
readonly SIGNING_ENVIRONMENT='rpm-signing'
readonly API_VERSION='2026-03-10'
readonly RPM_SIGNING_FINGERPRINT='7B54065FE061E78ED2C96252E3BE996196ABEA7F'
readonly RPM_SIGNING_SUBKEY_FINGERPRINT='1F5B769CE48A08AAC0A7D9DDECC9894B41830245'
readonly RPM_SIGNING_KEY='packaging/keys/RPM-GPG-KEY-OscarFrog'
readonly RELEASE_TAG_SIGNING_FINGERPRINT='43E5361414863738F0324F2B047B26057E612CDC'

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 65
}

usage() {
    cat >&2 <<'USAGE'
Usage:
  scripts/release-preflight.sh \
    --confirm-admin-bypass-disabled \
    --confirm-tag-policy \
    --confirm-single-maintainer-self-review \
    vX.Y.Z

The explicit confirmations cover GitHub Environment settings and operating
choices that must be acknowledged by the maintainer:
- administrator deployment-protection bypass is disabled;
- the selected deployment policy named v* is configured as a TAG policy;
- this repository is intentionally operated by one maintainer, so the sole
  required reviewer may approve the deployment they initiated.
USAGE
}

api_capture() {
    local description=$1
    shift
    local output=''

    if ! output=$(
        gh api \
            -H 'Accept: application/vnd.github+json' \
            -H "X-GitHub-Api-Version: ${API_VERSION}" \
            "$@"
    ); then
        fail "${description}"
    fi

    printf '%s' "${output}"
}

cleanup() {
    if [[ -n ${listing:-} ]]; then
        rm -f -- "${listing}" || true
    fi
    if [[ -n ${gpg_home:-} ]]; then
        rm -rf -- "${gpg_home}" || true
    fi
}

parse_preflight_arguments() {
    local output_variable=$1
    local confirm_admin_bypass=false
    local confirm_tag_policy=false
    local confirm_single_maintainer_self_review=false
    local parsed_release_tag=''
    shift

    while (($# > 1)); do
        case $1 in
            --confirm-admin-bypass-disabled)
                confirm_admin_bypass=true
                ;;
            --confirm-tag-policy)
                confirm_tag_policy=true
                ;;
            --confirm-single-maintainer-self-review)
                confirm_single_maintainer_self_review=true
                ;;
            *)
                usage
                exit 2
                ;;
        esac
        shift
    done

    (($# == 1)) || {
        usage
        exit 2
    }

    parsed_release_tag=$1
    [[ ${parsed_release_tag} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "invalid semantic release tag: ${parsed_release_tag}"
    [[ ${confirm_admin_bypass} == true ]] || {
        printf '%s\n' \
            'Error: confirm in GitHub Settings > Environments > rpm-signing that administrator bypass is disabled.' >&2
        usage
        exit 77
    }
    [[ ${confirm_tag_policy} == true ]] || {
        printf '%s\n' \
            'Error: confirm in GitHub Settings > Environments > rpm-signing that v* is configured as a TAG deployment policy.' >&2
        usage
        exit 77
    }
    [[ ${confirm_single_maintainer_self_review} == true ]] || {
        printf '%s\n' \
            'Error: explicitly confirm that this single-maintainer repository intentionally allows the sole reviewer to self-approve rpm-signing.' >&2
        usage
        exit 77
    }
    printf -v "${output_variable}" '%s' "${parsed_release_tag}"
}

require_preflight_commands() {
    local command_name=''

    for command_name in awk chmod date gh git gpg grep mktemp rm; do
        command -v -- "${command_name}" >/dev/null 2>&1 \
            || fail "required preflight command is absent: ${command_name}"
    done
}

resolve_preflight_repository() {
    local output_variable=$1
    local resolved_repository=${GH_REPO:-${DEFAULT_REPOSITORY}}
    local repo_root=''
    local physical_repo_root=''
    local current_dir=''

    [[ ${resolved_repository} =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] \
        || fail "invalid GH_REPO repository coordinate: ${resolved_repository}"

    if ! repo_root=$(git rev-parse --show-toplevel); then
        fail 'unable to resolve the repository root.'
    fi
    if ! physical_repo_root=$(cd -- "${repo_root}" && pwd -P); then
        fail 'unable to resolve the physical repository root.'
    fi
    if ! current_dir=$(pwd -P); then
        fail 'unable to resolve the current physical directory.'
    fi
    [[ ${current_dir} == "${physical_repo_root}" ]] || fail 'run the preflight from the repository root.'
    printf -v "${output_variable}" '%s' "${resolved_repository}"
}

verify_release_tag() {
    local release_tag=$1
    local output_variable=$2
    local head_commit=''
    local tag_commit=''
    local tag_verification=''
    local tag_primary_fingerprint=''

    head_commit=$(git rev-parse HEAD)
    tag_commit=$(git rev-parse "${release_tag}^{commit}") \
        || fail "unable to resolve local tag: ${release_tag}"
    [[ ${tag_commit} == "${head_commit}" ]] \
        || fail "release tag ${release_tag} does not resolve to current HEAD."

    if ! tag_verification=$(git verify-tag --raw "${release_tag}" 2>&1 >/dev/null); then
        fail "release tag is not a valid signed tag: ${release_tag}"
    fi
    tag_primary_fingerprint=$(
        awk '
            $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
                fingerprint = (NF >= 12 && $12 != "") ? $12 : $3
                print toupper(fingerprint)
            }
        ' <<<"${tag_verification}"
    )
    [[ -n ${tag_primary_fingerprint} &&
        ${tag_primary_fingerprint} != *$'\n'* ]] || fail "unable to determine the unique signer fingerprint for tag: ${release_tag}"
    [[ ${tag_primary_fingerprint} == "${RELEASE_TAG_SIGNING_FINGERPRINT}" ]] || fail "release tag signer is not authorized: ${tag_primary_fingerprint}"
    printf -v "${output_variable}" '%s' "${tag_commit}"
}

verify_release_tree_and_version() {
    local release_tag=$1
    local git_status=''
    local version_output=''
    local version=''

    git_status=$(git status --porcelain)
    [[ -z ${git_status} ]] \
        || fail 'working tree is not clean.'

    if ! version_output=$(./download-video.sh --version); then
        fail 'unable to query the project version.'
    fi
    if [[ ${version_output} =~ ^download-video\.sh[[:space:]]version[[:space:]]([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        version=${BASH_REMATCH[1]}
    else
        fail "unexpected project version output: ${version_output}"
    fi
    [[ ${release_tag} == "v${version}" ]] \
        || fail "release tag/version mismatch: tag=${release_tag} project=${version}"

    [[ -f ${RPM_SIGNING_KEY} && ! -L ${RPM_SIGNING_KEY} ]] \
        || fail "RPM signing public certificate is missing or unsafe: ${RPM_SIGNING_KEY}"
}

verify_immutable_releases() {
    local repository=$1
    local immutable=''

    immutable=$(
        api_capture \
            'unable to query Immutable Releases setting.' \
            "repos/${repository}/immutable-releases" \
            --jq '.enabled'
    )
    [[ ${immutable} == true ]] \
        || fail 'GitHub Immutable Releases are not enabled.'
}

verify_signing_environment() {
    local repository=$1
    local environment_endpoint="repos/${repository}/environments/${SIGNING_ENVIRONMENT}"
    local required_reviewer_rules=''
    local reviewer_count=''
    local reviewer_login=''
    local authenticated_login=''
    local prevent_self_review=''
    local custom_policies=''
    local deployment_policy_output=''
    local -a deployment_policies=()

    required_reviewer_rules=$(
        api_capture \
            'unable to query rpm-signing required reviewers.' \
            "${environment_endpoint}" \
            --jq '[.protection_rules[]? | select(.type == "required_reviewers")] | length'
    )
    [[ ${required_reviewer_rules} == 1 ]] \
        || fail "rpm-signing must have exactly one required-reviewers rule; found ${required_reviewer_rules}."

    reviewer_count=$(
        api_capture \
            'unable to query rpm-signing reviewer count.' \
            "${environment_endpoint}" \
            --jq '[.protection_rules[]? | select(.type == "required_reviewers")][0].reviewers | length'
    )
    [[ ${reviewer_count} == 1 ]] \
        || fail "single-maintainer rpm-signing must have exactly one reviewer; found ${reviewer_count}."

    reviewer_login=$(
        api_capture \
            'unable to query rpm-signing reviewer identity.' \
            "${environment_endpoint}" \
            --jq '[.protection_rules[]? | select(.type == "required_reviewers")][0].reviewers[0].reviewer.login // ""'
    )
    [[ -n ${reviewer_login} ]] \
        || fail 'unable to determine the sole rpm-signing reviewer login.'

    authenticated_login=$(
        api_capture \
            'unable to query the authenticated GitHub user.' \
            user \
            --jq '.login'
    )
    [[ ${reviewer_login} == "${authenticated_login}" ]] \
        || fail "sole rpm-signing reviewer must match the authenticated maintainer: reviewer=${reviewer_login} authenticated=${authenticated_login}"

    prevent_self_review=$(
        api_capture \
            'unable to query rpm-signing self-review policy.' \
            "${environment_endpoint}" \
            --jq '[.protection_rules[]? | select(.type == "required_reviewers")][0].prevent_self_review // false'
    )
    [[ ${prevent_self_review} == false ]] \
        || fail 'single-maintainer rpm-signing must allow self-review.'

    custom_policies=$(
        api_capture \
            'unable to query rpm-signing deployment policy.' \
            "${environment_endpoint}" \
            --jq '.deployment_branch_policy.custom_branch_policies // false'
    )
    [[ ${custom_policies} == true ]] \
        || fail 'rpm-signing must use selected custom deployment branch/tag policies.'

    deployment_policy_output=$(
        api_capture \
            'unable to list rpm-signing deployment policies.' \
            "${environment_endpoint}/deployment-branch-policies" \
            --paginate \
            --jq '.branch_policies[]?.name'
    )
    [[ -n ${deployment_policy_output} ]] \
        || fail 'rpm-signing has no selected deployment branch/tag policy.'

    mapfile -t deployment_policies <<<"${deployment_policy_output}"
    ((${#deployment_policies[@]} == 1)) \
        || fail "rpm-signing must have exactly one deployment policy; found ${#deployment_policies[@]}."
    [[ ${deployment_policies[0]} == 'v*' ]] \
        || fail "rpm-signing deployment policy must be exactly v*; found ${deployment_policies[0]}."
}

verify_signing_secret_scope() {
    local repository=$1
    local environment_endpoint="repos/${repository}/environments/${SIGNING_ENVIRONMENT}"
    local environment_secret_output=''
    local repository_secret_output=''
    local required_secret=''
    local signing_secret=''
    local -a environment_secrets=()
    local -a repository_secrets=()

    environment_secret_output=$(
        api_capture \
            'unable to list rpm-signing environment secrets.' \
            "${environment_endpoint}/secrets" \
            --paginate \
            --jq '.secrets[]?.name'
    )
    if [[ -n ${environment_secret_output} ]]; then
        mapfile -t environment_secrets <<<"${environment_secret_output}"
    fi

    for required_secret in RPM_SIGNING_PRIVATE_KEY_B64 RPM_SIGNING_PASSPHRASE; do
        printf '%s\n' "${environment_secrets[@]}" \
            | grep -Fxq -- "${required_secret}" \
            || fail "missing rpm-signing environment secret: ${required_secret}"
    done

    repository_secret_output=$(
        api_capture \
            'unable to list repository Actions secrets.' \
            "repos/${repository}/actions/secrets" \
            --paginate \
            --jq '.secrets[]?.name'
    )
    if [[ -n ${repository_secret_output} ]]; then
        mapfile -t repository_secrets <<<"${repository_secret_output}"
    fi

    for signing_secret in RPM_SIGNING_PRIVATE_KEY_B64 RPM_SIGNING_PASSPHRASE; do
        if printf '%s\n' "${repository_secrets[@]}" \
            | grep -Fxq -- "${signing_secret}"; then
            fail "signing secret must not also exist at repository scope: ${signing_secret}"
        fi
    done
}

inspect_preflight_rpm_certificate() {
    local listing=$1
    local gpg_home=$2

    LC_ALL=C gpg \
        --homedir "${gpg_home}" \
        --batch \
        --no-options \
        --with-colons \
        --show-keys \
        --fingerprint \
        "${RPM_SIGNING_KEY}" >"${listing}" \
        || fail 'unable to inspect RPM signing public certificate.'
}

check_preflight_rpm_signing_expiry() {
    local signing_expires=$1
    local now remaining_seconds remaining_days

    [[ ${signing_expires} =~ ^[0-9]+$ ]] \
        || fail 'unable to determine signing subkey expiry.'
    now=$(date +%s)
    remaining_seconds=$((signing_expires - now))
    ((remaining_seconds > 0)) \
        || fail 'RPM signing subkey is expired.'
    remaining_days=$((remaining_seconds / 86400))
    if ((remaining_days <= 90)); then
        printf 'Warning: RPM signing subkey expires in %d day(s).\n' \
            "${remaining_days}" >&2
    fi
}

validate_preflight_rpm_certificate() {
    local listing=$1
    local primary_count primary_fingerprint primary_capabilities
    local signing_subkey_count signing_subkey_record signing_subkey signing_expires

    primary_count=$(
        awk -F: '$1 == "pub" { count++ } END { print count + 0 }' "${listing}"
    )
    primary_fingerprint=$(
        awk -F: \
            '$1 == "pub" { want=1; next }
             want && $1 == "fpr" && !found {
                 value=toupper($10); found=1
             }
             END { if (found) print value }' \
            "${listing}"
    )
    primary_capabilities=$(
        awk -F: '$1 == "pub" { print $12; exit }' "${listing}"
    )
    signing_subkey_count=$(
        awk -F: \
            '$1 == "sub" &&
             $2 != "r" &&
             $2 != "e" &&
             index($12, "s") > 0 {
                 count++
             }
             END { print count + 0 }' \
            "${listing}"
    )
    signing_subkey_record=$(
        awk -F: -v expected="${RPM_SIGNING_SUBKEY_FINGERPRINT}" \
            '$1 == "sub" {
                 want=($2 != "r" && $2 != "e" && index($12, "s") > 0)
                 expiry=$7
                 next
             }
             want && $1 == "fpr" {
                 value=toupper($10)
                 if (value == expected) {
                     print value, expiry
                     exit
                 }
                 want=0
             }' \
            "${listing}"
    )
    [[ -n ${signing_subkey_record} ]] \
        || fail "expected signing subkey is absent or unusable: ${RPM_SIGNING_SUBKEY_FINGERPRINT}"
    read -r signing_subkey signing_expires <<<"${signing_subkey_record}"

    [[ ${primary_count} == 1 ]] \
        || fail "public certificate must contain exactly one primary; found ${primary_count}."
    [[ ${primary_fingerprint} == "${RPM_SIGNING_FINGERPRINT}" ]] \
        || fail "unexpected primary fingerprint: ${primary_fingerprint:-missing}"
    [[ ${primary_capabilities} == *c* && ${primary_capabilities} != *s* ]] \
        || fail 'primary certificate must remain certification-only.'
    [[ ${signing_subkey_count} == 1 ]] \
        || fail "certificate must contain exactly one usable signing subkey; found ${signing_subkey_count}."
    [[ ${signing_subkey} == "${RPM_SIGNING_SUBKEY_FINGERPRINT}" ]] \
        || fail "expected signing subkey is absent or unusable: ${RPM_SIGNING_SUBKEY_FINGERPRINT}"
    check_preflight_rpm_signing_expiry "${signing_expires}"
}

verify_rpm_signing_certificate() {
    (
        local listing=''
        local gpg_home=''

        trap cleanup EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        listing=$(mktemp) || fail 'unable to create the signing-certificate listing file.'
        gpg_home=$(mktemp -d) || fail 'unable to create the temporary GnuPG home.'
        chmod 700 -- "${gpg_home}" || fail 'unable to secure the temporary GnuPG home.'

        inspect_preflight_rpm_certificate "${listing}" "${gpg_home}"
        validate_preflight_rpm_certificate "${listing}"
    )
}

report_release_preflight() {
    local release_tag=$1
    local tag_commit=$2

    printf 'Release preflight passed for %s at %s.\n' \
        "${release_tag}" "${tag_commit}"
    printf '%s\n' \
        'rpm-signing: sole authenticated reviewer, intentional self-review allowance, v* deployment policy, and environment-secret scope verified.'
    printf '%s\n' \
        'Administrator bypass: operator explicitly confirmed disabled.'
    printf '%s\n' \
        'Deployment policy type: operator explicitly confirmed v* is a TAG policy.'
    printf '%s\n' \
        'Single-maintainer self-review: operator explicitly confirmed intentional.'
}

main() {
    local release_tag=''
    local repository=''
    local tag_commit=''

    parse_preflight_arguments release_tag "$@"
    require_preflight_commands
    resolve_preflight_repository repository
    verify_release_tag "${release_tag}" tag_commit
    verify_release_tree_and_version "${release_tag}"
    verify_immutable_releases "${repository}"
    verify_signing_environment "${repository}"
    verify_signing_secret_scope "${repository}"
    verify_rpm_signing_certificate
    report_release_preflight "${release_tag}" "${tag_commit}"
}

main "$@"
