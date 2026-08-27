# 300K Linux deadline MVP

300K Linux is an unofficial, offline parody. It is not an OpenAI product and it does not use an OpenAI account, API, model, Codex, credential, cloud service, or telemetry. The graphical conversation is a local Tcl script; the Terminal button and `Ctrl+Alt+T` open a real local BusyBox `ash` shell.

## Build one quarantined candidate

Run from a clean committed repository:

```powershell
pwsh -NoProfile -File build.ps1 -Backend Qemu -Target DeadlineMvp -StateRoot "$env:LOCALAPPDATA\300k-linux" -QemuRoot 'D:\VM\qemu'
```

The command builds once through the existing signed, offline Alpine repository path and writes only `dist/.deadline-candidates/<build-id>`. It does not change `dist/LATEST.json`. The result reports the exact `deadline-candidate.json` path.

## Execute the single BIOS optical smoke

Use a fresh evidence directory for that candidate. This is intentionally one attempt; ordinary guest, marker, screenshot, PTY, timeout, and QEMU failures cannot be retried by this runner.

```powershell
pwsh -NoProfile -File scripts/host/Invoke-DeadlineSmoke.ps1 `
  -CandidateManifest 'dist\.deadline-candidates\<build-id>\deadline-candidate.json' `
  -EvidenceDirectory 'dist\.deadline-evidence\<build-id>' `
  -QemuRoot 'D:\VM\qemu' `
  -TimeoutSeconds 900 `
  -Promote
```

The executed lane is direct x86_64 QEMU, legacy BIOS `pc`, read-only optical `-cdrom`, 1 GiB RAM, standard VGA, `-display none`, and literal `-nic none`. It attaches no writable guest disk. Promotion happens only after the serial log contains one ordered `ROOTFS_READY`, `X_READY`, `UI_READY`, and `TERM_EXEC_OK`; the terminal fact must prove non-root user `chatgpt`, a `/dev/pts/<n>` PTY, command and file round trips, and a real exit code of 1. QMP captures exactly one nonblank P6 screenshot.

One explicit successor is available only when the immutable first attempt is the exact Windows live-serial `ReadAllText` sharing failure, ended before every `300K_STAGE`, PTY marker, screenshot, and completed smoke record, still matches the candidate hash and byte count, and owns zero matching QEMU processes. Keep the first evidence directory unchanged and use a different fresh directory:

```powershell
pwsh -NoProfile -File scripts/host/Invoke-DeadlineSmoke.ps1 `
  -CandidateManifest 'dist\.deadline-candidates\<build-id>\deadline-candidate.json' `
  -EvidenceDirectory 'dist\.deadline-evidence\<build-id>-host-observation-recovery' `
  -QemuRoot 'D:\VM\qemu' `
  -TimeoutSeconds 900 `
  -RecoverHostObservationFailure `
  -Promote
```

The successor record links the predecessor attempt SHA-256 and is created with `CreateNew`; a second recovery is rejected. This exception does not weaken the general one-attempt rule.

## What this proves

- One clean source commit produced one hash-qualified Alpine ISO candidate.
- One BIOS optical boot reached the mapped original 300K UI without a virtual NIC.
- The automatic xterm probe ran a real local shell as `chatgpt`, not root.
- The promoted pointer, ISO, serial, screenshot, and smoke evidence agree on exact hashes and byte counts.

The visible button and keyboard shortcut wiring are covered by the fast static suite. The smoke does not claim automated clicking or typing.

## Explicitly deferred

| Claim | Status |
| --- | --- |
| UEFI runtime boot | Not executed; only UEFI structure is inspected |
| raw USB or physical media | Not executed |
| Docker parity | Not executed |
| second build / byte-for-byte reproducibility | Not executed |
| 100 MB target and size optimization | Measured after the build; no target claim before that |
| exhaustive security recursive audit | Deferred from Phase 01-02 |
| broad hardware support | Not executed |
| general release certification | Not claimed |

This is a deadline BIOS optical MVP, not a daily-driver distribution or a general release certification.
