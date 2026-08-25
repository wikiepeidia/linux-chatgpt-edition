# Project Research Summary

**Project:** 300K Linux  
**Domain:** Tiny offline graphical x86_64 live-Linux parody ISO  
**Researched:** 2026-08-25  
**Confidence:** MEDIUM

## Executive Summary

300K Linux should be built as a product layer on a proven live distribution, not as a new distribution stack. The research strongly favors an **Alpine Linux 3.24.1 x86_64 diskless ISO** derived from Alpine's `profile_virt`, built with a pinned `3.24-stable` aports commit in a pinned Linux/amd64 container. The runtime should use `linux-virt`, OpenRC, Xorg, Openbox, Tcl/Tk, xterm, and BusyBox. Alpine's normal `mkimage` path already supplies the right boot-media primitives: a signed offline APK repository, an apkovl-restored RAM-backed system, ISOLINUX for BIOS, GRUB for x86_64 UEFI, and hybrid ISO metadata.

The smallest convincing product is one full-screen, original conversation-style shell that boots without login, visibly says it is an unofficial offline parody, returns transparent local scripted jokes, and opens a **real** shell in a themed xterm. Comedy must come from reviewed UTF-8 catalogs and a deterministic seeded shuffle-bag, never from remote inference or from executing composer text. Calculator, factual System Info, Help/About, keyboard navigation, Reduced Chaos, reboot, and shutdown complete the minimum useful experience. Scratchpad, file browsing, wallpaper, boot theater, reactions, and extra joke decks wait until the core path passes twice from clean builds.

The main risks are environmental and integrational rather than conceptual: Docker's Linux daemon was not running during research; the exact graphical APK closure and ISO size remain unmeasured; apkovl/package/signing mistakes can yield an offline ISO whose packages are present but not installed; and QEMU process state alone cannot prove application readiness. Mitigate these with hard phase gates, a Linux-owned build volume, pinned repositories and signing inputs, ordered serial milestones, `-nic none`, real PTY tests, QMP screenshots, fresh UEFI variables, and a saved last-known-good ISO at every gate. **100 MB is a stretch metric, not a release gate**; a larger, fully working and honestly measured image wins over a broken sub-100 MB artifact.

## Resolved Decisions

The four research tracks agree on the core design. Where they exposed alternatives or different test defaults, use these resolutions:

| Question | Decision | Resolution rationale |
|---|---|---|
| Base distribution | Alpine Linux `3.24.1`, x86_64, `linux-virt` | The official virt image is about 66M and Alpine provides the most direct maintained hybrid-ISO workflow for the overnight constraint. Tiny Core and SliTaz are smaller but add remaster/UEFI or stability risk; Debian, Arch, Fedora, and Buildroot cost more time or space. |
| Image builder | `aports` `3.24-stable` `mkimage.sh`, with the exact commit recorded | Do not use moving `master`, `edge`, or `latest-stable`; align profile source with v3.24 main/community repositories. |
| Runtime composition | Official APKs in the ISO-local signed repository; `/etc/apk/world`, users, startup, authored scripts, catalogs, and small assets in the apkovl | This is the shortest reliable v1 seam. Packaging authored files into a project APK is useful post-MVP hardening, not required before first release. Never copy third-party libraries into the overlay. |
| UI | One Tcl/Tk `wish` process under Openbox | It gives a small native GUI without Chromium, WebKit, Python, Node, a local web server, or a second toolkit. |
| Terminal | A fixed launcher into themed `xterm -e /bin/ash -l` | xterm already supplies a real PTY. Do not build a pipe-based or fake terminal overnight. Composer text is never interpolated into the terminal command. |
| Display device | `virtio-vga` primary; QEMU standard VGA fallback | Keep one fixed, tested device contract. If modesetting/Mesa blocks the graphical gate, fall back to standard VGA before adding drivers or firmware. |
| VM memory | Use 1 GiB for the initial acceptance matrix; test 512 MiB only after measuring tmpfs and RAM use | The compressed ISO size does not predict Alpine diskless root usage. A 512 MiB command is a later optimization target, not the first reliability baseline. |
| Firmware | BIOS and non-Secure-Boot UEFI are release targets; Secure Boot is out of scope | Both paths are supported by Alpine's builder, but each claim requires its own QEMU lane. A BIOS-only artifact may be published only as an explicitly degraded fallback. |
| USB wording | Claim USB-hybrid support only after raw-disk boot plus xorriso system-area inspection | Optical El Torito success does not prove that the same bytes boot when written as a disk. |
| Branding | Ship as **300K Linux**, with **300K Terminal** and original art; describe the interaction as ChatGPT-inspired and show the offline/unofficial disclosure | Recognition should come from conversation grammar, not copied OpenAI logos, fonts, icons, or a claim of affiliation. |
| Size | Measure exact bytes and MiB; preserve the last complete green image even above 100 MB | The roughly 66M virt baseline leaves an unverified graphics budget. Do not pre-announce a final size. |

