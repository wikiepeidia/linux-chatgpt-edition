# Domain Pitfalls

**Domain:** Tiny graphical Alpine 3.24 live ISO, built in Docker on Windows and tested with QEMU
**Researched:** 2026-08-25
**Overall confidence:** MEDIUM — critical claims were cross-checked against current Alpine, QEMU, Linux kernel, Docker, and xorriso primary documentation; exact behavior still needs validation against the first local ISO.

## Overnight Critical Path and Cut-Lines

The shortest credible route is a sequence of independently provable gates. Save the last known-good ISO at every gate.

| Order | Gate | Maximum investigation before fallback | Required proof | Cut-line |
|------:|------|---------------------------------------|----------------|----------|
| 0 | Builder preflight | 15 minutes | Linux Docker engine responds; a tiny container runs; output directory is writable | Start/fix Docker Desktop. Do not rewrite the build around native Windows tools. |
| 1 | Alpine live core | 45 minutes | ISO reaches an OpenRC serial marker under SeaBIOS | Stay with upstream `profile_virt`; remove all UI customization until this passes. |
| 2 | Offline payload | 45 minutes | Required APKs are installed during a `-nic none` boot | Fix the signed boot repository and apkovl `/etc/apk/world`; never install from the network at startup. |
| 3 | Graphical shell | 60 minutes | X starts as the demo user and the first UI frame is captured | Use a minimal `startx` path, one video model, one font, and a plain xterm fallback. Drop the display manager and compositor. |
| 4 | Real terminal | 60 minutes | `tty`, interactive input, Ctrl-C, ANSI output, and resize all work | Theme xterm and ship it. Cut a custom terminal renderer before shipping a pipe-based fake terminal. |
| 5 | UEFI | 45 minutes after BIOS/UI/PTY pass | Fresh EDK2 state boots the same ISO to `UI_READY` | If it still fails, publish v1 as BIOS/QEMU-only and remove the UEFI claim. Do not destabilize the BIOS artifact. |
| 6 | USB-hybrid semantics | 30 minutes | xorriso reports BIOS+EFI boot equipment and QEMU boots the ISO as a raw disk | If unproven, call the artifact a bootable CD ISO, not USB-tested. |
| 7 | Size/reproducibility | Remaining time | Final SHA-256, package manifest, clean rebuild attempt, measured size | Ship a working image above 100 MiB. Never delete input, font, boot, or PTY dependencies merely to hit 100 MiB. |

Explicit overnight cuts: no installer, persistence UI, Secure Boot, broad physical-hardware support, browser engine, full desktop environment, display manager, audio stack, or custom terminal emulation unless every earlier gate is already green.

## Critical Pitfalls

### Pitfall 1: The Docker Builder Never Actually Reaches Linux

**Owner:** Phase 1 — Build foundation

**What goes wrong:** The build is debugged as an Alpine problem even though Docker Desktop is stopped, the client cannot reach the server, the engine is in Windows-container mode, or the host bind mount has Windows path/permission behavior.

**Why it happens:** `docker.exe` being installed proves only that the client exists. Docker Desktop runs the Linux daemon in a VM. Windows bind mounts also do not preserve Unix ownership and executable semantics in the same way as a native Linux filesystem, and CRLF scripts fail inside `/bin/sh`.

**Warning signs:**

- `docker version` prints a Client section but no Server section.
- `docker info` reports `OSType: windows`, a daemon connection error, or a virtualization error.
- Shell errors contain `$'\r'`, `^M`, `bad interpreter`, or `not found` for a file that visibly exists.
- `fakeroot` or an apkovl generator says `Permission denied` despite permissive-looking host ACLs.

**Prevention:**

- Make `docker version`, Linux `OSType`, and a trivial Alpine container the first build target.
- Keep aports, signing material, mkimage work files, and package cache on a Linux-owned Docker volume. Bind-mount source read-only if convenient and copy only the final ISO/checksums to Windows.
- Enforce LF with `.gitattributes`, and run explicit `chmod` inside the container for every generator, OpenRC service, `.start` script, and launcher.
- Use Alpine mkimage/xorriso's file-based build. If a replacement recipe demands host loop devices or `--privileged`, cut that recipe rather than adding Windows-specific mount complexity.

**Fast diagnostic:**

```powershell
docker version
docker info --format '{{.OSType}}'
docker run --rm alpine:3.24 sh -c 'uname -sm; test -x /bin/sh'
```

Then inspect one mounted shell script inside the container with `file` and `sed -n l`.

