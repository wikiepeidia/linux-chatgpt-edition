---
status: resolved
trigger: "Deadline MVP ISO boots stock Alpine 3.24 to (none) login but never applies the packaged 300K apkovl"
created: 2026-08-27
updated: 2026-08-28T02:55:00+07:00
---

# Debug Session: APKOVL Not Applied

## Symptoms

- expected: BIOS optical boot of the quarantined Deadline MVP candidate loads its generated Alpine apkovl, sets the 300K hostname and unprivileged `chatgpt` account, starts the local graphical runtime, emits ordered `300K_ROOTFS_READY`, `300K_X_READY`, `300K_UI_READY`, and `300K_TERM_EXEC_OK` serial markers, and provides a real xterm-backed `/bin/ash -l` PTY.
- actual: The guest boots through ISOLINUX into Alpine Linux 3.24 with kernel `6.18.44-0-virt`, then stops at the stock `(none) login:` prompt. Serial remains stable at 179 bytes and contains zero project readiness markers for the full 900-second bound.
- errors: Recovery smoke attempt `4007e73ec7ce482ab47c99388e576f1d` closed with `DEADLINE_SMOKE_TIMEOUT`; no graphical screenshot or terminal/PTY proof exists.
- artifact: Quarantined candidate `300k-deadline-x86_64-ecd8ad7698d6.iso`, SHA-256 `ecd8ad7698d6b201d048c8f0175964a5a0124758d6e37e547af53cd9bd929982`, exactly 183,500,800 bytes (175.000 MiB). Fast structural inspection reports BIOS boot support, kernel/initramfs, an apkovl member, local APK index, and structural UEFI files.
- preserved_evidence: The first smoke was a host observation failure and remains immutable with attempt SHA-256 `c789e80e4d85a92b035a429fb1c527189f431d349ff9cd89df127e7e7f6f1806`. The single hash-linked recovery has record SHA-256 `abc6524b98b26163e4de77914db5a6142cd15f2813d7776ff62136935c7acdb1`, failure SHA-256 prefix `4ebf2993`, argv prefix `f668acd8`, and serial prefix `c10d35bc`.
- integrity: Zero owned QEMU and runner processes remain. Candidate, both attempts, `dist/LATEST.json` (SHA-256 `34cb52ca77d0a6e679aa10a65aa34ff7131eb5cedb0796660d049ffbc1f297a7`), and the prior known-good bootstrap ISO (SHA-256 `2c968ee3a0c687bd0d779247b7b595494a6a9870308387a07572796fd46d0678`) must remain unchanged during diagnosis.
- environment: Windows host, QEMU 11.1.0 at `D:\\VM\\qemu`, no working Docker engine or WSL. The guest smoke used one `pc`/TCG QEMU, optical media, and `-nic none`.

## Current Focus

- hypothesis: The overlay is found and unpacked, but its noncanonical `./...` member list is passed verbatim to apk's overlay-protection input, so package install replaces project files; simultaneously, it provides neither Alpine's default-service sentinel nor a complete coherent explicit eudev runlevel set, and no `etc/hostname` guarantees `(none)`.
- test: The focused source/test fix is committed at `6ecda6b799f0`; archive this resolved offline session and append its recurrence pattern to the durable knowledge base.
- expecting: Planning records truthfully distinguish accepted offline root-cause verification from the still-required rebuilt-ISO graphical/PTY smoke.
- reasoning_checkpoint:
    hypothesis: `tar -C "$stage" ... .` emits `./...` names that apk does not match to package-relative overlay paths, while absent default-or-complete explicit boot services and hostname remove baseline runlevels and identity; together package installation yields the observed stock-like login with no project service marker.
    confirming_evidence:
      - Exact candidate archive is valid but every one of its 35 members is dot-prefixed; candidate `/init` writes tar verbose names unchanged to `/tmp/ovlfiles` and passes that stream to apk `--overlay-from-stdin`.
      - Candidate initramfs suppresses automatic baseline service links whenever an ovl file exists, while the archive lacks `etc/.default_boot_services`, `etc/hostname`, and most baseline sysinit/boot/shutdown links.
      - Exact `nlplug-findfs` binary contains `.boot_repository` and `*.apkovl.tar.gz*`; the ISO has both a root overlay and `/apks/.boot_repository`, eliminating the filename/path branch.
    falsification_test: A canonicalized fixture built from unchanged source would have no `./` members and would contain hostname/default-service sentinels, or pinned apk source would prove dot-prefixed names are normalized before overlay matching.
    fix_rationale: Archiving explicit top-level operands makes tar output match apk package-relative paths; adding hostname and a complete explicit eudev runlevel set restores identity/services without simultaneously activating mdev; explicit parent modes keep the unprivileged desktop traversable.
    blind_spots: No Linux runtime execution is allowed in this offline phase, so actual apk behavior will ultimately require the corrected build/smoke; the RED test covers the pinned static contracts and the later direct ISO smoke remains mandatory.
    candidate_causes:
      - code: generator archives `.` and implicitly creates ancestor directories under umask 077.
      - config/data: archive omits both default-service declaration and a complete explicit runlevel alternative, plus `etc/hostname`, required by the extracted initramfs lifecycle.
      - environment: QEMU transport and serial reader are eliminated by preserved successful BIOS/login evidence.
    and_gate: yes; dot-prefixed overlay-protection names explain project-file replacement, while missing coherent lifecycle state independently explains absent identity/baseline services and must be fixed together for a viable graphical boot.
