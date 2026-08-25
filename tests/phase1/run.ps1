[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Docker', 'Qemu', 'Artifact', 'All')]
    [string] $Scope = 'Unit',

    [string] $Requirement,

    [string] $QemuRoot = 'D:\VM\qemu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:TestCases = [System.Collections.Generic.List[object]]::new()
$script:LoadErrors = [System.Collections.Generic.List[string]]::new()

function Add-TestCase {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string[]] $Scopes,
        [Parameter(Mandatory)] [string[]] $Requirements,
        [Parameter(Mandatory)] [scriptblock] $Body
    )

    $script:TestCases.Add([pscustomobject]@{
        Name         = $Name
        Scopes       = $Scopes
        Requirements = $Requirements
        Body         = $Body
    })
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
        if ($expectedJson -cne $actualJson) {
            throw "$Message Expected=$expectedJson Actual=$actualJson"
        }
        return
    }
    if ($Expected -cne $Actual) { throw "$Message Expected=<$Expected> Actual=<$Actual>" }
}

function Assert-Match {
    param([Parameter(Mandatory)] [string] $Value, [Parameter(Mandatory)] [string] $Pattern, [string] $Message = 'Value did not match.')
    if ($Value -notmatch $Pattern) { throw "$Message Pattern=<$Pattern> Value=<$Value>" }
}

function Assert-ThrowsCode {
    param(
        [Parameter(Mandatory)] [scriptblock] $Body,
        [Parameter(Mandatory)] [string] $Code
    )

    try {
        & $Body
    }
    catch {
        $actualCode = [string] $_.Exception.Data['Code']
        if ($actualCode -cne $Code) {
            throw "Expected exception code '$Code', received '$actualCode': $($_.Exception.Message)"
        }
        return
    }
    throw "Expected exception code '$Code', but no exception was thrown."
}

if ($Scope -in @('Unit', 'All')) {
    foreach ($relativeScript in @(
        'scripts/host/Invoke-CheckedProcess.ps1',
        'scripts/host/Invoke-QemuBackend.ps1'
    )) {
        $importPath = Join-Path $script:RepositoryRoot $relativeScript
        try { . $importPath }
        catch { $script:LoadErrors.Add("$relativeScript :: $($_.Exception.Message)") }
    }
    $buildEntry = Join-Path $script:RepositoryRoot 'build.ps1'
    if (Test-Path -LiteralPath $buildEntry) {
        try { . $buildEntry }
        catch { $script:LoadErrors.Add("build.ps1 :: $($_.Exception.Message)") }
    }
}

Add-TestCase -Name 'BUILD-04 checked process lease stays live during a second command and drains split streams' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $lease = $null
    try {
        $lease = Start-CheckedProcessLease -FilePath $pwshPath -ArgumentList @(
            '-NoProfile',
            '-Command',
            "[Console]::Out.WriteLine('lease-out'); [Console]::Error.WriteLine('lease-err'); Start-Sleep -Seconds 30"
        ) -TimeoutSeconds 35

        Start-Sleep -Milliseconds 300
        Assert-False -Condition $lease.Process.HasExited -Message 'The long-lived lease exited before management work began.'

        $probe = Invoke-CheckedProcess -FilePath $pwshPath -ArgumentList @(
            '-NoProfile',
            '-Command',
            "[Console]::Out.WriteLine('probe-out'); [Console]::Error.WriteLine('probe-err')"
        ) -TimeoutSeconds 10
        Assert-Match -Value $probe.StandardOutput -Pattern 'probe-out'
        Assert-Match -Value $probe.StandardError -Pattern 'probe-err'
        Assert-False -Condition $lease.Process.HasExited -Message 'Running a checked command detached or stopped the QEMU-style lease.'

        Stop-CheckedProcessLease -Lease $lease -TimeoutSeconds 5
        Assert-True -Condition $lease.Process.HasExited -Message 'The owned lease did not stop within the bound.'
    }
    finally {
        if ($null -ne $lease) {
            Close-CheckedProcessLease -Lease $lease -TimeoutSeconds 5
            Close-CheckedProcessLease -Lease $lease -TimeoutSeconds 5
        }
    }

    $drain = Invoke-CheckedProcess -FilePath $pwshPath -ArgumentList @(
        '-NoProfile',
        '-Command',
        "1..2500 | ForEach-Object { [Console]::Out.WriteLine('o' + `$_); [Console]::Error.WriteLine('e' + `$_) }"
    ) -TimeoutSeconds 20
    Assert-Match -Value $drain.StandardOutput -Pattern 'o2500'
    Assert-Match -Value $drain.StandardError -Pattern 'e2500'
}

