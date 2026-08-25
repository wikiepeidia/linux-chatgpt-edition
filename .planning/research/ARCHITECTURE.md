# Architecture Patterns

**Project:** 300K Linux
**Domain:** Tiny x86_64 graphical live parody ISO
**Researched:** 2026-08-25
**Confidence:** MEDIUM — the design is grounded in current first-party Alpine, QEMU, and Docker documentation, but the exact package closure and Windows/QEMU behavior still require an implementation spike.

## Recommendation

Build 300K Linux as a thin product layer on Alpine's existing `mkimage` and diskless-live machinery, deriving the project profile from Alpine's VM-focused `profile_virt`. The ISO should contain the proven boot chain, kernel/initramfs, an offline APK repository, and one generated APK overlay (`apkovl`) carrying project configuration, scripts, assets, and `/etc/apk/world`. At boot Alpine creates a RAM-backed writable root, restores the overlay, installs the declared package world from the ISO, and hands control to normal OpenRC/getty startup.

Do not build a kernel, initramfs framework, installer, display manager, desktop environment, browser shell, or custom package manager. Autologin one unprivileged live user on tty1, launch X through `startx`, run one minimal window manager, and start a single native lightweight parody UI. Keep the real terminal as a separate fixed launcher into an ordinary local shell. This structure reaches a bootable checkpoint early and lets UI/content failures degrade to a usable console rather than a dead ISO.

Start with the stock Alpine boot profile for the first green boot, then prune the package closure without changing the boot mechanism. The 100 MB figure is a stretch metric, not an architectural constraint: measure every layer, but never trade away the known boot path or terminal for an unverified custom rootfs.

## System Overview

```text
Windows host
  build.ps1
      |
      v
Pinned Linux builder container
  Alpine aports/mkimage + project profile + rootfs overlay
      |
      +--> dist/300k-linux-x86_64.iso
      +--> dist/manifest.json + SHA256SUMS + size-report.txt
      |
      v
QEMU 11.1.0 smoke runner (D:\VM\qemu)
  serial milestones <------ guest boot/session/UI/terminal probes
  QMP --------------------> send-key, screendump, quit

ISO runtime
  BIOS ISOLINUX | UEFI GRUB
             |
        kernel + initramfs
             |
   Alpine diskless tmpfs root
     + local APK repository
     + 300k.apkovl.tar.gz
             |
        OpenRC + tty1 login
             |
   unprivileged session launcher
             |
      Xorg -> window manager
               |         |
       300k wish UI   real xterm -> /bin/ash -l
               |
       content engine -> static content catalog
```

## Component Boundaries

| Component | Owns | Must not own | Interface / evidence |
|---|---|---|---|
| Host build wrapper | Docker/QEMU discovery, path normalization, targets, exit codes | Linux image assembly details | `build.ps1` invokes the pinned builder and receives files under `dist/` |
| Builder container | Linux tooling, pinned aports checkout, package download cache, `mkimage` invocation | Runtime state or host-specific absolute paths inside the image | Inputs are read-only source plus lock data; outputs are ISO, manifest, logs |
| ISO profile | Architecture, boot options, bootloaders, kernel flavor, package closure, overlay generator | UI behavior or jokes | `mkimg.300k.sh` and an explicit package list |
| Rootfs overlay | Users, permissions, inittab/getty setup, X session, project scripts/assets, service runlevel links | Official packages or generated kernel/initramfs | Deterministic staging tree packed as `300k.apkovl.tar.gz` |
| Session launcher | tty ownership, X retries, logging, fallback shell | Content selection or arbitrary command execution | Starts `startx`; emits `X_READY`/failure milestones |
| Window manager | Window placement, fullscreen UI, terminal shortcut, emergency menu | Desktop services, package management, login | Static configuration; fixed command targets only |
| Parody UI | Chat-style presentation, prompt history, typed UI events | Shell evaluation, network calls, package installation | Sends normalized prompt events to content engine; renders structured replies |
| Content engine/catalog | Trigger matching, seeded selection, no-repeat policy, reply/effect IDs | GUI layout or unrestricted executable snippets | Pure input/output contract with golden tests |
| Terminal launcher | Opens a real terminal emulator and login shell | Treating chat text as commands | Fixed `exec` argv; no interpolation from UI input |
| Guest observability | Stable serial markers and local logs | QEMU orchestration | `300K_STAGE=<name>` records on serial and `/var/log/300k/` |
| QEMU smoke runner | VM lifecycle, timeouts, QMP, screenshots, artifact collection | Guessing readiness from sleep delays | Pass/fail comes from ordered guest markers plus nonblank screenshot checks |

