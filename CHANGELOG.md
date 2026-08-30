# Changelog

## 2.3.7 - 2026-08-30

### GUI continuity

- Classify URL hosts with the engine's exact YouTube host rules, hide the
  authenticated Firefox HLS profile for every other site, and replace an
  incompatible remembered profile with complete video for the current request.
- Centralize safe diagnostic errors behind consistent **View log** and **Close**
  actions across worker startup, runtime, downloader, progress, post-processing,
  final-result validation, and bounded Zenity technical failures.

### Diagnostic logs

- Add the retained diagnostic's exact final basename and canonical absolute
  path to a terminal identity section that survives bounded source-log
  truncation.
- Preserve URL sanitization, private permissions, symlink defenses, bounded
  retention, atomic no-overwrite publication, and fail closed when no useful
  sanitized payload remains after reserving the identity section.

### Agent tooling

- Add a fixed-action read-only Git inspection helper so unattended status,
  inventory, diff, and diff-check operations no longer require a broad direct
  Git exemption; mutating and remote commands remain protected.

### Release integrity

- Align the English/French RPM, DEB, ZIP, and verification examples with
  v2.3.7 before tagging so the immutable artifacts do not embed instructions
  rejected by the version-locked Fedora bootstrap.
- Make both the maintainer preflight and the read-only release validation fail
  closed unless the packaged documentation's published-version contract
  matches the release tag.

## 2.3.6 - 2026-08-30

### Progress accuracy

- Keep exact aggregate byte weighting whenever both planned stream totals are
  known. For an explicit two-stream complete-video plan with incomplete totals,
  use a bounded 80/20 video/audio fallback instead of the misleading equal-item
  average, while preserving monotonic Zenity progress, the post-processing
  range, and generic behavior for single, combined, or ambiguous plans across
  native yt-dlp and aria2c.

### Release documentation

- Correct the English and French installation examples from stale v2.3.4 asset
  names to the immutable v2.3.5 RPM, DEB, and ZIP assets.
- Add a fail-closed post-release documentation updater and workflow that
  independently revalidates the successful immutable release, exact data-only
  handoffs, and the complete local suite before publishing a bounded branch for
  a maintainer-opened, reviewable pull request.

## 2.3.5 - 2026-08-30

### Security and state robustness

- Isolate every yt-dlp runtime probe from personal configuration, plugins and
  self-updates, and disable curl configuration before managed downloads.
- Bind Deno candidates to the exact resolved release, return immutable
  versioned runtime paths to the engine, preserve those bytes across later
  activation changes, and reject a symlinked managed XDG application root
  before creating runtime state.
- Prevent retained-log truncation from exposing a secret-bearing URL suffix by
  discarding the single potentially partial line at the 8 MiB boundary before
  redaction, then enforcing the final size limit again after sanitization.
- Ignore non-regular, symbolic-link, oversized, or overlong GUI configuration
  inputs without blocking or partially applying them; accept at most 64 KiB
  and 128 lines before atomically publishing loaded settings.
- Refuse portable-launcher mutation through a symbolic-link XDG root or any
  parent/intermediate component or a shared-writable data root, anchor every
  transaction to no-follow directory descriptors so concurrent path replacement
  cannot redirect it, reject false success after root or managed-directory identity
  changes, restrict stale cleanup to exact private token formats and expected
  non-mounted artifact types without recursive traversal, clean partial
  allocation failures, serialize concurrent install/uninstall transactions on
  the anchored data-root inode with bounded waiting, revalidate the executable
  GUI target and visible root immediately before success, roll back partial
  three-leaf publication/removal, bound desktop-validator time and output, and
  keep missing managed branches from falling back to the process working
  directory, reject non-UTF-8 desktop-entry paths without a traceback, and
  reject overflowing NSS UID/GID values before Bash arithmetic or cleanup.
- Make portable-launcher interruption transactional across the Bash/Python
  boundary: preserve 129/130/143, cancel and reap an active validator, register
  temporary files and hard-link backups before delivering a pending signal,
  keep the asynchronous handler flag-only under concurrent group/wrapper
  delivery, revalidate retained child identities before signaling and avoid
  KILL after validator reaping, finish rollback/cleanup before exit, preserve
  the first request through final cleanup and process return, and keep
  descriptor-close diagnostics from masking the primary failure.

### GUI process reliability

- Run every captured Zenity dialog as a registered child and connect the
  progress monitor and progress dialog through a private mode-`0600` FIFO, so
  their independent statuses can be waited and preserved explicitly.
- Handle HUP, INT, and TERM immediately while a dialog or progress session is
  blocked; close, bound, signal, and reap all GUI children and the worker group
  without leaving temporary Zenity captures or changing 129/130/143 statuses.
- Accept at most 64 KiB from captured Zenity stdout, ingest at most the final
  64 KiB of stderr diagnostics, and preserve the first signal received while
  registering the worker supervisor, a captured dialog, or the progress pair.
- Return explicit worker-liveness statuses so Bash 5.2 cleanup entered through
  the negated EXIT-trap condition cannot mistake a live pre-PGID supervisor for
  a terminated worker and block while waiting without first signaling it.
- Supervise managed-runtime preparation and protect every CLI child-registration
  window; restore default HUP/INT/TERM dispositions inherited by asynchronous
  children and wait for post-restoration readiness before replaying a deferred
  signal while allowing a repeated request to escalate immediately, so every
  signal is relayed and reaped without leaking descendants, waiting for forced
  escalation, or replacing the requested 129/130/143 status with a raw `setsid`
  signal number.
- Remove the opaque `setsid --fork` supervisor from GUI and autonomous CLI
  launches. With job control explicitly disabled, the directly registered
  worker becomes the session leader (`PID = PGID = SID`), closing the
  foreground-group signal race before PGID publication and on repeated-signal
  escalation.

### Runtime performance

- Reuse the immutable paths and versions captured by the final managed-runtime
  validation when emitting the engine attestation, removing four redundant
  executable probes from every managed launch.

### Documentation

- Align every English and French installation example with the immutable
  v2.3.4 RPM, DEB and ZIP, while opening the next development version so its
  package identity cannot collide with the published release tag.
- Declare the DEB's verified-TLS CA-certificate dependency, keep installed
  README links usable, and qualify portable source-tree uninstall instructions.

### Test reliability

- Synchronize the startup-signal stress test with the sender acknowledgement,
  allowing Bash 5.2 to dispatch a pending trap after the `DEBUG` hook returns
  while still proving that the signal preceded complete child registration.
- Reject oversized `--jobs` values before Bash arithmetic, make suite/static
  mappings exact, and execute a hermetic manifest regression that proves all
  full, fast and ShellCheck commands without omissions, overlap or duplicates.
- Authenticate runner cancellation with a child-published Linux start time and
  private inherited token, plus a same-snapshot parent/start-time fallback when
  a fatal signal precedes publication. Keep the token-bearing session
  supervisor alive through signal-resistant descendants and apply the same
  stale-identity rejection to signal-test cleanup.
- Front-load the latency-dominant signal and test-runner suites at four-way
  concurrency, reducing the parallel tail without increasing worker count or
  removing validation.

### Repository maintenance

- Add a statically enforced tracked-file utility inventory and document the
  active, historical, and compatibility reason for retaining every path.
- Revalidate all 83 tracked paths and their package, CI, test, documentation,
  and compatibility consumers; remove the duplicate raw path list and stale
  snapshot narrative from the current inventory.
- Define a language-appropriate Python identity contract instead of copying the
  Bash-only header, and document the manual real-Zenity and post-release
  qualification helpers.
