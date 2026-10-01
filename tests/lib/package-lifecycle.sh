#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==============================================================================
# Project     : yt-dlp-aria2-downloader-gui
# File        : tests/lib/package-lifecycle.sh
# Purpose     : Share package lifecycle payload and removal assertions.
# ==============================================================================

readonly PACKAGE_DESKTOP_FILE='/usr/share/applications/yt-dlp-aria2-downloader.desktop'
readonly PACKAGE_ICON_FILE='/usr/share/icons/hicolor/scalable/apps/yt-dlp-aria2-downloader.svg'

# Require the installed command to report the expected package version.
assert_package_cli_version() {
    local package_kind=$1
    local expected_version=$2
    local stage=$3
    local reported_version=''

    if ! reported_version=$(/usr/bin/yt-dlp-aria2-downloader --version); then
        printf 'Error: %s executable failed during %s.\n' \
            "${package_kind}" "${stage}" >&2
        return 65
    fi
    if [[ ${reported_version} != "yt-dlp-aria2-downloader version ${expected_version}" ]]; then
        printf 'Error: %s executable reports an unexpected version during %s: %s\n' \
            "${package_kind}" "${stage}" "${reported_version}" >&2
        return 65
    fi
    return 0
}

# Require the shared launcher, desktop, icon, and dependency payload.
assert_common_package_payload() {
    local package_kind=$1
    local runtime_command=''

    [[ -x /usr/bin/yt-dlp-aria2-downloader-gui ]] || {
        printf 'Error: %s GUI launcher is absent.\n' "${package_kind}" >&2
        return 65
    }
    [[ -f ${PACKAGE_DESKTOP_FILE} && ! -L ${PACKAGE_DESKTOP_FILE} ]] || {
        printf 'Error: %s desktop file is absent or unsafe.\n' \
            "${package_kind}" >&2
        return 65
    }
    [[ -f ${PACKAGE_ICON_FILE} && ! -L ${PACKAGE_ICON_FILE} ]] || {
        printf 'Error: %s icon is absent or unsafe.\n' "${package_kind}" >&2
        return 65
    }
    desktop-file-validate --no-hints "${PACKAGE_DESKTOP_FILE}"
    grep -Fqx -- 'Icon=yt-dlp-aria2-downloader' "${PACKAGE_DESKTOP_FILE}"

    for runtime_command in \
        aria2c ffmpeg ffprobe python3 curl gpg unzip flock timeout; do
        command -v "${runtime_command}" >/dev/null 2>&1 || {
            printf 'Error: %s dependency command is absent: %s\n' \
                "${package_kind}" "${runtime_command}" >&2
            return 65
        }
    done
    # The helper has one explicitly checked Python driver, independent of errexit.
    # shellcheck disable=SC2310
    assert_package_helper_behavior /usr/bin/yt-dlp-aria2-downloader || return $?
    return 0
}

