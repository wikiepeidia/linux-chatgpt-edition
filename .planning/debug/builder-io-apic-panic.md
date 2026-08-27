---
status: awaiting_human_verify
trigger: "Deadline MVP builder VM panics before SSH_READY under both q35/TCG and pc/i440fx/TCG"
created: 2026-08-27
updated: 2026-08-27T22:26:00+07:00
---

# Debug Session: Builder IO-APIC Panic

## Symptoms

- expected: The pinned Alpine builder image boots under the owned QEMU backend, emits the ordered 300K no-cloud and SSH readiness markers, accepts strict SSH, and proceeds to the signed DeadlineMvp ISO build.
- actual: Alpine Linux 6.18.35 panics before any 300K marker or SSH readiness with `IO-APIC + timer doesn't work`; the kernel suggests trying `noapic`.
- errors: The q35/TCG product run ends as `QEMU_SERIAL_TIMEOUT` after 600 seconds. The isolated pc/i440fx/TCG readiness probe ends before readiness with the same panic and a 300-second bound.
- timeline: The first key-initialization VM under q35/TCG succeeded once. Subsequent product build under q35/TCG and isolated readiness probe under pc/i440fx/TCG both failed before SSH_READY on 2026-08-27.
- reproduction: From clean commit 5559ef2, invoke the bounded BuilderReadinessProbe or the QEMU DeadlineMvp build using the pinned cached builder image. Do not run package transfer/build during diagnosis unless a readiness-only transport proof passes first.
- environment: Windows host; QEMU 11.1.0 at D:\\VM\\qemu; deterministic TCG; Docker CLI 29.6.0 installed but no engine, service, pipe, or Desktop installation; no WSL/native Linux build chain.
- preserved evidence: q35 failure record SHA-256 53e7d3e4a36bf7617d0e87e438294d41a2a687a564e16b5c13bb1e52a228ca92 and serial SHA-256 53d2f76f8feb558138985a14dcfc58d259af3e8f54d9cd367848057ea679296d. pc probe record SHA-256 ba58e94721c4dfeaa7de2da9847ce6eb146605dcee5cc292feaecd7c26dd6b15 and serial SHA-256 808cfecaf6b4b106217e6b2a5bdcf38eef82fd415d464a7944cfa3a74214fea9.
- integrity: Repository source is clean at 5559ef2. LATEST SHA-256 remains 34cb52ca77d0a6e679aa10a65aa34ff7131eb5cedb0796660d049ffbc1f297a7 and prior ISO remains 69,206,016 bytes with SHA-256 2c968ee3a0c687bd0d779247b7b595494a6a9870308387a07572796fd46d0678.

## Current Focus

- hypothesis: The confirmed QEMU TCG IO-APIC timer failure is bypassed by verified direct-kernel boot with the pinned image command line plus one `noapic`; automated readiness and cleanup now pass.
- test: Human confirms the original DeadlineMvp workflow should proceed from the now-proven builder transport, or reports any remaining environment-specific failure.
- expecting: Confirmation that the readiness blocker is resolved; package build and ISO smoke remain deliberately unstarted.
- next_action: Await human response `confirmed fixed` or a description of what still fails.
- bug_class: bohrbug
- reasoning_checkpoint:
    hypothesis: QEMU 11.1.0 TCG on this host fails Alpine 6.18.35 early IRQ0 delivery through the IO-APIC, and the builder's Extlinux-only boot path provides no `noapic` override, causing a deterministic pre-readiness panic.
    confirming_evidence:
      - Two preserved runs on q35 and pc have verified hashes, identical Alpine kernel/command line, and the same failed IRQ0 fallbacks ending in `setup_IO_APIC` panic before any project marker.
      - The verified qcow2 Extlinux APPEND line exactly matches the failed kernel command line and lacks `noapic`; QEMU and the kernel explicitly support direct kernel arguments and the recommended workaround.
      - Both qcow2 images pass `qemu-img check`, and operation-specific project logic begins only after readiness.
    falsification_test: A single bounded direct-kernel readiness probe using the verified image arguments plus `noapic` still emits the same IO-APIC panic or fails before ordered serial trust and strict SSH.
    fix_rationale: Extract only the verified base's kernel, initramfs, and Extlinux config into owned run scratch, validate the closed boot contract, then pass the original APPEND line plus only `noapic` through QEMU direct boot; this bypasses the failing IO-APIC path without mutating the base, changing packages, or exposing signing material.
    blind_spots: The readiness probe does not prove the later package build; direct boot still depends on the already-installed 7-Zip QCOW/ext reader and must fail closed if its output or image layout changes.
    candidate_causes:
      - environment: QEMU 11.1.0 TCG timer/IO-APIC delivery on this Windows host
      - config: pinned Extlinux APPEND lacks `noapic` and backend has no kernel-command-line override
      - data: base/cache corruption was considered and refuted by `qemu-img check` plus pinned base hash validation
    and_gate: yes - the panic requires the environment's broken IO-APIC timer path and a boot configuration that enters that path without the `noapic` bypass.