## Delivery Contract

### Hard requirements for the first complete release

- A source-built x86_64 live ISO that cold-boots in QEMU without a login or typed command.
- A Linux-container build pipeline pinned to Alpine `3.24.1`, a builder digest, an exact `3.24-stable` aports commit, v3.24 `main` and `community`, a fixed build epoch, and a persisted private signing key that never enters Git or the ISO.
- Offline diskless boot from the ISO-local signed APK repository and apkovl, verified with `-nic none`.
- An unprivileged live user, bounded tty1 `startx` startup, tty2 rescue path, readable X input/video/font support, and a terminal fallback on UI failure.
- A polished, original 300K conversation shell at 1024x768, still usable at 800x600, with visible unofficial/offline identity.
- A strict composer/terminal boundary: composer prompts produce only structured local replies; the separate 300K Terminal runs a normal BusyBox `ash` session through a real PTY.
- At least 40 reviewed original comedy lines across boot/status, six intent categories, fallback, terminal companion, and lifecycle/reaction decks.
- Deterministic seed injection, no-repeat shuffle-bags, a known startup gag, and cosmetic randomness that cannot alter commands, files, boot, or shutdown.
- Calculator, factual System Info, Help/About, Reduced Chaos, keyboard-complete navigation, visible focus, and clean reboot/shutdown.
- Ordered guest milestones and release evidence proving offline root, X, UI, terminal execution, BIOS, UEFI, artifact integrity, and the exact ISO tested.
- Output artifacts: uniquely identified ISO, SHA-256, byte size, resolved package/checksum manifest, build lock, xorriso boot report, size report, serial logs, and screenshots.

### Stretch goals

- ISO at or near 100 MB without regressing any hard requirement.
- Stable boot at 512 MiB after measurement; initial acceptance remains 1 GiB.
- RAM-only Scratchpad and Home Files panel.
- Regenerate/reaction polish, fictional bundled history, visible replay seed, boot micro-theater, tiny original wallpaper, and more joke decks.
- Clipboard and mouse polish where they add no new fragile dependency.
- A second clean build with byte-identical output; input-level reproducibility and a published final checksum remain mandatory even if byte identity is not reached overnight.

### Immediate blockers and unknowns

- **Docker runtime:** the client is installed, but the Linux Docker daemon was not running during research. No image work starts until `docker version`, Linux `OSType`, and an `alpine:3.24.1` amd64 container pass.
- **First-build network:** the builder image, pinned aports revision, and v3.24 APKs must be fetched before the runtime can be proven offline.
- **Unmeasured closure:** final Tcl/Tk, Xorg, Mesa/input, Openbox, xterm, and font dependencies determine both ISO size and live tmpfs use.
- **Unverified Windows QMP lane:** QMP `screendump` with the selected Windows display/headless flags needs a focused spike.
- **Unverified media matrix:** BIOS/UEFI optical and raw-disk boots must be run against the final bytes before making corresponding claims.

