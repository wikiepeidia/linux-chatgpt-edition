---
status: awaiting_human_verify
trigger: "Corrected Deadline MVP applies its apkovl and hostname but reaches login without ROOTFS_READY or graphical runtime"
created: 2026-08-28
updated: 2026-08-28T02:44:00+07:00
---

# Debug Session: ROOTFS Ready Not Emitted

## Symptoms

- expected: After the apkovl is applied, explicit OpenRC runlevels execute `/etc/local.d/300k.start`, establish the locked unprivileged `chatgpt` live user and runtime prerequisites, emit `300K_STAGE=ROOTFS_READY` to `/dev/ttyS0`, then tty1 autologin reaches guarded X/Openbox/Tk startup and emits X/UI/terminal proof markers.
- actual: Corrected candidate `deadline-45af9bbdc0f5` boots through ISOLINUX and Alpine 3.24 to exactly one hostname-correct `300k login:` prompt, proving the overlay identity applies, but its 900-second smoke records zero ROOTFS/X/UI/TERM markers and no OpenRC/X failure text.
- artifact: `300k-deadline-x86_64-c7d40c23fd78.iso`, SHA-256 `c7d40c23fd78d7d07f899ea89e680292cf662b7c5acc752fbe0b719402b71bae`, exactly 183,500,800 bytes (175 MiB), source commit `9e46df093b79`.
- offline_overlay_proof: Overlay SHA-256 `d846cc8494488bfe0743b6775ecfb46752974df3c48a39d30bfd2863f08dd34d`, 7,361 bytes, 49 canonical package-relative members, exact hostname `300k`, 16 coherent explicit eudev runlevel symlinks, no mdev/default-service conflict, and 20 required parent directories at mode 0755.
- smoke_evidence: Ordinary attempt `3d92a1ec8a0946d98fdb2fbcb1aa1ff9` closed `DEADLINE_SMOKE_TIMEOUT`; record SHA-256 prefix `64b18ab4`, failure prefix `117cd0c8`, argv prefix `121cb629`, serial prefix `ccd73df6` with 177 bytes. No screenshot or PTY evidence exists.
- integrity: No retry, recovery, or promotion occurred. QEMU and runner counts are zero. `dist/LATEST.json` remains SHA-256 `34cb52ca77d0a6e679aa10a65aa34ff7131eb5cedb0796660d049ffbc1f297a7`; old LKG remains `2c968ee3a0c687bd0d779247b7b595494a6a9870308387a07572796fd46d0678`; prior failed candidate and attempts remain exact. Product tree is clean at `9e46df093b79` before this debug record.
- environment: Windows host, QEMU 11.1.0 at `D:\\VM\\qemu`; direct BIOS optical pc/TCG lane with literal `-nic none`; no working Docker engine or WSL.

## Current Focus

reasoning_checkpoint:
  hypothesis: "BusyBox adduser -D writes an already locked shadow entry, so unconditional passwd -l returns nonzero; set -e aborts 300k.start before ROOTFS_READY, while OpenRC local suppresses the diagnostic and returns success."
  confirming_evidence:
    - "Exact candidate BusyBox 1.37.0-r31 binary contains locked adduser shadow template !:%u:0:99999:7::: and the already-locked passwd fatal message."
    - "Exact OpenRC 0.63.2-r0 local service redirects non-verbose child output to /dev/null and intentionally returns 0 after child errors."
    - "Focused RuntimeStatic regression is RED only on the absent idempotent shadow-lock guard; the other eight RuntimeStatic checks remain green."
  falsification_test: "The hypothesis would be false if pinned BusyBox passwd -l returned zero for a shadow password beginning with !, or if installing the conditional guard did not make the focused test green while preserving one fallback lock operation."
  fix_rationale: "Guard the single passwd -l fallback with an awk check that accepts ! and !! as already locked; this preserves the locked-account security contract and prevents the redundant nonzero call rather than suppressing set -e or the ROOTFS marker."
  blind_spots: "No Linux user-mode executor is available offline, so exact guest command execution is not repeated; downstream tty1/getty/login/profile behavior still requires an immediate static contract audit before another build."
  candidate_causes:
    - "code: unconditional passwd -l under set -e after adduser -D"
    - "environment/data: pinned BusyBox default shadow field is already locked and redundant passwd -l is nonzero"
    - "config: OpenRC local non-verbose redirection and forced success hide the child failure"
  and_gate: "yes — missing ROOTFS_READY requires the unconditional relock plus BusyBox's already-locked/nonzero semantics; the observed silence additionally requires OpenRC local's masking behavior."
