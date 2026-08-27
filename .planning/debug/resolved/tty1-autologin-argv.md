---
status: resolved
trigger: "Guest emits ROOTFS_READY but BusyBox tty1 custom-login ABI prevents autologin and X_READY"
created: 2026-08-28
updated: 2026-08-28T02:06:00+07:00
---

# Debug Session: TTY1 Autologin Argv

## Symptoms

- expected: After `ROOTFS_READY`, tty1 `getty -n -l /usr/local/bin/300k-autologin` invokes the fixed helper contract, the dispatcher executes `/bin/login -f chatgpt`, the login profile starts the bounded X session, and the guest emits `X_READY`, `UI_READY`, then `TERM_EXEC_OK`.
- actual: Candidate `deadline-bade6e8baa9d` emits exactly one `ROOTFS_READY`, then remains without X/UI/TERM markers for the 900-second smoke. Independent ttyS0 shows hostname-correct `300k login:` and no error.
- artifact: `300k-deadline-x86_64-22e05e4d383c.iso`, SHA-256 `22e05e4d383c1e2e4d68543178a2ba27c14c46ab15f085f5d479af3a6e67f50d`, exactly 183,500,800 bytes (175 MiB), source commit `a084138` with product fix `cc612a4`.
- smoke_evidence: Sole ordinary attempt `feb8490977c24c398cabb5162f07cc66` closed `DEADLINE_SMOKE_TIMEOUT`; record SHA prefix `edd4b7c9`, failure prefix `92449a62`, argv prefix `04772d4f`, serial prefix `4af7ab07` with 204 bytes. Ordered markers contain only `ROOTFS_READY`; no screenshot or PTY proof.
- integrity: No retry, recovery, or promotion. QEMU/runner counts zero. Prior protected 51-file aggregate remains `8fac828bc950b2a83add314bf2251e0a56f8814a253cfe88b492c52f4e5a3e50`. LATEST, old LKG, all earlier candidates/attempts/evidence remain exact.
- environment: Alpine 3.24, pinned BusyBox 1.37.0-r31, custom inittab, BIOS pc/TCG optical QEMU with literal `-nic none`.

## Current Focus

- reasoning_checkpoint:
    hypothesis: Exact pinned BusyBox passes one literal `--` to the `300k-autologin` custom login, and the argc-0 basename guard exits usage/64 before forced login.
    confirming_evidence:
        - Candidate-pinned APK hash matches the retained BusyBox 1.37.0-r31 bytes; its Alpine source/config provenance enables unpatched GETTY.
        - BusyBox 1_37_0 source leaves `logname` null under `-n` and calls `BB_EXECLP(G.login, G.login, "--", logname, (char *)0)`.
        - Authored runtime requires `$# -eq 0`; the specified-oracle regression is RED 8/9 only at this mismatch.
    falsification_test: The hypothesis would be false if the exact source/package appended no sentinel under `-n`, or if the focused singleton-sentinel assertion passed before the runtime change.
    fix_rationale: Require argc 1, validate `$1` is literal `--`, and shift it before selecting autologin; the unchanged action-level argc-0 guard then proves no user-controlled or extra argv reaches `/bin/login -f chatgpt`.
    blind_spots: No QEMU or rebuilt guest is permitted in this session, so graphical runtime behavior remains for a later candidate smoke; the complete authored login/profile/startx/X_READY chain has been audited offline with no second concrete blocker.
    candidate_causes:
        - code: basename dispatcher enforces argc 0 instead of the custom-login singleton sentinel ABI.
        - config: wrong tty1 `getty -n -l LOGIN` form; eliminated because the authored form is intentional and exact BusyBox semantics define its sentinel.
        - environment: stale/different BusyBox; eliminated by exact candidate APK SHA and package source/config provenance.
        - data: prompted username adds an argument; eliminated because `-n` deliberately leaves `logname` null.
    and_gate: no; BusyBox/config/data are the contract and trigger, while the helper predicate is the single faulty condition.
- tdd_checkpoint:
    test_file: tests/deadline/run.ps1
    test_name: Locked live-user boot path is bounded and retains rescue access
    status: green
    failure_output: Prior RED 8/9; current GREEN 9/9
- next_action: Archive this resolved record under `.planning/debug/resolved/`, append its prevention summary to the knowledge base, and commit only those two planning files.
- bug_class: bohrbug
- constraints:
    - preserve_all_artifacts_and_evidence: true
    - qemu_before_test_first_fix: forbidden
    - rebuild_before_green: forbidden
    - promotion_without_all_markers_screenshot_pty: forbidden

