# Architecture

This document is the current technical map of
`yt-dlp-aria2-downloader-gui`. It explains how components interact and where
the security and lifecycle boundaries live. Use `REPOSITORY_FILES.md` for the
path-by-path inventory, `TESTING.md` for validation procedures, and the READMEs
for user-facing behavior.

## System overview

The project is a GNU/Linux desktop application with a Bash CLI engine, a Zenity
front end, private Python helpers, managed per-user runtimes, native
RPM/DEB packages, and GitHub Actions release automation.

```mermaid
flowchart TD
    desktop[Desktop entry or packaged GUI command] --> gui[download-video-gui.sh]
    portable[Portable GUI invocation] --> gui
    launcher[install-gui.sh] --> launcher_helper[private-launcher-manager.py]
    launcher_helper --> xdg[Anchored per-user XDG launcher files]
    cli[CLI or packaged CLI command] --> engine[download-video.sh]
    gui --> engine
    gui --> monitor[progress-monitor.sh]
    monitor --> zenity[Zenity progress dialog]
    engine --> runtime[runtime-manager.sh]
    runtime --> ytdlp[Verified yt-dlp runtime]
    runtime --> deno[Verified Deno runtime]
    engine --> plan[yt-dlp metadata plan]
    plan --> helper[private-aria2-plan.py]
    helper -->|direct HTTP or safe HTTPS| aria2[aria2c private staging]
    aria2 --> commit[Validated helper commit]
    commit --> replay[yt-dlp load-info post-processing]
    helper -->|native or fragmented transport| native[yt-dlp native download]
    replay --> normalize[Normalized final path]
    native --> normalize
    normalize -->|YouTube HLS profile| remux[FFprobe guards and FFmpeg remux]
    normalize -->|Other profiles| validate[Final FFprobe validation]
    remux --> validate
    validate --> result[Final media and private result record]
```

`download-video.sh` is the single source of truth for application version and
download behavior. The GUI collects a request and supervises the engine; it
does not implement a second download pipeline.

## Entrypoints and installed layout

| Interface | Source | Installed form | Responsibility |
| --- | --- | --- | --- |
| Graphical | `download-video-gui.sh` | `/usr/bin/yt-dlp-aria2-downloader-gui` symlink | Collect one request, supervise it, render progress, and report the result |
| Command line | `download-video.sh` | `/usr/bin/yt-dlp-aria2-downloader` symlink | Validate inputs and runtimes, select transport, download, validate, and publish one result |
| Portable launcher management | `install-gui.sh` plus `private-launcher-manager.py` | Run from a Git checkout or ZIP | Validate the request, then install or remove the current user's desktop launcher through anchored filesystem operations |
| Fedora bootstrap | `install-fedora.sh` | Published beside release packages | Authenticate a release RPM, install dependencies and the package, then prepare managed runtimes |

Native packages keep implementation files under a private libexec directory.
`packaging/install-tree.sh` creates the shared RPM/DEB payload, public symlinks,
desktop entry, icon, manpages, and user documentation. Python helpers remain
mode `0644` and are invoked explicitly with `python3`; they are not public
commands. Only the aria2 helper belongs to the native package payload, because
the launcher helper is specific to ZIP and Git installations.

The portable launcher manager requires the data root and managed directories to
be owned by the current user and not writable by group or others, rejects the
filesystem root, rejects data paths that are not valid UTF-8 desktop-entry
input, and opens every `XDG_DATA_HOME` component with
`O_DIRECTORY|O_NOFOLLOW`. Every ancestor, including the intermediate icon
directories, must be owned by root or the current user; group/other write
permission is accepted only with sticky protection. This ancestor exception
does not relax the stricter ownership and mode checks on the data root and
managed leaves. Each parent is checked before creating a child, and each opened
child is checked after its device/inode binding. It holds the data root and each
managed directory open for the complete transaction. Install and uninstall take
one exclusive advisory lock on that anchored data-root inode before opening managed
directories, serializing cooperating transactions without a removable
lockfile; lock acquisition is bounded. The helper also opens and retains the
regular executable GUI target,
then revalidates its identity and executable mode before success. Python
`dir_fd` operations perform staging, validation, publication, and known-file
removal. Desktop validation has bounded time and captured output. Private hard
link backups in each destination directory allow every already-attempted leaf
publication or removal to roll back in reverse order when a later step fails.
The full path chain and strict managed-directory policy are revalidated before
stale cleanup, before publication/removal, and during final validation; refusal
never attempts to repair permissions on an unsafe ancestor. A refusal before
stale cleanup preserves the pre-existing temporary artifacts as well as the
managed leaves.
The Bash entrypoint supervises the Python helper and keeps ordinary helper
failures normalized to status 1. HUP, INT, and TERM retain their public
129/130/143 statuses. Before forwarding TERM or retrying an interrupted wait,
the wrapper proves that its retained PID is still a direct child, so PID reuse
cannot redirect cancellation. The Python handler records the first request without
raising at an arbitrary bytecode; explicit checkpoints convert it into a
transaction exception only after the affected resource is registered. Later
catchable requests leave that first flag unchanged and return without mutating
signal dispositions until bounded validator termination, rollback,
temporary-artifact cleanup, and descriptor cleanup complete, so interruption
cannot publish only a subset of the three managed leaves. Validator cleanup
sends KILL only while `Popen` still proves that its child is unreaped. Once all mutation,
cleanup, and diagnostic work is finished, the helper atomically enables
immediate delivery and its process entrypoint covers the final function-return
window.
An absent optional branch remains represented by `None` only at orchestration
boundaries; backup and rollback helpers explicitly reject or skip it so Python
can never reinterpret it as the process working directory.
Stale cleanup recognizes only the current and legacy private token formats.
File-shaped artifacts are never treated as directories. A launcher stage's
contents are inspected and removed non-recursively only when its mount identity
matches the parent and they contain at most the single expected `launch`
symlink. When mount identity is unavailable, content is preserved and only an
already-empty stage may be removed with `rmdir`; unknown contents are always
preserved. Renaming the validated root and replacing its pathname during an
operation therefore cannot redirect mutations into the replacement tree; root
identity is checked both around managed-directory validation and last, and a
rejected install restores its prior managed leaves.

The advisory lock coordinates invocations of this helper; it is not a security
boundary against an unrelated process running as the same UID, which retains
normal authority to mutate its own files after the helper's final checks. The
closing validation sequence checks target, managed paths, target again, and the
visible data root last to cover mutations during the transaction without
claiming post-return immutability.

## Graphical session lifecycle

`download-video-gui.sh` performs one bounded session:

1. Resolve physical GUI temporary, XDG configuration, and state paths; accept
   only system/current-user-owned chains whose shared writable components use
   sticky-bit protection; and validate required host commands, adjacent engine
   files, and `setsid` capabilities. Unsafe optional roots fall back to the
   independently validated standard locations.
2. Load `gui.conf` only when it is a regular non-symbolic-link file within the
   64 KiB and 128-line limits. Collect the URL, classify its normalized host
   with the engine's exact YouTube host set, and offer exactly two profiles:
   authenticated Firefox HLS video and native audio for YouTube, complete MKV
   video and native audio for every other host. A remembered audio profile stays
   selected; every other saved value, including absent or invalid preferences,
   selects the compatible video profile for the current URL. Collect the destination,
   then persist only the destination and selected compatible profile; never
   persist the URL.
