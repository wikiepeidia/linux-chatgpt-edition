---
phase: quick-260827-se6-deadline-mvp
plan: "01"
subsystem: live-iso
tags: [alpine, qemu, openbox, tcl-tk, xterm, bios, offline]
requires:
  - phase: 01-reproducible-build-foundation
    provides: pinned Alpine builder, immutable LKG, QEMU ownership, and artifact validation
provides:
  - deterministic offline parody desktop/runtime source
  - isolated DeadlineMvp build, candidate, and BIOS smoke contracts
  - five failed 175 MiB deadline ISO candidates retained in quarantine and one verified 175 MiB candidate atomically published
affects: [deadline-mvp, qemu-builder, bios-smoke, phase-01]
actuals:
  tokens: 57622
  tasks: 3
  commits: 12
tech-stack:
  added: [Openbox, Tcl/Tk, xterm, Alpine apkovl]
  patterns: [prompt-as-data, immutable-candidate promotion, owned QEMU lifecycle, verified direct-kernel builder boot]
key-files:
  created:
    - builder/apkovl/genapkovl-300k.sh
    - builder/apkovl/rootfs/usr/local/lib/300k/ui.tcl
    - builder/apkovl/rootfs/usr/local/lib/300k/content.tcl
    - builder/apkovl/rootfs/usr/local/bin/300k-runtime
    - scripts/linux/inspect-deadline-iso.sh
    - scripts/host/Invoke-DeadlineSmoke.ps1
    - tests/deadline/run.ps1
    - docs/DEADLINE-MVP.md
  modified:
    - build.ps1
    - scripts/host/Invoke-QemuBackend.ps1
    - scripts/linux/run-build.sh
    - builder/inputs.json
    - builder/profiles/mkimg.300k.sh
    - tests/phase1/run.ps1
key-decisions:
  - "Keep all OpenAI/API/account/cloud functionality out of the runtime; prompts remain local data only."
  - "Never replace LATEST until a direct BIOS smoke proves the exact candidate bytes."
  - "After each evidence-backed rootfs fix, permit exactly one new candidate build and one ordinary smoke; preserve every failed attempt and candidate and promote only after all four runtime stages and independent evidence verification."
patterns-established:
  - "Deadline candidate isolation: build output cannot enter the published namespace before exact smoke evidence."
  - "Builder transport: preserve the pinned Extlinux APPEND contract and add exactly one noapic for this verified TCG host path."
requirements-completed: []
coverage:
  - id: D1
    description: Offline graphical parody runtime and deterministic apkovl source
    verification:
      - kind: unit
        ref: tests/deadline/run.ps1 -Scope AllStatic
        status: pass
    human_judgment: false
  - id: D2
    description: Deadline-only build, closed candidate, direct BIOS smoke, and fail-closed promotion contracts
    verification:
      - kind: unit
        ref: tests/deadline/run.ps1 -Scope AllStatic
        status: pass
      - kind: unit
        ref: tests/phase1/run.ps1 -Scope Unit
        status: pass
      - kind: integration
        ref: five retained failed candidates plus published deadline-b39bb9f19a23 candidate validation
        status: pass
    human_judgment: false
  - id: D3
    description: BIOS optical boot reaching the mapped UI and real xterm PTY proof
    verification:
      - kind: integration
        ref: successful smoke fbcc2717a4524f9faa65593cbb63f5cb after six disclosed failed attempts
        status: pass
    human_judgment: true
    rationale: The published candidate emitted unique ordered ROOTFS/X/UI/TERM markers and proved the non-root chatgpt PTY command/file/exit contract with a nonblank screenshot.
duration: 7h 22m
completed: 2026-08-27
status: complete
---

# Quick 260827-se6: Deadline MVP Vertical Slice Summary

**A sixth 175 MiB corrective ISO booted through the original graphical parody UI, proved a real non-root `chatgpt` PTY, and was atomically published while the old LKG and all failed evidence remained exact.**

## Performance

- **Duration:** 7h 22m
- **Started:** 2026-08-27T13:48:50Z
- **Stopped:** 2026-08-27T21:10:55Z
- **Tasks complete:** 3 of 3
- **Product files changed:** 22
- **Product commits:** 12

## Accomplishments

- Added the deterministic Alpine apkovl, locked unprivileged `chatgpt` session, original full-screen Tcl/Tk parody UI, safe local comedy engine, fixed xterm launcher, and real PTY proof contract.
- Added a target-isolated `DeadlineMvp` build, fast structural inspector, quarantined candidate publisher, single-attempt direct BIOS smoke runner, and fail-closed promotion.
- Resolved the builder IO-APIC panic with a verified direct-kernel boot that preserves the pinned image APPEND line and adds exactly one `noapic`.
- Built and independently revalidated one closed ISO candidate without modifying the prior publication.
- Preserved the pre-observation harness failure byte-for-byte, fixed live serial reads under a dedicated debug workflow, and executed exactly one hash-linked recovery smoke.
- The recovery booted Alpine but produced no project readiness marker within 900 seconds; retained both attempts, performed no further retry, and left the old publication untouched.
- Diagnosed and fixed canonical apkovl member names, hostname, coherent explicit eudev runlevels, and traversable parent modes with a mutation-proven regression.
- Built a distinct corrective candidate from `9e46df0`, verified its overlay offline, and ran exactly one ordinary smoke. The guest identity changed from `(none)` to `300k`, proving overlay application, but the local runtime still did not emit its first readiness marker.
- Fixed BusyBox live-user locking to be idempotent, built one distinct candidate from `a084138`, and proved the exact next boundary: `ROOTFS_READY` now emits, but X/UI/TERM do not.
- Corrected the tty1 getty sentinel dispatch, built one distinct candidate from clean `bf59c78`, proved the exact overlay contract offline, and retained its sole 900-second ROOTFS-only smoke without retry or promotion.
- Removed the authored ttyS0 getty and added fail-closed dialout ownership, built one distinct candidate from clean `a56538c`, then proved Alpine initramfs recreates the serial getty from the active SPCR console after the overlay is applied.
- Reserved ttyS0 with one dormant inittab entry, built one distinct candidate from clean `20fd371`, proved the initramfs append rule stayed suppressed, then passed ROOTFS/X/UI/TERM, screenshot, PTY, and atomic promotion gates.

