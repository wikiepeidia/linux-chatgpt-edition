---
phase: 01-reproducible-build-foundation
plan: "01"
subsystem: infra
tags: [alpine, qemu, powershell, apk, reproducibility, ssh-trust]

requires: []
provides:
  - Clean-commit QEMU-first bootstrap ISO build path for Windows hosts without Docker
  - Owned headless QEMU lifecycle with serial-derived, run-local Ed25519 SSH trust
  - Content-addressed offline APK repository and closed four-key mkimage trust policy
  - Immutable BuildRequest and post-resolution ResolvedBuildLock evidence contracts
affects: [01-02, 01-03, reproducible-builds, boot-verification]

actuals:
  tokens: 47532
  tasks: 3
  commits: 34

tech-stack:
  added: [Alpine Linux 3.24.1, Alpine mkimage, QEMU 11.1.0, PowerShell 7]
  patterns: [owned process leases, serial-derived SSH trust, immutable build requests, content-addressed offline repositories, closed key allowlists]

key-files:
  created:
    - build.ps1
    - builder/inputs.json
    - builder/profiles/mkimg.300k.sh
    - builder/cloud-init/meta-data.template
    - builder/cloud-init/user-data.template
    - scripts/host/Invoke-CheckedProcess.ps1
    - scripts/host/Invoke-QemuBackend.ps1
    - scripts/linux/run-build.sh
    - tests/phase1/run.ps1
    - .gitattributes
  modified: []

key-decisions:
  - "Treat QEMU as an executed first-class backend and record Docker as unverified-unavailable when its daemon is absent."
  - "Trust SSH only from the owned serial channel and ignore ambient SSH configuration, agents, proxies, and host-key stores."
  - "Build only from a verified content-addressed file:///repo snapshot after networking is disabled."
  - "Pass --hostkeys to pinned mkimage only after replacing /etc/apk/keys with a hash-verified closed set of three Alpine x86_64 keys plus the project public signing key."

patterns-established:
  - "Temporal build contracts: initialize external signing identity, create immutable BuildRequest, then emit ResolvedBuildLock only after package resolution."
  - "Owned resource lifecycle: one outer owner acquires and unconditionally releases QEMU, listeners, ports, SSH material, seed media, and overlay state."
  - "Trust evidence is content-bound: exact key, repository, package, command, source, and artifact hashes are validated before publication."

requirements-completed: [BUILD-04]

coverage:
  - id: D1
    description: "Owned QEMU transport remains live across every management stage and uses only serial-derived Ed25519 SSH trust."
    requirement: "BUILD-04"
    verification:
      - kind: unit
        ref: "tests/phase1/run.ps1 -Scope Unit -Requirement BUILD-04"
        status: pass
      - kind: e2e
        ref: "tests/phase1/run.ps1 -Scope Qemu -QemuRoot D:\\VM\\qemu"
        status: pass
    human_judgment: false
  - id: D2
    description: "Immutable request and resolved-lock contracts prove a closed trusted keyring and offline content-addressed APK consumption."
    requirement: "BUILD-04"
    verification:
      - kind: unit
        ref: "tests/phase1/run.ps1#BUILD-04 mkimage trusts only the verified closed x86_64 keyring"
        status: pass
      - kind: integration
        ref: "dist/p01-172f13500b74/resolved-build-lock.json"
        status: pass
    human_judgment: false
  - id: D3
    description: "A clean committed source tree produces a nonzero hash-qualified Alpine 3.24.1 x86_64 bootstrap ISO through real QEMU execution."
    requirement: "BUILD-04"
    verification:
      - kind: e2e
        ref: "tests/phase1/run.ps1#BUILD-04 real clean-tree QEMU tracer"
        status: pass
      - kind: other
        ref: "dist/p01-172f13500b74/300k-bootstrap-x86_64-2c968ee3a0c6.iso sha256:2c968ee3a0c687bd0d779247b7b595494a6a9870308387a07572796fd46d0678"
        status: pass
    human_judgment: false

duration: 3h 40m
completed: 2026-08-26
status: complete
---

# Phase 01 Plan 01: QEMU-First Reproducible Build Foundation Summary

**Clean-commit QEMU execution built a 69,206,016-byte Alpine 3.24.1 x86_64 ISO from a content-addressed offline APK repository under serial-derived SSH trust.**

## Performance

- **Duration:** 3h 40m
- **Started:** 2026-08-25T23:52:58+07:00
- **Completed:** 2026-08-26T03:33:00+07:00
- **Tasks:** 3
- **Files modified:** 10
- **Task commits:** 34

## Accomplishments

