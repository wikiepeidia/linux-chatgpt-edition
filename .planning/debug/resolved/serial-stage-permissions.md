---
status: resolved
trigger: "ROOTFS_READY is visible but every non-root X/UI/TERM marker is silently lost after ttyS0 getty starts"
created: 2026-08-28
updated: 2026-08-28T02:47:00+07:00
---

# Debug Session: Serial Stage Permissions

## Symptoms

- expected: Root and unprivileged `chatgpt` runtime stages all write ordered readiness records to the same `/dev/ttyS0` channel so the smoke can observe ROOTFS/X/UI/TERM and then capture a screenshot.
- actual: Candidate `deadline-0d2637f5f224` emits exactly `ROOTFS_READY` as root before getties start, then the serial stream contains only Alpine boot and `300k login:`. No later non-root marker appears over 900 seconds, and the marker-gated harness therefore never captures a screenshot or PTY proof.
- artifact: `300k-deadline-x86_64-689db084d9ad.iso`, SHA-256 `689db084d9ad188c192e0a681c53fc7c3c289d0a1e14f33efa3de1948a779ac7`, exactly 183,500,800 bytes (175 MiB), source commit `bf59c781`.
- smoke_evidence: Sole attempt `702509c6691f492b86e8a6209992cf47` closed `DEADLINE_SMOKE_TIMEOUT`; attempt SHA prefix `92f8afe`, failure prefix `32e8c4f`, argv prefix `0d12f304`, serial SHA prefix `4af7ab07`. No retry, recovery, promotion, screenshot, or PTY evidence.
- integrity: QEMU and runners are zero; clean HEAD `bf59c781`; LATEST SHA prefix `34cb52`, old LKG prefix `2c968e`, and all earlier candidates/attempts remain exact.
- environment: Alpine 3.24, exact BusyBox 1.37.0-r31, eudev lifecycle, chatgpt uid/gid 1000 with tty/dialout supplemental groups, BIOS pc/TCG optical QEMU, literal `-nic none`.

## Current Focus

- reasoning_checkpoint:
    hypothesis: The failure requires the authored BusyBox ttyS0 getty to reset the device to root:root 0620 after ROOTFS_READY while X/UI/TERM use the direct serial-stage helper as chatgpt; without a post-group root:dialout 0660 contract, every later write fails the helper's `-w` gate and is silently omitted.
    confirming_evidence:
        - Exact inittab starts the ttyS0 getty only after OpenRC default and the sole root ROOTFS_READY producer.
        - Exact BusyBox 1.37.0 getty chowns its tty root:root and chmods 0620; chatgpt's tty/dialout groups cannot write that mode.
        - Exact X/UI/TERM producer paths all call the same direct ttyS0 helper as uid 1000 after the getty starts.
        - Focused specified RuntimeStatic regression is RED 9/10 solely on the incompatible ttyS0 getty; all nine pre-existing checks remain green.
    falsification_test: The hypothesis would be false if the focused oracle accepted the current getty/direct-writer combination, if exact BusyBox did not reset ownership/mode, or if the later producers ran as root or wrote through a different channel.
    fix_rationale: Remove only the serial getty that retakes ttyS0, retain tty2 rescue, and establish root:dialout 0660 inside an exact character-device guard after verified chatgpt dialout membership and before ROOTFS_READY; this removes the ownership race while preserving direct validated non-root markers without privilege.
    blind_spots: No rebuilt guest or QEMU run is permitted in this session, so static checks cannot prove the separate X path executes; exact X/profile/UI sources show no distinct deterministic blocker and will not be edited.
    candidate_causes:
        - config: inittab respawns BusyBox getty on the same ttyS0 proof channel.
        - code: startup does not verify dialout membership and establish root:dialout 0660 before declaring ROOTFS_READY.
        - environment: pinned BusyBox getty deterministically applies root:root 0620 to its opened tty.
    and_gate: yes — the missing non-root markers require both the post-ROOTFS getty ownership reset and later uid-1000 direct writers; startup's absent fail-closed ownership contract leaves that combination uncorrected.
