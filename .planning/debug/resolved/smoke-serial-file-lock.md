---
status: resolved
trigger: "Direct BIOS smoke reader cannot read QEMU serial.log while QEMU owns the live file"
created: 2026-08-27
updated: 2026-08-27T23:17:22.9876487+07:00
---

# Debug Session: Smoke Serial File Lock

## Symptoms

- expected: `Invoke-DeadlineSmoke.ps1` tails the live QEMU serial log, observes ordered ROOTFS/X/UI/TERM markers, captures one QMP screenshot, verifies evidence, and promotes only on pass.
- actual: Immediately after QEMU launch, PowerShell calls a non-share-safe text reader and fails because `serial.log` is in use by another process. No guest-runtime verdict is obtained.
- error: `DEADLINE_SMOKE_FAILED: ... ReadAllText ... serial.log ... being used by another process.`
- timeline: Occurred on the first direct BIOS smoke of the first validated graphical candidate on 2026-08-27.
- reproduction: Candidate `deadline-7d9935426bbb`, ISO SHA-256 `ecd8ad7698d6b201d048c8f0175964a5a0124758d6e37e547af53cd9bd929982`, 183,500,800 bytes. Invoke the smoke runner on Windows while QEMU writes the serial file. Do not relaunch the guest until the reader and recovery policy have test-first proof.
- consumed attempt: ID prefix `60b575ba`; immutable attempt SHA-256 `c789e80e...`, qemu-argv SHA-256 `5261e883...`, failure SHA-256 `a703a688...`, serial SHA-256 `43a8361c...`, 79 bytes containing the ISOLINUX prompt. No readiness marker, screenshot, or PTY evidence exists.
- integrity: QEMU/owned process counts are zero. Candidate remains closed/quarantined. LATEST SHA-256 is still `34cb52ca77d0a6e679aa10a65aa34ff7131eb5cedb0796660d049ffbc1f297a7`; old ISO is still 69,206,016 bytes with SHA-256 `2c968ee3a0c687bd0d779247b7b595494a6a9870308387a07572796fd46d0678`.

## Current Focus

- bug_class: `bohrbug`
- hypothesis: On Windows, `File.ReadAllText` shares only read access, which is incompatible with QEMU's already-open write handle; a bounded `FileStream` opened for read with `FileShare.ReadWrite | FileShare.Delete` removes that deterministic conflict while strict UTF-8/complete-line parsing keeps partial writes retryable.
- test: Resolved after RED/GREEN, mutation, adjacent, and immutable-host-state verification.
- expecting: Complete — no guest relaunch was authorized or needed for this host-only fix gate.
- next_action: Archived; the explicit successor may be invoked separately with `-RecoverHostObservationFailure` and a fresh evidence directory.
- reasoning_checkpoint:
    hypothesis: `File.ReadAllText shares only read access; when QEMU already has serial.log open for write on Windows, the new read handle is rejected before parsing, and the catch path consumes the one attempt as a generic failure.`
    confirming_evidence:
      - `The immutable failure message names ReadAllText and the live serial path as in use; no 300K marker, PTY, screenshot, or smoke evidence exists.`
      - `A host fixture with an open writer reproduces the IOException under ReadAllText and succeeds under FileShare.ReadWrite | FileShare.Delete.`
      - `The agent-authored RED test fails at that exact shared-writer read with no structured DEADLINE_SERIAL_INCOMPLETE code.`
    falsification_test: `If the same open-writer fixture still fails after only the explicit share-safe snapshot replaces ReadAllText, or if reverting that change does not restore RED, the hypothesis is false.`
    fix_rationale: `Opening one bounded append-only snapshot with symmetric read/write/delete sharing addresses Windows handle compatibility; strict decoder flush distinguishes a partial trailing UTF-8 sequence from malformed internal bytes, so retry semantics remain fail closed. A separate CreateNew recovery record preserves the predecessor and the general one-attempt record.`
    blind_spots: `QEMU is intentionally not relaunched, so host tests prove Windows handle semantics and closed recovery classification rather than a new guest boot. CIM command-line ownership is verified only against the current zero-process host and injected nonzero unit boundary.`
    candidate_causes:
      - `code: Get-DeadlineSerialFacts uses File.ReadAllText with insufficient sharing for a concurrent writer.`
      - `environment: Windows enforces symmetric handle-sharing compatibility while QEMU retains its live write handle.`
      - `config: the one-attempt policy makes the harness failure permanent but is intentional and must remain unchanged outside the explicit recovery path.`
      - `data: a growing log can end mid-line or mid-UTF-8 code point, which is retryable but did not cause the observed sharing exception.`
    and_gate: `yes — the observed failure requires both the non-share-safe code path and a concurrently open Windows writer; neither alone produces the exception.`
