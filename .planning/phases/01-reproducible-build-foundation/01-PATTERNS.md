# Phase 1: Reproducible Build Foundation - Pattern Map

**Mapped:** 2026-08-25  
**Files analyzed:** 19 tracked path groups, plus generated artifact contracts  
**Local analogs found:** 1 / 19  
**Strong upstream analogs found:** 8 / 19  

## Repository Baseline

This repository is greenfield. The only existing implementation-adjacent file is `.gitignore`; there are no PowerShell modules, shell build scripts, Dockerfiles, tests, or runtime sources to copy. Accordingly:

- `exact-local` means an existing repository convention can be extended.
- `exact-upstream` means the file is a thin extension of a pinned upstream interface.
- `role-match-upstream` means an official interface defines the shape, but project orchestration remains new.
- `contract-only` means the phase research defines behavior but no implementation analog exists. The planner must treat the interface as a new Phase 1 contract and lock it with tests.

The Alpine links below use the readable `3.24-stable` branch, but implementation must fetch and verify commit `52643b7a176095362fd87fe73cdb994cb2e5ffae`. Do not build from the moving branch name.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog or Contract | Match Quality |
|---|---|---|---|---|
| `build.ps1` | controller | batch, request-response | `01-RESEARCH.md:228-270` | contract-only |
| `builder/inputs.json` | config/model | transform, batch | `01-RESEARCH.md:551-608` | contract-only |
| `builder/Dockerfile` | config/provider | batch | `01-RESEARCH.md:415-435` | role-match-upstream |
| `builder/profiles/mkimg.300k.sh` | config/provider | batch, file-I/O | Alpine `scripts/mkimg.standard.sh:71-87` | exact-upstream |
| `builder/cloud-init/meta-data.template` | config | event-driven, file-I/O | cloud-init NoCloud `meta-data` contract | exact-upstream |
| `builder/cloud-init/user-data.template` | config | event-driven, file-I/O | cloud-init NoCloud `user-data` contract | role-match-upstream |
| `scripts/host/Invoke-CheckedProcess.ps1` | utility | request-response, streaming | .NET `ProcessStartInfo.ArgumentList` | role-match-upstream |
| `scripts/host/Invoke-DockerBackend.ps1` | provider | request-response, batch | `01-RESEARCH.md:228-289,495-511` | contract-only |
| `scripts/host/Invoke-QemuBackend.ps1` | provider | event-driven, request-response, file-I/O | `01-RESEARCH.md:291-315,513-533` | contract-only |
| `scripts/linux/run-build.sh` | service | batch, file-I/O, transform | Alpine `scripts/mkimage.sh` | exact-upstream integration |
| `scripts/linux/init-signing-key.sh` | utility | file-I/O | Alpine `abuild-keygen` lifecycle | role-match-upstream |
| `scripts/linux/inspect-iso.sh` | utility | batch, file-I/O, transform | `xorriso` reporting contract in `01-RESEARCH.md:535-549` | role-match-upstream |
| `tests/phase1/run.ps1` | test | batch | `01-RESEARCH.md:724-771` | contract-only |
| `tests/phase1/Preflight.Tests.ps1` | test | request-response | `01-RESEARCH.md:737-765` | contract-only |
| `tests/phase1/LockAndManifest.Tests.ps1` | test | transform, file-I/O | `01-RESEARCH.md:737-765` | contract-only |
| `tests/phase1/BackendParity.Tests.ps1` | test | transform | `01-RESEARCH.md:737-765` | contract-only |
| `tests/phase1/fixtures/*` | test data | file-I/O | `01-RESEARCH.md:766-771` | contract-only |
| `.gitignore` | config | file-I/O | Existing `.gitignore:7-12,90-93` | exact-local |
| `README.md` | config/docs | request-response | BUILD-01 documented-entry requirement | contract-only |

## Critical Shared Seam

The planner should make this dependency direction explicit and testable:

```text
build.ps1
  -> creates one immutable BuildRequest
  -> selects exactly one adapter
       -> Invoke-DockerBackend.ps1 ----+
       -> Invoke-QemuBackend.ps1 ------+--> identical guest contract
                                              |
                                              v
                                  scripts/linux/run-build.sh
                                              |
                                              v
                                   identical staged-result contract
                                              |
                                              v
                             host validation + atomic publication
```