3. Create a private temporary session containing a mode-`0600` URL file, live
   log, result record, and process-group record.
4. With shell job control explicitly disabled, start `download-video.sh` as the
   directly supervised leader of a dedicated session using no-fork
   `setsid --wait`; the registered PID, PGID, and SID are therefore identical.
   The URL is passed through `--url-file`, not through the engine argument
   vector.
5. Feed the private live log to a separately supervised
   `progress-monitor.sh`, which emits Zenity's numeric/text protocol through a
   private mode-`0600` FIFO. The monitor receives no dedicated URL argument,
   but can read URLs present in the raw log; it belongs to the same private
   session trust domain. It renders parsed progress fields, not arbitrary log
   lines. Only separately sanitized snapshots are offered for viewing or
   published in the persistent log directory; an unconfirmed shutdown can
   separately require preservation of the private live session.
6. Run captured Zenity dialogs as registered children with 64 KiB in-memory
   ingestion bounds. On cancellation, HUP, INT, TERM, or failure, signal and
   reap Zenity, the monitor, and the complete worker process group, escalating
   within bounded waits when necessary.
7. Accept success only when the worker succeeded and the private result record
   names a valid final path. Retain a sanitized diagnostic log only when useful;
   when its source exceeds 8 MiB, discard the first potentially partial tail
   line before URL redaction and abandon retention if no useful safe payload
   remains. After validating the state directory's owner and mode, assemble the
   payload in a hidden private staging file and reserve space inside the same
   8 MiB limit for a final section containing the future file's exact basename
   and canonical absolute path. Compare that section byte-for-byte, publish the
   completed inode atomically without overwriting, and revalidate identity,
   containment, ownership, mode, type, and size before viewing. Every
   interactive error with such a safely retained diagnostic uses one shared
   View log/Close path. Pre-session Zenity failures with bounded technical
   output use that same dialog with a mode-`0600` diagnostic inside a private
   temporary directory, then remove it immediately after the interaction. The
   GUI never falls back to the private raw worker log.

`LOG_FILE` always identifies the private live session log;
`RETAINED_LOG_FILE` identifies a separate sanitized point-in-time snapshot.
Retention does not unlink or retarget the live path. If worker or GUI-child
shutdown remains unconfirmed, cleanup preserves the session and live log, so
later producer writes remain accessible by the same path. Only confirmed
shutdown permits normal session removal; the snapshot is not automatically
refreshed and does not claim to contain later writes.

The GUI recognizes legacy audio-profile values solely to migrate old settings
to the current single native-audio profile.

## Engine pipeline

`download-video.sh` owns the end-to-end download contract:

1. Parse one URL from a direct argument or a private `--url-file`; stdin is not
   a URL input interface. Reject
   raw control characters, line breaks, non-HTTP(S) schemes, and URL user
   information while preserving Unicode and percent-encoded URL data.
2. Ask `runtime-manager.sh prepare update` for an attested yt-dlp/Deno pair, or
   `prepare require` when automatic managed-runtime updates are disabled. This
   command is supervised as a signal-aware child and writes its output through
   a private mode-`0600` capture file.
3. Validate the yt-dlp, Deno, aria2c, and `setsid` versions or capabilities used
   by the current option contract, and require FFmpeg, FFprobe, and the other
   host commands used later in the pipeline.
4. Resolve and record the final destination identity, then acquire the stable
   same-user destination lock. A shared media destination need not have private
   permissions. `private-aria2-plan.py media-local-safe` checks the actual
   filesystem and physical owner/write chain to decide whether external tools
   may safely work there. Otherwise a separate private local disk workspace
   becomes the processing directory; the chosen destination remains the final
   publication target. `report_abandoned_private_aria2_staging` reports old
   destination residues for manual inspection; it does not recover or delete
   them by pattern, age or a marker alone.
5. Use the shared `private-root` allocator for local mode-`0700` metadata
   sessions, independent of either media directory. File creation probes verify
   actual mode `0600` before secrets are written. The allocator opens directory
   components without symlink traversal, validates owner/mode and filesystem
   on descriptors, and never changes existing user-directory permissions.
   `XDG_RUNTIME_DIR`, `/tmp`, `/var/tmp` are metadata candidates; disk workspaces
   use existing XDG/default cache directories, then `/var/tmp`, excluding tmpfs.
   Export the private session as yt-dlp's TMPDIR/TMP/TEMP so Firefox temporary
   database copies also stay private. Catchable signals are deferred while
   workspace/path-record descriptors and identities are registered. The media
   staging acquisition also registers its complete ownership marker before
   replaying a signal; the HLS remux acquisition registers and cross-checks its
   pathname, inode and open descriptor before replay or FFmpeg launch. Failed
   directory descriptor/path bindings discard the observed pathname identity
   before cleanup: an inode seen after replacement is not deletion authority.
   Acquisition failures preserve ambiguous resources rather than weakening
   cleanup checks, and deferred signals keep their original exit status.
6. Run a metadata-only yt-dlp planning pass and ask
   `private-aria2-plan.py classify` whether the selected formats may use the
   direct aria2 path.
7. Execute exactly one selected transport, while publishing structured progress
   records when the GUI requested machine progress. Ordinary native video first
   checks the planned final MKV name and binds subsequent extraction/retries to
   that basename; metadata refresh must not redirect postprocessing to another
   pre-existing final. The HLS/Firefox profile keeps its separate remux path.
8. Validate the produced media with FFprobe. The repaired YouTube HLS profile
   additionally checks duration/tail consistency and remuxes to a temporary MKV
   with FFmpeg before no-overwrite publication. The temporary inode is held by
   an authenticated open descriptor from before FFmpeg starts, preventing
   unlink-and-recreate inode reuse from satisfying the identity checks.
   Publication first links from that descriptor; filesystems without hard
   links use the compatible no-clobber rename only after the protected parent
   chain and temporary pathname identity are revalidated.
9. For a local-disk fallback, copy the validated media through opened source
   and destination descriptors into an exclusive destination temporary. Check
   source identity, size and modification timestamps, all writes and fsync,
   then use actual `renameat2(RENAME_NOREPLACE)` or atomic hard-link publication.
   Unsupported primitives and ambiguous remote results fail closed, retaining
   the valid local source. This is one-file atomic naming, not a multi-filesystem
   transaction. Then atomically publish the private result record only after the final media path
   is normalized, contained in the selected destination, and validated. Its
   canonical parent chain and inode are authenticated before use. Reads,
   rewrites, and primary no-overwrite publication remain bound to the opened
   descriptor; the filesystem-compatibility fallback revalidates the parent and
   temporary pathname immediately before a no-clobber rename.