### Fallback ladder

1. If Docker Desktop cannot provide Linux containers, use a small Alpine build VM under the installed QEMU and keep the same aports profile; do not switch distributions.
2. If bind mounts break modes, ownership, or symlinks, build in a Linux-owned Docker volume and copy only final artifacts to `dist/`.
3. If the custom profile does not boot, return to upstream `profile_virt`, add only serial markers and the minimal apkovl, and reintroduce package groups one at a time.
4. If graphics fail, use guarded tty1 `startx`, standard VGA, one font, Openbox, and xterm; remove compositing and polish before adding drivers.
5. If the custom GUI is late, preserve the graphical spine and real themed xterm, but do not call the core product complete until a minimal conversation shell and disclosure reach `UI_READY`.
6. If UEFI remains red after a bounded investigation, preserve the BIOS-green ISO and label it BIOS/QEMU-only; do not claim UEFI or Secure Boot.
7. If raw-disk boot remains unproven, call the result a bootable CD ISO rather than USB-tested.
8. If QMP visual automation is blocked, execute the same gates manually and retain serial logs and screenshots; never substitute process existence for readiness.
9. If the image exceeds 100 MB, ship the last fully green image with its measured size and size ledger.

## Key Findings

### Recommended Stack

Build inside `alpine:3.24.1` for `linux/amd64`, pinned by the researched multi-platform digest `sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b`. Resolve and record the exact `3.24-stable` aports commit, runtime APK versions/checksums, and amd64 manifest digest during Phase 1. Use Alpine's profile and overlay hooks rather than mutating a downloaded ISO after construction.

**Core technologies:**

- **Alpine Linux 3.24.1 + `linux-virt`:** small, supported runtime and VM-focused kernel.
- **aports `3.24-stable` `mkimage.sh`:** official custom-image pipeline with dependency resolution, boot repository, apkovl, BIOS, UEFI, and hybrid ISO support.
- **Pinned Alpine Linux/amd64 builder container:** reproducible Linux filesystem semantics on the Windows host.
- **`abuild`, `alpine-conf`, `grub`, `grub-efi`, `mtools`, `squashfs-tools`, `syslinux`, `xorriso`, and `git`:** exact image-construction toolchain.
- **Alpine apkovl + `/etc/apk/world`:** deterministic users, services, configuration, authored product files, and boot-time installation from local media.
- **OpenRC + guarded tty1 autologin + `startx`:** smallest diagnosable graphical startup path without a display manager.
- **Xorg, eudev, libinput, Mesa Gallium, Openbox, xterm, and one Terminus font package:** first reliable QEMU graphical spine; prune only after both firmware lanes stay green.
- **Tcl/Tk 8.6 family:** native one-process conversation shell, safe tools panels, and testable content state machine without a browser stack.
- **BusyBox `ash` and applets:** real compact Linux terminal and utility base; document only applet flags actually compiled into the image.
- **QEMU 11.1.0 at `D:\VM\qemu`:** BIOS/UEFI, offline, serial, QMP, screenshot, shutdown, and raw-media verification. Use non-Secure-Boot EDK2 code and a fresh copied vars file for each UEFI run.

Do not add Chromium, Firefox, WebKitGTK, Electron, Node.js, Python, XFCE/LXQt, a display manager, NetworkManager, audio, office/media suites, broad firmware collections, or multiple GUI toolkits to v1.

### Expected Features

**Must have (P0/table stakes):**

