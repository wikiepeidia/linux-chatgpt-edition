# Feature Landscape

**Project:** 300K Linux  
**Domain:** Offline graphical x86_64 live-Linux parody/demo artifact  
**Researched:** 2026-08-25  
**Overall confidence:** MEDIUM — official sources verify the surrounding platform, brand, and accessibility constraints; the comedy and scope recommendations are product judgment that must be validated in the first bootable build.

## Product Thesis

The smallest convincing product is not a miniature general-purpose desktop and not a fake AI. It is one polished, full-screen conversation shell that boots without login, immediately identifies itself as **300K Linux**, accepts scripted local “chat” prompts, and can switch into a genuinely usable local terminal. The joke lands because the familiar conversation grammar is recognizable while every detail—name, artwork, copy, color, command set, and disclosure—is original and openly offline.

The terminal is the credibility anchor. The comedy composer must never execute arbitrary shell text; it routes only to local scripted responses and a short allowlist of slash commands. “300K Terminal” is a separate PTY-backed view in which normal shell commands really run. This boundary makes the artifact funny without lying about what it is or turning a joke prompt into an accidental command runner.

## Scope and Size Rules

- **P0** means the overnight ISO is not worth demonstrating without it.
- **P1** is polish only after boot, graphical startup, terminal, and shutdown are proven.
- **P2** is explicitly deferred beyond the overnight release.
- Size bands below are **incremental compressed payload estimates**, excluding the base kernel, initramfs, graphics stack, and any shared runtime already selected in `STACK.md`: Tiny `<100 KiB`, Small `100 KiB–1 MiB`, Medium `1–5 MiB`, Large `>5 MiB`.
- Prefer one UI process and data files. A calculator, scratchpad, system-info view, joke engine, and About view should be panels in that process, not separately packaged desktop applications.
- Text and vector-like code-drawn shapes are nearly free. Extra fonts, raster wallpapers, sound, video, browser engines, and duplicate GUI toolkits are not.
- The 100 MB goal is a stretch target, not permission to remove the real terminal, visible parody identity, keyboard navigation, or clean shutdown.

## The 90-Second Demo Contract

The release should support this exact path with the VM network adapter absent:

1. Boot the ISO and reach the graphical 300K shell without a login prompt or manual command.
2. Read an original greeting, an absurd boot/session status, and the visible “unofficial offline parody” disclosure.
3. Type `Do you have internet?`; receive a clearly labelled local scripted joke with no loading failure or account prompt.
4. Activate **Regenerate Nonsense**; receive a different response from the same deck.
5. Open **300K Terminal** by button or `Ctrl+Alt+T`; run `printf 'TERMINAL_OK\n'`, `pwd`, and `ls`; see real output and exit status behavior.
6. Run `300k credits` and receive an optional comedy line from the bundled local helper without altering normal shell semantics.
7. Return home with a documented keyboard path, open one basic tool, then select Shutdown and make QEMU halt cleanly.

If any step needs network, credentials, root login, hidden keystrokes, or presenter explanation, the MVP is not finished.

## Table Stakes

Missing any P0 row makes the artifact feel broken, deceptive, or unfinished.