This separation is important: a prompt typed into the parody UI is data, never a shell command. The only path to a shell is an explicit terminal action that executes a constant program and argument list.

## Build-Time Architecture on Windows

### Reproducibility contract

For v1, “reproducible” means a fresh Windows machine with Docker can run one documented PowerShell command and recreate a functionally equivalent ISO from source-controlled configuration. Do not claim byte-for-byte reproducibility until package archives and the build signing key are also hermetically preserved.

Pin and record:

- Builder image by tag and digest, not a mutable tag alone.
- Alpine release branch, repository URLs, aports commit, architecture, and kernel flavor.
- The resolved package name/version list and SHA-256 of every fetched APK.
- `SOURCE_DATE_EPOCH` from a committed release value or source commit.
- The public fingerprint of the ignored build signing key.
- QEMU executable/version and exact VM arguments used for verification.

Keep downloaded APKs, aports checkout, and the private abuild key in an ignored cache volume. They are build inputs, not ISO runtime secrets. The ISO receives only required public verification material. Emit `manifest.json`, `SHA256SUMS`, and a per-package size report alongside the ISO.

### Container boundary

`build.ps1` should first verify that Docker is running Linux containers and that `D:\VM\qemu\qemu-system-x86_64.exe` exists. It then resolves Windows paths and invokes the builder with three mounts:

1. Repository source, read-only.
2. Build/package cache, writable and ignored.
3. `dist/`, writable for canonical artifacts.

The builder copies the overlay into an internal staging directory with explicit `install -m` modes. Never trust executable bits from NTFS bind mounts. Enforce LF endings for shell/config files with `.gitattributes` and fail preflight on CRLF shebangs. Normalize ownership, modes, mtimes, locale, and timezone before packing the overlay.

The container should run only with the capabilities the official tools prove they need. `mkimage`, `fakeroot`, `xorriso`, and GRUB tooling should be attempted without a privileged container first; do not make `--privileged` the default merely for convenience.

### Image assembly

Use a project `mkimage` profile and overlay generator, not post-build ISO surgery:

1. Profile selects x86_64, kernel/initramfs features, ISOLINUX and GRUB EFI support, serial console arguments, local packages, and the overlay generator.
2. `mkimage` recursively fetches packages into the ISO's local APK repository.
3. Overlay generator creates `/etc/apk/world`, live user/group configuration, session files, app code, content, assets, and startup links.
4. `mkimage` creates an ISO with BIOS and EFI boot records when both bootloader inputs are present.
5. Post-build inspection verifies El Torito entries, required paths, checksum, package manifest, and size before QEMU starts.

Avoid remastering a downloaded ISO. Remastering hides package provenance, makes deletions fragile, and creates a second boot-layout implementation that the overnight schedule cannot afford.

## Runtime Filesystem Model

The ISO is immutable. Alpine's diskless boot creates the writable root on `tmpfs`; the project overlay supplies configuration and the local ISO repository supplies packages. Kernel modules/firmware remain managed by Alpine's normal media/modloop path. There is no persistent home, disk installer, or write-back to the ISO.

```text
Read-only ISO
  /boot/{vmlinuz,initramfs,syslinux,grub}
  /apks/x86_64/*.apk
  /300k.apkovl.tar.gz
          |
          v
RAM-backed live root
  /etc                configuration and package world from overlay
  /usr/local/lib/300k executable project code from overlay
  /usr/share/300k     static assets and content from overlay
  /home/chatgpt       disposable session state
  /run, /tmp, /var    runtime logs/state only
```

