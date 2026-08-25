<!-- GSD:project-start source:PROJECT.md -->

## Project

**300K Linux**

300K Linux is a tiny, bootable x86_64 live Linux parody that drops the user into a desktop inspired by ChatGPT's familiar conversation interface. It is an offline comedy artifact: a usable local terminal presented as “ChatGPT Terminal,” a handful of basic utilities, and random absurd interactions—without OpenAI APIs, Codex, accounts, or cloud dependencies.

It is designed as a memorable demonstration of what an intensive AI-assisted build sprint can produce, not as an official OpenAI product or a general-purpose daily-driver distribution.

**Core Value:** The ISO must reliably boot into an immediately recognizable, funny ChatGPT-like experience with a genuinely usable local terminal.

### Constraints

- **Timeline**: Produce the strongest verifiable artifact possible overnight, with the first bootable result prioritized over optional polish.
- **Image size**: Aim near 100 MB, but treat it as a stretch target; measure and publish the actual result.
- **Runtime**: Fully local and offline after boot; never embed API keys, credentials, or user account data.
- **Compatibility**: Target x86_64 virtual machines; support both BIOS and UEFI when the chosen base/build system makes that reliable within the deadline.
- **Build host**: Windows with Docker available but no installed WSL or native Linux build chain.
- **Emulator**: Use the supplied QEMU installation at `D:\\VM\\qemu` for repeatable boot tests.
- **Quality**: A claimed ISO is not “done” until a boot smoke test reaches the graphical experience and the terminal can execute commands.
- **Identity**: Clearly label the distribution as an unofficial parody and use original project artwork.

<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->

## Technology Stack

## Decision

## Base Comparison

| Candidate | Current official evidence | Build/boot fit | Decision |
|---|---|---|---|
| **Alpine Linux 3.24.1** | Released 2026-06-13. The official x86_64 directory reports the 3.24.1 `virt` ISO as **66M**, `minirootfs` as **4M**, and `standard` ISO as **352M**. The supported `v3.24` branch runs through 2028-06-01. | `mkimage.sh` has profiles, APK dependency resolution, apkovl support, ISOLINUX, GRUB EFI, `mtools`, and `xorrisofs` hybrid output. | **Use it.** |
| **Tiny Core Pure64 17.0** | Official 2026-02-10 artifacts are exceptionally small: `CorePure64-17.0.iso` is **25,853,952 bytes** and `TinyCorePure64-17.0.iso` is **42,991,616 bytes**. | Official remaster documentation publishes a manual cpio/gzip/mkisofs flow and a BIOS ISOLINUX recipe. The current Core book discusses UEFI installations, but no equally clear current official hybrid BIOS+UEFI ISO remaster path was found. Its extension model would also make a polished custom UI more bespoke. | Reject for v1 schedule risk; revisit only if Alpine cannot approach the size target. |
| **SliTaz Cooking / 5.1 in development** | Official downloads advertise a 55 MB Cooking desktop and a separate native x86_64 Cooking base image; the project says 5.1 is still being developed. July 2026 notes show active x86_64 and GRUB2-EFI work. | Impressively small and active, but the native x86_64 line is still a development target rather than the conservative stable base for a one-night release. | Reject for v1 stability/tooling risk. |
| **Debian live-build / Archiso / Fedora live tooling** | Mature, documented ecosystems. | Their general-purpose live-image defaults and dependency footprints work against the near-100-MB target; trimming them would consume the night without improving the parody UI. | Reject for v1 size and iteration speed. |
| **Buildroot** | Purpose-built minimal appliance images are possible. | It shifts the job into source builds, kernel configuration, device integration, and package recipes. That is excellent for a later appliance edition, not the fastest route to a polished live desktop tonight. | Defer. |

## Recommended Stack

### Image and Boot Layer

| Technology | Pin | Purpose | Why |
|---|---|---|---|
| Alpine Linux | `3.24.1`, repositories under `/alpine/v3.24` | Runtime base and package source | Current stable x86_64 release with a small official `virt` baseline. |
| Alpine Docker Official Image | `alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` | Linux build environment on Windows | Docker Hub currently maps 3.24.1 to this multi-platform index digest. Use `--platform linux/amd64`. |
| Alpine aports | branch `3.24-stable`; record the resolved commit in `build-lock.json` | ISO profile and image generator | Keeps image logic aligned with the v3.24 package repositories. Do not build from moving `master`/`edge`. |
| `linux-virt` | exact APK version captured during the first successful build | VM-focused kernel/modloop | Alpine's official `profile_virt` selects the slimmed virtual kernel. |
| ISOLINUX/Syslinux | v3.24 package lock | Legacy BIOS El Torito boot | Generated by Alpine's image scripts for x86/x86_64 ISO output. |
| GRUB EFI | `grub-efi 2.14-r0` in v3.24 at research time | `EFI/BOOT/BOOTX64.EFI` path | Current aports source builds `bootx64.efi` and an EFI FAT image. |
| `xorriso` + `mtools` | v3.24 package lock | Hybrid ISO assembly | Aports uses `xorrisofs` with an isohybrid MBR, alternate EFI El Torito image, and GPT hybrid marker. |
| Alpine apkovl | project script, versioned in repo | Boot-time configuration and project files | Natural Alpine diskless mechanism for users, OpenRC services, X startup, UI scripts, branding, and `/etc/apk/world`. |