## Evidence

- timestamp: 2026-08-28T01:44:30+07:00
  checked: Debug knowledge base and working tree before investigation
  found: No prior resolution matches the tty1 custom-login argv ABI; the only working-tree change is the untracked active debug record. The resolved predecessor establishes that `ROOTFS_READY` now succeeds before tty1.
  implication: Investigate this as a fresh deterministic post-ROOTFS contract failure while preserving every candidate/evidence artifact.

- timestamp: 2026-08-28T01:48:00+07:00
  checked: Complete authored tty1-to-X chain and all Deadline RuntimeStatic/AllStatic definitions
  found: Inittab invokes `getty -n -l /usr/local/bin/300k-autologin`; the symlink dispatcher currently accepts only argc 0 and would otherwise call usage/64. If reached, forced login enters `/etc/profile.d/300k-session.sh`, which gates tty1/no-DISPLAY/re-entry then execs the bounded `session` action; `startx -- -nolisten tcp vt1` loads the owned `.xinitrc`, which verifies Openbox before the sole `X_READY` producer. No second authored pre-X blocker is evident in that chain.
  implication: The existing RuntimeStatic assertion encodes the wrong zero-argument ABI and is the minimal regression seam; the downstream chain should be hardened in the same focused contract test but not otherwise changed without concrete evidence.

- timestamp: 2026-08-28T01:48:00+07:00
  checked: Candidate manifest pin against the locally retained BusyBox APK
  found: Candidate `deadline-bade6e8baa9d` records `busybox-1.37.0-r31.apk` SHA-256 `0e626fa97cf937fda7bba4ed4dde8e2f2dbb5083ac34e02180cec0c4eba9351b`; the retained local APK has exactly that SHA-256. Its extracted BusyBox binary is 804616 bytes with SHA-256 `01a989eb4d1d04b0d146c790ac536abd88f374ec74a2e110c58910b840d42045`.
  implication: ABI validation can be performed against exact candidate-pinned bytes, not an unpinned system BusyBox.

- timestamp: 2026-08-28T01:53:00+07:00
  checked: Exact BusyBox 1.37.0 source contract and Alpine package patch/config provenance
  found: BusyBox tag `1_37_0` initializes `logname = NULL`; `-n` skips username acquisition; line 689 executes `BB_EXECLP(G.login, G.login, "--", logname, (char *)0)`, so the first null terminates argv after one literal sentinel. The candidate APK metadata names Alpine aports origin `c3ef5d10e6ef6528852c51f0564963e2f8c1be19`; the retained commit enables `CONFIG_GETTY=y`, and none of its BusyBox patches changes getty/custom-login argv construction.
  implication: The helper receives argc 1 with argv[1] exactly `--`; the current argc-0 guard deterministically exits 64. This confirms the root cause rather than merely correlating it with the smoke timeout.

- timestamp: 2026-08-28T01:53:00+07:00
  checked: SBFL eligibility
  found: The PowerShell RuntimeStatic suite has passing/failing assertions but no per-test execution coverage for shell lines, so an Ochiai spectrum cannot be computed.
  implication: SBFL is explicitly skipped; the direct specified ABI assertion is the deterministic fault-localization seam.

- timestamp: 2026-08-28T01:56:00+07:00
  checked: Agent-authored focused RuntimeStatic regression before runtime change
  found: RuntimeStatic produced eight passes and exactly one failure: `Locked live-user boot path is bounded and retains rescue access` rejected the absent singleton `--` consume sequence.
  implication: The regression is RED on only the confirmed root-cause contract; all unrelated RuntimeStatic assertions remain green.

- timestamp: 2026-08-28T01:58:00+07:00
  checked: Focused RuntimeStatic after minimal runtime fix
  found: RuntimeStatic is GREEN with nine passes and zero failures; the corrected basename branch requires argc 1, literal `--`, shifts it, and reaches the unchanged action-level argc-0 guard before fixed forced login.
  implication: The specified oracle accepts the smallest root-cause fix and retains closed argv on both sides of dispatch.

- timestamp: 2026-08-28T02:00:00+07:00
  checked: Exact fix-site mutant plus revert-and-reconfirm
  found: Replacing only the singleton-sentinel consume sequence with the original argc-0 guard returned RuntimeStatic to 8/9 at exactly the focused test; reapplying the fix restored 9/9. No test assertion changed during the counterfactual.
  implication: The regression kills the causal mutant and the runtime hunk, not an unrelated change, is necessary and sufficient for focused GREEN.