- Direct boot to the graphical 300K shell, with an original recognizable conversation layout and persistent unofficial/offline disclosure.
- A real PTY-backed local terminal, strict chat/terminal execution separation, and a documented `Ctrl+Alt+T`/return-home path.
- Transparent local prompt routing for identity, internet, credits, capability, help, and unknown input, with every response identified as locally scripted.
- A fixed-seed, no-immediate-repeat comedy engine and at least 40 short reviewed lines in immutable catalogs.
- A small documented BusyBox command set plus `300k help|credits|why|fortune|seed|about` as an ordinary local helper.
- Calculator, factual System Info, Help/About, Reduced Chaos, reboot, shutdown, and an honest ephemeral-session warning.
- Keyboard-only completion, visible focus, readable contrast, no keyboard trap, no focus-stealing randomness, and no substantive auto-dismissed text.
- An offline 90-second demo that reaches the UI, answers a local prompt, regenerates a joke, runs real terminal commands, opens one tool, and halts cleanly.

**Should have after P0 passes twice:**

- Regenerate/reaction microinteractions, truthful absurd status chips, bundled fictional history, and a visible session/replay seed.
- RAM-only Scratchpad and basic Home Files listing implemented as panels in the existing Tk process.
- Short boot micro-theater, more catalog content, one tiny original wallpaper, and cheap mouse/clipboard polish.

**Defer to v2+:**

- Installer, persistent storage, package-store UI, updater, disk partitioning, multi-user support, Secure Boot, and broad physical-hardware certification.
- Wi-Fi/network UI, remote services, browser, media/audio stack, voice, local LLM, API/account integration, Codex, or telemetry.
- Custom terminal emulation, a full desktop environment, second GUI toolkit, theme marketplace, or destructive/deceptive pranks.

### Architecture Approach

The system is a thin deterministic product layer over Alpine's diskless runtime. The immutable ISO contains the generated BIOS/UEFI boot chain, kernel/initramfs/modloop, signed local APK repository, and `300k.apkovl.tar.gz`. Early userspace restores the overlay and installs `/etc/apk/world` into a RAM-backed root. OpenRC prepares devices and consoles; tty1 autologins one unprivileged user; a bounded launcher runs Xorg, Openbox, and the Tcl/Tk shell; xterm launches `/bin/ash -l` through a real PTY. Runtime writes stay under the disposable home, `/run`, `/tmp`, or `/var/log`, never beside read-only assets.

**Major components:**

1. **PowerShell host wrapper** — validates Docker/QEMU, normalizes Windows paths, invokes build/test targets, and propagates failures.
2. **Pinned builder container** — owns Linux filesystem semantics, aports, signing, APK cache, `mkimage`, and deterministic artifact generation.
3. **Project ISO profile** — derives from `profile_virt` and selects kernel, package closure, repositories, boot configuration, and overlay generator.
4. **Apkovl generator** — creates the live user, `/etc/apk/world`, startup/service configuration, authored scripts, catalogs, theme, and permissions.
5. **Session supervisor** — owns one bounded `startx` path, serial/log milestones, cleanup, tty2 rescue, and terminal fallback.
6. **Openbox session** — places the UI, binds the constant terminal launcher, and keeps an emergency menu path.
7. **Tcl/Tk UI and pure content engine** — render transcript/tools and map normalized prompts plus a seed to structured reply/effect IDs without shell or network access.
8. **Fixed terminal launcher** — executes a constant xterm/ash argv and never consumes composer text.
9. **Guest observability contract** — emits stable ordered stage/result markers and preserves human-readable diagnostics separately.
10. **QEMU smoke runner** — owns VM lifecycle, TCG baseline, timeouts, `-nic none`, serial logs, QMP interaction/screenshots, fresh UEFI vars, and exact artifact hashes.

**Key patterns:**

- Build all authored changes into the profile or overlay before ISO assembly; never perform post-build ISO surgery.
- Treat human-readable logs and stable machine milestones as separate interfaces.
- Test the content engine headlessly under `tclsh` with fixed seeds before booting a VM.
- Keep catalog records declarative (`id`, category, weight, trigger, effect, text); effects come from a fixed whitelist and cannot name executables.
- Save a last-known-good ISO at every boot, offline, graphics, terminal, firmware, and size gate.
- Optimize only after a complete integrated baseline, one package/asset group at a time, followed by the full smoke matrix.