- Implemented a dependency-free PowerShell/QEMU path that initializes the project signing identity and builds from two distinct checked child processes without requiring Docker.
- Bound guest management to an owned headless QEMU lease, loopback-only channels, and an exact Ed25519 host key accepted from the serial trust milestone.
- Materialized and reverified a 256-APK content-addressed repository, disabled networking, and assembled with pinned mkimage from only `file:///repo`.
- Published a nonzero 65.99 MiB ISO plus request, package, repository, environment, serial, boot-layout, resource, and artifact-manifest evidence.

## Artifact Evidence

| Fact | Proven value |
| --- | --- |
| Build ID | `p01-172f13500b74` |
| Clean source commit | `7c72eee3f001133eb80a94c17a21b2e37191e432` |
| BuildRequest SHA-256 | `172f13500b7460beb6d1d9eb0c8ab9fe6f8321d0faeb40dfbdae5a1921f23a43` |
| Aports commit | `52643b7a176095362fd87fe73cdb994cb2e5ffae` |
| Repository object | `4c885b460fa76be45711dcc89823f6a955e8154c2b52d0931e478095936fddd1` |
| Retained APK count | 256 |
| ISO | `dist/p01-172f13500b74/300k-bootstrap-x86_64-2c968ee3a0c6.iso` |
| ISO bytes | 69,206,016 |
| ISO SHA-256 | `2c968ee3a0c687bd0d779247b7b595494a6a9870308387a07572796fd46d0678` |
| Backend status | QEMU `executed`; Docker `unverified-unavailable` |
| Cleanup | Complete; every owned resource recorded `false` after shutdown |

### Closed Trusted Key Set

| Basename | SHA-256 | Trust |
| --- | --- | --- |
| `alpine-devel@lists.alpinelinux.org-4a6a0840.rsa.pub` | `9c102bcc376af1498d549b77bdbfa815ae86faa1d2d82f040e616b18ef2df2d4` | Alpine x86_64 |
| `alpine-devel@lists.alpinelinux.org-5261cecb.rsa.pub` | `12f899e55a7691225603d6fb3324940fc51cd7f133e7ead788663c2b7eecb00c` | Alpine x86_64 |
| `alpine-devel@lists.alpinelinux.org-6165ee59.rsa.pub` | `207e4696d3c05f7cb05966aee557307151f1f00217af4143c1bcaf33b8df733f` | Alpine x86_64 |
| `300k.rsa.pub` | `cd961b064aa0925e118528718ef43474f8ffa7091c4a8ab5c619d3748b333d0b` | Project signing |

The resolved lock records `mkimage_hostkeys: true`, `closed_keyring_verified: true`, and `signature_bypass: false`.

## Verification

- `pwsh -NoProfile -File tests/phase1/run.ps1 -Scope Unit -Requirement BUILD-04` — 14 passed, 0 failed.
- `pwsh -NoProfile -File tests/phase1/run.ps1 -Scope Qemu -QemuRoot 'D:\VM\qemu'` — real clean-tree tracer passed, 1 passed, 0 failed.
- Host rehash of the published ISO matched `LATEST.json` exactly and confirmed 69,206,016 nonzero bytes.
- `git status --porcelain --untracked-files=all` remained empty after ignored artifact publication.
- Resolved evidence proves Alpine 3.24.1 x86_64, exact clean source identity, seven pinned inspection commands, `apk --no-network`, disabled networking, and complete resource cleanup.

## Task Commits

1. **Task 1: Implement the owned QEMU lease and isolated SSH trust path**
   - `1ff3270` — RED: define QEMU trust contracts
   - `94d13e6` — GREEN: own QEMU transport trust
2. **Task 2: Implement immutable requests and the verified offline repository build**
   - `4d24e0f` — RED: define immutable build contracts
   - `b0e759b` — GREEN: build from retained APK bytes
   - `965d44c` through `6d292d6` — bounded tracer-driven correctness and security repairs detailed below
3. **Task 3: Execute the real QEMU tracer from a clean commit**
   - `b4a69a0` — close the mkimage trust keyring at the retained signature blocker
   - `7c72eee` — pin authoritative LF Git-blob key bytes
   - Verification-only tracer then passed from clean commit `7c72eee`; generated `dist/` remains ignored by design.

## Files Created/Modified

- `.gitattributes` — preserves LF bytes for guest shell/profile source archives.
- `build.ps1` — sole public entry, clean-tree guard, request creation, backend selection, artifact validation, and publication.
- `builder/inputs.json` — exact Alpine, aports, QEMU, repository-index, package, command, and repository-key pins.
- `builder/profiles/mkimg.300k.sh` — thin `profile_virt` bootstrap profile.
- `builder/cloud-init/meta-data.template` — deterministic NoCloud instance metadata.
- `builder/cloud-init/user-data.template` — ephemeral builder setup and ordered serial trust milestones.
- `scripts/host/Invoke-CheckedProcess.ps1` — checked short process and owned long-lived lease primitives.
- `scripts/host/Invoke-QemuBackend.ps1` — headless QEMU, seed, serial, strict SSH/SCP, transfer, export, and cleanup adapter.
- `scripts/linux/run-build.sh` — signing initialization, repository resolution, offline mkimage assembly, inspection, and evidence generation.
- `tests/phase1/run.ps1` — 14 dependency-free unit contracts and one real clean-tree QEMU tracer.

