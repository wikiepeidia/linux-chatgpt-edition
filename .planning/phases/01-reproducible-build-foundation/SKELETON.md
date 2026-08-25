# Walking Skeleton — 300K Linux

**Phase:** 1  
**Generated:** 2026-08-25

## Capability Proven End-to-End

> After source changes are committed, a contributor runs one PowerShell command on Windows; the bounded QEMU Alpine backend carries an immutable request into the shared Linux builder and atomically publishes a uniquely hash-named bootstrap ISO, resolved lock, decoded-content audit, manifest, checksum, package records, QEMU evidence, and structural xorriso boot-layout report under `dist/`.

This is a build-appliance skeleton, not a web application skeleton. It has no route, database, browser UI, end-user authentication, hosted API, or deployment service.

## Architectural Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Image framework | Alpine Linux `3.24.1` plus Alpine `mkimage.sh` from exact aports commit `52643b7a176095362fd87fe73cdb994cb2e5ffae` | Reuses Alpine's signed package resolution, `linux-virt`, ISOLINUX, GRUB EFI, modloop, and hybrid ISO assembly rather than rebuilding a boot stack overnight. |
| Project profile | Thin `profile_300k_bootstrap` inheriting upstream `profile_virt` | Project identity remains small while upstream owns kernel, bootloader, package-index, and ISO mechanics. |
| Host contract | One root `build.ps1` creates an ordered immutable BuildRequest and owns selection, validation, and publication | Contributor behavior and content identity do not drift by backend. |
| Data contract | Versioned public `builder/inputs.json`; KeyInitRequest; immutable pre-build `build-request.json`; guest-emitted post-resolution `resolved-build-lock.json`; `artifact-manifest.json`; checksums; package/APK locks; and sanitized environment evidence | Key initialization, known content inputs, and resolved package/output facts are temporally distinct; deterministic relative-name files are the cross-phase interface. |
| Linux build core | `/workspace/scripts/linux/run-build.sh` at fixed canonical guest paths | Docker and QEMU are transport/state adapters, never separate distributions or build implementations. |
| First executable backend | QEMU 11.1.0 from `D:\VM\qemu`, pinned Alpine cloud base, disposable overlay, content-scoped cache, owned long-lived process lease, public-only NoCloud, serial-derived Ed25519 host trust, and isolated loopback SSH | The local Docker server is unavailable, while QEMU is installed and can prove the complete path now. |
| Container backend | Thin adapter over the exact pinned Alpine linux/amd64 image using a networked repository-resolver container followed by a separate network-disabled build container | A verified index/package set cannot be replaced between checking and installation, and Docker remains visibly unverified until a real daemon completes the lane. |
| Package replay | Verified indexes, complete APK closure, exact aports bytes, and pinned gzip/xz/zstd/lz4/cpio inspection commands retained as a same-host content-addressed local repository | Build installation uses only file repositories; decoder package ownership, executable paths, versions, and round trips are proven before networking is disabled and recorded in ResolvedBuildLock. |
| Hostile image extraction | Preflight each complete member/type/size/link graph before materialization; stream regular files only through exclusive, bounded destinations under a fresh scratch root; never materialize archive links | An absolute, traversing, cyclic, or link-mediated member cannot write outside scratch, and declared/actual expansion limits fail before publication. |
| Secrets | External APK/SSH identities, read-only ingress, guest tmpfs at `/run/300k-secrets`, public filename/hash only in evidence | Private material cannot enter Git, persistent guest state, logs, staging, `dist/`, or the ISO. |
| Auth | No product authentication; ephemeral public-key-only SSH exists solely for one loopback-bound QEMU management run | The running parody has no accounts, and the build channel has no reusable password/session. |
| Network | Only pinned public Alpine/Git downloads during image construction; no hosted application API or runtime cloud dependency | Downloads are checksum/signature gated and cached externally; the eventual ISO remains local/offline. |
| Publication | Host validates untrusted staging, copies `.partial`, re-hashes, renames atomically, and updates `dist/LATEST.json` last | A failed overnight run cannot replace the last complete artifact. |