Standalone engine commands use a dedicated process group; GUI-owned engines
reuse the GUI's dedicated session rather than creating an escaping nested
session. Child registration is signal-atomic. In
autonomous mode, job control remains disabled and an outer `env` ignores HUP,
INT, and TERM until the no-fork `setsid --wait` process has become the new
session leader; an inner `env` then restores default dispositions before the
worker command is exposed as ready. In GUI-owned-session mode, readiness is
likewise published only after default dispositions are restored. The critical
section remains active until that readiness marker or PGID is published, so the
first signal cannot disappear in the fork/exec window; a repeated signal still
escalates immediately to KILL while retaining the first requested status.
Signals are relayed during runtime preparation, transfer, and post-processing,
and cleanup removes only state owned by the current invocation after worker
shutdown is confirmed. If bounded termination cannot confirm shutdown, cleanup
warns and preserves active temporary files and the original exit status. It
does not explicitly unlock the file description that surviving children may
still hold; process exit closes the parent's descriptors. Before using a
PID or negative process-group target, the supervisor revalidates its direct
parent where applicable and its Linux PID, PGID, SID, and start-time identity.
The autonomous engine keeps an authenticated session-leader sentinel alive
until every live same-session descendant has exited. If that leader disappears
unexpectedly, its numeric PGID remains a cleanup veto, never renewed signaling
authority. Observed live PGID/SID members prevent quiescence; when the leader
cannot be authenticated and the process-table snapshot finds no live member,
only a kernel ESRCH response to a signal-zero probe confirms group absence.
Permission failures or other uncertainty preserve the state. Before readiness
adoption, the no-fork worker PID supplies the same observation-only candidate.
Unconfirmed shutdown preserves remaining readiness records and the private
aria2 input as well as media resources; a new supervised command cannot discard
the pending tracking. If Bash has already
harvested the GUI's leader asynchronously, an inherited private token plus a
fresh PID, PGID, SID, and start-time check authenticates a surviving member
instead. Cancellation can therefore still reach a child that outlives the
command wrapper without granting authority to a recycled numeric process
group. Once readiness has been consumed into the in-memory PID or PGID state,
its private record is unlinked before the registration critical section ends
so a later SIGKILL cannot strand it.

### Session state and ownership

These globals represent resources spanning acquisition, external commands,
publication and EXIT cleanup; making them local independently would lose that
ownership information. An empty pathname, missing identity and open FD are not
interchangeable states. Registration defers catchable signals until the
identity/descriptor binding is complete; failed authentication grants no
deletion authority. An unconfirmed worker stop vetoes resource cleanup before
individual inode checks even begin.

| State | Creator / users / publisher | Cleanup owner and preserve condition |
| --- | --- | --- |
| `FINAL_OUTPUT_DIR`, identity, FD | `prepare_output_directory` records the canonical user destination; final validation and publication use it | Engine closes its FD; never recursively deletes the user's destination |
| `OUTPUT_DIR` | Initially the requested destination; after output preparation it is the processing directory, either that destination or `MEDIA_WORKSPACE` | This name must not be used to infer the final destination after workspace selection |
| `MEDIA_WORKSPACE`, identity, FD, cleanup-safe flag | Output preparation allocates local media storage; tools process there; `publish-media` copies the validated result | Engine/helper remove only authenticated owned contents; unknown identity, mount, retained media or unsafe child cleanup preserves remaining state |
| `PRIVATE_ARIA2_METADATA` and `PRIVATE_ARIA2_STAGING` triplets | `prepare_private_work_files` allocates and registers them; plan/credentials live in metadata, transfer bytes in staging | Engine removes current-session state only. Flat Bash staging cleanup checks identity, owner, mode, marker, regular types and its name allowlist; it does not recurse or inspect mount IDs. Metadata uses `cleanup-workspace`, including mount-ID checks, and can remove other authenticated regular files. Failed required checks preserve state |
| `HLS_REMUX_TMP`, identity, FD | `remux_hls_result` registers before FFmpeg; publication consumes the verified inode | Engine removes the authenticated temporary or records its retained identity; failed publication does not authorize deleting the verified result |
| `RESULT_FILE_TMP` / `INTERNAL_PATH_FILE_TMP` / `PATH_RECORD_TMP` | Exactly one first-choice temporary is allocated: beside the requested result record, or internally when none was requested. `PATH_RECORD_TMP` selects that same inode; its identity/FD bind yt-dlp reporting and validation | Finalization publishes the external record or removes the internal record; EXIT uses the common selected path, not three independent files |
| `LOG_FILE` / `RETAINED_LOG_FILE` | GUI owns the private live log and separately published sanitized snapshot | Confirmed shutdown permits session cleanup; snapshot retention never removes a live producer's path |

`run_supervised_command` normally returns shell status zero even when its
command fails: this lets the caller handle failures under `set -e` without
disabling error handling throughout supervision. The command/startup/requested
signal outcome is in `DOWNLOAD_STATUS` (initially internal failure `125`), not
`$?`; every caller must inspect it. `DOWNLOAD_WAITED_STATUS` records an observed
wait result, while a requested signal can take precedence in `DOWNLOAD_STATUS`.
Neither value alone proves shutdown: retained PID/PGID state remains a separate
cleanup veto. These names and the path-record aliases are retained to avoid a
large cosmetic rewrite of their callers.

## Transport boundary and Python helper

The initial yt-dlp pass resolves formats and filenames but does not download.
`private-aria2-plan.py` provides the shared storage allocator and these transport commands:

- `classify` validates the plan and selects `direct` only for representable
  direct HTTP(S) formats whose headers can be safely replayed;
- `check-native-final` refuses an existing ordinary-video MKV in the actual
  final directory using its recorded identity and an opened descriptor. On
  success it returns an absolute yt-dlp output template with a fixed basename
  and dynamic extension. Literal percent and dollar characters are escaped for
  yt-dlp's template/environment expansion. The engine passes this override last
  so refreshed native metadata cannot select a different basename;
- `build` converts the validated plan into a mode-`0600` aria2 input file and a
  version-2 manifest inside the separate mode-`0700` metadata directory;
  media component staging stays in a private child of the processing directory.
  The manifest binds output/staging identities and existing component and
  assembled PLAN names are refused. For ordinary direct video, a preflight also
  checks the known MKV result in the actual final directory by descriptor and
  recorded directory identity, even when processing uses a private workspace;
- `commit` validates completed staging files and publishes every component to
  the exact yt-dlp-selected destination without overwriting an existing path,
  rolling back partial publication when possible. A real kernel no-replace
  rename supports local filesystems without hard links; no unsafe rename
  emulation is used.

Private plans, manifests, and staging directories must belong to the effective
user. Commit rejects duplicate staging sources before publishing any component,
and still handles destination collisions that appear after the build check.
The early assembled-name check prevents a known final from triggering fresh
component downloads or metadata rewriting, and does not report existing media
as a newly validated success. It is not an atomic publication mechanism: direct
and native local yt-dlp postprocessing still have a pathname collision window
after that preflight. A separate private POST/rebased-plan transaction would be needed to
close it while preserving interrupted-download resume. The same-user advisory
lock does not exclude unrelated writers; descriptor-bound workspace publication
and the separate HLS/Firefox remux publication already refuse late collisions.
The classifier sends unsupported transport features to native yt-dlp. Malformed
URL/header fields encountered during direct classification remain validation
errors; an earlier native fallback does not inspect every remaining field and
leaves unsupported transport handling to yt-dlp. Subsequent build/publication
path checks remain mandatory on their respective paths. Header names repeated
with different casing are not replayed through aria2. Rejected protocol fields
are never copied into diagnostics.