**Fallback:** Start Docker Desktop and use Linux containers. If bind mounts remain unreliable, build entirely in a named volume and use `docker cp` for artifacts. Native Windows ISO remastering is not the overnight fallback.

### Pitfall 2: aports, APK Repositories, and Signing Keys Drift Apart

**Owner:** Phase 1 — Build foundation

**What goes wrong:** mkimage cannot resolve packages, rejects the embedded repository, or builds an image whose boot-time APKINDEX is not trusted.

**Why it happens:** The profile comes from one Alpine branch while `main`/`community` point at another; `edge` is mixed into stable; the build key was regenerated or omitted; or the private key exists but its public half was not injected. Alpine's 3.24 mkimage source signs the embedded APKINDEX and requires a package-signing key when modloop signing is enabled.

**Warning signs:**

- `unable to select packages`, especially for `xorg-server` from `community`.
- `UNTRUSTED signature`, `BAD signature`, or `Need $PACKAGER_PRIVKEY`.
- Build succeeds only with `--allow-untrusted`.
- The package solver chooses `edge` revisions in an otherwise v3.24 image.

**Prevention:**

- Pin the `3.24-stable` aports commit and use only `https://dl-cdn.alpinelinux.org/alpine/v3.24/main` and `/community`.
- Generate an abuild key in builder initialization, persist it in a protected Docker volume for the sprint, expose `PACKAGER_PRIVKEY`, and allow mkimage to inject its public key. Never commit the private key or place it in the ISO.
- Fail the build if repository files contain `edge`, `testing`, `latest-stable`, or a different stable branch.
- Never make `--allow-untrusted` part of the release path.

**Fast diagnostic:** Check the aports commit, print the exact repositories file, verify that the private key and `.pub` file are readable, run `apk update` in mkimage's APK root, and run `apk policy xorg-server` to confirm the selected v3.24 source.

**Fallback:** Recreate only the builder container and keys, then rebuild from a clean work directory. Do not change the distro branch to make a missing package error disappear.

### Pitfall 3: APKs Are Present on the ISO but Absent from the Running System

**Owner:** Phase 2 — Bootable live core and offline payload

**What goes wrong:** `xorg-server`, the UI, or xterm appears under `/apks/x86_64` on the ISO, yet `command -v` and `apk info -e` fail after boot.

**Why it happens:** In Alpine mkimage, the profile's `apks` list builds the signed package repository carried by the media. It does not by itself express the diskless live system's desired installed state. Official mkimage guidance uses a generated apkovl containing `/etc/apk/world` and enables required services.

**Warning signs:**

- ISO inspection shows the `.apk`, but boot reaches only a console.
- Startup tries to download packages or waits for DNS.
- `/etc/apk/world` contains only `alpine-base`.
- The image works with QEMU's default network but fails with `-nic none`.

**Prevention:**

- List every runtime package in the ISO repository and in the generated apkovl's `/etc/apk/world`.
- Preserve `/apks/.boot_repository`, inject the signing public key, and test from the first boot with `-nic none`.
- Package application binaries/assets as APKs where possible. Use apkovl primarily for configuration, users, service links, and the world file.
- Make boot fail visibly to serial if a required `apk info -e PACKAGE` check fails.

**Fast diagnostic:** Inside the guest run `cat /etc/apk/world`, `cat /etc/apk/repositories`, `apk info -e xorg-server`, and inspect the mounted media's `apks/x86_64/APKINDEX.tar.gz` and `.boot_repository`.

**Fallback:** As a temporary diagnostic only, install from the signed local media repository in an early script. Once confirmed, move the package list back into apkovl/world so startup remains deterministic and offline.

### Pitfall 4: The apkovl Is Ignored, Malformed, or Loses Executable Bits

**Owner:** Phase 2 — Bootable live core and offline payload

**What goes wrong:** Users, services, `.xinitrc`, and UI configuration vanish even though an overlay archive was produced.

**Why it happens:** The archive name/hostname does not match the profile, it is nested under an extra directory, it was not copied to the ISO root, the generator is not executable, or Windows/Git did not preserve modes. Runtime edits also disappear on reboot by design in diskless mode; `lbu` persistence is not part of v1.

**Warning signs:**

- No boot message about loading user settings.
- The guest hostname is still `alpine`, the demo user is absent, or `rc-update show` lacks custom services.
- `tar -tvf` shows paths beginning with a staging directory rather than `etc/`, `home/`, and so on.
- OpenRC silently skips `/etc/local.d/name.start` because it is not executable or the `local` service is disabled.

**Prevention:**