- Add a stable architecture map, recast `AGENTS.md` as the repository policy
  router with explicit code-review blockers, and provide progressively loaded
  skills for shell, supply-chain, packaging, and release work.
- Add a non-provisioning validation doctor with bounded probes, fail-closed
  Git/shfmt readiness and versioned JSON output; add conservative
  repository-local Codex execution rules and structured issue/pull-request
  templates for scope, authority, and validation evidence.

## 2.3.4 - 2026-08-28

### Test reliability

- Replace the startup-signal stress test's timing delay with a deterministic
  parent/child registration handshake, and terminate the complete fixture
  process group if its bounded failure envelope expires.

## 2.3.3 - 2026-08-28

### Release automation

- Align the release workflow's English and French development-version checks
  with the README wording, with a static regression that fails before a release
  tag is created if either contract drifts again.
- Resolve the upgrade baseline from stable published GitHub Releases rather
  than every repository tag, so a protected tag whose workflow stopped before
  publication cannot hide the latest immutable package release. Ancestry,
  immutability, checksum, asset-identity and provenance checks remain required.

## 2.3.2 - 2026-08-28

### Security

- Close the Fedora bootstrap verification-to-install race by copying
  application and RPM Fusion authorization inputs into private root-owned
  staging, then repeating identity, fingerprint and isolated-signature checks
  against the exact copies consumed by system key import and DNF.
- Add mutation regressions that replace every original key/RPM immediately
  after staging and prove privileged consumers remain bound to the verified
  bytes.

### Repository maintenance

- Remove the superseded v2.3.0 audit report and historical v2.2.0
  qualification plan from the current source tree.
- Remove the static assertions that required the historical qualification
  document after its release evidence had already been preserved in Git.
- Keep the English and French installation examples aligned with the exact RPM,
  DEB and ZIP names from the latest published GitHub release, independently of
  the development version carried by `main`.
### Validation performance

- Build and probe the immutable real-FFmpeg input fixture once, shorten its
  bounded media duration, and retain three independent progress/publication
  executions.
- Replace arbitrary mock downloader waits with short scheduling windows where
  explicit marker synchronization already carries the timing contract, and
  bound the deliberate signal-escalation fixture without changing the
  production runner's five-second grace period.
- Schedule read-only shfmt, static and ShellCheck validation through one bounded
  completion-driven pool, and stagger CPU-heavy integration suites with
  wait-heavy validations to reduce contention and the parallel tail.
- Add a supervised repeat runner with deterministic log replay, then use it for
  independent real-tool, HLS, RPM-v6, runtime-hardening and package-cleanup
  qualification repetitions in local release checks and GitHub Actions.
- Bind signal-stress PID liveness checks to an inherited fixture token so rapid
  PID reuse cannot report or terminate an unrelated parallel test process.

### Production efficiency and consistency

- Replace separate content-video, audio and timeline FFprobe launches with one
  bounded JSON summary that still excludes attached cover art; ordinary final
  validation now uses two FFprobe processes instead of four, and HLS final
  validation uses four instead of six.
- Add a versioned managed-runtime attestation so the engine consumes validated
  yt-dlp/Deno paths and versions from one runtime-manager invocation instead of
  repeating two path lookups plus yt-dlp/Deno version and capability discovery.
- Reuse versions already obtained during runtime validation when reporting
  versions and installing candidates, without removing any executable,
  signature, capability, rollback or minimum-version check.
- Align the GUI initialization phases, callable test-library documentation and
  durable regression comments with `SHELL_STYLE.md`, and extend static policy
  checks to reject versioned/audit-history comments in canonical shell files.

## 2.3.1 - 2026-08-28

### Security and supply chain

- Authenticate the Fedora 44 RPM Fusion bootstrap before any privileged
  transaction by pinning its OpenPGP fingerprint and NEVRA, verifying both in
  isolated keyrings, and requiring DNF local-package signature checks.
- Route HTTPS plans away from affected aria2 1.37.x GnuTLS builds while
  retaining direct acceleration for unaffected TLS backends and corrected
  aria2 generations.
- Require the release workflow to verify the exact authorized tag-signing
  fingerprint locally instead of trusting a generic GitHub verification flag.

### Process reliability and diagnostics

- Defer signals arriving inside the test-runner launch/registration critical
  section until the new child PID and process group are fully supervised, and
  close the final replay window so a later signal cannot supersede the first.
- Synchronize cancellation and private-staging signal fixtures with observable
  worker readiness, and preserve the intended signal status under load.
- Redact the forbidden external source label from engine diagnostics and
  retained GUI logs, with a repository-wide static gate against reintroduction;
  keep the streaming redactor alive through cancellation to avoid SIGPIPE races.
- Enforce owner-only URL-file permissions and report bounded, secret-safe
  FFprobe validation reasons for rejected final media.

### Consistency and release evidence

- Remove the dead signal alias and harden the output-by-name helpers exposed by
  the audit's dynamic-scope mutations.
- Verify administrator bypass and the exact deployment tag-policy type through
  the GitHub API, paginate exact-SHA workflow lookup, and retry transient public
  evidence operations with a bounded budget.
- Align Fedora support, English/French documentation, testing scope and static
  content policy with the implemented v2.3.1 guarantees.

## 2.3.0 - 2026-08-28

### Architecture and consistency

- Apply the canonical shell structure, four-space formatting, headers,
  comments, local-variable scope, and bottom-level orchestration consistently
  across the engine, GUI, runtime manager, installers, package builders,
  lifecycle tests, release tooling, and integration suites.
- Split runtime compatibility, HLS remux publication, Fedora RPM certificate
  authentication, release preflight, qualification reporting, and large test
  scenarios into focused phases with explicit trust and cleanup boundaries.
- Deduplicate package lifecycle orchestration and assertion helpers, including
  symlink targets and Unix permission modes, while removing obsolete helpers
  and unnecessary test prerequisites.

### Validation performance and coverage

- Add fast/full validation profiles, elapsed-time reporting, supervised
  process-group execution, buffered deterministic output, completion-driven
  scheduling, and bounded parallel ShellCheck validation.
- Divide the mock contract into independent engine, GUI, signal, runtime, and
  validation groups so local and CI runs can use four-way parallelism while
  preserving aggregate groups and historical scenario order.
- Keep ordinary runtime-hardening repetitions short while restoring ten-cycle
  rollback/contention coverage inside the dedicated ten-run stress workflow.
- Expand and modularize real FFmpeg, HLS duration, aria2 behavior/header,
  private publication, runtime rollback, installer, packaging, and runner
  qualifications; the full local contract now completes in about one minute.

### Release and packaging

- Run bounded parallel validation for source, archive, package, release, and
  verified-formatter CI paths, with static contracts protecting the scheduler
  groups and security-sensitive phases.
- Preserve behavior and artifact compatibility while strengthening version,
  RPM signing-certificate, immutable-release, package-upgrade, and diagnostic
  validation for the 2.3.0 release.

## 2.2.6 - 2026-08-27

### Code consistency and hardening

- Harden static shell/workflow policy checks so canonical headers, inventory
  discovery, privileged shfmt publication boundaries, and mutation controls
  fail closed with precise diagnostics.
- Refactor runtime-manager helper scope, remove dead helper code, make
  package-cleanup registration explicitly RPM best-effort, improve path/link
  diagnostics, bind downloaded yt-dlp candidates to the exact resolved
  release version, and extract only the expected Deno executable.
- Harden RPM per-user cleanup by binding direct user-home cleanup to the
  effective UID, bounding metadata parsing, applying a timeout/minimal
  environment to root cleanup too, restoring shell-option state, and using
  associative UID/HOME deduplication.