## Canonical Directory Layout

```text
/
├── build.ps1
├── builder/
│   ├── inputs.json
│   ├── profiles/mkimg.300k.sh
│   └── cloud-init/
│       ├── meta-data.template
│       └── user-data.template
├── scripts/
│   ├── host/
│   │   ├── Invoke-CheckedProcess.ps1
│   │   ├── Invoke-QemuBackend.ps1
│   │   └── Invoke-DockerBackend.ps1
│   └── linux/
│       ├── run-build.sh              # key init, repository prepare, offline build
│       └── inspect-iso.sh             # bounded recursive Alpine payload audit
├── tests/phase1/
│   └── run.ps1                       # Unit/Qemu/Security/Artifact/Docker/All
└── dist/                         # generated, ignored, complete artifacts only
```

Canonical Linux guest roles are `/workspace`, `/inputs/build-request.json`, `/work`, `/var/cache/apk`, `/run/300k-secrets`, `/export`, and `/workspace/scripts/linux/run-build.sh`.

## Stack Touched in Phase 1

- [ ] Windows host entry, checked native-process runner, typed preflight, and stable result codes
- [ ] Temporally distinct KeyInitRequest, immutable BuildRequest, and post-resolution ResolvedBuildLock contracts
- [ ] Real QEMU NoCloud/SSH provisioning using an immutable base, owned process lease, serial-derived host trust, and disposable overlay
- [ ] Verified same-host content-addressed repository with exact inspection-tool pins and network-disabled package installation/build
- [ ] Shared Alpine `mkimage` build through `profile_300k_bootstrap`
- [ ] Explicit external signing identity and guest-tmpfs secret lifecycle
- [ ] Preflight-first, no-follow, root-confined recursive ISO/container decoding with outside-scratch sentinel tests, decoded secret scan, independent host re-hash, and atomic `dist/` publication
- [ ] Thin Docker linux/amd64 adapter over the identical guest contract, reported unverified until a real daemon lane runs
- [ ] Native PowerShell unit/QEMU/Docker/artifact scopes with no Pester dependency

## Capability Gate

Phase 1 is complete only when source-changing tasks are committed, the tree is clean, Unit, real QEMU, Security, and exact-hash Artifact scopes are green, and `dist/LATEST.json` points to the complete bundle produced by that run. Docker has a separate operational state: it is `executed-pass` only after a real Linux daemon completes the lane; otherwise it remains visibly `unverified-unavailable`.

Structural El Torito/EFI/xorriso evidence and `qemu-img` readability do not claim a BIOS or UEFI boot. The output is a **bootstrap artifact**, not a release.

## Out of Scope (Deferred to Later Slices)

- Phase 2: diskless overlay restoration, ISO-local package installation, offline BIOS optical boot, and a root-ready milestone
- Phase 3: Xorg/Openbox/Tcl-Tk graphical spine, real xterm/BusyBox PTY behavior, and rescue path
- Phase 4: the complete offline 300K parody UI, comedy engine, keyboard/accessibility behavior, tools, and lifecycle controls
- Phase 5: exact-byte BIOS, UEFI, and conditional raw-media execution plus screenshot/terminal/composer/shutdown evidence
- Phase 6: measured package/asset size work, the 100 MB stretch result, and release-candidate evidence
- Persistent installation, partitioning, updates, Secure Boot, broad hardware certification, browser stacks, hosted APIs, accounts, Codex, OpenAI services, and model runtimes

## Subsequent Slice Plan

Each later phase extends this skeleton without changing the immutable request, shared Linux build core, external secret boundary, or atomic artifact identity:

- Phase 2 turns the bootstrap profile into a diagnosable offline diskless BIOS-boot foundation.
- Phase 3 adds the graphical session and genuine local terminal spine.
- Phase 4 adds the recognizable 300K interface, safe comedy, and utilities.
- Phase 5 proves every claimed firmware/media/user flow against the exact ISO hash.
- Phase 6 measures and trims only after the complete experience remains green.
