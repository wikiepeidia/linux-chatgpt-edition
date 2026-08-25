# Phase 1: Reproducible Build Foundation - Research

**Researched:** 2026-08-25  
**Domain:** Windows-to-Linux ISO build orchestration, Alpine `mkimage`, secret isolation, and QEMU fallback  
**Confidence:** MEDIUM

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- Establish one pinned, secret-safe Windows-to-Linux image-building environment that can produce and identify a bootstrap Alpine ISO. This phase proves the builder, artifact transfer, signing-key boundary, QEMU discovery, and fallback path; it does not yet build the final diskless runtime or graphical product.

### Claude's Discretion

- All implementation choices are at Claude's discretion because this is a pure infrastructure phase and the user explicitly delegated the overnight build.
- Use Alpine Linux 3.24.1, a pinned `3.24-stable` aports commit, and a Linux/amd64 builder rather than a moving branch or a different distribution.
- Prefer Docker Desktop Linux containers after an explicit daemon/platform preflight; use an Alpine QEMU build VM as the documented fallback without changing profiles or runtime architecture.
- Keep Linux-sensitive build work on a Linux-owned volume so Windows CRLF, executable-bit, ownership, and symlink behavior cannot silently corrupt inputs.
- Persist the APK signing key and caches outside Git and runtime artifacts; record public identity and resolved inputs without exposing private material.
- Treat one PowerShell entry point as the host contract and fail early with actionable diagnostics for Docker, platform, QEMU, firmware, disk space, and artifact paths.

### Deferred Ideas (OUT OF SCOPE)

- Diskless offline package installation, graphical startup, comedy UI, firmware/media matrix, and size optimization remain in their dedicated later phases.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BUILD-01 | A contributor can invoke one documented PowerShell entry point from Windows to build the x86_64 ISO in a pinned Linux/amd64 environment; QEMU may satisfy the default working build, while explicitly selected Docker requires a real verified Linux/amd64 daemon. | Defines the `build.ps1` contract, exact builder/index/aports pins, clean source snapshot, fixed epoch, Linux-owned storage, the working QEMU path, and strict Docker platform proof when Docker is selected. [VERIFIED: `.planning/REQUIREMENTS.md:12`] |
| BUILD-03 | Private signing keys, credentials, tokens, host paths, and build caches remain outside Git and outside the runtime ISO. | Defines the external state/secret roots, ephemeral guest secret path, read-only ordinary-build mounts, public-only manifests, denylist scans, and atomic export boundary. [VERIFIED: `.planning/REQUIREMENTS.md:14`] |
| BUILD-04 | If Docker Linux containers are unavailable, the documented fallback can perform the same build inside an Alpine VM without changing the distribution architecture. | Defines a pinned official Alpine x86_64 cloud image, immutable base plus overlay, NoCloud/SSH provisioning, and the same Linux build script/profile/lock used by Docker. [VERIFIED: `.planning/REQUIREMENTS.md:15`] |
</phase_requirements>

## Project Constraints (from AGENTS.md)

- Prioritize the first verifiable artifact overnight; the near-100 MB figure is a stretch target and actual size must be reported. [VERIFIED: `AGENTS.md:15-16`]
- The eventual runtime is fully local/offline and must not contain API keys, credentials, user account data, OpenAI APIs, Codex, accounts, or cloud dependencies. [VERIFIED: `AGENTS.md:7,17`; `.planning/phases/01-reproducible-build-foundation/01-CONTEXT.md:46-48`]
- Target x86_64 VMs, use the supplied `D:\VM\qemu`, and support BIOS plus non-Secure-Boot UEFI when later boot phases prove them. [VERIFIED: `AGENTS.md:18-20`; `.planning/REQUIREMENTS.md:21-23`]
- The build host is Windows without WSL or a native Linux build chain. [VERIFIED: `AGENTS.md:19`]
- A final ISO is not done until graphical and terminal smoke tests pass; Phase 1 must call its output a **bootstrap artifact**, not a release. [VERIFIED: `AGENTS.md:21`; `.planning/phases/01-reproducible-build-foundation/01-CONTEXT.md:9`]
- Alpine `3.24.1`, the Docker base digest, `linux-virt`, Alpine `mkimage`, ISOLINUX, GRUB EFI, `xorriso`, `mtools`, and apkovl are the established project stack. [VERIFIED: `AGENTS.md:46-55`]
- The repository currently has no established code conventions or architecture; new build contracts must therefore be explicit. [VERIFIED: `AGENTS.md:120-130`]
- Work is already inside a GSD phase-research workflow. Implementation edits must later go through `/gsd-execute-phase`. [VERIFIED: `AGENTS.md:141-151`]
- Although the configuration contains the verbatim value `"nyquist_validation": false`, the orchestrator explicitly requested validation architecture in this research. Security remains enabled with the verbatim values `"security_enforcement": true` and `"security_asvs_level": 1`. [VERIFIED: `.planning/config.json:20-49`]

## Summary

Phase 1 should implement a backend-neutral build contract, not two build systems. A single root `build.ps1` validates committed pins and a clean Git snapshot, selects Docker or QEMU, and invokes one identical Linux script (`scripts/linux/run-build.sh`) with fixed guest paths and the same `300k_bootstrap` Alpine profile. Docker and QEMU are only transport/state adapters. Alpine's pinned `mkimage` scripts already assemble ISOLINUX, GRUB EFI, the EFI FAT image, the signed package index, modloop, and the hybrid ISO; this phase should extend `profile_virt`, not recreate those mechanisms. [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.base.sh] [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.standard.sh]

The Docker client is installed, but there is no reachable Docker server on this host. The primary path therefore cannot be considered validated yet, and BUILD-04 requires an executable QEMU path in this phase rather than fallback prose. QEMU 11.1.0, `qemu-img`, TCG/WHPX support, x86_64 EDK2 code, and the matching i386-named variables template are present. [VERIFIED: local host probes on 2026-08-25] The fallback should use Alpine's fixed 3.24.1 x86_64 cloud-init QCOW2, a per-run overlay, loopback-only SSH, and NoCloud metadata containing only a public management key. The exact cloud-image/NoCloud route is not yet boot-proven locally and must be the first bounded integration spike. [ASSUMED]