- Align permanent shell/comment/testing documentation with the post-2.2.5
  RPM-vs-DEB lifecycle split and document sourced-library APIs.

### Scope

- No downloader routing, media selection, aria2/FFmpeg behavior, GUI process
  supervision, progress calculation, or DEB remove/purge policy changes.

## 2.2.5 - 2026-08-27

### Packaging correctness and lifecycle

- Make Debian `remove` and `purge` non-destructive for per-user runtime,
  configuration, state, and cache by dropping unnecessary DEB maintainer hooks
  and the RPM-only all-user cleanup helper from the DEB payload.
- Add Debian manual pages, a Debian changelog, machine-readable copyright
  metadata, and package-file checksums.
- Stop redundantly declaring unversioned Essential Debian dependencies while
  retaining explicit application/runtime requirements.

### Qualification and maintainability

- Deduplicate the DEB/RPM upgrade runtime-preservation snapshot and assertion
  helpers into one shared test library while keeping APT/dpkg and DNF/RPM
  lifecycle orchestration independent.
- Qualify Debian install, remove, purge, remove-to-purge, reinstall, and upgrade
  paths with explicit per-user runtime preservation assertions.
- Add Lintian error gating for the built DEB, stronger package-identity and
  diagnostic checks, deterministic fixture cleanup, and stricter staging-path
  validation.

## 2.2.4 - 2026-08-27

### Filesystem safety and reliability

- Harden active private aria2 staging cleanup so a different directory that
  replaces the transaction-owned staging pathname is preserved instead of
  being recursively deleted.
- Reuse the conservative private-staging ownership validation for active EXIT
  cleanup, keeping ambiguous or foreign contents intact.

### Qualification

- Add deterministic fault-injection coverage that replaces the active staging
  pathname before EXIT cleanup and proves that foreign replacement contents
  survive.
- Verify that valid transaction-owned staging still cleans normally and that
  existing crash recovery, process-group supervision, private aria2 rollback,
  progress, runtime, packaging and cleanup suites remain green.

## 2.2.3 - 2026-08-27

### Security and reliability

- Keep media URLs containing URI userinfo on yt-dlp's native transport instead
  of replaying those embedded credentials through wrapper-managed aria2.
- Compare external version components and FFprobe durations without entering
  unbounded decimal strings into fixed-width Bash arithmetic.
- Harden private aria2 publication rollback and reject invalid Unicode
  surrogates without raw Python tracebacks.
- Preserve valid progress records that follow an oversized log record.

### Qualification and diagnostics

- Add userinfo, huge-decimal, oversized-progress and private-publication
  failure-path regressions while strengthening real-tool mutation diagnostics.
- Clarify retained HLS intermediate, classifier and result-file failures.
- Keep race-sensitive process-group scenarios under repeated stress without
  adding hot-path synchronization or changing transfer concurrency.
- Harden release/package/shfmt qualification trust boundaries, bind the required
  stress gate to every stress family, authenticate the Fedora RPM Fusion
  bootstrap, hash-pin reproducible yt-dlp wheels and isolate event concurrency.
- Use all available public-runner CPUs for the verified FFmpeg 9 source build
  without introducing executable dependency caches into the release trust path.
- Bind scheduled/manual shfmt automation to the immutable main run revision,
  scope handoffs per run, sandbox the candidate formatter without network access
  and defer project-code execution until the fresh verifier accepts the patch.

### Documentation

- Align direct-header routing, private aria2 clean-restart behavior, managed EJS
  behavior and bilingual downloader documentation with the implemented policy.
- Reject metadata-parseable clean truncation by checking that the required
  A/V packet timeline reaches the declared container tail, while tolerating
  legitimate audio/video duration skew and avoiding a full-file decode.

## 2.2.2 - 2026-08-26

### Security and reliability

- Keep wrapper-managed direct aria2 downloads behind a strict replay-safe
  HTTP-header allowlist. Credential-bearing, Referer, proxy-authorization and
  arbitrary custom headers now remain on yt-dlp's native transport instead of
  being replayed by aria2 across redirects.
- Require FFprobe `V:0` content video for complete-video validation so an
  attached picture, thumbnail or cover art cannot satisfy the video-stream
  requirement.
- Run each `tests/run-all.sh` suite in its own process-group/session boundary
  and terminate the complete group on HUP, INT or TERM, including descendants
  and bounded SIGKILL fallback.
- Validate and canonicalize runtime lock/network timeout integers before Bash
  arithmetic or use by `flock`, `curl` or `timeout`, preventing fixed-width
  arithmetic overflow from bypassing configured bounds.

### Qualification

- Add a real two-origin aria2 redirect qualification with an unsafe mutation
  proving Authorization/Cookie cross-origin replay when the protection is
  removed.
- Add audio-plus-cover-art rejection coverage for complete-video FFprobe
  validation.
- Add standalone and nested INT/TERM process-tree qualification for
  `tests/run-all.sh`.
- Add oversized-decimal rejection tests for every configurable runtime
  lock/network timeout bound.
- Keep the complete static, ShellCheck, mock, packaging, runtime, aria2 and
  progress validation suite green.

## 2.2.1 - 2026-08-25

### Reliability and progress

- Recover abandoned private aria2 staging after a non-interceptable crash only
  when ownership, permissions, location and file structure are unambiguous;
  preserve ambiguous, symlinked or foreign candidates instead of deleting them.
- Restore meaningful Zenity progress after the 2.2.0 private direct-transfer
  change by carrying the exact direct transfer count, keeping one aria2 queue
  item active at a time while preserving per-item split connections, and
  ignoring yt-dlp `MetadataParser` pre-process hooks as final post-processing.
- Add regression coverage for the real Fedora/Zenity progress failure observed
  after 2.2.0.

### Qualification and metadata

- Add a real aria2 loopback matrix for exact `Referer`, `Cookie`,
  `Authorization`, multiple-header and redirect fidelity, with aria2 argv/output
  privacy assertions and a dropped-Authorization mutation test.
- Freeze historical RPM changelog versions at 2.1.20, 2.1.24 and 2.1.25 so
  future package builds cannot rewrite release history through `%{version}`.
- Mark `QUALIFICATION_2.2.0.md` explicitly as a historical pre-release plan and
  add a concise post-release verification note based on the immutable public
  2.2.0 release.

## 2.2.0 - 2026-08-24

### Direct-transfer privacy and publication hardening

- Replace yt-dlp's external aria2 direct-transfer handoff with a private
  PLAN/build/commit/POST pipeline for direct HTTP(S), keeping media URLs and
  request headers out of `aria2c` process arguments.
- Keep DASH/HLS on yt-dlp's native downloader and make wrapper-managed aria2
  cancellation privacy-first: private staging and partial state are removed,
  so a later direct HTTP(S) run starts cleanly instead of resuming the cancelled
  aria2 transfer.
- Preserve the final destination path component without resolving a final
  symlink, reject malformed URLs and non-string HTTP header values, and make
  multi-component publication rollback inode-aware and conservative.
- Require Python 3.10 or newer for the private aria2 planning helper and package
  it as a non-executable private implementation file.

### Qualification hardening

- Pin FFmpeg source-release verification to the expected primary signing
  fingerprint and reject near-prefix FFmpeg/FFprobe version mismatches.
- Update real aria2 qualification to cover private argv, cancellation cleanup,
  and clean restart semantics rather than persistent aria2 resume state.

## 2.1.35 - 2026-08-23

- Isolate untrusted shfmt update candidates in a read-only qualification job and keep repository write permissions in a clean publication-only job.
- Add regression coverage for the shfmt updater privilege boundary and document the formatter-update trust model.