tdd_checkpoint:
  test_file: "tests/deadline/run.ps1"
  test_name: "BusyBox live-user locking is idempotent before ROOTFS readiness"
  status: "green"
  failure_output: "Prior RED: RESULT scope=RuntimeStatic passed=8 failed=1; GREEN: RESULT scope=RuntimeStatic passed=9 failed=0"
next_action: "Await a separately authorized rebuild from commit `cc612a4` and real-guest verification of ordered ROOTFS_READY/X_READY/UI_READY/TERM_EXEC_OK markers; do not archive this session or update LATEST/LKG before that evidence exists."
bug_class: bohrbug
- constraints:
    - preserve_all_candidates_attempts_latest_lkg: true
    - offline_first: true
    - qemu_before_root_cause: forbidden
    - rebuild_before_test_first_fix: forbidden
    - promotion_without_gui_and_pty_proof: forbidden

## Evidence

- timestamp: 2026-08-28T01:12:00+07:00
  checked: Debug knowledge base and authored startup chain
  found: No prior resolved entry matches this post-overlay boundary. The prior `apkovl-not-applied` pattern is contradicted by the corrected hostname and canonical member proof. Authored files do include executable `etc/local.d/300k.start`, a `default/local` runlevel symlink, and an inittab tty1 autologin path; `300k.start` executes many commands before its sole `ROOTFS_READY` marker.
  implication: Treat this as a deterministic Bohrbug and test the exact OpenRC/package-command contract rather than retrying the prior overlay namespace fix.

- timestamp: 2026-08-28T01:20:00+07:00
  checked: Corrected candidate build lock and requested image package set
  found: The candidate is pinned to Alpine 3.24.1, BusyBox 1.37.0-r31, and OpenRC 0.63.2-r0; its ISO retains an offline `/apks/x86_64` repository. The image request includes `alpine-base`, `doas`, `eudev`, Xorg/Openbox/Tk/xterm and the `profile_virt` package set, but the manifest does not prove which package owns each pre-marker command or how `/etc/init.d/local` behaves.
  implication: Exact APK payload inspection is available offline and is the strongest differentiating test between a code-command failure and an OpenRC configuration failure.

- timestamp: 2026-08-28T01:40:00+07:00
  checked: Exact BusyBox 1.37.0-r31 and OpenRC 0.63.2-r0 APK payloads extracted from immutable corrected ISO
  found: The exact BusyBox binary contains the adduser shadow template `!:%u:0:99999:7:::` and fatal message `password for %s is already %slocked`. Exact `/etc/init.d/local` sets `redirect='> /dev/null 2>&1'` when non-verbose, records child errors internally, calls `eend`, and intentionally `return 0`. Authored `300k.start` has `set -eu`, uses `adduser -D`, then unconditionally executes `passwd -l chatgpt` before the only ROOTFS marker at line 38.
  implication: The account is already locked on creation; redundant relock is a deterministic nonzero exit that OpenRC hides, fully explaining hostname-correct login with no error text or marker.

- timestamp: 2026-08-28T01:40:00+07:00
  checked: Spectrum-based fault localization eligibility
  found: Before the new regression there is no failing unit test and no per-test coverage spectrum for the shell startup path.
  implication: SBFL is skipped as coverage-gated; direct payload differential and working-backwards evidence localize the fault exactly.