| ID | Feature | Why Expected | Priority | Complexity | Size | Testable Acceptance |
|----|---------|--------------|----------|------------|------|---------------------|
| TS-01 | Boot directly to graphical shell | The artifact must be instantly legible as a product, not a build environment | P0 | Medium | Tiny feature payload | Fresh QEMU boot reaches the main 300K view with no login or typed command within the smoke-test timeout |
| TS-02 | Original, recognizable conversation shell | Conversation rail, response cards, composer, and action row communicate the requested chat-like interaction | P0 | Medium | Small | At 1024×768, the shell shows its identity, response area, composer, terminal affordance, and status/disclosure without clipping |
| TS-03 | Clear unofficial/offline identity | Users must not mistake the artifact for an OpenAI product or expect real inference | P0 | Low | Tiny | Boot screen, main shell, and About each state: “Unofficial offline parody. Not affiliated with or endorsed by OpenAI. No AI service is included.” |
| TS-04 | Real PTY-backed local terminal | A fake command parser destroys the core promise | P0 | Medium | Small–Medium, stack-dependent | In Terminal, `printf`, `pwd`, `ls`, pipelines, Ctrl+C, command-not-found, and exit codes behave as the bundled shell specifies |
| TS-05 | Strict chat/terminal boundary | Funny prose input must not become arbitrary code execution | P0 | Medium | Tiny | Entering `touch /tmp/composer-must-not-execute` in the chat composer yields a scripted response and does not create the file; the same command in Terminal does |
| TS-06 | Compact useful local command set | A Linux demo should do something after the joke | P0 | Low | Usually shared with base | Exact compiled commands are documented and smoke-tested; minimum user flow covers file listing/copying, text viewing/editing, search, process/system info, date, calculator, compression, and shutdown |
| TS-07 | Offline-first and secret-free behavior | Network/account failures would ruin the demo and violate scope | P0 | Low | Saves size | All P0 flows pass with QEMU networking disabled; UI contains no sign-in, API-key, update, telemetry, or remote-content affordance |
| TS-08 | Live-session lifecycle | A demo must start and stop cleanly, and ephemeral state must be honest | P0 | Low | Tiny | UI exposes Shutdown and Reboot; the user is told files are session-only; shutdown halts the guest cleanly |
| TS-09 | Minimal integrated tools drawer | “Basic apps” should exist without importing a desktop suite | P0 core / P1 breadth | Medium | Small | P0: Calculator and System Info work offline. P1: RAM-only Scratchpad and simple Home Files listing work and return to the main shell |
| TS-10 | Keyboard-complete operation | VM demos often begin before mouse integration works; keyboard access is also basic usability | P0 | Medium | Tiny | Tab/Shift+Tab traverse controls in a logical order, Enter/Space activate them, Escape closes dialogs, focus is visible, and no panel traps focus |
| TS-11 | Readable static mode | Comedy must not depend on flashing, motion, or disappearing text | P0 | Low | Tiny | Text meets 4.5:1 contrast (3:1 for large text); all jokes remain until dismissed; Reduced Chaos disables nonessential motion and unsolicited effects |
| TS-12 | Built-in Help/About | The interaction vocabulary and terminal escape path must be discoverable | P0 | Low | Tiny | `F1` or Help lists slash commands, terminal shortcut, return-home shortcut, offline status, ephemeral-state warning, version/build ID, and demo seed |

### Basic Utility Cut

The tools drawer should reuse the main shell rather than launch heavyweight programs:

| Tool | P0 Behavior | P1 Extension | Explicit Limit |
|------|-------------|--------------|----------------|
| Calculator | Evaluate bounded arithmetic through a safe arithmetic parser or bundled calculator applet | History for the current session | Never pass expressions to a shell evaluator |
| System Info | Show kernel, architecture, uptime, memory, hostname, build ID, and ISO version | Copyable diagnostic block | No fabricated “AI model” hardware values inside the factual block |
| Scratchpad | Defer if it threatens first boot | Plain text, manual save to the live home overlay, clear “lost on reboot” label | No rich text, cloud sync, or persistence promise |
| Home Files | Defer if it needs a new toolkit | List the live user’s home directory and offer “Open Terminal Here” | No privileged paths, drag/drop, thumbnails, mounting, or destructive file management in v1 |

BusyBox can supply many expected command-line utilities from one binary, but its official documentation warns that applets often expose fewer flags than GNU equivalents. The UI and help must advertise only commands and options actually compiled into the image.

## Differentiators

These features make the image memorable. Only the first four belong in the MVP.