## 2.1.34 - 2026-08-23

- Support canonical shell-inventory validation from Git-free source archives and qualify the extracted release archive during package CI.
- Pin and verify the upstream shfmt toolchain, enforce the canonical four-space shell format in `run-all.sh`, and add automated stable-release update pull requests.
- Add real-tool regression coverage for audio files with attached cover art, and ensure
  the suite detects a `V:0` to `v:0` validation regression.
- Normalize the headers of every canonical shell script and enforce the shared format in static validation.
- Strengthen project-version coherence checks and remove release validation dependencies on versioned comment headers.
- Normalize permanent shell comments around rationale-first production notes and durable test labels, removing patch-specific comment history and redundant version assertions.

## 2.1.33 - 2026-08-23

- Harden aria2 resume qualification by waiting for explicit server quiescence before strict-remainder accounting.
- Enforce audio-only final validation in audio mode while allowing attached cover art.
- Retain the repaired HLS intermediate until final media validation and result publication succeed.

## 2.1.32 - 2026-08-22

### Real-tool audio qualification

- Add a generated WebM/Opus audio-only fixture and prove that audio mode keeps
  the Opus codec, removes video, publishes a validated result, and crosses the
  real aria2c boundary.
- Exercise the `ba/b` fallback with a combined A/V source and prove that the
  final result is audio-only while preserving its AAC codec when no transcode
  is required.
- Add a temporary forced-MP3 engine mutation and prove that the Opus
  codec-preservation assertion rejects it without modifying production source.

### aria2 direct-transfer qualification

- Add a hermetic loopback server for Range, no-Range, redirect, deterministic
  HTTP error, and interrupted-transfer resume behavior using the real engine,
  yt-dlp, aria2c, FFmpeg, FFprobe, and progress monitor.
- Prove resume from server observations rather than final success alone: the
  interrupted run publishes no result/global 100%, a completed Range is retained,
  and the restart transfers a strict remainder rather than the complete object.
- Repeat Range/no-Range/redirect/error three times and resume ten times for each
  pinned/current-stable qualification job and before release packaging.

### Documentation and release metadata

- Document the expanded real-tool audio and direct-transfer qualification in
  English/French documentation and TESTING.md.
- Bump current release declarations and examples to 2.1.32. Production
  downloader routing, HLS duration guard, progress behavior, and aria2 tuning
  remain unchanged.

## 2.1.31 - 2026-08-22

### HLS post-remux validation

- Reject a wrapper-remuxed HLS MKV when FFmpeg exits successfully but FFprobe
  shows a material duration loss versus the repaired HLS source. The guard uses
  metadata only, permits a bounded 2% timestamp/remux tolerance with a 0.5 s
  floor and 5 s ceiling, and retains the repaired source for diagnosis instead
  of performing a costly full decode.
- Add a real FFmpeg/FFprobe regression fixture reproducing the truncated-input
  false-success boundary and a positive complete-input control.

### Real-tool and progress qualification

- Extend hermetic real-tool coverage to direct HTTP, native audio, HLS and DASH
  fixtures generated locally, with a transparent aria2c shim proving the real
  downloader boundary while preserving native DASH/HLS routing.
- Add a real `ffmpeg -nostdin -progress pipe:1` integration that verifies
  parseable progress, monotonic/bounded global progress, FFprobe-valid output,
  and no global 100% before final result publication.
- Repeat deterministic real-tool routing and HLS duration scenarios three times
  in CI and retain a routing mutation check.

### Race and upstream-compatibility CI

- Add bounded deterministic jitter to cancellation/success arbitration, delayed
  PGID publication, worker/FFmpeg startup, and supervisor startup; repeat the
  complete race-sensitive mock suite twenty times.
- Preserve pinned yt-dlp `2026.6.9` and `2026.8.19` PR qualification and add a
  separate weekly job that resolves, logs, and tests the current stable yt-dlp.

### Documentation and release metadata

- Restore English/French prerequisite parity for yt-dlp's bundled `curl_cffi`
  and EJS support.
- Document the current `web_safari` HLS trusted-session limitation symmetrically
  in English and French without adding an automatic PO Token provider.
- Bump user-facing version declarations and release examples to 2.1.31.

## 2.1.30 - 2026-08-22

### Package cleanup and filesystem safety

- Refuse recursive cleanup through symbolic-link components beneath authorized
  XDG roots while preserving ambiguous paths conservatively.
- Extend adversarial cleanup coverage and repeat package-cleanup safety
  qualification ten times in stress CI.

### RPM format and signing qualification

- Explicitly pin generated production RPMs to package format v4 and independently
  verify that format after build and before/after release signing.
- Add a dedicated RPM v6 fixture that qualifies multi-signature ordering,
  multiple valid signers, and corrupted-signature behavior; repeat the
  qualification three times in package PR CI and three times in release CI.
- Make the secret-bearing `rpm-sign` job verify the signed result through an
  isolated RPM 6 `fs` keyring matching the consumer trust model.
- Shorten signing-secret lifetime by removing materialized key/passphrase files
  as soon as possible, clearing secret environment variables, and explicitly
  terminating the temporary `gpg-agent`.

### Release provenance and CI hardening

- Bind manual `workflow_dispatch` recovery to the exact requested tag ref and
  source commit, and remove stale version-specific workflow help text.
- Make workflow shell blocks pass `actionlint`/ShellCheck without suppressing
  the new checks, including explicit absence checks under `set -e`.
- Add a separate read-only post-publication job that freshly downloads the
  immutable public release, compares all assets byte-for-byte with the exact
  tested Actions artifacts, rechecks `SHA256SUMS`, and verifies release/asset
  provenance against the exact tag commit.
- Add a maintainer preflight for Immutable Releases, `rpm-signing` reviewer
  identity, explicit single-maintainer self-approval policy, tag deployment
  policy, signing-secret scope, pinned certificate identity, and signing-subkey
  expiry.

### Documentation and release metadata

- Correct the Fedora bootstrap documentation to describe the private RPM 6
  filesystem keyring rather than RPM display metadata as the authorization
  primitive.
- Document RPM-v4 production pinning, RPM-v6 qualification, exact-tag manual
  recovery, fresh public-release verification, and parent-symlink cleanup
  refusal in English and French.
- Bump current package/install/verification examples and user-facing version
  declarations to 2.1.30.

## 2.1.29 - 2026-08-21

### RPM signer authorization hardening

- Bind Fedora release authentication to the exact OscarFrog certificate and
  dedicated signing subkey `1F5B769CE48A08AAC0A7D9DDECC9894B41830245` instead of accepting any
  key already trusted by the host RPM database.
- Verify release RPMs against a private RPM 6 filesystem keyring containing
  only the pinned certificate, with key storage and transaction locking
  redirected away from the host RPM database; retain DNF
  `localpkg_gpgcheck=True` as a second transaction-time verification layer.
- Make release signing select the dedicated signing subkey explicitly,
  require exactly one usable signing subkey with the pinned full fingerprint,
  and cryptographically verify the signed result before publication; RPM's
  display-only long Key ID is not used for authorization.
- Validate that the repository public key contains exactly one expected primary
  certificate and the required usable signing subkey.
- Add a Fedora release regression test that deliberately trusts a different
  ephemeral key globally, resigns a copy of the release RPM with it, and proves
  the production bootstrap rejects that wrong signer.

### Package cleanup data safety

- Add a private per-runtime ownership sentinel binding application ID, UID,
  HOME, and the effective custom `XDG_DATA_HOME`.
