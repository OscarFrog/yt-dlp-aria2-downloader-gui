# Rust style and safety policy

This policy applies to production, qualification and development crates. Use the
[architecture](ARCHITECTURE.md) for component boundaries and the
[qualification procedures](TESTING.md#rust-qualification) for executable checks.

## Platform and supported compiler

Use Rust edition 2024 and the stable Fedora 45 x86_64 GNU/Linux toolchain from
the distribution. The supported floor is Rust **1.100**, qualified with Fedora
rustc 1.100.0. Declare `rust-version = "1.100"` in Cargo.toml. The floor
describes the compiler we support and test. Qualify any proposed lower floor
on Fedora before making a compatibility promise. Qualify newer Fedora toolchains
through the same checks. A build on a newer compiler alone cannot establish
the floor. Record the target, compiler release and RPM versions when changing
the toolchain contract. [Cargo rust-version](https://doc.rust-lang.org/cargo/reference/rust-version.html)

## Crate structure, names and documentation

- Give each crate a durable responsibility and name. Set the MIT license and
  `publish = false` for private crates. Keep system interfaces, protocol
  parsing and state management distinct where their invariants differ. Add
  a library or trait when there is an actual consumer or substitution boundary.
- Start Rust sources with `// SPDX-License-Identifier: MIT` followed by
  `//!` documentation of the module's role. Write technical comments in
  English. Use `///` to document APIs, resource ownership and non-obvious
  caller obligations. Describe recoverable errors under `# Errors`, justified
  panic conditions under `# Panics`, and caller obligations for unsafe
  functions under `# Safety`.
- Use `snake_case` for functions and modules, `UpperCamelCase` for types and
  enum variants, and `SCREAMING_SNAKE_CASE` for constants. Give units to
  numeric fields and distinguish process IDs from task IDs. Start with private
  visibility and expose the narrowest interface a caller actually needs.
  Review all consumers, including protocols, before narrowing an interface.
  [Rust Style Guide](https://doc.rust-lang.org/style-guide/) · [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/)

## Results, ownership and external data

- Return `Result` for failures and `Option` for an absence the caller can
  interpret. Preserve the operation, phase and relevant OS error. Propagate
  the primary failure while attempting independent cleanup. Retain bounded
  secondary diagnostics when useful. Distinguish a proven exit from denied,
  timed-out or incomplete observation when authorizing cleanup.
- Handle external input, OS failures and allocation limits through explicit
  errors. Keep production `panic!`, `unwrap` and `expect` confined to local
  invariants whose justification is apparent at the call site. Assertions in
  tests should identify the contract that failed.
- Borrow for inspection, move ownership when responsibility transfers, and
  use RAII for unconditional cleanup. Prefer iteration over borrowed values
  for queries. Justify copies, clones and allocations by their use or lifetime.
  Bound protocol frames before growing buffers, and bound nested fields and
  collections before decoding. Check narrowing integer conversions and
  arithmetic involving lengths, timeouts and externally supplied values.
- Use `Path` and `OsStr` for borrowed filesystem names, their owned types
  when storage is required, and bytes for arbitrary kernel or file data.
  Decode UTF-8 explicitly at text protocol boundaries. Compare identities in
  their original representation. Keep serialized fields, exit codes,
  cancellation semantics and stdout/stderr roles compatible with callers.
- Public diagnostics identify a technical cause independently of the content
  provider. Keep private URLs, headers, tokens, cookies, environment contents
  and raw process arguments out of logs, panics and debug dumps. Test data
  crossing a private protocol and data allowed in a public diagnostic separately.

## Descriptors, processes and concurrency

Represent ownership with `OwnedFd` or `File`, and borrow with `BorrowedFd` or
`AsFd`. Keep raw descriptors at the ABI boundary. Convert a newly returned
descriptor to an owner exactly once. When a close error matters to the caller,
consume the owner explicitly, preserve any earlier failure and observe the OS
close semantics. Retrying a failed Linux close can close a reused descriptor.
[Standard descriptor types](https://doc.rust-lang.org/std/os/fd/index.html)

Authenticate identity, ownership, permissions and containment before acting on
files. Anchor operations to an admitted descriptor across pathname changes.
Preserve uncertain files and live resources. For process actions, bind the
authorized process generation and lifetime through the project's pidfd and
cgroup contracts. A reused PID, an unreadable process or a zombie leader with
live threads each requires a distinct decision.

Assign a termination and collection owner to every worker or child. Make
cancellation, signal delivery, deadline expiry and join or wait outcomes
observable. Bound waits with monotonic deadlines and preserve the clock and
units in exchanged timestamps. Use explicit readiness handshakes in tests.
An observation-only component retains observation-only authority.

## Unsafe Rust and the Linux ABI

Keep unsafe operations in narrow wrappers with a safe interface when their
preconditions can be established there. Enable `deny(unsafe_op_in_unsafe_fn)`
for each crate. Place a meaningful `// SAFETY:` comment at each unsafe block
and unsafe implementation. State the relevant lifetimes, pointer validity,
layout, bounds, aliasing, ownership transfer or syscall guarantees. Enforce
the presence of these comments with Clippy's `undocumented_unsafe_blocks`
lint. Review establishes whether the justification is correct.
[Edition Guide](https://doc.rust-lang.org/edition-guide/rust-2024/unsafe-op-in-unsafe-fn.html)

For `unsafe extern "C"` declarations, check the signature, signedness, widths,
variadic arguments and return/error convention against the target headers.
Use `#[repr(C)]` for shared structures and verify sizes, alignments and
field offsets when their declarations change. Bind numeric ABI constants to
their Linux x86_64 definitions. Keep buffers and borrowed descriptors live
through the call. Read errno at the failing boundary. Exercise both success
and refusal on the supported kernel, including thread and group lifetimes
where those differ. [Rust Reference](https://doc.rust-lang.org/reference/items/external-blocks.html)

## Dependencies, builds and review

Prefer the standard library when it expresses the required contract. Review
each external crate's purpose, license, transitive dependencies and build-time
execution, including build scripts and procedural macros. Track Cargo.lock
for executables and workspaces. Build with the distribution tools, a locked
resolution and offline inputs. A deterministic build claim requires evidence
from the toolchain, linker, inputs and resulting bytes. A cache hit establishes
only reuse for its declared key. [Cargo build options](https://doc.rust-lang.org/cargo/commands/cargo-build.html)

Use stable rustfmt defaults for the edition, Clippy across all targets with
warnings denied, and frozen release-mode Cargo tests. Document a narrow lint
exception at its site if its semantic need survives review. Add configuration
only for an adopted behavior the existing tools cannot express by default.
Combine unit tests for the state and parser with behavioral tests at the actual
OS or protocol boundary. Preserve negative controls, independent witnesses and
failure paths for identity, privacy, cancellation and cleanup. For distributed
binaries, qualify the installed RPM and ZIP interfaces and verify the published
artifact through the existing signing and attestation boundaries.
[rustfmt](https://github.com/rust-lang/rustfmt) · [Clippy](https://doc.rust-lang.org/clippy/)
