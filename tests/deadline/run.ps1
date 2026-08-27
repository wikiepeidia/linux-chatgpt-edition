[CmdletBinding()]
param(
    [ValidateSet('RuntimeStatic', 'BuildStatic', 'Publication', 'SmokeUnit', 'AllStatic', 'Evidence')]
    [string] $Scope = 'AllStatic',

    [string] $QemuRoot = 'D:\VM\qemu',

    [string] $LatestPath = 'dist/LATEST.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:Tests = [System.Collections.Generic.List[object]]::new()

function Add-Test {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string[]] $Scopes,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    $script:Tests.Add([pscustomobject]@{ Name = $Name; Scopes = $Scopes; Body = $Body })
}

function Assert-True {
    param([Parameter(Mandatory)] [bool] $Condition, [string] $Message = 'Expected condition to be true.')
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([Parameter(Mandatory)] [bool] $Condition, [string] $Message = 'Expected condition to be false.')
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message = 'Values are not equal.')
    if ($Expected -is [System.Array] -or $Actual -is [System.Array]) {
        $expectedJson = ConvertTo-Json @($Expected) -Compress
        $actualJson = ConvertTo-Json @($Actual) -Compress
        if ($expectedJson -cne $actualJson) { throw "$Message Expected=$expectedJson Actual=$actualJson" }
        return
    }
    if ($Expected -cne $Actual) { throw "$Message Expected=<$Expected> Actual=<$Actual>" }
}

function Assert-Match {
    param([Parameter(Mandatory)] [string] $Value, [Parameter(Mandatory)] [string] $Pattern, [string] $Message = 'Value did not match.')
    if ($Value -notmatch $Pattern) { throw "$Message Pattern=<$Pattern>" }
}

function Assert-Throws {
    param([Parameter(Mandatory)] [scriptblock] $Body, [string] $Message = 'Expected an exception.')
    try { & $Body }
    catch { return }
    throw $Message
}

function Assert-ThrowsCode {
    param(
        [Parameter(Mandatory)] [scriptblock] $Body,
        [Parameter(Mandatory)] [string] $ExpectedCode,
        [string] $Message = 'Expected a coded exception.'
    )
    try { & $Body }
    catch {
        $actualCode = [string]$_.Exception.Data['Code']
        if ($actualCode -ceq $ExpectedCode) { return }
        throw "$Message ExpectedCode=<$ExpectedCode> ActualCode=<$actualCode> Error=<$($_.Exception.Message)>"
    }
    throw "$Message ExpectedCode=<$ExpectedCode> but no exception was thrown."
}

function Get-RepoText {
    param([Parameter(Mandatory)] [string] $Path)
    $full = Join-Path $script:RepositoryRoot $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Required file is missing: $Path" }
    return [System.IO.File]::ReadAllText($full, [System.Text.UTF8Encoding]::new($false, $true))
}