### Host `BuildRequest` contract

This is a new project contract, not an existing pattern. Create it once in `build.ps1` as an ordered, immutable-by-convention object and pass it unchanged to either adapter. At minimum it must carry:

- target (`Bootstrap`) and architecture (`x86_64`);
- source archive path plus SHA-256;
- exact public input/script/profile/repository hashes; the serialized `build-request.json` hash travels in the adapter envelope and is not a self-field inside the request;
- shared `run-build.sh` path plus SHA-256;
- `mkimg.300k.sh` path plus SHA-256;
- fixed source epoch;
- signing public-key SHA-256, never private-key bytes;
- bounded state, secret-input, run-staging, and export paths.

Backend-only observations such as Docker server version, accelerator, SSH port, overlay path, and absolute guest paths must not mutate content identity. They belong in the sanitized environment result.

### Canonical guest contract

Both adapters must materialize the same clean source snapshot, exact immutable request bytes, profile bytes, and shared script on a Linux-owned filesystem, then invoke that same script. Freeze the chosen paths in `tests/phase1/run.ps1` before backend implementation. Recommended fixed roles are:

| Guest role | Canonical location |
|---|---|
| Clean source snapshot | `/workspace` |
| Exact build request input | `/inputs/build-request.json` |
| Mutable build work | `/work` |
| APK cache | `/var/cache/apk` |
| Ephemeral signing material | `/run/300k-secrets` |
| Pre-publication export | `/export` |
| Shared build entry | `/workspace/scripts/linux/run-build.sh` |

The research Dockerfile example names `/workspace/scripts/linux/run-build.sh` as its entrypoint while also requiring a build context restricted to `builder/`. Those constraints do not populate that path at image-build time. The planner must resolve this explicitly: keep the builder image generic, extract the read-only Git archive into the Linux-owned `/workspace`, and have the adapter invoke the fixed shared entry only after extraction. Do not create a second Docker-only build script.

### Staged-result contract

Both adapters return the same host-visible result shape: stable result code, sanitized backend evidence, export staging directory, and retained diagnostic log paths. Only `build.ps1` validates and publishes. Neither adapter may write `out/LATEST.json` or final artifact names.

## Pattern Assignments

### `build.ps1` (controller, batch/request-response)

**Local analog:** None.

**Planning contract:** `01-RESEARCH.md:228-270`.

Use the researched public interface verbatim as the starting shape:

```powershell
param(
    [ValidateSet('Auto', 'Docker', 'Qemu')]
    [string] $Backend = 'Auto',

    [ValidateSet('Bootstrap')]
    [string] $Target = 'Bootstrap',

    [string] $StateRoot = (Join-Path $env:LOCALAPPDATA '300k-linux'),
    [string] $QemuRoot = 'D:\VM\qemu',
    [Nullable[long]] $SourceDateEpoch,
    [switch] $InitializeSigningKey,
    [switch] $PreflightOnly,
    [switch] $Clean
)
```

Required symbols/steps:

1. Set `$ErrorActionPreference = 'Stop'`.
2. Dot-source the three host scripts by paths rooted at `$PSScriptRoot`.
3. Validate canonical paths, clean Git state, pins, free space, key boundary, and output boundary.
4. Run explicit key initialization when requested, then create the clean `git archive`, fixed epoch, exact immutable BuildRequest bytes, and hashes; resolved package/output facts arrive later in a separate ResolvedBuildLock.
5. Implement backend semantics exactly: explicit `Docker` fails closed, explicit `Qemu` never probes Docker, and `Auto` performs one bounded Docker probe before sanitized QEMU fallback.
6. Validate the returned staging set, scan for secrets/absolute paths, copy as `.partial`, re-hash, atomically rename, and update `LATEST.json` last.

**Error pattern:** throw or return stable Phase 1 result codes, include a short actionable message, and never persist raw environment dumps or unredacted native output.

---