### Graphical Runtime

| Package | Version/pin | Purpose | Notes |
|---|---|---|---|
| `xorg-server` | v3.24 package lock; package version observed as `21.1.24-r0` | X11 display server | Use QEMU's `virtio-vga`; include the normal modesetting stack for reliability before attempting size cuts. |
| `xinit`, `eudev`, `xf86-input-libinput`, `mesa-dri-gallium` | v3.24 package lock | Session startup, devices, input, rendering | First reliable package set. Remove or replace only after BIOS and UEFI boots are green. |
| `openbox` | `3.6.1-r8` | Minimal window manager | Small, packaged, and explicitly documented by Alpine. No panel or desktop shell is needed. |
| `tcl` + `tk` | Tcl `8.6.17-r1`; lock Tk from v3.24 | Full-screen parody UI | Scriptable native widgets and canvas drawing with no browser or Python runtime. |
| `xterm` | v3.24 package lock | Real “ChatGPT Terminal” | Launch `/bin/ash -l`; theme via X resources/arguments. |
| `font-terminus` | v3.24 package lock | Legible compact UI/terminal font | Alpine's own Openbox guide recommends it with Openbox and xterm. |
| BusyBox/OpenRC | supplied by `alpine-base` | Shell, core utilities, init | Gives a genuinely usable offline terminal without GNU userland bulk. |

## Exact Builder Toolchain

## Windows and Docker Feasibility

## BIOS and UEFI

## Size Contract

## Reproducibility Contract

- Docker image index digest and resolved linux/amd64 manifest;
- exact aports commit from `3.24-stable`;
- repository URLs and the resolved APK names/versions/checksums;
- project APK signing-key fingerprint;
- fixed `SOURCE_DATE_EPOCH`;
- ISO SHA-256, byte size, and `xorriso -indev ... -report_el_torito as_mkisofs` output;
- BIOS and UEFI QEMU command lines and smoke-test results.

## Confidence Assessment

| Area | Confidence | Reason |
|---|---|---|
| Alpine 3.24.1 release and artifact sizes | MEDIUM | Cross-checked on Alpine's release page, download page, and official directory; web-search seam classifies verified web findings as MEDIUM. |
| Hybrid BIOS/UEFI generation | MEDIUM | Current aports source explicitly contains the ISOLINUX, GRUB EFI, FAT image, and xorriso hybrid paths. Actual project ISO still needs both boots tested. |
| Docker-on-Windows build | MEDIUM | The builder uses filesystem tools and should not need privileged loop mounts, but the local Docker daemon was stopped, so this exact host has not run the pipeline yet. |
| Near-100-MB outcome | LOW | Only the 66M official baseline is measured; the custom graphical package closure is not. |
| QEMU firmware availability | HIGH | QEMU 11.1.0 and both local EDK2 files were directly inspected on this host. |

## Sources

- [Alpine downloads and current release](https://www.alpinelinux.org/downloads/)
- [Alpine 3.24.1 release announcement](https://www.alpinelinux.org/posts/Alpine-3.24.1-released.html)
- [Official Alpine latest-stable x86_64 artifact index](https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/)
- [Alpine release branches and support windows](https://www.alpinelinux.org/releases/)
- [Alpine custom ISO with mkimage](https://wiki.alpinelinux.org/wiki/How_to_make_a_custom_ISO_image_with_mkimage)
- [Alpine aports image-builder source mirror: `mkimg.base.sh`](https://github.com/alpinelinux/aports/blob/master/scripts/mkimg.base.sh)
- [Alpine aports profile source mirror: `mkimg.standard.sh`](https://github.com/alpinelinux/aports/blob/master/scripts/mkimg.standard.sh)
- [Alpine Openbox guidance](https://wiki.alpinelinux.org/wiki/Openbox)
- [Alpine Xorg guidance](https://wiki.alpinelinux.org/wiki/Xorg)
- [Docker Official Image for Alpine](https://hub.docker.com/_/alpine)
- [Tiny Core Pure64 17.0 official release directory](https://www.tinycorelinux.net/17.x/x86_64/release/)
- [Tiny Core official remastering guide](https://wiki.tinycorelinux.net/doku.php?id=wiki:remastering)
- [Tiny Core current Core book](https://www.tinycorelinux.net/corebook.pdf)
- [SliTaz current downloads](https://www.slitaz.org/en/get/)
- [SliTaz July 2026 x86_64 development update](https://www.slitaz.org/en/news/july-2026.php)
- [QEMU system emulator command-line documentation](https://www.qemu.org/docs/master/system/qemu-manpage.html)

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