### Critical Pitfalls

1. **The builder is not actually a Linux environment** — preflight the Docker server, Linux `OSType`, amd64 container, line endings, and artifact path before diagnosing Alpine. Keep build work on a Linux-owned volume.
2. **aports, repositories, and signing inputs drift** — pin one `3.24-stable` commit and only v3.24 main/community; persist but never commit the private key; reject `edge`, mismatched branches, and `--allow-untrusted`.
3. **Packages are carried but not installed, or the apkovl is ignored** — put every runtime package in both the media repository selection and apkovl `/etc/apk/world`; verify archive name, root paths, modes, services, `.boot_repository`, and a `-nic none` clean boot.
4. **Cached build sections hide changes or mix kernel artifacts** — key workdirs by aports/profile/repository hashes, never hand-copy kernel/initramfs/modloop, and make one clean release build.
5. **BIOS optical boot is overclaimed as UEFI or USB support** — inspect El Torito/system-area records and separately test BIOS/UEFI plus optical/raw-disk paths with fresh EDK2 vars.
6. **Diskless runtime exhausts RAM** — start acceptance at 1 GiB and record ISO size, installed size, root tmpfs use, and free memory separately before attempting 512 MiB.
7. **Graphical autostart races, loops, or runs as root** — choose one guarded tty1 owner, run as the live user, bound retries, keep tty2 and an xterm fallback, and fix one VGA contract.
8. **The terminal is fake** — xterm is the v1 implementation; verify `tty`, `test -t`, ANSI output, Ctrl-C, resize, pipelines, failing commands, and exit codes.
9. **Size trimming removes required functionality** — maintain a subsystem size ledger and rerun the complete matrix after each removal; never sacrifice boot, input, font, EFI, UI, terminal, or shutdown for 100 MB.
10. **Smoke tests prove only that QEMU runs** — pass only on ordered guest markers plus visual evidence and terminal behavior; use `-nic none`, bounded timeouts, distinct BIOS/UEFI results, and the tested ISO hash.

## Implications for Roadmap

Use six gated phases. Every phase must preserve a uniquely hashed last-known-good artifact or fast local test result; a later phase cannot redefine an earlier proof.

### Phase 1: Reproducible Build Foundation

**Rationale:** Every later task depends on a working Linux builder and immutable version seams. Docker/NTFS/signing failures otherwise masquerade as Alpine bugs.  
**Delivers:** Docker/QEMU preflight; pinned builder digest; exact aports revision; v3.24 repositories; persistent ignored signing/cache volume; LF/mode validation; `build.ps1`; build lock; deterministic epoch; artifact directories and manifest schema.  
**Addresses:** reproducible documented pipeline, secret-free release, exact artifact identity.  
**Avoids:** Pitfalls 1, 2, 5, and 19.  
**Exit gate:** Linux amd64 container runs; QEMU/EDK2 paths resolve; a minimal profile build emits a uniquely named ISO, manifest, checksum, and xorriso report.  
**Research flag:** Standard official pattern; skip broad research. Verify the resolved digest/commit/package sources during implementation.

### Phase 2: Offline Diskless Boot Core

**Rationale:** Prove the boot/media/package contract before graphics or product code obscures failures.  
**Delivers:** `profile_virt`-derived `mkimg.300k.sh`; `linux-virt`; signed embedded APK repository; generated apkovl with `/etc/apk/world`; clean RAM-backed boot; serial logging; `ROOTFS_READY`; BIOS optical smoke; initial hybrid metadata inspection.  
**Addresses:** TS-01 foundation, TS-07 offline behavior, TS-08 lifecycle foundation.  
**Avoids:** Pitfalls 3, 4, 5, 8, 9, and 20.  
**Exit gate:** A clean 1 GiB QEMU boot with `-nic none` reaches `ROOTFS_READY`, proves required packages installed from local media, and leaves a rescue console.  
**Research flag:** Existing research is sufficient; prefer a focused implementation spike against the pinned aports source to more desk research.

