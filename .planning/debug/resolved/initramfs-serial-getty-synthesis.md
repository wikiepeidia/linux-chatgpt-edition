---
status: resolved
trigger: "Alpine initramfs synthesizes a ttyS0 getty after the overlay, undoing the serial marker permission fix"
created: 2026-08-28
updated: 2026-08-28T11:27:00+07:00
---

# Debug Session: Initramfs Serial Getty Synthesis

## Symptoms

- expected: The authored inittab has no serial getty, startup preserves `/dev/ttyS0` as root:dialout 0660, and uid-1000 X/UI/TERM stages can write the same serial evidence channel after ROOTFS.
- actual: Candidate `deadline-46bc6f6aedc0` contains no authored ttyS0 getty and passes the permission contract offline, yet the guest still prints `300k login:` on serial and records only root-emitted ROOTFS_READY. Exact Alpine initramfs code recreates a ttyS0 getty after overlay/APK installation.
- artifact: `300k-deadline-x86_64-3a199cc92c9a.iso`, SHA-256 `3a199cc92c9af75145f46aab2a2ef34de484e2f35bb6d9aca0e399e650039093`, exactly 183,500,800 bytes (175 MiB), source `a56538c`.
- smoke_evidence: Sole attempt `0225487f2db64fe2ad8d9ac16fd167cd` timed out after exactly ROOTFS_READY and `300k login:`; attempt SHA-256 `62364afae072dfb9677bb3782a5ae5e33b8d4694f3d54efe0866b4be3efe4bbb`, failure prefix `d0a9495`, argv prefix `80a7f240`, serial prefix `4af7ab07`. No retry, recovery, promotion, screenshot, or PTY.
- integrity: Prior 93-file aggregate remains `1ba0b53c3a0fb0e2e64be01e4f5c7ed882915b38ce089f81b89244f16e3fc2e6`; LATEST/LKG and all earlier artifacts remain exact; QEMU/runners zero; tree clean at `a56538c` before this record.

## Current Focus

- hypothesis: Candidate initramfs `/init` runs `setup_inittab_console` after APK/overlay installation. QEMU pc ACPI SPCR plus the exact kernel serial-console configuration identifies ttyS0 as active even without `console=`. Because the overlay inittab lacks any `^ttyS0:` ID, init appends `ttyS0::respawn:/sbin/getty -L 0 ttyS0 vt100`; that later getty retakes root:root 0620 and deterministically mutes non-root stage writes.
- known_pattern_candidate: `serial-stage-permissions` established that a ttyS0 getty revokes uid-1000 marker access, but its source-only removal did not cover initramfs post-overlay synthesis.
- confirming_evidence:
    - Exact `/init` lines 145-157 append a getty for active console IDs absent from inittab; lines 1130-1131 invoke it after APK/overlay installation and before switch-root.
    - QEMU 11.1 pc enables ACPI SPCR by default; exact kernel enables ACPI SPCR and 8250 console support.
    - Live serial explicitly identifies `/dev/ttyS0` and prints `300k login:` despite no authored serial getty.
    - Timing matches: root startup sets 0660/emits ROOTFS during default; synthesized respawn starts afterward and changes ownership/mode.
- test: Simulate the exact initramfs append rule against the authored inittab and require the resulting inittab to contain no ttyS0 getty while retaining kernel serial diagnostics, tty2 rescue, and direct non-root stage writes. Removing the reservation or replacing it with a getty must fail.
- expecting: RED because no `^ttyS0:` reservation exists; GREEN after adding one valid dormant `ttyS0::ctrlaltdel:/bin/true` entry that suppresses synthesis while never entering the normal-boot action mask. Retain the existing empty-ID Ctrl-Alt-Del reboot and root:dialout 0660 setup.
- next_action: Archived resolution; rebuild the ISO from code commit `8446a2cdcad1e1c633e802efa264e3570c0a3ce9` before the next single permitted guest smoke.
- bug_class: bohrbug
- tdd_checkpoint:
    test_file: tests/deadline/run.ps1
    test_name: Alpine initramfs console synthesis is suppressed by a dormant ttyS0 reservation
    status: green
    failure_output: RED was `RESULT scope=RuntimeStatic passed=10 failed=1`; fixed source is GREEN at 11/11.