- tdd_checkpoint:
    test_file: `tests/deadline/run.ps1`
    test_name: `Direct smoke contract is one-attempt BIOS optical and evidence driven`
    status: `green`
    failure_output: `Expected DEADLINE_SERIAL_INCOMPLETE; got the ReadAllText in-use exception with no structured code.`
    oracle: `specified — live append-only serial snapshots must be readable with strict retryable partial UTF-8 handling; recovery is permitted only for the closed exceptional predecessor predicate`

## Evidence

- timestamp: 2026-08-27T00:00:01+07:00
  checked: repository worktree before investigation
  found: Only `.planning/debug/smoke-serial-file-lock.md` is untracked; no source or test edits are present.
  implication: A minimal source/test/debug-only change can be isolated without overwriting another agent's tracked edits.
- timestamp: 2026-08-27T00:00:02+07:00
  checked: `.planning/debug/knowledge-base.md`
  found: No prior serial-file sharing or deadline-attempt recovery pattern exists; the sole entry concerns a builder IO-APIC panic.
  implication: Knowledge-base recall supplies no matching root-cause shortcut.
- timestamp: 2026-08-27T00:00:03+07:00
  checked: smoke-source and test text search
  found: `Invoke-DeadlineSmoke.ps1` owns attempt creation/update and live serial processing; the deadline test suite already exercises direct-smoke argv, ordered markers, and rejection of a second attempt.
  implication: The regression should extend the existing `SmokeUnit` contract rather than introduce a separate test harness.
- timestamp: 2026-08-27T00:00:04+07:00
  checked: complete `Invoke-DeadlineSmoke.ps1`
  found: The polling loop calls `Get-DeadlineSerialFacts` directly against QEMU's live `serial.log`; any error except incomplete/order is rethrown and permanently records the attempt as `failed`. `New-DeadlineAttemptRecord` uses `CreateNew` and converts every collision into `DEADLINE_ATTEMPT_ALREADY_EXISTS`.
  implication: The handle fault deterministically consumes the one attempt, and recovery must be an explicit closed-schema successor path rather than deletion/rewrite of the predecessor.
- timestamp: 2026-08-27T00:00:05+07:00
  checked: git history for smoke source and tests
  found: The direct smoke path entered in commit `77d69a1`; later QEMU fixes did not alter its serial-reader or one-attempt semantics.
  implication: Git bisect is unnecessary because the exact deterministic call site and introducing feature commit are already localized.
- timestamp: 2026-08-27T00:00:06+07:00
  checked: complete `tests/deadline/run.ps1` and serial/evidence helper implementations
  found: `Get-DeadlineSerialFacts` calls `File.ReadAllText` before line completeness and marker validation. `SmokeUnit` dot-sources the runner and already asserts serial grammar plus unconditional second-attempt rejection. Publication revalidates the closed serial bytes after QEMU exits.
  implication: Add the share-safe bounded snapshot at the reader seam and extend the same `SmokeUnit` with agent-authored shared-writer/partial-UTF-8 plus fail-closed recovery matrices.
- timestamp: 2026-08-27T00:00:07+07:00
  checked: immutable predecessor metadata, hashes, observation artifacts, and exact-path process ownership
  found: Attempt `60b575ba15894b9e9dc4207787e9b5c3` is a closed v1 failed record for candidate SHA `ecd8ad...9982` / 183500800 bytes. Root and copied attempt bytes are identical at SHA `c789e80e...f1806`; failure SHA is `a703a688...40a29`, argv SHA `5261e883...086dc`, serial SHA `43a8361c...25751` over 79 bytes. Failure is the ReadAllText in-use exception; serial has no 300K or PTY marker; screen and smoke evidence are absent; matching owned QEMU process count is zero.
  implication: This predecessor satisfies the proposed exceptional recovery shape without modifying it; recovery can be keyed to its immutable attempt SHA and exact candidate identity.
- timestamp: 2026-08-27T00:00:08+07:00
  checked: spectrum-based fault localization eligibility
  found: No failing test or per-test coverage exists before the regression is authored.
  implication: SBFL is skipped; the deterministic call chain and direct fixture provide stronger localization for this small seam.
