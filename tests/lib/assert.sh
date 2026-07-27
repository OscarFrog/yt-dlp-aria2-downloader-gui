#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# This file is sourced by the test scripts.

# shellcheck disable=SC2034 # Read by test suites that source this file.
ASSERT_OUTPUT=''

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_readable_file() {
    (($# == 2)) || fail "assert_readable_file requires 2 arguments; got $#."
    local file=$1
    local label=$2

    [[ -r ${file} ]] || fail "${label}: file is not readable: ${file}"
}

assert_status() {
    (($# >= 3)) || fail 'assert_status requires an expected status, a label, and a command.'
    local expected=$1
    local label=$2
    shift 2
    local actual=0
    local output=''

    ASSERT_OUTPUT=''
    output=$("$@" 2>&1) || actual=$?

    if ((actual != expected)); then
        printf 'FAIL: %s\n' "${label}" >&2
        printf 'Expected status: %d\n' "${expected}" >&2
        printf 'Actual status:   %d\n' "${actual}" >&2
        printf 'Command:' >&2
        printf ' %q' "$@" >&2
        printf '\nOutput:\n%s\n' "${output}" >&2
        exit 1
    fi

    ASSERT_OUTPUT=${output}
}

assert_equals() {
    (($# == 3)) || fail "assert_equals requires 3 arguments; got $#."
    local expected=$1
    local actual=$2
    local label=$3

    if [[ ${actual} != "${expected}" ]]; then
        printf 'FAIL: %s\nExpected: %s\nActual:   %s\n' \
            "${label}" "${expected}" "${actual}" >&2
        exit 1
    fi
}

assert_text_contains() {
    (($# == 3)) || fail "assert_text_contains requires 3 arguments; got $#."
    local text=$1
    local needle=$2
    local label=$3

    if [[ ${text} != *"${needle}"* ]]; then
        printf 'FAIL: %s\nMissing text: %s\nText:\n%s\n' \
            "${label}" "${needle}" "${text}" >&2
        exit 1
    fi
}

assert_text_not_contains() {
    (($# == 3)) || fail "assert_text_not_contains requires 3 arguments; got $#."
    local text=$1
    local needle=$2
    local label=$3

    if [[ ${text} == *"${needle}"* ]]; then
        printf 'FAIL: %s\nUnexpected text: %s\nText:\n%s\n' \
            "${label}" "${needle}" "${text}" >&2
        exit 1
    fi
}

assert_file_contains() {
    (($# == 3)) || fail "assert_file_contains requires 3 arguments; got $#."
    local file=$1
    local needle=$2
    local label=$3

    assert_readable_file "${file}" "${label}"
    if ! grep -Fq -- "${needle}" "${file}"; then
        printf 'FAIL: %s\nMissing text: %s\nFile: %s\n' \
            "${label}" "${needle}" "${file}" >&2
        exit 1
    fi
}

assert_file_not_contains() {
    (($# == 3)) || fail "assert_file_not_contains requires 3 arguments; got $#."
    local file=$1
    local needle=$2
    local label=$3

    assert_readable_file "${file}" "${label}"
    if grep -Fq -- "${needle}" "${file}"; then
        printf 'FAIL: %s\nUnexpected text: %s\nFile: %s\n' \
            "${label}" "${needle}" "${file}" >&2
        exit 1
    fi
}

assert_file_has_line() {
    (($# == 3)) || fail "assert_file_has_line requires 3 arguments; got $#."
    local file=$1
    local expected=$2
    local label=$3

    assert_readable_file "${file}" "${label}"
    if ! grep -Fxq -- "${expected}" "${file}"; then
        printf 'FAIL: %s\nExpected complete line: %s\nFile: %s\n' \
            "${label}" "${expected}" "${file}" >&2
        exit 1
    fi
}

assert_file_has_no_line() {
    (($# == 3)) || fail "assert_file_has_no_line requires 3 arguments; got $#."
    local file=$1
    local unexpected=$2
    local label=$3

    assert_readable_file "${file}" "${label}"
    if grep -Fxq -- "${unexpected}" "${file}"; then
        printf 'FAIL: %s\nUnexpected complete line: %s\nFile: %s\n' \
            "${label}" "${unexpected}" "${file}" >&2
        exit 1
    fi
}
