# Roadmap: 300K Linux

## Overview

300K Linux moves through six deliberately gated outcomes: first a reproducible Windows-to-Linux builder, then a diagnosable offline BIOS boot, a working graphical/PTY spine, the complete 300K parody experience, exact firmware/media verification, and finally measured size optimization plus release evidence. Each gate preserves a uniquely hashed last-known-good artifact or a fast local proof; later work may extend that proof but cannot silently redefine it. The 100 MB target is measured only after the complete experience is green.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): planned milestone work
- Decimal phases (2.1, 2.2): urgent insertions, marked `INSERTED`

- [ ] **Phase 1: Reproducible Build Foundation** - A contributor has one pinned, secret-safe Windows build path and a compatible Alpine VM fallback.
- [ ] **Phase 2: Offline Diskless BIOS Boot** - A clean build yields an identified ISO that reaches a diagnosable offline root through BIOS optical boot.
- [ ] **Phase 3: Graphical Spine and Real Terminal** - The live user gets reliable graphics, a real PTY-backed shell, and a rescue path.
- [ ] **Phase 4: 300K Product Slice and Comedy Engine** - Cold boot lands in the complete offline parody interface with safe comedy, utilities, and terminal separation.
- [ ] **Phase 5: Firmware, Media, and Semantic Verification** - Every compatibility claim is proven against the exact candidate bytes with bounded evidence.
- [ ] **Phase 6: Size Optimization and Release Evidence** - The smallest complete green candidate is rebuilt, measured, and published honestly.

## Phase Details

### Phase 1: Reproducible Build Foundation

**Goal:** Contributors can reliably enter the same pinned, secret-safe Linux image-building environment from the Windows host.
**Mode:** mvp
**Depends on:** Nothing (first phase)
**Requirements:** BUILD-01, BUILD-03, BUILD-04
**Success Criteria** (what must be TRUE):

  1. A contributor can invoke one documented PowerShell entry point and receive clear pass/fail results for Docker Linux/amd64, pinned Alpine/aports/repository/epoch inputs, QEMU, and artifact-path preflight.
  2. The pinned builder can produce a uniquely hashed bootstrap ISO and boot report, proving the Windows-to-Linux build and artifact-transfer path before custom runtime work begins.
  3. Inspection of Git and the bootstrap ISO finds no private signing key, credential, token, host-specific path, or build cache; persistent signing material remains outside both.
  4. When Docker Linux containers are unavailable, a contributor can run the same profile and inputs in the documented Alpine QEMU VM fallback without changing the distribution architecture.

**Plans:** 1/3 plans executed

Plans:
**Wave 1**

- [x] 01-01-PLAN.md — Prove the QEMU-first walking skeleton and freeze the shared build contract.

**Wave 2** *(blocked on Wave 1 completion)*

- [ ] 01-02-PLAN.md — Harden secret, process, path, inspection, and atomic-publication boundaries.

**Wave 3** *(blocked on Wave 2 completion)*

- [ ] 01-03-PLAN.md — Add the strict Docker adapter, cross-backend parity, and contributor contract.

### Phase 2: Offline Diskless BIOS Boot

**Goal:** Contributors have a uniquely identified, offline, diskless ISO foundation that cold-boots through the BIOS optical path and remains diagnosable.
**Mode:** mvp
**Depends on:** Phase 1
**Requirements:** BUILD-02, BOOT-03
**Success Criteria** (what must be TRUE):

  1. A clean custom-profile build produces a uniquely named x86_64 ISO with its SHA-256, exact byte size, build lock, resolved package manifest, and boot-layout report.
  2. With 1 GiB RAM and `-nic none`, the current hashed ISO cold-boots through QEMU's BIOS optical path, restores its diskless overlay, installs the declared packages from the ISO-local repository, and emits an unambiguous `ROOTFS_READY` milestone.
  3. Human-readable boot diagnostics remain available alongside the stable milestone, and the resulting hash is retained as the boot-core last-known-good candidate.

**Plans:** TBD

### Phase 3: Graphical Spine and Real Terminal

**Goal:** Users can enter a reliable unprivileged graphical session, use a genuine local shell, and recover when graphics fail.
**Mode:** mvp
**Depends on:** Phase 2
**Requirements:** BOOT-06, TERM-01, TERM-02
**Success Criteria** (what must be TRUE):

  1. A cold boot reaches `X_READY` as the unprivileged live user under the fixed QEMU display contract, with readable text and working keyboard, pointer, and resize behavior.
  2. Pressing `Ctrl+Alt+T` opens 300K Terminal as a real PTY-backed BusyBox `ash` login shell owned by the unprivileged live user.
  3. In that terminal, ordinary commands, pipelines, file creation, ANSI output, resize, Ctrl-C, and failing-command exit status behave like a normal local shell and produce a retained `TERM_EXEC_OK` proof.
  4. A failed or exhausted graphical startup attempt stops retrying and leaves a usable rescue console or terminal fallback rather than a blank screen or restart loop.

