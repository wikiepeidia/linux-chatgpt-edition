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
    foreach ($stage in @('ROOTFS_READY','X_READY','UI_READY')) {
        $count = [regex]::Matches($all, 'serial-stage\s+' + $stage).Count
        Assert-Equal 1 $count "Stage $stage must have exactly one authored producer."
    }
    Assert-Equal 1 ([regex]::Matches($all, 'TERM_EXEC_OK uid=').Count) 'TERM_EXEC_OK must be emitted only by the PTY proof.'
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