- timestamp: 2026-08-28T02:02:00+07:00
  checked: Adjacent machine-verifiable suites after reapplying the fix
  found: Deadline AllStatic passed 15/15 and Phase 1 Unit passed 27/27. The included RuntimeStatic contract, build/static publication boundaries, smoke-unit logic, and Phase 1 host/build invariants all remain green.
  implication: The minimal runtime/test change has no detected regression in the immediately adjacent or broader offline gates.

- timestamp: 2026-08-28T02:06:00+07:00
  checked: Atomic runtime/test commit after accepted guardrail
  found: Commit `cbaf47e` contains exactly `300k-runtime` and `tests/deadline/run.ps1`, with four insertions and two deletions.
  implication: The machine-verified product fix and regression are durably isolated from the debug/planning archive.

- timestamp: 2026-08-28T01:41:17+07:00
  checked: Exact candidate inittab/runtime, pinned BusyBox custom-login ABI, and sole guest smoke
  found: The guest crosses ROOTFS_READY; BusyBox supplies literal `--` to the custom login helper; the helper rejects every nonzero argc before reaching login.
  implication: The first deterministic downstream failure is pre-login tty1 argv handling, not Xorg itself.

## Eliminated

- hypothesis: Root filesystem customization or local startup still blocks the session.
  evidence: The same guest emitted one authenticated `ROOTFS_READY`, and the prior debug session was archived with guest proof.
  timestamp: 2026-08-28T01:41:17+07:00

- hypothesis: The locked shadow field prevents root forced login.
  evidence: BusyBox stores `x` in passwd and `!` in shadow; root `login -f` checks the passwd field before bypassing password verification, and the authored user explicitly uses `/bin/ash`.
  timestamp: 2026-08-28T01:41:17+07:00

## Resolution

- root_cause: The `300k-autologin` basename branch accepts only argc 0, but exact pinned BusyBox 1.37.0-r31 `getty -n -l LOGIN` always invokes the custom login as `LOGIN --` when `logname` is null; the helper therefore exits usage/64 before `/bin/login -f chatgpt`.
- fix: Require exactly one literal BusyBox `--` sentinel in the `300k-autologin` basename branch and shift it before the unchanged zero-argument autologin action executes `/bin/login -f chatgpt`; replace the stale RuntimeStatic zero-argv assertion with the exact closed ABI.
- verification:
    target_test: { result: pass, suite: "Deadline RuntimeStatic 9/9" }
    mutation_check: { result: pass, method: "manual exact fix-site mutant because Stryker is not configured for shell/PowerShell", mutant_killed: true, mutant_result: "RuntimeStatic 8/9" }
    no_op_deletion: { result: pass, deletion_justified_by_rca: false, evidence: "runtime diff is additive closed-argv validation; test oracle is strengthened, not weakened" }
    adjacent_tests: { result: pass, suites_run: ["Deadline AllStatic 15/15", "Phase 1 Unit 27/27", "downstream login/profile/startx/X_READY offline contract audit"] }
    revert_and_reconfirm: { result: pass, bug_returned_on_revert: true, fixed_on_reapply: true, results: "8/9 -> 9/9" }
    guardrail_verdict: accepted
    environment_note: "No QEMU, build, candidate, evidence, LATEST, or LKG mutation was permitted or performed; a new candidate smoke is required for guest-level confirmation."
    code_commit: cbaf47e
- oracle_type: specified
- files_changed:
    - builder/apkovl/rootfs/usr/local/bin/300k-runtime
    - tests/deadline/run.ps1

## Prevention

- causal_branches:
    - code: The helper's basename path was written and reviewed against an assumed zero-argument custom-login call rather than the dependency's actual sentinel-bearing ABI.
    - environment_contract: The pinned BusyBox implementation terminates its variadic exec argv at null `logname`, leaving literal `--` as the one helper argument; Alpine enables that unpatched GETTY path.
    - test_gate: RuntimeStatic asserted the same zero-argument assumption, so it certified the defect instead of modeling the dependency boundary.
- why_not_caught: RuntimeStatic encoded an inferred zero-argument `getty -n -l` contract and lacked a dependency-ABI assertion with closed boundary neighbors.
- recurrence_guard: `tests/deadline/run.ps1` test `Locked live-user boot path is bounded and retains rescue access` now requires argc 1, literal `--`, immediate shift, and the unchanged action-level argc-0 guard; the original-guard mutant is killed 8/9 and fixed code passes 9/9.