Add-TestCase -Name 'BUILD-04 timeout stops only the captured process tree' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $source = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/host/Invoke-CheckedProcess.ps1')
    Assert-False -Condition ([bool]($source -match '(?im)\b(Get-Process|Stop-Process|taskkill|Win32_Process)\b')) -Message 'Process ownership may not be implemented through executable-name or global process lookup.'
    Assert-Match -Value $source -Pattern '\.Kill\s*\(\s*\$true\s*\)' -Message 'Owned timeout cleanup must kill the captured process tree.'

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $lease = Start-CheckedProcessLease -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutSeconds 30
    try {
        Assert-ThrowsCode -Code 'PROCESS_TIMEOUT' -Body {
            Wait-CheckedProcessLease -Lease $lease -TimeoutSeconds 1 | Out-Null
        }
        Assert-True -Condition $lease.Process.HasExited -Message 'Timeout did not stop the exact captured process.'
    }
    finally {
        Close-CheckedProcessLease -Lease $lease -TimeoutSeconds 5
    }
}

Add-TestCase -Name 'BUILD-04 serial trust accepts one ordered matching Ed25519 milestone only' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $keyBytes = [byte[]](0..31)
    $publicKey = [Convert]::ToBase64String($keyBytes)
    $valid = @(
        'boot diagnostic',
        '300K_NOCLOUD_BEGIN',
        "300K_SSH_HOST_KEY ssh-ed25519 $publicKey SHA256:fixtureFingerprint",
        '300K_SSH_READY'
    )
    $verify = { param($KeyType, $Key, $Fingerprint) $KeyType -ceq 'ssh-ed25519' -and $Key -ceq $publicKey -and $Fingerprint -ceq 'SHA256:fixtureFingerprint' }

    $parsed = Get-QemuSerialHostKey -SerialLines $valid -VerifyFingerprint $verify
    Assert-Equal -Expected 'ssh-ed25519' -Actual $parsed.KeyType
    Assert-Equal -Expected $publicKey -Actual $parsed.PublicKey
    Assert-Equal -Expected 'SHA256:fixtureFingerprint' -Actual $parsed.Fingerprint

    $invalidCases = @(
        @{ Code = 'SERIAL_MILESTONE_MISSING'; Lines = @('300K_NOCLOUD_BEGIN', '300K_SSH_READY') },
        @{ Code = 'SERIAL_MILESTONE_DUPLICATE'; Lines = @('300K_NOCLOUD_BEGIN', $valid[2], $valid[2], '300K_SSH_READY') },
        @{ Code = 'SERIAL_MILESTONE_MALFORMED'; Lines = @('300K_NOCLOUD_BEGIN', '300K_SSH_HOST_KEY ssh-rsa invalid SHA256:nope', '300K_SSH_READY') },
        @{ Code = 'SERIAL_MILESTONE_OUT_OF_ORDER'; Lines = @($valid[2], '300K_NOCLOUD_BEGIN', '300K_SSH_READY') }
    )
    foreach ($case in $invalidCases) {
        Assert-ThrowsCode -Code $case.Code -Body { Get-QemuSerialHostKey -SerialLines $case.Lines -VerifyFingerprint $verify | Out-Null }
    }
    Assert-ThrowsCode -Code 'SERIAL_FINGERPRINT_MISMATCH' -Body {
        Get-QemuSerialHostKey -SerialLines $valid -VerifyFingerprint { $false } | Out-Null
    }
}

