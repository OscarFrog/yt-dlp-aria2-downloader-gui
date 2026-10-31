# Contributing to yt-dlp aria2 downloader

Bug reports, feature suggestions, documentation and code improvements are
welcome in English or French. Use your usual editor and development tools.

## Report a problem or suggest an improvement

Search the [existing issues](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/issues)
first, then use the [bug report](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/issues/new?template=bug-report.yml)
or [feature request](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/issues/new?template=feature-request.yml)
form. Describe the outcome you need and a small reproducible example where
possible. For a bug, include the application version, installation method,
GNU/Linux distribution, expected behavior and actual result.
Use [Discussions](https://github.com/OscarFrog/yt-dlp-aria2-downloader-gui/discussions)
for usage questions and open-ended ideas.

Public reports must not contain cookies, tokens, credentials, authentication
headers, private media URLs, personal data or unredacted logs. Review even
sanitized logs: local paths and media titles can remain personal. Share only
the relevant redacted excerpt. Report suspected vulnerabilities through
[the security policy](SECURITY.md), not a public issue or pull request.

## Prepare a pull request

1. Start a focused branch from the latest `main` in your fork. Discuss a large
   change in an issue before implementing it.
2. Read the relevant [architecture](ARCHITECTURE.md), [testing](TESTING.md) and
   [shell conventions](SHELL_STYLE.md). Preserve the existing privacy,
   verification, cleanup and user-data protections.
3. Add regression coverage where behavior changes. Keep English and French
   READMEs equivalent and update [the file inventory](REPOSITORY_FILES.md) for
   added, removed or repurposed files.
4. Open a PR against `main` and complete its template with the reason for the
   change, risks and validation actually performed.

Ordinary contributions do not require a version bump. Keep all version copies
coherent and leave published tags and release assets unchanged; see
[version coherence](TESTING.md#version-coherence-and-release-preparation).

## Validate your change

Run from the repository root. The doctor checks your environment before the
complete local suite:

```bash
python3 -B scripts/check-push-version.py coherence
./tests/run-all.sh --doctor
./tests/run-all.sh --full --jobs 4
git diff --check
```

Use the [task-to-test table](TESTING.md#codex-session-setup-and-task-routing)
for focused tests during development and additional qualifications. Shell
changes also require `./scripts/check-shell-format.sh`; workflow changes
require `./scripts/check-workflows.sh`. Before a source push, run
`python3 -B scripts/check-push-version.py check` and follow the documented
[pre-push hook setup](TESTING.md#version-coherence-and-release-preparation).

If a dependency or environment capability prevents a check, report the exact
command and limitation in the PR. Do not weaken assertions or security checks
to make a test pass. A local full pass does not replace the real-tool,
packaging or graphical qualifications described in `TESTING.md`.