- tdd_checkpoint:
    test_file: tests/deadline/run.ps1
    test_name: Non-root serial stages retain a dialout-writable tty without a competing getty
    status: green
    failure_output: "Prior RED: RuntimeStatic passed=9 failed=1; GREEN: RuntimeStatic passed=10 failed=0."
- next_action: Archive this file under `.planning/debug/resolved/`, append the recurrence pattern to `knowledge-base.md`, and commit only those two planning paths.
- bug_class: bohrbug
- constraints:
    - preserve_all_artifacts_and_evidence: true
    - qemu_before_green: forbidden
    - rebuild_before_green: forbidden
    - keep_tty2_rescue: true
    - promotion_without_markers_screenshot_pty: forbidden

## Evidence

- timestamp: 2026-08-28T02:25:00+07:00
  checked: Exact candidate inittab, BusyBox getty ownership contract, stage writers, and failed serial evidence
  found: The only root marker is emitted before ttyS0 getty; every missing marker is emitted later as uid 1000 through a helper that silently skips an unwritable device.
  implication: The serial readiness channel has a deterministic privilege/ownership conflict; absence of X/UI/TERM records cannot yet diagnose the graphical runtime.

- timestamp: 2026-08-28T02:39:00+07:00
  checked: Debug knowledge base, exact local inittab/startup/runtime/X/UI sources, and RuntimeStatic harness
  found: No prior KB entry covers this tty ownership collision. The local sources reproduce the recorded causal order exactly; the existing RuntimeStatic suite asserts marker producers and tty2 rescue but does not assert serial ownership or exclude ttyS0 getty.
  implication: A specified static oracle can reproduce the missing contract without QEMU, build, artifact, evidence, LATEST, or LKG mutation.

- timestamp: 2026-08-28T02:40:22+07:00
  checked: Focused test-first RuntimeStatic regression against unchanged production sources
  found: RuntimeStatic is RED at 9 passed and 1 failed; the sole failure is `Non-root serial stages retain a dialout-writable tty without a competing getty` rejecting the exact ttyS0 getty. All nine prior RuntimeStatic tests pass.
  implication: The bug is reproducible with a specified contract oracle; production code may now receive the smallest causal fix.

- timestamp: 2026-08-28T02:41:11+07:00
  checked: Minimal production fix against the focused specified RuntimeStatic oracle
  found: Removing only the ttyS0 getty and adding the character-device-guarded dialout membership/root:dialout 0660 startup contract makes RuntimeStatic GREEN at 10 passed and 0 failed; tty2 rescue and all sole-producer marker checks remain green.
  implication: The causal contract is repaired without changing stage validation, adding privilege, or editing the post-login/X/UI path.

- timestamp: 2026-08-28T02:42:00+07:00
  checked: Held-out adjacent static suites after the fix
  found: Deadline AllStatic passes 16/16 and Phase 1 Unit passes 27/27. These scopes launch no QEMU and perform no ISO build, promotion, artifact/evidence, LATEST, or LKG mutation.
  implication: Runtime, build, publication, smoke-unit, and Phase 1 host/build invariants remain green; proceed to causal mutants.

- timestamp: 2026-08-28T02:43:00+07:00
  checked: Exact fix-site mutant reintroducing `ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100`
  found: RuntimeStatic returns to RED at 9/10, with only the focused serial contract failing on the competing getty.
  implication: The regression test kills the original getty defect specifically; restore green before testing the permission branch.

- timestamp: 2026-08-28T02:44:00+07:00
  checked: Independent permission mutant changing only `chmod 0660 /dev/ttyS0` to `chmod 0620 /dev/ttyS0`
  found: RuntimeStatic is RED at 9/10, with only the focused serial contract failing because the mode is not exactly 0660.
  implication: The oracle independently covers the ownership/mode branch rather than passing merely because the getty was removed.

- timestamp: 2026-08-28T02:45:00+07:00
  checked: Reapplication after both causal mutants
  found: Restoring the getty-free inittab and exact 0660 mode returns RuntimeStatic to GREEN at 10/10.
  implication: The bug returns under each targeted causal mutation and disappears only when the complete fix is reapplied.