- tdd_checkpoint:
    test_file: tests/deadline/run.ps1
    test_name: Builder direct boot preserves the pinned image contract and adds noapic once
    status: green
    failure_output: RED was `Direct-kernel transport contract is absent - function Get-QemuDirectBootSpec`; GREEN is 4 passed, 0 failed.

## Evidence

- timestamp: 2026-08-27T22:10:37+07:00
  checked: Phase 0 semantic/knowledge-base recall
  found: No MemPalace tool is available and `.planning/debug/knowledge-base.md` does not exist; the only prior project memory records successful QEMU bootstrap operation and a storage safety block, not this IO-APIC panic.
  implication: No known-pattern root cause can be reused; successful historical QEMU boot makes a universally broken QEMU install less likely but remains only a hypothesis input.

- timestamp: 2026-08-27T22:10:37+07:00
  checked: Project and configured debugger skills
  found: Neither `.codex/skills` nor `.agents/skills` exists and `.planning/config.json` has an empty `agent_skills` map.
  implication: No additional project skill rules govern this fix.

- timestamp: 2026-08-27T22:12:00+07:00
  checked: Complete `scripts/host/Invoke-QemuBackend.ps1` boot path and commits 502b024/5559ef2
  found: Operation mode branches only after serial and strict-SSH readiness. All operations create a fresh overlay over the same hash-verified base, attach the same persistent cache disk, and construct the same boot argv at a given commit. Commit 502b024 selected q35/TCG; 5559ef2 changed only the machine to pc and added a readiness-only post-SSH branch.
  implication: `init-signing-key` versus `build` cannot itself explain a panic occurring before readiness. q35 alone is eliminated as a sufficient cause because pc reproduced the same panic; retained external inputs or non-deterministic QEMU/guest timing remain candidates.

- timestamp: 2026-08-27T22:14:00+07:00
  checked: Preserved q35 and pc failure records plus raw serial logs
  found: All four supplied SHA-256 values match the preserved files. Both commands use QEMU 11.1.0, `tcg,thread=multi`, 4 vCPUs, the same verified Alpine base and persistent cache; only machine and ephemeral paths/ports differ. Both kernels report identical boot arguments without `noapic`, fail every IRQ0 delivery fallback, and panic at `setup_IO_APIC` before any 300K marker.
  implication: The failure is entirely before cloud-init, SSH, source transfer, signing, package build, and project runtime. The relevant input boundary is QEMU CPU/timer/APIC emulation plus the image boot command line.

- timestamp: 2026-08-27T22:16:00+07:00
  checked: Commit/run chronology, qcow2 integrity, builder boot contents, and installed alternate runtimes
  found: The successful image/cache activity began under the prior WHPX-first/TCG-fallback argv, but the host has no active hypervisor, so the actual accelerator is not retained and success does not establish a stable alternate. Both qcow2 images pass `qemu-img check`. No WSL distribution, Docker engine, PATH QEMU, Podman, or second QEMU installation is available. Installed 7-Zip 21.04 can read the pinned qcow2 directly and exposes `boot/vmlinuz-virt` (12,575,744 bytes), `boot/initramfs-virt` (10,847,826 bytes), and `boot/extlinux.conf`; its APPEND line exactly matches the failed kernel command line and lacks `noapic`.
  implication: A direct-kernel QEMU launch can preserve the verified base and boot arguments while adding only the kernel-prescribed workaround; no installation or base-image mutation is required.

- timestamp: 2026-08-27T22:16:05+07:00
  checked: SBFL, common-pattern scan, and bug classification
  found: SBFL is skipped because the runtime panic has no failing automated test with per-test coverage. Environment/Config is the matching common pattern. With current TCG inputs the failure reproduced on both q35 and pc, so it is classified as a deterministic Bohrbug and routed to differential debugging plus a test-first counterfactual.
  implication: The fix must alter only the boot command-line seam and preserve machine, accelerator, image, cache, and readiness behavior for causal attribution.

- timestamp: 2026-08-27T22:19:00+07:00
  checked: Agent-authored direct-kernel/noapic regression before implementation
  found: `tests/deadline/run.ps1 -Scope BuildStatic` reports 3 pass, 1 fail at the new regression because `Get-QemuDirectBootSpec` and the direct-kernel transport do not exist.
  implication: TDD RED is valid and specifically proves the current backend cannot apply the required verified `noapic` boot contract.

- timestamp: 2026-08-27T22:19:52+07:00
  checked: Target regression after direct-kernel implementation
  found: `tests/deadline/run.ps1 -Scope BuildStatic` reports 4 passed, 0 failed. The new test validates exact original APPEND plus one `noapic` and rejects zero or duplicate APPEND lines.
  implication: TDD GREEN is achieved; real-image extraction, adjacent tests, and causal revert/reapply remain before acceptance.