- timestamp: 2026-08-27T00:00:09+07:00
  checked: unmodified host-only `SmokeUnit` baseline
  found: The existing direct-smoke unit test passes 1/1.
  implication: Any subsequent RED result is attributable to the new regression fixture, not a pre-existing host-test failure.
- timestamp: 2026-08-27T00:00:10+07:00
  checked: bounded Windows temporary-file sharing experiment
  found: With a write handle kept open using `FileShare.Read`, `File.ReadAllText` throws an IOException, while a read `FileStream` using `FileShare.ReadWrite | FileShare.Delete` snapshots all 6 bytes successfully.
  implication: The source hypothesis is directly confirmed on this host; the fix can be limited to the live snapshot/open/decode seam.
- timestamp: 2026-08-27T00:00:11+07:00
  checked: agent-authored RED `SmokeUnit` regression
  found: The test fails 0/1 at the split UTF-8 live-writer assertion because the current ReadAllText exception has no `DEADLINE_SERIAL_INCOMPLETE` code.
  implication: The regression reproduces the original handle defect before any production edit and provides the revert/reconfirm oracle.
- timestamp: 2026-08-27T00:00:12+07:00
  checked: minimal production diff before focused verification
  found: `build.ps1` now snapshots at most 16 MiB through `FileShare.ReadWrite | FileShare.Delete` and strict decoder flush; the smoke runner adds only the explicit recovery switch/record/process query while retaining normal `CreateNew` attempt behavior and exact QEMU argv/promotion flow.
  implication: The implementation addresses the confirmed handle mechanism and exceptional consumed attempt without weakening ordinary guest-failure finality.
- timestamp: 2026-08-27T00:00:13+07:00
  checked: first GREEN focused run
  found: `SmokeUnit` passes 1/1 with the live writer, partial UTF-8, byte cap, recovery rejection matrix, immutable predecessor link, and second-recovery guard.
  implication: The target regression is green; final hardening now additionally checks wrong candidate hash and every predecessor artifact hash.
- timestamp: 2026-08-27T00:00:14+07:00
  checked: strengthened focused run
  found: `SmokeUnit` again passes 1/1 after adding wrong-hash rejection, double-hash predecessor stability, and all predecessor artifact hash preservation.
  implication: The final target-test shape is green and ready for adjacent static regression testing.
- timestamp: 2026-08-27T00:00:15+07:00
  checked: complete host-only `AllStatic` suite
  found: All 13 runtime static, build/preflight static, publication fixture, smoke unit, and documentation tests pass; no QEMU was launched.
  implication: Adjacent functionality remains green across the changed reader's publication consumer and the smoke runner's existing contracts.
- timestamp: 2026-08-27T00:00:16+07:00
  checked: fix-site mutation and revert/reconfirm guardrail
  found: Replacing `FileShare.ReadWrite | FileShare.Delete` with read-only sharing makes the focused test fail 0/1 with `DEADLINE_SERIAL_READ_FAILED`; restoring the exact flags makes it pass 1/1.
  implication: The driving regression kills the sharing mutant, and this exact fix is necessary and sufficient for the reproduced handle defect.
- timestamp: 2026-08-27T00:00:17+07:00
  checked: exact-path process ownership, immutable artifacts, candidate, LATEST, and final diff shape
  found: Owned QEMU count is zero. Attempt/copy remain 536 bytes SHA `c789e80e...f1806`; failure `a703a688...40a29`; argv `5261e883...086dc`; serial 79 bytes `43a8361c...25751`; candidate 183500800 bytes `ecd8ad...9982`; LATEST 260 bytes `34cb52ca...97a7`. `git diff --check` passes and the production diff is additive rather than behavior-deleting.
  implication: No forbidden runtime, candidate, predecessor, or publication mutation occurred; only the intended source/test/debug changes exist.
- timestamp: 2026-08-27T00:00:18+07:00
  checked: `AllStatic` after timestamp/reparse/documentation hardening
  found: 12/13 pass; the smoke fixture rejects a marker-bearing predecessor as timestamp-invalid before reaching the marker predicate.
  implication: Timestamp syntax is useful malformed-evidence validation, but cross-file wall-clock ordering is an unnecessary and flaky eligibility condition and must be removed.