## Product Commits

1. `079c6e2cba710978c22365edf6f307873da7dbfd` — `feat(deadline): add offline desktop runtime`
2. `77d69a1a3d55d6299600e231b06becda4c7a8507` — `feat(deadline): add BIOS candidate proof path`
3. `91ec08e8cc8b220fcec2d7977b4d1328733e8cd4` — `fix(deadline): validate signing preflight`
4. `502b024dca5f151b8e74f533c7071194d89374e0` — `fix(qemu): force reliable TCG builder`
5. `5559ef2103e04181344ad59990be86d92b616bc0` — `fix(qemu): probe stable pc builder`
6. `d43a00e8dbed0d10fd8566c5addb882861e28699` — `fix(qemu): direct-boot builder with noapic`
7. `b609302085e5cfe5789fda3963500d6da0b07366` — `fix(deadline): read live serial safely`
8. `6ecda6b799f04e11b96946753eef4bd7e73b805c` — `fix(deadline): preserve apkovl lifecycle`
9. `cc612a4d668cb288254ad6a29afc2a43fc7d4425` — `fix(runtime): make live-user lock idempotent`
10. `cbaf47eb44c658c6d90d9b21478760895f9579ce` — `fix(runtime): consume getty argv sentinel`
11. `ab43575d82367360c03fa36f1856fe39380c4840` — `fix(runtime): preserve serial stage access`
12. `8446a2cdcad1e1c633e802efa264e3570c0a3ce9` — `fix(runtime): reserve active serial console`

The initial candidate source identity is `021de7a00872b9b1f46506c78cc0a8fe62d6cfc1`; later sections record each distinct corrective source identity through final clean source `20fd3711cb5c7fd77bf46e828b13e053fc1ea6a2`.

## Pre-Build Verification

| Gate | Result | Facts |
| --- | --- | --- |
| Product tree | PASS | Clean at `021de7a`; quick planning files are locally excluded |
| Deadline static suite | PASS | `AllStatic`: 13 passed, 0 failed, including direct-kernel/noapic contract |
| Phase 1 regression suite | PASS | `Unit`: 27 passed, 0 failed |
| Deadline preflight | PASS | QEMU available and external signing identity validated |
| Signing public SHA-256 | PASS | `f928c93614a6413160f89a17b65c189c90e29756033951ddf041623896854f4c` |
| Disk floors before build | PASS | C: 174.46 GiB; D: 76.02 GiB |
| Owned runtime state | PASS | Zero QEMU/build processes, runs, overlays, candidates, attempts, or evidence |
| Prior publication | PASS | LATEST and old ISO matched their expected hashes and bytes |

## Builder Execution

- Host command: `pwsh -NoProfile -File build.ps1 -Backend Qemu -Target DeadlineMvp -StateRoot "$env:LOCALAPPDATA\300k-linux" -QemuRoot 'D:\VM\qemu'`
- Invocation count after the resolved readiness probe: exactly one.
- Run ID: `810a545ced7a4208a21d618093b52734`.
- Builder QEMU PID: `12456` (owned and cleaned).
- Machine/accelerator: `pc` / `tcg,thread=multi`.
- Direct boot: verified pinned kernel/initramfs, original APPEND plus exactly one `noapic`.
- Ordered builder serial trust:
  - line 371: `300K_NOCLOUD_BEGIN`
  - line 372: Ed25519 host key, fingerprint `SHA256:GsvgQbiuPW4GUJsbR2waXtBWYqw+4D7p4040xliHnHY`
  - line 373: ephemeral management key fingerprint `SHA256:RuFCzBb5A2ROPcxegdnKZwTvvm0QFsTTj8ch6R11M3A`
  - line 374: `300K_SSH_READY`
- Strict SSH then completed `prepare-repository`, `build-from-local`, export, shutdown, and cleanup.
- Build result: `candidate-staged`.

Exact builder QEMU argv:

`"D:\VM\qemu\qemu-system-x86_64.exe" -machine pc -accel tcg,thread=multi -m 4096 -smp 4 -kernel C:\Users\wikiepeidia\AppData\Local\300k-linux\state\runs\810a545ced7a4208a21d618093b52734\direct-boot\boot\vmlinuz-virt -initrd C:\Users\wikiepeidia\AppData\Local\300k-linux\state\runs\810a545ced7a4208a21d618093b52734\direct-boot\boot\initramfs-virt -append "root=LABEL=/ modules=sd-mod,usb-storage,ext4,ena,gve,mana console=ttyS0,115200n8 console=ttyAMA0,115200n8 console=tty0 noapic" -drive if=none,id=os,format=qcow2,file=C:\Users\wikiepeidia\AppData\Local\300k-linux\state\runs\810a545ced7a4208a21d618093b52734\overlay.qcow2 -device virtio-blk-pci,drive=os,bootindex=1,serial=300k-builder -drive if=none,id=cache,format=qcow2,file=C:\Users\wikiepeidia\AppData\Local\300k-linux\state\qemu\cache\300k-cache-d26306b03cee.qcow2 -device virtio-blk-pci,drive=cache,serial=300k-cache -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:52210-:22 -smbios type=1,serial=ds=nocloud;s=http://10.0.2.2:52212/ -display none -serial tcp:127.0.0.1:52213 -monitor none -no-reboot`

## Candidate Evidence

| Fact | Value |
| --- | --- |
| Build ID | `deadline-7d9935426bbb` |
| Candidate directory | `D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-candidates\deadline-7d9935426bbb` |
| Manifest | `deadline-candidate.json` |
| Manifest SHA-256 | `3417dbbab54310ace3b1cfee6087a51f4b8a7028c89964216154e8e02d209cd1` |
| ISO file | `300k-deadline-x86_64-ecd8ad7698d6.iso` |
| ISO SHA-256 | `ecd8ad7698d6b201d048c8f0175964a5a0124758d6e37e547af53cd9bd929982` |
| ISO bytes | `183,500,800` |
| ISO MiB | `175.000` |
| 100 MB stretch target | Missed; measured candidate is 175 MiB |
| Source commit | `021de7a00872b9b1f46506c78cc0a8fe62d6cfc1` |
| Fast inspection | `deadline-fast-structural`, result `pass` |
| BIOS structure | Boot catalog `/boot/syslinux/boot.cat`; loader `/boot/syslinux/isolinux.bin`; bootable `true` |
| Required content | kernel, initramfs, apkovl, local APK index, BIOS loader, EFI loader present |
| UEFI | Structural records only; runtime not executed |