| ID | Feature | Value Proposition | Priority | Complexity | Size | Testable Acceptance |
|----|---------|-------------------|----------|------------|------|---------------------|
| DF-01 | Local scripted prompt router | Gives the composer immediate “assistant” behavior without a model, network, or secret | P0 | Low | Tiny | Case-insensitive rules cover at least identity, internet, credits, capability, help, and unknown input; each response is marked `Local scripted reply` |
| DF-02 | Seeded shuffle-bag joke engine | Feels varied across interactions without annoying immediate repeats; fixed seeds make demos reproducible | P0 | Medium | Tiny | Same seed produces the same first 10 choices; different seed changes at least one; no line repeats within a deck until that deck is exhausted |
| DF-03 | Deliberate-action comedy | Random absurdity appears during normal use without interrupting typing or reading | P0 | Low | Tiny | Events occur only after submit, regenerate, tool launch, or explicit Chaos action; no background timer can steal focus or cover terminal output |
| DF-04 | `300k` terminal companion | Lets the joke survive in a real shell while keeping commands honest | P0 | Low | Tiny | `300k help`, `credits`, `why`, `fortune`, `seed`, and `about` work as ordinary local commands and return documented exit codes |
| DF-05 | Regenerate and reaction actions | Evokes conversation-product grammar and creates a repeatable audience interaction | P1 | Low | Tiny | Regenerate advances the appropriate deck; reaction buttons give short original feedback and do not transmit or persist data |
| DF-06 | Absurd but truthful status chips | Communicates constraints as comedy: local, ephemeral, zero cloud | P1 | Low | Tiny | Status always agrees with reality; examples include `Inference: locally scripted`, `Network: not required`, `Memory: until reboot` |
| DF-07 | Boot micro-theater | Makes the first seconds screenshot-worthy | P1 | Low | Tiny | 3–5 short original messages appear during real startup progress, never delay boot, and obey Reduced Chaos |
| DF-08 | Demo seed/replay token | Presenter can reproduce a strong sequence while normal boots still vary | P1 | Medium | Tiny | About displays the session seed; a documented boot parameter or config override selects a known seed for automated tests |
| DF-09 | Session “history” as fictional prompts | A few original sidebar titles make the UI recognizable before first input | P1 | Low | Tiny | Entries are clearly bundled examples, reset with the live session, and never imply access to user history |
| DF-10 | Optional Chaos button | Gives the audience an explicit route to the wild material | P2 | Low | Tiny | Chaos is opt-in, reversible, non-destructive, and cannot flash, play sound, move focus, or execute commands |

## Comedy System Specification

### Minimum Content Corpus

Ship at least **40 short, original lines** split across at least five decks. Plain UTF-8 text should remain well below 20 KiB compressed.

| Deck | Minimum | Trigger | Tone |
|------|---------|---------|------|
| Boot/status | 8 | Startup milestones and explicit refresh | Confident machine bureaucracy |
| Intent replies | 18 | Six prompt intents, at least three variants each | Helpful setup, absurd local limitation |
| Generic fallback | 6 | Unmatched composer text | Admits it is scripted; never insults the user |
| Terminal companion | 5 | Explicit `300k` subcommands | Linux jokes that do not impersonate shell output |
| Reactions/shutdown | 3 | Button or lifecycle action | Brief, readable, reversible |

Recommended prompt intents are `identity`, `internet`, `credits`, `capability`, `help`, and `unknown`. The router should be simple keyword/regular-expression matching with deterministic precedence. It is not an NLP project.

### Original Content Direction

These examples establish the voice; implementation should expand them with newly authored lines rather than copied memes, screenshots, or quotes:

- Boot: “Compressing confidence into squashfs…”
- Boot: “Mounting `/dev/overthinking`…”
- Boot: “Starting absolutely no cloud services…”
- Identity: “I’m a shell wearing a conversation interface. Please lower your benchmarks.”
- Internet: “No. I can browse `/usr/bin`; the wider web and I are taking space.”
- Credits: “All 300,000 credits are represented by this one extremely employed cursor.”
- Unknown: “This answer was generated locally using advanced confidence and one text file.”
- Terminal aside: “The command returned 127. My confidence remains suspiciously high.”
- Shutdown: “Unsaved hallucinations will now be responsibly forgotten.”

### Randomness Rules

Use a shuffled deck (“shuffle bag”) per content category, not independent random selection. Apple’s official `GKShuffledDistribution` documentation describes the same general mechanic: each value is used before it repeats, avoiding visible streaks while remaining pseudorandom. The implementation need not use Apple code; it should reproduce the pattern locally with a tiny PRNG.

Rules:

1. Seed once per session from an available local source; accept a fixed test/demo seed.
2. Shuffle each deck independently and consume sequentially.
3. Never repeat the last visible line when reshuffling a deck boundary.
4. Keep randomness cosmetic. It must not change command execution, exit codes, files, boot success, or shutdown behavior.
5. Do not fire idle popups. Random events attach to deliberate user actions and never steal keyboard focus.
6. Log the seed and chosen content IDs—not private user text—to an in-memory diagnostic view when debug mode is enabled.