### Phase 3: Graphical Spine and Real Terminal

**Rationale:** X startup and PTY behavior are the highest-risk runtime integration seams and must be green before UI polish.  
**Delivers:** unprivileged live user; eudev/input/video groups; one font; Xorg/xinit/Openbox; guarded tty1 autologin; bounded session supervisor; tty2 rescue; themed xterm/ash launcher; `X_READY` and `TERM_EXEC_OK`; first screenshot.  
**Addresses:** TS-01, TS-04, TS-06, terminal portion of TS-10.  
**Avoids:** Pitfalls 9, 10, 11, 12, and 15.  
**Exit gate:** Under the fixed QEMU display contract, keyboard/mouse/text work and the terminal passes `tty`, `printf`, `pwd`, `ls`, pipeline, failing-command/exit-code, Ctrl-C, and resize checks.  
**Research flag:** **Targeted phase research/spike recommended** for the exact v3.24 recursive APK closure, selected QEMU VGA path, and minimum required Mesa/input packages. Use standard VGA as the predeclared fallback.

### Phase 4: 300K Product Slice and Comedy Engine

**Rationale:** With boot, X, and terminal isolated, the product can be implemented as small deterministic code and data without destabilizing the platform.  
**Delivers:** full-screen Tcl/Tk conversation shell; original theme/disclosure; six-intent router; safe composer; 40-line reviewed catalog; seeded shuffle-bags; `300k` helper; calculator; factual System Info; Help/About; keyboard/focus/contrast/Reduced Chaos; reboot/shutdown; `UI_READY`.  
**Addresses:** TS-02 through TS-05, TS-08 through TS-12, DF-01 through DF-04.  
**Avoids:** arbitrary chat execution, copied trade dress, offensive/destructive jokes, focus theft, read-only asset writes, and nondeterministic acceptance (Pitfalls 15 and 17).  
**Exit gate:** The full 90-second demo passes keyboard-only with no NIC and a fixed seed; composer shell-looking text produces no side effect, while the same text in xterm behaves normally.  
**Research flag:** Standard Tcl/Tk state-machine and data-catalog patterns; skip research. Spend time on golden tests and actual QEMU visual review.

### Phase 5: Firmware, Media, and Semantic Smoke Automation

**Rationale:** Release claims must be attached to guest behavior, not merely valid-looking ISO structures or a running QEMU process.  
**Delivers:** PowerShell QEMU runner; TCG reliability path and optional WHPX speed path; ordered serial assertions; QMP lifecycle/send-key/screendump; screenshot variance checks; fresh-vars UEFI; BIOS/UEFI optical lanes; BIOS/UEFI raw-disk lanes; offline and shutdown checks; failure artifact bundle.  
**Addresses:** reproducible verification, TS-07, TS-08, complete acceptance matrix.  
**Avoids:** Pitfalls 6, 7, 14, 16, 19, and 20.  
**Exit gate:** The final candidate reaches `ROOTFS_READY`, `X_READY`, `UI_READY`, `TERM_EXEC_OK`, and `PASS` with `-nic none` in every claimed lane; screenshots and logs reference the exact ISO SHA-256.  
**Research flag:** **Targeted research/spike recommended** for QMP `screendump` and display backend behavior on this QEMU 11.1.0 Windows bundle. If automation blocks, retain the same manual evidence contract.

### Phase 6: Size, Polish, and Release Evidence