- Require a single-line custom-XDG marker plus its matching regular `0600`
  sentinel before package final-removal may clean a custom data root.
- Add adversarial cleanup tests for forged and multi-line markers, symlinked
  sentinels, unavailable homes, and terminal runtime symlinks.
- Preserve pre-2.1.29 custom roots conservatively when no 2.1.29 ownership
  sentinel has ever been recorded.

### Documentation and release operations

- Add tables of contents to both English and French READMEs and to TESTING.md.
- Document the exact RPM trust bootstrap, `rpm-signing` GitHub Environment
  hardening, post-release signer verification, and signing-key
  rotation/revocation procedure.
- Bump all user-facing version declarations and installation examples to
  2.1.29.

## 2.1.28 - 2026-08-21

### RPM OpenPGP release signing

- Sign the exact Fedora release RPM in an isolated `rpm-signing` GitHub
  Environment after build and before any release-package qualification.
- Keep the signing job free of repository checkout, verify the expected primary
  OpenPGP fingerprint, use only the dedicated signing secret/subkey, and publish
  only the signed RPM artifact.
- Make `install-fedora.sh` reject unsigned release RPMs by default, pin and
  import the OscarFrog RPM public signing key, verify the RPM with `rpmkeys`,
  and enable DNF `localpkg_gpgcheck=True`.
- Retain an explicit `--allow-unsigned-dev` path solely for local and pull-request
  development builds; package CI proves the normal release path fails closed.
- Publish and attest the public RPM signing key alongside the RPM, DEB, ZIP,
  Fedora bootstrap, and `SHA256SUMS`.

## 2.1.27 - 2026-08-21

### Package uninstall cleanup

- Clean the managed per-user yt-dlp/Deno runtime on final DEB or RPM package
  removal while preserving it during package upgrades.
- Run non-root home cleanup under the owning UID/GID and remove only an
  explicit allowlist of managed runtime and exact legacy
  `yt-dlp-aria2-downloader-gui` XDG paths.
- Preserve the portable ZIP/Git launcher and unrelated similarly named files.
- Record the effective `XDG_DATA_HOME` prospectively so later package removal
  can find custom runtime locations without a filesystem-wide search.
- Add DEB maintainer scripts, an RPM final-erase `%preun`, package payload
  checks, and integration coverage for final-removal cleanup.

## 2.1.26 - 2026-08-21

### Release qualification closure

- Qualify RPM and DEB upgrades in both pull-request package CI and the release
  workflow from the exact package bytes published by the previous immutable
  GitHub release instead of rebuilding the previous version from source.
- Verify the previous release's immutable state, SHA-256 integrity,
  release-asset identity, SLSA provenance, signer workflow, source repository,
  and exact source commit before using its packages in upgrade tests.
- Verify that a deterministic archive snapshot of the per-user managed-runtime
  tree remains unchanged across previous-package installation, package upgrade,
  and final package removal.
- Fail explicitly if cleanup of an unexpectedly mutable newly-created release
  fails or cannot be confirmed.
- Repeat the runtime-manager hardening integration suite ten times in stress CI
  in addition to the existing ten-pass process/cancellation stress suite.
- Correct the yt-dlp version used during 2.1.25 release qualification to
  2026.08.19 and complete French documentation parity for the authenticated
  YouTube HLS fallback.
- Tighten release and testing documentation so that only successfully executed
  immutable-release and attestation checks are described as qualification
  evidence.

## 2.1.25 - 2026-08-21

### Release-grade hardening and audit closure

- Add a strict zero-network managed-runtime mode: `YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE=0`
  now validates already-installed runtimes only and never bootstraps them.
- Resolve exact yt-dlp and Deno release tags before downloading assets, removing
  the multi-request `latest` race while retaining signed yt-dlp manifests and
  Deno release checksums.
- Add bounded validation for downloaded/cached runtime executables, safer private
  runtime directories, distinct lock-path versus contention statuses, and an
  activation journal that repairs `current`/`previous` after interrupted updates.
- Add stable -> nightly -> stable, double rollback, unsafe/missing previous,
  journal recovery, ten-cycle lock contention, strict-offline, exact-tag, and
  lock-FD isolation integration tests.
- Build the release RPM once and test the exact same artifact in Fedora `fresh`
  and `ffmpeg-free` scenarios; add true v2.1.24 -> v2.1.25 RPM and DEB upgrades
  plus deterministic reinstall lifecycle checks.
- Test both the minimum supported yt-dlp 2026.06.09 and the then-current stable
  yt-dlp 2026.08.19 with real yt-dlp/aria2c/FFmpeg/FFprobe integration.
- Add a ten-pass concurrency/cancellation stress workflow.
- Require exact existing-release asset inventory, GitHub Immutable Releases,
  release-attestation verification, and `gh release verify-asset` for every
  published artifact; document consumer-side attestation verification.

## 2.1.24 - 2026-08-20

### Runtime reliability and DEB requalification

- Fix YouTube extraction when the verified managed Deno runtime is not present
  in the system PATH; pass the managed absolute path directly to yt-dlp.
- Default managed yt-dlp to the signed stable release channel while retaining
  an explicit nightly opt-in through `YTDLP_ARIA2_YTDLP_CHANNEL=nightly`.
- Bound runtime lock waits, curl connection/transfer/retry time, and Deno update
  checks; keep read-only runtime lookups independent of the update lock.
- Prevent long-running child processes from inheriting the runtime update lock
  and add verified rollback to the previous yt-dlp or Deno runtime.
- Add `YTDLP_ARIA2_MANAGED_RUNTIME_UPDATE=0` for launches that must use already
  verified runtimes without performing update checks.
- Validate Fedora RPM name, version, and architecture before any privileged DNF
  transaction.
- Realign the Debian package with the managed-runtime architecture: remove
  system yt-dlp/Deno dependencies, declare curl/GnuPG/unzip, restore DEB
  lifecycle CI, and publish DEB release artifacts again.
- Add hermetic runtime-manager regression tests for lock contention, offline
  fallback, rollback, timeout options, lock-FD inheritance, and aarch64 asset
  mapping, plus the exact managed-Deno-outside-PATH regression test.
- Re-run Fedora fresh and ffmpeg-free bootstrap qualification on the exact
  release tag before publication.

## 2.1.23 - 2026-08-20

### Runtime and Fedora installation hardening

- Add a Fedora bootstrap installer that enables RPM Fusion Free, replaces
  `ffmpeg-free` with the full RPM Fusion `ffmpeg`, installs required system
  dependencies, installs the application RPM, and validates the resulting
  environment.
- Add a per-user managed runtime for yt-dlp and Deno. Every launch checks for
  yt-dlp nightly and Deno stable updates, stages updates separately, validates
  them, and only then switches the active runtime atomically.
- Verify yt-dlp downloads against the upstream signed SHA-256 manifest and use
  Deno's official checksum-verified upgrade mechanism.
- Keep the last verified runtime when an update check fails, allowing continued
  use during upstream or network outages.
- Prevent collection URLs from silently downloading multiple entries by
  rejecting playlist-indexed entries.
- Reduce native HLS/DASH fragment concurrency to one for reliability while
  retaining aria2c multi-connection acceleration for direct transfers.
- Use the official yt-dlp executable's bundled EJS support instead of allowing
  runtime EJS downloads.

## 2.1.22 - 2026-08-20

### GUI version display

- Show the current application version in the Zenity dialog titles.
- Keep `download-video.sh --version` as the single source of truth for the GUI-displayed version.
- Retain the 2.1.21 packaging policy: qualified Fedora RPM and portable ZIP publication, with DEB publication suspended.