# Exercise exact installed bytes through their public launcher and adjacent
# helpers. Negative layouts are private copies, never edits to installed files.
assert_package_helper_behavior() {
    python3 -I -B - "$1" <<'PY_PACKAGE_HELPERS'
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise AssertionError(message)


launcher = Path(sys.argv[1]).absolute()
payload = launcher.resolve(strict=True).parent
helpers = ('private-process-supervisor.py', 'private-aria2-plan.py')
for name in (*helpers, 'download-video.sh', 'runtime-manager.sh'):
    info = (payload / name).lstat()
    require(stat.S_ISREG(info.st_mode), f'unsafe installed file: {name}')
    expected = 0o644 if name in helpers else 0o755
    require(stat.S_IMODE(info.st_mode) == expected, f'wrong installed mode: {name}')
    print(f'Payload {name}: {hashlib.sha256((payload / name).read_bytes()).hexdigest()}', flush=True)

with tempfile.TemporaryDirectory(prefix='package-helper-contract-') as temporary:
    root = Path(temporary)
    for name in ('home', 'data', 'config', 'state', 'cache', 'runtime', 'bin', 'cwd', 'output'):
        (root / name).mkdir(mode=0o700)
    env = dict(PATH=str(root / 'bin') + os.pathsep + os.defpath,
               HOME=str(root / 'home'), XDG_DATA_HOME=str(root / 'data'),
               XDG_CONFIG_HOME=str(root / 'config'), XDG_STATE_HOME=str(root / 'state'),
               XDG_CACHE_HOME=str(root / 'cache'), XDG_RUNTIME_DIR=str(root / 'runtime'),
               LC_ALL='C', PYTHONDONTWRITEBYTECODE='1',
               YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE='0', YTDLP_DISABLE_REMOTE_EJS='1',
               PACKAGE_HELPER_CALLS=str(root / 'calls.jsonl'))

    def executable(path, body):
        path.write_text(body)
        path.chmod(0o755)

    # Record actual helper argv, then use the selected interpreter unchanged.
    # Nothing resolves an application helper via this test's checkout.
    executable(root / 'bin/python3', f'#!{sys.executable}\n' + '''import json, os, sys
with open(os.environ['PACKAGE_HELPER_CALLS'], 'a') as record:
    record.write(json.dumps(sys.argv[1:]) + '\\n')
os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
''')
    for command in ('curl', 'ffmpeg', 'ffprobe'):
        executable(root / 'bin' / command, '#!/bin/sh\nexit 91\n')
    for name in helpers:
        (root / 'cwd' / name).write_text('raise SystemExit(92)\n')

    def run(arguments, status, label):
        result = subprocess.run(list(map(str, arguments)), env=env, cwd=root / 'cwd',
                                capture_output=True, text=True, timeout=15)
        require(result.returncode == status,
                f'{label}: expected {status}, got {result.returncode}: {result.stderr}')
        return result

    supervisor = payload / helpers[0]
    plan = root / 'plan.json'
    plan.write_text(json.dumps({'requested_downloads': [{
        'url': 'http://127.0.0.1/package-fixture.mp4', 'protocol': 'http', 'ext': 'mp4',
    }]}))
    plan.chmod(0o600)
    result = run([sys.executable, '-I', '-B', payload / helpers[1], 'classify', '--plan', plan],
                 0, 'installed classifier accepts a direct plan')
    require(result.stdout == 'transport=direct\ntransfer_count=1\n',
            f'unexpected installed classifier result: {result.stdout}')
    for status in (0, 23):
        run([sys.executable, '-I', '-B', supervisor, '--timeout', '5', '--grace', '.2',
             '--', sys.executable, '-I', '-B', '-c', f'raise SystemExit({status})'],
            status, 'installed supervisor command status')

    # A stdout barrier comes only after the consumer's TERM handler is ready.
    # Assert the production outcome before rescuing any failed fixture.
    consumer = '''import os, signal
from pathlib import Path
signal.signal(signal.SIGTERM, lambda *_: exit(0))
start = Path('/proc/self/stat').read_text().rsplit(') ', 1)[1].split()[19]
print(f'READY {os.getpid()} {start}', flush=True)
while True: signal.pause()
'''
    for cancel in (False, True):
        child_identity = None
        process = subprocess.Popen(
            [sys.executable, '-I', '-B', str(supervisor), '--timeout', '10' if cancel else '1',
             '--grace', '.2', '--', sys.executable, '-I', '-B', '-c', consumer],
            env=env, cwd=root / 'cwd', stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True)
        try:
            require(select.select([process.stdout], [], [], 5)[0], 'consumer readiness missing')
            ready = process.stdout.readline().split()
            require(len(ready) == 3 and ready[0] == 'READY', f'invalid readiness: {ready}')
            child_identity = (int(ready[1]), ready[2])
            if cancel:
                process.send_signal(signal.SIGTERM)
            _, errors = process.communicate(timeout=5)
            expected = 143 if cancel else 124
            require(process.returncode == expected,
                    f'installed supervisor shutdown: expected {expected}, got {process.returncode}: {errors}')
            try:
                fields = Path(f'/proc/{child_identity[0]}/stat').read_text().rsplit(') ', 1)[1].split()
            except FileNotFoundError:
                fields = None
            require(fields is None or fields[19] != child_identity[1],
                    'supervisor returned before reaping its direct consumer')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            if child_identity is not None:
                pid, start = child_identity
                try:
                    descriptor = os.pidfd_open(pid)
                    try:
                        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
                        if fields[19] == start:
                            signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                    finally:
                        os.close(descriptor)
                except ProcessLookupError:
                    pass
                except FileNotFoundError:
                    pass
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

    runtime = root / 'data/yt-dlp-aria2-downloader/runtime'
    yt_dir, deno_dir = runtime / 'yt-dlp/2026.08.19', runtime / 'deno/2.9.4'
    yt_dir.mkdir(parents=True, mode=0o700)
    deno_dir.mkdir(parents=True, mode=0o700)
    for directory in (yt_dir, deno_dir):
        directory.parent.chmod(0o700)
        (directory.parent / 'current').symlink_to(directory.name)
    runtime.chmod(0o700)
    runtime.parent.chmod(0o700)
    options = '''audio-format audio-quality batch-file break-match-filters color concurrent-fragments
continue cookies cookies-from-browser downloader dump-single-json embed-metadata extract-audio
extractor-args extractor-retries fixup format fragment-retries ignore-config js-runtimes
list-impersonate-targets load-info-json merge-output-format no-clean-info-json no-overwrites
no-playlist no-plugin-dirs no-post-overwrites no-update newline output parse-metadata print
print-to-file progress progress-delta progress-template remux-video retries retry-sleep
skip-download socket-timeout'''.split()
    yt_name = 'yt-dlp_linux_aarch64' if os.uname().machine == 'aarch64' else 'yt-dlp_linux'
    executable(yt_dir / yt_name, f'#!{sys.executable}\n' + f'''import sys
args = sys.argv[1:]
if '--version' in args: print('2026.08.19')
elif '--help' in args: print({chr(10).join('--' + option for option in options)!r})
elif '--list-impersonate-targets' in args: print('Chrome-140 Linux curl_cffi')
elif '--dump-single-json' in args: print('{{')
else: raise SystemExit(93)
''')
    executable(deno_dir / 'deno', '#!/bin/sh\nprintf "deno 2.9.4 (stable, release)\\n"\n')
    manager = payload / 'runtime-manager.sh'
    run([manager, 'require'], 0, 'installed runtime probes')
    executable(deno_dir / 'deno', '#!/bin/sh\nexit 23\n')
    run([manager, 'require'], 69, 'installed runtime rejects failing probe')
    executable(deno_dir / 'deno', '#!/bin/sh\nprintf "deno 2.9.4 (stable, release)\\n"\n')

    url = root / 'request.url'
    url.write_text('https://package-fixture.invalid/media\n')
    url.chmod(0o600)
    args = ['--url-file', url, '--output-dir', root / 'output']
    # Deliberately malformed metadata reaches the actual installed classifier.
    # It must fail there, rather than succeeding or failing dependency lookup.
    result = run([launcher, *args], 65, 'installed launcher/classifier boundary')
    require('unable to classify the selected download transport' in result.stderr,
            f'engine failed before its installed classifier: {result.stderr}')
    calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
    for name in helpers:
        require(any(str(payload / name) in call for call in calls),
                f'installed caller did not invoke adjacent {name}')
    require(any(str(payload / helpers[1]) in call and 'classify' in call for call in calls),
            'installed engine did not invoke classify')

    # These malformed layouts retain every other installed byte and key. A
    # valid copy in the working directory must not serve as a fallback.
    for name in helpers:
        shutil.copy2(payload / name, root / 'cwd' / name)
    for name in helpers:
        for symbolic in (False, True):
            case = root / f'bad-{name}-{symbolic}'
            shutil.copytree(payload, case)
            (case / name).unlink()
            if symbolic:
                (case / name).symlink_to(payload / name)
            entry = root / f'entry-{name}-{symbolic}'
            entry.symlink_to(case / 'download-video.sh')
            result = run([entry, *args], 66, 'installed engine rejects unsafe adjacent helper')
            diagnostic = ('timed-command supervisor is missing or unsafe' if name == helpers[0]
                          else 'private aria2 helper is missing or unsafe')
            require(diagnostic in result.stderr, f'wrong helper refusal: {result.stderr}')
            if name == helpers[0]:
                result = run([case / 'runtime-manager.sh', 'require'], 66,
                             'installed runtime rejects unsafe adjacent supervisor')
                require(diagnostic in result.stderr, f'wrong runtime refusal: {result.stderr}')

print(f'Installed helper contract passed: {payload}')
PY_PACKAGE_HELPERS
}

# Require every caller-provided package path to be absent.
assert_package_paths_absent() {
    local package_kind=$1
    local stage=$2
    local path=''
    shift 2

    for path in "$@"; do
        [[ ! -e ${path} && ! -L ${path} ]] || {
            printf 'Error: %s left a package path during %s: %s\n' \
                "${package_kind}" "${stage}" "${path}" >&2
            return 65
        }
    done
    return 0
}