- Set `hostname` and `apkovl` together in the profile and confirm the output is `<hostname>.apkovl.tar.gz` at ISO root.
- Inspect archive paths, ownership, and modes before ISO creation. Apply all `chmod`/`chown` operations inside Linux.
- Explicitly enable each OpenRC service in the generated overlay; for `/etc/local.d`, enable `local` and require the `.start` suffix plus executable mode.
- Treat every reboot as a clean-state test. Do not use `lbu commit` during acceptance because it can hide missing build inputs.

**Fast diagnostic:** Run `tar -tzvf` on the generated overlay, list the ISO root with xorriso, then check `id`, `rc-update show`, and file modes in a clean boot.

**Fallback:** Use the `apkovl=` kernel parameter to prove the archive itself works. Fix discovery before release; do not add a writable persistence disk merely to mask a bad built-in overlay.

### Pitfall 5: Cached mkimage Sections Hide Changes or Mix Kernels

**Owner:** Phase 1 — Build foundation; rechecked in Phase 6 — Release verification

**What goes wrong:** A rebuild ignores a launcher/service change, or a cached kernel/initramfs/modloop no longer matches the package set.

**Why it happens:** `--workdir` is an intentional section/package cache. It is valuable overnight, but cache identity does not protect against every external input: aports changes, repository indexes mutate, build keys change, and hand-copied artifacts bypass mkimage's section graph.

**Warning signs:**

- The ISO hash and embedded file are unchanged after a source edit.
- Boot reports invalid modules, unknown symbols, or a modloop for another kernel.
- A clean build fails while a warm build passes.
- Package versions differ between two machines using the same profile.

**Prevention:**

- Key the work directory by aports commit, architecture, profile hash, and repository file hash. Create a new directory instead of broadly deleting an uncertain cache.
- Never manually copy `vmlinuz`, initramfs, or modloop between builds.
- Pin the builder image by digest for the release build, set an explicit `SOURCE_DATE_EPOCH`, record the resolved recursive APK list/checksums, and retain the successful cache until shipment.
- Perform one clean release build after the fast cached iteration passes all smoke tests.

**Fast diagnostic:** Build twice from separate clean work directories with identical inputs and compare SHA-256 hashes. If they differ, compare embedded package lists, archive timestamps, build key fingerprints, and xorriso boot reports before changing code.

**Fallback:** If byte-for-byte identity cannot be achieved overnight, publish the exact aports commit, builder digest, epoch, repositories, resolved package manifest, and final checksum. Reproducible inputs are required; a perfect second hash is not allowed to block a working ISO.

### Pitfall 6: A SeaBIOS Pass Is Mistaken for UEFI Support

**Owner:** Phase 2 — Boot chain, verified again in Phase 6

**What goes wrong:** Default QEMU boots through ISOLINUX, while EDK2 drops to its shell or reports no bootable option.

**Why it happens:** Default x86 QEMU uses legacy BIOS. Alpine's hybrid builder includes EFI only when GRUB/EFI sections exist. A custom profile that stops inheriting `profile_virt`/`profile_standard`, clears `grub_mod`, or omits GRUB/mtools can silently become BIOS-only.

**Warning signs:**

- Only `boot/syslinux` exists; `boot/grub/efi.img` or `efi/boot/bootx64.efi` is absent.
- `xorriso -report_el_torito plain` reports only a BIOS image.
- EDK2 opens its shell instead of the Alpine menu.
- UEFI works only after a previous run, indicating stale NVRAM state.

**Prevention:**

- Extend the upstream virt profile; override the smallest possible variables and preserve its Syslinux and GRUB logic.
- Install the documented build prerequisites: Syslinux/xorriso plus GRUB and mtools for EFI.
- Maintain separate BIOS and UEFI smoke-test commands. Use a fresh copy of the EDK2 vars template for each UEFI run.
- Keep Secure Boot disabled and out of scope.

**Fast diagnostic:** Inspect El Torito and system-area reports, then run the same ISO twice: default firmware and explicit EDK2. This host contains `D:\VM\qemu\share\edk2-x86_64-code.fd` and `edk2-i386-vars.fd`; do not rely on firmware autodiscovery.

**Fallback:** After the BIOS/UI/PTY path is green, time-box UEFI to 45 minutes. If it remains red, ship a clearly labeled BIOS/QEMU v1 and preserve the working ISO.

### Pitfall 7: Optical Boot Is Mistaken for USB-Hybrid Boot

**Owner:** Phase 2 — Boot chain, verified in Phase 6

**What goes wrong:** `-cdrom` boots because El Torito is valid, but writing the ISO to a USB device would not boot because the system-area MBR/GPT metadata is missing or broken.