## 2.1.21 - 2026-08-20

### Release qualification, packaging, and progress

- Express the engine's minimum yt-dlp and aria2 versions in DEB and RPM metadata.
- Keep the DEB tooling and strict dependency metadata in-tree, but suspend DEB publication because the currently available Debian 13 backports binary is below the secure yt-dlp minimum.
- Direct Debian and Ubuntu users to the portable ZIP or Git installation while their supported repositories remain below the required yt-dlp version.
- Publish only the qualified RPM, portable ZIP, and shared SHA256SUMS assets for 2.1.21.
- Make package lifecycle tests reject missing or weakened minimum-version dependencies.
- Gate release publication on the hermetic real-tool integration suite.
- Weight multiple aria2 direct transfers by parsed byte counters when their sizes are available.
- Add regression coverage for strongly asymmetric aria2 stream sizes.

## 2.1.20 - 2026-08-02

### Security, correctness, and stable-release qualification

- Keep GUI-entered URLs out of GUI, engine, and yt-dlp command-line arguments by using private URL and batch files.
- Reject URLs containing embedded user information and redact URL-like values from retained failure logs.
- Bound retained logs to the last 8 MiB and reject symbolic-link state/config directories.
- Require both a video and an audio stream before publishing a complete-video result.
- Make Deno conditional for generic extraction while retaining the required minimum for YouTube extraction.
- Restrict remote EJS activation to YouTube and provide a strict opt-out environment variable.
- Add explicit network retry and socket-timeout policy.
- Add `-nostdin` and measured FFmpeg remux progress through `-progress`.
- Harden progress arithmetic against oversized and overflowing counters.
- Remove stale application-owned temporary files after acquiring the exclusive destination lock.
- Declare yt-dlp and all mandatory runtime commands as package dependencies.
- Verify every package-owned file is removed during DEB and RPM lifecycle tests.
- Install the dedicated application icon for ZIP and Git per-user installations.
- Add hermetic real-tool integration tests with locally generated media and a local HTTP server.
- Add GitHub artifact provenance attestations to the release workflow.

## 2.1.19 - 2026-08-01

### Package usability

- Add a prominent RPM/DEB/ZIP installation chooser near the top of both README
  files.
- State explicitly that RPM and DEB installations create the graphical menu
  launcher automatically and must not run the per-user `install-gui.sh` helper.
- Add package removal commands and clarify migration from older ZIP or Git
  installations.
- Install a dedicated application icon in the Freedesktop hicolor theme and
  reference it from the system desktop entry.
- Add the hicolor icon-theme runtime dependency to RPM and DEB metadata.
- Install and remove the generated DEB and RPM with their native package
  managers in both package-validation and release workflows.
- Verify commands, version output, desktop entry, icon, and complete application
  file cleanup during package lifecycle tests.

## 2.1.18 - 2026-08-01

### Native packages and release automation

- Add architecture-independent Fedora RPM and Debian DEB packages.
- Install stable CLI and GUI commands plus a system desktop entry.
- Build and validate packages in dedicated Ubuntu and Fedora CI jobs.
- Publish the tested RPM, DEB, portable ZIP, and a shared SHA256SUMS file for
  every release tag.
- Keep release write permission restricted to the final publication job.
- Add a common install-tree implementation and package-layout integration tests.
- Remove the obsolete screenshot files from the repository and release ZIP.
- Document package installation, upgrades from source installations, runtime
  dependency limits, and the portable ZIP fallback in English and French.

## 2.1.17 - 2026-08-01

### Urgent compatibility hotfix

- Accept aria2 capability lines that include a short-option alias, notably
  `-n, --no-netrc`.
- Treat netrc disabling as an optional aria2 build capability and pass
  `--no-netrc=true` only when the installed build advertises it.
- Add regression coverage for both the real short-alias help format and builds
  compiled without optional netrc support.
- Update English and French documentation to describe the conditional policy.

## 2.1.16 - 2026-08-01

### Reliability

- Supervise both yt-dlp and the wrapper-managed HLS FFmpeg remux with one
  reusable bounded command supervisor.
- Reuse the GUI process session instead of creating a nested yt-dlp session,
  keeping every descendant reachable during emergency shutdown.
- Preserve the real exit status of commands that fail before PGID observation.
- Validate the final audio or video stream with FFprobe before publishing a
  successful result.
- Use no-target-directory moves for no-clobber result and MKV publication.
- Prevent aria2c from reading credentials from a personal `.netrc` file.
- Give the progress monitor the canonical destination directory so its final
  100 percent contract matches the engine and GUI validation.
- Remove all embedded screenshots from the English and French README files and
  replace them with theme-independent procedural descriptions.

### Tests

- Add immediate-worker-failure, FFprobe-rejection, FFmpeg signal-forwarding,
  single-session GUI, and canonical progress-result coverage.

## 2.1.15 - 2026-08-01

### Security and data integrity

- Disable inherited yt-dlp plugins and keep personal yt-dlp configuration
  ignored for deterministic execution.
- Refuse to overwrite completed media files and post-processed outputs while
  retaining interrupted `.part` resume support.
- Run yt-dlp in a dedicated process group and relay CLI HUP, INT, and TERM
  signals to yt-dlp, aria2c, FFmpeg, Deno, and their descendants.
- Create destination locks under a validated private XDG runtime directory,
  with a restrictive `/tmp` fallback and `umask 077`.

### Reliability and portability

- Bound output-template title and identifier fields by encoded byte length for
  long Unicode filenames.
- Ignore relative XDG configuration and state paths and fall back to the
  standard locations under HOME.
- Record the final HLS MKV path before deleting the repaired intermediate.
- Pin Ubuntu validation to 24.04 and add bounded APT retries.

### Validation and documentation

- Add regression tests for existing-media preservation, CLI-only signal
  delivery, plugin isolation, runtime-lock permissions, byte-bounded output
  templates, and relative XDG paths.
- Update both README files and the testing guide for the new policies.

## 2.1.14 - 2026-08-01

### Security and data safety

- Replace untrusted yt-dlp format identifiers with opaque internal progress
  keys and reject malformed records containing extra protocol delimiters.
- Canonicalize every reported final media path and require it to remain inside
  the selected destination before remuxing, deleting, or publishing it.
- Publish machine result files without overwriting a destination that appears
  concurrently.
- Bound unterminated progress records to prevent unbounded monitor memory use.
- Check `ffprobe` explicitly alongside FFmpeg.
- Prevent concurrent engine instances from writing into the same canonical
  destination directory.
- Keep the worker process-group identifier until every descendant has exited,
  even if the direct `setsid` supervisor terminates first.
- Restrict integration-suite root cleanup to the Bash process that created
  it, preventing timeout or asynchronous shell copies from deleting the
  complete workspace during later scenarios.

### CI and release

- Run push validation only on `main` while retaining pull-request validation,
  avoiding duplicate branch and pull-request jobs for the same change.
- Refuse to publish a release tag whose commit is not reachable from
  `origin/main`.

## 2.1.13 - 2026-07-31

### Interface and progress

- Increase the profile-selection dialog to 620 by 305 pixels and the progress
  dialog width to 700 pixels.
- Keep every percentage sent to Zenity monotonic during webpage analysis,
  unknown-size transfers, and long post-processing operations.

### Reliability and data safety

- Read the progress log directly and preserve partial records, eliminating the
  asynchronous reader pipeline and preventing busy loops at end of input.
- Refuse to overwrite an existing machine result file or a pre-existing final
  HLS MKV, and emit symmetric remux completion/error records.