Keep authored files in the overlay and third-party files in APKs. Do not copy package-owned libraries into the overlay. At runtime, write only to `/run/300k`, `/tmp`, the disposable home directory, and `/var/log/300k`. This makes a fresh boot a clean reset and turns accidental state dependence into an obvious test failure.

Because the root is RAM-backed, compressed ISO size and runtime memory are separate budgets. Test with 512 MiB first; record the observed minimum only after repeated boots. A smaller ISO that exhausts tmpfs during package installation is a regression.

## Boot Lifecycle

1. **Firmware:** BIOS selects ISOLINUX; UEFI selects `BOOTX64.EFI`/GRUB. Both entries load the same kernel, initramfs, and command line.
2. **Early userspace:** Initramfs discovers the ISO, creates the diskless root, mounts required module media, applies `300k.apkovl.tar.gz`, and installs `/etc/apk/world` from the ISO-local repository.
3. **System init:** OpenRC brings up device management and local prerequisites. Networking is not required or enabled for the experience. A marker writer records `300K_STAGE=ROOTFS_READY` to serial.
4. **Controlling tty:** tty1 autologins the unprivileged `chatgpt` live user through a tiny fixed helper. tty2 remains a rescue console. This is preferable to launching X directly from an OpenRC daemon because `startx` receives a real controlling VT.
5. **Session launch:** The tty1 profile executes `300k-session` only when `DISPLAY` is empty and the tty is tty1. The launcher attempts X a bounded number of times, logs each failure, and falls back to an interactive shell instead of respawning forever.
6. **X session:** `startx` runs a project xinit script with X TCP listening disabled. The script applies display/background settings, starts the minimal window manager, and then the parody UI.
7. **Readiness:** After its top-level window is mapped, the UI writes `300K_STAGE=UI_READY seed=<value>`. A one-shot terminal-emulator probe executes a harmless shell command under X and writes `300K_STAGE=TERM_EXEC_OK`; it then exits. The normal terminal remains available through a visible button and window-manager shortcut.
8. **Recovery:** Closing or crashing the UI restarts it once, then opens a real terminal with a visible error message. Exiting the window manager ends X and returns to the tty launcher. tty2 is always independent of the graphical session.

Use ordered, stable machine markers rather than scraping human log text. Human-readable logs can change; marker names form a test API.

## X Session and Window Manager

Use Xorg plus `xinit` and a minimal configurable window manager such as Openbox. Do not add a display manager, full desktop environment, compositor, D-Bus, polkit, audio stack, or network manager unless an implemented feature demonstrates that it needs one.

The window manager has three jobs:

- Place the parody UI maximized/fullscreen and remove unnecessary decoration.
- Bind one obvious shortcut and menu item to the constant `300k-terminal` launcher.
- Keep an emergency terminal/menu path available if the UI crashes.

The xinit script is the session supervisor, but it should remain small: start the window manager, start the UI, wait, and clean up children on exit. Do not bury business logic in `.xinitrc` or window-manager XML. Run X as the live user, add only the required input/video/tty groups, and use default modesetting before adding model-specific video drivers.

## Parody UI, Content, and Real Terminal

### UI contract

The ChatGPT-inspired UI is a local Tcl/Tk `wish` state machine, not a browser pointed at localhost. Keep selection logic in a sourced Tcl module so it can run under `tclsh` without creating a display. Its stable interface is:

```text
submit(prompt_text, session_seed, turn_index)
  -> {reply_id, rendered_text, effect_id, suggested_actions[]}
```

The UI owns layout and transcript state. The content engine owns normalization, trigger matching, and reply selection. Effects are a small whitelist such as `none`, `fake_progress`, `toast`, or `open_about`; catalog data cannot contain shell fragments or executable paths.

### Real terminal boundary