### `scripts/host/Invoke-CheckedProcess.ps1` (utility, request-response/streaming)

**Local analog:** None.

**Official primitive:** [.NET `ProcessStartInfo.ArgumentList`](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo.argumentlist) documents an argument collection whose elements do not require caller-side shell escaping. Use it instead of interpolated command strings.

PowerShell adaptation to implement and test:

```powershell
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $FilePath
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
foreach ($argument in $ArgumentList) {
    [void] $startInfo.ArgumentList.Add($argument)
}
```

Required function contract:

- `Invoke-CheckedProcess -FilePath <string> -ArgumentList <string[]> -TimeoutSeconds <positive int> [-WorkingDirectory <path>] [-RedactValue <string[]>]`;
- asynchronously drain stdout and stderr separately;
- on timeout, kill only the process tree it started and return/throw a distinct timeout code;
- propagate native exit code and retain split streams in memory;
- redact before formatting or persistence;
- never call `Invoke-Expression`, `cmd /c`, or a shell-built command line.

All host tool execution in `build.ps1` and both backend adapters must pass through this function so timeout, redaction, and exit behavior cannot drift.

---

### `scripts/host/Invoke-DockerBackend.ps1` (provider, request-response/batch)

**Local analog:** None.

**Planning contract:** `01-RESEARCH.md:228-289,495-511`.

Expose one adapter function, `Invoke-DockerBackend`, which accepts the common `BuildRequest` and the injected checked-process runner. Keep all ISO/profile/package logic out of this file.

Adapter sequence:

1. Prove a reachable Linux server and accepted `amd64`/`x86_64` architecture.
2. Pull and inspect the pinned digest with `--platform linux/amd64`.
3. Run the exact image to prove `uname -m`, `apk --print-arch`, and Alpine `3.24.1`.
4. Use named Linux volumes for workspace and APK cache, read-only input/key mounts, tmpfs for `/run/300k-secrets`, and only the per-run export bind as writable host storage.
5. Extract the clean archive into the canonical Linux workspace and invoke `/workspace/scripts/linux/run-build.sh`.
6. Return the common staged-result object.

Never mount the Docker socket, repository worktree, user home, or broad state root; never use `--privileged`; never persist raw `docker info`.

---

### `scripts/host/Invoke-QemuBackend.ps1` (provider, event-driven/request-response/file-I/O)

**Local analog:** None.

**Planning contract:** `01-RESEARCH.md:291-315,513-533`.

Expose one adapter function, `Invoke-QemuBackend`, with the same `BuildRequest` and checked-process runner interface as Docker. It owns only VM transport/state:

- verify the pinned cloud-image SHA-512 before use;
- keep the base immutable and create a per-run qcow2 overlay;
- attach the content-scoped persistent cache disk by virtio serial `300k-cache`;
- serve public-only NoCloud seed files on a dynamic loopback port;
- bind SSH forwarding to `127.0.0.1` only and use run-specific `known_hosts` plus an ephemeral management key;
- launch ordered `whpx` then `tcg,thread=multi` acceleration through `Invoke-CheckedProcess`;
- wait with finite metadata, cloud-init/SSH, and build bounds;
- transfer the same inputs, place the APK key only in `/run/300k-secrets`, invoke the same `run-build.sh`, and SCP validated staging back;
- retain serial evidence and terminate only the QEMU process this run started.

Do not use a writable FAT share or guest-home persistence for secrets.

---

### `builder/inputs.json` (config/model, transform/batch)

**Local analog:** None.

**Planning contract:** the immutable values in `01-RESEARCH.md:89-155` and lock shape in `01-RESEARCH.md:551-608`.

Keep only approved, public pins:

- Alpine release and v3.24 repository URLs;
- Docker index and linux/amd64 manifest digests;
- aports URL and exact 40-hex commit;
- main/community `APKINDEX.tar.gz` SHA-256 values;
- exact builder package revisions, including `gzip=1.14-r2`, `xz=5.8.3-r0`, `zstd=1.5.7-r2`, `lz4=1.10.0-r1`, and `cpio=2.15-r0` for inspection;
- an `inspection_toolchain` map from each supported format to its pinned package and fixed decoder/fixture-encoder argv prefix;
- fallback cloud-image URL/name and SHA-512;
- target architecture/profile and minimum host/tool constraints.