URLs and replayed HTTP headers are written to private files rather than command
arguments. aria2 diagnostics pass through byte-oriented URL redaction, including
malformed UTF-8 input. Diagnostic filters ignore cooperative termination signals
until the producer closes its pipe, preserving its final cancellation messages;
unexpected filter failures remain fatal. Fragmented DASH/HLS,
unsafe headers, URL user information, unrepresentable formats, and HTTPS on an
aria2 build that lacks the required safety capability stay on yt-dlp's native
transport. Cleanup revalidates the recorded filesystem identities of the
transaction-owned plan, cookie jar, aria2 input, and transfer manifest
immediately before pathname removal. The temporary HLS remux is kept open from
before FFmpeg starts, the result record is likewise opened and authenticated,
and their primary no-overwrite publications are bound to those descriptors
instead of their mutable names. A replacement that is visible at an identity
check is preserved for diagnosis. As with the installer transaction, a process
running under the same Unix UID remains in the same trust domain and can race a
later path-based cleanup after its final check.
If an otherwise owned staging directory must be preserved because it contains
an unknown artifact, validated private authentication metadata is still removed
before the directory is left for diagnosis.

The helper is Python because structured JSON parsing, URL decomposition,
file-mode inspection, and transactional manifest handling are clearer there
than in Bash. JSON shape and transfer-count checks follow `json.load`; there
is no explicit pre-parse byte or nesting-depth bound. Large metadata can
therefore consume substantial memory, and transfer-count limits must not be
described as a parsing-memory limit.
Its SPDX-plus-module-docstring header is the project-wide Python identity
contract; `SHELL_STYLE.md`'s Bash banner does not apply.