- timestamp: 2026-08-28T01:48:00+07:00
  checked: Agent-authored focused regression before production change
  found: `tests/deadline/run.ps1 -Scope RuntimeStatic` produced eight passes and exactly one failure: `BusyBox live-user locking is idempotent before ROOTFS readiness` rejected the missing leading-`!` shadow guard. All unrelated RuntimeStatic tests remained green.
  implication: The RED test minimally reproduces the faulty source contract with a derived oracle and is ready to drive the one-site production fix.

- timestamp: 2026-08-28T01:55:00+07:00
  checked: Focused regression after minimal production fix
  found: A leading-`!` `/etc/shadow` guard now skips redundant relock for both `!` and `!!` while retaining one fallback `passwd -l` for an unlocked entry. RuntimeStatic is GREEN with nine passes and zero failures.
  implication: The target regression now accepts the root-cause behavior; downstream tty1/session contracts must be checked before broad suites and mutation/revert guardrails.

- timestamp: 2026-08-28T02:08:00+07:00
  checked: Immediately downstream tty1/autologin/login-profile/session contract against exact candidate packages and authored overlay
  found: Exact BusyBox applet mapping provides `/sbin/getty`, `/bin/login`, `/usr/bin/awk`, `/usr/bin/passwd`, `/usr/sbin/adduser`, and `/usr/bin/install`. Exact Alpine baselayout `/etc/profile` sources every readable `/etc/profile.d/*.sh`. Authored inittab waits for OpenRC default then uses `getty -n -l /usr/local/bin/300k-autologin 38400 tty1`; the generator creates a same-directory relative symlink to `300k-runtime`; basename dispatch with zero args executes `/bin/login -f chatgpt`; the profile limits session exec to tty1 with no DISPLAY and a re-entry sentinel; runtime bounds startx to two attempts then execs an ash login rescue shell.
  implication: No second offline blocker is present in the immediate tty1 chain, but existing assertions are too loose to prevent argv/symlink/dispatch drift before the next expensive build.

- timestamp: 2026-08-28T02:16:00+07:00
  checked: Hardened downstream RuntimeStatic assertions
  found: Exact default-runlevel ordering, getty argv, autologin symlink/dispatcher, forced login, profile exec, re-entry guard, and bounded rescue assertions all pass; RuntimeStatic remains 9/9.
  implication: The immediate tty1 path has an offline recurrence contract and no authored blocker; proceed to broad static/unit neighbors.

- timestamp: 2026-08-28T02:24:00+07:00
  checked: Broad offline adjacent suites after fix and downstream contract hardening
  found: Deadline AllStatic passed 15/15 and Phase 1 Unit passed 27/27; no QEMU, build, artifact, candidate, pointer, or evidence mutation occurred.
  implication: Target and adjacent suites are green. A manual fix-site causal mutant is the applicable mutation signal because this repository has no Stryker configuration for shell/PowerShell.

- timestamp: 2026-08-28T02:31:00+07:00
  checked: Causal mutant and revert/reapply guardrail
  found: Replacing only the new conditional guard with the original unconditional `passwd -l` made exactly the focused test fail (RuntimeStatic 8/9). Reapplying the guard restored RuntimeStatic 9/9. No test assertion was weakened during either run.
  implication: The regression kills the exact root-cause mutant and the production change is causally necessary and sufficient for the offline contract.

- timestamp: 2026-08-28T02:40:00+07:00
  checked: Final diff, artifact immutability, and guardrail completeness
  found: Production diff is one conditional guard replacing one unconditional relock; test diff adds the focused oracle and exact immediate-downstream assertions. LATEST remains `34cb52ca77d0a6e679aa10a65aa34ff7131eb5cedb0796660d049ffbc1f297a7`; corrected candidate ISO remains `c7d40c23fd78d7d07f899ea89e680292cf662b7c5acc752fbe0b719402b71bae`. No candidate/evidence/pointer file changed. Owned ignored extraction scratch cleanup was denied by host command policy after exact path validation, so `.gsd/debug-rootfs-contract` remains ignored and must not be staged.
  implication: All applicable offline acceptance signals pass; only a future rebuilt-guest end-to-end verification can close and archive the session under the no-build/no-QEMU constraint.