- tdd_checkpoint:
    test_file: tests/deadline/run.ps1
    test_name: Apkovl member paths and lifecycle survive diskless package install
    status: green
    oracle_type: specified
    failure_output: `FAIL ... Overlay must choose exactly one coherent lifecycle: Alpine default services or the complete explicit eudev runlevel set.`
- next_action: Commit this resolved session and its knowledge-base entry, then hand off the corrected ISO rebuild and direct BIOS GUI/PTY smoke as the next required product-verification action.
- bug_class: bohrbug
- constraints:
    - preserve_candidate_and_evidence: true
    - offline_iso_inspection_first: true
    - qemu_before_root_cause: forbidden
    - rebuild_before_test_first_fix: forbidden
    - promotion_without_gui_and_pty_proof: forbidden

## Evidence

- timestamp: 2026-08-28T00:15:00+07:00
  checked: Phase 0 semantic/fallback recall and project skill discovery
  found: MemPalace CLI is absent; the durable knowledge base contains only the resolved IO-APIC panic and Windows serial-file-lock patterns, neither of which matches a BIOS-booted stock Alpine guest with a visible but unapplied apkovl. No project-defined debugger skills were found.
  implication: There is no known-pattern shortcut. Continue with offline working-backwards and differential inspection; do not reuse either transport fix as an overlay diagnosis.

- timestamp: 2026-08-28T00:20:00+07:00
  checked: Hidden deadline artifact roots
  found: `dist/.deadline-candidates`, `dist/.deadline-attempts`, and `dist/.deadline-evidence` exist; the quarantined candidate ISO is 183500800 bytes and the recovery serial is 179 bytes. Paths were only enumerated; no artifact was opened for write.
  implication: All protected state is locally available for an exact integrity baseline before ISO extraction.

- timestamp: 2026-08-28T00:25:00+07:00
  checked: Share-safe SHA-256 baseline of every preserved deadline candidate/attempt/evidence file plus `LATEST.json` and the prior bootstrap ISO
  found: All recorded high-value identities match exactly: candidate `ecd8ad7698d6b201d048c8f0175964a5a0124758d6e37e547af53cd9bd929982` at 183500800 bytes; first attempt `c789e80e4d85a92b035a429fb1c527189f431d349ff9cd89df127e7e7f6f1806`; recovery `abc6524b98b26163e4de77914db5a6142cd15f2813d7776ff62136935c7acdb1`; recovery failure/argv/serial `4ebf2993...`/`f668acd8...`/`c10d35bc...`; `LATEST.json` `34cb52ca...`; bootstrap ISO `2c968ee3...`.
  implication: Integrity is green. Offline extraction may proceed only into disposable scratch while all protected trees remain read-only by policy.

- timestamp: 2026-08-28T00:35:00+07:00
  checked: Complete project profile, apkovl generator, fast inspector, candidate build request/lock, and pinned structural boot report
  found: The profile sets `hostname=300k` and `apkovl=genapkovl-300k.sh`; the generator emits `$PWD/$hostname.apkovl.tar.gz`; the ISO contains the exact expected `/300k.apkovl.tar.gz`; but the fast inspector validates only path/type/non-empty presence and never opens the overlay or checks BIOS kernel arguments. Candidate source/pins are commit `021de7a...`, aports `52643b7...`, Alpine 3.24.1, xorriso 1.5.8-r0.
  implication: Filename presence alone does not establish initramfs usability. Archive validity/root paths and boot-media discovery remain live, falsifiable branches.