`Test-DeadlineCandidateDirectory` independently rehashed every closed manifest record and confirmed no extra directories, links, or files.

## BIOS Smoke Attempts

### Predecessor: pre-observation harness failure

- Attempt ID: `60b575ba15894b9e9dc4207787e9b5c3`.
- Attempt record: `dist/.deadline-attempts/deadline-7d9935426bbb.json`.
- Attempt SHA-256: `c789e80e4d85a92b035a429fb1c527189f431d349ff9cd89df127e7e7f6f1806`.
- Status/code: `failed` / `DEADLINE_SMOKE_FAILED`.
- Started: `2026-08-27T15:55:36.6847703Z`; completed: `2026-08-27T15:55:37.4255076Z`.
- Evidence directory: `dist/.deadline-evidence/deadline-7d9935426bbb`.
- Failure: the host runner called exclusive `ReadAllText` on `serial.log` while QEMU still held the file, causing an immediate sharing violation.
- This is a pre-observation harness failure, not a negative UI/runtime boot result.
- QEMU cleanup completed; the attempt was not deleted, modified, or retried.

Retained evidence:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `attempt.json` | 536 | `c789e80e4d85a92b035a429fb1c527189f431d349ff9cd89df127e7e7f6f1806` |
| `failure.json` | 507 | `a703a688dd23a49fa655f25e854e1bfbc8c28e11342d2417afa06b47da740a29` |
| `qemu-argv.json` | 648 | `5261e8834567de3b382fdc17c76ede11b22430cfa2268af18a58fad869f086dc` |
| `serial.log` | 79 | `43a8361cb2d724742b7659740ce6867e5133f12b8558fefee4d07f039f725751` |
| `qemu.stdout.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `qemu.stderr.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

The 79-byte serial log proves BIOS optical execution reached:

`ISOLINUX 6.04 6.04-pre1 ... boot:`

No `ROOTFS_READY`, `X_READY`, `UI_READY`, or `TERM_EXEC_OK` marker was observed before the harness aborted. No screenshot or PTY facts exist.

Exact smoke QEMU argv:

`D:\VM\qemu\qemu-system-x86_64.exe -machine pc -accel tcg -m 1024 -boot order=d,strict=on -cdrom D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-candidates\deadline-7d9935426bbb\300k-deadline-x86_64-ecd8ad7698d6.iso -vga std -display none -serial file:D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-evidence\deadline-7d9935426bbb\serial.log -qmp tcp:127.0.0.1:62379,server=on,wait=off -monitor none -nic none -no-reboot`

### Authorized hash-linked recovery

- Attempt ID: `4007e73ec7ce482ab47c99388e576f1d`.
- Attempt record: `dist/.deadline-attempts/deadline-7d9935426bbb.recovery.json`.
- Attempt SHA-256: `abc6524b98b26163e4de77914db5a6142cd15f2813d7776ff62136935c7acdb1`.
- Predecessor link: `deadline-7d9935426bbb.json`, SHA-256 `c789e80e4d85a92b035a429fb1c527189f431d349ff9cd89df127e7e7f6f1806`.
- Status/code: `failed` / `DEADLINE_SMOKE_TIMEOUT`.
- Started: `2026-08-27T16:22:02.2918804Z`; completed: `2026-08-27T16:37:02.8032616Z`.
- Evidence directory: `dist/.deadline-evidence/deadline-7d9935426bbb-recovery`.
- The share-safe reader remained operational for the full 900-second bound. QEMU booted the exact candidate through ISOLINUX into Alpine Linux 3.24, kernel `6.18.44-0-virt`, and stopped at `(none) login:`.
- No `ROOTFS_READY`, `X_READY`, `UI_READY`, or `TERM_EXEC_OK` marker appeared. No screenshot or PTY facts were created, so promotion remained closed.
- QEMU and the runner were fully cleaned after timeout. This was the one explicitly authorized recovery; no additional smoke was launched.

Retained recovery evidence:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `attempt.json` | 746 | `abc6524b98b26163e4de77914db5a6142cd15f2813d7776ff62136935c7acdb1` |
| `failure.json` | 329 | `4ebf2993789c923ac899cc524f23807c7b119a6f0fb8c75507ef379e14bc7c16` |
| `qemu-argv.json` | 657 | `f668acd8ef143cdb4f5572aed839cfaf129acddddf5f96d65e799bd5fa476491` |
| `serial.log` | 179 | `c10d35bcc62cfe69dcd8c1b7d2a692cddee7347ff222f0420874fd3d2ee6db8d` |
| `qemu.stdout.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `qemu.stderr.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

Exact recovery QEMU argv:

`D:\VM\qemu\qemu-system-x86_64.exe -machine pc -accel tcg -m 1024 -boot order=d,strict=on -cdrom D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-candidates\deadline-7d9935426bbb\300k-deadline-x86_64-ecd8ad7698d6.iso -vga std -display none -serial file:D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-evidence\deadline-7d9935426bbb-recovery\serial.log -qmp tcp:127.0.0.1:50096,server=on,wait=off -monitor none -nic none -no-reboot`

## Corrective Build and Offline Overlay Proof

- Clean source HEAD: `9e46df093b796f7558245ff6fc3d2b9441528ae6`.
- Corrective production fix: `6ecda6b799f04e11b96946753eef4bd7e73b805c`.
- Pre-build gates: RuntimeStatic 8/8, AllStatic 14/14, Phase 1 Unit 27/27.
- QEMU deadline/signing preflight: pass; public signing SHA-256 `f928c93614a6413160f89a17b65c189c90e29756033951ddf041623896854f4c`.
- Exactly one corrective `DeadlineMvp` build was invoked. Builder run `302c4b994e2a4e6e8c83d97ecfaa3c3e` used `pc`/TCG direct kernel boot, reached ordered `300K_NOCLOUD_BEGIN` and `300K_SSH_READY`, staged the candidate, shut down, and cleaned QEMU.
- This is a corrective second candidate build after a source fix. It is not a second identical-source build and therefore is not reproducibility proof.