## Decisions Made

- Kept QEMU transport-only: all package, profile, repository, and mkimage decisions live in the shared Linux entry and public inputs.
- Used serial-derived host trust instead of first-use or ambient host-key state so the loopback SSH boundary fails closed.
- Kept private APK and SSH keys outside Git and moved the APK private key directly into guest tmpfs.
- Used pinned raw aports Git-blob hashes for Alpine keys; Windows working-tree CRLF bytes are not accepted as repository trust pins.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Made the tracer exercise real child processes and retain execution evidence**
- **Found during:** Task 2 integration preparation
- **Issue:** The initial runner did not yet prove separate initialization/build children and full cleanup/environment evidence.
- **Fix:** Added checked child launches, exact result propagation, and verified evidence publication.
- **Files modified:** `tests/phase1/run.ps1`, `build.ps1`
- **Verification:** Unit contracts and the final real QEMU tracer pass.
- **Committed in:** `965d44c`

**2. [Rule 1 - Bug] Corrected NoCloud compilation and live serial trust capture/parsing**
- **Found during:** Task 2 QEMU integration
- **Issue:** The seed server response buffer, concurrent serial reads, blank records, and Ed25519 wire parsing prevented reliable trust establishment.
- **Fix:** Initialized the response buffer, streamed serial through an owned listener, used shared reads, ignored blank records, and validated canonical OpenSSH blobs.
- **Files modified:** `scripts/host/Invoke-QemuBackend.ps1`, `tests/phase1/run.ps1`
- **Verification:** Serial trust unit cases and real SSH readiness pass.
- **Committed in:** `453412f`, `bb5bf7e`, `62b5064`, `ff1185d`, `f35e77c`

**3. [Rule 1 - Bug] Made key-only SSH readiness deterministic and diagnostic**
- **Found during:** Task 2 QEMU integration
- **Issue:** Account lock state and overlapping probes rejected the intended public-key login while discarding the final reason.
- **Fix:** Used an unusable unlocked password hash, serialized bounded probes, proved authorized-key installation, and retained sanitized failure tails.
- **Files modified:** `builder/cloud-init/user-data.template`, `scripts/host/Invoke-QemuBackend.ps1`, `tests/phase1/run.ps1`
- **Verification:** Strict key-only login and readiness tests pass; final QEMU management completed.
- **Committed in:** `afe08e2`, `e134a48`, `11573cb`

**4. [Rule 2 - Missing Critical] Closed guest transfer, remote argv, and source-byte boundaries**
- **Found during:** Task 2 QEMU integration
- **Issue:** Broad guest paths, disk-backed private-key transfer, shell metacharacters, and CRLF shell bytes could weaken or break the host-to-guest contract.
- **Fix:** Bounded writable paths, transferred the signing key directly to tmpfs, quoted remote arguments, and rejected carriage returns in archived guest scripts.
- **Files modified:** `.gitattributes`, `build.ps1`, `scripts/host/Invoke-QemuBackend.ps1`, `tests/phase1/run.ps1`
- **Verification:** Boundary and LF archive unit contracts pass.
- **Committed in:** `18ad4ef`, `b72f75b`, `08ea267`, `054de4b`

**5. [Rule 1 - Bug] Corrected disposable storage and canonical offline repository layout**
- **Found during:** Task 2 real repository preparation
- **Issue:** The overlay was undersized and APK 3 cache, index, manifest, architecture, mount, and target-root key paths did not initially match the canonical offline layout.
- **Fix:** Expanded the overlay/root filesystem and corrected signed-index refresh, run-local cache, self-excluding manifest, `x86_64` staging, `/repo` binding, and target-root trust paths.
- **Files modified:** `scripts/host/Invoke-QemuBackend.ps1`, `scripts/linux/run-build.sh`, `tests/phase1/run.ps1`
- **Verification:** Repository evidence reports 256 verified APKs and the final lock records only `file:///repo` with networking disabled.
- **Committed in:** `aa979d7`, `133d29b`, `8d50f24`, `4ae2ad0`, `9351f87`, `720a413`, `5847d2b`, `1b03785`