**Rationale:** Size work is meaningful only against a complete green baseline; optional polish should consume only proven remaining time and bytes.  
**Delivers:** subsystem size ledger; recursive package and installed-size reports; one-group-at-a-time pruning; P1 additions in deletion-order priority; clean release rebuild; final ISO/checksum/manifest/lock/xorriso report/logs/screenshots; honest compatibility and size statement.  
**Addresses:** 100 MB stretch target, DF-05 through DF-09 where affordable, release documentation.  
**Avoids:** Pitfalls 5, 9, 13, 18, and 19.  
**Exit gate:** The smallest last-known-good candidate passes the complete Phase 5 matrix after a clean build; no private key, credential, remote dependency, or unsupported compatibility claim is present.  
**Research flag:** Skip research. This phase is measurement-driven; preserve the larger green image whenever a trim fails.

### Phase Ordering Rationale

- The dependency chain is builder → offline root → X/PTY → product UI/content → cross-firmware semantics → optimization/release.
- Package and boot failures remain visible before a graphical splash exists; graphical failures preserve tty and xterm recovery.
- The terminal lands before the parody interface so the core promise cannot be replaced with a fake when time runs short.
- Seed injection and stable milestone names land with their first consumers, preventing nondeterminism and observability from becoming late test retrofits.
- Firmware/media automation occurs after the product emits semantic markers, but a BIOS smoke and structural inspection run in earlier phases.
- Size is deliberately last because only measured integrated behavior can tell which dependencies are safe to remove.

### Research Flags

**Needs targeted phase research or implementation spikes:**

- **Phase 3:** exact v3.24 Xorg/Tk/Openbox/xterm/font closure, `virtio-vga` behavior, and installed-RAM cost.
- **Phase 5:** Windows QEMU QMP/screendump display configuration, fresh EDK2 variable handling, and raw-disk invocation.

**Standard or sufficiently researched patterns; skip research-phase:**

- **Phase 1:** container preflight, digest/commit locking, Linux volume, and build manifests are documented patterns.
- **Phase 2:** Alpine `mkimage`, diskless apkovl, local repository, and hybrid boot logic are already source-traced; execute a spike instead.
- **Phase 4:** Tcl/Tk state machine, declarative catalogs, fixed-seed golden tests, and xterm launcher boundary are straightforward.
- **Phase 6:** dependency sizing, one-variable pruning, checksum generation, and release evidence are empirical tasks.

## Confidence Assessment

| Area | Confidence | Notes |
|---|---|---|
| Stack | MEDIUM | Current Alpine release/artifact listings and aports code support the decision; the local graphical closure and Docker build have not run. |
| Features | MEDIUM | The core terminal/offline/accessibility requirements are strong; humor quality and optional-tool value require the first live demo. |
| Architecture | MEDIUM | The design follows official Alpine diskless, Xorg/OpenRC, Docker, and QEMU seams; exact Windows and package behavior remains an implementation check. |
| Pitfalls | MEDIUM | Failure modes are cross-checked against authoritative docs and local host inspection, but the project has not yet produced its first ISO. |

**Overall confidence:** MEDIUM

### Gaps to Address

- **Docker health:** confirm Linux-container operation before Phase 1 planning assumes the builder can run.
- **Exact locks:** resolve the aports commit, amd64 builder manifest, APK versions/checksums, `linux-virt` version, Tk version, and signing-key fingerprint in the first successful build.
- **Final image and memory budgets:** measure recursive compressed closure, installed tmpfs use, and steady-state RAM before setting size or minimum-memory claims.
- **QMP visual evidence:** prove `screendump` with the selected Windows display mode; use a manual screenshot lane if automation remains fragile.
- **Firmware/media behavior:** independently prove BIOS, UEFI, optical, and raw-disk lanes before promising UEFI or USB-hybrid boot.
- **UI fit and accessibility:** inspect actual 1024x768 and 800x600 rendering, keyboard focus, contrast, terminal escape path, and Reduced Chaos in QEMU.
- **Comedy quality:** review all shipped lines and test several fixed seeds plus one unseeded session; randomness must never become a readiness condition.
- **Public-release identity:** inventory licenses and original assets, keep the prominent unofficial/offline disclosure, and seek qualified review if the artifact becomes commercial or widely publicized.
- **Byte reproducibility:** functional input reproducibility is required; byte identity remains deferred unless APK archives and signing inputs become hermetic.