**Plans:** TBD
**UI hint:** yes

### Phase 4: 300K Product Slice and Comedy Engine

**Goal:** Users can cold-boot directly into the complete recognizable, funny, offline 300K Linux experience and safely use every core control.
**Mode:** mvp
**Depends on:** Phase 3
**Requirements:** BOOT-01, BOOT-02, UI-01, UI-02, UI-03, UI-04, TERM-03, TERM-04, TERM-05, FUN-01, FUN-02, FUN-03, FUN-04, FUN-05, TOOL-01, TOOL-02, TOOL-03, TOOL-04
**Success Criteria** (what must be TRUE):

  1. With networking disabled, a cold boot restores the local package set and opens the full-screen 300K conversation shell without login or typed commands; the UI stays usable at 1024x768 and 800x600 and persistently identifies itself as unofficial, offline, and locally scripted.
  2. The composer answers identity, internet, credits, capability, help, and unknown-input intents locally, while shell-looking input causes no command, file, or network side effect and arbitrary commands remain confined to the clearly separate terminal.
  3. At least 40 reviewed original lines span the required comedy decks; fixed seeds replay the same shuffle-bag sequences, no deck item repeats before exhaustion, and random effects occur only after deliberate actions without changing semantics or lifecycle behavior.
  4. A user can finish the core demo using only the keyboard with visible focus, logical traversal, readable contrast, no trap, a reliable terminal-to-home path, and Reduced Chaos suppressing nonessential motion without removing controls or substantive text.
  5. Calculator, factual System Info, Help/About, clean reboot/shutdown, the ephemeral-session warning, and `300k help|credits|why|fortune|seed|about` all provide accurate documented behavior and stable exits from the main interface or terminal.

**Plans:** TBD
**UI hint:** yes

### Phase 5: Firmware, Media, and Semantic Verification

**Goal:** Testers can trust every boot and media claim because it is tied to ordered guest behavior and retained evidence for the exact ISO hash.
**Mode:** mvp
**Depends on:** Phase 4
**Requirements:** BOOT-04, BOOT-05, VER-01, VER-02, VER-03
**Success Criteria** (what must be TRUE):

  1. The exact candidate ISO completes bounded, offline BIOS and non-Secure-Boot x86_64 UEFI optical lanes, using fresh writable UEFI variables and emitting ordered overlay, package, live-user, X, UI, terminal, and clean-shutdown milestones.
  2. USB-hybrid wording appears only if those exact ISO bytes also pass the QEMU raw-disk lane; otherwise the evidence and release text explicitly say optical-ISO-only.
  3. The scripted smoke flow captures a nonblank screenshot and proves UI readiness, real terminal execution, composer non-execution, and clean shutdown against the recorded ISO SHA-256.
  4. Every claimed firmware/media lane has its own bounded timeout, pass/fail result, serial log, diagnostics, and retained evidence bundle; process existence alone cannot count as success.

**Plans:** TBD
**UI hint:** yes

### Phase 6: Size Optimization and Release Evidence

**Goal:** Users receive the smallest verified 300K Linux release candidate together with complete, honest evidence of its size, identity, capabilities, and limits.
**Mode:** mvp
**Depends on:** Phase 5
**Requirements:** VER-04, VER-05
**Success Criteria** (what must be TRUE):

  1. The release reports exact compressed ISO bytes and MiB, installed/runtime observations, package and asset contributions, and an explicit met/missed result for the 100 MB stretch target.
  2. The accepted smallest candidate preserves the complete P0 experience through two clean builds or clean-boot validation passes without a warm guest cache, and the full Phase 5 matrix still references its final hash.
  3. If any size trim breaks boot, input, UI, terminal, firmware, or shutdown, the larger last-known-good image remains the release candidate and the failed trim is not used to make a smaller claim.

**Plans:** TBD

## Progress

**Execution Order:** Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5 → Phase 6

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Reproducible Build Foundation | 1/3 | In Progress | - |
| 2. Offline Diskless BIOS Boot | 0/TBD | Not started | - |
| 3. Graphical Spine and Real Terminal | 0/TBD | Not started | - |
| 4. 300K Product Slice and Comedy Engine | 0/TBD | Not started | - |
| 5. Firmware, Media, and Semantic Verification | 0/TBD | Not started | - |
| 6. Size Optimization and Release Evidence | 0/TBD | Not started | - |