`300k-terminal` must use a fixed execution path equivalent to:

```text
terminal-emulator -e /bin/ash -l
```

The launcher may set prompt/theme environment variables, but it must never concatenate prompt text into a command line. The terminal is ordinary local Linux: BusyBox utilities and explicitly included basics work normally, command exit codes are real, and no response is pretended to come from an AI service.

### Deterministic random content model

Store comedy as UTF-8 catalog data with stable IDs, categories, weights, trigger tags, and effect IDs. Keep logic out of the catalog. A suitable record is:

```text
id | category | weight | trigger | effect | text
```

Seed resolution has one deterministic seam:

1. `300K_SEED` environment variable, when supplied by unit or smoke tests.
2. Optional `300k.seed=` kernel argument for diagnostic boots.
3. Otherwise, a seed read once from `/dev/urandom` at session start.

Record the resolved seed and catalog revision in the session log. Use a specified small PRNG algorithm implemented in the content engine, not shell `$RANDOM`. Build a shuffled bag of eligible reply IDs, consume it without repetition, and reshuffle only after exhaustion. The same catalog revision + seed + prompt sequence must produce the same reply IDs; normal boots still vary because their seed varies.

Content validation should reject duplicate IDs, invalid weights/effects, missing fallback replies, control characters, overlong lines, and executable-looking action fields. Golden tests should assert reply IDs rather than entire prose where possible, so copy edits do not make the algorithm appear broken.

## Proposed Source Tree

```text
/
├── build/
│   ├── Dockerfile
│   ├── build.ps1
│   ├── lock.env
│   └── container/
│       ├── build-iso.sh
│       └── verify-iso.sh
├── iso/
│   ├── mkimg.300k.sh
│   ├── genapkovl-300k.sh
│   └── packages.world
├── rootfs-overlay/
│   ├── etc/
│   │   ├── inittab
│   │   ├── profile.d/300k-session.sh
│   │   └── 300k/
│   ├── usr/local/bin/
│   │   ├── 300k-ui
│   │   └── 300k-terminal
│   ├── usr/local/lib/300k/
│   │   ├── session
│   │   ├── content-engine.tcl
│   │   └── emit-milestone
│   ├── usr/share/300k/
│   │   ├── content/
│   │   ├── assets/
│   │   └── theme/
│   └── home/chatgpt/
│       ├── .xinitrc
│       └── .config/<window-manager>/
├── tests/
│   ├── unit-content.sh
│   ├── validate-overlay.sh
│   ├── smoke-qemu.ps1
│   └── fixtures/
├── dist/                 # ignored generated artifacts
└── .cache/               # ignored packages, aports, signing key
```

The exact executable extensions depend on the selected UI toolkit, but these ownership boundaries should remain unchanged.

## Verification Architecture

### Pre-boot gates

Fail before QEMU if any of these fail:

- Shell/config syntax, LF/shebang, ownership/mode manifest, and overlay path validation.
- Content schema and fixed-seed golden tests.
- Dependency/package lock resolution and absence of unexpected network/client packages.
- ISO exists, is nontrivial, contains kernel/initramfs/overlay/APK repository, and reports BIOS plus UEFI boot records.
- SHA-256, resolved package manifest, compressed size, and largest-package report are emitted.

### QEMU semantic smoke test

The Windows runner should call the supplied executable by absolute path, use software emulation as the reliable baseline, allocate 512 MiB, attach the ISO read-only, and disable the virtual NIC. Capture serial to a dedicated log and expose QMP on a loopback-only dynamically selected port.

Pass requires these ordered markers before a bounded timeout:

```text
300K_STAGE=ROOTFS_READY
300K_STAGE=X_READY
300K_STAGE=UI_READY seed=...
300K_STAGE=TERM_EXEC_OK
300K_RESULT=PASS
```

