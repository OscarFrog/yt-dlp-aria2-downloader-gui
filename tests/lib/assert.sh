#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# This file is sourced by the test scripts.

# shellcheck disable=SC2034 # Public result for callers that inspect command output.
ASSERT_OUTPUT=''

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_status() {
    local expected=$1
    local label=$2
    shift 2
    local actual=0
    local output=''

    set +e
    output=$("$@" 2>&1)
    actual=$?
    set -e

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
    local file=$1
    local needle=$2
    local label=$3

    if ! grep -Fq -- "${needle}" "${file}"; then
        printf 'FAIL: %s\nMissing text: %s\nFile: %s\n' \
            "${label}" "${needle}" "${file}" >&2
        exit 1
    fi
}

assert_file_not_contains() {
    local file=$1
    local needle=$2
    local label=$3

    if grep -Fq -- "${needle}" "${file}"; then
        printf 'FAIL: %s\nUnexpected text: %s\nFile: %s\n' \
            "${label}" "${needle}" "${file}" >&2
        exit 1
    fi
}
