# Testing

This document describes the repeatable validation procedure for the current
project. It is intentionally independent of a particular release date.

## Contents

- [Codex session setup and task routing](#codex-session-setup-and-task-routing)
- [Python changes](#python-changes)
- [Workflow syntax qualification](#workflow-syntax-qualification)
- [Environment diagnosis](#environment-diagnosis)
- [Complete local test suite](#complete-local-test-suite)
- [Fast feedback, timing and concurrency](#fast-feedback-timing-and-concurrency)
- [Version coherence and release preparation](#version-coherence-and-release-preparation)
- [Shell formatting](#shell-formatting)
- [Bash syntax](#bash-syntax)
- [ShellCheck](#shellcheck)
- [Covered behavior](#covered-behavior)
- [GitHub Actions](#github-actions)
- [Controlled real Zenity qualification](#controlled-real-zenity-qualification)
- [Shared-destination and process qualification](#shared-destination-and-process-qualification)
- [Release maintainer preflight](#release-maintainer-preflight)
- [Post-release evidence qualification](#post-release-evidence-qualification)
- [Real-world checks on Fedora 44](#real-world-checks-on-fedora-44)
- [Locale-stabilized probes](#locale-stabilized-probes)
- [Stress validation](#stress-validation)
- [Network destination qualification](#network-destination-regression-and-opt-in-cifs-qualification)

## Codex session setup and task routing

Open this repository itself as the Codex project, or start the CLI with
`codex --cd /absolute/path/to/yt-dlp-aria2-downloader-gui`. Starting from a parent
directory does not automatically discover a child repository's instructions,
skills or trusted rules. A later shell `cd` is not proof of loading them.
For a fresh session, confirm the checkout with `./scripts/git-inspect.sh summary`
and inspect `status` before editing. Preserve existing changes.

`AGENTS.md` supplies persistent repository guidance; the full documents it
links are read on demand. Codex discovers global guidance first, then the
project-to-working-directory chain, preferring `AGENTS.override.md` over
`AGENTS.md` in each directory. The default combined budget is 32 KiB.
Project `.codex/rules` requires a trusted, active project configuration layer.
Skills under `.agents/skills` are discovered upward from the startup directory,
not by scanning unrelated child repositories. Their descriptions are loaded
before their full instructions. See the official
[instruction discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md),
[rules](https://learn.chatgpt.com/docs/agent-configuration/rules) and
[skills](https://learn.chatgpt.com/docs/build-skills) documentation.

The three repository skills are `shell-change`, `packaging-release` and
`workflow-supply-chain`. Check their presence in the session's skill list; if
absent, read the paths routed by `AGENTS.md` and correct the next session's
startup directory. Static skill checks validate their file structure, not the
active Codex runtime. Likewise, `codex execpolicy check --rules FILE -- ARGV...`
tests a supplied policy without executing ARGV; it does not prove automatic
loading. Static validation parses the repository's literal `prefix_rule` subset
without executing it, including when the Codex CLI is absent; the optional CLI
check additionally validates actual Codex matching semantics. Include active
global rules when auditing combined decisions. Never
dump configuration, historical rules or session logs without redaction.

Choose focused tests from this table; `tests/run-all.sh --list` and
`tests/mock-integration.sh --list-groups` are the authoritative accepted names.
Paths in the first two columns are entry points: follow their actual callers
and imports when the change crosses a boundary.

| Task | Start with | Focused validation |
| --- | --- | --- |
| Engine, formats or transports | `ARCHITECTURE.md` engine/transport sections; `download-video.sh`, `private-aria2-plan.py` | `./tests/mock-integration.sh --group engine`; private aria2 plan and auth-header suites |
| Network destination or private state | Same engine/helper boundary; network section below | `./tests/mock-integration.sh --group engine-network`; `./tests/private-aria2-plan-integration.sh`; opt-in real-tools/network qualification |
| GUI, progress or cancellation | GUI/progress sections; `download-video-gui.sh`, `progress-monitor.sh` | `./tests/mock-integration.sh --group gui`; progress-monitor suite; `--group signals` when supervision changes |
| Managed runtimes | Managed-runtimes section; `runtime-manager.sh` | Runtime-manager and runtime-manager-hardening suites; mocks `--group runtime` |
| Launcher/install/cleanup | Entrypoints/packaging sections; `install-gui.sh`, `private-launcher-manager.py`, `packaging/` | Installer and package-user-cleanup suites; lifecycle/upgrade qualification as applicable |
| Versioning/contributor guards | Version section below; `scripts/check-push-version.py`, `.githooks/pre-push` | `python3 -B scripts/check-push-version.py coherence`; `python3 -B tests/push-version-integration.py` |
| Workflows, packages or release | CI/release trust zones; matching skill and full affected workflow | `./scripts/check-workflows.sh` for workflows; `./test-static.sh`; applicable packaging or release qualification below |
| Documentation or inventories | Both READMEs, relevant source of truth, `REPOSITORY_FILES.md` | `./test-static.sh`; inspect links in installed documentation as well as GitHub |

Run cheap coherence, syntax and formatting checks before focused integration.
Use `--fast --jobs 4` for broader development feedback and `--full --jobs 4`
for final review, after failures are diagnosed. Both profiles include the same
static checks; running fast immediately before full is not an extra environment
qualification. Reuse a successful doctor diagnosis while its environment stays
unchanged. A sandbox-denied loopback bind requires an authorized environment
change, not repeated identical test runs. External GitHub reads still need
their own authorized network access; a hermetic full pass does not check live
release-tag availability.

A task prompt only needs the problem, current/expected behavior, observable
acceptance criteria, task-specific constraints and the requested delivery
authority. Repository conventions and normal tests need not be repeated:

```text
Problem: ...
Current behavior / reproduction: ...
Expected result and acceptance criteria: ...
Task-specific constraints: ... (or none)
Delivery: local changes only / commit / push a PR / other explicit authority.
```

## Python changes

The production minimum is Python 3.10 with standard-library dependencies. Read
the helper's entry point, imports and Bash callers; review stdout/stderr and
exit-status contracts, bounded parsing, subprocess groups/timeouts, private
paths, descriptor ownership and cleanup after exceptions/signals. Keep private
values out of errors, process arguments and test artifacts. Choose behavioral
tests from the route table, including the Bash side when applicable.

`test-static.sh` validates every `PYTHON_FILES` module's SPDX/docstring identity
and parses it with Python 3.10's grammar. This detects newer syntax but does not
prove runtime/API compatibility with Python 3.10. The existing Bash integration
suites and stdlib `unittest` tests are the test entry points; no pytest, Ruff or
type-checker configuration is currently a project requirement. Compilation or
typing alone cannot establish exception, subprocess or cancellation behavior.
The `shell.yml` job **Python 3.10 / Ubuntu** selects the real minimum interpreter,
asserts its minor version, and runs doctor plus the full contract together with
GNU Bash 4.4.0. The Bash source archive is verified by fixed SHA-256 and the
exact upstream maintainer signature before building. Both absolute and PATH
lookups are bound and checked only on the disposable GitHub-hosted runner. This job is
additional qualification; its addition does not change remote required-check
settings.

The paired minimum-interpreter job allows eight minutes for the complete
four-worker suite, within its unchanged ten-minute job budget. This aggregate
budget includes every static and integration task; it is separate from the
individual signal, shutdown and fixture deadlines, which remain unchanged.
Ubuntu allows seven minutes for its complete suite; Fedora retains five.
Every wrapper retains TERM followed by KILL after ten seconds. The Ubuntu
budget includes headroom for the measured workload: a complete remote Git-free
Ubuntu run took 299.487 seconds, while a checkout run reached the former
300-second boundary with 35 successful verdicts and two suites still progressing.
The complete measurement plus a 25% allowance, rounded up to whole minutes,
gives 420 seconds. Git-free and checkout environments are distinct; this budget
does not attribute historical delays to unmeasured load. The ten-minute job cap,
four-worker schedule and every individual fixture deadline remain unchanged.

The Ubuntu `Run validation` step also records bounded passive diagnostics for
its current execution. `scripts/ci-validation-diagnostics.py` reads aggregate
resource counters and allowlisted progress from the GUI-state and packaging
logs. The runner consumes its optional private rendezvous before starting
sub-suites, so nested runners cannot overwrite that handoff. Reading an already
opened log through its final drain preserves observations across ordinary
cleanup without preventing cleanup or changing supervision. Raw log contents,
process arguments and environments are not exported by this diagnostic.

Missing or denied observations remain explicit. A nonzero validation status,
including timeout 124, is preserved; missing diagnostic evidence must not turn
into a successful qualification. Compare monotonic observations within their
actual run and keep earlier failures distinct from later successful executions.
The diagnostic's tests run in the canonical CI-validation integration suite.
Its reader has a separate finite 450-second, 451-sample ceiling, allowing
collection after the seven-minute command and its termination grace period.

Some Linux fixtures deliberately use `/usr/bin/python3` or a restricted system
PATH. After installing distribution dependencies, the disposable minimum-Python
CI runner binds that path to its selected Python 3.10 and asserts both lookup
forms before validation. Selecting only the driver's PATH would leave those
helpers running the distribution's newer interpreter. This adjustment belongs
only to the disposable qualification environment; do not replace the system
Python on a user's workstation. Equivalent local containers must expose Python
3.10 through both paths and run as a non-root user, matching the ordinary CI
user rather than UID 0 with its capabilities removed.

## Workflow syntax qualification

For workflow edits, run the explicit shared validator before full validation:

```bash
./scripts/check-workflows.sh
```

It requires installed actionlint at the exact version in
`scripts/dev-tools/actionlint-pin.env` and ShellCheck. Missing tools or a
mismatched version return 69; invalid workflows return the linter's failure
status. The check never installs or downloads tools. It validates every YAML
workflow and its embedded shell; optional Pyflakes integration stays disabled
because it is not a project dependency.

The required Ubuntu CI job provisions the reviewed Linux archive, checks its
SHA-256 before extracting the executable, and invokes this same script before
the canonical suite. Use that bounded bootstrap procedure when preparing a
local tool, adjusting the reviewed architecture pin if necessary. Merely
matching a version string is not authentication of newly downloaded bytes.
Local fast/full profiles retain their existing dependency contract, so record
this additional command explicitly when changing workflows. A new pin requires
review of the upstream release and archive digests, not only a computed hash.

## Version coherence and release preparation

Ordinary commits, source pushes and PR merges may keep the same coherent
version, including the latest published version. Contributor follow-ups and
formatter/documentation automation do not force a PATCH increment. Source
qualification identifies an exact tree and commit, not just a version number.

Explicit release preparation chooses the target for the changes grouped since
the relevant release. Keep an unpublished target through follow-up corrections
unless the scope calls for a different version. Freeze the final version before
qualifying the candidate to tag; changed contents require the corresponding
new validation. Never reuse a published tag/version/assets for different bytes.

| Version surface | Contract |
| --- | --- |
| `download-video.sh` → `VERSION` | Coherent source version; ordinary development may retain a published number |
| `install-fedora.sh` → `APP_VERSION`; `test-static.sh` → `EXPECTED_VERSION` | Must equal the source version |
| Development paragraph and manual release commands in both READMEs; leading versioned CHANGELOG and RPM `%changelog` entries | Must identify the same source version |
| RPM `%{project_version}`, DEB/ZIP builders | Derive/validate the requested package version against the engine |
| `EXPECTED_PUBLISHED_VERSION` and README asset references | Describe the latest immutable published version; advance them only after that release exists and has passed the post-publication verification |
| Signed `vX.Y.Z` tag and release preflight | Separately authorized identity, qualified contents and publication prerequisites |

Check local coherence before expensive validation, without Git or network:

```bash
python3 -B scripts/check-push-version.py coherence
```

For an authorized source push, also use the live remote check:

```bash
python3 -B scripts/check-push-version.py check
```

Defaults are `origin` and the current branch; `--remote NAME --branch DESTINATION`
selects another named destination. The check validates coherence and the remote
reference snapshot; no larger version than main, a working branch or a published
tag is required. It neither edits files nor fetches, commits, pushes or tags.
Connection or malformed-reference failures remain failures. The hook inspects
regular Git blobs of the actual pushed commits as data, never candidate code.

Automation uses the following read-only context command:

```bash
python3 -B scripts/check-push-version.py source-context --branch automation/EXACT-BRANCH
```

It binds main, target, current source version and the reference-catalogue SHA-256. Prepare and independent
verify jobs retain this source version. Privileged publishers revalidate the
allowlisted patch and remote identities as data; they execute no candidate
helper. No-op updates create no branch or artificial version entry.

For explicit release planning only:

```bash
python3 -B scripts/check-push-version.py next-version --branch PREPARATION-BRANCH
```

This suggests a PATCH from numeric release tags while
retaining an already newer main version. A working branch's largest version is
not a mandatory increment. This recommendation does not determine the change
scope or authorize publication. The maintainer chooses PATCH/MINOR/MAJOR for
the accumulated changes and verifies the relevant release baseline.

The offline `scripts/prepare-source-version.py` helper prepares the seven
source carriers from an explicitly verified published-version floor, date and
reason, with `--target-version` for an explicit choice. Repeating preparation
of the same unpublished target is a no-op. A leading `## Unreleased` changelog
section is promoted into the chosen target with its accumulated notes. The helper preserves published
references and file modes, stages replacements and backups, and rolls back
controlled failures. It is for isolated source trees, not concurrent writers
or a crash-atomic multi-file transaction. It deliberately preserves
`EXPECTED_PUBLISHED_VERSION` and the README asset references: until immutable
publication completes, they continue to describe the previous published
release. After the complete release workflow succeeds,
`scripts/update-published-version.py` performs the separately reviewed
post-publication alignment. The signed-tag release preflight remains mandatory.

Enable the additional Git guard once per checkout. First inspect the existing
effective `core.hooksPath` and `pre-push` hook; do not overwrite another hook or
redirect an existing hook setup without preserving its behavior. In a checkout
with no custom hook configuration or pre-push hook, activate this tracked path:

```bash
git config --local core.hooksPath .githooks
```

`.githooks/pre-push` checks the actual commit IDs Git intends to send. Coherent
working-tree edits cannot repair incoherent committed version carriers. It refuses the whole
push before updating remote refs if any source update fails. Pure deletions,
tag-only pushes and no-ops require no source-coherence check. Git tag/release authority
remains separate. Do not use `--no-verify` or alternate hooks paths to skip this
policy. Git does not automatically enable tracked hooks in a fresh clone: repeat
the inspected setup there. This is a local guard, not a GitHub server rule;
remote CI and branch protection remain necessary, including for concurrent
remote changes and writes from clients without this hook.

The hook requires Git, Bash and Python 3.10+, a simple configured remote name
such as `origin`, one identical fetch/push URL and a remote main branch. Split
URLs, multiple push URLs and raw-URL push invocations fail explicitly instead of
checking another repository. The checker avoids copying remote URLs into its
Git subprocess arguments or echoing raw Git errors. Remote reads have a
twenty-second deadline; interruption stops the current Git process group.

Run the behavioral qualification without contacting GitHub:

```bash
python3 -B tests/push-version-integration.py
```

It uses disposable bare repositories and real Git pushes: successive same-version
pushes, unchanged unpublished PR targets, incoherent committed metadata despite
uncommitted repairs, release-tag planning, remote errors and races, split URLs,
data-only parsing, batch rejection, deletions, no-ops, process timeout cleanup,
all seven source carriers, idempotent release preparation, write failures,
interruption and rollback. `test-static.sh` includes it in
both canonical profiles; it explicitly skips Git-dependent cases if Git is
absent from a Git-free source-validation environment. Installed RPM/DEB payloads
do not include these contributor tools; source archives contain them.

The automation handoffs have separate behavioral replays, also called by static
validation:

```bash
python3 -B tests/shfmt-version-handoff-integration.py
python3 -B tests/release-docs-integration.py
```

The shfmt replay uses real disposable Git repositories and the pinned formatter,
with controlled upstream and container stubs. It covers unchanged-version preparation,
independent verification, altered bytes, incomplete manifests, no-op runs and
branch creation races. A coherent replacement patch with unchanged version and
complete but stale tested-tree digests must fail the actual publisher checksum
step. The release-docs replay executes the actual publisher
shell and inline Python against a simulated API, including large streamed blobs,
fast-forward updates, concurrent refs, ambiguous responses and substituted
paths; preparation no-op uses real Git. Missing Git (and jq for release-docs)
is an explicit skip in archive environments. Canonical shell CI installs both tools.
These tests do not dispatch workflows or establish that GitHub publication ran.

`tests/ci-validation-integration.py` includes independent business oracles for
the mandatory RPM v4/v6 signature qualification step and the release signer's
private-primary-key guard. The latter replays the real workflow shell with fake
GPG/RPM commands: only the contract's `#` primary state reaches `rpmsign`; empty,
malformed and private-material-present states must be refused. No real secret
is used. Removing each protection in a disposable source copy must turn its
corresponding test red.

Inline Python assertion drivers use isolated, bytecode-disabled execution
(`python3 -I -B`) where compatible. The helper mount-boundary negative and doctor
schema negative are also replayed under `PYTHONOPTIMIZE=1` and `2`, proving that
an unsafe mutant or invalid diagnostic cannot silently pass with assertions
disabled by the caller's environment.

## Environment diagnosis

Inspect whether a new workstation, container, or restricted agent environment
can run the hermetic local contract before choosing a validation profile:

```bash
./tests/run-all.sh --doctor
```

This diagnostic does not run a validation suite, install a dependency, populate
the managed shfmt cache, or modify the repository. It checks required commands,
the Bash 4.4 and Python 3.10 baselines, the pinned shfmt/bootstrap contract,
private temporary-directory semantics, IPv4 loopback binding, and readable
Linux `/proc` process metadata. It also reports optional qualification tools,
selected tool versions through time/output-bounded probes, Git/source-archive
state, and a bounded HTTPS probe to GitHub. Git is required when `.git`
metadata is present. External HTTPS remains optional when an exact verified
shfmt binary is already cached; otherwise both a provisionable cache target
and successful HTTPS probe are required for formatter readiness. Any failed
required capability makes the command exit with status `69`.

For automation, request the versioned JSON schema:

```bash
./tests/run-all.sh --doctor --json
```

The `ready` field is true exactly when no required check failed. Doctor mode is
exclusive: it cannot be combined with `--fast`, `--full`, `--jobs`, or `--list`.
Passing `--json` without `--doctor` is rejected.

## Complete local test suite

Run from the repository root:

```bash
./tests/run-all.sh
```

The default is intentionally the complete hermetic `full` profile with one
integration suite at a time. It is the complete local contract and gives the
most readable live output. A release additionally requires the real-tools,
distribution packaging, external-version and interactive qualification jobs
documented below; `--full` alone does not claim those environments.

## Fast feedback, timing and concurrency

For a shorter development loop, run the static checks and the integration
suites marked as fast:

```bash
./tests/run-all.sh --fast --jobs 4
```

Run the complete contract with up to four independent integration suites in
parallel:

```bash
./tests/run-all.sh --full --jobs 4
```

For unattended Codex inspection of repository state, use the tracked helper:

```bash
./scripts/git-inspect.sh status
./scripts/git-inspect.sh diff-check
```

Its closed action parser also provides `summary`, `log`, `diff`, `diff-staged`,
and `inventory`. `summary` reports branch/commit/tree identity; `log` reports at
most five commit/parent identities and dates without author or message data.
It accepts no caller-provided Git option, revision, path, helper, or output
filename. The helper has no explicit Codex `allow` rule: it runs under the
ordinary sandbox or baseline policy. Direct Git remains interactive under the
repository execution policy.

Every static step and integration suite reports its elapsed time. The read-only
shfmt check, static behavioral validation, and four ShellCheck inventories
share the requested job limit. Parallel output is buffered separately and
printed in canonical manifest order, so completion races do not produce
interleaved logs. The integration manifest starts the latency-dominant signal
and runner suites first. Separate compact start/completion events expose the
already recorded monotonic timestamps and statuses as tasks progress, so an
outer timeout cannot erase the distinction between completed and active tasks.
Detailed suite logs retain their canonical order. The manifest then
staggers CPU-heavy mocks with wait-heavy suites.
The scheduler immediately reuses a slot when any suite finishes; a short suite
therefore cannot leave a worker idle while an unrelated long suite is still
running. Reports and the first nonzero status remain selected in manifest order
rather than completion order.

The Python version, source-archive, CI-proof, automation-handoff and formatter
bootstrap suites are explicit timed tasks in that same bounded static phase,
not serial subprocesses hidden inside the source-assertion task. Both canonical
profiles execute each family exactly once. Standalone `./test-static.sh` keeps
the complete contract; `./test-static.sh --source-only` intentionally omits
these separately scheduled behavioral suites and is not a qualification profile.

Interruption still terminates every supervised validation process group. A
descendant that deliberately creates a new session is outside that
process-group contract. Before signaling, the runner reaps slots whose original
identity has disappeared and authenticates every retained PID/process group
with a child-published Linux start time or a private inherited token. A fatal
signal received before publication uses one state/parent/start-time `/proc`
snapshot of the still-direct launcher instead. A stale numeric PID is therefore
never sufficient signaling authority. The Python session supervisor retains
its token through cancellation until every same-group descendant exits or the
authenticated KILL escalation completes, including when the direct command
removes the token from its own environment and ignores the first signal.

The canonical and repetition executables enable Bash monitor mode to keep
trapped INT on its ordinary handler during foreground-child reaping. The shared
library leaves caller options unchanged. Before starting a command, its Python
supervisor moves from the provisional Bash process group into a dedicated
session with managed signals blocked and the same PID. Group readiness and
signaling require SID to equal PGID as well as the existing identity proof.
Before that transition completes, cancellation signals the authenticated
registered child directly. It does not wait for session readiness or scan for
orphaned group members while that original child still provides authority.
The handoff oracle retains its 0.8-second pending-signal deadline and injects a
slow orphan lookup to prove that unrelated discovery cannot delay delivery to
the known child. Grace-period and final cleanup measurements remain separate.
The runner integration suite qualifies this transition, pending fatal signals,
status/output preservation and rejection of provisional group identity. It
also sends real terminal Ctrl-C during scheduler polling, incomplete identity
handoff and handoff-file removal. It verifies the worker's received INT,
descendant shutdown and cleanup after a second Ctrl-C, including an explicitly
handled poll status 130 under Bash 4.4 and the EXIT path that bypasses Bash’s
ordinary INT trap. Failed or missing scheduler polls must preserve their exact
status and clean active children without consuming a nonexistent completion slot.
The startup stress records monotonic failure time, barrier states and the
fixture parent/child procfs state before watchdog rescue. A timeout remains a
failure even if that rescue succeeds. The GUI progress mock similarly retains
only allowlisted failure categories before removing its private logs; it does
not expose raw requests or replace the original exit status.
Provisional supervision precedes every
foreground command in the registration window. The full-profile signal suite
retains its original time limits; diagnostics also
cover failure to enter the reentrant-signal guard. Its stderr fixture establishes
backpressure with two nonwritable POLLOUT observations after the producer starts
an output larger than the capture pipe. Partial padding writes can exhaust pipe
slots below nominal byte capacity. The identity-checked observation descriptor
is closed before communicate, which must drain every byte and retain status 130;
waiting before draining is rejected. No debugger is required by either profile.
After escalation, the monitor test permits at most one second for an original
descendant with an already pending SIGKILL to become a zombie or disappear.
It authenticates PID/start-time around the signal snapshot and sends no extra
signal; a live descendant without pending SIGKILL fails immediately. This
observes the kernel's asynchronous exit, without changing runner timeouts.

The assembled-output real-tool fixture keeps its 60-second execution deadline,
then allows two bounded 20-second cooperative shutdown waits. The second signal
requests the engine's own authenticated escalation; an unconfirmed shutdown
preserves the fixture directory and remains a failure. Runner integration
qualifies timeout, HUP/INT/TERM, signal registration and preservation using the
actual engine supervision functions. Preservation is established before launch;
a capture error during cleanup keeps both that state and the original failure.
The fixture driver uses isolated Python
so PYTHONOPTIMIZE cannot silently remove its no-overwrite assertions.

Before allocating fixtures, the mock entry point registers its own Bash
process as a Linux child subreaper through an isolated Python `prctl`/`exec`
bootstrap. The PID and signal topology stay unchanged, and Bash harvests
terminated orphan descendants instead of depending on the host or container's
PID 1. This does not terminate live descendants or relax engine quiescence:
after losing its leader, the engine still requires ESRCH or two complete matching
zombie-only inventories with identity revalidation before releasing tracked
resources. Runner integration includes a
non-reaping outer parent, a no-bootstrap negative control, and live-child,
identity and exit-status checks for this fixture lifecycle.

The complete mock contract is divided into nine isolated scheduler suites
(`engine-core`, `engine-hls`, `engine-staging`, `engine-network`, `gui-progress`, `gui-state`,
`signals`, `runtime-compat`, and `runtime-validation`) so `run-all.sh --jobs N`
can schedule its hermetic scenarios concurrently. The `engine`, `gui`, and
`runtime` groups remain convenient aggregates of their respective subgroups,
and running the mock script without an option still executes every scenario in
the historical order. A single group can be targeted while developing:

```bash
./tests/mock-integration.sh --group gui-progress
```

Use `./tests/mock-integration.sh --list-groups` to list the accepted group
names. These groups use independent temporary homes, output directories, and
mock binaries when the top-level runner executes them concurrently.

List the integration manifest and fast-profile membership without running any
validation:

```bash
./tests/run-all.sh --list
```

`YTDLP_ARIA2_TEST_JOBS` supplies the default concurrency when `--jobs` is not
provided. Values are restricted to `1..32`. The fast profile is a developer
convenience, not a substitute for the complete suite before review or release.

Independent stability repetitions use the same bounded process supervision:

```bash
./tests/repeat-qualification.sh \
  --label 'HLS duration iteration' --runs 3 --jobs 3 -- \
  bash ./tests/hls-remux-duration-integration.sh
```

Each repetition receives an isolated log and its output is replayed in numeric
order. The first child failure is preserved after every active child has been
reaped. `YTDLP_ARIA2_REPEAT_JOBS` can lower the default concurrency on a small
machine. Use this helper only when repetitions own separate temporary state;
tests that intentionally share one server, lock, or accounting log remain
sequential internally.

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
`tests/run-all.sh` performs the non-mutating check automatically. If the
pinned upstream binary is absent from the local managed tool directory, the
bootstrap downloads the exact GitHub release asset and verifies its SHA-256
before execution.

The scheduled `.github/workflows/shfmt-update.yml` workflow detects a newer
stable upstream release, preserves the source version while
executing the candidate formatter, updates the pin/checksums, reformats all
canonical shell files, runs the complete validation suite, and prepares a
dedicated update branch for a maintainer-opened pull request. Both formatting
and complete validation execute the candidate inside containers without network
or host credentials. The candidate image sets the formatter's mode to `0555`
explicitly: copying it into a private host build context under `umask 077`
must not prevent the non-root container user from executing it. Static mutation
tests protect that mode and each container's non-root execution.
Validation mounts the source read-only and cannot access
the host handoff. The verifier destroys its container before rechecking the
canonical tree and producing the data-only handoff. Canonical comparison uses
the clean immutable source as its baseline; only the pin and canonical shell
files may change, and their source-version declarations must remain unchanged. Only the final publisher receives repository
content write permission; it has no pull-request permission. An existing branch
for the same base and upstream pin is preserved without another source push;
a conflicting branch or raced reference causes refusal instead of replacement.

See `SHELL_STYLE.md` for the complete permanent shell-style contract.

## Bash syntax

The canonical inventory is centralized in `tests/lib/project-files.sh`:

```bash
source ./tests/lib/project-files.sh
for file in "${ALL_SHELL_FILES[@]}"; do
    bash -n -- "${file}"
done
```

`SOURCED_SHELL_FILES` and `NO_ERREXIT_SHELL_FILES` make the permitted startup
option models explicit. `test-static.sh` verifies that those classifications
remain inside the canonical inventory and that every executable begins with an
approved top-level `set` declaration. Installed production and cleanup helpers
target GNU Bash 4.4 or newer. The **Python 3.10 / Ubuntu** job exercises the
full contract with Bash 4.4.0 as well as Python 3.10, including absolute-path
and restricted-PATH fixtures; Ubuntu and Fedora jobs additionally cover their
distribution interpreters. A version string or syntax parse alone is insufficient.

## ShellCheck

```bash
source ./tests/lib/project-files.sh
shellcheck -x -o all -- "${ALL_SHELL_FILES[@]}"
```

ShellCheck is intentionally taken from the supported Ubuntu and Fedora
environments rather than pinned by the repository. The `-o all` contract means
new optional diagnostics become enforced when those environments update; fix
the construct or review an explicit policy change instead of silently retaining
an older warning set.

The mechanically testable parts of the comment contract are enforced by
`test-static.sh` (canonical headers and rejection of historical patch/audit
labels). The quality and accuracy of rationale/API prose remain review
requirements rather than brittle regex policy.

## Covered behavior

The automated suite checks, among other things:

- shell-comment policy: preserve ShellCheck directives and non-obvious
  rationale, use durable `Scenario`, `Mutation test`, `Regression guard`,
  `Negative control`, and `Positive controls` labels in tests, and reject
  permanent `PATCH`/`AUD` labels;
- development-version coherence across active scripts, documentation and
  release-workflow surfaces, plus a separate documentation pin for the exact
  RPM, DEB and ZIP names of the latest published release, while keeping
  historical CHANGELOG entries exempt;
- standardized Bash headers on every canonical shell script, including the canonical interpreter line, an SPDX MIT tag, project name, repository-relative file name and purpose;
- argument validation, terminal `--`, and exactly one URL per run;
- preservation of URLs containing shell metacharacters;
- rejection of raw URL control bytes while preserving Unicode and percent
  escapes; byte-oriented redaction of malformed UTF-8 diagnostic URL tokens;
- graceful-signal deferral during private result-record creation, including
  repeated signals and preservation of a replaced record inode;
- HUP/INT/TERM during staging/remux allocation, permissions, identity, descriptor
  and marker registration, with authenticated cleanup before transport starts
  and conservative preservation after acquisition failures or replacement;
  directory replacement between descriptor open and path-identity capture must
  not grant deletion authority for metadata, media workspaces or aria2 staging;
- preservation of active temporary files and the original requested exit status
  when bounded worker shutdown cannot be confirmed; after admission the engine
  stays alive holding historical and fine reservation FDs until consumers stop,
  including consumers that closed all inherited lock descriptors;
- aria2 diagnostic filters drain the producer's final cancellation message
  before closing, while unexpected redaction failures remain fatal;
- trimming of leading and trailing whitespace entered in the GUI;
- exact GUI YouTube-host classification and false-domain rejection, with exactly
  HLS/Firefox video plus audio for YouTube and complete video plus audio for
  other hosts; one compatible default selection and persistence for each saved
  profile, including missing or invalid preferences;
- unchanged progress messages, percentage, speed and ETA with or without the
  local-storage event; storage diagnostics remain in the log, while the final
  destination-copy phase stays visible;
- native-audio selection with `ba/b`, `best`, and quality `0`;
- absence of forced MP3, M4A, or Opus output formats;
- MKV video selection without forced re-encoding;
- structured yt-dlp planning and progress records, aria2c console fallback,
  exact byte-weighted progress, the bounded 80/20 fallback for an explicit
  two-stream video/audio plan with incomplete totals, monotonic transition
  between those models, fragment progress, unknown-size animation, exact
  private-direct transfer-count preallocation, and protection against
  pre-download `MetadataParser` hooks being misclassified as final post-processing;
- separate video/audio transfers, direct audio, HLS, DASH, merge, remux,
  extraction, late progress, and error paths;
- verification that a local transfer reaching 100% does not complete the global
  operation and that global 100% appears only after final-result publication;
- deletion of successful-download logs and retention of failure logs, with
  shared View log/Close actions for every interactive failure that has a safely
  sanitized diagnostic and fail-closed refusal to open the raw live log;
- preservation of the live log's path and inode while a real producer writes
  after an error snapshot and shutdown remains unconfirmed; the snapshot stays
  separate and sanitized, and confirmed cleanup removes the private session
  without removing the retained snapshot;
- View log/Close handling for bounded pre-session Zenity diagnostics, including
  correct text-viewer content, Close without viewing, private containment, and
  immediate removal after the interaction;
- exact retained-log basename/canonical-path footers, byte-bounded survival of
  that identity after an over-8-MiB source truncation, private atomic
  publication, and refusal to publish a footer-only artificial diagnostic;
- automatic removal of retained diagnostic logs older than 15 days while
  preserving newer logs, unrelated files, and symbolic links;
- atomic process-group publication, bounded cancellation tests, explicit
  progress-pipe closure, termination, and verification that no worker process
  remains after GUI scenarios;
- direct HUP, INT, and TERM delivery to the sole GUI PID while either the URL
  entry or progress dialog is blocked, with exact 129/130/143 statuses, bounded
  Zenity/monitor/worker reaping, and no private temporary path left behind;
- deterministic TERM injection after the worker fork but immediately before
  `WORKER_PID` registration, proving that the launched session leader is still
  registered, terminated, and reaped without leaving private temporary state;
- HUP, INT, and TERM delivered to isolated complete GUI and CLI foreground
  groups while worker PGID publication is blocked, with runtime proof that the
  directly supervised worker has identical PID, PGID, and SID and leaves no
  detached descendant; repeated pre-publication requests retain the first
  status while escalating immediately;
- independent progress-monitor and Zenity statuses across the private
  owner-only FIFO, plus 64 KiB accepted-stdout and in-memory stderr bounds for
  captured dialogs;
- process-group recovery when PGID-file publication is delayed;
- immediate readiness-record unlinking in standalone-PGID and shared-session
  PID paths, including before an uncatchable worker crash;
- authenticated-descriptor publication and failure cleanup of the result-path
  file, including a deterministic temporary-inode replacement mutation;
- rejection of non-sticky shared destination/result ancestors, safe fallback
  from hostile runtime/TMPDIR/XDG roots, acceptance of sticky shared parents,
  and descriptor-first HLS/result publication with no-clobber rename fallback
  when the filesystem does not support hard links;
- parallel independent writers in one canonical destination, and refusal of
  overlapping filename families; legacy exclusive-lock compatibility during
  supervised shutdown, without a guarantee after external SIGKILL removes the
  historical lock holders;
- explicit no-overwrite options and refusal of known final-video/native-audio collisions,
  while preserving authenticated native resumes bound to the full media ID and
  extractor identity; filename truncation, changed extractors and missing
  identity cannot authorize adoption, while signed transfer URLs may refresh;
  these checks do not
  establish atomic local yt-dlp postprocessing against unrelated writers;
- complete staging-inventory admission, including empty/error, partial/error,
  unknown files and a file introduced after acquisition; the last file must
  survive because deletion never rescans for new entries;
- disabling of inherited yt-dlp plugins and personal configuration;
- forwarding of HUP, INT, and TERM sent only to the CLI wrapper PID;
- signal-safe CLI child registration before `$!` is published, plus bounded
  cancellation of managed-runtime preparation with restored asynchronous-child
  signal dispositions, outer ignored dispositions around no-fork `setsid`, a
  post-restoration readiness barrier exercised at the pre-`env` race window,
  immediate repeated-signal escalation, exact 129/130/143 status, and proof of
  the signal received by the runtime manager;
- requested-signal status preservation when a supervised child exits during
  process-group discovery;
- forwarding of termination signals during the wrapper-managed HLS FFmpeg remux;
- preservation of immediate command failure statuses before PGID observation;
- GUI-owned engine wrappers share the outer worker session; runtime and FFprobe
  helpers stay in that SID while pinning their direct child's private SID with
  WNOWAIT through all live subgroups; engine force escalation freezes an
  authenticated target through a pidfd, then checks every thread's stopped
  state, identity and children in two stable inventories before leaf KILL or
  parent CONT;
- FFprobe rejection of missing or structurally invalid expected media streams;
- canonical destination validation before the progress monitor emits 100 percent;
- no-target-directory publication when a destination changes into a directory;
- private XDG runtime locks and fallback permissions;
- byte-bounded Unicode output templates;
- fallback from relative XDG configuration and state paths;
- retention of process-group tracking until quiescence, distinct from permission
  to signal it: a real vanished-leader/live-descendant fixture verifies refusal
  to claim shutdown, preservation of private state and the inherited lock, no
  signal without authority, and cleanup after the descendant actually exits;
- positive zombie-only quiescence without requiring an external reaper: after
  lost leader authority, two complete matching PGID/SID inventories and final
  PID/start/state revalidation are required; live members, changed inventories
  and read/parse/permission errors cannot authorize cleanup;
- Zenity timeout and unexpected-error handling;
- folder-chooser fallback behavior on Zenity 4;
- minimum versions, suffixed yt-dlp versions, required capabilities, and
  behavior under a hostile inherited locale;
- aria2 help lines containing short-option aliases and builds that omit the
  optional netrc capability;
- `.desktop` launcher installation through a stable private link, exact Exec
  escaping, restrictive-path handling, validation, permissions, reinstall, and
  removal, including refusal to mutate through a symbolic-link XDG root,
  parent, terminal, intermediate, or shared-writable directory plus
  ancestor ownership/mode policy before child creation and before publication
  or removal: root/current-user ancestors and sticky shared ancestors are
  accepted, foreign-owned ancestors are refused even without shared write bits,
  and managed leaves retain their stricter policy during revalidation; these
  cases use real paths/permissions and inode-targeted owner metadata fixtures,
  without changing host users or ownership;
  synchronized root and managed-directory replacements after descriptor anchoring
  while preserving victim files and rejecting false success; allocation fault
  cleanup and exact current/legacy stale namespaces are covered, with
  close-name, wrong-type, unknown-content, mount-boundary, and non-UTF-8 path
  cases preserved,
  overlapping install/uninstall transactions must follow a serial order, each
  publication/removal fault must restore the prior three-leaf state, late root
  or executable-target replacement must reject success, lock/validator waits
  and validator output must remain bounded, and cleanup must retain the primary
  failure diagnostic; wrapper-only and foreground-group HUP/INT/TERM must return
  129/130/143 only after validator reaping and rollback, including deterministic
  retained-non-child PID rejection, already-reaped validator-group rejection,
  pre-Python, post-open, post-hardlink, post-publication, post-validator-fork,
  validator-finally, transaction-cleanup, diagnostic-output, and final
  entrypoint-return windows while preserving the first request through a
  flag-only asynchronous handler; an absent managed branch must never redirect
  backup, removal, or rollback operations to same-named working-directory decoys;
- package install-tree layout, stable command symlinks, system desktop entry,
  dedicated hicolor icon, documentation permissions, positive inclusion of the
  native aria2 helper, and exclusion of tests, obsolete images, and the
  portable-only launcher helper;
- Fedora RPM install/upgrade migration of every verified historical per-user
  desktop schema that used `video-x-generic` and masks the system launcher:
  the three strict direct-Exec comment variants (including an exact 302-byte
  fixture) and the later stable-link variant, while preserving portable target
  links and any current, modified, out-of-HOME, symbolic-link, mode-changed,
  or non-regular launcher candidate observed during validation;
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
- root-owned Fedora staging mutation tests that replace the original
  application and RPM Fusion key/package inputs immediately after copying, then
  prove that isolated verification, system key import, and DNF all consume only
  the unchanged staged bytes;
- an independent release-CI negative test that repeats the wrong-signer attack
  against a copy of the actual signed release RPM before publication;
- real build, APT installation, removal, and ownership validation of the DEB on
  Ubuntu 24.04 without system yt-dlp or Deno package dependencies.

- private GUI URL transfer through owner-only URL and yt-dlp batch files, with
  the requested URL absent from GUI, engine, and yt-dlp process arguments;
- conservative preservation of abandoned private aria2 staging after SIGKILL;
  names, markers and legacy fingerprints alone do not authorize its removal.
  Symlink, unknown-entry, invalid-mode and cross-destination negative controls,
  plus active-session
  inode replacement of the plan and post-success replacement of the aria2
  input and manifest so cleanup never removes an ambiguous replacement;
- refusal of pre-existing direct-transfer destinations before aria2 starts,
  with a second no-overwrite check at commit; duplicate staging sources and
  foreign-owner private state are rejected before publication;
- descriptor-bound workspace cleanup rejects directory mount boundaries even
  when `st_dev` is unchanged, including a mounted workspace root. Deterministic
  fdinfo fixtures verify no descent or deletion through such boundaries and
  preservation when mount identity is unavailable or changes between passes;
  these fixtures perform no real mount;
- real-tools refusal of pre-existing ordinary-video MKVs for direct two-stream,
  native HTTP (single and merged streams), HLS and DASH transfers. Repeated runs
  and changed metadata preserve bytes, inode and modification/change timestamps,
  produce no result record and issue no additional media requests. Native final
  preflight also rejects symlinks, directories and replaced destination identity;
- malformed or secret-bearing protocol metadata produces no traceback or raw
  protocol diagnostic, and case-insensitive duplicate header names select
  native transport without rewriting the header values;
- real two-origin aria2 qualification proving that replay-safe direct
  headers can stay on private aria2 while `Referer`, `Cookie`, `Authorization`,
  proxy authorization and non-allowlisted custom headers force native yt-dlp;
- an unsafe helper mutation proving the cross-origin credential-replay risk when
  that native-fallback guard is removed, while protected runs keep secrets out
  of aria2 argv and captured output;
- retained-log URL redaction even when the 8 MiB boundary crosses a
  secret-bearing URL, a strict final retained-size limit including the final
  identity section, no leaked temporary path or partial staging file, and
  private live diagnostics kept under the runtime temporary directory;
- GUI configuration acceptance at the exact 64 KiB and 128-line limits,
  atomic fallback above either limit, and non-blocking replacement of FIFO or
  symbolic-link configuration paths;
- complete-video rejection when either the video or audio stream is absent,
  plus audio-mode rejection when a content-video stream remains in the final file;
- real MP3/ID3 attached-cover qualification proving the combined JSON summary
  sees the attached stream but excludes it from content video, with a temporary
  validator mutant that ignores `attached_pic` and must be killed;
- managed Deno requirements for YouTube extraction and use of the EJS
  components bundled with the managed official yt-dlp runtime, without asking
  the downloader for `--remote-components ejs:npm`;
- measured wrapper-managed FFmpeg remux progress and bounded progress arithmetic;
- a complementary real-FFmpeg `-progress pipe:1` integration, repeated three
  times, proving parseable `out_time_us`, monotone/bounded global progress and
  no global 100% before result-file publication;
- HLS post-remux duration consistency with real FFmpeg/FFprobe, including a
  reproducible truncated-input case where FFmpeg exits 0 with both streams but
  a materially shortened MKV; that result must not be published, and the
  repaired HLS source remains available until global validation/publication
  succeeds; mock replacement of the temporary remux inode proves that the
  creation-time descriptor prevents inode-number reuse from authorizing a
  replacement, failure cleanup cannot remove it, and an identity-changed
  publication is never accepted as an application result;
- hermetic real-tool direct HTTP, AAC/M4A, Opus/WebM, combined-source audio,
  attached-cover audio, HLS and DASH transfers using generated media and loopback HTTP servers, with
  transparent shims proving that real aria2c is used for direct transfers and
  not for HLS/DASH fragments;
- controlled real aria2 Range/no-Range/redirect/error behavior plus
  cancellation and clean restart, with explicit server active-request state
  around the restart/accounting boundary, no premature result-file/global 100%,
  removal of private aria2 staging/partials, and FFprobe-valid finals; native
  yt-dlp `.part` resumption remains available when supported upstream;
- managed-runtime operation with Deno outside PATH, bounded lock/network waits,
  strict zero-network `require` mode, exact-tag stable/nightly/stable switching,
  isolation from personal curl/yt-dlp configuration and yt-dlp plugins, exact
  executable-version binding to the resolved yt-dlp and Deno release tags,
  bounded runtime-probe output and invalid-version diagnostics, rejection of
  malformed timeout settings before external operations, same-repository
  release redirects,
  single-member non-symlink Deno archive extraction, immutable attested paths
  that survive later activation changes, preservation of identical cached
  binaries after transient probes or comparison errors, and verified repair of
  a damaged same-version binary without a rollback target, canonical and
  non-replaceable XDG path chains, independent registry-path validation,
  descriptor/path lock identity, repair of invalid active runtimes
  without a previous target, same-channel downgrade refusal, and a versioned
  engine attestation that avoids duplicate
  path/version/capability discovery, explicit invalid-`path` and
  invalid-`prepare` diagnostics,
  lock-descriptor isolation, repeated contention/double-rollback coverage
  (three cycles in ordinary validation and ten per dedicated stress run),
  interrupted-activation journal recovery, explicit/automatic rollback, and
  x86_64/aarch64 asset mapping.
- runtime bootstrap cleanup on HUP/INT/TERM, including creation/registration
  windows, preservation of the first signal status and replaced inodes, partial
  install recovery, and lock retention until foreground writes and GnuPG cleanup
  finish; SIGKILL and probe-capture residue collection are outside this guarantee.
- package reinstall plus real previous-immutable-release -> current upgrade
  validation for RPM and DEB, using the exact previously published package
  bytes rather than rebuilding the previous version from source;
- preservation of a deterministic archive snapshot of the per-user
  managed-runtime tree across previous package installation and package
  upgrade, followed by allowlisted cleanup on final RPM removal and explicit
  DEB preservation through remove and purge;
- package-cleanup integration coverage for a custom `XDG_DATA_HOME`, exact
  legacy `-gui` paths, preservation of unrelated similarly named files, and
  preservation of a portable ZIP/Git launcher;
- automatic launcher migration skips disabled-login and maintenance shells
  while retaining root, low-UID users, custom homes, and empty or unknown login
  shells; final-erase enumeration retains its existing account coverage;
- adversarial cleanup coverage for forged, multi-line, and oversized
  custom-XDG metadata, symlinked ownership sentinels, missing homes, terminal
  runtime symlinks, overflowing UID/GID text, and refusal of direct root cleanup
  for a non-root HOME;
- refusal to traverse symlinked intermediate cleanup components beneath
  authorized XDG roots, covered once by each full-suite environment;
- explicit production RPM-v4 pinning plus a dedicated RPM-v6 fixture that
  qualifies multi-signature ordering/corruption semantics once in package PR
  CI; the final release signature is independently checked on the signed RPM;
- exact same RPM artifact tested in Fedora `fresh` and `ffmpeg-free`;
- current stable yt-dlp compatibility in addition to the minimum supported
  version;
- exact release asset inventory and immutable-release/asset verification.
- a separate read-only post-publication job that freshly downloads the public
  release and proves byte identity with the tested Actions artifacts, rechecks
  `SHA256SUMS`, and verifies provenance against the exact tag commit.


### Final-validation scope

Container duration and stream presence alone do not establish that media is
complete: physical truncation can preserve both. The real-tool regression
therefore checks a metadata-parseable truncated fixture at publication.

Final publication still checks the expected content-video/audio streams and
retains the HLS-specific duration guard. One bounded FFprobe JSON summary now
supplies stream types, attached-picture dispositions, `start_time` and
`duration`; attached cover art therefore remains distinct from content video.
When finite timeline metadata is available, a second probe seeks near the
declared end and requires the final required A/V timeline to reach within 2% of
that timeline, with a one-second floor. Audio mode requires audio to reach that
boundary. Video mode requires content video and audio structurally and accepts
the tail when either required stream reaches it, so a legitimate longer audio
tail does not turn a valid video into a false truncation. The tail probe reads
packets from a near-tail interval to EOF and is bounded by the same 15-second
deadline; it does not decode the complete media. If finite timeline metadata is
unavailable, the structural validation remains the fallback.

The permanent real-tool regression injects a metadata-parseable physical
truncation immediately before final validation and requires exit 65 with no
published result-file. The mock suite separately qualifies the tail threshold.

Race-sensitive qualification continues to repeat process-group cancellation,
PGID publication, quiescence, and clean-restart scenarios. Every asynchronous
GUI-child launch uses a short signal-registration critical section: the first
HUP, INT, or TERM received before the relevant PIDs are recorded is deferred,
then replayed immediately after registration so cleanup never loses a child.
The mock signal group exercises the worker boundary with the production
registration and cleanup functions in the exact launch-handler-PID-replay
order. A static ordered-source assertion binds that composed regression to
`start_download_worker`; adjacent blocked-entry and blocked-progress scenarios
independently deliver real HUP, INT, and TERM signals. Their outer watchdogs
retain timeout status 124, so a watchdog-delivered TERM cannot impersonate the
original signal. This separation avoids the version-specific semantics of
delivering a signal from inside Bash's `DEBUG` trap while retaining both
behavioral guarantees.

## GitHub Actions

The five qualification workflows run on pull requests, with manual dispatch
available for diagnostics. Each checks event/checkout identity, version
coherence and Bash syntax before its own qualification jobs. `shell.yml`
qualifies Ubuntu 24.04, Fedora 44 and actual Python 3.10; package, real-tool,
FFmpeg and stress work need not wait for that complete shell contract. Root
jobs retain `needs: identity` and downstream package/shard dependencies.
This avoids four allocated runners polling for shell completion and overlaps
independent qualifications. Cheap local failures still stop that workflow's
fan-out, but a later functional failure can occur after other work has started.
The tradeoff improves successful PR latency rather than minimizing work on
every failing PR.

The existing required check **Mock process/cancellation stress (20x deterministic
jitter)** also waits for every complementary shell, package, real-tool and
FFmpeg job. It excludes its own workflow from that API wait: its local `needs`
cover its shards and runtime test, avoiding a self-dependency. All nine required
check names are preserved; no remote ruleset change is necessary. Matrices
cancel remaining entries after a failure, and PR concurrency cancels superseded
revisions. Scheduled current-stable tools remain independent diagnostics.

`promotion.yml` is the only source workflow triggered by `push main`. It checks
qualification identity without running the suites again. `release.yml`
independently requires the same proof before building, even if the main
promotion run was skipped, cancelled or failed. No successful main status,
cache, version string or artifact filename can substitute for source proof.

### Content qualification and promotion

`scripts/ci-validation.py` uses authenticated, read-only GitHub API responses.
Each qualification workflow has a job named `Source identity ${{ github.sha }}`.
GitHub resolves that name from the event; the isolated job checks that checkout
HEAD equals this SHA before any dependent test job. For a PR this is the virtual
merge, while Actions REST `run.head_sha` identifies the branch HEAD. Do not
confuse these identities or infer the tested merge from `head_commit.tree_id`.

Promotion requires one merged PR for the exact squash commit, an ancestor of
canonical main; the five expected workflow IDs/paths and latest PR-head runs;
their latest attempts and complete expected successful job inventories; and
equality of the **entire** qualified and promoted Git trees, including scripts,
workflow definitions, pins, documentation, file modes and test parameters. The
virtual merge parents must be the squash parent and final PR HEAD. This supports
the repository's enforced squash policy and deliberately refuses other merge
shapes or a changed base. A deleted fork, missing Git object, disabled workflow,
unknown/skipped job, pagination overflow, unavailable API or concurrent change
of run/attempt fails closed. The scheduled-only real-tools job is the sole
expected skipped job in PR evidence. GitHub clears some run PR associations
after merge; the verifier uses the authoritative squash-to-PR API relationship
and exact Git parent identities instead.

A historical qualification of immutable content does not expire merely because
time passes. Obsolescence is concrete: changed tree/base/head/parameters,
workflow identity, newer failing or unfinished run, or withdrawn/unavailable
GitHub evidence. Timestamps must remain well formed, non-future and consistent
with the run. Scheduled current-stable diagnostics still detect upstream
movement; release installation, signer checks and previous-release verification
inspect current external inputs independently. Latest run/attempt identities
are re-read before accepting the proof; an older success never masks a newer
pending or failed run. No PR artifact, cache or attestation permission is
introduced. The trust root is GitHub's authenticated run/job records plus
immutable Git objects and the reviewed workflow definition in the equal tree.
This proves what the source passed with the qualification environment; it does
not claim compatibility with every future distribution update.

The latest pinned media job must prove installation of the hash-pinned
impersonation prerequisites before shared-destination qualification. The two
earlier pins must retain an explicitly skipped record for that conditional
step. Missing records, failed installation, a skipped latest-pin installation
or an unexpected execution in the earlier pins are refused. Regression fixtures
model the workflow condition independently of the verifier's obligation tables.

An authorized maintainer can inspect a merged candidate without publishing:

```bash
python3 -I scripts/ci-validation.py verify --commit <full-squash-commit-SHA>
```

Provide `GH_TOKEN` through the environment. Never put it in command arguments.
The command returns the qualified tree, PR number and five run/attempt/source
identities. There is no automatic fallback that runs tests or accepts incomplete
evidence. If a newer attempt fails, explicitly correct the cause or rerun
**all jobs of the original PR workflows** under the normal authority, preserving
event/source identity. Their independent qualifications may run concurrently;
the final required gate still needs the complete successful cohort. Then retry
promotion or release from the exact existing tag. If
original runs/merge objects/fork identities are no longer available, prepare a
new normally qualified PR and a new version/tag under the usual authority.
An old tag predating source-identity jobs cannot use this new proof protocol.
Manual diagnostic dispatch runs do not replace PR evidence.

| Class | Content and place | Reuse |
| --- | --- | --- |
| A | Event/checkout identity, version, syntax; formatting, ShellCheck, static and workflow contracts early in shell CI | Cheap rejection before costly work |
| B | Full hermetic functional suites on Ubuntu/Fedora/Python 3.10 | Once in each complementary environment on PR |
| C | Git-free source, real-tool/pinned versions, FFmpeg generations, signal jitters, native package candidate qualification | Once per candidate tree; complete required gate before merge |
| D | Tag/signer/main/version, final ZIP identity, release build/sign/install/upgrade, newly resolved distribution runtime, provenance, immutable assets and public download | At release, on final objects and current external inputs |

The full source archive is qualified once on PR without `.git`. At release,
`scripts/verify-source-archive.py` compares the ZIP commit identity and complete
paths, extraction modes and bytes with the immutable Git blobs, reading members
without extracting or executing them. Its strict Git ZIP format rejects altered
inventory, unsupported metadata and content; a new intentional archive/export
format needs a corresponding verifier change. RPM/DEB construction is inexpensive
relative to qualification, so release builds new candidates and tests their
final bytes. Cross-run package promotion would introduce digest/provenance and
retention obligations for little wall-clock gain; it is not used here.

The PR source proof does not contain a cryptographically bound fingerprint of
every installed distribution package and library. Even an unchanged FFmpeg
version string can hide a changed distribution revision. Therefore release
retains `release-runtime`: one routing and aria2 behavior pass for each original
pinned yt-dlp version (2026.6.9 and 2026.8.19) on freshly resolved Ubuntu
dependencies. The aria2 fixture uses native yt-dlp fallbacks, so both versions
remain necessary, with their existing internal cycles. FFmpeg progress and HLS
duration run once in the latest matrix entry because those fixtures are
independent of yt-dlp. Resolved tool and distribution package versions are
logged. This job runs alongside builds and must succeed before final source
verification and publication. It has no outer repeat wrapper or full suite.
Removing this gate would require verified environment identity/reuse;
installation and `--version` checks alone cannot establish real transfer and
conversion compatibility.

`tests/ci-validation-integration.py` and `tests/source-archive-integration.py`,
called by static validation, exercise rejected proofs and source archives and
protect the graph against reintroducing full PR/main/release qualification.
Dated baseline measurements and implementation evidence are in `CI_AUDIT.md`.

The Fedora shell, FFmpeg and RPM lifecycle/upgrade qualification containers
mount anonymous Docker volumes at `/tmp` and `/var/tmp`, with `TMPDIR=/var/tmp`
for test fixtures. These
provide separate local storage rather than treating the container's overlay
filesystem as a qualified private filesystem. Production checks still validate
the actual filesystem, ownership and modes; a volume whose backing filesystem
does not satisfy those checks fails qualification. The volumes belong to the
disposable GitHub-hosted job and contain no host home or credential bind mounts.
The isolated shfmt verifier retains its private `/tmp` tmpfs and adds an
anonymous `/var/tmp` disk volume for the media workspace cases; both normal and
failure cleanup remove that volume with the verifier container. The RPM `rpm`
job in `packages.yml` and `rpm-test` job in `release.yml` exercise installed
helpers after installation and upgrade, including private JSON plans and engine
workspace checks; both matrix scenarios require these volumes. RPM build-only
and isolated signing jobs do not execute that helper contract and retain their
existing storage setup. DEB lifecycle/upgrade and Git-free source qualification
run directly on Ubuntu runners with their ordinary local temporary storage.

`.github/workflows/packages.yml` validates both package formats. Before package
upgrade testing, a dedicated `previous-release` job resolves the immediately
preceding semantic-version release, requires it to be immutable, downloads its
exact published RPM, DEB, and SHA256SUMS, and verifies release identity,
checksums, release-asset identity, and SLSA provenance bound to the expected
repository, release workflow, and exact source commit. The RPM and DEB upgrade
jobs consume those verified bytes through a short-lived Actions artifact and
recheck their transferred SHA-256 digests before installation.

Ordinary PRs retain their source version even when its release tag exists or a
working branch has a higher number. Upgrade qualification still selects the
immediately preceding published semantic version strictly below the candidate,
and requires its exact immutable assets and ancestry. This tests a real version
upgrade rather than substituting a same-version reinstall. Missing compatible
release evidence fails qualification. It does not authorize re-publication.

The development RPM and DEB Actions artifacts include the full source SHA,
and `github.run_id` in their names. Their Actions records
also identify the producing attempt and digest. A consumer-only rerun can
still download the successful producer artifact from the same run. Keep this identity when downloading or
sharing a CI build: its plain package filename and numeric `--version` alone
are not release identity. RPM/DEB version comparison and Git-free installed
payloads are unchanged. Official releases remain separately signed/attested,
immutable and bound to their authorized tag; CI packages are never promoted as
those final objects.

Pull-request CI builds one unsigned noarch RPM and proves that the production
bootstrap rejects it unless `--allow-unsigned-dev` is explicitly selected.
PR CI qualifies RPM-v4/v6 signature semantics once; the fixture already covers
multiple signers, signature ordering and corruption. Release CI reuses that
source qualification, builds the RPM once, explicitly requires RPM package
format v4, then signs those exact bytes once in the
isolated `rpm-signing` GitHub Environment. The signer has no
repository checkout, uses the same private RPM 6 `fs` keyring model as the
consumer bootstrap, removes materialized signing secrets as soon as they are no
longer needed, and explicitly terminates its temporary `gpg-agent`. The
identical signed RPM is then installed on Fedora 44 in `fresh` and
`ffmpeg-free` scenarios through the supported RPM Fusion bootstrap. The
architecture-independent DEB is built on Ubuntu 24.04 and qualified through
install, remove, purge, remove-to-purge, reinstall, and previous-release upgrade
paths. The DEB lifecycle deliberately preserves per-user managed runtime/state
while still verifying the runtime manager and embedded yt-dlp signing key; it
no longer depends on distribution yt-dlp or Deno packages.


`.github/workflows/real-tools.yml` installs actual yt-dlp, aria2c, FFmpeg, and
FFprobe on Ubuntu. Pull-request qualification retains the pinned yt-dlp
`2026.6.9`, `2026.7.4`, and `2026.8.19` matrix for reproducibility. It generates
tiny direct HTTP, AAC/M4A, Opus/WebM, combined-audio, HLS and DASH fixtures
locally, serves them over loopback, proves the aria2c/native downloader boundary,
exercises real
FFmpeg progress, and checks HLS post-remux duration consistency without
contacting a public media service. Routing runs once per pinned yt-dlp version.
HLS duration mocks yt-dlp and FFmpeg progress does not use it; those fixtures
run once on the latest Ubuntu matrix entry with FFmpeg/FFprobe 6.1.1 verified.
Before shared-destination qualification, that latest entry has a dedicated
Python 3.12 / Ubuntu 24.04 prerequisite step. It installs curl-cffi 0.16.0,
cffi 2.1.1, certifi 2026.7.22 and pycparser 3.0 into its disposable yt-dlp venv
with exact wheel SHA-256 pins, `--require-hashes` and `--only-binary=:all:`.
These versions come from the verified yt-dlp wheel's `pin-curl-cffi` metadata;
the wheel hashes come from the corresponding public PyPI releases. The other
matrix entries retain their existing environments. The static contract binds
each version/hash, the Python target, installation flags and latest-only
placement before the shared run, with discriminating source mutations.
The FFmpeg 6 generation job adds only generation-specific compatibility fixtures;
Fedora 8 and upstream 9 each run the common fixtures with their distinct tools.
The verified upstream FFmpeg 9 build enables libvpx as well as libopus so the
foreign native WebM witness contains real VP9/Opus media. Missing encoders are
qualification failures; that preservation witness is never skipped.
The controlled
aria2 behavior suite repeats
Range/no-Range/redirect/error three times, the silent-active quiescence
negative control ten times, and interrupted resume ten times. A separate weekly
scheduled job resolves and logs the current stable yt-dlp
version and runs the same qualification without changing PR pins.

`.github/workflows/release.yml` is triggered by tags matching `v*`. It runs
the exact-source qualification proof and release-specific identity checks, verifies
tag ancestry, project versions, and coherent source/published-release metadata
before it builds immutable artifacts. It then resolves the previous
semantic-version release. This guard is intentionally pre-publication: the
candidate source version must match the tag, while README asset references
continue to identify the latest immutable release until post-publication
documentation alignment has completed.

That previous release must be immutable. Its exact published RPM and DEB are
downloaded and verified with the published SHA256SUMS, `gh release verify`,
`gh release verify-asset`, and SLSA provenance constrained to the expected
repository, release workflow, and exact source commit.

The current ZIP, RPM, and DEB are built in separate jobs. Every release checkout
uses `${{ github.sha }}` directly, making the immutable event identity explicit
to Actions security analysis. Tag validation requires its target to equal that
commit before checkout; job outputs remain proof data, never checkout refs.
Signer and publisher independently refuse a tag-object change; the final read-only `verify-source`
job requires the validated output to equal `GITHUB_SHA` and rechecks all source
proof for that event commit after package tests and the signing-environment
wait. The publisher does not execute a repository verification helper. GitHub
API checks and publication are not one transaction; the immutable-tag ruleset
and fixed source/artifact identities remain part of the trust boundary. The release RPM is
built exactly once as an unsigned artifact, then a secret-bearing signing job
with no repository checkout verifies the expected primary and dedicated
signing-subkey fingerprints, requires exactly one usable signing subkey,
requests that exact subkey, and cryptographically verifies the result before
publication. RPM `OPENPGP:pgpsig` output is diagnostic metadata only and is not
treated as a full-fingerprint authorization primitive.
The resulting signed RPM bytes are the exact bytes
requalified in Fedora `fresh` and `ffmpeg-free` and later published. RPM and DEB
upgrade tests use the previously published immutable package bytes and verify
that a deterministic archive snapshot of the per-user managed-runtime tree
remains unchanged across installation and upgrade. Final RPM erase then verifies
allowlisted managed-runtime cleanup, while DEB remove and purge verify that the
same per-user runtime remains unchanged.

Build, signing and test jobs propagate immutable Actions artifact IDs in their
outputs. Downloads request one exact ID at a time with `digest-mismatch: error`;
they never select a current release candidate by name or pattern. Missing IDs,
deleted artifacts and changed digests fail explicitly. Publication and public
download verification consume the same IDs accepted by the package tests.

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

After the complete release workflow succeeds, `.github/workflows/release-docs.yml`
revalidates that exact successful run, semantic tag, source SHA, and immutable
release. A read-only job invokes `scripts/update-published-version.py` to update
only the known English/French release references and
`EXPECTED_PUBLISHED_VERSION`; exact reference counts make documentation drift
fail closed. All replacement and backup files are staged before publication.
A caught publication failure restores the previous generation with renames;
failed restoration preserves the backup and reports its location. This does
not claim recovery after SIGKILL or a filesystem-wide failure. The updater
accepts only a published version between the previous published version and the
current development version. With the pre-publication tag guard, this is
normally an idempotent consistency check and no branch or bump is needed.

When an update is needed, preparation uses current main or an existing target
that descends from it, preserves that base's source version and changes only
the two READMEs and the static published-reference assertion. Divergent branches require maintainer
reconciliation. A fresh read-only verifier reconstructs the exact patch from
that authenticated base, compares candidate bytes and runs the complete local
contract. Only the final job receives content-write permission. It performs no
checkout and executes no repository code. Fixed isolated Python verifies the
exact published-reference transformations, unchanged source version, file modes,
manifest paths and digests using GitHub API data. Large blobs are streamed into
JSON payloads, never passed through a command argument.

The publisher rechecks main, target and tag identities before writing the
`automation/release-docs-vX.Y.Z` reference. It creates an absent branch or uses
an explicit fast-forward-only update (`force:false`) whose commit parent is the
verified target. It never writes directly to main or receives PR permissions.
Reference-catalogue checks and the final branch update are separate operations:
this is not a global atomic transaction with all branches and tags. A detected
race refuses publication; ordinary protected-branch review remains required.

The successful workflow summary identifies the exact branch and commit. Open
the pull request with a maintainer-authenticated GitHub session, inspect its
checks, and merge through the normal protected-branch path. The repository
intentionally leaves GitHub Actions pull-request creation disabled. The
updater's local non-mutating consistency check is:

```bash
python3 scripts/update-published-version.py --check X.Y.Z
```

GitHub only delivers this `workflow_run` trigger when the documentation
workflow already exists on the default branch. It does not backfill a release
that completed before the workflow was merged. Align any such missed release
through a separate reviewed documentation change.

If a newly created release unexpectedly remains mutable, the workflow attempts
to delete it and verifies that cleanup succeeded. Failure or unconfirmed cleanup
causes publication to fail explicitly. Only the final job receives
`contents: write`.

## Controlled real Zenity qualification

`tests/zenity-real-session-qualification.sh` is the interactive end-to-end
protocol for behavior that a headless mock cannot prove. It deliberately does
not run in `tests/run-all.sh` or GitHub Actions because an operator must perform
and confirm visible desktop interactions in a real Fedora 44 or Ubuntu 24.04
graphical session.

Run one documented scenario at a time:

```bash
bash ./tests/zenity-real-session-qualification.sh success
bash ./tests/zenity-real-session-qualification.sh cancel-transfer
bash ./tests/zenity-real-session-qualification.sh signal-entry
bash ./tests/zenity-real-session-qualification.sh signal-progress
```

The accepted scenarios are `success`, `error`, `cancel-transfer`,
`cancel-ffmpeg`, `cancel-success-race`, `new-download`, `open-folder`,
`signal-entry`, and `signal-progress`. The signal scenarios send TERM only to
the GUI PID after the operator confirms that the requested real Zenity window
is active; they require status 143 and no residual process or visible window.
The harness prints the exact operator steps and records environment versions,
process topology, exit state, potential URL exposure in process arguments, and
residual descendants. Its default output is under
`qualification-evidence/zenity/`, which is ignored because it is local,
generated evidence rather than permanent source documentation. Pass an
explicit second path when another evidence store owns the result.

## Shared-destination and process qualification

Run the deterministic process/observer controls through the `signals` group
(or `python3 -B tests/process-supervision-integration.py` while developing).
The deterministic cases exercise production supervision functions with
controlled consumers; real-media cycles are qualified separately:

| Cases | Required observation before rescue |
| --- | --- |
| Orphan observer and intentional external viewer | The actual Zenity harness rejects a marked orphan in another SID and detects a synthetic URL in argv; the explicitly opened external viewer remains alive and excluded without being signaled |
| Timed command with early leader exit | A resistant descendant in another process group retains its pipe/resource until the helper signals the pinned private SID and returns 137 after KILL |
| Runtime timed probe | The actual runtime capture path retains the original manager's update lock and registered temporary through the child's last access, then cleans up and returns 124 |
| Engine wrapper exit, GUI and CLI modes | The engine retains resources and locks after the command wrapper exits, delivers cancellation, and waits for last access; adopted zombies remain unreaped by the test until after the production verdict |
| Engine FFprobe cancellation, GUI and CLI paths | The actual `capture_media_probe` path runs a controlled FFprobe executable with an early leader exit and resistant subgroup; cancellation returns 143 with no live marked consumer and removes the probe capture only after shutdown |
| Uncertain stop with closed consumer lock FDs | With KILL failure injected only for that consumer, the admitted engine remains alive, preserves its resource and denies an old-style exclusive lock; an independent lock remains available and release occurs only after the consumer stops |
| CLI escalation before sentinel retirement | Explicit escalation reaches the helper's private command session while its leader is pinned, before the outer sentinel can be retired |
| GUI shutdown after worker leader exit | A token-bearing GNU-timeout subgroup remains observable and is stopped before the GUI reports completion |
| Zombie leader with surviving threads | Real orphan and direct-child witnesses retain a pipe after pthread_exit; observer, GUI/CLI predicates and timed supervisor must still detect and stop the live thread before return. A revalidated consumer pidfd must be readable immediately after helper wait, before pipe draining; a premature-return mutant fails this assertion before rescue |
| Capability admission and degraded observation | Actual private-child pidfd/WNOWAIT probe, refusals injected before launch and waitid/procfs failures after admission; errors never become absence or cleanup authority |
| Observer procfs failure | Root/stat failures reject the real Zenity harness even when a previous empty success JSON exists; an ESRCH stat read is reopened once, and only a confirmed vanished pathname is skipped. A fresh live identity is retained; repeated ESRCH, permission and I/O errors still fail observation |
| Bash quiescence decisions | A private procfs model changes an enumerated parent to a zombie and adds a live child before its stat is read; GUI session reuse, GUI observation and the CLI sentinel retain supervision. Removing the second inventory fails each oracle without creating or signaling the modeled processes |

The orphan control starts a marked worker in another session, waits for its
parent to exit, and requires the real Zenity harness verdict to fail before
rescue. The observer follows the launch marker and recorded PID/start identity,
not all processes of the user. It neither ptraces nor reaps the application.
The open-folder scenario marks the deliberately launched external viewer via
its fixture launcher; the observer excludes that application and its children.
An independent positive control verifies this exception without signaling it.
Polling cannot prove absence of a process that erased its marker and escaped
before any observation. Test-only subreaping changes reparenting and collects
already stopped zombies; it is never counted as application wait-status proof.
The engine wrapper cases deliberately defer that collection until after their
verdict. The test-only `finish()` service harvests only already attributed
children of its controller, revalidates PID/start/parent and WNOWAIT exit state,
and leaves managed Popen statuses to their owner. Its real ESRCH counterexample
must not turn an unrelated process's stat race into a harvesting prerequisite.
The frozen-parent causal tests bound the root inventory to their complete known
fixture while reading real task states, children and descriptors and delivering
real pidfd signals. Their ambient-inventory control demonstrates how unrelated
ESRCH can mask the intended missing-freeze mutation; separate uncertainty tests
still require conservative production refusal.
The late-fork oracle also bounds enumeration to its real, pinned participants
and requires the late child in the second snapshot. Its single-inventory mutant
must report the live child absent; an unrelated read error cannot mask that
defect. A separate foreign-stat ESRCH witness requires conservative refusal,
including rejection of a mutant that silently skips that error.
The direct zombie-leader retirement oracle likewise enumerates only its complete
known fixture, with real task/child/FD reads and real pidfd signals. Every subcase
has separate resource paths so a conservatively refused predecessor cannot leave
a last-access marker for the next case. The leader-only mutant must be rejected
while its sibling thread still owns the release pipe, before release or rescue.
The correct case observes pidfd readiness after delivered KILL and before wait or
pipe draining; this test observation does not claim application status collection.
A held foreign stat descriptor produces real ESRCH after reaping: retirement must
refuse, resume the authenticated parent and leave its sibling/pipe alive until
the test releases its own barrier after the verdict.
Confirmed zombie-only state requires stable inventories of every
thread; a zombie leader alone is insufficient. It means no live consumer can
use a descriptor, not that the application reaped every descendant. Production engine/GUI
lost-authority checks require two complete, stable inventories and identity/state
revalidation, with uncertain observations preserving state. Timed helpers also
require two complete unchanged member inventories with no live member, then
reap their own direct child retained through WNOWAIT. A child forked after
the first `/proc` enumeration must be caught by the second complete inventory;
rechecking only the already enumerated zombie PIDs is insufficient.
The timed-thread test uses its known consumer's pidfd as the independent stop
oracle, not another global procfs scan. An unrelated process can exit between
opening and reading its stat file: a real-kernel control requires this ESRCH to
remain unknown in the production predicate, even after that process is reaped.
The test observer independently reopens an ESRCH stat exactly once: it retains
a revalidated live identity, skips only a now-missing pathname and propagates
every repeated or different error. A real held-stat descriptor after child
reaping and injected transient/persistent failures exercise these distinctions.
Pidfd readiness proves all threads in this fixture's thread group have stopped;
it does not prove general session quiescence or application reaping.
The same requirement covers the Bash GUI, engine session-reuse and CLI sentinel
paths: two complete inventories must retain identical zombie PID/start identities,
with any live consumer, changed inventory or uncertainty vetoing cleanup.

Ordinary duplicate TERM delivery must retain the helper's original grace
deadline. The outer supervisor's CONT control forces private-session KILL only
after a graceful signal was recorded; a helper with a pinned child cannot be
retired as an outer leaf. Deadline/forced KILL repeats until private-session
quiescence, covering members missed by an earlier enumeration.

The force path requires Linux pidfds and Python's `os.pidfd_open` and
`signal.pidfd_send_signal`. Entry admission actually probes pidfd open and
0/STOP/CONT/KILL delivery on a private child, WNOWAIT stop/exit observation,
waitpid collection and procfs process/thread access. Admission also reads every
visible process stat and validates its session/start identity fields; only a
pathname that disappeared during enumeration is skipped. A pre-existing unreadable
or malformed stat refuses admission before any command is launched. Missing APIs, kernel
support or permissions cause status 69 before media activity. Revocation
following admission preserves protection; it is not a successful shutdown.
A TGID marked Z is not quiescent while sibling threads are live. Refusal and
post-admission failure injections complement real minimum-interpreter runs. Its safety assertions require an authenticated
PID/start/SID and pidfd STOP, followed by two complete inspections while frozen:
every live thread must be in `T`/`t`, terminated threads may be `Z`/`X`,
and the nonempty sets of task IDs/start identities must match. Every thread's children are checked; same-session children are stopped
while the parent stays frozen, then revalidated as quiescent before its retirement.
A different-session child vetoes retirement even when it is a pinned zombie of
a timed helper. A child created by a non-leader thread must not be missed when the
leader's children list is empty. The pre-env double-signal fixture retains its
two-second limit and verifies that a startup loop cannot recreate a child between
escalation attempts. Its private readiness marker is published from the registration
loop after the first signal handler returns, so a second INT tests escalation
instead of signal coalescing while an instrumented handler is still active.
Uncertain-stop fixtures publish their first escalation
observation once, so retries cannot truncate a witness while it is being read.
The runtime contention fixture uses exec for its lock-holding sleep: the waited
PID owns the descriptor whose lifetime the assertion measures.
Session-leader retirement additionally requires two complete
quiescent inventories of its other members. A running,
missing or unreadable thread, or changed task inventory, must also refuse KILL.
Parents resume with CONT. Missing pidfd support or any failed observation must
refuse unsafe force delivery and preserve
unconfirmed resources; process names and UID matching are never substitutes.
With `WORKER_ENGINE_SUPERVISION` on a real engine launch, GUI escalation sends
CONT to the authenticated engine and its persistent force loop owns subsequent
freezes. The GUI may freeze targets itself only on the orphan/generic-worker
fallback, avoiding concurrent GUI/engine STOP/CONT decisions that reopen the
fork race. These escalation deadlines do not bound closure of an
uninterruptible consumer. A retained active checkpoint protects new-protocol
admission after a crash, but an old executable cannot read it. The controlled
legacy-lock fixture qualifies owner retention during uncertain shutdown, not
exclusion after external SIGKILL destroys every historical lock holder.

```bash
python3 -B tests/multi-instance-real.py
```

This local qualification also runs in the required latest pinned yt-dlp CI
entry, after verified Deno provisioning and the pinned impersonation prerequisites.
Its managed-runtime admission requires a usable `curl_cffi` target: successful
`--version`, `--help` or `--list-impersonate-targets` exit statuses alone do not
satisfy that contract. A wheel without those dependencies is refused with 69;
the fixture does not bypass admission or fabricate an impersonation target.
It uses real yt-dlp, aria2, FFprobe and FFmpeg,
a loopback media server and scripted Zenity answers. It shares HOME, all XDG
roots, preferences and managed runtimes between instances. HTTP barriers prove
active transfer overlap, decoded frame hashes verify distinctive content,
and monotonic events record closure and quiescence before any rescue. It covers
three bounded GUI/GUI, GUI/CLI and CLI/CLI cycles, transfer and real remux
cancellation, D admission while B/C run, and authorized native partial resume.
These are bounded qualification cycles, not an unbounded soak test; barrier
expiry or a closure deadline failure remains a failure before rescue.
It also covers two URLs with identical names, different profiles sharing an
input, title truncation, and conflicts through a destination alias and a
different XDG runtime root. A real aria2 consumer paused with an open staging
descriptor proves that both staging and reservations survive until its stop;
independent transfers continue during that interval. Legacy exclusive locking
is exercised in both launch orders against the historical inode. To also run
an available, separately preserved 2.3.29 executable, set
`YTDLP_LEGACY_ENGINE=/absolute/path/to/old/download-video.sh`; its adjacent
helpers must be from that version. Application workspaces remain private
`/tmp/shared-destination-real-*` directories, independent of an artifact root
whose ancestors may not satisfy the application's private-directory policy.
If `TMPDIR` selects another evidence store, only the exact launched labels'
logs, statuses, pre-rescue inventories and fixture metadata/events are copied
there. Media, seeds, configuration and runtimes are never exported. The printed
evidence directory retains ancestor modes/filesystem metadata and redacted
scripted-dialog diagnostics so a startup refusal cannot become an empty log.
Scripted answers do not
qualify visible desktop gestures; the interactive Zenity procedure remains
separate. No network outage or actual CIFS qualification is implied.

On a graphical Linux host with Xwayland, Zenity, D-Bus, libX11 and libXtst,
run the optional real-event variant through the same bounded wrapper:

```bash
YTDLP_QUALIFY_ZENITY_EVENTS=1 ./tests/repeat-qualification.sh --runs 1 --jobs 1 -- \
    python3 -B tests/multi-instance-real.py
```

`tests/zenity-x11-events.py` starts a dedicated X11 server and a private bus
without service activation. Startup reads the complete newline-terminated
Xwayland display reply before closing its pipe. A canonical headless regression
uses a real pipe with a separately gated newline and rejects the premature-read
control, incomplete EOF, malformed replies and oversized frames. Before semantic keyboard actions,
a disposable private window must receive two complete KeyPress/KeyRelease pairs
with matching window/keycode within a bounded readiness wait; accepted XTest
requests alone do not prove delivery. Readiness records carry their own `title`
so the New download reader can consume the shared event stream.

The adapter injects window-close and activates the real Cancel button in
entry/progress windows, including transfer and real remux cancellation while
other instances continue. It selects New download in a real completion dialog
and closes the new real entry. Ordinary URL/profile/folder selection is still
scripted. Event records identify real windows and monotonic emission times;
this is neither a human gesture nor a substitute for the operator-assisted
procedure. Missing graphical capabilities fail this opt-in run, never silently
turn it into a scripted PASS. Cancel uses Tab then Space for entry and Space on
the initially focused Cancel button for progress; `escape` is a separate action.
Short response controls distinguish `ZENITY_CANCEL=41` from `ZENITY_ESC=42` and
retain the normal cancellation status 1; progress input stays open until the
verdict so EOF cannot fake cancellation. Keyboard readiness does not extend the
adapter's 10-second dialog-result timeout or retry a failed semantic action.
The ordinary headless CI matrix remains independent.

The private-plan suite exercises shared/exclusive ancestor reservations,
Unicode/case aliases, different URLs and overlapping intermediate families,
unchanged owned resumes, ambiguous legacy partials and active-record retention
after uncertain shutdown. Incarnation cases distinguish a recreated destination
from an active checkpoint for an older directory while retaining lock keys,
old records, alias convergence and refusal when handle identity is unavailable.
A bounded real inode-reuse experiment complements the deterministic checkpoint
oracle; failure to obtain reuse is inconclusive, not a successful witness.
The descriptor barrier replaces the visible destination after observation and
requires refusal while the authenticated inode remains pinned. The real shared
matrix compares checkpoint digests before and after its own cycles: its records
must become passive, while older active records must remain byte-identical.
Resume cases keep the request, filename and formats
fixed while changing the full media ID beyond its 64-byte filename prefix, or
changing either extractor field. Both inherited and per-download identities
are covered; refreshed signed URLs and either available extractor field remain
valid positive controls. Missing, null or malformed identities permit a fresh
transfer but never authenticate its later partial. Pre-identity checkpoints are
not upgraded into ownership. The regression must fail against the former
binding; removing the missing-binding admission guard must also fail.

Qualify the following four independent oracles on disposable source copies.
Each mutant must fail its intended assertion before rescue; a startup error,
unrelated timeout or rescue killing the witness is not an oracle success.

| Oracle | Controlled input and positive control | Mutation that must be detected |
| --- | --- | --- |
| Process observation | Marked orphan in a new SID, plus the intentionally opened external viewer | Disable marker observation: the actual Zenity verdict must no longer satisfy the orphan-rejection assertion |
| Deno checksum | A valid ZIP with a deliberately wrong expected checksum; reject before extraction, execution or activation | Disable checksum verification: the integrity/no-extraction assertion must fail |
| Copy stability | Change the source in place after the first destination write, at both constant and changed size; unchanged source succeeds | Disable post-copy source-stability verification: mutated-source publication must violate the rejection assertion |
| GUI result containment | A separate engine returns success with an outside path; an inside path is the positive control | Disable GUI containment: the outside-result rejection assertion must fail |

Record source identity, the intended assertion and pre-rescue outcome for each
run. These procedures describe qualification requirements, not evidence that a
particular working tree or mutant has already passed.

## Release maintainer preflight

The preferred preflight is the repository helper:

```bash
bash ./scripts/release-preflight.sh \
  --confirm-single-maintainer-self-review \
  vX.Y.Z
```

The single confirmation records that single-maintainer self-approval is an
intentional operating choice. The script verifies through the GitHub API that
administrator bypass is disabled and the sole selected `v*` deployment policy
is a **tag** policy. It also verifies Immutable Releases, exactly one required
reviewer, that the reviewer matches the authenticated GitHub account, that
self-review remains allowed for this single-maintainer mode, secret scope, the
pinned public certificate, the dedicated signing subkey,
signed-tag/HEAD/version identity, and source/published-release metadata
coherence. It warns when the signing subkey is within 90 days of expiry.

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

## Post-release evidence qualification

After publication, `scripts/release-evidence-qualification.sh` independently
binds the immutable public release, its assets, checksums and attestations to an
expected tag commit. It also requires the exact-SHA successful release run, the complete PR tree
qualification proof described above, and fresh scheduled `real-tools.yml` and `shfmt-update.yml` evidence:

```bash
release_sha=$(git rev-parse 'vX.Y.Z^{}')
bash ./scripts/release-evidence-qualification.sh vX.Y.Z "${release_sha}"
```

All five source workflows, including `qualification.yml`, are mandatory; the
former optional extended-qualification flag no longer changes this contract.
By default, the generated Markdown report is written below `qualification-evidence/`, an ignored local output.
Supply a third path to place it in a separately managed evidence archive.

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

`.github/workflows/stress.yml` qualifies pull requests after its cheap
identity/coherence/syntax gate, retaining twenty distinct timing tuples in four
shards. The full shell contract is still required by the final aggregate. Each tuple
runs `tests/mock-integration.sh --group stress-signals`: the complete signals
group plus network cancellation and runtime error/progress scenarios that also
consume startup/cancellation delays. It covers cancellation/late completion,
PGID publication, worker startup, FFmpeg startup and `setsid` startup. Staging
mutation fixtures synchronize on readiness before replacing an inode, so their
startup delay does not change the tested state; they remain in the full suite.
The unrelated engine, GUI configuration, installer and static scenarios remain in
the full suite and are not repeated for each timing tuple. Each shard retains
five bounded five-minute iterations and ten-second termination grace periods.

The runtime-manager job runs each hardening group once: `validation`,
`rollback-admission`, `recovery`, `cache-identity` and `transactions`. Each group
has its own initialized private fixtures and a two-minute wrapper with the
existing ten-second termination grace. The job records every group status and
fails if any group fails; its required check name and job deadline are unchanged.
The transaction group retains ten internal lock-contention and double-rollback
cycles, with updates, rollbacks and journal recovery sharing their state in the
original order. No scenario is removed or repeated merely to fill a group.

The full runner schedules the same five groups through its existing bounded
worker pool. Direct invocation without `--group` still runs every phase in the
original order. These semantic groups cover the expanded exact-admission and
recovery matrices without imposing one serial deadline on all independent
fixtures. The runner-manifest and phase-coverage controls require their union to
execute every original phase exactly once. This retains stateful transaction
stress without multiplying ten internal cycles by ten complete-suite wrappers.
Deterministic package-cleanup scenarios are already covered in the full suite
on each supported environment and have no separate stress repetition. The
required aggregate check covers all shards/runtime plus the other four complete
qualification workflows before merge. It preserves its existing required name.

## Network destination regression and opt-in CIFS qualification

Run the selected checkout's scripts explicitly. Record its absolute path,
`download-video.sh --version` output and source identity; the installed command
may refer to a different release or tree even when its version string matches.
The network mock group uses entirely fictional URL/header/cookie sentinels and
checks both active download phases and cleanup. It runs the production
`media-local-safe` decision with CIFS (`0xff534d42`) or SMB2 (`0xfe534d42`)
filesystem types injected only for the opened destination inode. It simulates
permissive modes only on the selected destination, leaving the private local
workspace protected:

```bash
./tests/mock-integration.sh --group engine-network
./tests/private-aria2-plan-integration.sh
./tests/real-tools-integration.sh
./tests/real-tools-integration.sh --simulate-network
```

The helper suite separately exercises the actual `filesystem_type()` buffer
decoding through an injected `fstatfs`, local filesystem controls, SMB/CIFS/NFS/
FUSE/unknown types and syscall failure. No production override is used. Network
success cases require local processing during planning, aria2 and yt-dlp phases,
removal of that local workspace after completion, and exactly the final media
plus unchanged preexisting entries in the destination. An old staging directory
with a mode-`0755` marker must survive. Local audio/video success cases require
active staging removal; identity replacements and active directory/marker mode
changes must instead preserve ambiguous state with an explicit diagnostic.

The real-tool simulation serves tiny generated media over loopback and makes
only its disposable output directories permissive. It exercises real direct,
audio, HLS and DASH processing followed by destination copy. Native M4A/MP3
repetition and metadata changes must preserve hashes, inodes and
timestamps without new GET requests; a changed native input extension must be
refused before GET or postprocessing. Literal dollar/percent destinations cover
both native and direct transport with defined and undefined environment names.
Successful local
and simulated-network cases also check for destination staging/path/publication
residues and any retained local media workspace. It does not simulate
SMB caching, reconnects, Unix-extension behavior or kernel-blocked syscalls.
Helper fault injection covers unsupported hard links/rename, copy/write errors,
collisions, signals, identities and private-root selection; simulated failures
must not be reported as actual network failures.

After focused tests, run the canonical contract:

```bash
./tests/run-all.sh --doctor
./tests/run-all.sh --fast --jobs 4
./tests/run-all.sh --full --jobs 4
./scripts/check-shell-format.sh
./scripts/git-inspect.sh diff-check
```

Preconditions: host dependencies and a local loopback socket must be available.
A sandbox that remaps system ownership or blocks loopback is not a qualifying
runtime; use the authorized host test environment. A failing test must be
investigated before rerunning. The full profile runs Bash/Python syntax checks,
ShellCheck, formatting, integration and package-tree checks; no new checker is
required merely because the implementation is Python.

### Actual SMB/CIFS test: opt-in, not part of ordinary tests

Status for this change: **NOT EXECUTED on a real CIFS mount**. Use a disposable
share explicitly authorized by its owner, never a production destination.
An operator may prepare a Fedora 44 mount with SMB Unix extensions disabled
and fixed `file_mode=0755,dir_mode=0755` (or an equivalent test configuration).
A media file must be writable while `chmod 600` leaves its visible mode
permissive. Mount credentials belong in an operator-managed private credentials
file, not shell arguments or the test log. Mounting is an operator prerequisite;
ordinary tests never require sudo or change fstab, SELinux or mount options.

Set the exact authorized test mount path, then run:

```bash
CIFS_TEST_DIR=/absolute/path/to/disposable-test-share
./tests/real-tools-integration.sh --network-destination "$CIFS_TEST_DIR"
```

Expected: direct video/audio and native HLS/DASH results pass FFprobe, each
result-file points inside the chosen test share, and no plan, cookie, batch,
manifest or browser database is written there. The harness creates and prints
one unique `yt-dlp-network-qualification.*` subdirectory and preserves it for
operator inspection. Inspect filenames/types without printing credentials;
remove only the individually verified test media, then `rmdir` their exact
empty directories. Never recursively remove a wildcard match.

Use the GUI from the same physical checkout for complete video, audio and the
YouTube profile. Automated tests never use actual Firefox cookies; a real
YouTube-session test is an explicit operator action. During transfer and final
copy, cancel once; then send HUP/INT/TERM in separate runs to that specific
process. Verify no success is displayed, no preexisting file changed, and
controlled cleanup follows confirmed termination. Preserve residues if a
server outage leaves a syscall blocked; cancellation is not guaranteed instant.
Test an already-existing final name and a concurrently created final name.
Test a read-only share and a deliberately quota-limited *test* share: expect
failure, no complete final name for a partial copy, and retained valid local
source after a failed/ambiguous publication. These outage/quota/mount behaviors
remain **NOT EXECUTED** unless recorded in a separate operator qualification.

For an authorized manual check, start the selected checkout's absolute
`download-video-gui.sh` and select the intended test destination normally.
No production-share mutation is performed by the development tests. Identify
the code using the checkout path, its actual development version and source
SHA-256. A successful simulated qualification does not close the real
CIFS qualification requirement.