- timestamp: 2026-08-28T00:45:00+07:00
  checked: Read-only 7-Zip extraction of exact ISO members and retained aports archive into a new temporary directory
  found: The ISO member is exactly 7045 bytes; BIOS and GRUB both use Alpine's generated `modules=loop,squashfs,sd-mod,usb-storage quiet` line with no explicit `alpine_dev` or `apkovl`; the retained `aports.tar` was recovered at 69724160 bytes; the ISO hash remained `ecd8ad...` after extraction. Git-for-Windows tar could not read a Windows absolute path because its gzip/POSIX path environment was incomplete, so it yielded no archive evidence.
  implication: Boot config is identical across BIOS/UEFI and intentionally relies on initramfs media autodiscovery. Archive inspection must use a Windows-safe independent decoder or the embedded pinned tools, not the failed Git-tar invocation.

- timestamp: 2026-08-28T00:55:00+07:00
  checked: Separate gzip and inner-tar validation plus complete member metadata/content of extracted `/300k.apkovl.tar.gz`
  found: Both layers validate. The tar is 40960 bytes with 19 directories and 16 files; it contains `/etc/apk/world`, custom inittab, executable `300k.start`, default/local runlevel link, UI/runtime files, and the `ROOTFS_READY` call. It does not contain `/etc/hostname`. Several implicitly created parents (`/etc/runlevels`, `/home`, `/usr`, `/usr/local`) are mode 0700 due the generator's private umask.
  implication: Malformed/corrupt overlay is eliminated. `(none)` does not prove the overlay was skipped because this generator never writes the hostname; discovery must be decided from `/init`, while restrictive ancestor modes are a separate later usability defect if the overlay is applied.

- timestamp: 2026-08-28T01:05:00+07:00
  checked: Exact retained aports `mkimage.sh`/`mkimg.base.sh`/`mkimg.standard.sh` and candidate initramfs 3.14.0-r0 `/init`
  found: Aports invokes the custom callback exactly as assumed: `(cd "$DESTDIR"; fakeroot "$script" "$hostname")`, then merges the emitted root-level file. `/init` calls `nlplug-findfs ... -b /tmp/repositories -a /tmp/apkovls`; with no explicit `apkovl=`, it takes the first path from `/tmp/apkovls`, verifies it is a file, runs `tar -C "$sysroot" -zxvf`, reads its world, and passes the tar member list to apk as overlay input. The standard boot line and profile callback contract therefore align.
  implication: Callback cwd/name and initramfs decompression are eliminated. Static diagnosis now hinges on whether `nlplug-findfs` writes this ISO's overlay path; if it does, the session title is false and the failure moves to post-unpack boot/runtime defects.

- timestamp: 2026-08-28T01:15:00+07:00
  checked: Exact candidate `nlplug-findfs` binary and archive/initramfs lifecycle cross-check
  found: `nlplug-findfs` contains the literal discovery glob `*.apkovl.tar.gz*`, `.boot_repository`, and `found apkovl %s`; the ISO layout satisfies those predicates. Initramfs deliberately skips its default runlevel population whenever `$ovl` is a file, unless the unpacked root contains `/etc/.default_boot_services`. The candidate archive lacks that sentinel and `/etc/hostname`; all 35 member paths start `./` while `/init` feeds the verbose path list directly into apk overlay protection.
  implication: Overlay non-discovery is eliminated offline. The root cause is a post-discovery archive/lifecycle contract mismatch, not the ISO filename or boot cmdline; create a failing regression before changing the generator.

- timestamp: 2026-08-28T01:25:00+07:00
  checked: Focused test-first RuntimeStatic regression against unchanged production generator
  found: New test `Apkovl member paths and lifecycle survive diskless package install` fails RED on the current dot archive operand; all seven pre-existing RuntimeStatic tests pass. Result is exactly `passed=7 failed=1`, process exit 1. The specified oracle also requires validated hostname content, `.default_boot_services`, explicit safe top-level tar operands, and 0755 traversable ancestor directories.
  implication: The defect is reproducible without QEMU or rebuild and now has a durable regression guard. Production code remains unchanged for the required RED checkpoint.

