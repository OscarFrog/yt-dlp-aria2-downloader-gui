#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Maintainer-side release preflight for repository/environment controls that
# cannot be proven from workflow YAML alone.

set -Eeuo pipefail
umask 077

readonly DEFAULT_REPOSITORY='OscarFrog/yt-dlp-aria2-downloader-gui'
readonly SIGNING_ENVIRONMENT='rpm-signing'
readonly API_VERSION='2026-03-10'
readonly RPM_SIGNING_FINGERPRINT='7B54065FE061E78ED2C96252E3BE996196ABEA7F'
readonly RPM_SIGNING_SUBKEY_FINGERPRINT='1F5B769CE48A08AAC0A7D9DDECC9894B41830245'
readonly RPM_SIGNING_KEY='packaging/keys/RPM-GPG-KEY-OscarFrog'

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
    vX.Y.Z

The two explicit confirmations cover GitHub Environment settings that the
current REST responses do not expose unambiguously enough for this preflight:
- administrator deployment-protection bypass is disabled;
- the selected deployment policy named v* is configured as a TAG policy.
USAGE
}

confirm_admin_bypass=false
confirm_tag_policy=false
while (($# > 1)); do
    case $1 in
    --confirm-admin-bypass-disabled)
        confirm_admin_bypass=true
        ;;
    --confirm-tag-policy)
        confirm_tag_policy=true
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