- Bound GUI worker shutdown, protect procfs and PGID reads against races,
  validate that reported results remain inside the selected destination, and
  surface technical progress-monitor failures.
- Strengthen integration tests with bounded process waits, fragmented-record
  coverage, result-collision checks, and deterministic monotonic-progress
  assertions.
- Isolate the procfs visibility probe from the suite cleanup trap so a
  terminated probe cannot remove the complete integration-test root.

## 2.1.12 - 2026-07-29

### Unified download progress

- Add structured `yt-dlp` planning and progress records with format identifiers,
  byte counts, estimated sizes, and fragment counters.
- Aggregate separate video and audio transfers instead of treating each local
  100% value as completion of the whole operation.
- Preserve `aria2c` console progress as a fallback for direct transfers and use
  a bounded animated state whenever no reliable total size is available.
- Represent merge, remux, extraction, metadata, and final verification as
  explicit phases; 100% is emitted only after the atomic result file exists and
  the worker has exited.

### Authenticated YouTube HLS fallback

- Add an explicit video-only profile that reads Firefox cookies and selects
  `web_safari` HLS formats for YouTube sessions affected by sign-in checks or
  GVS HTTP 403 responses.
- Keep ordinary video, native-audio, and non-YouTube behavior unchanged.
- Let yt-dlp repair MPEG-TS-in-MP4 HLS output before a separate stream-copy MKV
  remux, preventing unknown-timestamp failures in FFmpeg's Matroska muxer.
- Ignore the native HLS bootstrap record reported as 100% at fragment 0/N.
- Validate the selected URL, persist the GUI profile, and cover the exact
  yt-dlp and FFmpeg argument vectors with integration tests.

### Validation

- Add dedicated progress-monitor integration scenarios for direct files, native
  downloads, HLS, DASH, composite streams, post-processing, unknown sizes, late
  output, and failure paths.
- Keep the existing GUI cancellation and process-group tests as regression
  coverage for interrupted downloads.

### Review hardening

- Normalize the final `after_move` path record to one verified regular file and
  reject stale, empty, or missing result targets before publishing GUI success.
- End the progress monitor cleanly when Zenity closes its input pipe and surface
  state-directory or temporary-log initialization failures in the graphical UI.
- Make release re-runs verify existing assets without overwriting them, validate
  semantic version tags strictly, and align Fedora CI timeout diagnostics with
  Ubuntu.

## 2.1.11 - 2026-07-29

### GUI and installer fixes

- Preserve the download worker's exit status when the retained log viewer is
  closed, and avoid displaying a failed download as 100% complete.
- Save GUI preferences transactionally, parse progress percentages explicitly
  as base 10, and relaunch the GUI through Bash when requested.
- Resolve scripts invoked as `bash script.sh` from the current directory.
- Allow uninstall from XDG paths rejected for desktop-entry generation, publish
  the desktop file with `mv -T`, and report launcher-link read failures clearly.

### Test reliability

- Normalize expected exit statuses as decimal values in the assertion helpers
  and isolate split-stream commands from the test harness shell.
- Reject missing or empty canonical file lists before running ShellCheck.
- Replace brittle comment-presence assertions with behavioral coverage.
- Improve integration-test dependency diagnostics, asynchronous `gio` polling,
  interrupted-worker cleanup, and hostile newline-path coverage.

## 2.1.10 - 2026-07-28

### Runtime robustness

- Publish result paths atomically only after a successful yt-dlp run and remove
  stale result files before starting.
- Recover the worker process group through `/proc` when PGID-file publication is
  delayed, and terminate the complete worker tree on startup failure.
- Resolve the cancellation/completion race, treat zombie supervisors as
  completed, verify actual process-group signal delivery, keep `setsid --wait`
  alive for graceful reaping, and force-stop it after the final `KILL` fallback.
- Exit the progress producer explicitly when Zenity closes its pipe, so
  cancellation cannot remain blocked in a synchronous Bash pipeline.
- Use real newlines in Zenity error dialogs.
- Handle configuration files without a final newline and ignore only the partial
  first record of oversized progress logs.
- Remove retained diagnostic logs older than 15 days when the graphical
  interface starts.

### Installer and validation

- Reject occupied non-symlink launcher paths, verify the published link target,
  report skipped optional desktop validation, and normalize validation failures.
- Remove known stale installer artifacts during uninstall and validate all
  required installer commands explicitly.
- Separate product failures from test-harness errors, distinguish grep failures,
  verify command invocability, and centralize the project shell-file lists.

## 2.1.9 - 2026-07-27

### Process lifecycle and progress

- Publish the worker process-group identifier atomically before the GUI reads it.
- Keep retrying transient or incomplete PGID reads instead of accepting a
  partial numeric value.
- Protect the cleanup critical section from repeated termination signals while
  preserving the original exit status.
- Display aria2c transfer speed even when the server does not report a total
  size or percentage.

### Desktop launcher

- Install a stable private launcher link so project paths containing Desktop
  Entry field-code characters remain usable.
- Apply the two required Desktop Entry escaping layers to the stable `Exec`
  path and reject XDG data paths that cannot be represented portably.
- Improve `desktop-file-validate` diagnostics while preserving an existing
  launcher after validation failure.
- Reject relative `XDG_DATA_HOME` values and clean up the stable launcher link
  during uninstall.

### Test reliability

- Avoid changing the caller's `errexit` state inside assertion helpers.
- Add exact-line assertions, readable-file checks, and explicit argument-count
  diagnostics.
- Verify option/value adjacency, locale stabilization, aria2c progress without
  a percentage, and additional engine and GUI error paths.
- Expand installer coverage for hostile project paths, exact `Exec` escaping,
  permissions, validation failures, reinstallations, and missing GUI scripts.

## 2.1.8 - 2026-07-27

### Argument parsing and diagnostics

- Unified positional-URL handling before and after `--`.
- Accept a harmless terminal `--` and reject duplicate URLs consistently.
- Distinguish unparseable runtime versions from versions that are too old.
- Use stable profile-label constants and report directory-resolution failures.

### Tests and continuous integration

- Added a shared `tests/run-all.sh` entry point for local, Ubuntu, Fedora, and
  release validation.
- Added reusable assertion helpers with named failure diagnostics.
- Made retained-log tests independent of scenario order.
- Added coverage for suffixed yt-dlp versions and separator edge cases.
- Added manual workflow dispatch for CI and release recovery.

### Installer and releases

- Removed the unnecessary MIME database refresh for a launcher without
  `MimeType` associations.
- Made repeated launcher removal messages accurate.
- Verified that a release tag resolves to the checked-out commit.
- Extracted and ran the complete validation suite from the final ZIP before
  publishing it.

### Documentation

- State the GNU/Linux-only platform requirement explicitly.
- Explain that yt-dlp-ejs components may be downloaded from npm and executed by
  Deno with restricted permissions.

## 2.1.7 - 2026-07-27

### Diagnostics and interface

- Delete the private download log after a successful run only when the final
  media file can be confirmed.
- Retain logs for failed, canceled, interrupted, or inconsistent runs.
- Keep graphical progress monotonic after yt-dlp enters post-processing.
- Read the last non-empty result path defensively when yt-dlp writes more than
  one `after_move` record.

### Installer and release safety

- Generate, validate, and replace the `.desktop` launcher atomically.
- Require the release workflow's validation job to succeed before publishing
  the ZIP archive and checksum.
- Verify script, README, and changelog versions before creating a release.

### Documentation and tests

- Clarify that native audio is preserved whenever possible, rather than
  promising that FFmpeg will never be required.
