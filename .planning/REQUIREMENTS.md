# Requirements: 300K Linux

**Defined:** 2026-08-25
**Core Value:** The ISO must reliably boot into an immediately recognizable, funny ChatGPT-like experience with a genuinely usable local terminal.

## v1 Requirements

Requirements for the first overnight release. The 100 MB figure is a measured stretch target, not permission to ship a broken image.

### Reproducible Build

- [ ] **BUILD-01**: A contributor can invoke one documented PowerShell entry point from Windows to build the x86_64 ISO using a Linux/amd64 container with pinned Alpine, aports, repository, and build-epoch inputs.
- [ ] **BUILD-02**: A clean build produces a uniquely identified ISO plus its SHA-256 checksum, exact byte size, build lock, resolved package manifest, and boot-layout report.
- [ ] **BUILD-03**: Private signing keys, credentials, tokens, host paths, and build caches remain outside Git and outside the runtime ISO.
- [ ] **BUILD-04**: If Docker Linux containers are unavailable, the documented fallback can perform the same build inside an Alpine VM without changing the distribution architecture.

### Live Boot

- [ ] **BOOT-01**: A cold x86_64 QEMU boot reaches the graphical 300K shell without a login, typed command, or network connection.
- [ ] **BOOT-02**: The live system restores its diskless overlay, installs every required package from the ISO-local repository, and reaches the UI with QEMU networking disabled.
- [ ] **BOOT-03**: The final ISO boots through the BIOS optical path in QEMU and emits an unambiguous ready milestone.
- [ ] **BOOT-04**: The same final ISO boots through non-Secure-Boot x86_64 UEFI in QEMU using fresh writable firmware variables and emits an unambiguous ready milestone.
- [ ] **BOOT-05**: USB-hybrid support is claimed only if the exact final ISO also passes a QEMU raw-disk boot check; otherwise release documentation labels it optical-ISO-only.
- [ ] **BOOT-06**: A failed graphical startup leaves a diagnosable rescue console or terminal fallback instead of an unrecoverable blank screen or restart loop.

### 300K Interface

- [ ] **UI-01**: The live session opens a polished full-screen conversation-style shell branded as 300K Linux with a persistent, readable statement that it is unofficial, offline, and locally scripted.
- [ ] **UI-02**: The main screen presents conversation history, prompt composer, terminal launch, basic tools, help, and power controls without copying OpenAI logos, wordmarks, fonts, icons, or other proprietary artwork.
- [ ] **UI-03**: The interface remains operable at 1024x768 and 800x600 without hiding the prompt, terminal escape path, or shutdown controls.
- [ ] **UI-04**: A user can complete the core demo using only the keyboard with visible focus, logical traversal, no keyboard trap, readable contrast, and a Reduced Chaos control.

### Real Terminal

- [ ] **TERM-01**: The user can open 300K Terminal with `Ctrl+Alt+T` and receive a real PTY-backed BusyBox `ash` login shell running as the unprivileged live user.
- [ ] **TERM-02**: The terminal correctly supports ordinary commands, pipelines, file creation, failing-command exit status, ANSI output, resize, and Ctrl-C.
- [ ] **TERM-03**: Text submitted to the conversation composer can never be interpolated into or executed by the shell; arbitrary commands run only inside the clearly separated terminal.
- [ ] **TERM-04**: The local `300k` command exposes documented `help`, `credits`, `why`, `fortune`, `seed`, and `about` subcommands with stable exit behavior.
- [ ] **TERM-05**: The user can return from the terminal to the main interface through a visible hint and a reliable keyboard path.

### Offline Comedy

- [ ] **FUN-01**: The composer returns transparent local scripted replies for identity, internet, credits, capability, help, and unknown-input intents without contacting a model or remote service.
- [ ] **FUN-02**: The release contains at least 40 reviewed original comedy lines across boot/status, intent, fallback, terminal-companion, and lifecycle/reaction decks.
- [ ] **FUN-03**: Each comedy deck uses seeded shuffle-bag selection so a fixed seed reproduces the same sequence and no item repeats before its deck is exhausted.
- [ ] **FUN-04**: Random comedy occurs only after deliberate actions, never steals focus, changes command semantics, alters files, simulates damage, or blocks boot and shutdown.
- [ ] **FUN-05**: Reduced Chaos disables nonessential random visual behavior while preserving every functional control and all substantive text.