Add-TestCase -Name 'BUILD-04 SSH and SCP ignore hostile ambient configuration and use only run-local trust' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-hostile-ssh-' + [Guid]::NewGuid().ToString('N'))
    $identity = Join-Path $scratch 'id_ed25519'
    $knownHosts = Join-Path $scratch 'known_hosts'
    New-Item -ItemType Directory -Path (Join-Path $scratch '.ssh') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $scratch '.ssh\config') -Value "Host *`n  ProxyCommand definitely-hostile`n  IdentityFile hostile-key" -NoNewline

    try {
        $before = New-IsolatedSshArgumentList -Tool ssh -IdentityFile $identity -KnownHostsFile $knownHosts -Port 22022 -RemoteUser builder -Payload @('true')
        $oldHome = $env:HOME
        $oldUserProfile = $env:USERPROFILE
        $env:HOME = $scratch
        $env:USERPROFILE = $scratch
        try {
            $after = New-IsolatedSshArgumentList -Tool ssh -IdentityFile $identity -KnownHostsFile $knownHosts -Port 22022 -RemoteUser builder -Payload @('true')
            $scp = New-IsolatedSshArgumentList -Tool scp -IdentityFile $identity -KnownHostsFile $knownHosts -Port 22022 -RemoteUser builder -Payload @('source.tar', 'builder@127.0.0.1:/inputs/source.tar')
        }
        finally {
            $env:HOME = $oldHome
            $env:USERPROFILE = $oldUserProfile
        }

        Assert-Equal -Expected $before -Actual $after -Message 'Ambient HOME/USERPROFILE changed strict SSH arguments.'
        $joined = ($after -join [char]0)
        foreach ($required in @(
            '-F', 'NUL', 'BatchMode=yes', 'IdentitiesOnly=yes', 'PreferredAuthentications=publickey',
            'PasswordAuthentication=no', 'KbdInteractiveAuthentication=no', 'IdentityAgent=none',
            'StrictHostKeyChecking=yes', "UserKnownHostsFile=$knownHosts", 'GlobalKnownHostsFile=NUL',
            'ProxyCommand=none', 'ProxyJump=none', 'KnownHostsCommand=none', 'ControlMaster=no',
            'HostKeyAlgorithms=ssh-ed25519', $identity
        )) {
            Assert-True -Condition $joined.Contains($required) -Message "Missing strict SSH argument '$required'."
        }
        Assert-False -Condition $joined.Contains('definitely-hostile') -Message 'Hostile user SSH configuration reached the invocation.'
        Assert-True -Condition (($scp -join [char]0).Contains('-P')) -Message 'SCP must use its uppercase port flag.'
    }
    finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Add-TestCase -Name 'BUILD-04 one idempotent outer resource owner cleans every acquired stage' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $stages = @('ports', 'seed-listener', 'ssh-key', 'known-hosts', 'overlay', 'qemu-lease', 'management-scratch')
    foreach ($failAt in 0..($stages.Count - 1)) {
        $counts = @{}
        $owner = New-QemuResourceOwner
        try {
            for ($index = 0; $index -lt $stages.Count; $index++) {
                $label = $stages[$index]
                $counts[$label] = 0
                Add-QemuOwnedResource -Owner $owner -Name $label -Cleanup {
                    param($cleanupState)
                    $cleanupState.Counts[$cleanupState.Label] = [int]$cleanupState.Counts[$cleanupState.Label] + 1
                } -CleanupArgument ([pscustomobject]@{ Counts = $counts; Label = $label })
                if ($index -eq $failAt) { throw "injected:$label" }
            }
        }
        catch {
            Assert-Match -Value $_.Exception.Message -Pattern '^injected:'
        }
        finally {
            Close-QemuResourceOwner -Owner $owner
            Close-QemuResourceOwner -Owner $owner
        }

        foreach ($entry in $counts.GetEnumerator()) {
            Assert-Equal -Expected 1 -Actual $entry.Value -Message "Cleanup for '$($entry.Key)' was not exactly once."
        }
    }

    $backendSource = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/host/Invoke-QemuBackend.ps1')
    Assert-Match -Value $backendSource -Pattern '(?s)function\s+Invoke-QemuBackend.*?try\s*\{.*?\}\s*finally\s*\{' -Message 'Invoke-QemuBackend must wrap acquisition and use in one outer try/finally.'
}

Add-TestCase -Name 'BUILD-04 NoCloud templates are public-only and emit the ordered Ed25519 serial milestone' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $meta = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'builder/cloud-init/meta-data.template')
    $user = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'builder/cloud-init/user-data.template')
    Assert-Match -Value $meta -Pattern 'instance-id:\s*@@INSTANCE_ID@@'
    Assert-Match -Value $user -Pattern '^#cloud-config'
    Assert-Match -Value $user -Pattern '300K_NOCLOUD_BEGIN'
    Assert-Match -Value $user -Pattern '300K_SSH_HOST_KEY'
    Assert-Match -Value $user -Pattern '300K_SSH_READY'
    Assert-Match -Value $user -Pattern 'ssh-ed25519'
    Assert-Match -Value $user -Pattern 'PasswordAuthentication\s+no'
    Assert-Match -Value $user -Pattern 'KbdInteractiveAuthentication\s+no'
    Assert-False -Condition ([bool]($meta + $user -match '(?i)BEGIN .*PRIVATE KEY|password:\s*[^!]|token:\s*\S+')) -Message 'NoCloud templates contain secret-bearing material.'
}

if ($Scope -in @('Qemu', 'All')) {
    Add-TestCase -Name 'BUILD-04 real clean-tree QEMU tracer' -Scopes @('Qemu') -Requirements @('BUILD-04') -Body {
        throw 'QEMU_SCOPE_NOT_IMPLEMENTED'
    }
}

$selected = @($script:TestCases | Where-Object {
    ($Scope -eq 'All' -or $_.Scopes -contains $Scope) -and
    ([string]::IsNullOrWhiteSpace($Requirement) -or $_.Requirements -contains $Requirement)
})

if ($selected.Count -eq 0) {
    Write-Error "No tests matched Scope='$Scope' Requirement='$Requirement'."
    exit 2
}

$failures = [System.Collections.Generic.List[string]]::new()
foreach ($loadError in $script:LoadErrors) {
    $failures.Add("load :: $loadError")
    Write-Host "FAIL load :: $loadError"
}

foreach ($test in $selected) {
    try {
        & $test.Body
        Write-Host "PASS $($test.Name)"
    }
    catch {
        $message = $_.Exception.Message -replace "[\r\n]+", ' '
        $failures.Add("$($test.Name) :: $message")
        Write-Host "FAIL $($test.Name) :: $message"
    }
}

Write-Host ("RESULT scope={0} requirement={1} passed={2} failed={3}" -f $Scope, $Requirement, ($selected.Count - $failures.Count), $failures.Count)
if ($failures.Count -gt 0) { exit 1 }
exit 0