| Fact | Value |
| --- | --- |
| Build ID | `deadline-45af9bbdc0f5` |
| Candidate directory | `dist/.deadline-candidates/deadline-45af9bbdc0f5` |
| Manifest SHA-256 | `f3586bed6fb268d219d3ef138d64041ca6567d8f520816691f48607c05062bd2` |
| ISO file | `300k-deadline-x86_64-c7d40c23fd78.iso` |
| ISO SHA-256 | `c7d40c23fd78d7d07f899ea89e680292cf662b7c5acc752fbe0b719402b71bae` |
| ISO bytes / MiB | `183,500,800` / `175.000` |
| 100 MB stretch target | **Missed**; measured candidate is 175 MiB |
| Source commit | `9e46df093b796f7558245ff6fc3d2b9441528ae6` |
| Inspection SHA-256 | `bb792ed2e2f6e468075311fd09a8758e0262bd1d19ce448452d2ce17be1350aa` |
| Fast inspection | `deadline-fast-structural`, pass |

Before guest boot, the exact ISO overlay was independently extracted and validated:

- `/300k.apkovl.tar.gz`: 7,361 bytes, SHA-256 `d846cc8494488bfe0743b6775ecfb46752974df3c48a39d30bfd2863f08dd34d`.
- 49 tar members; every member is package-relative, with no `./`, absolute, `..`, or backslash path.
- `etc/hostname` is exactly `300k`.
- All 16 expected explicit eudev runlevel links point to the matching `/etc/init.d/<service>` target; no `.default_boot_services`, `mdev`, or `hwdrivers` conflict exists.
- All 20 required parent directories are mode 0755 and traversable.
- `LATEST`, the old LKG, the first candidate, and both earlier attempt/evidence sets matched their protected hashes after this check.

## Corrective Ordinary Smoke Attempt

- Attempt ID: `3d92a1ec8a0946d98fdb2fbcb1aa1ff9`.
- Attempt record: `dist/.deadline-attempts/deadline-45af9bbdc0f5.json`.
- Attempt SHA-256: `64b18ab4b485eecc172886cc1f59f8c74abd732077a4e9e8bd2a2c0e0200f946`.
- Status/code: `failed` / `DEADLINE_SMOKE_TIMEOUT`.
- Started: `2026-08-27T17:27:30.9167164Z`; completed: `2026-08-27T17:42:31.7232921Z`.
- Evidence directory: `dist/.deadline-evidence/deadline-45af9bbdc0f5`.
- This was exactly one ordinary smoke of the new candidate. No recovery switch, relaunch, or retry was used.
- BIOS optical boot reached Alpine 3.24, kernel `6.18.44-0-virt`, and the hostname-correct `300k login:` prompt. This is stronger than the first candidate's `(none) login:` and confirms the corrected overlay identity applied.
- No `ROOTFS_READY`, `X_READY`, `UI_READY`, or `TERM_EXEC_OK` marker appeared in 900 seconds. There was no OpenRC/X error text, screenshot, or PTY fact, and promotion remained closed.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `attempt.json` | 537 | `64b18ab4b485eecc172886cc1f59f8c74abd732077a4e9e8bd2a2c0e0200f946` |
| `failure.json` | 329 | `117cd0c8908502b944c789a8a166d92a00ca407e8617905138be81e65be5bd80` |
| `qemu-argv.json` | 648 | `121cb629634ac2fa84971ecf9f574ba9d328114629f2c0cf7bcd4885f443622e` |
| `serial.log` | 177 | `ccd73df66cb0e02bf9e5dc73fac5ed11e09bc73092eb21125b8a7d02fa7529ce` |
| `qemu.stdout.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `qemu.stderr.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

Exact corrective smoke QEMU argv:

`D:\VM\qemu\qemu-system-x86_64.exe -machine pc -accel tcg -m 1024 -boot order=d,strict=on -cdrom D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-candidates\deadline-45af9bbdc0f5\300k-deadline-x86_64-c7d40c23fd78.iso -vga std -display none -serial file:D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-evidence\deadline-45af9bbdc0f5\serial.log -qmp tcp:127.0.0.1:64811,server=on,wait=off -monitor none -nic none -no-reboot`

## Rootfs-Contract Corrective Build

- Clean source HEAD: `a0841381de415678695cb1f3bbea55b397652fbe`.
- Product fix: `cc612a4d668cb288254ad6a29afc2a43fc7d4425`.
- Pre-build gates: RuntimeStatic 9/9, AllStatic 15/15, Phase 1 Unit 27/27; signing/QEMU preflight passed.
- Exactly one build was invoked through builder run `df91c03d2c75427cb541f34a72e30315`; it reached ordered SSH trust, staged the candidate, shut down, and cleaned QEMU.
- This is another corrective source build, not a same-source reproducibility run.

| Fact | Value |
| --- | --- |
| Build ID | `deadline-bade6e8baa9d` |
| Candidate directory | `dist/.deadline-candidates/deadline-bade6e8baa9d` |
| Manifest SHA-256 | `93083204bde6f4552106e57c0c08dc927bbfa0cad397b10e453c9d96bc7ca739` |
| Inspection SHA-256 | `fe0ba88f50bcac22268000d2a40174afd0bbe9e4a420b636a42ac933632d4f8c` |
| ISO file | `300k-deadline-x86_64-22e05e4d383c.iso` |
| ISO SHA-256 | `22e05e4d383c1e2e4d68543178a2ba27c14c46ab15f085f5d479af3a6e67f50d` |
| ISO bytes / MiB | `183,500,800` / `175.000` |
| 100 MB stretch target | **Missed**; measured candidate is 175 MiB |
| Source commit | `a0841381de415678695cb1f3bbea55b397652fbe` |

Pre-smoke exact-overlay proof:

- `/300k.apkovl.tar.gz`: 7,408 bytes, SHA-256 `7b9e8bc809a7dfde0f71ec18490a5202a76f7dec3a029e047744c223f15553ed`.
- 49 canonical package-relative members, hostname `300k`, 16 coherent eudev links, and 20 required mode-0755 parents.
- Generated `etc/local.d/300k.start` contains an idempotent leading-`!` `/etc/shadow` guard, exactly one conditional `passwd -l chatgpt` fallback, and the guard precedes the `ROOTFS_READY` call.
- The protected 51-file aggregate for `LATEST`, LKG, both prior candidates, and all three prior attempt/evidence sets remained `8fac828bc950b2a83add314bf2251e0a56f8814a253cfe88b492c52f4e5a3e50` before smoke.

## Rootfs-Contract Ordinary Smoke

- Attempt ID: `feb8490977c24c398cabb5162f07cc66`.
- Attempt record: `dist/.deadline-attempts/deadline-bade6e8baa9d.json`.
- Attempt SHA-256: `edd4b7c96cb1cbc81de0d9aa1c401dd55b50cb65f947c7841894ac23f0817042`.
- Status/code: `failed` / `DEADLINE_SMOKE_TIMEOUT`.
- Started: `2026-08-27T18:23:26.2250446Z`; completed: `2026-08-27T18:38:26.6805157Z`.
- Exactly one ordinary `pc`/TCG BIOS optical smoke ran with literal `-nic none`, 900 seconds, promotion enabled, and no recovery switch.
- Ordered observed stages: exactly one `ROOTFS_READY`; `X_READY`, `UI_READY`, and `TERM_EXEC_OK` were absent.
- Serial then reached hostname-correct `300k login:`. There was no screenshot, PTY proof, promotion, recovery, or retry.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `attempt.json` | 537 | `edd4b7c96cb1cbc81de0d9aa1c401dd55b50cb65f947c7841894ac23f0817042` |
| `failure.json` | 329 | `92449a623782f3380d0c0fc794e64dfe2a6d457338f98434b01bde1c60c1f492` |
| `qemu-argv.json` | 648 | `04772d4f3ff37da4c69ec41929e43a5ad644366d47f1f3521c143421829bec69` |
| `serial.log` | 204 | `4af7ab07c679f5ce6aa0ef902c9fff9da8d414d3849fb684968a618035dfae6c` |
| `qemu.stdout.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `qemu.stderr.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

Exact QEMU argv:

`D:\VM\qemu\qemu-system-x86_64.exe -machine pc -accel tcg -m 1024 -boot order=d,strict=on -cdrom D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-candidates\deadline-bade6e8baa9d\300k-deadline-x86_64-22e05e4d383c.iso -vga std -display none -serial file:D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-evidence\deadline-bade6e8baa9d\serial.log -qmp tcp:127.0.0.1:57950,server=on,wait=off -monitor none -nic none -no-reboot`

## Tty1-Sentinel Corrective Build

- Clean source HEAD: `bf59c7811b31e0d2956d2b4e3c5ee808e284f9dc`.
- Product fix: `cbaf47eb44c658c6d90d9b21478760895f9579ce`.
- Pre-build gates: RuntimeStatic 9/9, AllStatic 15/15, Phase 1 Unit 27/27; signing/QEMU preflight passed.
- Public signing SHA-256: `f928c93614a6413160f89a17b65c189c90e29756033951ddf041623896854f4c`.
- Exactly one build was invoked through builder run `386d738074174fe5a531689dd65875a8`; it reached ordered SSH readiness, staged a new candidate, shut down, and cleaned QEMU.
- This is a corrective source build, not a same-source reproducibility run.

| Fact | Value |
| --- | --- |
| Build ID | `deadline-0d2637f5f224` |
| Candidate directory | `dist/.deadline-candidates/deadline-0d2637f5f224` |
| Manifest SHA-256 | `58a622d0ccbdfe5da61cb2e8667d29672f3744d61bd01730e7fcaa25e6e8cd43` |
| Inspection SHA-256 | `1febb4a5eaa79c05c0dacbddd092706ecea0e53527a305f59659d28ab669484c` |
| ISO file | `300k-deadline-x86_64-689db084d9ad.iso` |
| ISO SHA-256 | `689db084d9ad188c192e0a681c53fc7c3c289d0a1e14f33efa3de1948a779ac7` |
| ISO bytes / MiB | `183,500,800` / `175.000` |
| 100 MB stretch target | **Missed**; measured candidate is 175 MiB |
| Source commit | `bf59c7811b31e0d2956d2b4e3c5ee808e284f9dc` |

Pre-smoke exact-overlay proof:

- `/300k.apkovl.tar.gz`: 7,418 bytes, SHA-256 `96a84aa5f85ec36978a40ba290581a3bb02aaf48b69a5dcc2bade938ccfe8265`.
- 49 canonical package-relative members, hostname `300k`, 16 coherent eudev links, and 20 required mode-0755 parents.
- Generated `300k.start` retains the idempotent leading-`!` shadow guard and one conditional `passwd -l chatgpt` fallback.
- `300k-autologin` resolves to `300k-runtime`; dispatch accepts exactly one literal `--`, shifts it, retains the zero-argument action guard, and executes fixed `/bin/login -f chatgpt`.
- The protected 72-file aggregate covering `LATEST`, the LKG, every earlier candidate, and every earlier attempt/evidence set remained the pre-recorded SHA-256 `6d66e159ea4cb0b0ab2b10a58448bd4442546b4a64435ec45c5258da8a9d1520` before smoke.

## Tty1-Sentinel Ordinary Smoke