## Sources

### Primary and authoritative

- [Alpine Linux 3.24.1 release](https://www.alpinelinux.org/posts/Alpine-3.24.1-released.html) and [Alpine downloads](https://www.alpinelinux.org/downloads/) — current release and supported artifacts.
- [Official Alpine x86_64 release index](https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/) — published virt ISO size baseline.
- [Alpine custom ISO with mkimage](https://wiki.alpinelinux.org/wiki/How_to_make_a_custom_ISO_image_with_mkimage) — supported profile, package, and apkovl workflow.
- [aports `3.24-stable` `mkimage.sh`](https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh), [`mkimg.base.sh`](https://github.com/alpinelinux/aports/blob/master/scripts/mkimg.base.sh), and [`mkimg.standard.sh`](https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.standard.sh) — image assembly, repository, profile, BIOS, EFI, and hybrid-media behavior.
- [Alpine Diskless Mode](https://wiki.alpinelinux.org/wiki/Diskless_Mode), [Local APK cache](https://wiki.alpinelinux.org/wiki/Local_APK_cache), and [APK documentation](https://docs.alpinelinux.org/user-handbook/0.1a/Working/apk.html) — RAM-backed live root, overlay, local package, and trust model.
- [Alpine Xorg](https://wiki.alpinelinux.org/wiki/Xorg), [Openbox](https://wiki.alpinelinux.org/wiki/Openbox), and [OpenRC](https://wiki.alpinelinux.org/wiki/OpenRC) — graphical session and service patterns.
- [QEMU system invocation](https://www.qemu.org/docs/master/system/invocation.html), [QMP specification](https://www.qemu.org/docs/master/interop/qmp-spec.html), and [QMP reference](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html) — VM, serial, machine-control, screenshot, and lifecycle interfaces.
- [Linux devpts documentation](https://docs.kernel.org/filesystems/devpts.html) and [`pty(7)`](https://man7.org/linux/man-pages/man7/pty.7.html) — real-terminal requirements.
- [Docker build best practices](https://docs.docker.com/build/building/best-practices/), [bind mounts](https://docs.docker.com/engine/storage/bind-mounts/), and [Docker Desktop troubleshooting](https://docs.docker.com/desktop/troubleshoot-and-support/troubleshoot/topics/) — digest pinning and Windows/Linux filesystem boundary.
- [GNU xorriso](https://www.gnu.org/software/xorriso/xorriso.html) and [xorrisofs boot/hybrid options](https://manpages.debian.org/testing/xorriso/xorrisofs.1.en.html) — final boot-record and system-area inspection.
- [BusyBox command documentation](https://busybox.net/downloads/BusyBox.html) and [BusyBox FAQ](https://busybox.net/FAQ.html) — compact command set and applet compatibility caveats.
- [OpenAI design guidelines](https://openai.com/brand/) — original identity and non-endorsement risk reduction.
- [WCAG 2.2](https://www.w3.org/TR/WCAG22/) — keyboard, focus, contrast, motion, and persistent-content acceptance criteria.

### Product-pattern reference

- [Apple GameplayKit `GKShuffledDistribution`](https://developer.apple.com/documentation/gameplaykit/gkshuffleddistribution) — precedent for consume-before-repeat shuffled selection; the project implements its own small local algorithm.

### Local host evidence recorded by research

- QEMU `11.1.0` is installed at `D:\VM\qemu`; the bundle exposes TCG and WHPX plus GTK, SDL, `none`, and `egl-headless` display backends.
- `D:\VM\qemu\share` contains non-Secure-Boot x86_64 EDK2 code and an EDK2 variables template. The test runner must copy the template per UEFI run.
- Docker client `29.6.0` was present, but the Linux daemon endpoint was not running when inspected.

---
*Research completed: 2026-08-25*  
*Ready for roadmap: yes*