### Humor Safety Contract

- Aim jokes at the fictional machine, the build budget, local limitations, and software bureaucracy—not at the user’s identity, ability, or appearance.
- Never simulate data loss, malware, credential theft, security compromise, or a failed boot as a prank.
- Never run a command, delete a file, change settings, or open a privileged shell for a punchline.
- Keep shell output and comedy visually distinct. Prefix optional asides with `[300K aside]`; never inject them into command stdout/stderr.
- No autoplay audio, flashing, forced shaking, rapidly moving windows, or text that vanishes before it can be read.
- Store all content locally in reviewable data files so offensive or confusing lines can be removed without changing code.

## Original Visual and Interaction Direction

Recognition should come from interaction grammar, not copied trade dress:

- **Name:** ship as **300K Linux**. Label the terminal **300K Terminal** or **300K Local Terminal**, not as an official “ChatGPT Terminal.”
- **Mark:** create an original `300K` speech-card/terminal-caret symbol. Do not use or imitate the OpenAI Blossom, wordmark, app icon, or OpenAI Sans.
- **Palette:** use a distinct “burnt credits” palette—charcoal/paper foundations with amber, electric cyan, or magenta accents—then measure contrast. Avoid cloning exact product colors.
- **Layout:** use a slim “Previous Bad Ideas” rail, a centered response stack, a bottom composer, and a factual status strip. Offset cards, terminal scan-line details, and a visible credit meter make the layout its own.
- **Language:** buttons such as **Regenerate Nonsense**, **Open Real Terminal**, and **Clear This Timeline** communicate the joke while remaining explicit about behavior.
- **Assets:** favor code-drawn geometry, a single openly licensed UI/mono font family already present in the base, and a tiny original wallpaper. Record licenses for every bundled third-party asset.

OpenAI’s current official brand guidance says its names, logos, icons, and design elements are protected marks and warns against implied endorsement, confusing sponsorship, incorporating its logo into another brand, or creating a similar logo. This document therefore recommends original naming/artwork plus a prominent disclosure. That is a risk-reduction product recommendation, **not legal advice or a legal conclusion about parody**; a public/commercial release may warrant qualified review.

## Accessibility and Basic Usability Contract

Treat these as acceptance requirements, not optional polish:

- Every mouse action has a keyboard path. Suggested global shortcuts: `Ctrl+Alt+T` toggles Terminal, `Ctrl+Alt+H` returns Home, and `F1` opens Help.
- When the embedded terminal captures keys, a persistent hint explains how to leave it; that shortcut must work even after a full-screen terminal program exits or misbehaves.
- Use visible focus rings and a logical Tab order. Do not remove focus styling.
- Meet WCAG 2.2 contrast guidance: at least 4.5:1 for ordinary text and 3:1 for large text; also verify focus indicators and meaningful non-text controls.
- Support 1024×768 first and remain usable at 800×600 with scrolling rather than clipped actions.
- Default body and terminal text should be comfortably legible at VM scaling; provide one-step text-size increase if the selected toolkit makes it cheap.
- Reduced Chaos must disable nonessential transitions, animated boot jokes after startup, and random visual events. No essential action may depend on motion or color alone.
- Do not auto-dismiss substantive responses or error messages. If any moving/auto-updating content lasts more than five seconds, provide one global stop control.
- Dialogs close with Escape, restore focus to their opener, and never cover the only shutdown or terminal-exit control.

These choices follow W3C guidance on keyboard operation, avoiding keyboard traps, visible focus, contrast, pausing moving content, and disabling nonessential interaction-triggered motion.