- Attempt ID: `702509c6691f492b86e8a6209992cf47`.
- Attempt record: `dist/.deadline-attempts/deadline-0d2637f5f224.json`.
- Attempt SHA-256: `92f8afeef819307c9897d0e673c8fe38e82c9f020b8b38ded3c86687b7c008ad`.
- Status/code: `failed` / `DEADLINE_SMOKE_TIMEOUT`.
- Started: `2026-08-27T19:18:04.5223675Z`; completed: `2026-08-27T19:33:04.8845486Z`.
- Exactly one ordinary `pc`/TCG BIOS optical smoke ran with literal `-nic none`, 900 seconds, promotion enabled, and no recovery switch.
- Ordered observed stages: exactly one `ROOTFS_READY`; `X_READY`, `UI_READY`, and `TERM_EXEC_OK` were absent.
- Serial reached hostname-correct `300k login:`. There was no OpenRC/X error text, screenshot, PTY proof, promotion, recovery, or retry.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `attempt.json` | 537 | `92f8afeef819307c9897d0e673c8fe38e82c9f020b8b38ded3c86687b7c008ad` |
| `failure.json` | 329 | `32e8c4f659a6f38d647531f653d46c3c0c7f4b7bf85b3fe6a0ced2078e95dd32` |
| `qemu-argv.json` | 648 | `0d12f3043bb0ec9da006d72e20f204f25b98becf07601b3e8b0bb075f7bb0df2` |
| `serial.log` | 204 | `4af7ab07c679f5ce6aa0ef902c9fff9da8d414d3849fb684968a618035dfae6c` |
| `qemu.stdout.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `qemu.stderr.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

Exact QEMU argv:

`D:\VM\qemu\qemu-system-x86_64.exe -machine pc -accel tcg -m 1024 -boot order=d,strict=on -cdrom D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-candidates\deadline-0d2637f5f224\300k-deadline-x86_64-689db084d9ad.iso -vga std -display none -serial file:D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-evidence\deadline-0d2637f5f224\serial.log -qmp tcp:127.0.0.1:59519,server=on,wait=off -monitor none -nic none -no-reboot`

## Serial-Permission Corrective Build

- Clean source HEAD: `a56538cc53587606e3ee261a587ef6ee30e4e9c0`.
- Product fix: `ab43575d82367360c03fa36f1856fe39380c4840`.
- Pre-build gates: RuntimeStatic 10/10, AllStatic 16/16, Phase 1 Unit 27/27; signing/QEMU preflight passed.
- Public signing SHA-256: `f928c93614a6413160f89a17b65c189c90e29756033951ddf041623896854f4c`.
- Exactly one build was invoked through builder run `5bdfa447e3d446c5b7bfec4fb0a4ff9a`; it reached ordered SSH readiness, staged a new candidate, shut down, and cleaned QEMU.
- This is a corrective source build, not a same-source reproducibility run.

| Fact | Value |
| --- | --- |
| Build ID | `deadline-46bc6f6aedc0` |
| Candidate directory | `dist/.deadline-candidates/deadline-46bc6f6aedc0` |
| Manifest SHA-256 | `8dc52435ec16b9c10d6c0c5c311455883f9d58bbe74570e86733979cb2b93e53` |
| Inspection SHA-256 | `53de2e6540d9830270ba160f72f42438aaac67b7694e797941059e6c2ee3e98f` |
| ISO file | `300k-deadline-x86_64-3a199cc92c9a.iso` |
| ISO SHA-256 | `3a199cc92c9af75145f46aab2a2ef34de484e2f35bb6d9aca0e399e650039093` |
| ISO bytes / MiB | `183,500,800` / `175.000` |
| 100 MB stretch target | **Missed**; measured candidate is 175 MiB |
| Source commit | `a56538cc53587606e3ee261a587ef6ee30e4e9c0` |

Pre-smoke exact-overlay proof:

- `/300k.apkovl.tar.gz`: 7,473 bytes, SHA-256 `9a06f490923b6378b2b51d08cc518a6771cc69dd3c2c7ac3b2971e3ac484515f`.
- 49 canonical package-relative members, hostname `300k`, 16 coherent eudev links, and all required parent directories mode 0755.
- Authored `inittab` contains no ttyS0 getty and retains the exact tty2 rescue getty.
- `300k.start` adds `chatgpt` to dialout, fail-closes when a character ttyS0 exists without membership, then applies exactly one `root:dialout` ownership and mode 0660 before `ROOTFS_READY`.
- The idempotent shadow lock, exact getty `--` autologin dispatcher, zero-argument action guard, and `/bin/login -f chatgpt` all remain exact.
- The protected 93-file aggregate for `LATEST`, the LKG, every earlier candidate, and every earlier attempt/evidence set remained `1ba0b53c3a0fb0e2e64be01e4f5c7ed882915b38ce089f81b89244f16e3fc2e6` before and after the attempt.

## Serial-Permission Ordinary Smoke