- reasoning_checkpoint:
    hypothesis: Alpine initramfs appends a ttyS0 getty because its post-overlay `^ttyS0:` predicate finds no authored ID; the synthesized getty then revokes the direct non-root marker channel.
    confirming_evidence:
        - Exact retained `/init` SHA-256 and lines 151-157 show the missing-ID append rule; lines 1130-1131 run it after overlay/package installation.
        - Focused regression is RED only because the authored inittab has zero ttyS0 ID reservations; the prior guest log contains the otherwise impossible synthesized `300k login:` prompt.
        - Exact patched BusyBox source proves `ctrlaltdel` is valid and excluded from SYSINIT/WAIT/ONCE/RESPAWN/ASKFIRST normal-boot actions, while `once` would open ttyS0 during boot.
    falsification_test: The hypothesis is false if an exact `^ttyS0:` dormant reservation still causes the modeled initramfs rule to append a getty, or if BusyBox normal boot selects the ctrlaltdel action and opens ttyS0.
    fix_rationale: One valid non-boot ttyS0 inittab entry satisfies Alpine's exact suppression predicate without starting a process, opening the tty during normal boot, changing permissions, removing serial diagnostics, or replacing tty2 rescue/Ctrl-Alt-Del reboot behavior.
    blind_spots: No rebuilt guest is permitted in this session, so the post-fix proof is exact-source static/unit behavior plus causal mutation rather than a new QEMU observation.
    candidate_causes:
        - config: authored inittab omitted every ttyS0 ID after deleting the getty.
        - environment: QEMU/kernel expose ttyS0 as an active console, intentionally retaining serial diagnostics and activating Alpine's synthesis path.
        - code: Alpine initramfs applies the alternative-console mutation after the overlay.
    and_gate: yes — active ttyS0 and the missing inittab ID must coexist; the environment condition is intentional, so the minimal correction is the missing config reservation.
- constraints:
    - preserve_all_artifacts_and_evidence: true
    - retain_kernel_serial_diagnostics: true
    - retain_tty2_rescue: true
    - no_serial_getty: true
    - qemu_before_green: forbidden

## Evidence

- timestamp: 2026-08-28T11:21:00+07:00
  checked: Required gates, minimal diff, immutable artifacts, and owned process state
  found: RuntimeStatic 11/11, Deadline AllStatic 17/17, and Phase 1 Unit 27/27 all pass. Diff is exactly one production inittab line plus 32 focused test lines. `LATEST.json` remains `34cb52ca...`/260 bytes, candidate ISO remains `3a199cc9...`/183500800 bytes, LKG ISO remains `2c968ee3...`/69206016 bytes, and QEMU process count is zero.
  implication: The source fix is accepted for a rebuild; no existing artifact, evidence, publication pointer, or emulator state was mutated.

- timestamp: 2026-08-28T11:13:00+07:00
  checked: Three one-at-a-time causal inittab mutants against the driving RuntimeStatic suite
  found: Removing the reservation fails 10/11 on zero ttyS0 IDs; replacing it with the synthesized getty fails 9/11 on both competing getty and non-dormant action; replacing ctrlaltdel with once fails 10/11 because once is a normal-boot action. The exact fixed line was restored after every mutant.
  implication: The regression kills the absence, symptom-reintroduction, and tempting boot-time-once mutants; it asserts the causal reservation/action contract rather than merely suppressing the observed prompt.

- timestamp: 2026-08-28T11:08:00+07:00
  checked: Focused RuntimeStatic regression after the one-line inittab reservation
  found: GREEN at 11/11; synthesis suppression, duplicate independent ctrlaltdel actions, dormant normal-boot mask, no serial getty, tty2 rescue, and direct non-root marker assertions all pass.
  implication: The minimal fix satisfies the driving oracle; causal mutants must now prove that the reservation value and action are essential.

- timestamp: 2026-08-28T11:04:00+07:00
  checked: Focused agent-authored RuntimeStatic regression before production change
  found: Genuine RED at 10/11; the sole failure is `Exactly one ttyS0 inittab ID ... Expected=<1> Actual=<0>` while all adjacent RuntimeStatic contracts pass.
  implication: The test reproduces the exact missing-reservation cause without QEMU or artifact mutation and is ready to drive the one-line fix.

- timestamp: 2026-08-28T10:57:00+07:00
  checked: Exact retained candidate initramfs `/init`
  found: Extracted `/init` SHA-256 `ED39CC3FE4DB146315F1F877C94FAD9FA99A057ED590CF1857ED9FB32912F57A`; lines 151-157 suppress synthesis only when `grep -q "^$tty:"` matches, otherwise append `$tty::respawn:/sbin/getty -L 0 $tty vt100`. Lines 1130-1131 invoke this after overlay/package installation.
  implication: A single line beginning exactly `ttyS0:` is the minimal causal contract; getty deletion alone cannot survive the post-overlay mutation.