- timestamp: 2026-08-27T22:20:33+07:00
  checked: Real pinned-image extraction and adjacent deadline suites
  found: The extractor returned the exact observed kernel/initramfs sizes (12,575,744 and 10,847,826 bytes), stable SHA-256 values, the original APPEND plus exactly one `noapic`, then cleaned its owned temporary directory. `AllStatic` reports 13 passed, 0 failed.
  implication: Installed 7-Zip can execute the real fail-closed extraction path and no adjacent runtime, publication, or smoke-unit contract regressed.

- timestamp: 2026-08-27T22:21:15+07:00
  checked: Fix-acceptance guardrail
  found: Removing only the backend fix makes the retained target regression fail (3 pass, 1 fail); restoring it returns 4 pass, 0 fail. The diff is addition-only and `git diff --check` passes. Stryker/mutation tooling is absent, so mutation testing is explicitly skipped.
  implication: Target, no-op/deletion, adjacent, and revert/reconfirm signals accept the minimal fix; live readiness remains the original-issue verification signal.

- timestamp: 2026-08-27T22:21:48+07:00
  checked: Atomic code commit
  found: Commit d43a00e contains only `scripts/host/Invoke-QemuBackend.ps1` and `tests/deadline/run.ps1` with 115 added lines; no signing material, publication pointer, or prior ISO changed.
  implication: The readiness probe can causally evaluate one immutable code revision.

- timestamp: 2026-08-27T22:25:25+07:00
  checked: Single bounded public builder-readiness probe from clean commit d43a00e
  found: The probe returned `builder-readiness-passed` on machine `pc` and accelerator `tcg,thread=multi`, observed `300K_SSH_READY`, verified the serial Ed25519 host fingerprint, passed strict SSH, shut down, and reported `cleanup_complete=true`.
  implication: The exact original pre-readiness IO-APIC panic no longer occurs with direct-kernel `noapic`; readiness is proven without source, signing-key, package, candidate, or ISO-smoke activity.

- timestamp: 2026-08-27T22:26:00+07:00
  checked: Post-probe cleanup and immutable publication integrity
  found: Zero QEMU processes, zero run/host-run entries, and zero overlays remain. LATEST is still 260 bytes with SHA-256 `34cb52ca77d0a6e679aa10a65aa34ff7131eb5cedb0796660d049ffbc1f297a7`; the prior 69,206,016-byte ISO remains SHA-256 `2c968ee3a0c687bd0d779247b7b595494a6a9870308387a07572796fd46d0678`.
  implication: The readiness verification cleaned all owned resources and did not alter the published artifact or pointer.

## Eliminated

- hypothesis: The q35 machine type alone causes the Alpine IO-APIC timer panic.
  evidence: The bounded readiness probe at commit 5559ef2 changed only the QEMU machine to pc/i440fx for the boot lane and reproduced the same pre-readiness panic.
  timestamp: 2026-08-27T22:12:00+07:00

## Resolution

- root_cause: QEMU 11.1.0 TCG on this Windows host fails Alpine 6.18.35 early IRQ0 delivery through the IO-APIC; the pinned image's Extlinux command line lacks `noapic` and the backend has no direct kernel override, so the guest deterministically panics before readiness.
- fix: Read only the verified qcow2's kernel, initramfs, and Extlinux config through installed 7-Zip into owned run scratch; fail closed on layout/APPEND drift; direct-boot QEMU with the exact image APPEND plus one `noapic`.
- verification:
    target_test: { result: pass, suite: tests/deadline/run.ps1 -Scope BuildStatic, passed: 4, failed: 0 }
    mutation_check: { result: skipped, reason_if_skipped: no Stryker or mutation framework is configured for PowerShell, mutant_killed: null }
    no_op_deletion: { result: pass, deletion_justified_by_rca: false, note: addition-only fail-closed transport and regression }
    adjacent_tests: { result: pass, suites_run: [tests/deadline/run.ps1 -Scope AllStatic], passed: 13, failed: 0 }
    revert_and_reconfirm: { result: pass, bug_returned_on_revert: true, fixed_on_reapply: true }
    real_image_extraction: { result: pass, kernel_bytes: 12575744, initrd_bytes: 10847826, noapic_count: 1 }
    readiness_probe: { result: pass, status: builder-readiness-passed, machine: pc, accelerator: tcg-thread-multi, serial_marker: 300K_SSH_READY, ssh_probe: passed, cleanup_complete: true }
    publication_integrity: { result: pass, latest_sha256: 34cb52ca77d0a6e679aa10a65aa34ff7131eb5cedb0796660d049ffbc1f297a7, prior_iso_sha256: 2c968ee3a0c687bd0d779247b7b595494a6a9870308387a07572796fd46d0678, live_qemu_count: 0, overlay_count: 0 }
    guardrail_verdict: accepted
- files_changed:
  - scripts/host/Invoke-QemuBackend.ps1
  - tests/deadline/run.ps1
- oracle_type: derived - preserve the verified image's exact Extlinux APPEND contract, add only the kernel-prescribed `noapic`, and require ordered serial trust plus strict SSH.