- Attempt ID: `0225487f2db64fe2ad8d9ac16fd167cd`.
- Attempt record: `dist/.deadline-attempts/deadline-46bc6f6aedc0.json`.
- Attempt SHA-256: `62364afae072dfb9677bb3782a5ae5e33b8d4694f3d54efe0866b4be3efe4bbb`.
- Status/code: `failed` / `DEADLINE_SMOKE_TIMEOUT`.
- Started: `2026-08-27T20:10:02.3786662Z`; completed: `2026-08-27T20:25:03.0390022Z`.
- Exactly one ordinary `pc`/TCG BIOS optical smoke ran with literal `-nic none`, 900 seconds, promotion enabled, and no recovery switch.
- Ordered observed stages: exactly one `ROOTFS_READY`; `X_READY`, `UI_READY`, and `TERM_EXEC_OK` were absent.
- Serial reached hostname-correct `300k login:`. There was no screenshot, PTY proof, promotion, recovery, or retry.
- Offline tracing proved the exact post-overlay mutation: Alpine initramfs `/init` runs `setup_inittab_console` after APK installation, and QEMU ACPI SPCR identifies ttyS0 as the active console, so a ttyS0 getty is appended despite its absence from the authored overlay. That getty retakes ttyS0 as root-owned mode 0620 after `ROOTFS_READY`, closing the non-root marker channel.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `attempt.json` | 537 | `62364afae072dfb9677bb3782a5ae5e33b8d4694f3d54efe0866b4be3efe4bbb` |
| `failure.json` | 329 | `d0a9495b1fff63dcc6ae1e680b4aba31c8e5b05e5c3230dc50b7edddbe7ae503` |
| `qemu-argv.json` | 648 | `80a7f240948add5ccc28f267629473ae541b9ca846a45585d4c7c61af6920dca` |
| `serial.log` | 204 | `4af7ab07c679f5ce6aa0ef902c9fff9da8d414d3849fb684968a618035dfae6c` |
| `qemu.stdout.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `qemu.stderr.log` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

Exact QEMU argv:

`D:\VM\qemu\qemu-system-x86_64.exe -machine pc -accel tcg -m 1024 -boot order=d,strict=on -cdrom D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-candidates\deadline-46bc6f6aedc0\300k-deadline-x86_64-3a199cc92c9a.iso -vga std -display none -serial file:D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-evidence\deadline-46bc6f6aedc0\serial.log -qmp tcp:127.0.0.1:59897,server=on,wait=off -monitor none -nic none -no-reboot`

## Active-Console Sentinel Corrective Build

- Clean source HEAD: `20fd3711cb5c7fd77bf46e828b13e053fc1ea6a2`.
- Product fix: `8446a2cdcad1e1c633e802efa264e3570c0a3ce9`.
- Pre-build gates: RuntimeStatic 11/11, AllStatic 17/17, Phase 1 Unit 27/27; signing/QEMU preflight passed.
- Public signing SHA-256: `f928c93614a6413160f89a17b65c189c90e29756033951ddf041623896854f4c`.
- Exactly one build was invoked through builder run `21d8642409cb43c0b412d9a89b468812`; it reached ordered SSH readiness, staged a new candidate, shut down, and cleaned QEMU.
- This is a corrective source build, not a same-source reproducibility run.

| Fact | Value |
| --- | --- |
| Build ID | `deadline-b39bb9f19a23` |
| Published directory | `dist/deadline-b39bb9f19a23` |
| Manifest SHA-256 | `a83bafa19dcb992893aaa47df846850f2aa6421ac95f277ed28c02c23450da1c` |
| Inspection SHA-256 | `b52c6dcbf9f4bb24a04cbe81290a97c7f3bfc8dc090aacecafc0a91d0e68b5c5` |
| ISO file | `300k-deadline-x86_64-688e94bf1b69.iso` |
| ISO SHA-256 | `688e94bf1b69a3748921892d43382703adea69be37e54257da0c376fd014c521` |
| ISO bytes / MiB | `183,500,800` / `175.000` |
| 100 MB stretch target | **Missed**; measured ISO is 175 MiB |
| Source commit | `20fd3711cb5c7fd77bf46e828b13e053fc1ea6a2` |

Pre-smoke exact-overlay proof:

- `/300k.apkovl.tar.gz`: 7,485 bytes, SHA-256 `f4631ef1e1a198f68fd5f6331134b4473e2bee2c7b8b18e0f7d4393162e82d73`.
- 49 canonical package-relative members, hostname `300k`, 16 coherent eudev links, and all required parent directories mode 0755.
- Authored `inittab` contains exactly one dormant `ttyS0::ctrlaltdel:/bin/true` reservation, no ttyS0 getty or boot-time `once` action, and the exact tty2 rescue getty.
- Exact simulation of Alpine initramfs's `^ttyS0:` append rule left the reservation unchanged and synthesized no getty.
- Root:dialout mode 0660 precedes `ROOTFS_READY`; the idempotent shadow lock and exact getty `--` autologin dispatcher remain intact.
- The pre-smoke protected inventory contained 114 files with aggregate `d892cf352909859a6e80bb21bb298e41bda1142b9303053ae68ebe2b386406c5`.

## Successful BIOS Smoke and Promotion

- Attempt ID: `fbcc2717a4524f9faa65593cbb63f5cb`.
- Attempt record: `dist/.deadline-attempts/deadline-b39bb9f19a23.json`.
- Attempt SHA-256: `0375dcd472da08433ff3caefe8289d2ac65449404040b2e8130343581addca89`.
- Status: `smoke-passed`.
- Started: `2026-08-27T21:09:13.2684238Z`; completed: `2026-08-27T21:10:55.0564499Z`.
- Exactly one ordinary `pc`/TCG BIOS optical smoke ran with literal `-nic none`, promotion enabled, and no recovery switch.
- Ordered markers were independently parsed exactly once each: `ROOTFS_READY` line 5, `X_READY` line 7, `UI_READY` line 9, and `TERM_EXEC_OK` line 11.
- Terminal proof: uid `1000`, user `chatgpt`, tty `/dev/pts/0`, command `ok`, file `ok`, exit `1`.
- Evidence: `dist/.deadline-evidence/deadline-b39bb9f19a23/deadline-smoke-evidence.json`, 2,338 bytes, SHA-256 `35156fa8f451e4e6eded593d7b1c72f620133bb8cede798e0035618e6a2a18ef`.
- Serial: 243 bytes, SHA-256 `0d56b821bf69ae7e84f9a457a498a7bdc1fbec08485e796b9f42d1450034221e`.
- Screenshot: `dist/.deadline-evidence/deadline-b39bb9f19a23/screen.ppm`, 3,072,016 bytes, SHA-256 `0fe13818b9e5a8b46e2fc37755062ebd865757fcaa1f2f54363b9c3fdccf2a48`, 1280x800, max value 255, nonblank. The runner recorded 189 sampled distinct pixels; an independent full RGB scan found 107 exact colors, also nonblank.
- QEMU argv record: 648 bytes, SHA-256 `b12943f3554dac12f47ec6124c0472e8a037c415281ead4aa324daae526f8f1e`.
- Publication was atomic: the quarantined candidate moved to `dist/deadline-b39bb9f19a23`, the closed published manifest independently rehashed with zero missing, extra, or mismatched files, and `LATEST.json` now names the exact ISO/evidence/screenshot/serial/source hashes.
- Reconstructing the prior aggregate with the byte-identical old 260-byte `LATEST` record reproduced `d892cf352909859a6e80bb21bb298e41bda1142b9303053ae68ebe2b386406c5` across all 114 prior protected records, proving every earlier candidate, attempt, evidence file, and the LKG remained unchanged.

Exact QEMU argv:

`D:\VM\qemu\qemu-system-x86_64.exe -machine pc -accel tcg -m 1024 -boot order=d,strict=on -cdrom D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-candidates\deadline-b39bb9f19a23\300k-deadline-x86_64-688e94bf1b69.iso -vga std -display none -serial file:D:\PROJEct\LINUX\linux-chatgpt-edition\dist\.deadline-evidence\deadline-b39bb9f19a23\serial.log -qmp tcp:127.0.0.1:63640,server=on,wait=off -monitor none -nic none -no-reboot`

## Publication Integrity

| Fact | Final state |
| --- | --- |
| Candidates | Five failed candidates retained under `.deadline-candidates`; successful candidate moved atomically to published namespace |
| Published `dist/deadline-b39bb9f19a23` | Present; closed manifest and exact ISO independently verified |
| Published `dist/deadline-46bc6f6aedc0` | Absent |
| Published `dist/deadline-0d2637f5f224` | Absent |
| Published `dist/deadline-bade6e8baa9d` | Absent |
| Published `dist/deadline-45af9bbdc0f5` | Absent |
| Published `dist/deadline-7d9935426bbb` | Absent |
| `dist/LATEST.json` SHA-256 / bytes | `044bc29bc9cd7bfc07eab395fc04dffc42088a953b86e683334480dfc06e72a8` / `742` |
| Old LKG path | `dist/p01-172f13500b74/300k-bootstrap-x86_64-2c968ee3a0c6.iso` |
| Old LKG SHA-256 / bytes | `2c968ee3a0c687bd0d779247b7b595494a6a9870308387a07572796fd46d0678` / `69,206,016` |
| Owned processes | Zero QEMU, build runner, or smoke runner |
| Final disk | C: 156.50 GiB; D: 74.49 GiB |
| Product tree | Clean at candidate source/final HEAD `20fd3711cb5c7fd77bf46e828b13e053fc1ea6a2` |

## Verified vs. Deferred

| Claim | Status |
| --- | --- |
| Offline prompt-as-data UI/runtime source and fixed terminal/power boundaries | Verified by static tests |
| Six closed signed builds and fast structural candidate inspections | Verified; later builds are corrective, not reproducibility proof |
| Corrective apkovl member namespace, hostname, service lifecycle, and directory modes | Verified offline from exact new ISO overlay |
| Idempotent live-user/rootfs, tty1 sentinel, serial permission, and active-console reservation | Verified offline and across unique ordered runtime stages |
| BIOS optical media with exact `pc`/TCG and literal `-nic none` | Passed and retained in exact argv/evidence |
| Mapped graphical UI and real non-root xterm PTY proof | Passed: uid 1000 `chatgpt`, `/dev/pts/0`, command/file ok, exit 1 |
| Screenshot dimensions, variance, and hash | Passed: nonblank 1280x800 PPM, SHA-256 `0fe13818b9e5a8b46e2fc37755062ebd865757fcaa1f2f54363b9c3fdccf2a48` |
| Runtime UEFI, raw USB, broad hardware | Deferred |
| Docker parity, second-build reproducibility, size optimization | Deferred |
| Exhaustive recursive security audit and release certification | Deferred |

## Deviations from Plan

1. Added signing-key preflight (`91ec08e`) so missing external identity fails before build work.
2. Replaced unstable WHPX-first builder acceleration with deterministic TCG (`502b024`).
3. Added a bounded readiness-only transport seam and stable `pc` builder machine (`5559ef2`).
4. Resolved the deterministic IO-APIC panic through verified direct-kernel `noapic` boot (`d43a00e`).
5. The predecessor smoke hit a serial file-sharing violation before observation. A dedicated debug workflow added share-safe reads plus a closed, predecessor-hash-linked recovery path (`b609302`).
6. The one authorized recovery reached Alpine's login prompt but timed out without project markers. The candidate and both attempts were preserved; no further build, edit, or smoke was performed.
7. A dedicated offline debug workflow fixed the proven apkovl member/lifecycle contract (`6ecda6b`). One distinct corrective candidate was then built and smoked. Its hostname applied, but local startup still stopped before `ROOTFS_READY`; this new narrow failure is preserved without another retry.
8. A second evidence-backed debug fix made BusyBox live-user locking idempotent (`cc612a4`). Its one new candidate crossed `ROOTFS_READY`, then timed out before X. The exact narrower failure was preserved with no additional retry.
9. A third evidence-backed fix consumed BusyBox getty's literal `--` sentinel (`cbaf47e`). Its one new candidate again crossed `ROOTFS_READY` and reached the login prompt but produced no later stages. Offline tracing now suggests a narrower observability boundary: getty changes `ttyS0` to root-owned mode 0620, while later uid-1000 stage writes silently skip a non-writable serial device. This is an evidence-backed hypothesis for a separate debug workflow, not a runtime-proven diagnosis.
10. A fourth evidence-backed fix removed the authored ttyS0 getty and established fail-closed dialout ownership (`ab43575`). Its one new candidate again crossed `ROOTFS_READY`; offline initramfs tracing then proved `setup_inittab_console` recreates the ttyS0 getty from QEMU ACPI SPCR after the overlay is installed. The exact narrower failure was retained with no retry or promotion.
11. A fifth evidence-backed fix reserved the active console with a dormant inittab action (`8446a2c`). Its one new candidate suppressed initramfs getty synthesis, passed every runtime and visual gate, and was atomically promoted without retry.

## Known Stubs

None. No skipped tests or placeholder evidence remain in the Deadline MVP contract.

## Remaining Deferred Work

No blocker remains for the Deadline MVP BIOS artifact. Runtime UEFI, raw USB, broad hardware, Docker parity, same-source second-build reproducibility, size optimization toward 100 MB, exhaustive recursive security, and general release certification remain explicitly deferred. All five failed candidates and six failed attempts remain retained beside the successful published build and smoke evidence.

## Self-Check: PASSED

All twelve cited product commits exist; all six candidate manifests and ISO hashes match; all seven attempt records and retained evidence hashes match; every ISO is exactly 183,500,800 bytes; the new `LATEST` points to the exact verified publication; the old LKG and reconstructed 114-file prior aggregate remain byte-identical; QEMU/runners are absent; and the product tree remains clean at `20fd3711cb5c7fd77bf46e828b13e053fc1ea6a2`.

---
*Quick task: 260827-se6*
*Completed: 2026-08-28*