function Assert-GuestTextFile {
    param([Parameter(Mandatory)] [string] $Path)
    $full = Join-Path $script:RepositoryRoot $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Required guest text file is missing: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    Assert-False -Condition ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -Message "$Path must not contain a UTF-8 BOM."
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    Assert-False -Condition $text.Contains("`r") -Message "$Path must use LF line endings."
    Assert-False -Condition ([bool]($text -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]')) -Message "$Path contains a forbidden control character."
}

$runtimeFiles = @(
    'builder/apkovl/genapkovl-300k.sh',
    'builder/apkovl/rootfs/etc/inittab',
    'builder/apkovl/rootfs/etc/local.d/300k.start',
    'builder/apkovl/rootfs/etc/profile.d/300k-session.sh',
    'builder/apkovl/rootfs/etc/doas.d/300k.conf',
    'builder/apkovl/rootfs/home/chatgpt/.xinitrc',
    'builder/apkovl/rootfs/home/chatgpt/.config/openbox/rc.xml',
    'builder/apkovl/rootfs/usr/local/bin/300k-runtime',
    'builder/apkovl/rootfs/usr/local/sbin/300k-power',
    'builder/apkovl/rootfs/usr/local/lib/300k/content.tcl',
    'builder/apkovl/rootfs/usr/local/lib/300k/ui.tcl'
)

Add-Test -Name 'Runtime source is deterministic text with an explicit apkovl manifest' -Scopes @('RuntimeStatic') -Body {
    foreach ($file in $runtimeFiles) { Assert-GuestTextFile -Path $file }
    $attributes = Get-RepoText '.gitattributes'
    Assert-Match $attributes '(?m)^builder/apkovl/\*\* text eol=lf$' 'The complete guest overlay tree must be pinned to LF.'

    $generator = Get-RepoText 'builder/apkovl/genapkovl-300k.sh'
    foreach ($pattern in @(
        'if \[ "\$#" -ne 1 \]',
        'case \$hostname in',
        'mktemp -d',
        "trap 'cleanup' EXIT",
        'umask 077',
        'install_file 0755',
        'install_file 0644',
        'LC_ALL=C sort -u',
        '--sort=name',
        '--owner=0',
        '--group=0',
        '--mtime=@\$SOURCE_DATE_EPOCH',
        'gzip -9n',
        '\$hostname[.]apkovl[.]tar[.]gz'
    )) { Assert-Match $generator $pattern "Generator contract is absent: $pattern" }
    foreach ($package in @('alpine-base','doas','eudev','font-terminus','mesa-dri-gallium','openbox','tcl','tk','xf86-input-libinput','xinit','xorg-server','xterm')) {
        Assert-Match $generator ("(?m)^" + [regex]::Escape($package) + '$') "Package world is missing $package."
    }
    foreach ($forbidden in @('PRIVATE KEY','C:\\Users\\','/home/builder','sshd','networking','wpa_supplicant')) {
        Assert-False ([bool]($generator -match [regex]::Escape($forbidden))) "Generator contains forbidden host/private/network material: $forbidden"
    }
}

Add-Test -Name 'Locked live-user boot path is bounded and retains rescue access' -Scopes @('RuntimeStatic') -Body {
    $local = Get-RepoText 'builder/apkovl/rootfs/etc/local.d/300k.start'
    $profile = Get-RepoText 'builder/apkovl/rootfs/etc/profile.d/300k-session.sh'
    $runtime = Get-RepoText 'builder/apkovl/rootfs/usr/local/bin/300k-runtime'
    $inittab = Get-RepoText 'builder/apkovl/rootfs/etc/inittab'

    Assert-Match $local 'addgroup -g 1000' 'The live group must have gid 1000.'
    Assert-Match $local 'adduser[^\r\n]*-u 1000[^\r\n]*chatgpt' 'The live user must have uid 1000.'
    Assert-Match $local 'passwd -l chatgpt' 'The live account must be locked.'
    Assert-Match $local 'chown -R chatgpt:chatgpt /home/chatgpt' 'Home ownership must be repaired at boot.'
    Assert-Match $local 'input video tty dialout' 'The live user must receive only the device groups needed for X, PTY, and serial evidence.'
    Assert-Match $local 'chown chatgpt:chatgpt /var/log/300k/stages[.]log' 'Later unprivileged stage writers must own the stage log.'
    foreach ($program in @('Xorg','startx','openbox','wish','tclsh','xterm','doas')) { Assert-Match $local ([regex]::Escape($program)) "Boot prerequisite check is missing $program." }
    Assert-Match $local '/dev/pts' 'Boot must verify the PTY filesystem.'

    Assert-Match $inittab '(?m)^tty1::respawn:/sbin/getty[^\r\n]*300k-autologin' 'tty1 must use the fixed autologin helper through getty.'
    Assert-Match $inittab '(?m)^tty2::respawn:/sbin/getty' 'tty2 must remain a normal rescue console.'
    Assert-Match $profile 'tty[^\r\n]*=\s*/dev/tty1' 'The graphical session must be limited to tty1.'
    Assert-Match $profile '-z "\$\{DISPLAY:-\}"' 'The profile must not nest X inside an existing display.'
    Assert-Match $profile '_300K_SESSION_ATTEMPTED' 'The rescue login shell must not re-enter the X launcher.'
    Assert-Match $runtime 'while \[ "\$attempt" -le 2 \]' 'X startup must have exactly two bounded attempts.'
    Assert-Match $runtime 'exec /bin/ash -l' 'Failed X startup must return to an interactive rescue shell.'
}

Add-Test -Name 'Stable boot and PTY markers have one authored producer each' -Scopes @('RuntimeStatic') -Body {
    $all = ($runtimeFiles | ForEach-Object { Get-RepoText $_ }) -join "`n"
    $runtime = Get-RepoText 'builder/apkovl/rootfs/usr/local/bin/300k-runtime'
    foreach ($stage in @('ROOTFS_READY','X_READY','UI_READY')) {
        $count = [regex]::Matches($all, 'serial-stage\s+' + $stage).Count
        Assert-Equal 1 $count "Stage $stage must have exactly one authored producer."
    }
    Assert-Equal 1 ([regex]::Matches($all, 'TERM_EXEC_OK uid=').Count) 'TERM_EXEC_OK must be emitted only by the PTY proof.'
    Assert-Match $runtime 'printf ''\\n%s\\n'' "\$line" > /dev/ttyS0' 'Serial stages must start on a fresh line even when the rescue getty prompt is active.'
}

Add-Test -Name 'Content records are closed, seedable, varied, and non-executable' -Scopes @('RuntimeStatic') -Body {
    $content = Get-RepoText 'builder/apkovl/rootfs/usr/local/lib/300k/content.tcl'
    $records = [regex]::Matches($content, '(?m)^\s*lappend (?:::threehundredk_)?catalog \[dict create id ([a-z0-9_-]+) triggers \{([^}]*)\} effect ([a-z_]+) actions \{([^}]*)\} text \{([^}]*)\}\]\s*$')
    Assert-True ($records.Count -ge 13) 'The content catalog must contain at least twelve reviewed replies plus fallback.'
    $ids = @($records | ForEach-Object { $_.Groups[1].Value })
    Assert-Equal $ids.Count @($ids | Sort-Object -Unique).Count 'Content IDs must be unique.'
    Assert-True ($ids -ccontains 'fallback') 'A fallback record is required.'
    $effects = @($records | ForEach-Object { $_.Groups[3].Value } | Sort-Object -Unique)
    foreach ($effect in $effects) { Assert-True (@('none','toast','fake_progress','open_about') -ccontains $effect) "Effect is outside the closed allowlist: $effect" }
    foreach ($record in $records) {
        foreach ($action in @($record.Groups[4].Value -split '\s+' | Where-Object { $_ })) {
            Assert-True (@('terminal','help','about','system_info','reboot','shutdown') -ccontains $action) "Action is outside the closed allowlist: $action"
        }
    }
    Assert-Match $content 'env\(300K_SEED\)' 'The content engine lacks the deterministic seed seam.'
    Assert-Match $content 'proc [^\r\n]*reply_for' 'The sourceable content interface is missing.'
    foreach ($primitive in @('eval','exec','open','source','load','socket','http')) {
        Assert-False ([bool]($content -match ('(?m)^\s*' + $primitive + '\b|\[' + $primitive + '\b'))) "Content engine contains forbidden primitive: $primitive"
    }
}

Add-Test -Name 'Composer treats hostile text as data and invokes only reply_for' -Scopes @('RuntimeStatic') -Body {
    $ui = Get-RepoText 'builder/apkovl/rootfs/usr/local/lib/300k/ui.tcl'
    Assert-Match $ui 'source /usr/local/lib/300k/content[.]tcl' 'UI must source the fixed local content module.'
    Assert-Match $ui 'reply_for \$prompt' 'Composer must send the prompt only to the local reply function.'
    Assert-False ([bool]($ui -match 'eval[^\r\n]*\$prompt|exec[^\r\n]*\$prompt|open[^\r\n]*\$prompt|source[^\r\n]*\$prompt|load[^\r\n]*\$prompt|socket[^\r\n]*\$prompt')) 'Prompt text reaches a Tcl execution, file, or network primitive.'
    foreach ($hostile in @('; reboot','$(id)','`uname`','| poweroff','../../etc/shadow')) {
        Assert-True ($hostile -is [string]) 'Hostile prompt fixture unexpectedly changed type.'
    }
}

Add-Test -Name 'Terminal and privileged power boundaries use constant commands' -Scopes @('RuntimeStatic') -Body {
    $runtime = Get-RepoText 'builder/apkovl/rootfs/usr/local/bin/300k-runtime'
    $power = Get-RepoText 'builder/apkovl/rootfs/usr/local/sbin/300k-power'
    $doas = Get-RepoText 'builder/apkovl/rootfs/etc/doas.d/300k.conf'
    $xmlPath = Join-Path $script:RepositoryRoot 'builder/apkovl/rootfs/home/chatgpt/.config/openbox/rc.xml'
    [xml] $xml = Get-Content -Raw -LiteralPath $xmlPath

    Assert-Match $runtime 'exec xterm -T "300K Terminal" -e /bin/ash -l' 'Normal terminal argv must be constant.'
    Assert-Match $runtime '/run/300k/terminal-proof[.]sh' 'The PTY probe must use a fixed proof script path.'
    Assert-Match $runtime 'xterm[^\r\n]*terminal-proof[.]sh' 'The probe must execute inside a real xterm.'
    foreach ($fact in @('id -u','/dev/pts/','command=ok','file=ok','exit=1')) { Assert-Match $runtime ([regex]::Escape($fact)) "PTY proof fact is absent: $fact" }

    $binding = @($xml.openbox_config.keyboard.keybind | Where-Object { $_.key -ceq 'C-A-t' })
    Assert-Equal 1 $binding.Count 'Openbox must define exactly one Ctrl+Alt+T binding.'
    Assert-Equal '/usr/local/bin/300k-runtime terminal' ([string]$binding[0].action.command).Trim() 'Openbox must call the fixed terminal launcher.'
    Assert-Match $power 'case "\$1" in' 'Power helper must use a closed argument dispatcher.'
    Assert-Match $power 'reboot\)' 'Power helper lacks reboot.'
    Assert-Match $power 'poweroff\)' 'Power helper lacks poweroff.'
    Assert-False ([bool]($power -match '(?m)^\s*exec\s+/(bin|usr/bin)/(sh|ash|bash)\b')) 'Power helper must never delegate to a root shell.'
    Assert-Equal 2 @([regex]::Matches($doas, '(?m)^permit nopass chatgpt as root cmd /usr/local/sbin/300k-power args (reboot|poweroff)$')).Count 'Doas must grant only the two exact power operations.'
}

Add-Test -Name 'Full-screen original UI keeps identity and fixed controls visible' -Scopes @('RuntimeStatic') -Body {
    $ui = Get-RepoText 'builder/apkovl/rootfs/usr/local/lib/300k/ui.tcl'
    Assert-Match $ui 'wm attributes [.] -fullscreen 1' 'UI must be full-screen.'
    Assert-Match $ui 'create (oval|polygon|rectangle)' 'UI must draw original project artwork in Tk.'
    Assert-Match $ui '300K' 'Original 300K identity artwork is missing.'
    Assert-Match $ui 'UNOFFICIAL PARODY / OFFLINE / LOCAL SCRIPT / NO OPENAI SERVICE' 'Persistent identity disclaimer is missing.'
    foreach ($label in @('Terminal','Help','About','System Info','Reboot','Shutdown')) { Assert-Match $ui ([regex]::Escape($label)) "UI control is missing: $label" }
    Assert-Match $ui 'winfo ismapped' 'UI readiness must depend on a mapped top-level window.'
    Assert-Match $ui 'after[^\r\n]*terminal-proof' 'UI must schedule one bounded terminal proof after mapping.'
}

Add-Test -Name 'Deadline target and profile extend rather than weaken Bootstrap' -Scopes @('BuildStatic') -Body {
    $build = Get-RepoText 'build.ps1'
    $profile = Get-RepoText 'builder/profiles/mkimg.300k.sh'
    $runner = Get-RepoText 'scripts/linux/run-build.sh'
    $qemuBackend = Get-RepoText 'scripts/host/Invoke-QemuBackend.ps1'
    $inputs = Get-RepoText 'builder/inputs.json' | ConvertFrom-Json -Depth 64

    Assert-Match $build "ValidateSet\('Bootstrap', 'DeadlineMvp'\)" 'Public target enum must include the isolated deadline target.'
    Assert-Match $build "300k_deadline" 'BuildRequest must map DeadlineMvp to the deadline profile.'
    Assert-Match $build "deadline_mvp_iso" 'Deadline artifact role is missing.'
    Assert-Match $build ([regex]::Escape("'deadline-' + `$requestHash.Substring(0,12)")) 'Deadline build identity must be request-qualified.'
    Assert-Match $profile 'profile_300k_bootstrap\(\)' 'Bootstrap profile must remain present.'
    Assert-Match $profile 'profile_300k_deadline\(\)[\s\S]*profile_virt' 'Deadline profile must inherit profile_virt.'
    Assert-Match $profile 'profile_300k_deadline\(\)[\s\S]*arch="x86_64"[\s\S]*hostname="300k"[\s\S]*apkovl="genapkovl-300k[.]sh"' 'Deadline profile identity/apkovl contract is incomplete.'
    foreach ($package in @('eudev','font-terminus','mesa-dri-gallium','openbox','tcl','tk','xf86-input-libinput','xinit','xorg-server','xterm')) {
        Assert-True (@($inputs.requested_image_packages) -ccontains $package) "Retained image closure is missing $package."
        Assert-Match $profile ([regex]::Escape($package)) "Deadline profile is missing $package."
    }
    Assert-True (@($inputs.builder_packages) -ccontains 'tcl=8.6.17-r1') 'Display-free guest content tests require exact tcl=8.6.17-r1.'
    Assert-Match $runner 'request_profile=\$\(json_scalar profile "\$REQUEST_FILE"\)' 'Linux build must derive the profile from immutable BuildRequest.'
    Assert-Match $runner '300k_bootstrap\|300k_deadline' 'Only the two known profiles may cross into mkimage argv.'
    Assert-Match $runner '300k_bootstrap\)[\s\S]*run_inspector_self_test[\s\S]*inspect_iso_artifact' 'Bootstrap must retain both recursive verification stages.'
    Assert-Match $runner '300k_deadline\)[\s\S]*run_content_self_test[\s\S]*inspect_deadline_iso_artifact' 'Deadline must use content self-test and fast inspection.'
    Assert-Match $runner '--profile \$request_profile' 'mkimage must use only the allowlisted request profile.'
    Assert-Match $build '\[switch\]\s*\$BuilderReadinessProbe' 'The bounded builder transport probe must be exposed explicitly.'
    Assert-Match $build 'Invoke-QemuBackend -Operation readiness-probe' 'The builder transport probe must reuse the owned QEMU backend.'
    $probeInvocation = [regex]::Match($build, '(?s)\$probe\s*=\s*Invoke-QemuBackend -Operation readiness-probe.*?(?=\r?\n\s*if \()').Value
    Assert-Match $probeInvocation '-BootTimeoutSeconds 300' 'Builder readiness probe must have a short finite boot bound.'
    Assert-False ([bool]($probeInvocation -match 'RequestFile|SourceArchive|SigningPrivateFile|SigningPublicFile')) 'Builder readiness probe must not accept source, request, or signing inputs.'
    Assert-Match $build 'QEMU_READINESS_BASE_(MISSING|HASH_MISMATCH)' 'Builder readiness probe must require the existing pinned base image.'
    Assert-Match $qemuBackend "ValidateSet\('init-signing-key', 'build', 'readiness-probe'\)" 'The QEMU backend must expose an isolated readiness-only operation.'
    Assert-Match $qemuBackend "'-machine', 'pc'" 'Builder VM must use the stable pc/i440fx machine.'
    Assert-False ([bool]($qemuBackend -match "'-machine', 'q35'")) 'q35 builder boot is forbidden after the Alpine IO-APIC timer panic under TCG.'
    Assert-Match $qemuBackend "'-accel', 'tcg,thread=multi'" 'Builder VM must retain the deterministic TCG accelerator.'
    Assert-False ([bool]($qemuBackend -match "'-accel', 'whpx'")) 'WHPX-first builder boot is forbidden after the observed Alpine IO-APIC timer panic.'
    Assert-Match $qemuBackend '(?s)after-ssh-readiness.*?if \(\$Operation -ceq ''readiness-probe''\)\s*\{\s*\$managementStages[.]Add\(''builder-readiness-live''\)\s*\}\s*else\s*\{' 'Readiness-only operation must stop after its live SSH proof; source transfer, package build, and artifact export belong only to the alternate branch.'

    . (Join-Path $script:RepositoryRoot 'build.ps1')
    $missingState = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-deadline-missing-signing-' + [Guid]::NewGuid().ToString('N'))
    $failureCode = $null
    try {
        Invoke-300kBuild -SelectedBackend Qemu -SelectedTarget DeadlineMvp -SelectedStateRoot $missingState -SelectedQemuRoot $QemuRoot -OnlyPreflight | Out-Null
    }
    catch { $failureCode = [string]$_.Exception.Data['Code'] }
    Assert-Equal 'SIGNING_PUBLIC_REQUIRED' $failureCode 'Deadline preflight accepted a state root without the external signing identity.'
}

Add-Test -Name 'Builder direct boot preserves the pinned image contract and adds noapic once' -Scopes @('BuildStatic') -Body {
    $qemuBackendPath = Join-Path $script:RepositoryRoot 'scripts/host/Invoke-QemuBackend.ps1'
    $qemuBackend = Get-RepoText 'scripts/host/Invoke-QemuBackend.ps1'
    foreach ($pattern in @(
        'function Get-QemuDirectBootSpec',
        'function Expand-QemuDirectBootMaterial',
        "Get-Command 7z[.]exe -CommandType Application",
        "'boot\\vmlinuz-virt'",
        "'boot\\initramfs-virt'",
        "'boot\\extlinux[.]conf'",
        '''-kernel'', \$directBoot[.]KernelPath',
        '''-initrd'', \$directBoot[.]InitrdPath',
        '''-append'', \$directBoot[.]KernelCommandLine'
    )) { Assert-Match $qemuBackend $pattern "Direct-kernel transport contract is absent: $pattern" }

    . $qemuBackendPath
    foreach ($functionName in @('Get-QemuDirectBootSpec','Expand-QemuDirectBootMaterial')) {
        Assert-True ($null -ne (Get-Command $functionName -CommandType Function -ErrorAction SilentlyContinue)) "Direct-kernel function is missing: $functionName"
    }

    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-direct-kernel-unit-' + [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($scratch) | Out-Null
    try {
        $kernel = Join-Path $scratch 'vmlinuz-virt'
        $initramfs = Join-Path $scratch 'initramfs-virt'
        $extlinux = Join-Path $scratch 'extlinux.conf'
        [System.IO.File]::WriteAllBytes($kernel, [byte[]](1,2,3))
        [System.IO.File]::WriteAllBytes($initramfs, [byte[]](4,5,6))
        $append = 'root=LABEL=/ modules=sd-mod,usb-storage,ext4,ena,gve,mana console=ttyS0,115200n8 console=ttyAMA0,115200n8 console=tty0'
        [System.IO.File]::WriteAllText($extlinux, "LABEL virt`n  APPEND $append`n", [System.Text.UTF8Encoding]::new($false))

        $spec = Get-QemuDirectBootSpec -KernelPath $kernel -InitrdPath $initramfs -ExtlinuxConfigPath $extlinux
        Assert-Equal ([System.IO.Path]::GetFullPath($kernel)) $spec.KernelPath 'Direct boot changed the verified kernel path.'
        Assert-Equal ([System.IO.Path]::GetFullPath($initramfs)) $spec.InitrdPath 'Direct boot changed the verified initramfs path.'
        Assert-Equal "$append noapic" $spec.KernelCommandLine 'Direct boot did not preserve APPEND and add exactly one noapic token.'
        Assert-Equal 1 @($spec.KernelCommandLine -split '\s+' | Where-Object { $_ -ceq 'noapic' }).Count 'Direct boot duplicated or omitted noapic.'

        [System.IO.File]::WriteAllText($extlinux, "LABEL virt`n", [System.Text.UTF8Encoding]::new($false))
        Assert-Throws { Get-QemuDirectBootSpec -KernelPath $kernel -InitrdPath $initramfs -ExtlinuxConfigPath $extlinux } 'A missing APPEND line was accepted.'
        [System.IO.File]::WriteAllText($extlinux, "LABEL virt`n  APPEND $append`nLABEL second`n  APPEND $append`n", [System.Text.UTF8Encoding]::new($false))
        Assert-Throws { Get-QemuDirectBootSpec -KernelPath $kernel -InitrdPath $initramfs -ExtlinuxConfigPath $extlinux } 'Duplicate APPEND lines were accepted.'
    }
    finally {
        if ([System.IO.Directory]::Exists($scratch)) { [System.IO.Directory]::Delete($scratch, $true) }
    }
}

Add-Test -Name 'Deadline inspector requires exact BIOS, EFI, ISO, and deferral evidence' -Scopes @('BuildStatic') -Body {
    $inspector = Get-RepoText 'scripts/linux/inspect-deadline-iso.sh'
    foreach ($path in @('/boot/vmlinuz-virt','/boot/initramfs-virt','/300k.apkovl.tar.gz','/apks/x86_64/APKINDEX.tar.gz','/boot/syslinux/isolinux.bin','/efi/boot/bootx64.efi','/boot/syslinux/boot.cat','/boot/grub/efi.img')) {
        Assert-Match $inspector ([regex]::Escape($path)) "Fast inspector is missing $path."
    }
    foreach ($fact in @('deadline-fast-structural','recursive_content_audit','runtime_uefi_boot','not-executed','iso_sha256','iso_bytes','result')) {
        Assert-Match $inspector ([regex]::Escape($fact)) "Fast inspection evidence is missing $fact."
    }
    Assert-Match $inspector '-report_el_torito plain' 'Fast inspector must prove plain El Torito records.'
    Assert-Match $inspector '-report_el_torito as_mkisofs' 'Fast inspector must prove BIOS and EFI image argv.'
    Assert-Match $inspector 'deadline-inspection[.]json[.]partial' 'Inspection JSON must be committed atomically.'
}

Add-Test -Name 'Deadline candidate and promotion path are isolated and fail closed' -Scopes @('Publication') -Body {
    $buildSource = Get-RepoText 'build.ps1'
    Assert-Match $buildSource '::Replace\(\$latestPartial, \$latest, \$backup, \$true\)[\s\S]{0,180}\$pointerChanged = \$true[\s\S]{0,180}::Delete\(\$backup\)' 'Pointer replacement must be marked before fallible backup cleanup so rollback remains armed.'
    . (Join-Path $script:RepositoryRoot 'build.ps1')
    foreach ($functionName in @('Test-DeadlineStagingBundle','Stage-DeadlineCandidate','Test-DeadlineCandidateDirectory','Test-DeadlineSmokeEvidence','Complete-DeadlineCandidate')) {
        Assert-True ($null -ne (Get-Command $functionName -CommandType Function -ErrorAction SilentlyContinue)) "Deadline publication function is missing: $functionName"
    }

    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-deadline-publication-' + [Guid]::NewGuid().ToString('N'))
    $dist = Join-Path $scratch 'dist'
    $candidateRoot = Join-Path $dist '.deadline-candidates'
    $evidenceRoot = Join-Path $dist '.deadline-evidence'
    [System.IO.Directory]::CreateDirectory($candidateRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
    try {
        $buildId = 'deadline-' + ('a' * 12)
        $candidate = Join-Path $candidateRoot $buildId
        [System.IO.Directory]::CreateDirectory($candidate) | Out-Null
        $isoName = '300k-deadline-x86_64-' + ('b' * 12) + '.iso'
        $isoPath = Join-Path $candidate $isoName
        [System.IO.File]::WriteAllBytes($isoPath, [byte[]](1..64))
        $inspectionPath = Join-Path $candidate 'deadline-inspection.json'
        Write-CanonicalJson ([ordered]@{ schema='DeadlineIsoInspection'; schema_version=1; scope='deadline-fast-structural'; result='pass' }) $inspectionPath
        $records = @($isoName, 'deadline-inspection.json' | Sort-Object -CaseSensitive | ForEach-Object {
            $item = Get-Item -LiteralPath (Join-Path $candidate $_)
            [ordered]@{ file=$_; sha256=Get-LowerFileSha256 $item.FullName; bytes=[long]$item.Length }
        })
        $deferred = [ordered]@{ runtime_uefi='not-executed'; raw_usb='not-executed'; broad_hardware_support='not-executed'; docker_parity='not-executed'; second_build_reproducibility='not-executed'; size_optimization='not-executed'; exhaustive_security='not-executed'; general_release_certification='not-executed' }
        $manifestPath = Join-Path $candidate 'deadline-candidate.json'
        Write-CanonicalJson ([ordered]@{
            schema='DeadlineCandidateManifest'; schema_version=1; build_id=$buildId; build_request_sha256=('c' * 64); source_commit=('d' * 40)
            iso=[ordered]@{ file=$isoName; sha256=Get-LowerFileSha256 $isoPath; bytes=[long](Get-Item $isoPath).Length }
            inspection=[ordered]@{ file='deadline-inspection.json'; scope='deadline-fast-structural' }; deferred=$deferred; files=$records
        }) $manifestPath

        $evidence = Join-Path $evidenceRoot $buildId
        [System.IO.Directory]::CreateDirectory($evidence) | Out-Null
        $serialPath = Join-Path $evidence 'serial.log'
        [System.IO.File]::WriteAllText($serialPath, (@(
            '300K_STAGE=ROOTFS_READY','300K_STAGE=X_READY','300K_STAGE=UI_READY',
            '300K_STAGE=TERM_EXEC_OK uid=1000 user=chatgpt tty=/dev/pts/0 command=ok file=ok exit=1'
        ) -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
        $screenPath = Join-Path $evidence 'screen.ppm'
        $ppm = [System.Collections.Generic.List[byte]]::new()
        $ppm.AddRange([System.Text.Encoding]::ASCII.GetBytes("P6`n2 2`n255`n"))
        $ppm.AddRange([byte[]](0,0,0,255,255,255,10,20,30,200,30,40))
        [System.IO.File]::WriteAllBytes($screenPath, $ppm.ToArray())
        $argv = New-DeadlineQemuArguments -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -IsoPath $isoPath -SerialPath $serialPath -QmpPort 49152
        $evidencePath = Join-Path $evidence 'deadline-smoke-evidence.json'
        $evidenceObject = [ordered]@{
            schema='DeadlineSmokeEvidence'; schema_version=1; result='pass'; build_id=$buildId; attempt_id=('e' * 32)
            iso=[ordered]@{ file=$isoName; sha256=Get-LowerFileSha256 $isoPath; bytes=[long](Get-Item $isoPath).Length }
            qemu=[ordered]@{ executable='D:\VM\qemu\qemu-system-x86_64.exe'; argv=@($argv); machine='pc'; firmware='bios'; media='optical-read-only'; nic='none'; memory_mib=1024 }
            markers=@(
                [ordered]@{ stage='ROOTFS_READY'; line=1 }, [ordered]@{ stage='X_READY'; line=2 },
                [ordered]@{ stage='UI_READY'; line=3 }, [ordered]@{ stage='TERM_EXEC_OK'; line=4 }
            )
            terminal=[ordered]@{ uid=1000; user='chatgpt'; tty='/dev/pts/0'; command='ok'; file='ok'; exit=1 }
            serial=[ordered]@{ file='serial.log'; sha256=Get-LowerFileSha256 $serialPath; bytes=[long](Get-Item $serialPath).Length }
            screenshot=[ordered]@{ file='screen.ppm'; sha256=Get-LowerFileSha256 $screenPath; bytes=[long](Get-Item $screenPath).Length; width=2; height=2; max_value=255; distinct_pixels=4; nonblank=$true }
            deferred=$deferred
        }
        Write-CanonicalJson $evidenceObject $evidencePath

        $priorDirectory = Join-Path $dist 'prior-build'
        [System.IO.Directory]::CreateDirectory($priorDirectory) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $priorDirectory 'sentinel.bin'), 'immutable')
        $latestPath = Join-Path $dist 'LATEST.json'
        $priorLatest = [System.Text.UTF8Encoding]::new($false).GetBytes('{"schema_version":1,"build_id":"prior-build","directory":"prior-build"}' + "`n")
        [System.IO.File]::WriteAllBytes($latestPath, $priorLatest)

        $mutations = @(
            { param($x) $x.iso.sha256 = ('0' * 64) },
            { param($x) $x.screenshot.nonblank = $false },
            { param($x) $x.markers[1].line = 1 },
            { param($x) $x.terminal.uid = 0 },
            { param($x) $x.terminal.tty = '/dev/tty1' },
            { param($x) $x.terminal.command = 'missing' },
            { param($x) $x.terminal.file = 'missing' },
            { param($x) $x.terminal.exit = 0 }
        )
        foreach ($mutation in $mutations) {
            $copy = ($evidenceObject | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64)
            & $mutation $copy
            $invalidPath = Join-Path $evidence ('invalid-' + [Guid]::NewGuid().ToString('N') + '.json')
            Write-CanonicalJson $copy $invalidPath
            Assert-Throws { Test-DeadlineSmokeEvidence -EvidencePath $invalidPath -CandidateManifestPath $manifestPath } 'Malformed evidence was accepted.'
            Assert-Equal ([Convert]::ToHexString($priorLatest)) ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($latestPath))) 'Rejected evidence changed LATEST.'
        }

        $completed = Complete-DeadlineCandidate -CandidateManifestPath $manifestPath -EvidencePath $evidencePath -DistRoot $dist
        Assert-True (Test-Path -LiteralPath $completed.Directory -PathType Container) 'Passing evidence did not promote the candidate.'
        $publishedManifest = Join-Path $completed.Directory 'deadline-candidate.json'
        $revalidated = Test-DeadlineSmokeEvidence -EvidencePath $evidencePath -CandidateManifestPath $publishedManifest
        Assert-Equal $isoPath $revalidated.ExecutedIsoPath 'Post-promotion validation forgot the exact quarantined ISO path that QEMU executed.'
        $latest = Get-Content -Raw -LiteralPath $latestPath | ConvertFrom-Json
        Assert-Equal $buildId $latest.build_id 'LATEST does not name the promoted build.'
        Assert-Equal (Get-LowerFileSha256 (Join-Path $completed.Directory $isoName)) $latest.iso_sha256 'LATEST hash differs from promoted bytes.'
        Assert-Equal 'immutable' ([System.IO.File]::ReadAllText((Join-Path $priorDirectory 'sentinel.bin'))) 'Prior published bytes changed.'
    }
    finally {
        if ([System.IO.Directory]::Exists($scratch)) { [System.IO.Directory]::Delete($scratch, $true) }
    }
}

Add-Test -Name 'Direct smoke contract is one-attempt BIOS optical and evidence driven' -Scopes @('SmokeUnit') -Body {
    $smokePath = Join-Path $script:RepositoryRoot 'scripts/host/Invoke-DeadlineSmoke.ps1'
    Assert-True (Test-Path -LiteralPath $smokePath -PathType Leaf) 'Direct deadline smoke runner is missing.'
    $smokeSource = Get-RepoText 'scripts/host/Invoke-DeadlineSmoke.ps1'
    Assert-Match $smokeSource '\[switch\]\s*\$RecoverHostObservationFailure' 'The exceptional recovery is not an explicit public switch.'
    Assert-Match $smokeSource '-EnableHostObservationRecovery:\$RecoverHostObservationFailure' 'The public recovery switch is not bound to the closed recovery path.'
    . $smokePath
    foreach ($functionName in @('New-DeadlineQemuArguments','Get-DeadlineSerialFacts','Read-DeadlinePpm','New-DeadlineAttemptRecord','Invoke-DeadlineQmpCommand')) {
        Assert-True ($null -ne (Get-Command $functionName -CommandType Function -ErrorAction SilentlyContinue)) "Smoke function is missing: $functionName"
    }
    Assert-True (Test-DeadlineRecoveryTimestamp -Value ([System.DateTimeOffset]::UtcNow)) 'An already-parsed canonical timestamp was rejected.'
    Assert-True (Test-DeadlineRecoveryTimestamp -Value ([System.DateTimeOffset]::UtcNow.ToString('o'))) 'Invariant round-trip timestamp text was rejected.'
    Assert-False (Test-DeadlineRecoveryTimestamp -Value '08/27/not-a-canonical-timestamp') 'Malformed timestamp text was accepted.'

    $args = New-DeadlineQemuArguments -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -IsoPath 'D:\candidate.iso' -SerialPath 'D:\serial.log' -QmpPort 49153
    Assert-Equal @('-machine','pc','-accel','tcg','-m','1024','-boot','order=d,strict=on','-cdrom','D:\candidate.iso','-vga','std','-display','none','-serial','file:D:\serial.log','-qmp','tcp:127.0.0.1:49153,server=on,wait=off','-monitor','none','-nic','none','-no-reboot') @($args) 'QEMU argv differs from the direct BIOS optical contract.'
    foreach ($forbidden in @('-drive','-hda','-netdev','hostfwd','-snapshot')) { Assert-False (@($args) -ccontains $forbidden) "QEMU argv contains forbidden token $forbidden." }

    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-deadline-smoke-unit-' + [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($scratch) | Out-Null
    try {
        $serial = Join-Path $scratch 'serial.log'
        [System.IO.File]::WriteAllText($serial, "300K_STAGE=ROOTFS_READY`n300K_STAGE=X_READY`n300K_STAGE=UI_READY`n300K_STAGE=TERM_EXEC_OK uid=1000 user=chatgpt tty=/dev/pts/2 command=ok file=ok exit=1`n", [System.Text.UTF8Encoding]::new($false))
        $facts = Get-DeadlineSerialFacts -Path $serial
        Assert-Equal 1000 $facts.Terminal.uid 'PTY proof uid was not parsed.'
        Assert-Equal '/dev/pts/2' $facts.Terminal.tty 'PTY proof tty was not parsed.'
        [System.IO.File]::AppendAllText($serial, "300K_STAGE=UI_READY`n")
        Assert-Throws { Get-DeadlineSerialFacts -Path $serial } 'Duplicate stage was accepted.'

        $liveSerial = Join-Path $scratch 'live-serial.log'
        $liveWriter = [System.IO.FileStream]::new($liveSerial, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
            $splitCodePoint = $utf8.GetBytes([string][char]0x03C0)
            $liveWriter.Write($splitCodePoint, 0, 1)
            $liveWriter.Flush($true)
            Assert-ThrowsCode { Get-DeadlineSerialFacts -Path $liveSerial } 'DEADLINE_SERIAL_INCOMPLETE' 'A trailing partial UTF-8 code point was not classified as retryable.'

            $completeTail = $utf8.GetBytes(" preface`n300K_STAGE=ROOTFS_READY`n300K_STAGE=X_READY`n300K_STAGE=UI_READY`n300K_STAGE=TERM_EXEC_OK uid=1000 user=chatgpt tty=/dev/pts/7 command=ok file=ok exit=1`n")
            $completeBytes = [byte[]]::new($splitCodePoint.Length - 1 + $completeTail.Length)
            [System.Array]::Copy($splitCodePoint, 1, $completeBytes, 0, $splitCodePoint.Length - 1)
            [System.Array]::Copy($completeTail, 0, $completeBytes, $splitCodePoint.Length - 1, $completeTail.Length)
            $liveWriter.Write($completeBytes, 0, $completeBytes.Length)
            $liveWriter.Flush($true)
            $liveFacts = Get-DeadlineSerialFacts -Path $liveSerial
            Assert-Equal '/dev/pts/7' $liveFacts.Terminal.tty 'Share-safe live parsing lost the completed PTY marker.'
            Assert-ThrowsCode { Read-DeadlineSerialSnapshot -Path $liveSerial -MaxBytes 1 } 'DEADLINE_SERIAL_TOO_LARGE' 'The bounded snapshot reader accepted bytes beyond its explicit cap.'
        }
        finally { $liveWriter.Dispose() }

        $ppmPath = Join-Path $scratch 'screen.ppm'
        $bytes = [System.Collections.Generic.List[byte]]::new()
        $bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes("P6`n2 1`n255`n"))
        $bytes.AddRange([byte[]](0,0,0,255,255,255))
        [System.IO.File]::WriteAllBytes($ppmPath, $bytes.ToArray())
        $ppm = Read-DeadlinePpm -Path $ppmPath
        Assert-True $ppm.nonblank 'Two-color PPM was classified blank.'
        $attemptRoot = Join-Path $scratch 'attempts'
        $attempt = New-DeadlineAttemptRecord -AttemptRoot $attemptRoot -BuildId 'deadline-aaaaaaaaaaaa' -CandidateSha256 ('a' * 64) -EvidenceDirectory $scratch
        Assert-True (Test-Path -LiteralPath $attempt.Path -PathType Leaf) 'Attempt record was not durable.'
        Assert-Throws { New-DeadlineAttemptRecord -AttemptRoot $attemptRoot -BuildId 'deadline-aaaaaaaaaaaa' -CandidateSha256 ('a' * 64) -EvidenceDirectory $scratch } 'A second candidate attempt was accepted.'

        $recoveryRoot = Join-Path $scratch 'recovery-contract'
        $recoveryDist = Join-Path $recoveryRoot 'dist'
        $recoveryAttemptRoot = Join-Path $recoveryDist '.deadline-attempts'
        $recoveryEvidenceRoot = Join-Path $recoveryDist '.deadline-evidence'
        $newRecoveryFixture = {
            param(
                [Parameter(Mandatory)] [string] $BuildId,
                [string] $FailureCode = 'DEADLINE_SMOKE_FAILED',
                [string] $SerialText = 'ISOLINUX boot prompt',
                [switch] $AddScreen
            )
            $candidateIso = Join-Path $recoveryRoot ($BuildId + '.iso')
            [System.IO.Directory]::CreateDirectory($recoveryRoot) | Out-Null
            [System.IO.File]::WriteAllBytes($candidateIso, [byte[]](1..32))
            $candidateSha256 = Get-LowerFileSha256 -Path $candidateIso
            $candidateBytes = [long](Get-Item -LiteralPath $candidateIso).Length
            $predecessorEvidence = Join-Path $recoveryEvidenceRoot $BuildId
            [System.IO.Directory]::CreateDirectory($predecessorEvidence) | Out-Null
            $serialPath = Join-Path $predecessorEvidence 'serial.log'
            [System.IO.File]::WriteAllText($serialPath, $SerialText, [System.Text.UTF8Encoding]::new($false))
            $predecessor = New-DeadlineAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $BuildId -CandidateSha256 $candidateSha256 -EvidenceDirectory $predecessorEvidence
            $qemuArguments = New-DeadlineQemuArguments -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -IsoPath $candidateIso -SerialPath $serialPath -QmpPort 49154
            Write-CanonicalJson ([ordered]@{ executable='D:\VM\qemu\qemu-system-x86_64.exe'; argv=@($qemuArguments) }) (Join-Path $predecessorEvidence 'qemu-argv.json')
            $failureMessage = if ($FailureCode -ceq 'DEADLINE_SMOKE_FAILED') {
                "Exception calling `"ReadAllText`" with `"1`" argument(s): `"The process cannot access the file '$serialPath' because it is being used by another process.`""
            }
            else { 'QEMU exited before all deadline stages.' }
            Write-CanonicalJson ([ordered]@{ schema='DeadlineSmokeFailure'; schema_version=1; build_id=$BuildId; attempt_id=$predecessor.AttemptId; code=$FailureCode; message=$failureMessage; completed_utc=[System.DateTimeOffset]::UtcNow.ToString('o') }) (Join-Path $predecessorEvidence 'failure.json')
            Update-DeadlineAttemptRecord -Attempt $predecessor -Status 'failed' -FailureCode $FailureCode
            [System.IO.File]::Copy($predecessor.Path, (Join-Path $predecessorEvidence 'attempt.json'), $false)
            if ($AddScreen) { [System.IO.File]::WriteAllBytes((Join-Path $predecessorEvidence 'screen.ppm'), [byte[]](1,2,3)) }
            return [pscustomobject]@{
                BuildId=$BuildId; CandidateIso=$candidateIso; CandidateSha256=$candidateSha256; CandidateBytes=$candidateBytes
                Predecessor=$predecessor; PredecessorEvidence=$predecessorEvidence
            }
        }

        $validRecovery = & $newRecoveryFixture -BuildId ('deadline-' + ('b' * 12))
        $validPredecessorBytes = [System.IO.File]::ReadAllBytes($validRecovery.Predecessor.Path)
        $validPredecessorSha256 = Get-LowerFileSha256 -Path $validRecovery.Predecessor.Path
        $validArtifactHashes = @{}
        foreach ($name in @('attempt.json','failure.json','qemu-argv.json','serial.log')) {
            $validArtifactHashes[$name] = Get-LowerFileSha256 -Path (Join-Path $validRecovery.PredecessorEvidence $name)
        }
        $validSuccessorEvidence = Join-Path $recoveryEvidenceRoot 'valid-successor'
        [System.IO.Directory]::CreateDirectory($validSuccessorEvidence) | Out-Null
        Assert-ThrowsCode {
            New-DeadlineRecoveryAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $validRecovery.BuildId -CandidateSha256 ('0' * 64) -CandidateBytes $validRecovery.CandidateBytes -CandidateIsoPath $validRecovery.CandidateIso -EvidenceDirectory $validSuccessorEvidence -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -OwnedProcessCount 0
        } 'DEADLINE_RECOVERY_IDENTITY_INVALID' 'Recovery accepted a different candidate hash.'
        Assert-ThrowsCode {
            New-DeadlineRecoveryAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $validRecovery.BuildId -CandidateSha256 $validRecovery.CandidateSha256 -CandidateBytes ($validRecovery.CandidateBytes - 1) -CandidateIsoPath $validRecovery.CandidateIso -EvidenceDirectory $validSuccessorEvidence -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -OwnedProcessCount 0
        } 'DEADLINE_RECOVERY_IDENTITY_INVALID' 'Recovery accepted candidate byte count N-1.'
        Assert-ThrowsCode {
            New-DeadlineRecoveryAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $validRecovery.BuildId -CandidateSha256 $validRecovery.CandidateSha256 -CandidateBytes ($validRecovery.CandidateBytes + 1) -CandidateIsoPath $validRecovery.CandidateIso -EvidenceDirectory $validSuccessorEvidence -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -OwnedProcessCount 0
        } 'DEADLINE_RECOVERY_IDENTITY_INVALID' 'Recovery accepted candidate byte count N+1.'
        Assert-ThrowsCode {
            New-DeadlineRecoveryAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $validRecovery.BuildId -CandidateSha256 $validRecovery.CandidateSha256 -CandidateBytes $validRecovery.CandidateBytes -CandidateIsoPath $validRecovery.CandidateIso -EvidenceDirectory $validSuccessorEvidence -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -OwnedProcessCount 1
        } 'DEADLINE_RECOVERY_PROCESS_ACTIVE' 'Recovery accepted a still-owned predecessor process.'

        $ordinaryFailure = & $newRecoveryFixture -BuildId ('deadline-' + ('c' * 12)) -FailureCode 'DEADLINE_QEMU_EXITED_EARLY'
        $ordinarySuccessor = Join-Path $recoveryEvidenceRoot 'ordinary-successor'
        [System.IO.Directory]::CreateDirectory($ordinarySuccessor) | Out-Null
        Assert-ThrowsCode {
            New-DeadlineRecoveryAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $ordinaryFailure.BuildId -CandidateSha256 $ordinaryFailure.CandidateSha256 -CandidateBytes $ordinaryFailure.CandidateBytes -CandidateIsoPath $ordinaryFailure.CandidateIso -EvidenceDirectory $ordinarySuccessor -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -OwnedProcessCount 0
        } 'DEADLINE_RECOVERY_NOT_ALLOWED' 'An ordinary guest/runtime failure received a recovery attempt.'

        $malformedFailure = & $newRecoveryFixture -BuildId ('deadline-' + ('d' * 12))
        [System.IO.File]::WriteAllText((Join-Path $malformedFailure.PredecessorEvidence 'failure.json'), '{', [System.Text.UTF8Encoding]::new($false))
        $malformedSuccessor = Join-Path $recoveryEvidenceRoot 'malformed-successor'
        [System.IO.Directory]::CreateDirectory($malformedSuccessor) | Out-Null
        Assert-ThrowsCode {
            New-DeadlineRecoveryAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $malformedFailure.BuildId -CandidateSha256 $malformedFailure.CandidateSha256 -CandidateBytes $malformedFailure.CandidateBytes -CandidateIsoPath $malformedFailure.CandidateIso -EvidenceDirectory $malformedSuccessor -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -OwnedProcessCount 0
        } 'DEADLINE_RECOVERY_EVIDENCE_INVALID' 'Malformed predecessor evidence received a recovery attempt.'

        $observedFailure = & $newRecoveryFixture -BuildId ('deadline-' + ('e' * 12)) -SerialText "300K_STAGE=ROOTFS_READY`n"
        $observedSuccessor = Join-Path $recoveryEvidenceRoot 'observed-successor'
        [System.IO.Directory]::CreateDirectory($observedSuccessor) | Out-Null
        Assert-ThrowsCode {
            New-DeadlineRecoveryAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $observedFailure.BuildId -CandidateSha256 $observedFailure.CandidateSha256 -CandidateBytes $observedFailure.CandidateBytes -CandidateIsoPath $observedFailure.CandidateIso -EvidenceDirectory $observedSuccessor -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -OwnedProcessCount 0
        } 'DEADLINE_RECOVERY_NOT_ALLOWED' 'A predecessor with a 300K marker received a recovery attempt.'

        $screenFailure = & $newRecoveryFixture -BuildId ('deadline-' + ('f' * 12)) -AddScreen
        $screenSuccessor = Join-Path $recoveryEvidenceRoot 'screen-successor'
        [System.IO.Directory]::CreateDirectory($screenSuccessor) | Out-Null
        Assert-ThrowsCode {
            New-DeadlineRecoveryAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $screenFailure.BuildId -CandidateSha256 $screenFailure.CandidateSha256 -CandidateBytes $screenFailure.CandidateBytes -CandidateIsoPath $screenFailure.CandidateIso -EvidenceDirectory $screenSuccessor -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -OwnedProcessCount 0
        } 'DEADLINE_RECOVERY_NOT_ALLOWED' 'A predecessor with screenshot evidence received a recovery attempt.'

        $recoveryAttempt = New-DeadlineRecoveryAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $validRecovery.BuildId -CandidateSha256 $validRecovery.CandidateSha256 -CandidateBytes $validRecovery.CandidateBytes -CandidateIsoPath $validRecovery.CandidateIso -EvidenceDirectory $validSuccessorEvidence -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -OwnedProcessCount 0
        Assert-Equal 'DeadlineSmokeRecoveryAttempt' $recoveryAttempt.Record.schema 'Recovery record schema is not explicit.'
        Assert-Equal ($validRecovery.BuildId + '.recovery.json') ([System.IO.Path]::GetFileName($recoveryAttempt.Path)) 'Recovery did not use the single successor record namespace.'
        Assert-Equal $validPredecessorSha256 $recoveryAttempt.Record.predecessor_attempt_sha256 'Recovery record does not link the immutable predecessor SHA.'
        Assert-Equal $validRecovery.CandidateBytes ([long]$recoveryAttempt.Record.candidate_bytes) 'Recovery record lost exact candidate bytes.'
        Assert-Equal ([Convert]::ToHexString($validPredecessorBytes)) ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($validRecovery.Predecessor.Path))) 'Recovery changed predecessor attempt bytes.'
        foreach ($name in $validArtifactHashes.Keys) {
            Assert-Equal $validArtifactHashes[$name] (Get-LowerFileSha256 -Path (Join-Path $validRecovery.PredecessorEvidence $name)) "Recovery changed predecessor artifact '$name'."
        }
        Assert-ThrowsCode {
            New-DeadlineRecoveryAttemptRecord -AttemptRoot $recoveryAttemptRoot -BuildId $validRecovery.BuildId -CandidateSha256 $validRecovery.CandidateSha256 -CandidateBytes $validRecovery.CandidateBytes -CandidateIsoPath $validRecovery.CandidateIso -EvidenceDirectory $validSuccessorEvidence -QemuExecutable 'D:\VM\qemu\qemu-system-x86_64.exe' -OwnedProcessCount 0
        } 'DEADLINE_RECOVERY_ALREADY_EXISTS' 'A second recovery attempt was accepted.'
    }
    finally {
        if ([System.IO.Directory]::Exists($scratch)) { [System.IO.Directory]::Delete($scratch, $true) }
    }
}

Add-Test -Name 'Deadline documentation states exact commands and honest deferrals' -Scopes @('BuildStatic') -Body {
    $doc = Get-RepoText 'docs/DEADLINE-MVP.md'
    Assert-Match $doc 'build[.]ps1 -Backend Qemu -Target DeadlineMvp' 'Documentation lacks the exact deadline build command.'
    Assert-Match $doc 'Invoke-DeadlineSmoke[.]ps1' 'Documentation lacks the direct smoke command.'
    Assert-Match $doc 'RecoverHostObservationFailure' 'Documentation lacks the explicit exceptional host-observation recovery command.'
    foreach ($claim in @('unofficial','offline','BIOS optical','UEFI runtime','raw USB','Docker parity','second build','size optimization','exhaustive security','release certification')) {
        Assert-Match $doc ([regex]::Escape($claim)) "Documentation does not classify $claim."
    }
}

Add-Test -Name 'Published deadline pointer revalidates immutable boot evidence' -Scopes @('Evidence') -Body {
    . (Join-Path $script:RepositoryRoot 'build.ps1')
    $latest = if ([System.IO.Path]::IsPathRooted($LatestPath)) { [System.IO.Path]::GetFullPath($LatestPath) } else { [System.IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot $LatestPath)) }
    Assert-True (Test-Path -LiteralPath $latest -PathType Leaf) 'Published LATEST pointer is absent.'
    $dist = [System.IO.Directory]::GetParent($latest).FullName
    $pointer = Read-ClosedJsonArtifact -Path $latest -Code 'DEADLINE_LATEST_INVALID'
    Assert-ClosedObjectKeys $pointer @('schema_version','build_id','directory','iso_file','iso_sha256','iso_bytes','verification','smoke_evidence','smoke_evidence_sha256','screenshot_sha256','serial_sha256','source_commit') 'DEADLINE_LATEST_INVALID' 'Deadline LATEST'
    Assert-True ([int]$pointer.schema_version -eq 1 -and $pointer.build_id -cmatch '^deadline-[0-9a-f]{12}$' -and $pointer.directory -ceq $pointer.build_id -and $pointer.verification -ceq 'deadline-bios-optical') 'LATEST does not identify one promoted deadline BIOS proof.'
    Assert-True ($pointer.iso_file -cmatch '^300k-deadline-x86_64-[0-9a-f]{12}[.]iso$' -and $pointer.iso_sha256 -cmatch '^[0-9a-f]{64}$' -and [long]$pointer.iso_bytes -gt 0 -and $pointer.source_commit -cmatch '^[0-9a-f]{40}$') 'LATEST ISO or source identity is malformed.'
    $expectedEvidenceName = '.deadline-evidence/' + $pointer.build_id + '/deadline-smoke-evidence.json'
    Assert-Equal $expectedEvidenceName ([string]$pointer.smoke_evidence) 'LATEST smoke evidence path is outside the retained candidate-keyed namespace.'

    $manifestPath = Join-Path (Join-Path $dist $pointer.directory) 'deadline-candidate.json'
    $candidate = Test-DeadlineCandidateDirectory -CandidateManifestPath $manifestPath
    $evidencePath = Join-Path $dist ([string]$pointer.smoke_evidence)
    $validated = Test-DeadlineSmokeEvidence -EvidencePath $evidencePath -CandidateManifestPath $manifestPath
    $expectedExecutedIso = [System.IO.Path]::GetFullPath((Join-Path $dist ('.deadline-candidates\' + $candidate.BuildId + '\' + $candidate.IsoFile)))
    Assert-Equal $expectedExecutedIso $validated.ExecutedIsoPath 'Evidence no longer retains the exact quarantined ISO path QEMU executed.'
    Assert-Equal $candidate.IsoSha256 ([string]$pointer.iso_sha256) 'LATEST ISO hash differs from promoted bytes.'
    Assert-Equal $candidate.IsoBytes ([long]$pointer.iso_bytes) 'LATEST ISO byte count differs from promoted bytes.'
    Assert-Equal $candidate.SourceCommit ([string]$pointer.source_commit) 'LATEST source commit differs from the candidate.'
    Assert-Equal $validated.EvidenceSha256 ([string]$pointer.smoke_evidence_sha256) 'LATEST evidence hash differs from retained bytes.'
    Assert-Equal $validated.Evidence.screenshot.sha256 ([string]$pointer.screenshot_sha256) 'LATEST screenshot hash differs from retained bytes.'
    Assert-Equal $validated.Evidence.serial.sha256 ([string]$pointer.serial_sha256) 'LATEST serial hash differs from retained bytes.'
    $expectedQemu = [System.IO.Path]::GetFullPath((Join-Path $QemuRoot 'qemu-system-x86_64.exe'))
    Assert-True (Test-Path -LiteralPath $expectedQemu -PathType Leaf) 'Supplied QEMU executable is absent during evidence verification.'
    Assert-Equal $expectedQemu ([string]$validated.Evidence.qemu.executable) 'Evidence names a different QEMU executable.'
}

$selected = @($script:Tests | Where-Object {
    if ($Scope -ceq 'AllStatic') { $_.Scopes -contains 'RuntimeStatic' -or $_.Scopes -contains 'BuildStatic' -or $_.Scopes -contains 'Publication' -or $_.Scopes -contains 'SmokeUnit' }
    else { $_.Scopes -contains $Scope }
})

$passed = 0
$failed = 0
foreach ($test in $selected) {
    try {
        & $test.Body
        $passed++
        Write-Host "PASS $($test.Name)"
    }
    catch {
        $failed++
        Write-Host "FAIL $($test.Name): $($_.Exception.Message)"
    }
}

Write-Host "RESULT scope=$Scope passed=$passed failed=$failed"
if ($failed -ne 0) { exit 1 }
