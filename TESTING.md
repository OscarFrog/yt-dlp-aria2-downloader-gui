# Testing

This document describes the repeatable validation procedure for the current
project. It is intentionally independent of a particular release date.

## Contents

- [Complete local test suite](#complete-local-test-suite)
- [Shell formatting](#shell-formatting)
- [Bash syntax](#bash-syntax)
- [ShellCheck](#shellcheck)
- [Covered behavior](#covered-behavior)
- [GitHub Actions](#github-actions)
- [Release maintainer preflight](#release-maintainer-preflight)
- [Real-world checks on Fedora 44](#real-world-checks-on-fedora-44)
- [Locale-stabilized probes](#locale-stabilized-probes)
- [Stress validation](#stress-validation)

## Complete local test suite

Run from the repository root:

```bash
./tests/run-all.sh
```

## Shell formatting

The project pins the upstream `mvdan/sh` `shfmt` release and its Linux
amd64/arm64 SHA-256 digests in `scripts/dev-tools/shfmt-pin.env`.

Check formatting without modifying files:

```bash
./scripts/check-shell-format.sh
```

Apply the canonical format:

```bash
./scripts/format-shell.sh
```

The project contract is `shfmt -i 4 -ci -bn`, with simplification disabled.
`tests/run-all.sh` performs the non-mutating check automatically. If the pinned
upstream binary is absent from the local managed tool directory, the bootstrap downloads the
exact GitHub release asset and verifies its SHA-256 before execution.

The scheduled `.github/workflows/shfmt-update.yml` workflow detects a newer
stable upstream release, updates the pin/checksums, reformats all canonical
shell files, runs the complete validation suite, and opens or refreshes a
dedicated update pull request.

See `SHELL_STYLE.md` for the complete permanent shell-style contract.

## Bash syntax

The canonical inventory is centralized in `tests/lib/project-files.sh`:

```bash
source ./tests/lib/project-files.sh
for file in "${ALL_SHELL_FILES[@]}"; do
    bash -n -- "${file}"
done
```

## ShellCheck

```bash
source ./tests/lib/project-files.sh
shellcheck -x -o all "${ALL_SHELL_FILES[@]}"
```

## Covered behavior

The automated suite checks, among other things:

- shell-comment policy: preserve ShellCheck directives and non-obvious rationale, use durable `Scenario`, `Mutation test`, `Regression guard`, `Negative control`, and `Positive controls` labels in tests, and reject permanent `PATCH`/`AUD`/version-history labels;
- project-version coherence across active scripts, documentation and release workflow surfaces, while keeping historical CHANGELOG entries exempt;
- standardized headers on every canonical shell script, including an SPDX MIT tag, project name, repository-relative file name and purpose;
- argument validation, terminal `--`, and exactly one URL per run;
- preservation of URLs containing shell metacharacters;
- trimming of leading and trailing whitespace entered in the GUI;
- native-audio selection with `ba/b`, `best`, and quality `0`;
- absence of forced MP3, M4A, or Opus output formats;
- MKV video selection without forced re-encoding;
- structured yt-dlp planning and progress records, aria2c console fallback,
  byte-weighted progress, fragment progress, unknown-size animation, exact
  private-direct transfer-count preallocation, and protection against
  pre-download `MetadataParser` hooks being misclassified as final post-processing;
- separate video/audio transfers, direct audio, HLS, DASH, merge, remux,
  extraction, late progress, and error paths;
- verification that a local transfer reaching 100% does not complete the global
  operation and that global 100% appears only after final-result publication;
- deletion of successful-download logs and retention of failure logs;
- automatic removal of retained diagnostic logs older than 15 days while
  preserving newer logs, unrelated files, and symbolic links;
- atomic process-group publication, bounded cancellation tests, explicit
  progress-pipe closure, termination, and verification that no worker process
  remains after GUI scenarios;
- process-group recovery when PGID-file publication is delayed;
- atomic publication and failure cleanup of the result-path file;
- rejection of a second writer targeting the same canonical output directory;
- explicit refusal to overwrite completed or post-processed media files while
  preserving interrupted-download resume behavior;
- disabling of inherited yt-dlp plugins and personal configuration;
- forwarding of HUP, INT, and TERM sent only to the CLI wrapper PID;
- forwarding of termination signals during the wrapper-managed HLS FFmpeg remux;
- preservation of immediate command failure statuses before PGID observation;
- one shared process session for GUI, engine, yt-dlp, aria2c, FFmpeg, and Deno;
- FFprobe rejection of missing or structurally invalid expected media streams;
- canonical destination validation before the progress monitor emits 100 percent;
- no-target-directory publication when a destination changes into a directory;
- private XDG runtime locks and fallback permissions;
- byte-bounded Unicode output templates;
- fallback from relative XDG configuration and state paths;
- retention of process-group control until every descendant has exited;
- Zenity timeout and unexpected-error handling;
- folder-chooser fallback behavior on Zenity 4;
- minimum versions, suffixed yt-dlp versions, required capabilities, and
  behavior under a hostile inherited locale;
- aria2 help lines containing short-option aliases and builds that omit the
  optional netrc capability;
- `.desktop` launcher installation through a stable private link, exact Exec
  escaping, restrictive-path handling, validation, permissions, reinstall, and
  removal;
- package install-tree layout, stable command symlinks, system desktop entry,
  dedicated hicolor icon, documentation permissions, and exclusion of tests
  and obsolete images;
- real privileged installation and removal of the generated RPM in Fedora 44
  `fresh` and `ffmpeg-free` GitHub Actions environments, including launcher and
  icon cleanup;
- fail-closed rejection of an unsigned PR RPM by the production Fedora bootstrap,
  with unsigned installation permitted only through the explicit
  `--allow-unsigned-dev` development path;
- release-RPM verification against an isolated OscarFrog trust domain,
  with the consumer bootstrap using a private RPM 6 filesystem keyring and
  independently pinning the full primary and dedicated signing-subkey
  fingerprints through GnuPG;
- a package-CI negative test that imports a different ephemeral signer into
  the host RPM database, signs the unsigned PR RPM with that key, and proves
  the production bootstrap still rejects it before merge;
- an independent release-CI negative test that repeats the wrong-signer attack
  against a copy of the actual signed release RPM before publication;
- real build, APT installation, removal, and ownership validation of the DEB on
  Ubuntu 24.04 without system yt-dlp or Deno package dependencies.

- private GUI URL transfer through owner-only URL and yt-dlp batch files, with
  the requested URL absent from GUI, engine, and yt-dlp process arguments;
- conservative recovery of abandoned private aria2 staging after SIGKILL,
  including owner-marker, legacy-fingerprint, symlink, unknown-entry,
  invalid-mode and cross-destination negative controls;
- real aria2 loopback qualification of exact `Referer`, `Cookie`,
  `Authorization`, multi-header and same-origin redirect fidelity, while
  sensitive header values remain absent from aria2 argv and captured output;
- a negative helper mutation that drops `Authorization` and must be rejected by
  the real header-fidelity server;
- retained-log URL redaction, an 8 MiB retained-size limit, and private live
  diagnostics kept under the runtime temporary directory;
- complete-video rejection when either the video or audio stream is absent,
  plus audio-mode rejection when a content-video stream remains in the final file;
- real MP3/ID3 attached-cover qualification proving `v:0` sees cover art while
  `V:0` does not, with a temporary `V:0` -> `v:0` validator mutant that must be killed;
- conditional Deno requirements and YouTube-only remote EJS fallback;
- measured wrapper-managed FFmpeg remux progress and bounded progress arithmetic;
- a complementary real-FFmpeg `-progress pipe:1` integration, repeated three
  times, proving parseable `out_time_us`, monotone/bounded global progress and
  no global 100% before result-file publication;
- HLS post-remux duration consistency with real FFmpeg/FFprobe, including a
  reproducible truncated-input case where FFmpeg exits 0 with both streams but
  a materially shortened MKV; that result must not be published, and the
  repaired HLS source remains available until global validation/publication succeeds;
- hermetic real-tool direct HTTP, AAC/M4A, Opus/WebM, combined-source audio,
  attached-cover audio, HLS and DASH transfers using generated media and loopback HTTP servers, with
  transparent shims proving that real aria2c is used for direct transfers and
  not for HLS/DASH fragments;
- controlled real aria2 Range/no-Range/redirect/error behavior plus interrupted
  transfer resumption, with explicit server active-request state around the
  restart marker/accounting boundary, no premature result-file/global 100%,
  FFprobe-valid finals, and proof that a resumed run transfers a strict
  remainder instead of the complete object again;
- managed-runtime operation with Deno outside PATH, bounded lock/network waits,
  strict zero-network `require` mode, exact-tag stable/nightly/stable switching,
  lock-descriptor isolation, ten-cycle contention/double-rollback stress,
  interrupted-activation journal recovery, explicit/automatic rollback, and
  x86_64/aarch64 asset mapping.
- package reinstall plus real previous-immutable-release -> current upgrade
  validation for RPM and DEB, using the exact previously published package
  bytes rather than rebuilding the previous version from source;
- preservation of a deterministic archive snapshot of the per-user
  managed-runtime tree across previous package installation and package
  upgrade, followed by allowlisted managed-runtime cleanup on final package
  removal;
- package-cleanup integration coverage for a custom `XDG_DATA_HOME`, exact
  legacy `-gui` paths, preservation of unrelated similarly named files, and
  preservation of a portable ZIP/Git launcher;
- adversarial cleanup coverage for forged and multi-line custom-XDG markers,
  symlinked ownership sentinels, missing homes, and terminal runtime symlinks;
- refusal to traverse symlinked intermediate cleanup components beneath
  authorized XDG roots, with that cleanup safety suite repeated ten times in
  stress CI;
- explicit production RPM-v4 pinning plus a dedicated RPM-v6 fixture that
  qualifies multi-signature ordering/corruption semantics three times in
  package PR CI and three times again before a release RPM is signed;
- exact same RPM artifact tested in Fedora `fresh` and `ffmpeg-free`;
- current stable yt-dlp compatibility in addition to the minimum supported
  version;
- exact release asset inventory and immutable-release/asset verification.
- a separate read-only post-publication job that freshly downloads the public
  release and proves byte identity with the tested Actions artifacts, rechecks
  `SHA256SUMS`, and verifies provenance against the exact tag commit.

## GitHub Actions

`.github/workflows/shell.yml` runs the same validation for pull requests and
for pushes to `main`, in two environments:

- `ubuntu-24.04`;
- a Fedora 44 container on a GitHub-hosted runner.

`.github/workflows/packages.yml` validates both package formats. Before package
upgrade testing, a dedicated `previous-release` job resolves the immediately
preceding semantic-version release, requires it to be immutable, downloads its
exact published RPM, DEB, and SHA256SUMS, and verifies release identity,
checksums, release-asset identity, and SLSA provenance bound to the expected
repository, release workflow, and exact source commit. The RPM and DEB upgrade
jobs consume those verified bytes through a short-lived Actions artifact and
recheck their transferred SHA-256 digests before installation.

Pull-request CI builds one unsigned noarch RPM and proves that the production
bootstrap rejects it unless `--allow-unsigned-dev` is explicitly selected.
Release CI builds the RPM once, explicitly requires RPM package format v4,
qualifies RPM-v4/v6 signature semantics three times, then signs those exact
bytes once in the isolated `rpm-signing` GitHub Environment. The signer has no
repository checkout, uses the same private RPM 6 `fs` keyring model as the
consumer bootstrap, removes materialized signing secrets as soon as they are no
longer needed, and explicitly terminates its temporary `gpg-agent`. The
identical signed RPM is then installed on Fedora 44 in `fresh` and
`ffmpeg-free` scenarios through the supported RPM Fusion bootstrap. The
architecture-independent DEB is built on Ubuntu 24.04, installed with APT, and
removed again. Both lifecycle checks verify the managed-runtime manager and
embedded yt-dlp signing key; the DEB no longer depends on distribution yt-dlp
or Deno packages.


`.github/workflows/real-tools.yml` installs actual yt-dlp, aria2c, FFmpeg, and
FFprobe on Ubuntu. Pull-request qualification retains the pinned yt-dlp
`2026.6.9` and `2026.8.19` matrix for reproducibility. It generates tiny direct
HTTP, AAC/M4A, Opus/WebM, combined-audio, HLS and DASH fixtures locally, serves
them over loopback, proves the aria2c/native downloader boundary, exercises real
FFmpeg progress, and checks HLS post-remux duration consistency without
contacting a public media service. Audio/routing and HLS-duration scenarios are
repeated three times. The controlled aria2 behavior suite repeats
Range/no-Range/redirect/error three times, the silent-active quiescence
negative control ten times, and interrupted resume ten times. A separate weekly
scheduled job resolves and logs the current stable yt-dlp
version and runs the same qualification without changing PR pins.

`.github/workflows/release.yml` is triggered by tags matching `v*`. It runs
the complete validation and the hermetic real-tool integration first, verifies
tag ancestry and project versions, then resolves the previous semantic-version
release.

That previous release must be immutable. Its exact published RPM and DEB are
downloaded and verified with the published SHA256SUMS, `gh release verify`,
`gh release verify-asset`, and SLSA provenance constrained to the expected
repository, release workflow, and exact source commit.

The current ZIP, RPM, and DEB are built in separate jobs. The release RPM is
built exactly once as an unsigned artifact, then a secret-bearing signing job
with no repository checkout verifies the expected primary and dedicated
signing-subkey fingerprints, requires exactly one usable signing subkey,
requests that exact subkey, and cryptographically verifies the result before
publication. RPM `OPENPGP:pgpsig` output is diagnostic metadata only and is not
treated as a full-fingerprint authorization primitive.
The resulting signed RPM bytes are the exact bytes
requalified in Fedora `fresh` and `ffmpeg-free` and later published. RPM and DEB upgrade tests use the previously published
immutable package bytes and verify that a deterministic archive snapshot of
the per-user managed-runtime tree remains unchanged across installation and
upgrade. Final package removal then verifies that the managed runtime has been
removed by the package cleanup hook.

The publication job downloads the exact tested current artifacts, adds the
public `RPM-GPG-KEY-OscarFrog` certificate, generates one shared SHA256SUMS file,
verifies the exact release asset inventory, requires the
resulting GitHub Release to be immutable, and verifies the release attestation
and every local asset.

A separate `verify-published` job then starts with read-only permissions,
downloads the immutable public release again, reconstructs the expected
inventory from the tested Actions artifacts, compares every public asset
byte-for-byte, verifies the shared checksum file, and constrains attestation
verification to this repository, `release.yml`, and the exact tag commit.

If a newly created release unexpectedly remains mutable, the workflow attempts
to delete it and verifies that cleanup succeeded. Failure or unconfirmed cleanup
causes publication to fail explicitly. Only the final job receives
`contents: write`.

## Release maintainer preflight

The preferred preflight is the repository helper:

```bash
bash ./scripts/release-preflight.sh \
  --confirm-admin-bypass-disabled \
  --confirm-tag-policy \
  --confirm-single-maintainer-self-review \
  vX.Y.Z
```

The three confirmation flags require the operator to have checked that
administrator bypass is disabled, that the selected `v*` deployment policy is a
**tag** policy, and that single-maintainer self-approval is intentional. The
script additionally verifies Immutable Releases, exactly one required reviewer,
that the reviewer matches the authenticated GitHub account, that self-review is
allowed for this single-maintainer mode, secret scope, the pinned public
certificate, the dedicated signing subkey, signed-tag/HEAD/version identity,
and warns when the signing subkey is within 90 days of expiry.

For manual workflow recovery, invoke the workflow from the exact same tag:

```bash
gh workflow run release.yml   --ref vX.Y.Z   -f tag=vX.Y.Z   -R OscarFrog/yt-dlp-aria2-downloader-gui
```

Before pushing a release tag, confirm that GitHub Immutable Releases are
enabled for the repository:

    gh api \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2026-03-10' \
      repos/OscarFrog/yt-dlp-aria2-downloader-gui/immutable-releases \
      --jq '.enabled'

The command requires repository administration read access. A successful
preflight must return:

    true


Before approving the `rpm-sign` environment deployment, also verify the
`rpm-signing` GitHub Environment itself:

1. `RPM_SIGNING_PRIVATE_KEY_B64` and `RPM_SIGNING_PASSPHRASE` are environment
   secrets, not repository-level secrets;
2. exactly one required reviewer is configured for this single-maintainer
   repository, that reviewer is the authenticated maintainer, and self-review
   remains intentionally allowed;
3. deployment branch/tag rules are restricted to the minimum release paths
   required by the tag workflow and any intentionally retained
   `workflow_dispatch` recovery path;
4. the public certificate still has primary fingerprint
   `7B54065FE061E78ED2C96252E3BE996196ABEA7F`;
5. the dedicated signing subkey is
   `1F5B769CE48A08AAC0A7D9DDECC9894B41830245` and has not expired or been revoked;
6. a temporary import of the environment private bundle shows the primary as
   an offline `sec#` stub and the dedicated signing subkey as usable secret
   material; the primary private key itself must not be present in CI.

After the final `publish` job succeeds, download the release RPM and independently
confirm its signer and isolated trust binding on Fedora 44:

```bash
rpm -qp --qf '[%{OPENPGP:pgpsig}\n]' ./yt-dlp-aria2-downloader-gui-X.Y.Z-1.fc44.noarch.rpm

VERIFY_ROOT=$(mktemp -d)
VERIFY_KEYRING="${VERIFY_ROOT}/keyring"

mkdir -p "$VERIFY_KEYRING"
chmod 700 "$VERIFY_ROOT" "$VERIFY_KEYRING"

rpmkeys   --define "_keyring fs"   --define "_keyringpath ${VERIFY_KEYRING}"   --define "_keyring_lockpath ${VERIFY_KEYRING}/.keyring.lock"   --define "_rpmlock_path ${VERIFY_KEYRING}/.rpm.lock"   --import ./RPM-GPG-KEY-OscarFrog

rpmkeys   --define "_keyring fs"   --define "_keyringpath ${VERIFY_KEYRING}"   --define "_keyring_lockpath ${VERIFY_KEYRING}/.keyring.lock"   --define "_rpmlock_path ${VERIFY_KEYRING}/.rpm.lock"   --checksig ./yt-dlp-aria2-downloader-gui-X.Y.Z-1.fc44.noarch.rpm

rm -rf -- "$VERIFY_ROOT"

gh release verify vX.Y.Z -R OscarFrog/yt-dlp-aria2-downloader-gui
gh release verify-asset vX.Y.Z   ./yt-dlp-aria2-downloader-gui-X.Y.Z-1.fc44.noarch.rpm   -R OscarFrog/yt-dlp-aria2-downloader-gui
gh attestation verify   ./yt-dlp-aria2-downloader-gui-X.Y.Z-1.fc44.noarch.rpm   -R OscarFrog/yt-dlp-aria2-downloader-gui
```

A specific release is considered qualified only after its final `publish` job
has completed successfully. The presence of immutable-release, attestation, or
asset-verification commands in the workflow alone is not evidence that a
particular release actually passed those checks.

## Real-world checks on Fedora 44

After the automated suite passes, perform lawful manual tests:

1. download one complete MKV video;
2. download one native audio track;
3. download one YouTube video with the authenticated Firefox HLS profile;
4. cancel one direct transfer and one fragmented HLS transfer;
5. test a destination containing spaces, Unicode characters, and `%`;
6. verify that a second concurrent download targeting the same output cannot
   corrupt files created by the first one;
7. interrupt the authenticated HLS profile during the final FFmpeg remux and
   verify that no FFmpeg process remains;
8. verify one audio and one video result with FFprobe before opening them.

Verify that cancellation stops the download, the final files open correctly,
the audio extension was not forced by the interface, and no worker process is
left behind.

## Locale-stabilized probes

Version, help, and progress output is generated under `LC_ALL=C` for stable
parsing. Zenity windows remain in the graphical session's locale.

## Stress validation

`.github/workflows/stress.yml` runs three independent stress jobs on pull
requests and pushes to `main`:

- the complete mock process/cancellation integration suite twenty times with
  bounded deterministic timing variations around cancellation, late
  cancel/success arbitration, PGID publication, worker/FFmpeg startup, and
  `setsid` startup;
- the runtime-manager hardening integration suite ten times, repeatedly
  exercising fresh bootstrap, strict zero-network behavior, exact-tag
  resolution, activation-journal recovery, lock contention, and rollback
  transactions.
