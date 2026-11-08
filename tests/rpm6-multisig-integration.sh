#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/rpm6-multisig-integration.sh
# Purpose     : Validate RPM signatures and RPM Fusion bootstrap authentication.
# ==============================================================================

#
# Fedora/RPM 6 qualification for the project's current RPM v4 release format
# and for RPM v6 multi-signature verification semantics.
#
# The production fixture is expected to be an unsigned RPM v4 package, matching
# Fedora 44's deliberate default. The test proves that the legacy v4 signing
# path cannot silently accumulate a second signer. Multi-signature semantics
# are then exercised independently on a tiny RPM v6 fixture built locally with
# %_rpmformat=6. Only ephemeral keys are used.
# The qualification bootstrap is exercised with real signatures and isolated
# trust stores. DNF is intercepted; this suite never installs an RPM on its host.

set -Eeuo pipefail
umask 077

root=''
home_a=''
home_b=''
keyring_a=''
keyring_b=''
keyring_both=''
pass_a=''
pass_b=''
pub_a=''
pub_b=''
fingerprint_a=''
fingerprint_b=''
rpm_version=''
project_format=''
V6_RPM=''

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 65
}

cleanup() {
    gpgconf --homedir "${home_a}" --kill gpg-agent >/dev/null 2>&1 || true
    gpgconf --homedir "${home_b}" --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf -- "${root}" || true
}

generate_key() {
    local home=$1
    local uid=$2

    gpg \
        --homedir "${home}" \
        --batch \
        --pinentry-mode loopback \
        --passphrase '' \
        --quick-generate-key \
        "${uid}" \
        rsa2048 sign 1d
}

fingerprint() {
    local home=$1

    gpg \
        --homedir "${home}" \
        --batch \
        --with-colons \
        --list-secret-keys \
        --fingerprint \
        | awk -F: \
            '$1 == "fpr" && !found {
                 value=toupper($10); found=1
             }
             END { if (found) print value }'
}

sign_rpm_v4() {
    local home=$1
    local key_fingerprint=$2
    local passphrase_file=$3
    local package=$4

    LC_ALL=C GPG_TTY=/dev/null rpmsign \
        --addsign \
        --key-id "${key_fingerprint}" \
        --define "_openpgp_sign gpg" \
        --define "_gpg_path ${home}" \
        --define "_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file ${passphrase_file}" \
        "${package}"
}

sign_rpm_v6() {
    local home=$1
    local key_fingerprint=$2
    local passphrase_file=$3
    local package=$4

    LC_ALL=C GPG_TTY=/dev/null rpmsign \
        --addsign \
        --rpmv6 \
        --key-id "${key_fingerprint}" \
        --define "_openpgp_sign gpg" \
        --define "_gpg_path ${home}" \
        --define "_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file ${passphrase_file}" \
        "${package}"
}

rpmkeys_fs() {
    local keyring=$1
    shift

    rpmkeys \
        --define "_keyring fs" \
        --define "_keyringpath ${keyring}" \
        --define "_keyring_lockpath ${keyring}/.keyring.lock" \
        --define "_rpmlock_path ${keyring}/.rpm.lock" \
        "$@"
}