## Anti-Features

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|--------------------|
| OpenAI API, local LLM, account login, Codex, or cloud inference | Violates the offline brief, introduces secrets/failure modes, and explodes scope/size | Local rule router plus transparent `Local scripted reply` label |
| Arbitrary shell execution from the chat composer | Turns a joke interface into a dangerous and ambiguous command runner | Fixed slash-command allowlist; real commands only in the clearly separated terminal |
| Fake terminal | Savvy viewers will discover it immediately | PTY-backed shell with normal command, signal, pipeline, and exit-code behavior |
| Pixel-perfect ChatGPT clone or OpenAI marks | Creates confusion and brand risk; proprietary assets are unnecessary | Original 300K identity and artwork; evoke only broad conversation interaction grammar |
| “ChatGPT,” “GPT,” or model names in the shipped product/app title | Can imply an official relationship and conflicts with current brand guidance | 300K Linux, 300K Shell, and 300K Terminal; mention inspiration descriptively only where appropriate |
| Chromium/Electron, full office suite, browser, media player, or second GUI toolkit | Likely consumes more space and integration time than the entire joke layer | One native/lightweight shell plus compact command-line utilities and integrated panels |
| Installer, partitioner, persistence wizard, updater, or package-store UI | High-risk work unrelated to the overnight live demo | Live-only session with an honest ephemeral-state notice |
| Network manager, remote services, telemetry, ads, or update checks | Adds attack surface and contradicts “fully offline” | No-network default; local version/build information only |
| Destructive or deceptive pranks | Can lose trust or data and make automated verification unreliable | Cosmetic, reversible jokes triggered by deliberate actions |
| Hijacking `sudo`, `rm`, command-not-found, stdout, or exit codes for jokes | Breaks expected Linux semantics and may hide real errors | Optional `300k` helper and visually separate asides |
| Copied memes, screenshots, logos, voices, fonts, or long quotations | Copyright/licensing burden and a less original artifact | Short original lines, original graphics, documented open licenses |
| Autoplay sound, flashing, focus-stealing popups, or endless animation | Bad VM demo behavior and accessibility failure | Silent by default, static responses, Reduced Chaos, deliberate-action effects |
| General-purpose hardware support promise | Overnight scope cannot validate it | Explicit x86_64 QEMU-first compatibility statement |

## Feature Dependencies

```text
Bootable x86_64 live image
  -> live-user creation + autologin
    -> graphics/input startup
      -> 300K conversation shell (TS-01/02)
        -> identity/disclosure + Help (TS-03/12)
        -> chat/terminal execution boundary (TS-05)
        -> local prompt router (DF-01)
          -> reviewed content decks
            -> seeded shuffle bag (DF-02)
              -> Regenerate, reactions, status, demo seed (DF-05/06/08)
        -> PTY + shell + monospace font (TS-04)
          -> tested compact applet set (TS-06)
            -> optional 300k helper (DF-04)
        -> integrated tools drawer (TS-09)
        -> keyboard/focus/contrast/motion controls (TS-10/11)
      -> privileged but narrow reboot/shutdown path (TS-08)

No-network runtime policy (TS-07) constrains every branch.
QEMU smoke automation verifies the complete path, not isolated files.
```

## Aggressively Scoped MVP Recommendation

### P0 — Ship Tonight

1. Boot/autologin directly into one full-screen 300K shell.
2. Original identity, one polished responsive layout, and visible unofficial/offline disclosure.
3. Separate real terminal with a documented keyboard toggle and return-home path.
4. Local prompt router with six intents, at least 40 reviewed lines across five decks, and seeded no-repeat selection.
5. `300k` helper with the six small subcommands listed above.
6. Calculator, factual System Info, Help/About, Reduced Chaos, Reboot, and Shutdown.
7. Keyboard/focus/contrast checks plus an offline QEMU end-to-end smoke test.

### P1 — Add Only After P0 Passes Twice From a Clean Build

- RAM-only Scratchpad and simple Home Files listing.
- Regenerate/reaction microinteractions and fictional bundled history titles.
- Boot micro-theater, additional content decks, one original tiny wallpaper, and visible session seed.
- Mouse/clipboard polish if it adds no fragile dependency.

### P2 — Defer

- Installer, persistence, package management, Wi-Fi/network UI, browser, media stack, voice, local model, multi-user support, broad hardware certification, and theme marketplace.

### Deletion Order Under Deadline or Size Pressure

Drop in this order:

1. Scratchpad and Home Files.
2. Clipboard/reaction polish and fictional history.
3. Wallpaper and boot animation.
4. Extra joke decks beyond the 40-line minimum.