- timestamp: 2026-08-27T00:00:19+07:00
  checked: isolated timestamp parsing probe after chronology removal
  found: `ConvertFrom-Json` auto-converts canonical ISO timestamps to `DateTime`; coercing them back to culture-formatted strings produces `08/27/2026 ...`, which `DateTimeOffset.TryParse` rejects under the current locale. The untouched ISO failure timestamp parses successfully.
  implication: The remaining failure is a type/coercion bug in the new validation, not invalid evidence; validation must accept already-parsed date objects and use invariant round-trip parsing only for strings.
- timestamp: 2026-08-27T00:00:20+07:00
  checked: focused and adjacent tests after timestamp type normalization
  found: `SmokeUnit` passes 1/1 and `AllStatic` passes 13/13; canonical parsed/text timestamps pass, malformed text fails, and the marker fixture reaches its intended fail-closed recovery rejection.
  implication: The implementation and its adjacent host-only contracts are green after eliminating the culture-sensitive validation defect.
- timestamp: 2026-08-27T23:17:22.9876487+07:00
  checked: final code/test/documentation commit
  found: Commit `b609302085e5cfe5789fda3963500d6da0b07366` contains only the verified reader, recovery, tests, and recovery documentation; the worktree otherwise contains only this debug session before archival.
  implication: The minimal fix is atomically recorded and ready for the separate planning-resolution commit.

## Eliminated

- hypothesis: `Cross-file UtcNow ordering is a safe closed-evidence predicate for recovery eligibility.`
  evidence: `One marker-bearing fixture had individually valid timestamps outside the assumed interval and failed before the intended marker rejection; wall-clock chronology is not part of the host-observation identity contract.`
  timestamp: 2026-08-27T00:00:18+07:00

## Resolution

- root_cause: `Get-DeadlineSerialFacts` uses `File.ReadAllText` (read-only sharing) while QEMU owns a live write handle; Windows requires the new reader to share the existing write access, so the deterministic host observation exception is rethrown and consumes the candidate's only smoke attempt before any guest marker can be evaluated.
- oracle_type: specified
- fix: `Replace the live ReadAllText path with a bounded share-safe strict UTF-8 snapshot; add one CreateNew recovery successor gated on exact candidate identity, immutable closed pre-observation predecessor evidence, zero matching owned QEMU process, and predecessor attempt SHA.`
- verification:
    target_test: { result: pass, suite: `SmokeUnit 1/1` }
    mutation_check: { result: pass, mutant_killed: `FileShare.Read-only mutant failed the driving test with DEADLINE_SERIAL_READ_FAILED` }
    no_op_deletion: { result: pass, deletion_justified_by_rca: false, note: `diff adds bounded reader/recovery behavior and does not short-circuit existing smoke or promotion logic` }
    adjacent_tests: { result: pass, suites_run: [`AllStatic 13/13`] }
    revert_and_reconfirm: { result: pass, bug_returned_on_revert: true, fixed_on_reapply: true }
    guardrail_verdict: accepted
- files_changed: [`build.ps1`, `scripts/host/Invoke-DeadlineSmoke.ps1`, `tests/deadline/run.ps1`, `docs/DEADLINE-MVP.md`]
- commit: `b609302085e5cfe5789fda3963500d6da0b07366`

## Prevention

- branching_5_whys:
    code: `The live poll reused a closed-artifact helper; that helper used ReadAllText defaults; the defaults do not share an existing writer's write access; no live-writer fixture exercised this distinction.`
    environment: `QEMU retains serial.log for append on Windows; Windows checks sharing symmetrically; a second read handle must share the first handle's write access; closed-file tests never reproduced that host condition.`
    config: `The one-attempt policy correctly failed closed, but had no exceptional classifier for a harness failure before any guest observation; the sharing defect therefore consumed a valid candidate until a hash-linked single successor was defined.`
    data: `A growing serial file may end mid-line or mid-UTF-8 code point; the prior fixture wrote a complete file before reading; retryable partial-write behavior was therefore untested.`
    and_gate: `The incident required both the non-share-safe reader and the concurrently open Windows writer; the permanent consequence also required the intentional one-attempt policy.`
- why_not_caught: `No existing host fixture held serial.log open for writing while Get-DeadlineSerialFacts read it; SmokeUnit covered only complete closed serial files.`
- recurrence_guard: `Regression test tests/deadline/run.ps1 — Direct smoke contract is one-attempt BIOS optical and evidence driven — holds a shared writer open, splits UTF-8, verifies bounded parsing, and exercises the full recovery rejection/single-successor matrix.`