`private-root`, `media-local-safe`, `check-space`, `publish-media` and
`cleanup-workspace` reuse the installed helper; no additional installed module
or dependency is introduced. Disk capability uses a conservative
ext2/3/4/XFS/Btrfs/ZFS allowlist; metadata also permit tmpfs. Filesystem identity
is checked on opened descriptors, not inferred from HOME/TMPDIR or a `cifs`
name alone. The disk-space estimate is three times known component bytes plus
64 MiB; unknown sizes and later ENOSPC remain explicit runtime limitations.
Cleanup authenticates a live session's root identity and snapshots its tree;
foreign ownership, links, mount boundaries or replaced entries are preserved.
Directory mount boundaries are checked with the opened descriptors' Linux
`/proc/self/fdinfo` `mnt_id`, not `st_dev` alone: a same-filesystem bind mount
still has a distinct mount identity. The workspace must share its immediate
parent's mount; every opened subdirectory must share that workspace mount
before recursion in both the inspection and removal passes. Missing, malformed
or ambiguous mount identity stops cleanup conservatively. Mounts elsewhere in
the ancestor chain, such as a separate `/home`, remain legitimate. Open
descriptors stay anchored if a mount subsequently covers their pathname; no
distinct mounted directory is recursively traversed through those validated
descriptors. This is not a transactional deletion or a defense against a
hostile administrator: a late change can preserve the remaining tree after
already-validated siblings have been removed. The kernel interface is described
in [the Linux proc documentation](https://docs.kernel.org/filesystems/proc.html).
An ambiguous component stage, path record, HLS temporary or repaired source
also prevents recursive cleanup of its parent workspace. These preservation
decisions survive finalization even after a component clears its path variables.

Native yt-dlp `.ytdl` state currently contains fragment position/count and opaque
extra state; HLS WebVTT may add timing/deduplication state. aria2 HTTP control
files contain binary piece/transfer state, including transient `.aria2__temp`.
Neither extension alone establishes safety. In network sessions all of these
remain on the local private media disk. Native partial resumption is unchanged
for trusted local outputs; isolated network sessions restart after cancellation.

No-replace rename cannot bind its source name conditionally to an open inode.
For a shared destination, the copy remains descriptor-bound and publication
checks the temporary before and final inode after the atomic operation. A
concurrent replacement is an error with the local source retained; no claim
is made against a malicious server or writers modifying deliberately shared
media after publication. Advisory locks coordinate this user's local launches,
not separate hosts. Normal HLS/DASH fixtures are qualified; upstream unsupported
or live HLS delegation to an external downloader requires separate argv-privacy
qualification.

### Private helper exchange formats

These are local interfaces between the adjacent engine and helper, not public
network protocols. Data files are private regular files; syntax never replaces
owner/mode/path/identity checks. Diagnostics go to stderr. CLI usage errors use
status `2`, validation failures `65`, OS failures `70`, existing destinations
`1`, and handled publication signals `128 + signal`. Unsupported transport
features can select native transport before all fields are inspected;
malformed fields encountered during validation are errors, while native
fallback leaves unsupported transport handling to yt-dlp.

| Exchange | Producer / consumer | Schema and rejection policy |
| --- | --- | --- |
| yt-dlp plan | Planning pass / `classify`, `build`, `check-native-final` | UTF-8 JSON from `--dump-single-json --no-clean-info-json`; upstream schema, not a project version. Exactly one `requested_downloads` object is required. Unknown yt-dlp metadata is not globally rejected; selected fields, component count and paths are validated before use |
| Classification | `classify` / engine | Two LF-terminated `key=value` lines: `transport=direct` or `transport=native`, then `transfer_count=N` where N is 1–16 without leading zero. The reader allows either order, requires both values, rejects unknown keys, repeated counts, repeated nonempty transport values and invalid final values |
| Direct-transfer manifest | `build` / `commit` | JSON version `2`, six top-level fields described below; no v1 compatibility. Unknown keys are ignored, not a strict closed-key schema |
| aria2 input | `build` / aria2c | aria2's line format: one URL followed by indented `out=...` and allowed `header=...` options per item. Contains sensitive replay data; it is not the manifest and never belongs on a shared destination |
| Build / commit summaries | Helper stdout / discarded by engine | One LF-terminated `transfer_count=N` / `published_count=N` line respectively. The engine redirects these summaries to `/dev/null`; success is established by exit status and subsequent validation |
| Native final preflight | `check-native-final` / engine | One absolute yt-dlp output template plus LF, frozen basename with literal-template escaping and dynamic extension. Used as the last output option; nonzero status aborts before native download |

The manifest producer emits `version` (integer 2), `output_dir` and
`staging_dir` (absolute path strings), `output_identity` and `staging_identity`
(two-element `[st_dev, st_ino]` arrays), and `items` (1–16 objects). Each item
has `staging_name` (`item-NNN.download`, three decimal digits) and `destination`
(contained absolute path). Names and destinations must be unique. There is no
absent/unknown sentinel for these required values. The consumer compares the
version and identity arrays to expected values and validates required shapes;
it does not separately enforce every producer's JSON numeric type. It rejects
changed directory identities, unsafe paths, empty/nonregular/symbolic sources,
remaining `.aria2` control files and existing destinations before publication.
The manifest contains no URL, cookie or header. JSON whitespace has no meaning;
neither plan nor manifest parsing has a pre-parse size bound.

Future incompatible manifest meanings need a new version with an explicit
reader policy. Classification and summary records have no version field: adding
classification keys would break the current strict reader, so their producers
and consumers must change together. Ignored JSON keys are not authority to
change the meaning of existing fields.
The classification transport duplicate check records only a nonempty value:
an empty transport record preceding a valid one is currently tolerated, although
the helper never produces it. Shell capture removes trailing newlines before
parsing classification output; internal blank or unrecognized lines are errors.

## Progress protocol

`YTDLP_STORAGE|local-disk` is a constant, path-free diagnostic emitted when the
engine selects local media staging. It remains in the log; the monitor consumes
it without changing the visible message, phase or percentage. Storage details
are not appended to progress messages, which retain speed and ETA. The later
`MediaPublication` postprocessor event announces the final destination copy.

The GUI captures the engine's human diagnostics and machine records in one
private live log. `progress-monitor.sh` tails that log and maintains a monotonic
display model for yt-dlp native downloads, aria2 direct transfers, yt-dlp
post-processing, and FFmpeg remux progress.

Machine records include plan membership, stable format identifiers, byte or
fragment counters, post-processing state, FFmpeg duration/progress, and the
final result record. The monitor sanitizes untrusted fields, bounds arithmetic,
and confirms output through the private result file rather than treating a
progress percentage as proof of success. Complete-video plans with an explicit
video-then-audio pair use an 80/20 fallback only while at least one byte total
is unavailable; exact aggregate byte weighting takes priority as soon as every
total is known, and the stable display prevents that transition from moving the
Zenity bar backward. Single streams and other plan shapes retain their generic
progress model.

### Record schema and compatibility

Records are LF-terminated text in the private mixed diagnostic/progress log,
with literal `|` separators and no escaping. Counts below include the record
name. The engine/yt-dlp emit them only when machine progress is enabled;
FFmpeg also emits its native `out_time_us=...` records. Except for the explicit
`V2` name, these record names have no numeric version; their current schema is
the compatibility contract, not an implied version negotiation.

| Record | Fields in order after the name | Count / meaning |
| --- | --- | --- |
| `YTDLP_PLAN` | media ID, combined format ID, first format ID, second format ID | 5; media ID is currently ignored. The explicit two-stream video order is video then audio |
| `YTDLP_PROGRESS_V2` | media ID, format ID, status, downloaded bytes, total bytes, estimated total bytes, fragment index, fragment count, percent text, speed text, ETA text | 12; media ID ignored; `finished` completes the item. Prefer known total, then estimated total, then fragments/percent; fragment 0/N bootstrap is neutralized when N > 1 and status is not `finished` |
| `YTDLP_PROGRESS` | status, percent text, speed text, ETA text | 5; legacy single-item model, status ignored; current engine no longer emits it |
| `YTDLP_POSTPROCESS` | status, processor name | 3; status is diagnostic, not proof of success. `MetadataParser` is ignored because it can run before download; other processors select the postprocessing display |
| `YTDLP_STORAGE` | `local-disk` | 2; only this exact complete record is recognized, no display transition |
| `FFMPEG_PROGRESS_DURATION` | expected source duration in microseconds | 2; starts remux display; invalid/zero duration leaves no quantitative denominator |
| `ARIA2_PLAN` | transfer count, integer 1–16 without leading zero | 2; pre-registers items, ignored after items have already been observed; two video items mean video then audio |

Byte and fragment counters and microseconds are unsigned decimal strings with
1–16 digits, at most `9000000000000000`; invalid/missing/out-of-range values
become zero. Zero totals mean unknown size, not completed transfer. Percent text
permits surrounding whitespace, a trailing `%`, one to three integer digits,
and up to six fractional digits; the integer part is displayed, capped at 100,
invalid input becomes unknown (`-1`). Format identifiers use at most 128
characters from `[A-Za-z0-9_.:+-]`; invalid identifiers become empty. Native
progress first falls back to an incomplete planned slot, then the last native
item, then a generic item. yt-dlp defaults absent IDs/status to `unknown`,
counters to `0`, optional plan IDs and display strings to empty. Speed and ETA
are formatted display strings, not arithmetic inputs or fixed units;
empty, `NA`, `N/A`, `Unknown`,
`unknown`, `None` and `null` are omitted from the message.

The reader pads missing PLAN/V2/legacy/postprocess fields with empty strings;
surplus parsed fields make it ignore that record. ARIA2_PLAN and duration
require two parsed fields. Splitting uses Bash `read -a`, including its handling
of a trailing empty field; this is not a general escaped-delimiter format.
Unknown lines, consecutive duplicates and malformed count records are ignored.
CR becomes a line boundary. Records exceeding 1 MiB are discarded with a
generic progress warning. `out_time_us=N` advances only an active FFmpeg phase
with a positive denominator; other FFmpeg keys are ignored. No progress record
authorizes publication, deletion or a success result.

Adding fields to an existing name can therefore break older readers. Use a new
record name for incompatible changes, preserve legacy consumption until an
explicit compatibility decision, and test producer/consumer fixtures together.

## Managed runtimes and persistent state

`runtime-manager.sh` manages yt-dlp and Deno under:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/yt-dlp-aria2-downloader/runtime/
```

Each component has version directories and a `current` activation link.
Activation preserves installed binaries, including when a failed probe leads
to downloading an identical verified candidate: identical bytes retain their
existing inode. Repair may atomically replace a damaged copy whose bytes differ
from the verified candidate. Older version directories remain available because
an engine can still hold an attested path after several later activations;
keeping only `current` and `previous` would not protect those engines.
Updates are serialized with a lock, candidates are downloaded into
private work areas, authenticated or checksum-verified according to the
component contract, and validated for exact version and required capabilities
before activation. Personal curl and yt-dlp configuration and yt-dlp plugins
cannot alter these probes or downloads. The final validation captures both
immutable paths and versions; engine attestations reuse that exact result
instead of probing the executables again or resolving the mutable activation
links a second time. Activation uses a journal so interrupted link changes can
be recovered; a validated previous version remains available for rollback.

The selected XDG data root is resolved once to a canonical physical path before
use. Every existing component of that resolved path must be owned by root or
the current user and must not be replaceable by another user; later operations
never follow the original XDG spelling again. Lock acquisition
revalidates that the opened descriptor and the named mode-`0600` lock are the
same inode before and after `flock`, and distinguishes ordinary contention from
an operational locking failure. Runtime probe output is bounded before it is
captured in the shell, and invalid-version diagnostics use the same truncation
limit as other probe failures. Environment timeout values are validated as whole
decimal strings against fixed bounds before external operations.
Mutating `ensure` and `update` operations repair an
invalid active runtime through a verified bootstrap when no valid rollback is
available, while `require` remains strictly offline. Automatic updates refuse
a same-channel version downgrade; an explicit rollback remains available.

The manager records an ownership sentinel for custom XDG data roots. Its
secondary registry under HOME is resolved and checked independently, including
after directory creation, before writing a location marker. Package cleanup
uses that evidence to avoid deleting unrelated user data.

Bootstrap work directories, temporary GnuPG homes, and staged executables are
registered with an open descriptor and inode identity. HUP, INT, and TERM are
deferred while each temporary is created and registered. Bash waits for the
foreground command to finish before handling a pending signal; EXIT cleanup
then removes authenticated temporaries before releasing the update lock.
Changed identities and a GnuPG home whose agent cannot be stopped are preserved
with a warning. SIGKILL cannot run this cleanup. There is no global residue scan,
and capture files created inside probe command substitutions remain outside this
bootstrap tracking mechanism.

### Runtime attestation and temporary-resource contract

`runtime-manager.sh prepare update` or `prepare require` emits exactly five
LF-terminated lines, in this order, only after complete validation:

```text
runtime-contract=1
yt-dlp-path=<absolute immutable version path>
yt-dlp-version=<validated version>
deno-path=<absolute immutable version path>
deno-version=<validated version>
```

The separator is the first `=`; values are nonempty, line-safe strings without
escaping. Paths identify versioned assets, never `current` or `previous`.
The engine captures stdout privately and first requires successful supervised
completion. Shell command substitution removes trailing newlines; the parser
then requires exactly five ordered fields and rejects extra, missing, reordered
or unsupported-contract records. There is no unknown value or optional field.
Version compatibility is checked again without repeating the manager's
capability probes. Future incompatible changes require a new contract and coordinated reader support;
unknown fields are not silently ignored.

This attestation conveys a trusted adjacent component's validation result,
not a cryptographic signature or digest. yt-dlp acquisition authenticates a
signed checksum manifest; Deno checks the release checksum obtained over HTTPS,
not an equivalent signature. `require` performs no network update, but initial
storage/sentinel preparation can still write to disk. `update` can retain an
already validated pair after a bounded lock timeout or update failure.

The four `RUNTIME_TEMP_*` associative arrays are one logical resource table,
indexed by `work` (bootstrap directory), `gpg` (temporary GnuPG home), or
`staged` (executable before installation). Only complete authenticated
registration publishes path/identity/FD/kind together; its signal deferral
ends afterward. Cleanup revalidates, stops the GnuPG agent when applicable,
revalidates again, removes only an authenticated resource, then closes the FD
and removes all four entries. A preserved ambiguous residue is also
deregistered, never implicitly adopted by a later cleanup. After successful
executable publication the absent staging path merely causes descriptor
closure. EXIT belongs to the creating BASHPID and processes staged, gpg, work
before releasing the lock. Probe captures and sentinel temporaries are not
all covered by this table; it is not a registry of every runtime file.

The other persistent paths are:

| Data | Default location | Lifetime |
| --- | --- | --- |
| GUI preferences | `${XDG_CONFIG_HOME:-$HOME/.config}/yt-dlp-aria2-downloader/gui.conf` | Preserved across ordinary package removal; an unsafe XDG chain falls back to the validated HOME path |
| Retained sanitized logs | `${XDG_STATE_HOME:-$HOME/.local/state}/yt-dlp-aria2-downloader/download-*.log` | Self-identify their canonical final path, are pruned by age, and use the same safe-XDG fallback |
| Managed runtimes | `${XDG_DATA_HOME:-$HOME/.local/share}/yt-dlp-aria2-downloader/runtime/` | Preserved across upgrade/removal; eligible for proven-owned final RPM cleanup |
| GUI live session | Shared validated `private-root` / `yt-dlp-gui.*` | Local/private, removed after confirmed child shutdown; unconfirmed groups preserve active files |
| Transfer metadata | Validated local root / `.yt-dlp-aria2.*` | Plans, cookies, input, manifest, browser copies and internal paths; remove after confirmed shutdown, preserve changed identities |
| Direct-transfer media staging | Processing directory child `.yt-dlp-aria2.*` | Media and control files only; active directory descriptor/identity plus contents validated before cleanup |
| Network media workspace | Validated disk cache or `/var/tmp` root / `.media-work.*` | Local downloaded streams, fragments, native sidecars and remux; cleanup after shutdown, retain identified media on validation/publication failure |
| Network publication temporary | Selected destination / `.yt-dlp-publish.*.partial` | Copied media only; exclusive creation, no final name until copy/fsync, preserve ambiguous outcomes |

## Packaging architecture

`packaging/install-tree.sh` is the common payload assembler. The format-specific
builders wrap that tree:

- `packaging/rpm/build-rpm.sh` archives committed sources, builds the noarch RPM
  through the spec, and validates the produced payload;
- `packaging/deb/build-deb.sh` writes Debian control/checksum metadata, builds
  the architecture-independent DEB, and validates its payload;
- the RPM keeps `package-user-cleanup.sh` for two allowlisted lifecycle tasks:
  its install/upgrade scriptlet retires only exact historical project desktop
  entries that used the generic icon and would mask the system entry. The
  recognized schemas cover the three direct-Exec comment layouts and the later
  stable-link layout; a direct target must be a canonical quoted absolute path
  beneath HOME ending in `download-video-gui.sh`. The final erase scriptlet
  removes proven package-managed per-user data; migration preserves the
  portable launcher link and any current, modified, symbolic-link, or
  non-regular desktop candidate observed during validation. Automatic launcher
  migration skips accounts whose login shell ends in `/nologin`, `/false`,
  `/sync`, `/shutdown`, or `/halt`, without imposing UID or HOME-location
  restrictions on other accounts. This filter does not apply to final-erase
  enumeration or explicitly requested single-home operations;
- the DEB deliberately removes that helper and preserves per-user data on
  remove and purge.

Both package families test install/remove/reinstall and an upgrade from the
previous immutable release. Package assembly intentionally installs current
user documentation but not contributor-only policy, tests, skills, or this
architecture document. The source ZIP contains the tracked source tree.

## CI and release trust zones

| Workflow | Responsibility |
| --- | --- |
| `shell.yml` | PR source identity/coherence/syntax gate, pinned workflow checks, full local suite on Ubuntu/Fedora and Python 3.10 |
| `packages.yml` | Git-free source archive, RPM/DEB construction, lifecycle, authentication, and previous-release upgrade |
| `real-tools.yml` | Pinned real-tool behavior plus scheduled current-stable qualification |
| `qualification.yml` | Supported FFmpeg/FFprobe generation matrix |
| `stress.yml` | Twenty signal timing tuples and ten runtime transaction cycles; existing required check aggregates all five PR workflows |
| `promotion.yml` | Main-only authenticated verification of the complete PR source qualification, without suite execution |
| `shfmt-update.yml` | Prepare an untrusted formatter-pin candidate, verify it separately, and publish only allowlisted data |
| `release.yml` | Require the qualified tree and authorized tag, verify final ZIP identity, build/sign/test final native packages, attest and verify immutable public assets |
| `release-docs.yml` | After a successful immutable release, prepare and independently verify a bounded published-version patch, then publish a branch for a maintainer-reviewed documentation PR |

PR validation is attached to the entire Git tree. The five source workflows
record the GitHub event SHA in an isolated source-identity job name and verify
the checkout against it. The read-only `scripts/ci-validation.py` verifier uses
GitHub run/job metadata, exact workflow IDs/paths, latest attempts, complete
successful job inventories and immutable Git commit trees. It binds the tested
virtual merge's parents to the final PR HEAD and squash parent. The equal tree
includes every workflow, pin, parameter and test, so source/profile drift cannot
reuse an old success. No candidate artifact or dependency cache establishes
qualification. Historical content proof has no arbitrary calendar expiry; changed identity,
new failure or missing evidence invalidates reuse. Current external inputs and
explicit requalification/recovery are described in `TESTING.md`.

Each source workflow first checks its own immutable checkout identity, version
coherence and Bash syntax. The full shell contract and the complementary
qualifications then run independently: none holds a runner merely to poll for
shell completion. This favors the successful PR path; a late functional failure
can occur after complementary work has already started. The existing required
stress check still waits for all four complementary workflows and its own local
shards/runtime. This preserves deployed required-check names and complete
coverage before merge, without a circular wait or a partial-success shortcut.
Only `promotion.yml` runs on main pushes. It verifies source proof; release
independently repeats this inexpensive identity check before building and after
final package testing. Every release checkout directly uses `${{ github.sha }}`;
tag validation requires its target to equal that immutable event commit before
checkout. The final proof job independently checks this equality, and signer
and publisher reject a changed tag object. Job outputs carry proof data without
controlling checkout identity. A direct unqualified commit, stale merge base,
missing proof or new failure cannot obtain
release authority from a green status name. Source diagnostic dispatches and
scheduled tool checks do not substitute for PR qualification.

The final source ZIP is read as data and checked against exact Git blob contents,
paths and extraction modes. Native release builds remain separate because their
final containers/signatures and current installation/upgrade inputs differ from
PR candidates. Cross-run package artifacts are not promoted; their short build
time does not justify another provenance/retention trust boundary. The release
workflow no longer reruns full source suites. A parallel `release-runtime` job
retains routing and aria2 behavior for each of the two original yt-dlp versions
against newly resolved Ubuntu distribution dependencies. FFmpeg progress and
HLS duration run only in the latest-version matrix entry because those fixtures
do not depend on yt-dlp. This checks an external environment not identified by
the PR source proof. It records resolved package versions and gates final source
verification/publication, without delaying independent package builds.

Within a release run, builds, signing, package tests, publication and public
download verification pass immutable Actions artifact IDs through job outputs.
Each download requests one exact ID and rejects a digest mismatch; a replacement
artifact with the same name cannot substitute for the object already tested.

Third-party Actions are pinned by full commit SHA and checkout credentials stay
disabled. Jobs receive only the permissions they need. The Ubuntu validation
job verifies the pinned actionlint archive before running the shared explicit
workflow check; ordinary local fast/full validation does not provision this
additional tool. A separate setup-python job exercises the complete suite with
Python 3.10 and asserts the selected interpreter before starting.

Fedora jobs executing downloads use anonymous Docker volumes for `/tmp` and
`/var/tmp`, so private-state and media-workspace tests exercise the host volume's
actual local filesystem instead of an unqualified container overlay. The
isolated shfmt verifier likewise gets an anonymous `/var/tmp` disk volume while
retaining its `/tmp` tmpfs, read-only checkout, disabled network and dropped
capabilities. Its cleanup removes the disposable volume with the container.
No test storage volume grants access to a host home or changes publication
permissions.

The release workflow separates untrusted validation/build work from privileged
publication. The RPM signing job receives signing secrets but does not execute
candidate repository code. The publisher consumes reviewed artifacts and
revalidates their inventory and digests before attestation and publication.
Fresh-download verification independently compares public immutable assets with
the tested artifacts. Before any package or source archive is built, release
validation also requires the English/French published-asset references and
their static contract to match the tag version. This keeps the README files
embedded in the immutable ZIP, RPM, and DEB compatible with the version-locked
Fedora bootstrap; a later documentation update cannot repair those bytes.

The post-release documentation workflow is a separate `workflow_run` trust
zone. Its read-only preparation and verification jobs bind the triggering
successful `release.yml` run, semantic tag, exact source commit, and immutable
public release before producing a data-only patch when one is still needed.
For releases created under the tagged-documentation guard, the updater is
expected to be an idempotent no-op. Only the final job receives
`contents: write`; it does not execute repository code or check out any
repository ref. It resolves the protected `main` identity through the GitHub
API, requires the release SHA to be its ancestor and uses main or a target
branch descending from it as the immutable source base. If the published
references need updating, the read-only jobs independently reproduce the
three-file README/static transformation while retaining the source version.
The publisher validates these exact bytes, base modes, manifests and reference
catalogue using fixed isolated code, then uses Git database objects to create
or fast-forward a versioned automation branch. No-op updates do not publish;
divergent branches and detected reference races are refused. A maintainer then
opens the reviewed pull request; the workflow never writes directly to `main`
or receives pull-request permission.

Creating a tag, signing an RPM, publishing a release, or changing repository
secrets/environments is outside ordinary code-change authority.

## Validation architecture

`tests/lib/project-files.sh` is the canonical source inventory. `test-static.sh`
checks headers, Python 3.10 grammar/module identity, repository-skill file metadata,
version coherence, workflow pins and permissions, packaging contracts, and
exact agreement between tracked/non-ignored source paths and the file table in
`REPOSITORY_FILES.md`.

`tests/run-all.sh` schedules static validation and isolated integration suites.
Independent Python proof/automation replays are explicit timed tasks in the
same bounded static scheduler as formatting, source assertions and ShellCheck;
they are not nested serial work inside one long static task. Standalone
`test-static.sh` still runs the complete static contract, while its explicit
`--source-only` mode is a partial building block used by the scheduler. Every
Python family runs exactly once in either canonical profile before integration
starts; no persistent success cache substitutes for a test result.
The `fast` profile is a development loop; the default `full` profile is the
complete hermetic local contract. Its separate `doctor` mode diagnoses command,
filesystem, loopback, formatter-bootstrap, network, and repository capabilities
without running tests or provisioning tools. Real tools, privileged package
lifecycle, interactive Zenity, release evidence, upstream generations, and
stress runs are separate qualifications documented in `TESTING.md`.

Contributor control is layered around that runner. Repository skills route a
task to the relevant policy; issue and pull-request templates make scope,
invariants, validation evidence, and external authority explicit; conservative
Codex execution rules route unattended repository inspection through the
tracked fixed-action Git helper, which runs under the ordinary sandbox or
baseline policy without an explicit `allow` rule. They keep every direct Git
command, global-option form, GitHub CLI command, and common environment wrapper
interactive outside the sandbox, and forbid common force-push-to-`main` forms.
These controls improve task
execution but do not grant release, merge, or repository-administration
authority. These project controls depend on starting Codex in the trusted
repository; a file's existence or passing structure test does not prove it was
loaded into the active session. `TESTING.md` owns setup and task routing.

The version policy in `AGENTS.md` groups changes until explicit release
preparation. Ordinary commits, pushes, PR updates and automation retain the
coherent source number, including a previously published one. The helper
`scripts/check-push-version.py` checks linked source/published metadata offline;
its authorized-push mode additionally validates the remote snapshot. The tracked
`.githooks/pre-push`, enabled per checkout, checks the actual pushed regular Git
blobs as inert data, rejecting incoherence and reference races without demanding
an increment. Replacement refs cannot substitute different checked objects.

The read-only `source-context` API binds automation to main, target and tag
identities without preparing a bump. `next-version` is an explicit release
planning recommendation from numeric tags and an already prepared main version,
not a mandatory version derived from working branches. The offline
`scripts/prepare-source-version.py` retains an unpublished target or prepares an
explicitly selected new one across seven carriers, preserving modes and
rolling back controlled errors. Repeating the same target is a no-op.

Development RPM/DEB artifact names carry the source SHA and run ID;
Actions records bind their producing attempt and digest. Their numeric package
version and CLI output remain compatible and need no installed Git metadata. Only the
separate release chain can publish official signed/attested immutable objects.
A shared development version never authorizes changing a published tag or its
assets. `tests/push-version-integration.py` exercises same-version pushes,
incoherence, ref races and preparation in real temporary Git repositories;
CI integration also replays tag mismatch and changed-publication rejection.

Tests use private temporary homes, mock binaries, fixtures, and bounded process
supervision. The parallel runner binds cancellation to a child-published Linux
process start time and a private inherited token. If a fatal signal arrives
before publication, one `/proc` snapshot must instead bind the still-direct
launcher to the runner through its state, parent PID, and start time. The Python
session supervisor retains that identity until signal-resistant same-group
descendants have exited or the runner reaches authenticated KILL escalation;
inactive slots are reaped before any retained PID or process group is signaled.
The canonical and repetition executables enable Bash monitor mode so trapped
INT does not depend on Bash's foreground-child reaping handler. The sourced
library does not alter its caller's options. A monitor-mode child initially
leads a provisional process group: with managed signals blocked, the Python
supervisor joins its parent's group, then creates its own session without
changing PID. Group signaling additionally requires the authenticated process
to belong to that dedicated session (SID equals PGID), not merely to the
provisional group. A failed session transition exits 70 before starting the
command; pending managed signals retain their original cancellation semantics.
Terminal Ctrl-C can instead interrupt a foreground utility and take Bash
directly to EXIT with status 130. Both runners preserve INT on that path and
guard cleanup against repeated fatal signals. A provisional direct-child
identity is registered before foreground handoff polling or file removal, so
EXIT can also stop a worker whose normal identity handshake is incomplete.
The real-tool assembled-output fixture similarly lets the standalone engine
stop its own worker sessions on timeout or interruption; it preserves fixture
state when bounded cooperative shutdown remains unconfirmed. Its isolated
Python driver keeps qualification assertions active despite PYTHONOPTIMIZE.
Tests are part of the architecture: changing a trust, cleanup, progress,
process, packaging, or compatibility boundary requires updating or adding the
matching regression proof.

## Compatibility and independent validation

Persistent data can outlive the producer that created it. Absence from the
current happy path is not proof that a compatibility consumer is dead.

| Compatibility | Original purpose / current production | Current consumer and retention decision |
| --- | --- | --- |
| Legacy audio profile values | Older selectable MP3/M4A/Opus profiles; current settings writer emits `audio` instead | GUI maps `audio-mp3`, `audio-m4a`, `audio-opus` to `audio`; retain migration of existing settings |
| Older `download-*.log` names | Retained diagnostics predating the current naming/footer contract; old files persist | GUI pruning still validates ownership, mode and identity. Cleanup eligibility does not make an old log eligible for the current safe-view interface |
| Historical desktop schemas | Direct FR/EN/bilingual launchers and an older stable-link desktop using the generic icon; not emitted by current installer | RPM install/upgrade migration recognizes exact old schemas; retain so user entries do not mask the system launcher. Modified/custom entries remain preserved |
| Historical launcher temporaries | Old eight-alphanumeric tokens; current stages/backups use 24 hex characters | Launcher cleanup recognizes both narrow namespaces; interrupted old installations remain possible inputs |
| Partial launcher installations | Failed/interrupted transactions, including current ones | Optional branches remain `None`; rollback must never reinterpret them as the current directory. Preserve backups when restoration fails |
| Older runtime versions | Engines retain immutable attested paths while other sessions update `current`/`previous`; still produced | Keep older installed versions and identical inodes. No automatic collection based only on the activation links |
| `YTDLP_PROGRESS` | Old single-item progress records; current engine emits V2, fixtures still exercise legacy records | Monitor retains the legacy consumer. Removal requires an explicit interface-compatibility decision, not merely a producer grep |
| Forked `setsid` topology | Worker wrapper with a distinct direct-child session leader; normal current GUI launch is no-fork | GUI retains the authenticated direct-child leader fallback. It does not accept an arbitrary old numeric PGID |
| Unmarked aria2 staging | Older layouts or incomplete acquisition; no completed current session intentionally omits its marker | Old residue is reported/preserved, never adopted as deletion authority. There is no supported unmarked-cleanup mode |
| Packaging cleanup CLI | RPM migration/erase and re-execution as the target user | `--user-home*` has indirect callers; `--numeric-home` remains an exposed interface even without an in-tree caller. Retain unless explicitly deprecated |

The removed launcher validator parameter for an already-removed directory is
not an installation format: no transaction activated that mode. The separate
`launcher_removed` local in uninstall remains active and reports whether known
launcher leaves were actually removed; it does not mean the anchored parent
directory disappeared.

The following repeated checks intentionally retain independent implementations:

| Boundary | Shared contract / intentional difference |
| --- | --- |
| Engine / GUI YouTube classification | Remove the port, normalize host case and one terminal dot; recognize `youtube.com`, `youtu.be`, `youtube-nocookie.com` and their subdomains, not suffix lookalikes. GUI selects the experience; engine remains authoritative and revalidates profile eligibility |
| Engine / GUI private directory chains | Root/current-user ownership; group/other writable ancestors require sticky protection; canonical physical paths. Shared policy does not require a sourced shell library |
| Engine / GUI / runtime process handling | Common rule: numeric PID/PGID is not signaling authority and requested stop is not confirmed stop. Engine uses a leader/sentinel and observation-only lost-group veto; GUI additionally authenticates surviving token-bearing members; runtime bounds foreground probes and keeps child commands from retaining its lock FD |
| GUI / monitor result checks | Both require a contained canonical regular file from the last nonempty result line; monitor gates display, GUI gates the user-visible outcome/cancellation race, engine owns media validation |
| yt-dlp / Deno installation | Shared staging/activation primitives already exist; keep component-specific authentication, version and capability policies independent |
| Launcher install / uninstall | Publication order is link, icon, desktop; removal order is desktop, link, icon. Attempt flags precede mutations and reverse rollback preserves unrestored backups; a generic transaction loop must not hide these asymmetries |
| RPM / release / privileged publishers | Each trust boundary independently validates identities, signatures, digests and immutable source. A privileged publisher must not execute candidate code to validate that candidate |

Share documented contracts and boundary cases before considering code sharing.
Do not trade these independent refusals for a generic DRY abstraction.

## Change boundaries

When introducing a component or changing a connection between components:

1. update this document if the stable flow or boundary changes;
2. update `REPOSITORY_FILES.md` for every tracked path or changed consumer;
3. update source inventories and native packaging payloads when applicable;
4. update both READMEs only for user-visible behavior;
5. add or revise a regression test for the changed contract;
6. run the local and specialized validation required by `TESTING.md`.

Avoid duplicating a responsibility across GUI and engine, RPM and DEB builders,
or policy documents. Keep one authoritative implementation and make consumers
route through it.