### Basic Utilities

- [ ] **TOOL-01**: The user can perform a local arithmetic calculation from the graphical shell without opening a networked application.
- [ ] **TOOL-02**: The user can view factual system information that agrees with the running kernel, architecture, memory, and build identity.
- [ ] **TOOL-03**: Help/About explains the keyboard shortcuts, local-scripted behavior, ephemeral live session, parody identity, version, and build checksum.
- [ ] **TOOL-04**: The graphical shell provides clean reboot and shutdown actions and warns that normal live-session files disappear after power-off.

### Verification and Release Evidence

- [ ] **VER-01**: Guest startup emits stable ordered serial milestones for overlay, package installation, live user, X, UI, terminal, and clean shutdown while retaining separate human-readable diagnostics.
- [ ] **VER-02**: Automated or scripted QEMU smoke lanes verify offline boot, UI readiness, a screenshot, real terminal execution, composer non-execution, and clean shutdown against the exact ISO hash under test.
- [ ] **VER-03**: BIOS, UEFI, and any claimed raw-media result each have a bounded timeout, distinct pass/fail record, serial log, and retained evidence artifact.
- [ ] **VER-04**: The release reports compressed ISO bytes, installed/runtime size observations, package/asset contribution data, and whether the 100 MB stretch target was met without obscuring a miss.
- [ ] **VER-05**: A release candidate is accepted only after two clean builds or clean-boot validation passes preserve the complete P0 experience without relying on a warm cache inside the guest.

## v2 Requirements

Deferred until the complete P0 image passes twice.

### Experience Polish

- **POLISH-01**: User can use a RAM-only scratchpad from the existing graphical process.
- **POLISH-02**: User can browse a simple read-only Home Files panel from the existing graphical process.
- **POLISH-03**: User can regenerate and react to scripted responses and view a clearly fictional bundled conversation history.
- **POLISH-04**: User can select or display a replay seed for deterministic demos.
- **POLISH-05**: Boot can show short original micro-theater and a tiny original wallpaper without delaying readiness.

### Distribution Expansion

- **DIST-01**: User can install 300K Linux persistently to a disk.
- **DIST-02**: User can retain files and settings across boots through an explicit persistence workflow.
- **DIST-03**: Release supports a measured set of physical x86_64 hardware beyond the QEMU-first contract.
- **DIST-04**: Release supports a reviewed update and package-delivery mechanism.

## Out of Scope

| Feature | Reason |
|---------|--------|
| OpenAI API, ChatGPT accounts, Codex, remote inference, or a local LLM | Contradicts the offline joke and introduces secrets, cost, size, and failure modes. |
| Browser, Chromium/Electron/WebKit, Node.js, Python, full desktop environment, or a second GUI toolkit | Consumes the size and integration budget without improving the core experience. |
| Composer-driven arbitrary shell execution | Unsafe and ambiguous; real commands belong only in 300K Terminal. |
| Pixel-perfect ChatGPT clone or OpenAI logos, wordmarks, fonts, and icons | Original 300K parody identity is sufficient and avoids implying endorsement. |
| Destructive, deceptive, flashing, audio, or focus-stealing pranks | Breaks trust, accessibility, and deterministic verification. |
| Installer, partitioner, persistence, updater, Secure Boot, networking UI, telemetry, and broad hardware certification | High-risk work unrelated to the overnight live-ISO proof. |
| Hard sub-100 MB release gate | Reliability and the complete experience outrank an arbitrary byte ceiling; actual size must be disclosed. |

## Definition of Done

The overnight release is done when the final ISO hash has passed every claimed firmware/media lane with networking disabled, the UI and real terminal complete the documented demo, clean shutdown succeeds, evidence is retained, and the actual size and limitations are published. A source tree without a boot-tested ISO is not a release.

## Traceability

Phase mappings are populated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|

**Coverage:**
- v1 requirements: 33 total
- Mapped to phases: 0
- Unmapped: 33

---
*Requirements defined: 2026-08-25*
*Last updated: 2026-08-25 after initial definition*