- timestamp: 2026-08-28T01:30:00+07:00
  checked: Post-RED immutable artifact integrity and worktree scope
  found: Candidate, both attempt records, both failure/argv/serial evidence sets, `LATEST.json`, and bootstrap ISO retain every pre-investigation SHA-256 and byte count exactly. `git diff --check` has no error; only `tests/deadline/run.ps1` is modified and this debug session is untracked. Production generator and inspector have no diff.
  implication: The TDD checkpoint is clean and isolated. No preserved candidate/evidence bytes, promotion pointer, QEMU state, or production code changed.

- timestamp: 2026-08-28T01:45:00+07:00
  checked: Refined mutually exclusive lifecycle regression against unchanged production generator
  found: RuntimeStatic remains RED at `passed=7 failed=1`, exit 1, now specifically because the generator selects neither Alpine default/mdev services nor a complete explicit eudev runlevel set. The assertion also prevents enabling both device managers. No production source changed during refinement.
  implication: The test models the coherent pinned Alpine lifecycle rather than forcing the `.default_boot_services` sentinel. The GREEN fix may safely use explicit eudev services without mdev duplication.

- timestamp: 2026-08-28T01:55:00+07:00
  checked: Minimal generator GREEN against the unchanged refined regression
  found: Generator now writes the hostname, creates explicit 0755 ancestors, selects one complete explicit eudev lifecycle with no mdev/default sentinel, and archives exactly `etc home usr`. RuntimeStatic is GREEN at `passed=8 failed=0`, exit 0.
  implication: The focused regression accepts the complete repaired lifecycle. A causal fix-site mutant is next before broader adjacent verification.

- timestamp: 2026-08-28T02:05:00+07:00
  checked: Focused canonical-tar-operand mutant and exact reapplication
  found: Changing only `etc home usr` back to `.` returned RuntimeStatic to `passed=7 failed=1`, exit 1, on the expected unsafe-member assertion. Reapplying only that line restored `passed=8 failed=0`, exit 0.
  implication: The recurrence test kills the causal mutant and the repaired working tree is restored. Proceed to adjacent static/unit suites.

- timestamp: 2026-08-28T02:15:00+07:00
  checked: Adjacent deadline and Phase 1 offline suites
  found: Deadline AllStatic passes 14/14, including the new lifecycle regression; Phase 1 Unit passes 27/27. Neither suite launches QEMU or builds an ISO.
  implication: The generator repair does not regress build contracts, publication/smoke contracts, UI/runtime static behavior, or Phase 1 foundation units.

- timestamp: 2026-08-28T02:25:00+07:00
  checked: Pinned Alpine explicit eudev service contract after GREEN review
  found: The coherent `setup-devd` result removes both `mdev` and `hwdrivers`. The explicit runlevels must therefore omit `hwdrivers`; clock remains synthesized separately by initramfs and no default-service sentinel is valid for this strategy.
  implication: The first GREEN contained one excess legacy device-manager helper. Refine production and the specified oracle together, then rerun all offline verification before acceptance.

- timestamp: 2026-08-28T02:35:00+07:00
  checked: Corrected exact eudev contract plus target and adjacent suites
  found: Removed `hwdrivers` from both generator and specified oracle. RuntimeStatic passes 8/8, Deadline AllStatic passes 14/14, and Phase 1 Unit passes 27/27; the oracle rejects `mdev` and `hwdrivers` for the explicit eudev branch.
  implication: The GREEN fix now matches the pinned Alpine lifecycle exactly and preserves all adjacent offline contracts. Final integrity and hygiene signals remain.

- timestamp: 2026-08-28T02:45:00+07:00
  checked: Final offline fix-acceptance hygiene, process, and immutable-artifact signals
  found: Git-for-Windows `sh -n` passes; `git diff --check` passes (only the existing LF-to-CRLF warning is emitted); exact owned-process query finds zero QEMU/build/smoke processes. Candidate, both attempt records, both failure/argv/serial evidence sets, `LATEST.json`, and bootstrap ISO retain their exact pre-fix byte counts and SHA-256 hashes.
  implication: The multi-signal guardrail accepts the focused source/test change without mutating or exercising the quarantined ISO. A rebuilt ISO and direct BIOS graphical/PTY smoke remain a separate mandatory product verification step.

