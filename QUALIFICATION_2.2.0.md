# Qualification plan for 2.2.0

> **Historical qualification document.** This file preserves the pre-release
> qualification plan and wording used while 2.2.0 was being prepared. Statements
> such as `pre-release`, `pending`, and `publication remains gated` below describe
> that historical phase; they are not the current release status.
>
> **Post-release verification — 2026-08-25.** GitHub reports release `v2.2.0`
> as published at `2026-08-24T21:28:11Z` and immutable. The release tag resolves
> to source commit `e4ea92e196564211bbd6847877cbc3bc41ae1ae8`. The published
> release exposes the versioned RPM, DEB and ZIP together with `install-fedora.sh`,
> `SHA256SUMS`, and `RPM-GPG-KEY-OscarFrog`. This post-release note does not
> retroactively mark individual pre-release gates below as executed when their
> operator evidence is not reproduced in this document.

Status: **pre-release remediation and qualification**.

The initial qualification-only patch did not change the functional download
engine. Real Fedora 44 qualification then reproduced a blocking privacy defect:
yt-dlp's aria2 integration exposed direct media URLs in `aria2c` process
arguments. This branch now contains the functional remediation and regression
coverage for that finding. The product version is now 2.2.0 for the release
candidate. Publication remains gated on the qualification and release-evidence
requirements below.

Base required for this plan:

```text
v2.1.35
4d94f95a3ab170cc25b27885f90325b70ba3bd40
```

The SHA above is the peeled commit (`git rev-parse 'v2.1.35^{commit}'`), not
the object ID of the annotated tag itself.

## Gate IMP-001 — real Zenity on Fedora and Ubuntu

Use a real graphical session; do not replace Zenity with a mock.

Run every scenario on **Fedora 44** and **Ubuntu 24.04**:

```bash
./tests/zenity-real-session-qualification.sh success
./tests/zenity-real-session-qualification.sh error
./tests/zenity-real-session-qualification.sh cancel-transfer
./tests/zenity-real-session-qualification.sh cancel-ffmpeg
./tests/zenity-real-session-qualification.sh cancel-success-race
./tests/zenity-real-session-qualification.sh new-download
./tests/zenity-real-session-qualification.sh open-folder
```

Repeat `cancel-success-race` 10 times per distribution.

Acceptance criteria:

- no false success;
- no false failure after a valid completed result;
- no blocked GUI flow;
- no new yt-dlp/aria2c/FFmpeg/FFprobe/Deno/download worker left after exit;
- no sensitive URL detected in relevant external argv or retained state;
- equivalent user-visible behavior on Fedora 44 and Ubuntu 24.04.

The existing progress-monitor and real-tool tests remain responsible for the
machine-checked invariant that global 100 appears only after a valid result is
published. The real-Zenity protocol checks that the actual graphical session
preserves the expected user-visible lifecycle.

## Gate IMP-002 — FFmpeg/FFprobe 6.1.1, 8.1.2 and 9.0.1

`.github/workflows/qualification.yml` qualifies three explicit generations:

| Environment | Expected FFmpeg/FFprobe |
|---|---|
| Ubuntu 24.04 package | 6.1.1 |
| Fedora 44 + RPM Fusion | 8.1.2 |
| verified upstream source build | 9.0.1 |

The FFmpeg 9.0.1 source tarball is verified with the official FFmpeg release
signing key before compilation. The expected primary fingerprint is:

```text
FCF986EA15E6E293A5644F10B4322F04D67658D8
```

Each generation reuses the same project semantics:

- real yt-dlp/aria2/FFmpeg/FFprobe local-media routing, 3 runs;
- real FFmpeg progress, internally 3 runs;
- HLS post-remux duration guard, 3 runs;
- multi-stream stream-copy preservation;
- VFR stream-copy frame/duration preservation;
- FFmpeg process-group cancellation.

A generation mismatch is a hard failure. Do not silently substitute another
major/minor FFmpeg generation for the named gate.

## Gate IMP-003 — yt-dlp intermediary security boundary

The normal real-tools matrix now contains:

```text
2026.6.9   minimum project baseline
2026.7.4   intermediary advisory boundary
2026.8.19  stable observed during the v2.1.35 audit
```

The scheduled job continues to install the current stable yt-dlp at execution
time. This patch does not raise the project minimum above 2026.6.9.