**6. [Rule 2 - Missing Critical] Isolated pinned mkimage under a bounded build identity**
- **Found during:** Task 2 offline assembly
- **Issue:** Pinned aports needed a deterministic unprivileged identity, exact architecture, bounded mounts, and readable retained inputs without broadening source writes.
- **Fix:** Added the dedicated account records, CBUILD pin, proc/device mounts, access proofs, and narrowly readable payloads.
- **Files modified:** `scripts/linux/run-build.sh`, `tests/phase1/run.ps1`
- **Verification:** The isolated builder loads APK and completes pinned mkimage from offline bytes.
- **Committed in:** `42e839e`, `10cd01e`, `e5a30c3`, `5644de8`, `4313a4c`

**7. [Rule 1 - Bug] Retained the full virt image closure and permitted only verified repository links**
- **Found during:** Task 2 offline assembly
- **Issue:** Direct profile packages were missing from the retained closure and aports hardlink fetches could not traverse the otherwise read-only verified repository.
- **Fix:** Resolved all pinned profile packages before shutdown, permitted the narrow verified hardlink path, and reverified staged content.
- **Files modified:** `scripts/linux/run-build.sh`, `tests/phase1/run.ps1`
- **Verification:** Final mkimage completed and the complete manifest remained verified.
- **Committed in:** `d671a71`, `6d292d6`

**8. [Rule 2 - Missing Critical] Closed the mkimage keyring before enabling `--hostkeys`**
- **Found during:** Task 3 retained `UNTRUSTED signature` blocker
- **Issue:** Pinned mkimage copies `/etc/apk/keys` into its inner APKROOT only with `--hostkeys`; passing ambient keys would weaken trust.
- **Fix:** Rebuilt `/etc/apk/keys` as an exact hash-verified allowlist of three Alpine x86_64 keys plus the project public key, reverified it before mkimage, used exact `--hostkeys`, rejected bypass flags, and recorded the set in ResolvedBuildLock.
- **Files modified:** `builder/inputs.json`, `build.ps1`, `scripts/linux/run-build.sh`, `tests/phase1/run.ps1`
- **Verification:** Closed-set/mutation unit cases pass and the real inner install completed without `--allow-untrusted`.
- **Committed in:** `b4a69a0`

**9. [Rule 1 - Bug] Replaced CRLF checkout hashes with authoritative LF Git-blob hashes**
- **Found during:** Task 3 clean-tree tracer
- **Issue:** Windows checkout normalization changed the three PEM byte hashes even though Alpine installs the raw pinned aports blobs.
- **Fix:** Derived all three SHA-256 values from exact commit `52643b7a176095362fd87fe73cdb994cb2e5ffae` Git blobs and updated the regression allowlist.
- **Files modified:** `builder/inputs.json`, `tests/phase1/run.ps1`
- **Verification:** The test went RED at 13/14, GREEN at 14/14, then the real QEMU tracer passed.
- **Committed in:** `7c72eee`

---

**Total deviations:** 9 grouped auto-fixed issues across 30 bounded repair commits (5 Rule 1 bug groups, 4 Rule 2 missing-critical groups).
**Impact on plan:** Every repair was required for correctness, reproducibility, or a stated trust boundary. No optional product scope was added.

## Issues Encountered

- The first continuation launch inside the restricted tool sandbox stopped before QEMU because child Git ran as `CodexSandboxOffline` and rejected repository ownership. The unchanged command was rerun under the workspace owner, as required for external temp/network/QEMU execution; no Git trust bypass was added.
- The retained mkimage signature failure was traced to the exact pinned `--hostkeys` code path. The closed keyring repair preserved strict signature enforcement and did not add `--allow-untrusted` or any bypass.
- Stub scan found only internal nullable C# lifecycle variables in the compiled seed server; no placeholder, skipped test, or product stub remains.

## User Setup Required

None - the supplied `D:\VM\qemu` installation was used directly and all signing/state material was created outside Git.

## Next Phase Readiness

- BUILD-04 is proven by a real QEMU artifact and can support the next reproducibility/boot-foundation plans even when Docker is unavailable.
- `dist/LATEST.json` points to the validated bootstrap artifact; future plans can consume its request, lock, boot layout, and manifest evidence.
- No open blocker, unrun verification, skipped test, known stub, or unclean owned QEMU resource remains.

---

*Phase: 01-reproducible-build-foundation*
*Completed: 2026-08-26*

## Self-Check: PASSED

- All 10 source artifacts, this summary, and the published ISO exist.
- All 34 task/repair commits referenced above resolve to commit objects.
- The ISO is 69,206,016 bytes and rehashes to `2c968ee3a0c687bd0d779247b7b595494a6a9870308387a07572796fd46d0678`.
- Summary frontmatter records `status: complete`, `requirements-completed: [BUILD-04]`, and deterministic coverage metadata.