- timestamp: 2026-08-27T23:59:00+07:00
  checked: First real guest verdict from the hash-linked Deadline MVP recovery smoke
  found: BIOS optical boot, ISOLINUX, Alpine 3.24, and kernel 6.18.44-0-virt succeeded, but the guest identified as `(none)` and emitted no project marker over 900 seconds.
  implication: The failure is after generic ISO boot/rootfs availability and before every project runtime seam; absent hostname plus absent markers strongly localize it to overlay application or an equivalent earliest boot customization path.

## Eliminated

- hypothesis: `nlplug-findfs` rejects the overlay because its hostname starts with a digit, its path is ISO root, or BIOS lacks explicit `apkovl=`.
  evidence: The exact initramfs binary uses the broad `*.apkovl.tar.gz*` glob and `.boot_repository` discovery; the candidate has `/300k.apkovl.tar.gz` and `/apks/.boot_repository`, and the generated Alpine boot line intentionally uses autodiscovery.
  timestamp: 2026-08-28T01:15:00+07:00

- hypothesis: The candidate cannot boot through BIOS optical media.
  evidence: The preserved recovery serial reaches Alpine 3.24 and a login prompt under the exact required pc/TCG/optical/`-nic none` smoke lane.
  timestamp: 2026-08-27T23:59:00+07:00

- hypothesis: Missing project markers are solely another host serial-reader failure.
  evidence: The fixed share-safe reader captured and hashed 179 bytes through a bounded 900-second run, including ISOLINUX, kernel, and login output, with no file-lock failure.
  timestamp: 2026-08-27T23:59:00+07:00

## Resolution

- root_cause: The custom generator emits dot-prefixed tar member names that do not align with apk's package-relative overlay-protection stream, and it omits both a coherent boot-service strategy and `etc/hostname`; implicit 0700 ancestor modes would also block the non-root UI even after those files survive.
- fix: Archive exact package-relative roots `etc home usr`; write the validated hostname; create all runtime ancestors as 0755; and install the pinned explicit eudev runlevel set with no `.default_boot_services`, `mdev`, or `hwdrivers`. Add a specified RuntimeStatic contract covering the member namespace, lifecycle XOR, exact device-manager choice, hostname, and traversable modes.
- verification:
    target_test: pass — RuntimeStatic 8/8 after the exact eudev correction
    mutation_check: pass — focused `etc home usr` to `.` mutant was killed at 7/8 and canonical operands restored 8/8
    no_op_deletion: pass — production change is additive and every changed behavior maps to a confirmed root-cause branch
    adjacent_tests: pass — Deadline AllStatic 14/14, Phase 1 Unit 27/27, shell syntax, and diff hygiene
    revert_and_reconfirm: pass — dot-operand mutant reproduced the regression and exact reapplication restored GREEN
    integrity_and_process: pass — zero owned QEMU/build/smoke processes and all protected hashes unchanged
    guardrail_verdict: accepted
    runtime_limit: corrected ISO build and direct BIOS GUI/PTY smoke were forbidden in this offline fix step and remain mandatory before artifact promotion
    code_commit: 6ecda6b799f0
- files_changed:
    - builder/apkovl/genapkovl-300k.sh
    - tests/deadline/run.ps1
- oracle_type: specified

## Prevention

- five_whys:
    - code_branch: The generator archived `.` because deterministic tar flags were tested but the emitted member namespace was not; initramfs then passed those `./...` names unchanged to apk's package-relative overlay protection.
    - lifecycle_branch: The overlay partially authored runlevels without declaring default services or reproducing the complete pinned explicit eudev lifecycle; the initramfs suppresses automatic defaults whenever any apkovl exists.
    - permissions_branch: Private `umask 077` created implicit ancestors because only leaf destinations were assigned modes, leaving the non-root UI unable to traverse its installed path.
    - environment_branch: Eliminated; the exact BIOS run reached Alpine login and the discovery binary/ISO layout matched offline.
- why_not_caught: The fast ISO inspector checked only that an apkovl member existed and RuntimeStatic checked manifest/determinism, but no gate asserted tar member namespace, initramfs lifecycle completeness, device-manager exclusivity, hostname, or ancestor modes.
- recurrence_guard: `tests/deadline/run.ps1` test `Apkovl member paths and lifecycle survive diskless package install`, with target 8/8, Deadline AllStatic 14/14, Phase 1 Unit 27/27, and a focused causal mutant killed before acceptance.
