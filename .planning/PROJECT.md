# 300K Linux

## What This Is

300K Linux is a tiny, bootable x86_64 live Linux parody that drops the user into a desktop inspired by ChatGPT's familiar conversation interface. It is an offline comedy artifact: a usable local terminal presented as “ChatGPT Terminal,” a handful of basic utilities, and random absurd interactions—without OpenAI APIs, Codex, accounts, or cloud dependencies.

It is designed as a memorable demonstration of what an intensive AI-assisted build sprint can produce, not as an official OpenAI product or a general-purpose daily-driver distribution.

## Core Value

The ISO must reliably boot into an immediately recognizable, funny ChatGPT-like experience with a genuinely usable local terminal.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Produce a bootable x86_64 live ISO that can be launched in a standard virtual machine and written to USB media.
- [ ] Boot directly into a polished graphical shell whose layout and interaction language evoke ChatGPT while clearly identifying itself as an unofficial parody.
- [ ] Provide a real local shell through a themed “ChatGPT Terminal” application.
- [ ] Include deterministic and randomized comedy interactions that remain fun across repeated boots.
- [ ] Include a small set of useful local utilities without requiring network access or accounts.
- [ ] Provide a reproducible, documented build pipeline from source-controlled configuration and assets.
- [ ] Verify boot, UI startup, terminal usability, offline behavior, and final ISO integrity in an emulator or equivalent automated smoke test.
- [ ] Keep the image aggressively small, with 100 MB as a stretch target and any size tradeoff documented honestly.

### Out of Scope

- OpenAI API, ChatGPT account integration, Codex, or hosted AI inference — the running ISO is intentionally offline and secret-free.
- A new kernel, package ecosystem, or distribution built independently from an established base — impossible within the overnight delivery window and irrelevant to the core joke.
- A hard 100 MB release gate — boot reliability and the complete experience outrank an arbitrary byte ceiling.
- Persistent installation, disk partitioning, secure boot signing, and long-term update infrastructure — defer until the live artifact proves worthwhile.
- Pixel-perfect copying of proprietary assets or any claim of OpenAI endorsement — the product is a transformative parody with its own name and assets.
- Broad hardware certification — v1 targets common x86_64 virtual hardware first.

## Context

- The project began as a challenge to turn a very large, short-lived ChatGPT usage budget into a concrete and deliberately ridiculous Linux artifact within one night.
- The requested experience is “Linux with ChatGPT's own UI,” random hilarious material, a ChatGPT-styled terminal, and only basic applications.
- The user explicitly does not want Codex, OpenAI API integrations, or similar cloud functionality inside the ISO.
- The repository was empty at initialization and is already a Git worktree.
- The development host is Windows. Docker is installed, while WSL, xorriso, a native C compiler, and make are not currently available on the host PATH. QEMU 11.1.0 is installed outside PATH at `D:\\VM\\qemu`.
- The build should therefore be containerized where possible and avoid depending on an interactive Linux workstation.

## Constraints

- **Timeline**: Produce the strongest verifiable artifact possible overnight, with the first bootable result prioritized over optional polish.
- **Image size**: Aim near 100 MB, but treat it as a stretch target; measure and publish the actual result.
- **Runtime**: Fully local and offline after boot; never embed API keys, credentials, or user account data.
- **Compatibility**: Target x86_64 virtual machines; support both BIOS and UEFI when the chosen base/build system makes that reliable within the deadline.
- **Build host**: Windows with Docker available but no installed WSL or native Linux build chain.
- **Emulator**: Use the supplied QEMU installation at `D:\\VM\\qemu` for repeatable boot tests.
- **Quality**: A claimed ISO is not “done” until a boot smoke test reaches the graphical experience and the terminal can execute commands.
- **Identity**: Clearly label the distribution as an unofficial parody and use original project artwork.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Build a remix/live image from an established minimal Linux base | Reusing a proven boot stack is the only credible overnight path | — Pending base selection |
| Make v1 live-only | Removes installer, partitioning, persistence, and upgrade complexity | — Pending |
| Make all entertainment functionality offline | Preserves the joke without secrets, accounts, cost, or network fragility | — Pending |
| Prioritize boot reliability and experience over a strict 100 MB ceiling | A tiny file that does not reliably boot is not a deliverable | — Pending |
| Use original parody branding around a ChatGPT-inspired interaction model | Delivers the requested aesthetic while avoiding a false official-product claim | — Pending |
| Prefer a containerized build pipeline | Matches the available Windows host and improves reproducibility | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-08-25 after initialization*