On `UI_READY`, negotiate QMP capabilities, call `screendump`, send the fixed terminal shortcut with QMP `send-key`, and capture a second screenshot. Validate that both screenshots have the expected dimensions and nontrivial pixel/color variance; do not rely on an exact screenshot hash, which is brittle across fonts and QEMU rendering. Save screenshots for later human inspection. On timeout or unexpected QEMU exit, collect serial, QEMU stderr, screenshots if possible, manifest, and the exact invocation before terminating the VM through QMP.

Run both BIOS and UEFI smoke on every release build. The installed QEMU bundle has already been found to include `D:\VM\qemu\share\edk2-x86_64-code.fd` and `edk2-i386-vars.fd`; copy the variables template into the test-artifact directory before each UEFI run and never attach the shipped template writable. Keep firmware paths configurable so the runner remains portable.

### Test seams by layer

| Layer | Fast test | Integrated evidence |
|---|---|---|
| Content engine | Fixed seed + prompt sequence golden IDs | UI emits selected IDs/seed to session log |
| UI | Toolkit-level startup/render test where available | `UI_READY` after map + screenshot variance |
| Terminal | Launcher argv test | Terminal emulator executes shell probe under X |
| Session | Script syntax and mocked retry tests | `X_READY`, crash fallback, tty2 rescue |
| Rootfs/ISO | Inspect paths, modes, package world, El Torito records | Boot reaches `ROOTFS_READY` with `-nic none` |
| Firmware | ISO structure report | Separate BIOS and UEFI QEMU boots |

## Size and Failure Isolation

Track size by boot files, kernel/modules/firmware, X stack, UI toolkit, terminal/window manager/fonts, project assets, and miscellaneous utilities. Optimize in that order of evidence: remove unused firmware/drivers only after QEMU remains green; subset fonts and compress images; avoid browser engines and full desktop meta-packages; never minify shell/config files so aggressively that recovery becomes opaque.

The image should degrade safely:

- Bootloader/initramfs failure is isolated by keeping Alpine's generated path unmodified.
- Package installation failure appears on serial and leaves a console rather than hiding under a splash screen.
- X failure retries with a limit, preserves logs, and returns to tty1/tty2.
- UI failure cannot remove the real shell; it triggers a terminal fallback.
- Malformed content falls back to a built-in reply and cannot execute code.
- Missing assets use plain colors/text and do not block readiness.
- Smoke timeouts always preserve evidence and kill only the QEMU process they started.

Do not add a graphical splash until serial milestones and failure consoles are proven. Cosmetic boot hiding is last because it can turn a diagnosable failure into a black screen.

## Overnight Critical Path and Build Order

1. **Freeze the build seam (30–60 min).** Start/preflight Docker Desktop in Linux-container mode and verify the absolute QEMU/OVMF paths; pin builder/aports/repositories; create wrappers, cache, manifest, and artifact directories.
2. **Prove base boot (60–90 min).** Produce an x86_64 ISO from the `profile_virt`-derived project profile with serial console enabled. Boot it in QEMU with no NIC and require `ROOTFS_READY`. Nothing graphical is allowed to block this checkpoint.
3. **Prove the graphical spine (90–150 min).** Add live user, controlling-tty autologin, Xorg, minimal window manager, font, xterm, session retries, and rescue tty. Require `X_READY`, terminal shell probe, and a screenshot. This is the highest-risk phase and must precede UI polish.
4. **Add the thinnest complete product slice (90–180 min).** Implement one-screen chat UI, disclaimer, prompt entry, canned fallback, explicit terminal button/shortcut, fixed seed, and `UI_READY`. This is the first releasable parody ISO.
5. **Expand deterministic comedy (60–120 min).** Add catalog validation, trigger categories, shuffled-bag randomization, effects whitelist, and golden prompt-sequence tests. Content additions now cannot destabilize boot.
6. **Polish and measure (remaining time).** Original assets/theme, basic utilities, package/asset pruning, repeated cold boots, BIOS/UEFI verification where firmware is available, checksums, size report, and final screenshots.

If time collapses, stop after step 4 with a larger but verified ISO. Do not spend the last hours rewriting the rootfs, replacing X, or chasing 100 MB.