Use lower-case hex, explicit schema version, deterministic property order, LF, trailing newline, and UTF-8 without BOM. Reject unknown repository hosts, moving labels (`edge`, `latest`, `latest-stable`), malformed hashes, and absolute local paths. No username, machine name, secret path, private key, cache path, backend result, or wall-clock timestamp belongs here.

---

### `builder/Dockerfile` (config/provider, batch)

**Local analog:** None.

**Planning contract:** `01-RESEARCH.md:415-435`.

Copy the pinning pattern, not the unresolved entrypoint line:

```dockerfile
FROM --platform=linux/amd64 alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN apk add \
      abuild=3.17.0-r0 apk-tools=3.0.7-r0 alpine-conf=3.22.0-r0 \
      busybox=1.37.0-r31 fakeroot=1.37.2-r0 syslinux=6.04_pre1-r19 \
      xorriso=1.5.8-r0 squashfs-tools=4.7.5-r0 mtools=4.0.49-r0 \
      grub=2.14-r0 git=2.54.0-r0 ca-certificates=20260611-r0 \
      gzip=1.14-r2 xz=5.8.3-r0 zstd=1.5.7-r2 lz4=1.10.0-r1 cpio=2.15-r0
```

Write exact v3.24 main/community repositories before installation and arrange for index-hash verification. The image contains tools only. It must not copy source, keys, caches, or host configuration, and must not assume the shared script already exists until the adapter materializes `/workspace`.

---

### `builder/profiles/mkimg.300k.sh` (config/provider, batch/file-I/O)