**Why it happens:** Optical firmware reads El Torito boot entries. USB firmware treats the same bytes as a disk and relies on the hybrid partition/system area. These are separate paths.

**Warning signs:**

- `-cdrom` works but attaching the ISO as `format=raw,media=disk,readonly=on` does not.
- xorriso reports BIOS and EFI El Torito images but no isohybrid MBR/GPT equipment.
- The ISO was recreated with a generic archiver after mkimage, losing upstream boot options.

**Prevention:**

- Let Alpine's mkimage/xorriso create the final ISO. Its upstream path combines ISOLINUX isohybrid MBR, EFI El Torito, and `-isohybrid-gpt-basdat` when both loaders exist.
- Run `xorriso -indev IMAGE -report_el_torito plain -report_system_area plain` on the final bytes, not the staging tree.
- Add BIOS-optical, UEFI-optical, BIOS-raw-disk, and UEFI-raw-disk lanes before claiming USB compatibility.

**Fast diagnostic:** Compare QEMU `-cdrom IMAGE` with a read-only raw-disk attachment of `IMAGE`; inspect both xorriso reports.

**Fallback:** Release it as a QEMU/CD ISO and remove the USB statement. Do not hand-edit MBR/GPT bytes overnight.

### Pitfall 8: Kernel, initramfs, modloop, and QEMU Devices Do Not Share One Contract

**Owner:** Phase 2 — Bootable live core

**What goes wrong:** The kernel starts but cannot find the CD, modloop, video/input device, or matching modules; X later sees no usable screen.

**Why it happens:** Essential initramfs features were trimmed, cached artifacts were mixed, or the QEMU command changed from the hardware the package set was designed for. Broad real-hardware firmware is then added as a blind fix, exploding size without helping the selected virtual device.

**Warning signs:**

- Initramfs emergency shell, `Mounting boot media: failed`, missing modloop, or module version errors.
- `/lib/modules/$(uname -r)` is missing or does not match `uname -r`.
- Xorg reports `no screens found` immediately after changing QEMU VGA type.

**Prevention:**

- Keep upstream virt initfs support for loop, squashfs, CD-ROM/storage, and virtio. Generate the kernel/initramfs/modloop in one mkimage transaction.
- Select one QEMU display contract for v1 and keep it fixed in scripts. Add only the corresponding kernel/X driver path.
- Do not add the broad `linux-firmware` world package for QEMU-first support; Alpine documents it as large. Add a specific firmware subpackage only when a logged missing-firmware message proves it is required.

**Fast diagnostic:** Capture the full serial boot, then check `uname -r`, `/lib/modules`, `lsmod`, `dmesg`, mounted media, and `/var/log/Xorg.0.log`. Re-run the last known-good QEMU command before touching the image.

**Fallback:** Return to the upstream virt hardware defaults. If a specific video path remains blocked, use QEMU standard VGA and a simple X fallback; use `linux-lts` only as a deliberate size-costing diagnostic, not the first reaction.

### Pitfall 9: The Tiny ISO Expands Beyond the Live Root's RAM Budget

**Owner:** Phase 2 — Bootable live core; budget checked in Phase 6

**What goes wrong:** APK installation or X startup fails with `No space left on device`, OOM kills, missing sockets, or truncated files even though the ISO itself is small.

**Why it happens:** Alpine ISO media runs diskless: the root filesystem is tmpfs, whose default size is about half available RAM. Compressed APK/ISO size is not the installed in-RAM footprint.

**Warning signs:**

- A 512 MiB VM fails while a 1 GiB VM works.
- `df -h /` is full, `dmesg` shows OOM, or X cannot create `/tmp/.X11-unix`/logs.
- Boot-time package extraction stops partway through.

**Prevention:**

- Set the acceptance VM to at least 1 GiB until the complete package set is measured.
- Record compressed ISO size, installed package size, root tmpfs usage after `UI_READY`, and free RAM separately.
- If necessary, use Alpine's documented `rootflags=size=...` kernel parameter, but still enforce a sane minimum VM memory in the README.

**Fast diagnostic:** At each serial milestone print `df -h /`, `free -m`, and the kernel log's OOM tail.

**Fallback:** Increase QEMU RAM first. Only then remove optional packages based on measured installed size. Do not misdiagnose tmpfs exhaustion as an X or signing bug.

### Pitfall 10: Graphical Autostart Races, Loops, or Runs as Root

**Owner:** Phase 3 — Graphical shell and startup

**What goes wrong:** X starts before devices/users are ready, multiple X servers fight for display `:0`, the login respawns endlessly after an app crash, or the demo runs as root and hides permission defects.