- timestamp: 2026-08-28T10:57:00+07:00
  checked: Exact pinned BusyBox 1.37.0-r31 init semantics
  found: Reconstructed source from Alpine's official v3.24 BusyBox 1.37.0 distfile whose SHA-512 exactly matches pinned aports commit `52643b7a...`, then applied its sole init patch. `once` is accepted but normal boot calls `run_actions(ONCE)`; `run()` performs `setsid()` and `open_stdio_to_tty()`, which opens the parsed `/dev/ttyS0` with `O_RDWR` before exec. Therefore `ttyS0::once:/bin/true` violates the explicit no-open condition. `ctrlaltdel` is parsed as a distinct valid action and is absent from normal boot's SYSINIT/WAIT/ONCE/RESPAWN/ASKFIRST masks.
  implication: Reserve the ID with `ttyS0::ctrlaltdel:/bin/true`; it is dormant during normal boot, while the existing empty-ID `::ctrlaltdel:/sbin/reboot` remains independently parsed and functional.

- timestamp: 2026-08-28T10:45:00+07:00
  checked: Phase-0 semantic recall and code-graph availability
  found: MemPalace is unavailable; the durable knowledge base matches `serial-stage-permissions`, whose recurrence guard covered authored getty removal but not Alpine initramfs synthesis. GitNexus has no index for this repository, so graph tracing cannot be used without an out-of-scope index mutation.
  implication: Test the known-pattern extension first using direct source tracing; do not treat the prior KB entry as a confirmed diagnosis by itself.

- timestamp: 2026-08-28T03:15:00+07:00
  checked: Exact candidate initramfs console setup, QEMU SPCR/kernel console inputs, final serial output, and inittab
  found: The initramfs deterministically synthesizes the missing ttyS0 respawn after the overlay, explaining why the prior source-only getty removal did not survive into the running rootfs.
  implication: The marker channel fix requires an inert inittab ID reservation, not merely deletion of the authored getty.

## Eliminated

- hypothesis: tty1 output is merely mirrored onto the QEMU serial file.
  evidence: QEMU uses distinct VGA and serial backends, and the serial prompt is produced by initramfs-synthesized ttyS0 getty; tty1 uses forced autologin and cannot produce the prompt.
  timestamp: 2026-08-28T03:15:00+07:00

## Resolution

- root_cause: The intentional active ttyS0 environment and Alpine's post-overlay console synthesis combine with a missing `^ttyS0:` authored inittab ID; initramfs therefore appends a getty that retakes the non-root evidence channel.
- fix: Added exactly `ttyS0::ctrlaltdel:/bin/true` before the unchanged empty-ID Ctrl-Alt-Del reboot entry; no startup permission, marker, tty2, kernel/QEMU, artifact, evidence, LATEST, or LKG behavior changed.
- verification:
    target_test: { result: pass, suite: RuntimeStatic, passed: 11, failed: 0 }
    mutation_check: { result: pass, reason: three exact manual causal mutants were required because no Stryker configuration applies to PowerShell/static inittab text, mutant_killed: true, mutants: [reservation removed, reservation replaced by getty, dormant action replaced by once] }
    no_op_deletion: { result: pass, deletion_justified_by_rca: false, detail: additive one-line production fix with no behavior deletion }
    adjacent_tests: { result: pass, suites_run: [Deadline AllStatic 17/17, Phase 1 Unit 27/27] }
    revert_and_reconfirm: { result: pass, bug_returned_on_revert: true, fixed_on_reapply: true, detail: removal mutant failed 10/11 and restored source passed 11/11 }
    guardrail_verdict: accepted
- oracle_type: specified — exact Alpine append predicate plus required no-getty/no-normal-boot-open, tty2 rescue, Ctrl-Alt-Del reboot, direct marker, and root:dialout 0660 contracts.
- files_changed:
    - builder/apkovl/rootfs/etc/inittab
    - tests/deadline/run.ps1
- code_commit: 8446a2cdcad1e1c633e802efa264e3570c0a3ce9

## Prevention

- blameless_5_whys:
    - config_branch: The earlier correction deleted the authored getty but left no ttyS0 ID because the source contract treated absence as sufficient; Alpine's later missing-ID rule therefore reconstructed the forbidden process. The focused static gate had no model of that mutation, so the locally green overlay diverged from final inittab behavior.
    - environment_code_branch: QEMU/kernel intentionally keep ttyS0 active for diagnostics; Alpine initramfs intentionally discovers active consoles and edits inittab after applying the overlay. Those individually correct behaviors combined with the missing reservation, and the prior verification stopped before this post-overlay boundary.
    - and_gate: The failure requires both an active serial console and a missing authored ID; serial diagnostics remain required, so prevention makes the config state explicit and tests the integration boundary.
- why_not_caught: The prior RuntimeStatic contract proved only that the authored overlay lacked a serial getty; it did not simulate Alpine initramfs's post-overlay missing-ID synthesis or reject boot-time ttyS0 actions.
- recurrence_guard: `tests/deadline/run.ps1` — `Alpine initramfs console synthesis is suppressed by a dormant ttyS0 reservation`; it models the exact append predicate, duplicate ctrlaltdel parsing, normal-boot action masks, no getty, tty2 rescue, and direct non-root markers, and kills removal/getty/once mutants.