- timestamp: 2026-08-28T02:44:00+07:00
  checked: Atomic code commit
  found: Commit `cc612a4` contains only `300k.start` and `tests/deadline/run.ps1` with 20 insertions and 2 deletions. The active debug record remains outside the code commit and unarchived.
  implication: The fix is ready for the next authorized build/guest proof without mixing planning state or immutable artifacts into the commit.

- timestamp: 2026-08-28T00:45:00+07:00
  checked: Corrective candidate offline overlay inspection and sole direct BIOS smoke
  found: Canonical overlay paths, hostname, eudev runlevels, and directory modes pass offline validation; runtime serial shows `300k login:` but no marker for 900 seconds.
  implication: Apkovl discovery/path protection is resolved. The new failure boundary begins at OpenRC local service execution or inside the earliest pre-marker portion of `300k.start`.

## Eliminated

- hypothesis: Alpine does not discover or unpack the corrected candidate's apkovl.
  evidence: The guest prompt uses overlay-provided hostname `300k`, and direct extraction confirms the corrected archive and lifecycle contents.
  timestamp: 2026-08-28T00:45:00+07:00

- hypothesis: The host serial reader missed all guest output.
  evidence: The share-safe reader retained and hashed ISOLINUX, Alpine/kernel, and hostname-correct login output through the full 900-second attempt without a harness error.
  timestamp: 2026-08-28T00:45:00+07:00

## Resolution

- root_cause: `300k.start` unconditionally relocks the BusyBox `adduser -D` account even though its shadow entry is already locked; pinned BusyBox returns nonzero for the redundant relock and `set -e` aborts before `ROOTFS_READY`. OpenRC `local` redirects the diagnostic and returns success, masking the child failure.
- fix: Guard the single `passwd -l chatgpt` fallback with an `awk -F:` check that treats any shadow field beginning with `!` as already locked, preserving account locking without triggering BusyBox's redundant-lock failure.
- verification:
    target_test: { result: pass, suite: "Deadline RuntimeStatic 9/9" }
    mutation_check: { result: pass, method: "manual exact fix-site mutant because Stryker is not configured for shell/PowerShell", mutant_killed: true, mutant_result: "RuntimeStatic 8/9" }
    no_op_deletion: { result: pass, deletion_justified_by_rca: false, note: "fix retains locking and adds an idempotent state guard; no behavior is deleted or short-circuited" }
    adjacent_tests: { result: pass, suites_run: ["Deadline AllStatic 15/15", "Phase 1 Unit 27/27", "downstream tty1 RuntimeStatic contract 9/9"] }
    revert_and_reconfirm: { result: pass, bug_returned_on_revert: true, fixed_on_reapply: true }
    artifact_immutability: { result: pass, latest_sha256: "34cb52ca77d0a6e679aa10a65aa34ff7131eb5cedb0796660d049ffbc1f297a7", candidate_iso_sha256: "c7d40c23fd78d7d07f899ea89e680292cf662b7c5acc752fbe0b719402b71bae" }
    guardrail_verdict: accepted
    end_to_end_guest: { result: pending, reason: "rebuild and QEMU explicitly forbidden in this offline-fix task" }
    commit: "cc612a4"
- oracle_type: derived (exact pinned BusyBox/OpenRC runtime contract)
- tdd_status: green
- files_changed:
    - builder/apkovl/rootfs/etc/local.d/300k.start
    - tests/deadline/run.ps1

## Prevention

- why_not_caught: RuntimeStatic asserted the presence of `passwd -l` as a security proxy but did not model BusyBox `adduser -D`'s already-locked shadow state or the relock command's nonzero idempotence; OpenRC intentionally hid the child failure.
- recurrence_guard: `tests/deadline/run.ps1` test `BusyBox live-user locking is idempotent before ROOTFS readiness`, plus exact downstream tty1/getty/autologin/profile assertions; the exact unconditional-relock mutant is killed.