**Why it happens:** Several startup mechanisms are enabled at once (`inittab`, `.profile`, OpenRC, `local.d`, display manager), or an unguarded autologin repeatedly invokes `startx`.

**Warning signs:**

- Repeating login/Xorg messages, `Server is already active for display 0`, or rapidly growing logs.
- UI launches manually but not during boot.
- `$HOME`, `DISPLAY`, `XDG_RUNTIME_DIR`, or X authority points at root.
- Killing the UI causes an immediate high-CPU respawn storm.

**Prevention:**

- Choose one owner: a tty1 autologin guarded by `tty` and empty `DISPLAY`, with one `.xinitrc` ending in `exec UI`, is smaller than a display manager.
- Start only after eudev and the live root are ready. Use one retry with a visible console/xterm fallback, not an infinite restart loop.
- Run as a dedicated unprivileged user with a valid writable home and `video`/`input` group membership.
- Send startup errors and explicit `X_READY`/`UI_READY` markers to serial.

**Fast diagnostic:** Disable autostart and run `startx` once as the demo user. Check `id`, `tty`, environment, `rc-status`, processes, and `/var/log/Xorg.0.log`; then re-enable only the chosen startup path.

**Fallback:** Boot to console with a printed `startx` command, or automatically launch a themed xterm. Remove the display manager/compositor before adding more session machinery.

### Pitfall 11: X Has a Screen but No Input, Text, or Stable Video Driver

**Owner:** Phase 3 — Graphical shell and startup

**What goes wrong:** The display is black, keyboard/mouse do nothing, text renders as boxes, or the UI works only under one accidental QEMU VGA model.

**Why it happens:** Alpine's Xorg setup normally brings `xorg-server`, xinit, eudev, libinput, and Mesa Gallium; manual size trimming can remove a non-obvious dependency. Xorg is in `community`. The user also needs device permissions and at least one usable font.

**Warning signs:**

- `no screens found`, `failed to load module`, `cannot open /dev/input/event*`, or no pointer/keyboard devices in Xorg logs.
- Window borders appear but labels are blank/tofu.
- Switching between `std`, virtio, and QXL video changes success.

**Prevention:**

- Include v3.24 `community`, eudev, one input driver, xinit, and exactly one tested font.
- Add the demo user to `video` and `input`; verify device ownership after eudev starts.
- Pin the QEMU VGA/device option in both manual and automated scripts. Do not promise arbitrary graphics hardware.
- Measure the closure before deciding whether Mesa Gallium is affordable; never discover missing input/font dependencies only after final size stripping.

**Fast diagnostic:** Run a bare X server/test background, inspect `/var/log/Xorg.0.log`, then use `xdpyinfo` and `xinput list` if included. Verify font files and a known string before testing the themed UI.

**Fallback:** Standard VGA, a minimal window manager or no window manager, xterm, and one bitmap/font package. Drop acceleration and visual effects, not input or readable text.

### Pitfall 12: The “Terminal” Is Just Pipes Connected to a Shell

**Owner:** Phase 4 — ChatGPT Terminal integration

**What goes wrong:** Simple commands work, but interactive programs, prompts, ANSI control, Ctrl-C, job control, password readers, or resizing do not.

**Why it happens:** Pipes are byte streams, not terminals. A real local terminal needs a UNIX98 PTY pair, a mounted devpts filesystem, an accessible `/dev/ptmx`, and a child shell whose slave PTY is its controlling terminal.

**Warning signs:**

- `tty` says `not a tty`; `test -t 0` fails.
- Ctrl-C prints `^C` but does not interrupt the foreground command.
- `stty` fails, full-screen tools corrupt output, or resize never changes `stty size`.
- `/dev/pts` is absent or `/dev/pts/ptmx` has unusable mode.

**Prevention:**

- Use `forkpty`/`openpty` or the equivalent library abstraction, not separate stdin/stdout pipes. Establish a new session/controlling terminal, duplicate the slave to standard streams, and set `TERM`, `HOME`, `SHELL`, and `PATH` explicitly.
- Forward window size with `TIOCSWINSZ`/`SIGWINCH`, forward input bytes faithfully, use nonblocking backpressure, and reap the child process.
- Verify devpts is mounted and `/dev/ptmx` resolves to a usable PTY multiplexer. Run the terminal and shell as the demo user.
- Treat untrusted shell output as terminal data; do not interpolate it into markup or shell command strings.

**Fast diagnostic:** In the themed terminal run:

```sh
tty
test -t 0 && test -t 1 && echo PTY_OK
stty size
printf '\033[31mred\033[0m\n'
sleep 30
```