## Anti-Patterns to Avoid

### Browser-as-desktop shell

A browser plus local web server is familiar for CSS but dominates size, adds processes, complicates readiness, and expands failure surface. Use one lightweight native UI process.

### Chat prompt as shell command

It creates an ambiguous and dangerous interface. Keep parody chat and the real terminal visibly and technically separate.

### Post-build ISO mutation

Editing a generated ISO after `mkimage` makes boot records and provenance fragile. All authored changes belong in the profile or overlay before assembly.

### Fixed sleeps as readiness

Boot duration changes with cache and host load. Wait for serial milestones with a timeout, then use QMP for interaction and evidence.

### Optimizing before the first green boot

Kernel/firmware/package pruning before an integrated baseline makes failures difficult to localize. Measure and remove one package group at a time with QEMU smoke after each change.

## Architecture Decisions for the Roadmap

- Treat Alpine `mkimage` + diskless mode as the base adapter and do not build competing image paths.
- Make the serial milestone contract in the first implementation phase; every later phase depends on it.
- Land the real terminal and graphical fallback before the parody UI.
- Design deterministic seed injection with the first content engine, not as test retrofit.
- Separate functional completion from size optimization; size work is a final measured phase.
- Make BIOS and UEFI smoke mandatory for release, using the supplied QEMU OVMF files with a fresh writable variables copy per run.

## Open Verification Questions

- The selected Tcl/Tk, Openbox, Xorg, xterm, font, and driver package closure still must be built and measured; published base-ISO sizes cannot predict the final compressed result.
- Whether QMP `screendump` works with the selected fully headless display flags on this Windows build needs a small spike; fall back to a loopback-only VNC display while retaining QMP control.
- Exact minimum RAM and final ISO size cannot be known until the package closure and fonts/assets are assembled.
- Byte-for-byte reproducibility remains deferred unless package archives and signing inputs are made hermetic.

## Sources

- [Alpine: custom ISO with mkimage](https://wiki.alpinelinux.org/wiki/How_to_make_a_custom_ISO_image_with_mkimage) — profile/apkovl workflow and prerequisites. **Confidence: MEDIUM**.
- [Alpine aports `mkimg.base.sh` official mirror](https://github.com/alpinelinux/aports/blob/master/scripts/mkimg.base.sh) — current package-repository assembly, apkovl generation, ISOLINUX/GRUB EFI hybrid image flow, and `SOURCE_DATE_EPOCH` use. **Confidence: MEDIUM**.
- [Alpine: Diskless Mode](https://wiki.alpinelinux.org/wiki/Diskless_Mode) — RAM-backed root, apkovl, and local package cache behavior. **Confidence: MEDIUM**.
- [Alpine: Xorg](https://wiki.alpinelinux.org/wiki/Xorg) — `xinit`/`startx`, per-user `.xinitrc`, input, and modesetting guidance. **Confidence: MEDIUM**.
- [Alpine: OpenRC](https://wiki.alpinelinux.org/wiki/OpenRC) — service/runlevel model. **Confidence: MEDIUM**.
- [Alpine: Openbox](https://wiki.alpinelinux.org/wiki/Openbox) — minimal Xorg/window-manager/xterm session pattern. **Confidence: MEDIUM**.
- [QEMU system invocation](https://www.qemu.org/docs/master/system/invocation.html) — character backends, serial capture, monitor, and QMP endpoints. **Confidence: MEDIUM**.
- [QEMU QMP protocol specification](https://www.qemu.org/docs/master/interop/qmp-spec.html) — machine-readable control negotiation and message contract. **Confidence: MEDIUM**.
- [QEMU QMP reference](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html) — stable `send-key`, `screendump`, query, and quit commands. **Confidence: MEDIUM**.
- [Docker build best practices](https://docs.docker.com/build/building/best-practices/) — digest pinning, minimal builder inputs, and cache/bind-mount practices. **Confidence: MEDIUM**.
