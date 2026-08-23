#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/rpm6-multisig-integration.sh
# Purpose     : Validate RPM v6 multi-signature ordering and corruption semantics.
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

set -Eeuo pipefail
umask 077

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

main() {
    (($# == 1)) || fail 'usage: rpm6-multisig-integration.sh UNSIGNED_PROJECT.rpm'
    readonly source_rpm=$1
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

    root=$(mktemp -d)
    readonly root
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

    # Production model: Fedora's RPM v4 package format and one v4-compatible
    # OpenPGP signature. Prove that a second legacy signer cannot be appended.
    legacy_one="${root}/project-v4-one-signer.rpm"
    legacy_log="${root}/project-v4-second-signer.log"
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

    printf 'Project RPM format: v%s (single-signature production model confirmed).\n' "${project_format}"
    printf 'RPM v6 multi-signature qualification passed (%s).\n' "${rpm_version}"

}

main "$@"