Resize the window and repeat `stty size`; interrupt `sleep` with Ctrl-C and verify the shell survives.

**Fallback:** Ship a themed xterm titled “ChatGPT Terminal.” It already provides a real PTY and satisfies the core requirement; the custom frame can launch it. Never ship a fake terminal because the visual renderer is unfinished.

### Pitfall 13: The 100 MiB Goal Drives Removal of Required Functionality

**Owner:** Phase 5 — Size optimization and packaging

**What goes wrong:** The image crosses 100 MiB, then frantic trimming removes the font, input stack, EFI loader, PTY fallback, or required module and produces a tiny non-product.

**Why it happens:** The official Alpine 3.24.1 x86_64 virt ISO is already about 66 MiB, leaving roughly 34 MiB. Xorg's transitive closure includes Mesa/DRM, fonts, udev, and input libraries. Browser engines, full font families, broad firmware, multiple kernels/drivers, debug/doc/dev packages, and duplicate assets can each consume the remaining budget.

**Warning signs:**

- Package selection is based on top-level APK sizes rather than recursive closure.
- The same assets appear in an APK and apkovl.
- `linux-virt` and `linux-lts`, multiple VGA drivers, or large Noto/firmware sets coexist.
- The image shrinks but one of BIOS, UEFI, input, UI, or terminal smoke tests turns red.

**Prevention:**

- Maintain a size ledger by subsystem: boot/kernel, embedded APK repository, X/input, UI/assets/font, terminal, and free margin.
- Use `apk fetch --simulate --recursive` to review closure, install into a disposable root to measure `apk info -s`, and inspect the staging/ISO tree with `du` and xorriso.
- Use one font, one QEMU video path, BusyBox utilities, no browser/WebKit/Electron, no full desktop, and no runtime `-dev`, `-doc`, `-dbg`, locale, or broad firmware collections.
- Re-run the complete smoke matrix after every trimming batch.

**Fast diagnostic:** Compare the last good and current package manifests and per-directory byte totals. The largest new transitive package, not the most recently edited UI file, is usually the cause.

**Fallback:** Publish the measured size honestly. The project explicitly treats 100 MiB as a stretch target; a 120–180 MiB working parody ISO is a success where a 99 MiB broken one is not.

### Pitfall 14: Smoke Tests Prove Only That QEMU Is Running

**Owner:** Phase 6 — Release verification

**What goes wrong:** A timeout sees a QEMU process or boot splash and declares success while OpenRC, X, the UI, PTY, or offline package installation has failed.

**Why it happens:** QMP `query-status: running` means vCPUs are executing, not that the guest reached application readiness. `-nographic` also multiplexes serial and monitor onto stdio and suppresses the graphical window, which can confuse both logging and visual checks. QEMU creates default user networking unless `-nic none` is specified.

**Warning signs:**

- Tests use only process existence, a fixed sleep, or one screenshot.
- The “offline” test omitted `-nic none`.
- BIOS and UEFI share one result despite different firmware commands.
- Forced QEMU termination is interpreted as either universal success or universal failure.

**Prevention:**

- Emit ordered guest serial markers: `BOOT_MEDIA_OK`, `OPENRC_OK`, `X_READY`, `UI_READY`, and `PTY_OK:<expected output>`. Emit a failure marker and diagnostics on each gate's timeout.
- Capture a QMP `screendump` after `UI_READY`; QMP status alone is insufficient. Keep a separate manual GTK/SDL visual lane.
- For automation use the console-capable `.exe`, a dedicated serial file/chardev, `-monitor none` or separate QMP channel, a hard timeout, and `-nic none`.
- Test BIOS/UEFI and optical/raw-disk paths independently. Use a fixed comedy seed/test mode so random jokes do not make assertions flaky.
- After all markers, request orderly guest shutdown or QMP quit and distinguish harness timeout from guest failure.

**Fast diagnostic:** Deliberately break the UI launcher and verify the test fails despite QEMU remaining `running`; deliberately remove the NIC and confirm success is unchanged.

**Fallback:** If full automation cannot be completed overnight, use the same gate checklist manually, save serial logs and screenshots, and state exactly which lanes were manual. Never reduce “boots” to “firmware opened the ISO.”

## Moderate Pitfalls

### Pitfall 15: Applications Write Beside Read-Only Media Assets

**Owner:** Phase 3 — Graphical shell

**What goes wrong:** History, random-state, logs, or caches are written next to files on the mounted ISO and fail with a read-only filesystem error.

**Warning signs:** UI works from a development directory but crashes only in the ISO; errors mention `/media/*` or the application install directory.