- timestamp: 2026-08-28T02:46:00+07:00
  checked: Exact diff, diff hygiene, no-op/deletion guard, and post-login/X/UI scope
  found: `git diff --check` passes. The only production deletion is the RCA-justified conflicting ttyS0 getty; it is paired with a fail-closed permission contract and focused test. Profile, `.xinitrc`, `300k-runtime`, and `ui.tcl` have no diff, and no artifact/evidence/LATEST/LKG path changed.
  implication: The fix is minimal, does not weaken stage validation or add privilege, and introduces no unsupported X change.

## Eliminated

- hypothesis: The prior ROOTFS account-lock fix regressed.
  evidence: The exact guest emits one ROOTFS_READY and the candidate contains the idempotent lock guard.
  timestamp: 2026-08-28T02:25:00+07:00

- hypothesis: The authored post-login profile uses an invalid shell variable name or has a proven syntax failure.
  evidence: Exact ash syntax and `_300K_SESSION_ATTEMPTED` state name are valid; no deterministic profile syntax blocker was found offline.
  timestamp: 2026-08-28T02:25:00+07:00

## Resolution

- root_cause: The inittab respawns pinned BusyBox getty on ttyS0 after ROOTFS_READY, which resets the shared proof device to root:root 0620; later X/UI/TERM producers run as chatgpt and write directly through a helper that skips an unwritable tty, while startup lacks a verified root:dialout 0660 contract to keep the channel writable.
- fix: Remove the competing ttyS0 BusyBox getty while retaining tty2 rescue; in 300k.start, after supplemental-group assignment and only for a ttyS0 character device, fail closed unless chatgpt belongs to dialout, then apply root:dialout ownership and mode 0660 before ROOTFS_READY. Add a specified RuntimeStatic regression for the complete contract.
- verification:
    target_test: { result: pass, suite: "Deadline RuntimeStatic 10/10" }
    mutation_check: { result: pass, method: "manual exact fix-site mutants because no shell/PowerShell mutation runner is configured", mutant_killed: true, mutants: ["reintroduced ttyS0 getty -> RuntimeStatic 9/10", "changed 0660 to 0620 -> RuntimeStatic 9/10"] }
    no_op_deletion: { result: pass, deletion_justified_by_rca: true, evidence: "Only the conflicting serial getty is removed; startup gains a fail-closed ownership/mode contract and the oracle is strengthened." }
    adjacent_tests: { result: pass, suites_run: ["Deadline AllStatic 16/16", "Phase 1 Unit 27/27", "post-login/X/UI no-diff audit"] }
    revert_and_reconfirm: { result: pass, bug_returned_on_revert: true, fixed_on_reapply: true, evidence: "Both exact getty and permission mutants independently failed 9/10; complete reapplication passed 10/10." }
    guardrail_verdict: accepted
    end_to_end_guest: { result: not_run, reason: "Explicit task constraint forbids QEMU, rebuild, promotion, and artifact/evidence mutation; the next rebuilt candidate must still prove ordered markers, screenshot, and PTY." }
- files_changed:
    - builder/apkovl/rootfs/etc/inittab
    - builder/apkovl/rootfs/etc/local.d/300k.start
    - tests/deadline/run.ps1
- code_commit: ab43575
- oracle_type: specified

## Prevention

- branching_5_whys:
    - Later markers were absent because `serial-stage` skipped its direct ttyS0 write when `-w` was false.
    - ttyS0 was unwritable to chatgpt because BusyBox getty reset it to root:root 0620 after ROOTFS_READY.
    - The same tty was assigned both to a login getty and to the non-root proof channel.
    - Startup added dialout membership but did not verify it or establish an explicit final ownership/mode contract.
    - RuntimeStatic checked producer uniqueness and rescue consoles but not the cross-file serial ownership lifecycle.
- why_not_caught: RuntimeStatic asserted chatgpt's supplemental groups, marker producers, and tty2 rescue separately, but never modeled BusyBox getty's root:root 0620 side effect against the direct uid-1000 proof writer; the helper's silent `-w` skip hid the channel failure as missing X/UI/TERM.
- recurrence_guard: Specified regression `tests/deadline/run.ps1` — `Non-root serial stages retain a dialout-writable tty without a competing getty`; RED 9/10, GREEN 10/10, exact getty and 0620 mutants killed, Deadline AllStatic 16/16, and Phase 1 Unit 27/27.