**Upstream analog:** [Alpine `mkimg.standard.sh`, `profile_virt`, lines 71-87](https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.standard.sh#L71-L87).

Concrete inheritance pattern:

```sh
profile_virt() {
    profile_standard
    profile_abbrev="virt"
    title="Virtual"
    arch="aarch64 armv7 x86 x86_64"
    kernel_addons=
    kernel_flavors="virt"
    syslinux_serial="0 115200"
}
```

Project assignment:

```sh
profile_300k_bootstrap() {
    profile_virt
    profile_abbrev="300k"
    image_name="300k-bootstrap"
    title="300K Linux Bootstrap"
    desc="Pinned build-pipeline proof; not the final runtime."
}
```

Keep this thin. Do not duplicate kernel, bootloader, package-index, or ISO assembly functions. Install it as `$HOME/.mkimage/mkimg.300k.sh`, hash its exact bytes, and prove `--profile 300k_bootstrap` resolves before the expensive build.

---

### `builder/cloud-init/meta-data.template` and `user-data.template` (config, event-driven/file-I/O)

**Upstream contract:** [cloud-init NoCloud documentation](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html).

The official contract requires YAML `meta-data` with an `instance-id`; NoCloud fetches files named exactly `meta-data` and `user-data`, and the seed URL must end in `/`. Apply that shape as follows:

- `meta-data.template`: public run identity and local hostname only; make `instance-id` unique per disposable overlay so first-boot logic runs.
- `user-data.template`: begin with `#cloud-config`; create the bounded build user, install only the ephemeral management public key, disable password authentication, enable SSH/cloud-init readiness, and mount/discover the cache by virtio ID rather than `/dev/vdb`.
- Never render APK private-key bytes, SSH private-key bytes, credentials, tokens, host usernames, or broad host paths into either file.

The exact Alpine cloud-image module defaults are unproven. Treat the first NoCloud/SSH boot as a capped integration spike and retain sanitized serial evidence before freezing more fields.

---

### `scripts/linux/run-build.sh` (service, batch/file-I/O/transform)

**Upstream analogs:**

- [Alpine `mkimage.sh`, plugin loading and profile dispatch, lines 92-103 and 136-180](https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh#L92-L180)
- [Alpine `mkimage.sh`, signing key/repository setup, lines 250-280](https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh#L250-L280)
- `01-RESEARCH.md:454-493` for the exact detached-checkout/build invocation.

The upstream extension seam to reuse is:

```sh
load_plugins "$scriptdir"
if [ -n "$HOME" ]; then
    load_plugins "$HOME/.mkimage"
fi

profile_$PROFILE
# upstream later calls create_image_${output_format}
```

Project script pattern:

- start with `set -eu` and install an `EXIT` trap that removes only the tmpfs key copy;
- validate fixed input paths, exact hashes, target/profile/epoch, and archive entries before extraction/use;
- verify repository indexes before and after the build;
- fetch/checkout the exact aports commit and assert clean detached HEAD;
- set `HOME`, `SOURCE_DATE_EPOCH`, `PACKAGER_PRIVKEY`, and `PACKAGER_PUBKEY` to the canonical Linux paths;
- invoke pinned `mkimage.sh` once with repeated `--repository`, `--arch x86_64`, `--profile 300k_bootstrap`, content-addressed workdir, and `--checksum`;
- emit package/APK hashes and invoke `inspect-iso.sh`;
- stage only the allowlisted result set under `/export`, never publish final host output.

Do not implement backend detection, Docker/QEMU commands, host paths, or key generation here.

---

### `scripts/linux/init-signing-key.sh` (utility, file-I/O)

**Local analog:** None.

**Upstream behavior:** Alpine `abuild-keygen -a -n`; `mkimg.base.sh` requires `PACKAGER_PRIVKEY` when modloop signing is enabled.

[Alpine `mkimg.base.sh`, lines 5-24](https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.base.sh#L5-L24) provides the fail-closed signing pattern:

```sh
if [ "$modloop_sign" = "yes" ]; then
    if [ -z "$PACKAGER_PRIVKEY" ]; then
        error "Need \$PACKAGER_PRIVKEY to be set for modloop_sign=yes"
        return 1
    fi
fi
```

Make initialization an explicit, idempotence-guarded operation. Generate once, copy the pair to the external secret boundary, set private mode `0600` in Linux, return only public filename/hash, and fail if ordinary build mode lacks the pair. Never silently rotate or regenerate.

---

### `scripts/linux/inspect-iso.sh` (utility, batch/file-I/O/transform)

**Upstream analog:** [Alpine `mkimg.base.sh`, hybrid ISO assembly, lines 231-300](https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.base.sh#L231-L300).

The upstream source creates ISOLINUX El Torito data, an alternate EFI image, `bootx64.efi`, and hybrid GPT markers. Inspect those outputs instead of recreating them:

```sh
sha256sum -c "$ISO.sha256"
stat -c '%s' "$ISO"
xorriso -indev "$ISO" -pvd_info
xorriso -indev "$ISO" -report_el_torito plain
xorriso -indev "$ISO" -report_el_torito as_mkisofs
xorriso -indev "$ISO" -report_system_area plain
xorriso -indev "$ISO" -find / -type f -exec lsdl
```

Treat every image/container as hostile. Before writing a byte, obtain the complete member/type/declared-size/link manifest, reject duplicate canonical paths, non-directory ancestors, special objects, cycles, escaping links, and a declared expansion over budget. Materialize only directories and regular-file streams into a new mode-0700 scratch root: parents must pass `lstat` as real directories, each destination is an exclusive `.partial`, and links are scanned from the manifest but never created. For ISO regular files use pinned `xorriso -osirrox on:o_excl_on ... -extract_single`; for tar/cpio/SquashFS use the pinned tool's list operation followed by per-regular-member stdout/`-cat` streaming into the same bounded sink. Repeat preflight for every nested container and abort the decoder when actual bytes would exceed the remaining global budget.

The dedicated command set comes only from `builder/inputs.json`: `gzip=1.14-r2`, `xz=5.8.3-r0`, `zstd=1.5.7-r2`, `lz4=1.10.0-r1`, `cpio=2.15-r0`, plus the already pinned `xorriso` and `squashfs-tools`. `run-build.sh` verifies command paths, exact package ownership, deterministic round trips, and normalized version output before disabling networking; `ResolvedBuildLock` records those facts with the retained APK hashes. Missing commands, ambient aliases, version mismatches, unsupported magic, or trailing payload fail closed.

Write deterministic text reports, scan names, manifest link targets, and regular-file content for the secret/host-path denylist, allow only the expected `.rsa.pub`, and label the result `structural`. Hostile tests place canaries outside scratch and prove absolute/traversal/link fixtures cannot alter them or create any sibling path. Do not claim BIOS or UEFI boot success in Phase 1.

---

### `tests/phase1/run.ps1` (test, batch)

**Local analog:** None. Do not introduce Pester; research explicitly selects a self-contained PowerShell 7 harness.

Required runner symbols/behavior:

- parameters `-Scope` (`Unit`, `Docker`, `Qemu`, `Artifact`, `All`) and optional `-Requirement`;
- small assertion helpers such as `Assert-True`, `Assert-Equal`, `Assert-Match`, and `Assert-ThrowsCode`;
- dot-source the three `*.Tests.ps1` files;
- filter cases before execution, print one concise result per case, aggregate failures, and exit nonzero if any fail;
- Unit scope must use injected process/path fixtures and must not call Docker, QEMU, network, or mutate real external state.

---

### `tests/phase1/Preflight.Tests.ps1` (test, request-response)

**Local analog:** None.

Copy cases from `01-RESEARCH.md:748-755`: distinct Docker client/server/platform failures, stderr separated from JSON stdout, `Auto` fallback rules, QEMU/firmware/TCG discovery, and canonical-path edge cases. Inject the native-process runner and filesystem probes so each result is deterministic.

---

### `tests/phase1/LockAndManifest.Tests.ps1` (test, transform/file-I/O)

**Local analog:** None.

Use table-driven valid/invalid fixtures for pins, hashes, epoch, approved URLs, relative output names, bytes/hashes, secret markers, host paths, and atomic publication. Include a failure injection proving `.partial` files never replace the prior `LATEST.json`.

---

### `tests/phase1/BackendParity.Tests.ps1` (test, transform)

**Local analog:** None.

This is the architectural guardrail. Given one `BuildRequest`, capture the Docker and QEMU canonical invocation records and compare these fields exactly:

- source archive and lock hashes;
- script and profile hashes;
- aports commit and repository-index hashes;
- target, architecture, epoch, and signing public-key hash;
- canonical guest path roles and shared entrypoint.

Ignore only backend transport fields. A test must fail if either adapter embeds profile, package, `mkimage`, or publication logic rather than delegating to `run-build.sh`.

---

### `tests/phase1/fixtures/*` (test data, file-I/O)

**Local analog:** None.

Create small, sanitized fixtures only: Docker daemon absent/Windows/wrong-arch output, QEMU/firmware discovery results, good/bad lock JSON, good/bad manifests, secret-marker samples, and a canonical invocation record per backend. Fixtures must contain relative or obviously fictional paths and no copied host environment or real keys.

---

### `.gitignore` (config, file-I/O)

**Local analog:** existing secret and artifact blocks at `.gitignore:7-12,90-93`.

Current convention:

```gitignore
out/
*.iso
*.qcow2
*.pem
*.key
secrets/
credentials/
```

Extend the same section with `*.rsa` and the exact project-local state directory if one is introduced. Keep public `*.rsa.pub` trackable only when deliberately needed; external generated public identity should normally remain under the external state root.

---

### `README.md` (config/docs, request-response)

**Local analog:** None.

Document only the stable public contract: prerequisites, the `build.ps1 -Backend Auto -Target Bootstrap` command, explicit signing-key initialization, external state/output locations, Docker-to-QEMU fallback behavior, test commands, result codes, cleanup scope, and actual artifact/evidence names. Clearly call Phase 1 output a bootstrap artifact rather than a finished or boot-verified distribution.

## Generated Artifact Contracts

These are runtime outputs, not hand-maintained source. Their ownership must remain singular:

| Generated File | Producer | Validator/Publisher | Pattern |
|---|---|---|---|
| `signing-public.json` | `run-build.sh init-signing-key` | selected adapter and `build.ps1` | public basename/hash only; exists before BuildRequest |
| `build-request.json` | `build.ps1` | both adapters verify exact bytes; guest does not reserialize | ordered known content inputs, relative/public values only |
| `resolved-build-lock.json` | `run-build.sh prepare-repository` | `build.ps1` | request hash, complete repository/APK/aports facts, pinned inspection-package APK hashes, resolved decoder paths/versions, and generated-output facts |
| `builder-packages.lock` | `run-build.sh` | `build.ps1` | sorted installed package manifest |
| `apk-files.sha256` | `run-build.sh` | `build.ps1` | sorted cached APK byte hashes |
| `SHA256SUMS` | `run-build.sh` | `build.ps1` re-hashes independently | relative basenames only |
| `boot-layout.txt` | `inspect-iso.sh` | `build.ps1` | structural report, not boot claim |
| `qemu-image-info.json` | host QEMU tool | `build.ps1` allowlist/sanitize | exact exported ISO parse evidence |
| `environment-report.json` | selected adapter | `build.ps1` | allowlisted backend facts only |
| `artifact-manifest.json` | `build.ps1` after validation | tests and downstream phases | relative files, SHA-256, bytes, media type |
| `out/LATEST.json` | `build.ps1` last | atomic-publication tests | pointer changes only after complete success |

Use the JSON shapes at `01-RESEARCH.md:551-659`. Placeholder numeric zeros in research examples must be replaced with positive measured values and rejected in completed artifacts.

## Shared Patterns

### Validation

Apply allowlists before tool execution: enums, exact digest/hash formats, positive epoch, approved HTTPS repository origins, canonical non-reparse-point boundaries, and archive entries without absolute or `..` traversal. Validate both before backend dispatch and again before publication.

### Error Handling

One checked-process utility owns timeouts, process-tree termination, stream separation, exit-code propagation, and redaction. Higher layers add stable Phase 1 result codes and context; lower layers must not print secrets or broad environment state.

### Secret Boundary

Private APK and SSH keys remain outside Git, enter the guest through a bounded read-only input, are copied only to `/run/300k-secrets`, and are removed on exit. Public filename/hash may enter evidence; private path/content may not. Ordinary builds never generate keys.

### Deterministic I/O

Use clean `git archive` bytes, fixed `SOURCE_DATE_EPOCH`, exact request bytes, a separately linked post-resolution lock, sorted manifests, relative basenames, LF, UTF-8 without BOM for JSON, and content-addressed work namespaces. Never copy or mount the Windows worktree as the Linux build root.

### Atomic Publication

Build and inspect outside `out/`; copy validated artifacts as `.partial`; host re-hash; rename within one build directory; update `LATEST.json` last. Failure and timeout leave the previous pointer untouched.

## No Local Analog Found

No local implementation analog exists for any new Phase 1 code or test file. `.gitignore` is the sole local pattern. In particular, the planner must not describe the researched snippets as existing project code. The following contracts need tests before other phases depend on them:

| Contract | Why tests must freeze it |
|---|---|
| `BuildRequest` and adapter result objects | Both transports must stay behaviorally interchangeable. |
| Canonical guest paths/invocation | Resolves the Docker build-context/entrypoint seam and prevents two build cores. |
| JSON schemas and stable result codes | Downstream evidence tooling will consume them. |
| Native process timeout/redaction behavior | Every external tool inherits this security boundary. |
| NoCloud readiness and SSH provisioning | The exact Alpine cloud artifact has not yet been boot-proven locally. |
| QEMU cache device discovery | `/dev/vdb` ordering is not a stable interface. |
| Atomic publication behavior | A failed overnight run must preserve last-known-good evidence. |

## Metadata

**Analog search scope:** repository root including hidden tracked files; `.codex/skills` and `.agents/skills` were absent.  
**Repository implementation files found:** `.gitignore` only; all other visible files are planning/project instructions.  
**External patterns used:** Alpine aports `3.24-stable` image scripts, cloud-init NoCloud contract, .NET `ProcessStartInfo.ArgumentList`; exact project behavior comes from `01-RESEARCH.md`.  
**Files scanned:** 14 repository files plus the three required Phase 1 inputs.  
**Pattern extraction date:** 2026-08-25