**Prevention:** Treat application assets as immutable. Put runtime data in `$HOME`, `/tmp`, `/run`, or `/var` on the live tmpfs, create directories with demo-user ownership, and make persistence explicitly out of scope.

**Fast diagnostic:** Print the executable/resource path and attempt a test write to every configured state directory during boot.

**Fallback:** Disable history/cache and use `/tmp/300k-linux` for the session.

### Pitfall 16: Persistent EDK2 Variables or WHPX Hide Host-Specific Failures

**Owner:** Phase 6 — Release verification

**What goes wrong:** UEFI boots only because a prior run created a favorable BootOrder, or QEMU fails before firmware because WHPX is unavailable.

**Warning signs:** First UEFI run fails but later runs pass; deleting the vars file changes behavior; `failed to initialize whpx` appears before guest output.

**Prevention:** Copy the EDK2 vars template for every test and never modify the template. Probe accelerators separately. This host's QEMU 11.1.0 reports both `whpx` and `tcg`; make TCG the slower reliability fallback.

**Fast diagnostic:** Repeat the UEFI test twice from independent fresh vars copies; run the same command once with TCG.

**Fallback:** Use TCG for CI/smoke testing and WHPX only as an optional speed path.

### Pitfall 17: Random Comedy Makes Acceptance Nondeterministic

**Owner:** Phase 3 — Graphical shell; verified in Phase 6

**What goes wrong:** Tests wait for a random line that does not appear, or the first boot sometimes looks empty/offensive/broken because all content is random.

**Warning signs:** Re-running the same ISO changes test results; a random branch is the only path that proves UI interaction.

**Prevention:** Separate deterministic core interactions from randomized extras. Accept a `300K_TEST_SEED` or kernel test flag, guarantee one known startup gag, and keep random content in a finite reviewed catalog.

**Fast diagnostic:** Run several fixed seeds and one unseeded boot; all must reach the same readiness markers.

**Fallback:** Disable randomness in the release candidate and ship deterministic jokes; randomness is a differentiator, not a boot dependency.

### Pitfall 18: QEMU-First Quietly Expands into Physical-Hardware Support

**Owner:** Phase 5 — Packaging and release scope

**What goes wrong:** The team adds Wi-Fi, GPU, audio, microcode, installer, and firmware collections before the virtual appliance is stable.

**Warning signs:** Broad `linux-firmware`, NetworkManager, PipeWire, multiple GPU stacks, or an installer appears before UEFI/QEMU gates pass.

**Prevention:** Keep the v1 hardware contract explicit: x86_64 QEMU, selected VGA/input/storage devices, 1 GiB RAM, Secure Boot off. Physical USB boot semantics may be checked, but broad driver certification is not.

**Fast diagnostic:** For every new package ask which failing acceptance gate and exact log line requires it.

**Fallback:** Move the package/feature to a post-v1 backlog and restore the last green manifest.

## Minor Pitfalls

### Pitfall 19: Output Naming Hides Which Build Was Tested

**Owner:** Phase 6 — Release verification

**What goes wrong:** QEMU boots yesterday's ISO because every build uses the same path.

**Warning signs:** The test log contains no artifact hash/build ID, multiple same-named ISOs exist, or a source change is not visible in the booted UI.

**Prevention:** Include profile/commit or a build ID in the internal release string; keep one explicit `latest` copy only after tests pass; record SHA-256 in every test report.

**Fast diagnostic:** Compare the hash tested by QEMU with the current build output before launch.

**Fallback:** Archive the ambiguous files and rebuild once to a unique filename.

### Pitfall 20: Boot Quietness Removes the Only Useful Failure Evidence

**Owner:** Phase 2 — Boot chain

**What goes wrong:** `quiet` plus a graphical handoff yields a black screen with no clue whether initramfs, APK, OpenRC, or X failed.

**Warning signs:** The screen is blank, serial output stops before any project marker, and the only available action is to guess which layer failed.

**Prevention:** Keep a test boot entry with serial console and verbose logging; the release entry can remain polished. Preserve logs under `/tmp` and echo failure summaries to tty1/ttyS0.

**Fast diagnostic:** Boot the verbose entry and locate the last emitted gate marker.

**Fallback:** Temporarily remove `quiet`; restore it only after the same image passes.

## Phase-Specific Warnings