## Gate IMP-004 — executed release and schedule evidence

For the audited baseline, run:

```bash
./scripts/release-evidence-qualification.sh \
  v2.1.35 \
  4d94f95a3ab170cc25b27885f90325b70ba3bd40 \
  qualification-evidence/release-v2.1.35.md
```

The command fails unless it can prove all of the following from GitHub:

- exact local tag commit;
- public release exists and is immutable;
- expected ZIP/RPM/DEB/bootstrap/key/checksum inventory;
- downloaded asset inventory matches the public inventory;
- `SHA256SUMS` verifies;
- `gh release verify-asset` passes for every public asset;
- `gh attestation verify` passes for every public asset using the exact source
  digest and `.github/workflows/release.yml` as signer workflow;
- a successful `release.yml` run exists for the exact source SHA;
- a recent successful scheduled `real-tools.yml` run exists;
- a recent successful scheduled `shfmt-update.yml` run exists.

The default schedule freshness window is 14 days. Override only with an
explicitly justified value:

```bash
MAX_SCHEDULE_AGE_DAYS=21 \
  ./scripts/release-evidence-qualification.sh TAG SHA REPORT
```

## Static and regression validation

After applying the patch:

```bash
git diff --check
bash -n tests/ffmpeg-generation-compatibility.sh
bash -n tests/ffmpeg-generation-qualification.sh
bash -n tests/zenity-real-session-qualification.sh
bash -n scripts/release-evidence-qualification.sh
./tests/run-all.sh
```

Also run `actionlint` on all workflows and execute both `real-tools.yml` and
`qualification.yml` through GitHub Actions.

## Promotion to the actual 2.2.0 release

Only after IMP-001 through IMP-004 are green:

1. create a finding identifier for every newly reproduced defect, if any;
2. add a red regression test before changing functional code;
3. apply the smallest functional fix necessary;
4. rerun neighboring invariants, stress tests, packaging and real-tool matrices;
5. update all authoritative version declarations to `2.2.0`;
6. add the real release date to `CHANGELOG.md`;
7. tag the exact qualified commit;
8. run the existing release workflow;
9. rerun `scripts/release-evidence-qualification.sh` against `v2.2.0` and the
   final tag SHA with `REQUIRE_EXTENDED_QUALIFICATION=true`;
10. only then issue the final GO/NO-GO report.

No failure from these gates is to be reclassified as success or hidden by a
version bump, skipped test, relaxed assertion, or broad functional refactor.

## Qualification finding — aria2c direct-transfer URL exposure

Status: **FIXED LOCALLY / RELEASE QUALIFICATION PENDING**

During the Fedora 44 real-Zenity `cancel-transfer` qualification,
the harness repeatedly observed the active direct-transfer URL in
the process arguments of `aria2c`.

Evidence:

- scenario: `cancel-transfer`
- GUI exit status: `130` (expected user cancellation)
- harness exit status: `65`
- offending process: `aria2c`
- residual download processes: none
- finding reproduced continuously for several seconds

Root cause:

yt-dlp's `Aria2cFD` passes the direct media URL to aria2c as a
command-line positional argument. Therefore an HTTP/HTTPS media URL,
including any query tokens or signed parameters, is observable through
the process argument list while aria2c is running.

Release gate:

v2.2.0 MUST NOT be released unless the direct-transfer remediation remains
green in static, mock, real-tool, real-aria2 and real-Zenity qualification.

Implemented remediation:

- yt-dlp first creates a private `0600` plan without downloading media;
- direct HTTP(S) media URLs and headers are validated by
  `private-aria2-plan.py` and written to a private aria2 input file;
- aria2 receives only private file/directory paths in argv, never the media URL;
- the staging directory is `0700`, transfer metadata is `0600`, and completed
  components are published with no-overwrite hard links;
- aria2 diagnostics are URL-redacted before reaching CLI/GUI logs;
- HLS/DASH remain on yt-dlp's native downloader.

Functional consequence:

Wrapper-managed direct HTTP(S) aria2 state is deliberately private and
ephemeral. A normal user cancellation removes that staging state, so a later
run starts the direct transfer cleanly instead of resuming the cancelled aria2
partial. Native yt-dlp downloaders retain their own upstream resume semantics.
The user documentation and real-aria2 regression contract must describe this
behavior explicitly.
