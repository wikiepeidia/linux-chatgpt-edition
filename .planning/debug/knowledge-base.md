# GSD Debug Knowledge Base

Resolved debug sessions. Used by `gsd-debugger` to surface known-pattern hypotheses at the start of new investigations.

---

## builder-io-apic-panic — Alpine builder panicked before SSH readiness under QEMU TCG
- **Date:** 2026-08-27
- **Error patterns:** `IO-APIC + timer doesn't work`, `setup_IO_APIC`, `QEMU_SERIAL_TIMEOUT`, pre-readiness panic, missing `noapic`
- **Root cause(s):** QEMU 11.1.0 TCG on this Windows host fails Alpine 6.18.35 early IRQ0 delivery through the IO-APIC; the pinned image's Extlinux command line lacked `noapic` and the backend had no direct kernel override, so both environment and configuration conditions caused a deterministic pre-readiness panic.
- **Fix:** Read only the verified qcow2's kernel, initramfs, and Extlinux config through installed 7-Zip into owned run scratch; fail closed on layout/APPEND drift; direct-boot QEMU with the exact image APPEND plus one `noapic`.
- **Files changed:** `scripts/host/Invoke-QemuBackend.ps1`, `tests/deadline/run.ps1`
- **Why not caught:** No pre-existing static or readiness gate covered preservation of the pinned Extlinux command line while adding a host-specific kernel workaround; later build, signing, inspection, and smoke gates run after the point of failure.
- **Recurrence guard:** Regression test `tests/deadline/run.ps1` — `Builder direct boot preserves the pinned image contract and adds noapic once`; runtime extraction also fails closed on missing or duplicate APPEND lines.
---

## smoke-serial-file-lock — Windows live serial reader consumed the only smoke attempt
- **Date:** 2026-08-27
- **Error patterns:** `ReadAllText`, `serial.log`, `being used by another process`, pre-observation host failure, consumed smoke attempt
- **Root cause(s):** `Get-DeadlineSerialFacts` used read-only sharing while QEMU retained a live write handle; Windows required the reader to share that existing write access, and the intentional one-attempt policy made the harness failure final.
- **Fix:** Use a bounded strict UTF-8 `FileStream` snapshot with `FileShare.ReadWrite | FileShare.Delete`; permit one `CreateNew` hash-linked successor only for the exact closed pre-observation host failure with zero owned QEMU processes.
- **Files changed:** `build.ps1`, `scripts/host/Invoke-DeadlineSmoke.ps1`, `tests/deadline/run.ps1`, `docs/DEADLINE-MVP.md`
- **Why not caught:** No existing host fixture held `serial.log` open for writing while `Get-DeadlineSerialFacts` read it; `SmokeUnit` covered only complete closed files.
- **Recurrence guard:** Regression test `tests/deadline/run.ps1` — `Direct smoke contract is one-attempt BIOS optical and evidence driven` — covers live sharing, partial UTF-8, byte bounds, closed recovery rejection, predecessor immutability, and second-recovery refusal.
---

## apkovl-not-applied — Valid overlay was erased during diskless package installation
- **Date:** 2026-08-28
- **Error patterns:** `(none) login:`, `DEADLINE_SMOKE_TIMEOUT`, zero `300K_*` markers, dot-prefixed apkovl members, incomplete runlevels
- **Root cause(s):** The custom generator archived `.` so initramfs fed dot-prefixed names to apk's package-relative overlay protection; the overlay also omitted both a coherent boot-service strategy and `etc/hostname`, while implicit 0700 ancestors would block the non-root UI.
- **Fix:** Archive exact roots `etc home usr`, write the validated hostname, create traversable 0755 ancestors, and install the complete pinned explicit eudev runlevels without `.default_boot_services`, `mdev`, or `hwdrivers`.
- **Files changed:** `builder/apkovl/genapkovl-300k.sh`, `tests/deadline/run.ps1`
- **Why not caught:** Existing gates checked only apkovl presence and deterministic source, not tar member namespace, initramfs lifecycle completeness, device-manager exclusivity, hostname, or ancestor modes.
- **Recurrence guard:** Regression test `tests/deadline/run.ps1` — `Apkovl member paths and lifecycle survive diskless package install`; focused dot-operand mutant killed, RuntimeStatic 8/8, Deadline AllStatic 14/14, and Phase 1 Unit 27/27.
---

## rootfs-ready-not-emitted — Redundant BusyBox account relock aborted local startup
- **Date:** 2026-08-28
- **Error patterns:** hostname-correct `300k login:`, zero `ROOTFS_READY`, silent OpenRC local failure, `passwd -l`, already locked shadow entry
- **Root cause(s):** BusyBox `adduser -D` created `chatgpt` with an already locked shadow password; the unconditional `passwd -l chatgpt` returned nonzero under `set -e`, aborting `300k.start` before its marker. OpenRC `local` redirected the child diagnostic and returned success, masking the abort.
- **Fix:** Guard the one fallback relock with a BusyBox-awk shadow check that treats fields beginning with `!` (including `!` and `!!`) as already locked.
- **Files changed:** `builder/apkovl/rootfs/etc/local.d/300k.start`, `tests/deadline/run.ps1`
- **Why not caught:** RuntimeStatic treated the presence of `passwd -l` as a security proxy without modeling BusyBox's already-locked `adduser -D` state or redundant relock exit status; OpenRC suppressed the runtime diagnostic.
- **Recurrence guard:** `BusyBox live-user locking is idempotent before ROOTFS readiness`; RED 8/9, GREEN 9/9, exact unconditional-relock mutant killed, Deadline AllStatic 15/15, Phase 1 Unit 27/27, then rebuilt guest emitted exactly one `ROOTFS_READY` marker.
---