Never drop the boot-to-shell path, real terminal, composer/terminal boundary, offline behavior, visible parody disclosure, Help/escape path, readable keyboard operation, or clean shutdown.

## Acceptance Matrix for Requirements

| Requirement Seed | Verification |
|------------------|--------------|
| UI boots unattended | Cold-boot QEMU from ISO; automated timeout detects the graphical shell marker and captures a screenshot |
| Composer is local and safe | With no NIC, submit all six intent prompts; assert responses appear; submit a shell-looking string and assert no file/process side effect |
| Terminal is real | Run `printf`, pipeline, file creation, failing command, `$?`, and Ctrl+C; assert expected output/state |
| Random comedy is varied and repeatable | Run fixed seed twice and compare first 10 content IDs; run another seed; exhaust a deck and verify no early repeat |
| Offline and secret-free | Boot with QEMU `-nic none`; scan source/image configuration for credential placeholders and remote URLs; observe no account/update error |
| Basic tools work | Calculate a known expression; compare displayed factual system values with shell output; open/close each shipped panel by keyboard |
| Accessible control flow | Complete the 90-second demo with keyboard only; verify visible focus, Escape behavior, terminal escape hint, contrast, and Reduced Chaos |
| Identity is original and clear | Asset inventory contains no OpenAI logo/wordmark/font; shipped titles use 300K naming; disclosure is visible on boot/main/About |
| Session lifecycle is honest | Create a live-session file, show the ephemeral warning, shut down cleanly, reboot, and confirm persistence was not promised or silently retained |
| Size claim is honest | Build publishes ISO byte size and a compressed payload breakdown; failure to hit 100 MB is documented rather than hidden |

## Sources

Research-provider confidence is **MEDIUM** after verification against current official pages. Product-specific recommendations remain MEDIUM until user testing and the first ISO smoke run.

- [OpenAI Design Guidelines](https://openai.com/brand/) — official mark, logo, prominence, and endorsement guidance.
- [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/) — official cross-check that name/logo usage is governed by the brand guidelines.
- [Web Content Accessibility Guidelines (WCAG) 2.2](https://www.w3.org/TR/WCAG22/) — official keyboard, focus, contrast, motion, and moving-content criteria.
- [W3C: Understanding Keyboard](https://www.w3.org/WAI/WCAG22/Understanding/keyboard) and [No Keyboard Trap](https://www.w3.org/WAI/WCAG22/Understanding/no-keyboard-trap.html) — keyboard behavior and escape-path rationale.
- [W3C: Pause, Stop, Hide](https://www.w3.org/WAI/WCAG22/Understanding/pause-stop-hide.html) and [Animation from Interactions](https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions.html) — controls for moving and nonessential animated content.
- [BusyBox official command documentation](https://busybox.net/downloads/BusyBox.html) and [BusyBox FAQ](https://busybox.net/FAQ.html) — compact applet model and capability caveats.
- [Apple GameplayKit: GKShuffledDistribution](https://developer.apple.com/documentation/gameplaykit/gkshuffleddistribution) — primary documentation for no-repeat shuffled random selection as a general interaction pattern.
- [Debian Live Manual](https://live-team.pages.debian.net/live-manual/html/live-manual.en.html) — live-user/autologin, read-only image with writable overlay, and shutdown/lifecycle behavior.

## Confidence and Open Questions

| Area | Confidence | Remaining Validation |
|------|------------|----------------------|
| Minimum experience and demo path | HIGH | Confirm presenter preference after first visual build |
| Offline scripted comedy mechanics | MEDIUM | Tune hit rate, line quality, and deck size through a live demo |
| Real terminal/basic utility expectations | HIGH | Verify the exact selected shell and compiled applet flags |
| Accessibility contract | HIGH | Measure actual palette contrast and run keyboard-only QEMU test |
| Incremental size estimates | LOW | Measure only after the stack/base build exists; runtime choice dominates |
| Trademark/parody risk reduction | MEDIUM | Guidance is current and official, but this is not legal advice; review public release context if needed |

Open questions should not block P0: whether Scratchpad/Home Files fit P1, whether normal boots use a time-derived or entropy-derived seed, and which accent palette survives actual framebuffer/font rendering. Resolve them only after the first bootable graphical ISO proves the core flow.