Repository URLs alone are not immutable: Alpine stable indexes can change as fixes land. The implementation must pin the observed `APKINDEX.tar.gz` hashes, install exact package revisions, retain verified APK bytes in an external Linux cache, record every resolved APK hash, and refuse to publish if an index changes during a run. Exact replay on a new host cannot honestly be promised after upstream removes old package bytes unless a verified cache/snapshot is also retained; Phase 1 should fail on drift rather than silently produce a different image. [CITED: https://wiki.alpinelinux.org/wiki/Repositories]

**Primary recommendation:** Implement `build.ps1 -Backend Auto -Target Bootstrap` as strict orchestration around one Linux `run-build.sh`, and make the phase gate one hashed bootstrap ISO plus checksum, lock, package list, boot-layout report, QEMU image-info report, and a passing real QEMU-fallback build.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Parameter validation and preflight | Windows host orchestration | Backend adapter | PowerShell owns user-facing paths, tools, timeouts, diagnostics, and backend selection; adapters perform backend-specific probes. |
| Reproducible source snapshot | Windows host orchestration | Linux build core | `git archive` captures committed blob contents/modes; extraction and all mutation happen on Linux-owned storage. |
| Docker execution | Docker adapter | Linux build core | The adapter proves a Linux/amd64 server/container and mounts only bounded state; it does not contain image-build logic. |
| QEMU fallback execution | QEMU adapter | Linux build core | The adapter provisions/transfers/shuts down the VM; the guest calls the same build script and profile. |
| Alpine ISO construction | Linux build core | Alpine upstream tooling | `mkimage.sh` and the thin project profile own package resolution and ISO assembly. |
| APK signing identity | External secret boundary | Linux build core | One external key identity is copied into Linux tmpfs for a build; only its public key and SHA-256 leave the boundary. |
| Package/work caching | Backend persistent state | Linux build core | Docker volumes or the dedicated VM cache disk preserve Linux semantics and are keyed by content inputs. |
| Artifact identity and publication | Linux evidence stage | Windows host orchestration | Linux creates and inspects the ISO; the host re-hashes, validates, sanitizes, and atomically publishes relative-name evidence. |
| Final boot/UI/terminal validation | Later phases | — | Phase 1 proves the build seam and ISO structure only; it must not claim product readiness. [VERIFIED: `.planning/phases/01-reproducible-build-foundation/01-CONTEXT.md:9`]

## Standard Stack

### Core

| Technology | Version / immutable pin | Purpose | Why Standard |
|------------|--------------------------|---------|--------------|
| PowerShell | Require 7+; host has `7.6.1` | One Windows entry point, process control, validation, hashing, and JSON emission | Available on the target host and supports `ProcessStartInfo.ArgumentList` and UTF-8-no-BOM output. [VERIFIED: local `pwsh --version`, 2026-08-25] |
| Alpine Docker Official Image | `alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b`; linux/amd64 manifest `sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f` | Pinned Linux builder root | Docker supports digest pulls and explicit platforms; recording index and amd64 manifest prevents tag/platform ambiguity. [CITED: https://docs.docker.com/reference/cli/docker/image/pull/] [CITED: https://hub.docker.com/layers/library/alpine/3.24.1/images/sha256-79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f] |
| Alpine aports | remote `https://gitlab.alpinelinux.org/alpine/aports.git`; commit `52643b7a176095362fd87fe73cdb994cb2e5ffae` | Exact `mkimage` implementation and upstream profiles | Direct `git ls-remote` resolved this 40-hex commit for `3.24-stable` on 2026-08-25; build the commit, never the moving branch. [VERIFIED: official GitLab `git ls-remote`, 2026-08-25] |
| Project profile | `profile_300k_bootstrap`, source SHA-256 recorded | Thin identity layer over `profile_virt` | `mkimage.sh` loads `mkimg.*.sh` plugins and invokes named `profile_*` functions; `profile_virt` selects the `virt` kernel and x86_64 support. [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh] [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.standard.sh] |
| Docker Engine/Desktop Linux containers | Client `29.6.0`; require live Linux server | Primary backend | `docker info`, digest pull, image inspect, and a real `linux/amd64` container probe prove the needed backend rather than assuming it from the CLI. [CITED: https://docs.docker.com/reference/cli/docker/system/info/] |
| QEMU | Local `11.1.0` at `D:\VM\qemu` | Required fallback VM and structural artifact reader | The exact local executables and TCG/WHPX accelerators were probed; multiple `-accel` entries fall through in order. [VERIFIED: local QEMU probes, 2026-08-25] [CITED: https://www.qemu.org/docs/master/system/qemu-manpage.html] |
| Alpine fallback image | `generic_alpine-3.24.1-x86_64-bios-cloudinit-r0.qcow2`; SHA-512 `8d756f6fc7653daa4fb4e2e213d8a66007bcb1e5a846e28891af62c47b90685c694486c2746099ad99e9e8f5278db76b69d11dfe1e9361aa4c8406df16929a9c` | Immutable, automatable QEMU guest base | The versioned artifact and sidecar hash were fetched from Alpine's official v3.24 release directory on 2026-08-25. [VERIFIED: https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/] |

### Builder APK Snapshot

All packages below are named by the pinned `mkimage.sh` prerequisite comment, are the two explicit checkout/TLS additions, or provide the decoder/fixture commands required by the recursive ISO audit. Versions and dates were read from the official v3.24 main/community x86_64 APKINDEX files on 2026-08-25. The observed compressed-index SHA-256 values are `main=0076ecf24f2b49c08d7546e987e070a34af57a90a6831fbd312388eac2b01fd7` and `community=23d7e4a77f658c9e9c4dd50b88ce111fa27fe69282ed4a55234da6a1f4e516ba`. These are initial lock values, not timeless claims. [VERIFIED: official Alpine v3.24 APKINDEX downloads, 2026-08-25]

| Package | Observed version | Build date | Purpose |
|---------|------------------|------------|---------|
| `abuild` | `3.17.0-r0` | 2026-06-05 | Key generation and repository/index signing |
| `apk-tools` | `3.0.7-r0` | 2026-07-28 | Package resolution, verification, and manifests |
| `alpine-conf` | `3.22.0-r0` | 2026-06-09 | Alpine image configuration helpers |
| `busybox` | `1.37.0-r31` | 2026-01-10 | Required shell/core tools |
| `fakeroot` | `1.37.2-r0` | 2026-01-20 | Filesystem ownership modeling without privileged mounts |
| `syslinux` | `6.04_pre1-r19` | 2025-12-02 | BIOS El Torito boot files |
| `xorriso` | `1.5.8-r0` | 2026-04-13 | ISO/hybrid assembly and structural reports |
| `squashfs-tools` | `4.7.5-r0` | 2026-05-25 | Provides pinned `unsquashfs` inspection and `mksquashfs` fixture/image commands |
| `mtools` | `4.0.49-r0` | 2025-06-14 | EFI FAT image creation without loop mounts |
| `grub` | `2.14-r0` | 2026-05-29 | x86_64 GRUB EFI bootloader |
| `git` | `2.54.0-r0` | 2026-04-20 | Detached aports checkout |
| `ca-certificates` | `20260611-r0` | 2026-06-13 | TLS trust for official HTTPS sources |
| `gzip` | `1.14-r2` | 2025-06-03 | Dedicated gzip decoder plus deterministic `-n` fixture encoder; do not rely on a BusyBox alias |
| `xz` | `5.8.3-r0` | 2026-04-25 | Dedicated xz/lzma decoder and fixture encoder |
| `zstd` | `1.5.7-r2` | 2025-07-28 | Dedicated zstd decoder and fixture encoder |
| `lz4` | `1.10.0-r1` | 2026-03-11 | Dedicated lz4 decoder and fixture encoder |
| `cpio` | `2.15-r0` | 2025-07-14 | GNU newc/crc manifest, member streaming, and fixture construction |

The inspection command surface is immutable public input, not an ambient guest capability. `builder/inputs.json` must map each exact package revision to fixed argv prefixes: `/bin/gzip -dc --` and `/bin/gzip -n -c --`; `/usr/bin/xz -dc --single-stream --` and `/usr/bin/xz -zc --check=crc32 --`; `/usr/bin/zstd -q -dc --` and `/usr/bin/zstd -q -c --`; `/usr/bin/lz4 -q -d -c --` and `/usr/bin/lz4 -q -c --`; `/usr/bin/cpio --list --verbose --quiet` and `/usr/bin/cpio --extract --to-stdout --quiet`; `/usr/bin/unsquashfs -lln` and `/usr/bin/unsquashfs -cat`; and `/usr/bin/xorriso` manifest/`-extract_single` operations with `-osirrox on:o_excl_on`. Before networking is disabled, the builder must install these packages from the verified content-addressed repository, resolve each command without following an unapproved alias, run codec round trips on deterministic fixtures, and record package revisions, APK hashes, resolved executable paths, and normalized version output in `ResolvedBuildLock`. Unsupported magic remains a hard failure rather than an invitation to choose an ambient decoder.

### Supporting

| Technology | Version | Purpose | When to Use |
|------------|---------|---------|-------------|
| Git for Windows | `2.55.0.windows.4` | Clean-worktree check, source commit/epoch, `git archive` | Every build; do not copy the Windows worktree directly. [VERIFIED: local probe, 2026-08-25] |
| OpenSSH client tools | `OpenSSH_for_Windows_9.5p2` | QEMU management key and bounded SCP/SSH transfer | QEMU backend only. [VERIFIED: local probe, 2026-08-25] |
| Cloud-init NoCloud | Version supplied by fixed Alpine cloud image; record at first boot | Public-only first-boot configuration | QEMU backend; current NoCloud supports SMBIOS discovery and HTTP seed sources with a trailing slash. [CITED: https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html] |
| EDK2 firmware | local `edk2-x86_64-code.fd` plus `edk2-i386-vars.fd` | Discovery evidence for later UEFI lanes | Preflight and reporting only in Phase 1; parse the descriptor rather than inventing a `vars` filename. [VERIFIED: `D:\VM\qemu\share\firmware\60-edk2-x86_64.json:2-23`] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Alpine `mkimage` | Hand-built initramfs/ISO | Reject: duplicates package trust, bootloader, EFI FAT, modloop, and hybrid-media work already implemented upstream. |
| Docker named Linux volumes | Build directly on an NTFS bind mount | Reject: contradicts the locked Linux-owned-filesystem decision and exposes modes, links, line endings, and performance to host semantics. |
| Pinned Alpine cloud image | Hand-install an Alpine VM interactively | Reject: unrepeatable and too slow for the overnight fallback. |
| QEMU fallback | WSL | Reject: WSL is absent and the project explicitly selected QEMU. [VERIFIED: `AGENTS.md:19-20`] |
| Native PowerShell assertions | Pester 3.4.0 | Avoid for this phase: the installed Pester is old and adding a package manager dependency is unnecessary for simple contract tests. [VERIFIED: local module probe, 2026-08-25] |

**Builder installation (exact observed snapshot):**

```sh
apk add \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/main \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/community \
  abuild=3.17.0-r0 apk-tools=3.0.7-r0 alpine-conf=3.22.0-r0 \
  busybox=1.37.0-r31 fakeroot=1.37.2-r0 syslinux=6.04_pre1-r19 \
  xorriso=1.5.8-r0 squashfs-tools=4.7.5-r0 mtools=4.0.49-r0 \
  grub=2.14-r0 git=2.54.0-r0 ca-certificates=20260611-r0 \
  gzip=1.14-r2 xz=5.8.3-r0 zstd=1.5.7-r2 lz4=1.10.0-r1 cpio=2.15-r0
```

The implementation must verify the two APKINDEX hashes before installation, preserve every downloaded APK in the external cache, hash those APK files, and abort on a version/hash mismatch. Do not silently update these values during an ordinary build.

## Package Legitimacy Audit

The required GSD package-legitimacy seam accepts only `npm`, `pypi`, and `crates`; invoking it with `--ecosystem apk` returned its usage error. Therefore no npm/PyPI/crates verdict can truthfully be assigned. APK legitimacy is instead grounded in the official Alpine v3.24 signed repository, the pinned aports source, exact version constraints, APKINDEX hashes, APK signature verification, and cached APK SHA-256 values. [VERIFIED: local GSD seam invocation, 2026-08-25] [CITED: https://wiki.alpinelinux.org/wiki/Repositories]

| Package group | Registry | Age / downloads | Source Repo | Verdict | Disposition |
|---------------|----------|-----------------|-------------|---------|-------------|
| `abuild apk-tools alpine-conf busybox fakeroot syslinux xorriso squashfs-tools mtools grub gzip xz zstd lz4` | Alpine v3.24 main | Registry does not expose npm-style age/download signals | `alpinelinux/aports` at pinned commit | Official Alpine packages; GSD APK verdict unavailable | Approved only with signature, exact revision, APKINDEX, and APK-byte locks |
| `git ca-certificates` | Alpine v3.24 main | Registry does not expose npm-style age/download signals | `alpinelinux/aports` at pinned commit | Official Alpine packages; GSD APK verdict unavailable | Approved only with the same lock controls |
| `cpio` | Alpine v3.24 community | Registry does not expose npm-style age/download signals | `alpinelinux/aports` at pinned commit | Official Alpine package; GSD APK verdict unavailable | Approved only with community-index signature/hash, exact revision, and APK-byte lock |

**Packages removed due to `[SLOP]` verdict:** none; the seam cannot issue APK verdicts.  
**Packages flagged as suspicious `[SUS]`:** none; no third-party language packages are introduced.

## Architecture Patterns

### System Architecture Diagram

```text
Contributor
    |
    v
build.ps1 (validate parameters, clean Git state, pins, paths, space, tools)
    |
    +--> explicit KeyInitRequest (before a signing public identity exists)
    +--> create deterministic git archive + source SHA-256 + fixed epoch
    +--> immutable build-request.json (known inputs only)
    |
    v
Backend decision
    | Docker healthy                         | Docker unavailable / -Backend Qemu
    v                                        v
Docker adapter                          QEMU adapter
  pinned linux/amd64 base                 pinned Alpine x86_64 QCOW2
  Linux work/cache volumes                immutable base + run overlay + cache disk
  secret copied to /run tmpfs             NoCloud + loopback SSH; secret to /run tmpfs
    |                                        |
    +-------------------+--------------------+
                        v
            /workspace/scripts/linux/run-build.sh
                        |
                        +--> exact aports commit
                        +--> verified v3.24 repositories/APKs
                        +--> profile_300k_bootstrap -> profile_virt
                        +--> Alpine mkimage + abuild signing + xorriso
                        |
                        v
            Linux staging: ISO + post-resolution lock + package list + reports
                        |
                        v
             host re-hash / schema / secret scan
                        |
                        v
        out/<build-id>/ (relative names only; atomic publish)

External secret root ----private key----> /run/300k-secrets (never output)
                         public key hash-> BuildRequest; public key may enter ISO
```

### Recommended Project Structure

```text
/
├── build.ps1                         # sole documented Windows entry point
├── builder/
│   ├── inputs.json                   # immutable base, aports, repo/index, VM pins
│   ├── Dockerfile                    # exact Alpine digest and APK revisions
│   ├── profiles/
│   │   └── mkimg.300k.sh             # profile_300k_bootstrap
│   └── cloud-init/
│       ├── meta-data.template        # no secrets
│       └── user-data.template        # public management key only
├── scripts/
│   ├── host/
│   │   ├── Invoke-CheckedProcess.ps1 # argv arrays, timeouts, split stdout/stderr
│   │   ├── Invoke-DockerBackend.ps1  # transport/state adapter only
│   │   └── Invoke-QemuBackend.ps1    # transport/state adapter only
│   └── linux/
│       ├── run-build.sh              # one canonical backend-neutral build
│       ├── init-signing-key.sh       # explicit one-time operation
│       └── inspect-iso.sh            # hash/size/layout/package evidence
├── tests/
│   └── phase1/
│       ├── run.ps1
│       ├── Preflight.Tests.ps1
│       ├── LockAndManifest.Tests.ps1
│       └── BackendParity.Tests.ps1
└── out/                               # ignored, atomic completed artifacts only
```

The existing ignore rules quote `build/`, `out/`, `dist/`, `iso/`, `*.iso`, `*.qcow2`, `*.tar`, `*.tar.gz`, `*.pem`, `*.key`, `secrets/`, and `credentials/`. Keep tracked source under `builder/`, `scripts/`, and `image/`, and add `*.rsa` plus any chosen local state directory as defense in depth. [VERIFIED: `.gitignore:6-13,81-93`]

### Pattern 1: One Host Contract, Two Adapters, One Build Core

**What:** `build.ps1` is the only public entry. `Auto` tries one bounded Docker preflight, records a sanitized failure reason, then uses QEMU. Explicit `Docker` fails if Docker is unhealthy; explicit `Qemu` never probes Docker. Both adapters transfer the same source archive, `build-lock` request, profile, and script and invoke the same fixed guest paths.

**Recommended interface:**

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

Use `$ErrorActionPreference = 'Stop'` and a single process helper built on `System.Diagnostics.ProcessStartInfo.ArgumentList`. Capture stdout and stderr separately, enforce a timeout, propagate native exit codes, and redact diagnostics before persistence. Never use `Invoke-Expression`, `cmd /c`, interpolated command lines, or whole environment dumps.

### Pattern 2: Clean Content-Addressed Input

**What:** Refuse release-style builds with tracked modifications. Create the transfer archive with `git archive`, derive the default `SOURCE_DATE_EPOCH` from `git show -s --format=%ct HEAD`, hash the archive, and extract it only into an empty Linux filesystem. Git objects preserve committed LF bytes and executable bits independently of the Windows checkout. After explicit key initialization, the host creates exact immutable `build-request.json` bytes containing only known inputs and transfers them to either backend; the guest never reserializes that request. Package resolution later emits a separate `resolved-build-lock.json` tied to the request hash.

Cache namespaces must include at least the aports commit, profile SHA-256, source-archive SHA-256, fixed epoch, architecture, repository-index hashes, and signing-public-key SHA-256. `mkimage.sh` reuses existing work sections, so a generic work directory can conceal stale inputs. [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh]

### Pattern 3: Linux-Owned Docker State

**What:** Use named volumes for `/work` and `/var/cache/apk`; stage the clean Git archive as a read-only host file and extract to `/work/source`. Copy the external key into container tmpfs at `/run/300k-secrets` and mount the host input read-only. The sole writable host bind is a temporary artifact-export directory. Never mount the Docker socket, user home, repository read-write, or use `--privileged`. Docker volumes are daemon-managed and persist independently of containers. [CITED: https://docs.docker.com/engine/storage/volumes/] [CITED: https://docs.docker.com/engine/storage/bind-mounts/]

The hypothesis that the pinned Alpine build completes without `--privileged` remains an execution requirement, not an established result. [ASSUMED]

Use this exact external-state shape; none of it is tracked or copied into the ISO:

```text
%LOCALAPPDATA%\300k-linux\
├── state\
│   ├── downloads\                    # pinned cloud base + fetched sidecars
│   ├── qemu\
│   │   ├── base\                     # immutable verified QCOW2
│   │   └── cache\300k-cache.qcow2   # persistent package/aports cache only
│   └── runs\<run-id>\
│       ├── source.tar                # clean, hashed Git archive
│       ├── overlay.qcow2             # disposable VM overlay
│       ├── seed\                     # public-only NoCloud data
│       ├── export\                   # pre-publication artifact staging
│       └── serial.log
└── secrets\
    ├── apk\
    │   ├── 300k.rsa                  # private; restricted ACL
    │   └── 300k.rsa.pub              # public; fingerprint recorded
    └── ssh\
        └── fallback_ed25519           # private management key
```

Use Docker named volumes `300k-p01-work` at `/work` and `300k-p01-apk-cache` at `/var/cache/apk`. Ordinary Docker builds receive the clean source tar read-only, copy the APK key from a read-only input into `/run/300k-secrets`, and bind only the per-run `export` directory writable. Volume names are operational state and do not belong in the content lock or published evidence.

### Pattern 4: Bounded QEMU Fallback

**What:** Keep the verified fallback base immutable under the external state root, create a per-run qcow2 overlay, and attach a separate persistent cache qcow2 with virtio serial `300k-cache`. Cloud-init receives only public metadata. Forward SSH only to a dynamically selected `127.0.0.1` port and use a run-specific `known_hosts`; transfer the clean source archive in and validated artifacts out with SCP. Copy the APK private key directly into `/run/300k-secrets`, never the guest home or persistent disk.

Use QEMU's user-network host address `10.0.2.2` for a short-lived, loopback-bound seed server and SMBIOS discovery with a trailing slash, for example `ds=nocloud;s=http://10.0.2.2:<port>/`. NoCloud documents DMI/SMBIOS line configuration, HTTP seed sources, the required `meta-data`/`user-data` names, and the trailing slash. [CITED: https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html] QEMU documents loopback `hostfwd`, qcow2 backing files, and ordered accelerator fallback. [CITED: https://www.qemu.org/docs/master/system/devices/net.html] [CITED: https://www.qemu.org/docs/master/system/images] [CITED: https://www.qemu.org/docs/master/system/qemu-manpage.html]

The first implementation wave must prove this exact Alpine image discovers the NoCloud URL and accepts the injected key on this host; it has not been locally boot-tested during research. [ASSUMED]

### Pattern 5: Explicit Signing-Key Lifecycle

**What:** `-InitializeSigningKey` is an explicit one-time operation executed inside the selected Alpine backend with `abuild-keygen -a -n`. Normalize the generated pair into the external secret root, restrict its Windows ACL, and never regenerate it during a normal build. For each build, copy the private key to `/run/300k-secrets`, `chmod 600`, set `PACKAGER_PRIVKEY`, and remove the tmpfs copy on exit. Record only the public filename and raw-file SHA-256.

The image scripts require `PACKAGER_PRIVKEY` for modloop signing, sign the embedded APK index, and copy the selected public key into the APK root. Omit `--hostkeys`; architecture keys are already loaded from Alpine's packaged key directory and ambient host keys would make the result host-dependent. [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.base.sh] [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh]

### Pattern 6: Atomic, Relative-Name Artifact Publication

**What:** Build into external staging. Validate required files, JSON shape, byte counts, checksums, ISO layout, QEMU readability, and secret scans. Copy to `out/<build-id>/*.partial`, re-hash the copies, then rename within that directory. Update `out/LATEST.json` only after every check succeeds. A failed or timed-out run must not alter the previous last-known-good pointer.

Recommended identity:

- `request_id`: SHA-256 of the exact committed-input document, source archive, profile, epoch, repository indexes, architecture, and public-key hash.
- `build_id`: `p01-` plus the first 12 lowercase hex characters of `request_id`.
- ISO filename: `300k-bootstrap-x86_64-` plus the first 12 lowercase hex characters of the final ISO SHA-256, followed by `.iso`.
- JSON and report paths: relative basenames only; absolute host/guest paths are forbidden.

All identifiers and enum values in the artifact schemas below are proposed new contracts, not pre-existing repository values. [ASSUMED]

### Anti-Patterns to Avoid

- **CLI-present equals Docker-ready:** the local CLI exists while the server is absent; require server and guest-platform proofs.
- **Two backend build scripts:** backend drift would make BUILD-04 unverifiable; adapters must converge on `run-build.sh`.
- **Windows worktree as build root:** do not execute or mutate build sources on NTFS; archive committed Git content and extract on Linux.
- **Mutable `alpine:3.24.1` or `3.24-stable`:** use the two Docker digests and exact aports commit.
- **Repository URL called a lock:** pin/check index and APK-byte hashes and fail on drift.
- **Private key in environment or command line:** both can leak through diagnostics/process inspection; use a fixed tmpfs file path.
- **Per-build signing key:** changes artifact bytes and identity and makes cache comparisons meaningless.
- **`mkimage --hostkeys`:** imports ambient builder state and weakens provenance.
- **QEMU FAT writable export:** QEMU labels FAT write support beta; use SCP and re-hash on the host. [CITED: https://www.qemu.org/docs/master/system/images]
- **Structural report called a boot test:** Phase 1 layout evidence does not satisfy BOOT-03/BOOT-04.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Hybrid BIOS/UEFI ISO layout | Custom El Torito/GPT byte writer | Pinned Alpine `mkimage.sh` + `mkimg.base.sh` + `xorriso` | Upstream already coordinates ISOLINUX, GRUB EFI, FAT, MBR, alternate EFI entry, and GPT marker. |
| Package dependency resolution/trust | Download parser or unsigned local bundle | `apk` with official keys, exact repositories, versions, index hashes, and cached APK hashes | Dependency closure and signatures are security-sensitive. |
| APK/modloop signing | Custom crypto | `abuild-keygen`, `abuild-sign`, and Alpine image scripts | Avoids bespoke key formats and signature semantics. |
| Source transfer normalization | Recursive copy plus line-ending fixes | `git archive` followed by Linux extraction | Git already defines committed bytes and modes. |
| Docker platform detection | Inspecting process names only | `docker info`, `image inspect`, and a real pinned-container architecture probe | Client, daemon, image, and guest can disagree. |
| VM installation | Automated keyboard input to `setup-alpine` | Pinned official Alpine cloud-init QCOW2 | Removes an interactive, timing-sensitive state machine. |
| VM source/artifact filesystem sharing | Writable virtual FAT | Loopback-only SSH/SCP | Preserves Linux build semantics and permits end-to-end rehashing. |
| Hashing | Custom checksum code | `sha256sum` in Linux and `Get-FileHash` on Windows | Independent standard implementations catch transfer errors. |
| Test framework dependency | New third-party module | Small native PowerShell assertion harness | Enough for a greenfield CLI contract and works with the installed host. |

**Key insight:** This phase is orchestration and evidence. Every custom replacement for Alpine, Git, Docker, QEMU, SSH, or standard hashing expands the trust surface without improving the bootstrap artifact.

## Common Pitfalls

### Pitfall 1: Docker Client Exists but the Linux Server Does Not

**What goes wrong:** The wrapper reaches `docker build` and fails late, or connects to a Windows-container daemon.  
**Why it happens:** `docker.exe --version` proves only the client. On this host `docker version` reports client `29.6.0` and no server, with the `docker_engine` named pipe absent. [VERIFIED: local probe, 2026-08-25]  
**How to avoid:** Require `docker info --format` to return `linux` plus `x86_64`/`amd64`, inspect the pulled digest, and run the exact base with `--platform linux/amd64` to assert `uname -m`, `apk --print-arch`, and `/etc/alpine-release`.  
**Warning signs:** Server fields missing, `OSType=windows`, image architecture not amd64, or a probe requiring emulation without being recorded.

### Pitfall 2: Mutable Stable Repositories Masquerade as Reproducibility

**What goes wrong:** The same Git commit installs different builder/runtime APKs days later.  
**Why it happens:** `/alpine/v3.24` is a supported update stream, not a content-addressed snapshot. [CITED: https://wiki.alpinelinux.org/wiki/Repositories]  
**How to avoid:** Commit initial APKINDEX hashes, exact direct package revisions, and the aports commit; check index hashes before and after; retain/hash every APK in external state; publish nothing on drift. A deliberate lock refresh is a separate reviewed operation.  
**Warning signs:** Bare package names, `latest-stable`, `edge`, a moving branch checkout, or a package manifest with versions but no APK hashes.

### Pitfall 3: `SOURCE_DATE_EPOCH` Is Omitted or Derived Differently

**What goes wrong:** Archive timestamps and ISO hashes vary by wall clock or backend.  
**Why it happens:** Current `mkimage.sh` has fallback source-date logic when the variable is absent. [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh]  
**How to avoid:** Derive the default once from the clean project HEAD commit timestamp on Windows, validate it as a positive integer, put it in the request, and export exactly that value in both backends.  
**Warning signs:** Guest calls `date`, environment reports different epochs, or the lock omits the epoch.

### Pitfall 4: Persistent Work Cache Reuses Stale Sections

**What goes wrong:** A profile or repository change appears not to take effect.  
**Why it happens:** `mkimage.sh` can reuse section directories in the work directory. [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh]  
**How to avoid:** Namespace work directories by `request_id`; reserve `-Clean` for removing that exact namespace; never share a generic work directory across lock changes.  
**Warning signs:** Output changes only after manual deletion, or two different locks reference the same work path.

### Pitfall 5: Signing Material Leaks Through Convenience Paths

**What goes wrong:** A private RSA key, management SSH key, absolute Windows path, or proxy/token lands in Git, logs, JSON, the source archive, or ISO.  
**Why it happens:** Broad bind mounts, environment dumps, `--hostkeys`, copying via guest home, and extension-only scans miss content.  
**How to avoid:** External secret root, restrictive ACL, explicit initialization, tmpfs use, read-only ordinary-build input, redacted process results, Git/source/ISO filename and content scans, and relative output names. Add `*.rsa` to `.gitignore`.  
**Warning signs:** `BEGIN ... PRIVATE KEY`, drive letters/UNC prefixes, usernames, `.env`, `*.pem`, `*.key`, private `*.rsa`, Docker config/proxy values, or secret-root strings in output.

### Pitfall 6: Fallback Is a Document, Not a Capability

**What goes wrong:** Docker is unavailable overnight and the only alternative requires an interactive VM install.  
**Why it happens:** Fallback work is deferred because the primary path seems easier. The primary path is currently unavailable on this machine. [VERIFIED: `.planning/STATE.md:65-69`; local Docker probe]  
**How to avoid:** Make the first integration task boot/provision the pinned cloud image and run a minimal shared script; make phase acceptance require a full QEMU-produced bootstrap artifact.  
**Warning signs:** QEMU command examples exist but no retained serial log, guest architecture proof, or copied artifact.

### Pitfall 7: Hash-Qualified Naming Is Performed in the Wrong Order

**What goes wrong:** The filename prefix, checksum file, manifest, and actual ISO disagree, or a partial artifact replaces last-known-good.  
**Why it happens:** Naming occurs before final bytes settle or `LATEST.json` updates too early.  
**How to avoid:** Finish the ISO in staging, hash it, choose its final basename, generate artifact metadata, copy as `.partial`, re-hash, atomically rename, then update the pointer.  
**Warning signs:** Hash is calculated before `xorriso` finishes, manifest includes a staging path, or failure leaves a new `LATEST.json`.

### Pitfall 8: Boot Layout Is Reported as Boot Success

**What goes wrong:** The phase claims BIOS/UEFI support because El Torito entries exist.  
**Why it happens:** Structural generation and firmware execution are conflated.  
**How to avoid:** Label reports `structural`; Phase 1 asserts expected boot records and QEMU readability only. BOOT-03 and BOOT-04 stay with their assigned later phases. [VERIFIED: `.planning/REQUIREMENTS.md:21-22,105-113`]  
**Warning signs:** Words such as “boots” or “supported” without a bounded QEMU run and readiness milestone.

### Pitfall 9: Dirty or Host-Normalized Input Enters Linux

**What goes wrong:** Uncommitted files, CRLF, missing executable bits, symlinks, or ignored secrets affect a supposedly reproducible image.  
**Why it happens:** The wrapper mounts/copies the working directory.  
**How to avoid:** Default to clean tracked state, use `git archive`, hash it before transfer and after receipt, validate archive entries before extraction, and extract to an empty Linux path. If a developer-only dirty mode is later added, mark its artifact non-release and record `dirty=true`.  
**Warning signs:** `robocopy`, recursive `Copy-Item`, read-write repository mounts, or build inputs not reachable from the recorded Git commit.

## Code Examples

The examples below are planning contracts. Source comments identify official behavior; proposed project names and schema enum values are new and are therefore covered by the assumptions log.

### Pinned Docker Builder Image

```dockerfile
# syntax=docker/dockerfile:1
FROM --platform=linux/amd64 alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN printf '%s\n' \
      'https://dl-cdn.alpinelinux.org/alpine/v3.24/main' \
      'https://dl-cdn.alpinelinux.org/alpine/v3.24/community' \
      > /etc/apk/repositories \
 && apk add \
      abuild=3.17.0-r0 apk-tools=3.0.7-r0 alpine-conf=3.22.0-r0 \
      busybox=1.37.0-r31 fakeroot=1.37.2-r0 syslinux=6.04_pre1-r19 \
      xorriso=1.5.8-r0 squashfs-tools=4.7.5-r0 mtools=4.0.49-r0 \
      grub=2.14-r0 git=2.54.0-r0 ca-certificates=20260611-r0 \
      gzip=1.14-r2 xz=5.8.3-r0 zstd=1.5.7-r2 lz4=1.10.0-r1 cpio=2.15-r0

WORKDIR /workspace
ENTRYPOINT ["/bin/sh", "/workspace/scripts/linux/run-build.sh"]
```

Build with an explicit `--platform linux/amd64` and a context restricted to `builder/`; do not send the repository or secret root as Docker build context. Verify the two repository index hashes before the Dockerfile is built, then record the resulting local image ID and sorted `apk list --installed --manifest` output in environment/build evidence. Do not use build arguments or environment variables for secrets.

### Thin Alpine Bootstrap Profile

```sh
# Source behavior: mkimage plugin/profile loading and upstream profile_virt
# https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh
# https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.standard.sh
profile_300k_bootstrap() {
    profile_virt
    profile_abbrev="300k"
    image_name="300k-bootstrap"
    title="300K Linux Bootstrap"
    desc="Pinned build-pipeline proof; not the final runtime."
}
```

Place the file under the build user's `$HOME/.mkimage/mkimg.300k.sh`, record its SHA-256, and assert that `--profile 300k_bootstrap` resolves before the expensive build.

### Detached Aports Checkout and Exact Build Invocation

```sh
# Exact project contract; command options sourced from pinned mkimage.sh.
set -eu

APORTS_URL='https://gitlab.alpinelinux.org/alpine/aports.git'
APORTS_COMMIT='52643b7a176095362fd87fe73cdb994cb2e5ffae'

git init /work/aports
git -C /work/aports remote add origin "$APORTS_URL"
git -C /work/aports fetch --depth=1 origin "$APORTS_COMMIT"
git -C /work/aports checkout --detach FETCH_HEAD
test "$(git -C /work/aports rev-parse HEAD)" = "$APORTS_COMMIT"
test -z "$(git -C /work/aports status --porcelain)"

export HOME=/work/home
export SOURCE_DATE_EPOCH="$LOCKED_SOURCE_DATE_EPOCH"
export PACKAGER_PRIVKEY=/run/300k-secrets/300k.rsa
export PACKAGER_PUBKEY=/run/300k-secrets/300k.rsa.pub

sh /work/aports/scripts/mkimage.sh \
  --tag "$BUILD_ID" \
  --outdir "/work/out/$BUILD_ID/raw" \
  --workdir "/work/cache/mkimage/$REQUEST_ID" \
  --arch x86_64 \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/main \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/community \
  --profile 300k_bootstrap \
  --checksum

# Capture the exact builder installation and every cached APK byte.
apk list --installed --manifest | LC_ALL=C sort > "/work/out/$BUILD_ID/builder-packages.lock"
(cd /work/cache/apk && find . -type f -name '*.apk' -print \
  | LC_ALL=C sort \
  | while IFS= read -r apk; do sha256sum "$apk"; done) \
  > "/work/out/$BUILD_ID/apk-files.sha256"
```

Current `mkimage.sh` supports repeated `--repository`, while `--extra-repository` is deprecated; `--checksum` emits SHA-256/SHA-512 companions. [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh] A shallow exact-SHA fetch may be rejected if the server does not advertise the object; the bounded fallback is to shallow-fetch `3.24-stable`, assert the pinned commit is present, and deepen only as needed. [ASSUMED]

### Docker Preflight

```powershell
# Execute each command through Invoke-CheckedProcess with argv, timeout,
# separated stdout/stderr, and sanitized error reporting.
docker info --format '{{.OSType}}|{{.Architecture}}|{{.ServerVersion}}'
docker pull --platform linux/amd64 $PinnedBuilderRef
docker image inspect --format '{{.Os}}|{{.Architecture}}|{{.Id}}|{{json .RepoDigests}}' $PinnedBuilderRef
docker run --rm --network none --pull never --platform linux/amd64 `
  $PinnedBuilderRef sh -ceu '
    test "$(uname -m)" = x86_64
    test "$(apk --print-arch)" = x86_64
    test "$(cat /etc/alpine-release)" = 3.24.1
  '
```

Accept Docker server architecture spelling `amd64` or `x86_64`, but require server `OSType=linux` and the in-container three-part proof. Do not persist raw `docker info`; it can include hostnames, daemon roots, proxies, and registry configuration.

### QEMU Fallback Shape

```text
qemu-system-x86_64.exe
  -machine q35
  -accel whpx
  -accel tcg,thread=multi
  -m 4096
  -smp 4
  -drive if=none,id=os,format=qcow2,file=<per-run-overlay>
  -device virtio-blk-pci,drive=os,bootindex=1,serial=300k-builder
  -drive if=none,id=cache,format=qcow2,file=<persistent-cache>
  -device virtio-blk-pci,drive=cache,serial=300k-cache
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:<ssh-port>-:22
  -smbios type=1,serial=ds=nocloud;s=http://10.0.2.2:<seed-port>/
  -display none
  -serial file:<per-run-serial-log>
  -monitor none
```

Use `qemu-img create -f qcow2 -F qcow2 -b <verified-base> <overlay>` and never modify the base. Identify the cache device inside the guest through `/dev/disk/by-id/virtio-300k-cache`, not `/dev/vdb`. Recommended bounds are 3 minutes for metadata discovery, 5 minutes for SSH/cloud-init readiness, and 60 minutes for the build; these values need adjustment from the first measured run. [ASSUMED]

### ISO Evidence

```sh
# Source: GNU xorriso reporting and Alpine hybrid assembly.
sha256sum -c "$ISO.sha256"
stat -c '%s' "$ISO"

xorriso -indev "$ISO" -pvd_info
xorriso -indev "$ISO" -report_el_torito plain
xorriso -indev "$ISO" -report_el_torito as_mkisofs
xorriso -indev "$ISO" -report_system_area plain
xorriso -indev "$ISO" -find / -type f -exec lsdl
```

Require the structural report to show a BIOS El Torito entry for ISOLINUX, an alternate EFI El Torito image, `bootx64.efi`, and the hybrid system-area markers expected from the pinned `mkimg.base.sh`. [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.base.sh] [CITED: https://www.gnu.org/software/xorriso/man_1_xorriso.html] Then run the local `qemu-img info --output=json <iso>` and save its sanitized JSON as proof QEMU can parse the exact exported file. This is not a boot claim.

### Bootstrap Request and Resolved Build Lock

`build-request.json` is immutable before dispatch and contains only facts already known after explicit signing-key initialization. It must not contain resolved package/output facts, backend names, timestamps unrelated to content, absolute paths, usernames, machine names, environment variables, or its own hash.

```json
{
  "schema_version": 1,
  "target": {
    "os": "linux",
    "arch": "x86_64",
    "format": "iso",
    "profile": "300k_bootstrap"
  },
  "source": {
    "git_commit": "<40-lowercase-hex>",
    "archive_sha256": "<64-lowercase-hex>",
    "source_date_epoch": 0,
    "dirty": false
  },
  "builder": {
    "alpine_release": "3.24.1",
    "image_index_digest": "sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b",
    "linux_amd64_manifest_digest": "sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f"
  },
  "aports": {
    "remote": "https://gitlab.alpinelinux.org/alpine/aports.git",
    "commit": "52643b7a176095362fd87fe73cdb994cb2e5ffae"
  },
  "repositories": [
    {
      "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/main",
      "apkindex_sha256": "0076ecf24f2b49c08d7546e987e070a34af57a90a6831fbd312388eac2b01fd7"
    },
    {
      "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/community",
      "apkindex_sha256": "23d7e4a77f658c9e9c4dd50b88ce111fa27fe69282ed4a55234da6a1f4e516ba"
    }
  ],
  "profile": {
    "file": "mkimg.300k.sh",
    "sha256": "<64-lowercase-hex>"
  },
  "signing": {
    "public_key_file": "300k.rsa.pub",
    "public_key_sha256": "<64-lowercase-hex>"
  }
}
```

Emit it from an ordered PowerShell object as UTF-8 without BOM, with LF endings and a trailing LF. The host transfers the exact bytes to the backend and hashes those bytes; neither guest path reparses/re-emits it for identity.

After signed-index and package resolution, the guest emits `resolved-build-lock.json` tied to the exact request SHA-256. That lock owns the complete retained APK closure, exact aports bytes, `builder-packages.lock`, `apk-files.sha256`, and generated output references. `run-build.sh` produces those records; `build.ps1` independently validates their closed schemas, hashes, byte counts, relative basenames, and request linkage. Key initialization instead emits `signing-public.json`; no public-key hash may appear before that operation succeeds.

The numeric `0` values in these JSON examples are placeholders for a generated positive epoch/byte count; validation must reject zero in a completed artifact.

### Artifact Manifest and Sanitized Environment Evidence

```json
{
  "schema_version": 1,
  "phase": 1,
  "kind": "bootstrap",
  "build_id": "p01-<12-lowercase-hex>",
  "build_request": {
    "file": "build-request.json",
    "sha256": "<64-lowercase-hex>"
  },
  "resolved_build_lock": {
    "file": "resolved-build-lock.json",
    "sha256": "<64-lowercase-hex>"
  },
  "artifacts": [
    {
      "role": "bootstrap_iso",
      "file": "300k-bootstrap-x86_64-<12-lowercase-hex>.iso",
      "sha256": "<64-lowercase-hex>",
      "bytes": 0,
      "media_type": "application/x-iso9660-image"
    },
    {
      "role": "boot_layout",
      "file": "boot-layout.txt",
      "sha256": "<64-lowercase-hex>",
      "bytes": 0,
      "media_type": "text/plain"
    },
    {
      "role": "qemu_image_info",
      "file": "qemu-image-info.json",
      "sha256": "<64-lowercase-hex>",
      "bytes": 0,
      "media_type": "application/json"
    }
  ]
}
```

`environment-report.json` is separate because backend/version evidence is diagnostic rather than content-determining. Its allowed fields are: `schema_version`, `backend` (`docker` or `qemu`), `backend_version`, `guest_os` (`linux`), `guest_arch` (`x86_64`), `alpine_release` (`3.24.1`), `accelerator` (`whpx`, `tcg`, or `not_applicable`), stable preflight result codes, and booleans indicating verified pins. It must not contain absolute paths or raw command output. These allowed values are proposed new contract values. [ASSUMED]

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Docker tags as sufficient pins | Image index digest plus explicit linux/amd64 manifest and `--platform` | Current Docker content-addressed image workflow | Prevents tag movement and wrong-platform selection. [CITED: https://docs.docker.com/reference/cli/docker/image/pull/] |
| Windows bind-mounted mutable build tree | Clean Git archive extracted to a Docker volume/VM filesystem | Current Docker Desktop/Linux-container practice | Keeps filesystem semantics inside Linux while preserving exact Git content. [CITED: https://docs.docker.com/engine/storage/volumes/] |
| Manual Alpine remaster | Pinned aports `mkimage` profile | Current Alpine supported custom-ISO workflow | Reuses package signing and hybrid boot assembly. [CITED: https://wiki.alpinelinux.org/wiki/How_to_make_a_custom_ISO_image_with_mkimage] |
| Interactive fallback VM | Versioned Alpine cloud-init QCOW2 plus NoCloud/SSH | Current Alpine cloud images and cloud-init NoCloud | Makes BUILD-04 scriptable and bounded. [CITED: https://www.alpinelinux.org/cloud/] [CITED: https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html] |
| Single generic QEMU accelerator | Ordered WHPX then TCG fallback | Current QEMU CLI | Uses acceleration when available without making it a blocker. [CITED: https://www.qemu.org/docs/master/system/qemu-manpage.html] |

**Deprecated/outdated for this phase:**

- `mkimage --extra-repository`: use repeated `--repository`. [CITED: https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh]
- HAXM on Windows: removed upstream; use WHPX or TCG. [CITED: https://www.qemu.org/docs/master/about/removed-features.html]
- Moving `master`, `edge`, `latest`, or `latest-stable` inputs: incompatible with this phase's pinned contract.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | The pinned Alpine `mkimage` path completes without Docker `--privileged`. | Architecture Pattern 3 | Docker backend needs a narrower capability adjustment or QEMU becomes the only working backend. |
| A2 | The exact Alpine cloud image accepts SMBIOS NoCloud HTTP metadata and injected SSH access under this QEMU bundle. | Summary / Pattern 4 | BUILD-04 is blocked until the seed transport or image variant is adjusted. |
| A3 | An exact shallow fetch by commit is accepted by the aports server. | Code Examples | Fall back to a shallow branch fetch and bounded deepen while still checking the same commit. |
| A4 | Three-minute metadata, five-minute SSH, and 60-minute build timeouts are reasonable on this host. | QEMU example | Slow TCG may need measured higher bounds; keep all bounds finite. |
| A5 | A cache/input lock plus fixed epoch/key produces byte-identical bootstrap ISOs across clean builds/backends. | Summary / Open Questions | Require semantic/hash evidence separately until two clean runs demonstrate identity; never promise it in advance. |
| A6 | A 20 GiB free-space threshold is sufficient for fallback base, overlays, cache, and ISO work. | Environment / preflight recommendation | First measured build may require a higher threshold; report actual peak usage. |
| A7 | Proposed schema names/enums and 12-hex display prefixes are suitable new project contracts. | Artifact schemas | Changing them after downstream phases start causes compatibility churn; lock them in Phase 1 tests. |

## Open Questions (RESOLVED)

The planning revision adopts these outcomes as Phase 1 contracts:

- **Backend outcome:** QEMU is the required working Linux/amd64 backend on this host. Docker remains an optional compatible adapter and is reported `unverified-unavailable` while no real Linux daemon exists; fixture success never substitutes for real Docker execution.
- **NoCloud outcome:** the exact NoCloud spelling, public host key, readiness milestone, and timeout values are accepted only after a clean-tree QEMU tracer captures them from the owned serial channel. A failed tracer blocks the QEMU capability rather than weakening SSH trust or inventing readiness.
- **Replay outcome:** the builder retains a same-host, content-addressed local repository containing the verified indexes, exact APK closure, and aports bytes. Package/index drift, missing retained bytes, an unsupported container format, or any verification/install mismatch fails closed.
- **Parity outcome:** Docker and QEMU must receive semantically identical immutable input fields and invoke the same Linux build core. Phase 1 makes no byte-identity claim across backends or clean runs unless later evidence actually proves it.

1. **Can the primary Docker backend run on this host?**
   - What we know: Docker client `29.6.0` exists, but no server is reachable and no Docker Desktop service/executable was found in the probed locations. [VERIFIED: local host probes, 2026-08-25]
   - What's unclear: Whether the user can start an existing nonstandard installation or needs Docker Desktop installed/repaired.
   - Adopted outcome: Do not block the default build. Implement and prove QEMU first; retain strict Docker preflight, and leave Docker visibly unverified until a real daemon completes the lane.

2. **Does the exact Alpine cloud artifact complete the proposed NoCloud path locally?**
   - What we know: The image, its hash, QEMU accelerators, OpenSSH client, and NoCloud/QEMU mechanisms are documented and available. [CITED: https://www.alpinelinux.org/cloud/] [CITED: https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html]
   - What's unclear: Exact image defaults, readiness time, and whether `ds=nocloud` or the compatibility alias `ds=nocloud-net` is required by its packaged cloud-init.
   - Adopted outcome: Gate the spelling/template on the clean-tree QEMU tracer, derive the guest Ed25519 host-key fingerprint from its owned serial channel, and retain sanitized serial proof.

3. **How portable must exact clean replay be after Alpine repository updates?**
   - What we know: Exact index/package hashes detect drift, while external cache retention enables same-host replay.
   - What's unclear: Whether v1 must publish a cache bundle/snapshot for new-host replay after upstream package replacement.
   - Adopted outcome: Retain the verified content-addressed repository outside Git for same-host replay and fail closed on missing or drifted bytes. Fresh-host byte replay is not claimed.

4. **Must Docker and QEMU output be byte-identical?**
   - What we know: BUILD-04 requires the same build and architecture; it does not explicitly require identical ISO bytes. [VERIFIED: `.planning/REQUIREMENTS.md:15`]
   - What's unclear: Whether tool/backend nondeterminism remains after all inputs are fixed.
   - Adopted outcome: Gate on semantic equality of source/request/profile/script/public-key and repository inputs plus valid artifact evidence; do not claim byte identity without direct proof.

## Environment Availability

| Dependency | Required By | Available | Version / evidence | Fallback |
|------------|-------------|-----------|--------------------|----------|
| PowerShell | Host entry and tests | ✓ | `7.6.1` [VERIFIED: local probe] | — |
| Git | Clean archive and source epoch | ✓ | `2.55.0.windows.4` [VERIFIED: local probe] | None; fail preflight |
| Docker client | Primary backend | ✓ | `29.6.0` [VERIFIED: local probe] | QEMU |
| Docker Linux server | Primary backend | ✗ | No Server object; named pipe missing [VERIFIED: local probe] | QEMU; primary remains unverified |
| QEMU system emulator | Fallback | ✓ | `11.1.0` at supplied root [VERIFIED: local probe] | TCG if WHPX init fails |
| QEMU image tool | Overlay and ISO parse | ✓ | `11.1.0` [VERIFIED: local probe] | None; fail fallback preflight |
| WHPX | Fast fallback execution | Present in binary; host init unproven | QEMU advertises `whpx` [VERIFIED: local probe] | Ordered `tcg,thread=multi` |
| TCG | Dependable fallback execution | ✓ | QEMU advertises `tcg` [VERIFIED: local probe] | None |
| EDK2 x86_64 code + vars | Firmware discovery/later lanes | ✓ | Descriptor quotes `"architecture": "x86_64"`, `"edk2-x86_64-code.fd"`, and `"edk2-i386-vars.fd"`; files exist [VERIFIED: `D:\VM\qemu\share\firmware\60-edk2-x86_64.json:8-23`] | Not needed for BIOS fallback build VM |
| OpenSSH/scp/ssh-keygen | QEMU transport | ✓ | `OpenSSH_for_Windows_9.5p2` [VERIFIED: local probe] | None; fail fallback preflight |
| Python | Optional seed HTTP server | ✓ | `3.13.13` [VERIFIED: local probe] | Prefer a bounded PowerShell/.NET server so Python is not a hard project dependency |
| GPG | Optional fallback-image signature verification | ✗ | Command absent [VERIFIED: local probe] | Fixed SHA-512 pin already committed; do not claim `.asc` verification |
| D: free space | QEMU state/output | ✓ | `64,095,535,104` bytes (~59.7 GiB) on research probe [VERIFIED: local probe, 2026-08-25] | Allow external `-StateRoot` |
| Internet | Initial base/aports/APK acquisition | ✓ during research | Official GitLab/Alpine HTTPS probes succeeded [VERIFIED: live probes, 2026-08-25] | Retained external cache for later locked rebuilds |

**Missing dependencies with no fallback:** none for the proposed QEMU route, subject to the mandatory local NoCloud spike.  
**Missing dependencies with fallback:** Docker Linux server is missing; QEMU is the required fallback. GPG is missing; a committed SHA-512 pin detects any future byte mismatch, while signature verification must not be claimed.

Preflight should reject a state/secret root inside the repository, reparse-point output/state roots, unwritable roots, and broad write ACLs. It should probe free space on state and output drives. A conservative 20 GiB fallback threshold is a starting recommendation pending measurement. [ASSUMED]

## Validation Architecture

> Included by explicit orchestrator request even though `.planning/config.json` contains `"nyquist_validation": false`.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Self-contained PowerShell 7 assertion/fixture runner; no external package |
| Config file | none — create in Wave 0 |
| Quick run command | `pwsh -NoProfile -File tests/phase1/run.ps1 -Scope Unit` |
| Full suite command | `pwsh -NoProfile -File tests/phase1/run.ps1 -Scope All` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BUILD-01 | One entry rejects bad/mutable pins, dirty input, bad paths, and an explicitly selected dead/wrong-platform Docker backend; the working QEMU default and any healthy Docker backend receive exact request/archive/script/profile hashes | unit + real QEMU + conditional Docker integration | `pwsh -NoProfile -File tests/phase1/run.ps1 -Scope Unit -Requirement BUILD-01`; real default via `-Scope Qemu`; conditional real Docker lane via `-Scope Docker` | ❌ Wave 0 |
| BUILD-03 | Git/source/output/ISO scans reject private-key markers, private extensions, secret roots, host paths, credentials/tokens, and writable secret mounts; manifests remain relative/public-only | unit + artifact integration | `pwsh -NoProfile -File tests/phase1/run.ps1 -Scope Unit -Requirement BUILD-03`; artifact lane via `-Scope Artifact` | ❌ Wave 0 |
| BUILD-04 | `Auto` falls back after a sanitized Docker failure; QEMU proves Alpine `3.24.1`/`x86_64`, invokes the same build core/lock, and exports a validated bootstrap artifact | integration | `pwsh -NoProfile -File tests/phase1/run.ps1 -Scope Qemu` | ❌ Wave 0 |
| Walking skeleton | Final ISO basename hash matches bytes; `SHA256SUMS`, lock, package list, boot report, QEMU info, and environment report agree | integration | `pwsh -NoProfile -File tests/phase1/run.ps1 -Scope Artifact` | ❌ Wave 0 |

### Required Contract Cases

- Docker absent, daemon unreachable, Windows daemon, wrong image architecture, and wrong guest Alpine version yield distinct stable error codes and nonzero exit status.
- Docker warnings on stderr cannot corrupt JSON read from stdout.
- `Auto` chooses QEMU only after a bounded Docker probe; explicit `Docker` never silently changes backend.
- QEMU discovery accepts the supplied root, parses the firmware descriptor, resolves both firmware basenames, and requires TCG.
- Path tests cover `..`, sibling-prefix confusion (`repo` versus `repo2`), reparse points, spaces, unwritable roots, secret root inside repo, and output outside the allowed artifact root.
- Lock tests reject `latest`, `edge`, a non-40-hex aports commit, non-digest builder reference, non-x86_64 target, non-integer epoch, duplicate/unapproved repositories, malformed hashes, and any host path.
- Docker and QEMU command records contain semantically identical source archive, immutable request, script, profile, aports, repository-index, epoch, and public-key hashes; no cross-backend ISO byte-identity claim is implied.
- Manifest hashes/bytes match `Get-FileHash` and `FileInfo.Length`; filename prefix matches ISO hash.
- `xorriso` listing/content scan rejects `.env`, `*.pem`, `*.key`, private `*.rsa`, private-key PEM markers, token/credential patterns, drive/UNC paths, secret/cache path markers, and unexpected files while allowing the expected `.rsa.pub` public key.
- A failed/timeout run cannot publish partial files or change `LATEST.json`; the wrapper kills only the QEMU process it launched and retains the serial log.

### Sampling Rate

- **Per task commit:** `pwsh -NoProfile -File tests/phase1/run.ps1 -Scope Unit` (target under 30 seconds)
- **Per backend adapter completion:** its real integration lane
- **Per wave merge:** `pwsh -NoProfile -File tests/phase1/run.ps1 -Scope All`
- **Phase gate:** Full suite green, one real QEMU fallback artifact, and Docker lane green if a Linux daemon becomes available; otherwise Docker is explicitly reported unverified, not silently passed.

### Wave 0 Gaps

- [ ] `tests/phase1/run.ps1` — assertions, fixture loading, scoped execution, exit aggregation
- [ ] `tests/phase1/Preflight.Tests.ps1` — injected native-process/path/tool results for BUILD-01/04
- [ ] `tests/phase1/LockAndManifest.Tests.ps1` — schemas, hashes, relative paths, secret scanning for BUILD-01/03
- [ ] `tests/phase1/BackendParity.Tests.ps1` — canonical invocation-record comparison for Docker/QEMU
- [ ] `tests/phase1/fixtures/` — sanitized Docker/QEMU stdout/stderr and malformed lock examples
- [ ] Real QEMU NoCloud readiness spike and retained fixture/serial proof
- [ ] No test-framework installation; use PowerShell 7 already present

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | No end-user authentication exists; QEMU management uses one ephemeral public-key-only SSH channel bound to loopback. |
| V3 Session Management | no | No application session exists; backend process/SSH lifetime is bounded to one build run. |
| V4 Access Control | yes | External secret root ACL, read-only normal-build secret input, Linux tmpfs use, narrow mounts, no Docker socket/privileged container, loopback forwarding. |
| V5 Input Validation | yes | Validate enums, exact hashes/digests, epoch, approved HTTPS repository URLs, canonical paths, archive entries, process output schemas, artifact schemas, and sizes. |
| V6 Cryptography | yes | Alpine `abuild` signatures plus standard SHA-256/SHA-512; never hand-roll cryptography or log private material. |

### Known Threat Patterns for the Build Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Mutable or substituted base/aports/repository content | Tampering | Docker digests, exact aports commit, fixed fallback SHA-512, approved HTTPS URLs, APK signatures, index/APK hashes, fail-closed drift checks |
| PowerShell/QEMU/Docker command injection | Elevation of Privilege / Tampering | Typed parameters, allowlists, `ProcessStartInfo.ArgumentList`, no eval/cmd, reject unsafe paths/control characters |
| Private APK/SSH key disclosure | Information Disclosure | External restricted root, explicit init, read-only ingestion, `/run` tmpfs, redacted logs, content scans, no environment secret |
| Docker socket or privileged-container compromise | Elevation of Privilege | Never mount socket, never `--privileged`, use only required named volumes and bounded binds |
| Malicious archive entry or symlink escape | Tampering | Create archive from clean Git, validate entries, extract into empty Linux root, reject absolute/`..` entries, never accept arbitrary user tar |
| Cache poisoning or stale-section reuse | Tampering | Content-addressed namespaces, verified APK bytes, post-build index recheck, exact-cache clean operation |
| QEMU management port exposure/MITM | Spoofing | `127.0.0.1` hostfwd only, dynamic port, isolated `known_hosts`, ephemeral Ed25519 key, no passwords |
| Partial artifact promoted as last-known-good | Tampering / Repudiation | Stage, validate, host re-hash, atomic rename, update pointer last, retain stable result codes/log evidence |
| Host identity/path disclosure in published evidence | Information Disclosure | Relative basenames and allowlisted sanitized fields; never persist raw `docker info`, environment, command line, or absolute paths |

Security enforcement is applicable even though the resulting bootstrap has no application auth. The dominant attack surface is the supply chain and host-to-builder boundary, not a web session.

## Sources

### Primary (HIGH confidence)

- Local source-of-truth files: `AGENTS.md`, `.planning/REQUIREMENTS.md`, `.planning/config.json`, `.planning/STATE.md`, `.gitignore`, and `01-CONTEXT.md` — project constraints and exact requirement/config/ignore values opened with line numbers.
- Local executable/file probes on 2026-08-25 — PowerShell, Git, Docker client/server state, QEMU/qemu-img, accelerators, EDK2 descriptor/files, OpenSSH, Python, GPG absence, and disk space.
- Official Alpine v3.24 APKINDEX downloads on 2026-08-25 — exact package revisions/build timestamps and main/community compressed-index SHA-256 values.
- Official Alpine GitLab `git ls-remote` on 2026-08-25 — `3.24-stable` resolved to `52643b7a176095362fd87fe73cdb994cb2e5ffae`.
- Official Alpine cloud-image SHA-512 sidecar on 2026-08-25 — exact fallback image hash.

### Secondary (MEDIUM confidence)

- https://wiki.alpinelinux.org/wiki/How_to_make_a_custom_ISO_image_with_mkimage — supported custom-ISO workflow and prerequisites.
- https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh — profile loading, CLI, epoch, checksums, key handling, and section reuse.
- https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.base.sh — package/index/modloop signing and BIOS/EFI/hybrid assembly.
- https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.standard.sh — `profile_virt` inheritance, architecture, kernel, and serial settings.
- https://wiki.alpinelinux.org/wiki/Abuild_and_Helpers — Alpine key/build workflow.
- https://wiki.alpinelinux.org/wiki/Repositories — stable repository behavior.
- https://www.alpinelinux.org/cloud/ and https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/ — official cloud variants and versioned artifacts.
- https://docs.docker.com/reference/cli/docker/system/info/ — daemon/platform evidence.
- https://docs.docker.com/reference/cli/docker/image/pull/ — digest and platform pulls.
- https://docs.docker.com/engine/storage/volumes/ and https://docs.docker.com/engine/storage/bind-mounts/ — persistent Linux volumes and bounded bind behavior.
- https://www.qemu.org/docs/master/system/qemu-manpage.html — ordered accelerators, SMBIOS, and invocation behavior.
- https://www.qemu.org/docs/master/system/whpx.html — WHPX prerequisites and current Windows backend.
- https://www.qemu.org/docs/master/system/devices/net.html — user networking and loopback host forwarding.
- https://www.qemu.org/docs/master/system/images — qcow2 backing images and FAT caveat.
- https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html — SMBIOS/DMI discovery, HTTP seed, filenames, and trailing slash.
- https://docs.cloud-init.io/en/latest/tutorial/qemu.html — QEMU/cloud-init integration patterns.
- https://www.gnu.org/software/xorriso/man_1_xorriso.html — El Torito/system-area reporting.

### Tertiary (LOW confidence)

- None used as authoritative evidence. All unproven implementation expectations are explicitly listed in the Assumptions Log.

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH for exact current pins/package snapshot and local availability; MEDIUM for future availability of mutable Alpine repository bytes.
- Architecture: MEDIUM — it follows official Alpine/Docker/QEMU/cloud-init seams, but neither backend has yet completed this project build on the host.
- Docker backend: LOW operational confidence on this host until a Linux daemon becomes available; design evidence is MEDIUM.
- QEMU fallback: MEDIUM design confidence, LOW local integration confidence until the mandatory NoCloud spike succeeds.
- Pitfalls/security: MEDIUM — grounded in source behavior and direct host state, with execution checks specified for unproven claims.

**Research date:** 2026-08-25  
**Valid until:** 2026-09-01 for repository/index/package and Docker/cloud-image observations; the exact committed pins remain valid as identities but availability must be rechecked.