- Add integration coverage for successful-log deletion, failed-log retention,
  monotonic post-processing progress, and launcher temporary-file cleanup.

## 2.1.6 - 2026-07-27

### Post-review maintenance

- Trimmed accidental leading and trailing whitespace from URLs entered in the
  graphical interface.
- Replaced the premature final progress message with a neutral finalization
  message until the worker exit status is known.
- Added a French localized description to the generated `.desktop` launcher.
- Consolidated version-specific notes into this changelog and replaced the
  dated validation report with reusable testing documentation.
- Added GitHub Actions validation in a Fedora 44 container.
- Added tag-driven release automation for a versioned ZIP and `SHA256SUMS`.

### English localization

- Translated all Markdown documentation into English.
- Translated all Zenity labels, messages, and completion actions into English.
- Translated the application launcher's `.desktop` description into English.
- Translated the remaining French comments and integration-test expectations.
- Replaced hard-coded French directory fallbacks with XDG user-directory
  detection and English fallback paths.
- Updated the project version to 2.1.6.

### Validation

- Updated integration assertions for the English graphical interface.
- Retained Bash syntax checks, ShellCheck validation, mock integration tests,
  and launcher installation tests.

## 2.1.5 - 2026-07-25

### Locale stabilization

- Ran `yt-dlp --version` with `LC_ALL=C`.
- Ran `yt-dlp --help` with `LC_ALL=C`.
- Ran `deno --version` with `LC_ALL=C`.
- Ran `aria2c --version` with `LC_ALL=C`.
- Ran `aria2c --help=#all` with `LC_ALL=C`.
- Ran `setsid --help` with `LC_ALL=C`.
- Kept `LC_ALL=C` on the download worker to stabilize actual `yt-dlp` and
  aria2c progress output.

### Tests

- Added static checks preventing regressions in the six stabilized probes.
- Kept validation of the worker launch with
  `LC_ALL=C setsid --fork --wait`.

## 2.1.4 - 2026-07-25

### Interface

- Added a **New download** button after a successful download.
- The button restarts the interface at the URL entry step.
- The last destination folder and profile remain saved.

### Application launcher

- Replaced `Categories=AudioVideo;Network;` with `Categories=AudioVideo;`.
- Removed the warning about multiple main categories.

### Tests

- Updated the launcher integration test.
- Added validation for the **New download** button.

## 2.1.3 - 2026-07-25

### aria2c compatibility

- Fixed a false capability failure on Fedora's aria2c help syntax such as
  `--no-conf[=true|false]`. The parser now recognizes bracketed optional
  arguments in addition to `=VALUE`, whitespace, and end-of-line forms.
- Forced the aria2c version/help probes to use `LC_ALL=C` for stable parsing.
- Updated the integration mock to reproduce the real aria2c 1.37 help format.

### Interface

- Replaced literal `\n` sequences in the download-failure question with real
  line breaks.

## 2.1.2 - 2026-07-25

### Zenity

- Removed `--ok-label` and `--cancel-label` from directory-selection dialogs.
  Zenity 4 file choosers on Fedora reject these options even though they are
  accepted by other dialog types.
- Kept custom labels on entry and list dialogs, where they are supported.
- Added an integration guard that fails if custom button-label options are ever
  passed to a file-selection dialog again.

## 2.1.1 - 2026-07-25

### Zenity

- Captured Zenity stderr for unexpected dialog failures and displayed the
  underlying diagnostic instead of only a generic error.
- Added a compatibility fallback for directory selection: when the chooser
  fails with the remembered `--filename` directory, retry once without an
  initial directory.
- Added an integration test that simulates a `--filename`-specific Zenity
  failure and verifies the successful fallback.

## 2.1.0 - 2026-07-25

### Audio

- Reused the dedicated `download-audio.sh` selection strategy for audio mode:
  `ba/b`, `--extract-audio`, `--audio-format best`, and `--audio-quality 0`.
- Removed the public `--audio-format` and `--audio-quality` CLI options so the
  application no longer forces MP3, M4A, Opus, or another conversion format.
- Preserved the best source audio codec/container whenever possible.

### Interface

- Reduced the profile selector to exactly two entries: complete MKV video or
  native-format audio track.
- Migrated saved `audio-mp3`, `audio-m4a`, and `audio-opus` profiles to the new
  single `audio` profile.

### Tests and documentation

- Updated integration tests to require `ba/b`, `--audio-format best`, and
  `--audio-quality 0` while rejecting forced MP3/M4A/Opus values.
- Updated CLI validation, README files, and release validation notes.

## 2.0.4 - 2026-07-24

### Tests

- Added local `ffmpeg` and `ffprobe` mocks to the integration test so it no
  longer depends on executables installed on the host.
- Added assertions that both media tools resolve to the private mock directory.
- Replaced the remaining single-quoted French strings containing Unicode
  apostrophes in the test assertions.

### Static analysis

- Initialized `URL`, `PROFILE`, and `OUTPUT_DIR` before the Zenity selection
  loops to make their data flow explicit and avoid the SC2153 false positive.

## 2.0.3 - 2026-07-24

- Fixed the warnings and optional diagnostics reported by
  `shellcheck -o all` on the three production scripts.
- Removed reliance on `errexit` inside functions used as conditions by
  capturing expected statuses explicitly.
- Replaced process substitutions used for version discovery with checked
  command substitutions.
- Added explicit default branches to configuration and profile `case`
  statements.
- Replaced typographic apostrophes in single-quoted shell strings with
  double-quoted literal strings.
- Made Zenity error dialogs best-effort with a stderr fallback.
- Strengthened yt-dlp and aria2c capability checks so option names must appear
  as option definitions, not merely inside descriptive text.
- Configured CI to run ShellCheck optional checks on production scripts.

## 2.0.2 - 2026-07-24

- Raised the minimum yt-dlp version to 2026.06.09, which contains the security
  fix relevant to aria2c-backed downloads.
- Added an aria2c 1.37.0 minimum-version check and negative integration test.
- Added integration tests for Zenity progress timeout and unexpected progress
  errors, including process-group termination verification.
- Extended local syntax validation to every shipped Bash script.
- Preserved conventional signal exit codes: 129 for HUP, 130 for INT, and 143
  for TERM.
- Pinned actions/checkout v7.0.1 to its full commit SHA, disabled persisted
  credentials, and added a CI timeout.

## 2.0.1 - 2026-07-24

- Confirmed that the reported concatenated lines were display artifacts; all
  shipped Bash files pass syntax validation.
- Added minimum-version checks for yt-dlp 2025.11.12 and Deno 2.3.0.
- Added runtime capability checks for required yt-dlp and aria2c options.
- Distinguished Zenity cancellation, timeout, validation failure, and internal
  errors in all selection dialogs.
- Added integration coverage for dependency and Zenity failure paths.

## 2.0.0 - 2026-07-24

- Added the Zenity interface.
- Added destination-folder selection.
- Added MKV video, MP3 audio, M4A audio, and Opus audio profiles.
- Added atomic persistence of the last profile and destination folder.
- Added structured `yt-dlp` progress and fallback `aria2c` progress.
- Added private, unique logs.
- Added complete process-group cancellation.
- Added a `.desktop` launcher installer.
- Added static tests, mocked-command tests, and continuous integration.
- Added the `--output-dir`, `--mode`, `--audio-format`, `--audio-quality`,
  `--machine-progress`, and `--result-file` CLI options.
- Isolated user configurations with `--ignore-config` for `yt-dlp` and
  `--no-conf=true` for `aria2c`.

## 1.1.0 - 2026-07-22

- Initial MKV video engine using `yt-dlp` and `aria2c`.