readonly release_tag=$1
[[ ${release_tag} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "invalid semantic release tag: ${release_tag}"
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

for command_name in awk date gh git gpg grep mktemp; do
    command -v -- "${command_name}" >/dev/null 2>&1 ||
        fail "required preflight command is absent: ${command_name}"
done

readonly repository=${GH_REPO:-${DEFAULT_REPOSITORY}}
[[ ${repository} == */* && ${repository} != */*/* ]] ||
    fail "invalid GH_REPO repository coordinate: ${repository}"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    fail 'run the preflight from the repository root.'

head_commit=$(git rev-parse HEAD)
tag_commit=$(git rev-parse "${release_tag}^{commit}") ||
    fail "unable to resolve local tag: ${release_tag}"
[[ ${tag_commit} == "${head_commit}" ]] ||
    fail "release tag ${release_tag} does not resolve to current HEAD."

git verify-tag "${release_tag}" >/dev/null 2>&1 ||
    fail "release tag is not a valid signed tag: ${release_tag}"

git_status=$(git status --porcelain)
[[ -z ${git_status} ]] ||
    fail 'working tree is not clean.'

version=$(./download-video.sh --version)
version=${version##* }
[[ ${release_tag} == "v${version}" ]] ||
    fail "release tag/version mismatch: tag=${release_tag} project=${version}"

[[ -f ${RPM_SIGNING_KEY} && ! -L ${RPM_SIGNING_KEY} ]] ||
    fail "RPM signing public certificate is missing or unsafe: ${RPM_SIGNING_KEY}"

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

immutable=$(
    api_capture \
        'unable to query Immutable Releases setting.' \
        "repos/${repository}/immutable-releases" \
        --jq '.enabled'
)
[[ ${immutable} == true ]] ||
    fail 'GitHub Immutable Releases are not enabled.'

environment_endpoint="repos/${repository}/environments/${SIGNING_ENVIRONMENT}"
required_reviewer_rules=$(
    api_capture \
        'unable to query rpm-signing required reviewers.' \
        "${environment_endpoint}" \
        --jq '[.protection_rules[]? | select(.type == "required_reviewers")] | length'
)
[[ ${required_reviewer_rules} == 1 ]] ||
    fail "rpm-signing must have exactly one required-reviewers rule; found ${required_reviewer_rules}."

reviewer_count=$(
    api_capture \
        'unable to query rpm-signing reviewer count.' \
        "${environment_endpoint}" \
        --jq '[.protection_rules[]? | select(.type == "required_reviewers")][0].reviewers | length'
)
((reviewer_count >= 1)) ||
    fail 'rpm-signing required-reviewers rule has no reviewer.'

prevent_self_review=$(
    api_capture \
        'unable to query rpm-signing self-review policy.' \
        "${environment_endpoint}" \
        --jq '[.protection_rules[]? | select(.type == "required_reviewers")][0].prevent_self_review // false'
)
[[ ${prevent_self_review} == true ]] ||
    fail 'rpm-signing must prevent self-review.'

custom_policies=$(
    api_capture \
        'unable to query rpm-signing deployment policy.' \
        "${environment_endpoint}" \
        --jq '.deployment_branch_policy.custom_branch_policies // false'
)
[[ ${custom_policies} == true ]] ||
    fail 'rpm-signing must use selected custom deployment branch/tag policies.'

deployment_policy_output=$(
    api_capture \
        'unable to list rpm-signing deployment policies.' \
        "${environment_endpoint}/deployment-branch-policies" \
        --paginate \
        --jq '.branch_policies[]?.name'
)
[[ -n ${deployment_policy_output} ]] ||
    fail 'rpm-signing has no selected deployment branch/tag policy.'

mapfile -t deployment_policies <<<"${deployment_policy_output}"
((${#deployment_policies[@]} == 1)) ||
    fail "rpm-signing must have exactly one deployment policy; found ${#deployment_policies[@]}."
[[ ${deployment_policies[0]} == 'v*' ]] ||
    fail "rpm-signing deployment policy must be exactly v*; found ${deployment_policies[0]}."

environment_secret_output=$(
    api_capture \
        'unable to list rpm-signing environment secrets.' \
        "${environment_endpoint}/secrets" \
        --paginate \
        --jq '.secrets[]?.name'
)
environment_secrets=()
if [[ -n ${environment_secret_output} ]]; then
    mapfile -t environment_secrets <<<"${environment_secret_output}"
fi

for required_secret in RPM_SIGNING_PRIVATE_KEY_B64 RPM_SIGNING_PASSPHRASE; do
    printf '%s\n' "${environment_secrets[@]}" |
        grep -Fxq -- "${required_secret}" ||
        fail "missing rpm-signing environment secret: ${required_secret}"
done

repository_secret_output=$(
    api_capture \
        'unable to list repository Actions secrets.' \
        "repos/${repository}/actions/secrets" \
        --paginate \
        --jq '.secrets[]?.name'
)
repository_secrets=()
if [[ -n ${repository_secret_output} ]]; then
    mapfile -t repository_secrets <<<"${repository_secret_output}"
fi

for signing_secret in RPM_SIGNING_PRIVATE_KEY_B64 RPM_SIGNING_PASSPHRASE; do
    if printf '%s\n' "${repository_secrets[@]}" |
        grep -Fxq -- "${signing_secret}"; then
        fail "signing secret must not also exist at repository scope: ${signing_secret}"
    fi
done

listing=$(mktemp)
gpg_home=$(mktemp -d)
cleanup() {
    rm -f -- "${listing}" || true
    rm -rf -- "${gpg_home}" || true
}
trap cleanup EXIT
chmod 700 -- "${gpg_home}"

LC_ALL=C gpg \
    --homedir "${gpg_home}" \
    --batch \
    --no-options \
    --with-colons \
    --show-keys \
    --fingerprint \
    "${RPM_SIGNING_KEY}" >"${listing}" ||
    fail 'unable to inspect RPM signing public certificate.'

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
[[ -n ${signing_subkey_record} ]] ||
    fail "expected signing subkey is absent or unusable: ${RPM_SIGNING_SUBKEY_FINGERPRINT}"
read -r signing_subkey signing_expires <<<"${signing_subkey_record}"

[[ ${primary_count} == 1 ]] ||
    fail "public certificate must contain exactly one primary; found ${primary_count}."
[[ ${primary_fingerprint} == "${RPM_SIGNING_FINGERPRINT}" ]] ||
    fail "unexpected primary fingerprint: ${primary_fingerprint:-missing}"
[[ ${primary_capabilities} == *c* && ${primary_capabilities} != *s* ]] ||
    fail 'primary certificate must remain certification-only.'
[[ ${signing_subkey_count} == 1 ]] ||
    fail "certificate must contain exactly one usable signing subkey; found ${signing_subkey_count}."
[[ ${signing_subkey} == "${RPM_SIGNING_SUBKEY_FINGERPRINT}" ]] ||
    fail "expected signing subkey is absent or unusable: ${RPM_SIGNING_SUBKEY_FINGERPRINT}"
[[ ${signing_expires} =~ ^[0-9]+$ ]] ||
    fail 'unable to determine signing subkey expiry.'

now=$(date +%s)
remaining_seconds=$((signing_expires - now))
((remaining_seconds > 0)) ||
    fail 'RPM signing subkey is expired.'
remaining_days=$((remaining_seconds / 86400))
if ((remaining_days <= 90)); then
    printf 'Warning: RPM signing subkey expires in %d day(s).\n' \
        "${remaining_days}" >&2
fi

printf 'Release preflight passed for %s at %s.\n' \
    "${release_tag}" "${tag_commit}"
printf '%s\n' \
    'rpm-signing: reviewer(s), self-review prevention, v* deployment policy, and environment-secret scope verified.'
printf '%s\n' \
    'Administrator bypass: operator explicitly confirmed disabled.'
printf '%s\n' \
    'Deployment policy type: operator explicitly confirmed v* is a TAG policy.'