signature_count() {
    local package=$1
    local listing=''
    local -a signatures=()

    listing=$(LC_ALL=C rpm -qp --nosignature --qf '[%{OPENPGP}\n]' -- "${package}") \
        || fail "unable to query OpenPGP signatures: ${package}"
    [[ -n ${listing} ]] \
        || fail "no OpenPGP signatures reported for signed fixture: ${package}"
    mapfile -t signatures <<<"${listing}"

    ((${#signatures[@]} > 0)) \
        || fail "no OpenPGP signatures reported for signed fixture: ${package}"

    printf '%s\n' "${#signatures[@]}"
}

first_signature() {
    local package=$1
    local listing=''

    listing=$(LC_ALL=C rpm -qp --nosignature --qf '[%{OPENPGP}\n]' -- "${package}") \
        || fail "unable to query first OpenPGP signature: ${package}"
    printf '%s\n' "${listing%%$'\n'*}"
}

corrupt_signature_bytes() {
    local package=$1
    local signature=$2

    [[ -n ${signature} ]] || fail 'cannot corrupt an empty OpenPGP signature'

    python3 - "${package}" "${signature}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
needle = sys.argv[2].encode("ascii")
data = bytearray(path.read_bytes())
pos = data.find(needle)
if pos < 0:
    raise SystemExit("OpenPGP signature string was not found in RPM bytes")

index = pos + max(1, len(needle) // 2)
if index >= pos + len(needle):
    index = pos
original = data[index]
data[index] = ord("A") if original != ord("A") else ord("B")
path.write_bytes(data)
PY
}

build_v6_fixture() {
    local topdir="${root}/rpmbuild-v6"
    local spec="${topdir}/SPECS/rpm6-multisig-fixture.spec"
    local rpm_list="${root}/v6-rpm-list"
    local -a packages=()

    mkdir -p -- \
        "${topdir}/BUILD" "${topdir}/BUILDROOT" "${topdir}/RPMS" \
        "${topdir}/SOURCES" "${topdir}/SPECS" "${topdir}/SRPMS"

    cat >"${spec}" <<'SPEC'
Name: rpm6-multisig-fixture
Version: 1.0
Release: 1
Summary: Ephemeral RPM v6 multi-signature test fixture
License: MIT
BuildArch: noarch

%description
Ephemeral fixture used only by the project test suite.

%prep

%build

%install
mkdir -p %{buildroot}/usr/share/rpm6-multisig-fixture
printf '%s\n' fixture > %{buildroot}/usr/share/rpm6-multisig-fixture/payload

%files
/usr/share/rpm6-multisig-fixture/payload

%changelog
* Sat Aug 22 2026 yt-dlp aria2 CI <ci@example.invalid> - 1.0-1
- Deterministic RPM v6 multi-signature fixture.
SPEC

    rpmbuild -bb \
        --define "_topdir ${topdir}" \
        --define '_rpmformat 6' \
        "${spec}" >/dev/null

    find "${topdir}/RPMS" -type f -name '*.rpm' -print >"${rpm_list}"
    mapfile -t packages <"${rpm_list}"
    ((${#packages[@]} == 1)) \
        || fail "expected one RPM v6 fixture; found ${#packages[@]}"

    V6_RPM=${packages[0]}
}

validate_rpm6_environment() {
    local source_rpm=$1
    local command_name signature_state

    [[ -f ${source_rpm} && ! -L ${source_rpm} ]] \
        || fail "project RPM is not a regular file: ${source_rpm}"

    for command_name in awk cp find gpg gpgconf grep mkdir mktemp python3 rpm rpmkeys rpmbuild rpmsign; do
        command -v -- "${command_name}" >/dev/null 2>&1 \
            || fail "required command is absent: ${command_name}"
    done

    rpm_version=$(rpm --version)
    rpm_version=${rpm_version##* }
    [[ ${rpm_version} == 6.* ]] \
        || fail "RPM 6 is required; found ${rpm_version}"

    project_format=$(LC_ALL=C rpm -qp --qf '%{rpmformat}\n' -- "${source_rpm}")
    [[ ${project_format} == 4 ]] \
        || fail "project release RPM must currently use explicit RPM v4 format; found ${project_format}"

    signature_state=$(
        LC_ALL=C rpm -qp --qf '%|OPENPGP?{signed}:{unsigned}|\n' -- "${source_rpm}"
    )
    [[ ${signature_state} == unsigned ]] \
        || fail 'project fixture must start from an unsigned RPM'
}

prepare_rpm6_workspace() {
    root=$(mktemp -d)
    home_a="${root}/gpg-a"
    home_b="${root}/gpg-b"
    keyring_a="${root}/keyring-a"
    keyring_b="${root}/keyring-b"
    keyring_both="${root}/keyring-both"
    pass_a="${root}/pass-a"
    pass_b="${root}/pass-b"
    pub_a="${root}/a.asc"
    pub_b="${root}/b.asc"
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    mkdir -p -- \
        "${home_a}" "${home_b}" \
        "${keyring_a}" "${keyring_b}" "${keyring_both}"
    chmod 700 -- \
        "${home_a}" "${home_b}" \
        "${keyring_a}" "${keyring_b}" "${keyring_both}"
    : >"${pass_a}"
    : >"${pass_b}"
    chmod 600 -- "${pass_a}" "${pass_b}"

    V6_RPM=''
}

prepare_rpm6_signers() {
    generate_key "${home_a}" \
        'yt-dlp-aria2 RPM6 multisig A <rpm6-multisig-a@example.invalid>'
    generate_key "${home_b}" \
        'yt-dlp-aria2 RPM6 multisig B <rpm6-multisig-b@example.invalid>'

    fingerprint_a=$(fingerprint "${home_a}")
    fingerprint_b=$(fingerprint "${home_b}")
    [[ ${fingerprint_a} =~ ^[0-9A-F]{40}$ ]] \
        || fail "invalid key A fingerprint: ${fingerprint_a:-missing}"
    [[ ${fingerprint_b} =~ ^[0-9A-F]{40}$ ]] \
        || fail "invalid key B fingerprint: ${fingerprint_b:-missing}"
    [[ ${fingerprint_a} != "${fingerprint_b}" ]] \
        || fail 'ephemeral RPM signing keys unexpectedly share a fingerprint'

    gpg --homedir "${home_a}" --batch --armor \
        --export "${fingerprint_a}" >"${pub_a}"
    gpg --homedir "${home_b}" --batch --armor \
        --export "${fingerprint_b}" >"${pub_b}"

    rpmkeys_fs "${keyring_a}" --import "${pub_a}"
    rpmkeys_fs "${keyring_b}" --import "${pub_b}"
    rpmkeys_fs "${keyring_both}" --import "${pub_a}"
    rpmkeys_fs "${keyring_both}" --import "${pub_b}"
}

test_rpm_v4_legacy_signature() {
    local source_rpm=$1
    local legacy_one="${root}/project-v4-one-signer.rpm"
    local legacy_log="${root}/project-v4-second-signer.log"
    local legacy_count second_legacy_status

    # Production model: Fedora's RPM v4 package format and one v4-compatible
    # OpenPGP signature. Prove that a second legacy signer cannot be appended.
    cp -- "${source_rpm}" "${legacy_one}"
    sign_rpm_v4 "${home_a}" "${fingerprint_a}" "${pass_a}" "${legacy_one}"

    legacy_count=$(signature_count "${legacy_one}")
    [[ ${legacy_count} == 1 ]] \
        || fail "project RPM v4 fixture should contain exactly one OpenPGP signature; found ${legacy_count}"
    rpmkeys_fs "${keyring_a}" --checksig "${legacy_one}"

    set +e
    sign_rpm_v4 "${home_b}" "${fingerprint_b}" "${pass_b}" "${legacy_one}" \
        >"${legacy_log}" 2>&1
    second_legacy_status=$?
    set -e
    ((second_legacy_status != 0)) \
        || fail 'RPM v4 fixture unexpectedly accepted a second legacy signature'
    grep -Fq 'already contains a legacy signature' "${legacy_log}" \
        || fail 'RPM v4 second-signature rejection did not report the expected diagnostic'
}

test_rpm_v4_v6_multisig() {
    local source_rpm=$1
    local v4_v6_multi="${root}/project-v4-v6-multisig.rpm"
    local v4_v6_count v4_v6_format

    # Cross-format qualification: RPM 6 permits v6-style signatures on an RPM
    # package-format v4 payload. The package format must remain v4 while the
    # OpenPGP signature array accumulates independent signers.
    cp -- "${source_rpm}" "${v4_v6_multi}"

    sign_rpm_v6 "${home_a}" "${fingerprint_a}" "${pass_a}" "${v4_v6_multi}"
    v4_v6_format=$(LC_ALL=C rpm -qp --qf '%{rpmformat}\n' -- "${v4_v6_multi}")
    [[ ${v4_v6_format} == 4 ]] \
        || fail "RPM v6 signing unexpectedly changed package format: ${v4_v6_format}"
    v4_v6_count=$(signature_count "${v4_v6_multi}")
    [[ ${v4_v6_count} == 1 ]] \
        || fail "RPM v4/v6 fixture should contain one signature after signer A; found ${v4_v6_count}"
    rpmkeys_fs "${keyring_a}" --checksig "${v4_v6_multi}"

    sign_rpm_v6 "${home_b}" "${fingerprint_b}" "${pass_b}" "${v4_v6_multi}"
    v4_v6_format=$(LC_ALL=C rpm -qp --qf '%{rpmformat}\n' -- "${v4_v6_multi}")
    [[ ${v4_v6_format} == 4 ]] \
        || fail "second RPM v6 signature changed package format: ${v4_v6_format}"
    v4_v6_count=$(signature_count "${v4_v6_multi}")
    [[ ${v4_v6_count} == 2 ]] \
        || fail "RPM v4/v6 fixture should contain two signatures; found ${v4_v6_count}"
    rpmkeys_fs "${keyring_both}" --checksig "${v4_v6_multi}"
}

test_rpm_v6_multisig_semantics() {
    local v6_rpm v6_format v6_state
    local a_only b_only a_then_b b_then_a corrupt_then_b signature_a
    local a_only_count b_only_count a_then_b_count b_then_a_count corrupt_count
    local wrong_key_status corrupt_status

    # Scenario: build a package-format v6 fixture and qualify multi-signature
    # semantics independently of the production RPM v4 format.
    build_v6_fixture
    v6_rpm=${V6_RPM}
    [[ -n ${v6_rpm} ]] || fail 'RPM v6 fixture path was not published'
    v6_format=$(LC_ALL=C rpm -qp --qf '%{rpmformat}\n' -- "${v6_rpm}")
    [[ ${v6_format} == 6 ]] \
        || fail "dedicated multi-signature fixture is not RPM v6 format: ${v6_format}"

    v6_state=$(LC_ALL=C rpm -qp --qf '%|OPENPGP?{signed}:{unsigned}|\n' -- "${v6_rpm}")
    [[ ${v6_state} == unsigned ]] \
        || fail 'dedicated RPM v6 fixture unexpectedly starts signed'

    a_only="${root}/v6-a-only.rpm"
    b_only="${root}/v6-b-only.rpm"
    a_then_b="${root}/v6-a-then-b.rpm"
    b_then_a="${root}/v6-b-then-a.rpm"
    cp -- "${v6_rpm}" "${a_only}"
    cp -- "${v6_rpm}" "${b_only}"
    cp -- "${v6_rpm}" "${a_then_b}"
    cp -- "${v6_rpm}" "${b_then_a}"

    sign_rpm_v6 "${home_a}" "${fingerprint_a}" "${pass_a}" "${a_only}"
    sign_rpm_v6 "${home_b}" "${fingerprint_b}" "${pass_b}" "${b_only}"
    sign_rpm_v6 "${home_a}" "${fingerprint_a}" "${pass_a}" "${a_then_b}"
    sign_rpm_v6 "${home_b}" "${fingerprint_b}" "${pass_b}" "${a_then_b}"
    sign_rpm_v6 "${home_b}" "${fingerprint_b}" "${pass_b}" "${b_then_a}"
    sign_rpm_v6 "${home_a}" "${fingerprint_a}" "${pass_a}" "${b_then_a}"

    a_only_count=$(signature_count "${a_only}")
    b_only_count=$(signature_count "${b_only}")
    a_then_b_count=$(signature_count "${a_then_b}")
    b_then_a_count=$(signature_count "${b_then_a}")
    [[ ${a_only_count} == 1 ]] || fail 'RPM v6 A-only fixture does not contain one signature'
    [[ ${b_only_count} == 1 ]] || fail 'RPM v6 B-only fixture does not contain one signature'
    [[ ${a_then_b_count} == 2 ]] || fail 'RPM v6 A-then-B fixture does not contain two signatures'
    [[ ${b_then_a_count} == 2 ]] || fail 'RPM v6 B-then-A fixture does not contain two signatures'

    rpmkeys_fs "${keyring_a}" --checksig "${a_only}"
    rpmkeys_fs "${keyring_b}" --checksig "${b_only}"
    rpmkeys_fs "${keyring_both}" --checksig "${a_then_b}"
    rpmkeys_fs "${keyring_both}" --checksig "${b_then_a}"

    set +e
    rpmkeys_fs "${keyring_a}" --checksig "${b_only}" >/dev/null 2>&1
    wrong_key_status=$?
    set -e
    ((wrong_key_status != 0)) \
        || fail 'RPM v6 signed only by B unexpectedly verified in the A-only keyring'

    # Negative control: corrupt one known v6 signature while retaining another
    # valid signature. RPM 6 requires every known/enabled signature to validate.
    corrupt_then_b="${root}/v6-corrupt-a-then-valid-b.rpm"
    cp -- "${a_then_b}" "${corrupt_then_b}"
    signature_a=$(first_signature "${corrupt_then_b}")
    corrupt_signature_bytes "${corrupt_then_b}" "${signature_a}"

    corrupt_count=$(signature_count "${corrupt_then_b}")
    [[ ${corrupt_count} == 2 ]] \
        || fail 'corrupt-A-then-B RPM v6 fixture does not contain two signatures'

    set +e
    rpmkeys_fs "${keyring_both}" --checksig "${corrupt_then_b}" >/dev/null 2>&1
    corrupt_status=$?
    set -e
    ((corrupt_status != 0)) \
        || fail 'RPM 6 accepted one corrupt known signature alongside one valid signature'
}

test_rpm_fusion_bootstrap_authentication() {
    local source_rpm=$1
    local good_rpm="${root}/bootstrap-good.rpm"
    local wrong_rpm="${root}/bootstrap-wrong.rpm"
    local corrupt_rpm="${root}/bootstrap-corrupt.rpm"
    local workflow="${BASH_SOURCE[0]%/*}/../.github/workflows/qualification.yml"
    local signature=''

    cp -- "${source_rpm}" "${good_rpm}"
    cp -- "${source_rpm}" "${wrong_rpm}"
    sign_rpm_v6 "${home_a}" "${fingerprint_a}" "${pass_a}" "${good_rpm}"
    sign_rpm_v6 "${home_b}" "${fingerprint_b}" "${pass_b}" "${wrong_rpm}"
    rpmkeys_fs "${keyring_a}" --checksig "${good_rpm}"
    rpmkeys_fs "${keyring_b}" --checksig "${wrong_rpm}"
    cp -- "${good_rpm}" "${corrupt_rpm}"
    signature=$(first_signature "${corrupt_rpm}")
    corrupt_signature_bytes "${corrupt_rpm}" "${signature}"

    python3 -I -B - "${workflow}" "${root}" \
        "${source_rpm}" "${good_rpm}" "${wrong_rpm}" "${corrupt_rpm}" \
        "${pub_a}" "${pub_b}" "${fingerprint_a}" <<'PY_BOOTSTRAP_AUTHENTICATION'
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tempfile
import textwrap

workflow, root, unsigned, good, wrong, corrupt, key_a, key_b = map(Path, sys.argv[1:9])
fingerprint = sys.argv[9]
source = workflow.read_text()
start = '\n          gpg --homedir "${gpg_home}" --batch --no-options \\\n'
end = '          dnf install --assumeyes aria2 ffmpeg\n'
if source.count(start) != 1 or source.count(end) != 1:
    raise AssertionError('RPM Fusion authentication block is not uniquely located')
body = textwrap.dedent(source[source.index(start):source.index(end)])
nevra = subprocess.check_output(
    ['rpm', '-qp', '--qf', '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}', '--', str(unsigned)],
    text=True,
)

# Exercise the workflow's actual verifier with fixture trust roots. The original
# workflow retains its pinned RPM Fusion certificate and NEVRA. Both RPM trust
# domains here are private; DNF is observed, never executed or installed on host.
prefix = r'''set -Eeuo pipefail
umask 077
bootstrap_dir=$1
readonly rpmfusion_fingerprint=$2
readonly rpmfusion_nevra=$3
gpg_home=${bootstrap_dir}/gpg
key_listing=${bootstrap_dir}/key-listing
rpm_keyring=${bootstrap_dir}/isolated-keyring
system_keyring=${bootstrap_dir}/system-keyring
events=${bootstrap_dir}/events
rpmkeys() {
    if [[ $# == 2 && $1 == --import ]]; then
        printf 'system-import\n' >>"${events}"
        command rpmkeys --define "_keyring fs" \
            --define "_keyringpath ${system_keyring}" \
            --define "_keyring_lockpath ${system_keyring}/.keyring.lock" \
            --define "_rpmlock_path ${system_keyring}/.rpm.lock" "$@"
    else
        if [[ " $* " == *' --checksig '* ]]; then
            printf 'verify\n' >>"${events}"
        fi
        command rpmkeys "$@"
    fi
}
dnf() {
    printf 'dnf\n' >>"${events}"
    [[ $# == 4 && $1 == install && $2 == --assumeyes &&
       $3 == --setopt=localpkg_gpgcheck=True &&
       $4 == "${bootstrap_dir}/rpmfusion-free-release-44.noarch.rpm" ]] || exit 89
}
'''


def run(label, package, key=key_a, expected_nevra=nevra, implementation=body):
    with tempfile.TemporaryDirectory(prefix='bootstrap-' + label + '-', dir=root) as directory:
        case = Path(directory)
        for name in ('gpg', 'isolated-keyring', 'system-keyring'):
            (case / name).mkdir(mode=0o700)
        staged = case / 'rpmfusion-free-release-44.noarch.rpm'
        shutil.copyfile(package, staged)
        shutil.copyfile(key, case / 'RPM-GPG-KEY-rpmfusion-free-fedora-2020')
        before = hashlib.sha256(staged.read_bytes()).hexdigest()
        # Model global trust of the foreign signer without importing anything
        # into the host RPM database. The workflow's private verifier must not
        # acquire this authority from the separate transaction trust domain.
        subprocess.run(['rpmkeys', '--define', '_keyring fs',
                        '--define', f'_keyringpath {case / "system-keyring"}',
                        '--define', f'_keyring_lockpath {case / "system-keyring/.keyring.lock"}',
                        '--define', f'_rpmlock_path {case / "system-keyring/.rpm.lock"}',
                        '--import', str(key_b)], check=True, capture_output=True)
        result = subprocess.run(['bash', '-c', prefix + implementation, 'bootstrap-test',
                                 str(case), fingerprint, expected_nevra],
                                capture_output=True, text=True, timeout=20)
        events = (case / 'events').read_text().splitlines() if (case / 'events').exists() else []
        if hashlib.sha256(staged.read_bytes()).hexdigest() != before:
            raise AssertionError('bootstrap verification changed its RPM input')
        return result, events


def require_refusal(observed, expected_events, reason):
    result, events = observed
    if result.returncode == 0 or events != expected_events:
        raise AssertionError(reason)


for label, package in (('signed-v6', good), ('signed-legacy', root / 'project-v4-one-signer.rpm')):
    passed, events = run(label, package)
    if passed.returncode or events != ['verify', 'system-import', 'dnf']:
        raise AssertionError('valid signed fixture failed the complete authentication order: ' + passed.stderr)
require_refusal(run('unsigned', unsigned), [], 'unsigned RPM reached installation')
require_refusal(run('foreign-signer', wrong), ['verify'], 'foreign signer reached installation')
require_refusal(run('corrupt-signature', corrupt), ['verify'], 'corrupt signature reached installation')
require_refusal(run('foreign-certificate', good, key_b), [], 'foreign certificate reached verification')
require_refusal(run('wrong-nevra', good, expected_nevra=nevra + '-different'),
                ['verify'], 'wrong NEVRA reached installation')

# Signature presence is independent of RPM's digest-only success. Deleting that
# guard must reproduce the formerly admitted unsigned-package installation.
presence_start = body.index('signature_state=$(\n')
presence_end = body.index('\nrpmkeys \\\n', presence_start)
without_presence = body[:presence_start] + body[presence_end:]
observed = run('mutant-presence', unsigned, implementation=without_presence)
if observed[0].returncode or observed[1] != ['verify', 'system-import', 'dnf']:
    raise AssertionError('signature-presence mutant did not reach the expected unsafe admission')
try:
    require_refusal(observed, [], 'unsigned RPM reached installation')
except AssertionError as error:
    if str(error) != 'unsigned RPM reached installation':
        raise
else:
    raise AssertionError('signature-presence deletion escaped the refusal oracle')

verify_start = body.index('rpmkeys \\\n', body.index('rpmkeys \\\n') + 1)
verify_end = body.index('\nresolved_nevra=', verify_start)
without_verification = body[:verify_start] + body[verify_end:]
observed = run('mutant-verifier', wrong, implementation=without_verification)
if observed[0].returncode or observed[1] != ['system-import', 'dnf']:
    raise AssertionError('isolated-verifier mutant did not admit the foreign signer')
try:
    require_refusal(observed, ['verify'], 'foreign signer reached installation')
except AssertionError as error:
    if str(error) != 'foreign signer reached installation':
        raise
else:
    raise AssertionError('isolated-verifier deletion escaped the refusal oracle')

without_dnf_check = body.replace(' --setopt=localpkg_gpgcheck=True', '', 1)
observed = run('mutant-dnf', good, implementation=without_dnf_check)
if observed[0].returncode != 89 or observed[1] != ['verify', 'system-import', 'dnf']:
    raise AssertionError('DNF signature-policy deletion escaped its argument oracle')
print('RPM Fusion bootstrap: real signatures, isolated signer, unsigned/corrupt/identity refusals and mutations passed; DNF was intercepted, no installation performed.')
PY_BOOTSTRAP_AUTHENTICATION
}

main() {
    local source_rpm

    (($# == 1)) || fail 'usage: rpm6-multisig-integration.sh UNSIGNED_PROJECT.rpm'
    source_rpm=$1
    validate_rpm6_environment "${source_rpm}"
    prepare_rpm6_workspace
    prepare_rpm6_signers
    test_rpm_v4_legacy_signature "${source_rpm}"
    test_rpm_v4_v6_multisig "${source_rpm}"
    test_rpm_v6_multisig_semantics
    test_rpm_fusion_bootstrap_authentication "${source_rpm}"

    printf 'Project RPM format: v%s (single-signature production model confirmed).\n' "${project_format}"
    printf 'RPM v6 multi-signature qualification passed (%s).\n' "${rpm_version}"
}

main "$@"