| Phase topic | Must prove before advancing | Likely overnight trap | Required fallback |
|-------------|---------------------------|-----------------------|-------------------|
| Build foundation | Linux Docker server, pinned aports/repos, signing key, writable artifact path | Debugging Alpine while Docker/CRLF/bind mounts are broken | Linux-owned Docker volume plus `docker cp` |
| Bootable live core | BIOS serial marker, local signed APK repository, clean apkovl load, adequate tmpfs | Packages carried but not installed; cache-mixed kernel/modloop | Upstream virt profile and clean workdir |
| Graphical shell | Unprivileged `X_READY` and captured first frame with keyboard/mouse/text | Autostart loop, missing eudev/groups/font, changing VGA model | Guarded tty1 `startx`, standard VGA, xterm |
| Terminal integration | PTY smoke commands, Ctrl-C, resize, child cleanup | Pipes masquerading as a terminal | Themed xterm launched by the parody UI |
| Firmware/media | Same UI/PTY markers under BIOS and fresh-state EDK2; raw-disk check | SeaBIOS/optical success overclaimed as UEFI/USB | Label release BIOS/CD-only |
| Size/release | Full smoke matrix after trimming, final size and SHA-256, `-nic none` | Chasing 100 MiB breaks the product; QEMU-running false positive | Ship larger last-known-good ISO with evidence |

## Release Stop Conditions

Do not call the ISO complete if any of these is true:

- The build requires an untrusted APK repository or a private signing key is present in the output.
- The image needs network access to install or start the graphical experience.
- Only a boot menu, kernel, login prompt, or QEMU `running` state was observed.
- The terminal fails `tty`, Ctrl-C, or resize tests.
- UEFI or USB support is claimed without its separate lane passing.
- The sub-100 MiB image is less functional than the last green larger image.

## Sources

### Alpine Linux (primary)

- [Alpine 3.24.1 release](https://www.alpinelinux.org/posts/Alpine-3.24.1-released.html) and [current downloads](https://www.alpinelinux.org/downloads/)
- [Official x86_64 release index](https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/) — current virt ISO baseline is about 66 MiB
- [How to make a custom ISO with mkimage](https://wiki.alpinelinux.org/wiki/How_to_make_a_custom_ISO_image_with_mkimage)
- [aports 3.24-stable mkimage source](https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimage.sh)
- [aports mkimg base source](https://github.com/alpinelinux/aports/blob/master/scripts/mkimg.base.sh) and [3.24 standard/virt profiles](https://github.com/alpinelinux/aports/blob/3.24-stable/scripts/mkimg.standard.sh)
- [Diskless Mode](https://wiki.alpinelinux.org/wiki/Diskless_Mode), [Local APK cache](https://wiki.alpinelinux.org/wiki/Local_APK_cache), and [Alpine local backup](https://wiki.alpinelinux.org/wiki/Alpine_local_backup)
- [APK/repository documentation](https://docs.alpinelinux.org/user-handbook/0.1a/Working/apk.html)
- [Xorg](https://wiki.alpinelinux.org/wiki/Xorg), [Openbox](https://wiki.alpinelinux.org/wiki/Openbox), and [OpenRC](https://wiki.alpinelinux.org/wiki/OpenRC)
- [Alpine UEFI notes](https://wiki.alpinelinux.org/wiki/Alpine_and_UEFI)
- [Kernel/firmware guidance](https://wiki.alpinelinux.org/wiki/Kernels)

### QEMU, Linux, Docker, and ISO tooling (primary/authoritative)

- [QEMU system invocation](https://qemu-project.gitlab.io/qemu/system/invocation.html)
- [QEMU Machine Protocol reference](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html) — `query-status` and `screendump`
- [Linux kernel devpts documentation](https://docs.kernel.org/filesystems/devpts.html) and [Linux `pty(7)`](https://man7.org/linux/man-pages/man7/pty.7.html)
- [Docker Desktop troubleshooting for Windows bind mounts, CRLF, and virtualization](https://docs.docker.com/desktop/troubleshoot-and-support/troubleshoot/topics/)
- [Docker bind-mount documentation](https://docs.docker.com/engine/storage/bind-mounts/)
- [GNU xorriso](https://www.gnu.org/software/xorriso/xorriso.html) and [xorrisofs boot/hybrid options](https://manpages.debian.org/testing/xorriso/xorrisofs.1.en.html)

### Local host evidence

- Read-only probe on 2026-08-25: `D:\VM\qemu\qemu-system-x86_64.exe` reports QEMU 11.1.0 with `tcg` and `whpx`; available display backends include GTK, SDL, `none`, and `egl-headless`.
- `D:\VM\qemu\share` contains `edk2-x86_64-code.fd`, `edk2-x86_64-secure-code.fd`, and `edk2-i386-vars.fd`. Use the non-Secure-Boot code file and a fresh copy of the vars template for v1 tests.
