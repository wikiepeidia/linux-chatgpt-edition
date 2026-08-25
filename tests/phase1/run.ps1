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

if ($Scope -in @('Unit', 'Qemu', 'All')) {
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
    $sharedScratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-shared-serial-' + [Guid]::NewGuid().ToString('N'))
    $writer = [System.IO.FileStream]::new($sharedScratch, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("300K_NOCLOUD_BEGIN`n")
        $writer.Write($bytes, 0, $bytes.Length)
        $writer.Flush()
        $sharedLines = @(Read-SharedTextLines -Path $sharedScratch)
        Assert-Equal -Expected @('300K_NOCLOUD_BEGIN') -Actual $sharedLines -Message 'Serial log was not read cleanly while its writer remained live.'
    }
    finally {
        $writer.Dispose()
        Remove-Item -LiteralPath $sharedScratch -Force -ErrorAction SilentlyContinue
    }

    $rawKeyBytes = [byte[]](0..31)
    $wireKeyBytes = [byte[]](@(0, 0, 0, 11) + [System.Text.Encoding]::ASCII.GetBytes('ssh-ed25519') + @(0, 0, 0, 32) + $rawKeyBytes)
    $publicKey = [Convert]::ToBase64String($wireKeyBytes)
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
        @{ Code = 'SERIAL_MILESTONE_MALFORMED'; Lines = @('300K_NOCLOUD_BEGIN', "300K_SSH_HOST_KEY ssh-ed25519 $([Convert]::ToBase64String($rawKeyBytes)) SHA256:fixtureFingerprint", '300K_SSH_READY') },
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
    Assert-Equal -Expected '''alpha''"''"''beta; touch /tmp/forbidden''' -Actual (ConvertTo-PosixShellLiteral -Value "alpha'beta; touch /tmp/forbidden") -Message 'Remote SSH argv is not encoded as one POSIX literal.'
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
            'ConnectTimeout=60', 'ConnectionAttempts=1', 'HostKeyAlgorithms=ssh-ed25519', $identity
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
    $stages = @('ports', 'seed-listener', 'serial-listener', 'ssh-key', 'known-hosts', 'overlay', 'qemu-lease', 'management-scratch')
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
    Initialize-NoCloudSeedServerType
    Assert-True -Condition ($null -ne ('ThreeHundredK.NoCloudSeedServer' -as [type])) -Message 'NoCloud seed server type did not compile.'
    Assert-True -Condition ($null -ne ('ThreeHundredK.SerialCaptureServer' -as [type])) -Message 'Serial capture server type did not compile.'
    $meta = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'builder/cloud-init/meta-data.template')
    $user = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'builder/cloud-init/user-data.template')
    Assert-Match -Value $meta -Pattern 'instance-id:\s*@@INSTANCE_ID@@'
    Assert-Match -Value $user -Pattern '^#cloud-config'
    Assert-Match -Value $user -Pattern '(?s)growpart:.*?mode:\s*auto.*?devices:\s*\[''/''\].*?resize_rootfs:\s*true' -Message 'NoCloud does not expand the tiny pinned cloud disk before package installation.'
    Assert-Match -Value $user -Pattern '300K_NOCLOUD_BEGIN'
    Assert-Match -Value $user -Pattern '300K_SSH_HOST_KEY'
    Assert-Match -Value $user -Pattern '300K_SSH_READY'
    Assert-Match -Value $user -Pattern 'ssh-ed25519'
    Assert-Match -Value $user -Pattern 'PasswordAuthentication\s+no'
    Assert-Match -Value $user -Pattern 'KbdInteractiveAuthentication\s+no'
    Assert-Match -Value $user -Pattern 'lock_passwd:\s*false'
    Assert-Match -Value $user -Pattern 'hashed_passwd:\s*''\$6\$[A-Za-z0-9./]+\$[A-Za-z0-9./]+'''
    Assert-Match -Value $user -Pattern 'AuthenticationMethods\s+publickey'
    Assert-Match -Value $user -Pattern 'PermitEmptyPasswords\s+no'
    Assert-Match -Value $user -Pattern '300K_MANAGEMENT_KEY'
    Assert-False -Condition ([bool]($meta + $user -match '(?i)BEGIN .*PRIVATE KEY|password:\s*[^!]|token:\s*\S+')) -Message 'NoCloud templates contain secret-bearing material.'
}

Add-TestCase -Name 'BUILD-04 KeyInitRequest BuildRequest and ResolvedBuildLock enforce temporal ordering' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $inputs = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'builder/inputs.json') | ConvertFrom-Json -Depth 30
    $keyRequest = New-KeyInitRequest -Inputs $inputs -RunNonce '0123456789abcdef0123456789abcdef'
    $keyJson = $keyRequest | ConvertTo-Json -Depth 30 -Compress
    Assert-Match -Value $keyJson -Pattern 'KeyInitRequest'
    Assert-False -Condition ([bool]($keyJson -match '(?i)public_key_sha256|signing_public')) -Message 'KeyInitRequest contains an identity that does not exist yet.'

    $source = [pscustomobject]@{
        git_commit = ('a' * 40)
        archive_sha256 = ('b' * 64)
        source_date_epoch = 1787670000
        dirty = $false
    }
    $hashes = [ordered]@{
        inputs_sha256 = ('c' * 64)
        run_build_sha256 = ('d' * 64)
        profile_sha256 = ('e' * 64)
    }
    Assert-ThrowsCode -Code 'SIGNING_PUBLIC_REQUIRED' -Body {
        New-BuildRequest -Inputs $inputs -Source $source -InputHashes $hashes -SigningPublic $null | Out-Null
    }

    $signing = [pscustomobject]@{ schema = 'SigningPublic'; public_key_file = '300k.rsa.pub'; public_key_sha256 = ('f' * 64) }
    $request = New-BuildRequest -Inputs $inputs -Source $source -InputHashes $hashes -SigningPublic $signing
    $requestJson = $request | ConvertTo-Json -Depth 30 -Compress
    foreach ($forbidden in @('resolved_build_lock', 'apk_files', 'private', 'backend_observations', 'output_sha256', 'self_hash')) {
        Assert-False -Condition ([bool]($requestJson -match $forbidden)) -Message "BuildRequest contains forbidden post-resolution field '$forbidden'."
    }
    Assert-Match -Value $requestJson -Pattern 'BuildRequest'

    $requestHash = '1' * 64
    $validLock = [pscustomobject]@{
        schema = 'ResolvedBuildLock'
        build_request_sha256 = $requestHash
        repository_object_id = ('2' * 64)
        artifacts = @()
        inspection_commands = @()
    }
    [void](Test-ResolvedBuildLock -Lock $validLock -ExpectedBuildRequestSha256 $requestHash -AllowEmptyArtifacts)
    Assert-ThrowsCode -Code 'RESOLVED_LOCK_REQUEST_MISMATCH' -Body {
        Test-ResolvedBuildLock -Lock $validLock -ExpectedBuildRequestSha256 ('3' * 64) -AllowEmptyArtifacts | Out-Null
    }
}

Add-TestCase -Name 'BUILD-04 generated artifact ownership and independent host validation are closed' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-records-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    try {
        $file = Join-Path $scratch 'builder-packages.lock'
        [System.IO.File]::WriteAllText($file, "busybox-1.37.0-r31`n", [System.Text.UTF8Encoding]::new($false))
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $record = [pscustomobject]@{
            file = 'builder-packages.lock'
            sha256 = $hash
            bytes = (Get-Item -LiteralPath $file).Length
            producer = 'run-build.sh:prepare-repository'
            validator = 'build.ps1:Test-GeneratedFileRecord'
        }
        [void](Test-GeneratedFileRecord -Record $record -BaseDirectory $scratch -ExpectedProducer 'run-build.sh:prepare-repository')

        foreach ($badRecord in @(
            [pscustomobject]@{ file = '..\escape'; sha256 = $hash; bytes = 1; producer = $record.producer; validator = $record.validator },
            [pscustomobject]@{ file = $record.file; sha256 = $hash.ToUpperInvariant(); bytes = $record.bytes; producer = $record.producer; validator = $record.validator },
            [pscustomobject]@{ file = $record.file; sha256 = $hash; bytes = 0; producer = $record.producer; validator = $record.validator },
            [pscustomobject]@{ file = $record.file; sha256 = $hash; bytes = $record.bytes; producer = 'some-other-producer'; validator = $record.validator }
        )) {
            Assert-ThrowsCode -Code 'GENERATED_RECORD_INVALID' -Body {
                Test-GeneratedFileRecord -Record $badRecord -BaseDirectory $scratch -ExpectedProducer 'run-build.sh:prepare-repository' | Out-Null
            }
        }
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }

    $allSource = (Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'build.ps1')) + (Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/linux/run-build.sh'))
    Assert-False -Condition ([bool]($allSource -match '(?<!builder-)packages\.lock')) -Message 'A dangling packages.lock ownership reference remains.'
}

Add-TestCase -Name 'BUILD-04 public inputs pin the complete builder and inspection command surface' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $inputsPath = Join-Path $script:RepositoryRoot 'builder/inputs.json'
    $raw = Get-Content -Raw -LiteralPath $inputsPath
    $inputs = $raw | ConvertFrom-Json -Depth 30
    Assert-Equal -Expected '3.24.1' -Actual $inputs.alpine.release
    Assert-Equal -Expected 'x86_64' -Actual $inputs.target.arch
    Assert-Equal -Expected '52643b7a176095362fd87fe73cdb994cb2e5ffae' -Actual $inputs.aports.commit
    Assert-Equal -Expected '8d756f6fc7653daa4fb4e2e213d8a66007bcb1e5a846e28891af62c47b90685c694486c2746099ad99e9e8f5278db76b69d11dfe1e9361aa4c8406df16929a9c' -Actual $inputs.qemu.cloud_image_sha512

    $packages = @($inputs.builder_packages)
    foreach ($pin in @('gzip=1.14-r2', 'xz=5.8.3-r0', 'zstd=1.5.7-r2', 'lz4=1.10.0-r1', 'cpio=2.15-r0')) {
        Assert-True -Condition ($packages -ccontains $pin) -Message "Missing exact inspection package pin '$pin'."
    }
    foreach ($format in @('gzip', 'xz', 'zstd', 'lz4', 'cpio', 'squashfs', 'iso')) {
        $entry = $inputs.inspection_toolchain.$format
        Assert-True -Condition ($null -ne $entry) -Message "Inspection format '$format' is absent."
        Assert-Match -Value $entry.package -Pattern '^[a-z0-9+_.-]+=[0-9][A-Za-z0-9._-]*-r\d+$'
        Assert-Match -Value ([string]$entry.decoder[0]) -Pattern '^/' -Message "'$format' decoder is not an exact absolute command."
        Assert-True -Condition (@($entry.fixture_encoder).Count -gt 0) -Message "'$format' lacks a deterministic fixture encoder."
    }
    Assert-False -Condition ([bool]($raw -match '(?i)optional|\$PATH|latest-stable|/home/|[A-Z]:\\')) -Message 'Public inputs contain an ambient/moving/host-specific value.'
}

Add-TestCase -Name 'BUILD-04 source archive preserves LF-only guest shell scripts' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $attributes = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot '.gitattributes')
    Assert-Match -Value $attributes -Pattern '(?m)^\*\.sh text eol=lf$' -Message 'Git does not pin shell scripts to LF in archive output.'

    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-source-archive-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    try {
        foreach ($fixture in @(
            [pscustomobject]@{ Name = 'valid.tar'; Bytes = [System.Text.Encoding]::UTF8.GetBytes("#!/bin/sh`nset -eu`n"); ErrorCode = $null },
            [pscustomobject]@{ Name = 'crlf.tar'; Bytes = [System.Text.Encoding]::UTF8.GetBytes("#!/bin/sh`r`nset -eu`r`n"); ErrorCode = 'SOURCE_ARCHIVE_LINE_ENDINGS_INVALID' }
        )) {
            $path = Join-Path $scratch $fixture.Name
            $stream = [System.IO.File]::Create($path)
            $writer = [System.Formats.Tar.TarWriter]::new($stream, $false)
            try {
                foreach ($entryName in @('scripts/linux/run-build.sh', 'builder/profiles/mkimg.300k.sh')) {
                    $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, $entryName)
                    $entry.DataStream = [System.IO.MemoryStream]::new($fixture.Bytes, $false)
                    try { $writer.WriteEntry($entry) }
                    finally { $entry.DataStream.Dispose() }
                }
            }
            finally {
                $writer.Dispose()
                $stream.Dispose()
            }

            if ($null -eq $fixture.ErrorCode) {
                Assert-SourceArchiveUnixText -Path $path
            }
            else {
                Assert-ThrowsCode -Code $fixture.ErrorCode -Body { Assert-SourceArchiveUnixText -Path $path }
            }
        }
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

Add-TestCase -Name 'BUILD-04 repository drift aborts before the offline install boundary' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-repository-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    try {
        $apk = Join-Path $scratch 'fixture-1.0-r0.apk'
        [System.IO.File]::WriteAllBytes($apk, [byte[]](1..32))
        $manifest = Join-Path $scratch 'repository.sha256'
        $hash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText($manifest, "$hash  fixture-1.0-r0.apk`n", [System.Text.UTF8Encoding]::new($false))
        [void](Test-RepositorySnapshot -RepositoryDirectory $scratch -ManifestFile $manifest)
        [System.IO.File]::AppendAllText($apk, 'drift')
        Assert-ThrowsCode -Code 'REPOSITORY_DRIFT' -Body {
            Test-RepositorySnapshot -RepositoryDirectory $scratch -ManifestFile $manifest | Out-Null
        }
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }

    $linux = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/linux/run-build.sh')
    foreach ($pattern in @('init-signing-key', 'prepare-repository', 'build-from-local', 'file://', '--no-network', '300K_INJECT_REPOSITORY_DRIFT', 'ResolvedBuildLock', 'inspection_commands', 'network_disabled')) {
        Assert-Match -Value $linux -Pattern ([regex]::Escape($pattern)) -Message "Linux build core is missing '$pattern'."
    }
    Assert-Match -Value $linux -Pattern "printf '%s\\n' 'file:///repo'" -Message 'The target root does not receive the canonical local-only repository URL.'
    Assert-Match -Value $linux -Pattern '"\$build_root/repo/x86_64"' -Message 'The local v2 repository is not staged below its target architecture.'
    Assert-Match -Value $linux -Pattern 'apk --root "\$build_root" --arch x86_64 --initdb --keys-dir /etc/apk/keys' -Message 'APK root-relative key lookup or target architecture is not explicit.'
    Assert-Match -Value $linux -Pattern 'apk --cache-dir "\$online_cache" --repositories-file "\$online_repositories" update' -Message 'APK 3 repository indexes are not explicitly refreshed in an isolated cache.'
    Assert-Match -Value $linux -Pattern '(?s)repositories\.online.*?apk --cache-dir.*? update.*?apk --cache-dir.*? fetch --recursive' -Message 'Closure resolution does not follow the isolated repository update.'
    Assert-Match -Value $linux -Pattern '! -name repository\.sha256 ! -name repository\.sha256\.partial' -Message 'Repository manifest generation can include its own transient output.'
    Assert-False -Condition ([bool]($linux -match 'file://\$build_root|--keys-dir "\$build_root')) -Message 'APK root-relative paths were incorrectly expanded on the host side.'
    Assert-Match -Value $linux -Pattern '(?s)verify_repository_snapshot.*?disable_network.*?mkimage\.sh' -Message 'Repository verification, network disablement, and mkimage order is not fail-closed.'
}

Add-TestCase -Name 'BUILD-04 Docker and QEMU semantic records compare content without ISO byte identity' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $content = [pscustomobject]@{
        target = 'Bootstrap'; arch = 'x86_64'; source_archive_sha256 = ('a' * 64)
        build_request_sha256 = ('b' * 64); inputs_sha256 = ('c' * 64)
        run_build_sha256 = ('d' * 64); profile_sha256 = ('e' * 64)
        aports_commit = ('f' * 40); source_date_epoch = 1787670000
        signing_public_sha256 = ('1' * 64); repository_index_sha256 = @(('2' * 64), ('3' * 64))
        guest_roles = Get-CanonicalGuestRoles
    }
    $docker = [pscustomobject]@{ backend = 'docker'; transport = 'volume'; iso_sha256 = ('4' * 64); content = $content }
    $qemuContent = $content | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $qemu = [pscustomobject]@{ backend = 'qemu'; transport = 'ssh'; iso_sha256 = ('5' * 64); content = $qemuContent }
    Assert-True -Condition (Test-BuildSemanticParity -Left $docker -Right $qemu) -Message 'Semantically equal adapters were rejected due to transport/output differences.'
    $qemu.content.profile_sha256 = '6' * 64
    Assert-False -Condition (Test-BuildSemanticParity -Left $docker -Right $qemu) -Message 'A content-field mismatch was ignored.'
}

Add-TestCase -Name 'BUILD-04 Linux core owns package/profile decisions and the QEMU adapter remains transport-only' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $profile = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'builder/profiles/mkimg.300k.sh')
    Assert-Match -Value $profile -Pattern 'profile_300k_bootstrap'
    Assert-Match -Value $profile -Pattern 'profile_virt'
    Assert-False -Condition ([bool]($profile -match '(?i)apk add|xorriso|mkimage\.sh|linux-virt')) -Message 'The thin profile duplicated upstream assembly decisions.'
    Assert-True -Condition (($profile -split "`n").Count -le 12) -Message 'The bootstrap profile is no longer a thin profile_virt extension.'

    $qemu = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/host/Invoke-QemuBackend.ps1')
    Assert-Match -Value $qemu -Pattern '@\(''resize'', ''-f'', ''qcow2'', \$overlayPath, ''16G''\)' -Message 'The disposable cloud overlay is not expanded before boot.'
    Assert-False -Condition ([bool]($qemu -match '(?im)^\s*(apk\s+add|.*mkimage\.sh\s+--|profile_virt\s*\()')) -Message 'QEMU transport contains package/profile build logic.'
    Assert-Match -Value $qemu -Pattern 'install -d -m 700 -o builder -g builder /inputs /run/300k-secrets' -Message 'Guest input and tmpfs transfer directories are not explicitly owned by the ephemeral builder.'
    Assert-Match -Value $qemu -Pattern 'builder@127\.0\.0\.1:/run/300k-secrets/300k\.rsa' -Message 'The private APK key is not transferred directly into guest tmpfs.'
    Assert-False -Condition ([bool]($qemu -match 'builder@127\.0\.0\.1:/inputs/300k\.rsa[''"]')) -Message 'The private APK key still crosses the disk-backed guest input directory.'
    Assert-Match -Value $qemu -Pattern 'QEMU_SSH_FAILED.*SSH stage ''\$Stage'' failed' -Message 'Remote SSH failures do not retain their exact management stage.'
}

if ($Scope -in @('Qemu', 'All')) {
    Add-TestCase -Name 'BUILD-04 real clean-tree QEMU tracer' -Scopes @('Qemu') -Requirements @('BUILD-04') -Body {
        $gitPath = (Get-Command git.exe -CommandType Application -ErrorAction Stop).Source
        $cleanBefore = Invoke-CheckedProcess -FilePath $gitPath -ArgumentList @('status', '--porcelain', '--untracked-files=all') -WorkingDirectory $script:RepositoryRoot -TimeoutSeconds 30
        Assert-True -Condition ([string]::IsNullOrEmpty($cleanBefore.StandardOutput)) -Message "QEMU tracer requires an empty source tree before any external mutation.`n$($cleanBefore.StandardOutput)"

        $qemuExe = Join-Path $QemuRoot 'qemu-system-x86_64.exe'
        $qemuImg = Join-Path $QemuRoot 'qemu-img.exe'
        Assert-True -Condition ([System.IO.File]::Exists($qemuExe)) -Message "QEMU system emulator is missing: $qemuExe"
        Assert-True -Condition ([System.IO.File]::Exists($qemuImg)) -Message "QEMU image tool is missing: $qemuImg"

        $stateRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) '300k-linux-phase1-tracer'))
        $repositoryBoundary = $script:RepositoryRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        Assert-False -Condition ($stateRoot.StartsWith($repositoryBoundary, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'QEMU tracer state must resolve outside the repository.'

        $head = Invoke-CheckedProcess -FilePath $gitPath -ArgumentList @('rev-parse', 'HEAD') -WorkingDirectory $script:RepositoryRoot -TimeoutSeconds 30
        $sourceCommit = $head.StandardOutput.Trim()
        Assert-Match -Value $sourceCommit -Pattern '^[0-9a-f]{40}$' -Message 'Clean source commit is malformed.'

        $pwshPath = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
        $buildEntry = Join-Path $script:RepositoryRoot 'build.ps1'
        $commonArguments = @(
            '-NoProfile', '-File', $buildEntry,
            '-Backend', 'Auto',
            '-Target', 'Bootstrap',
            '-StateRoot', $stateRoot,
            '-QemuRoot', ([System.IO.Path]::GetFullPath($QemuRoot))
        )

        $initialization = Invoke-CheckedProcess -FilePath $pwshPath -ArgumentList ($commonArguments + '-InitializeSigningKey') -WorkingDirectory $script:RepositoryRoot -TimeoutSeconds 5400 -AllowNonZero
        if ($initialization.ExitCode -ne 0) {
            throw "Signing-key initialization child failed.`nSTDOUT:`n$($initialization.StandardOutput)`nSTDERR:`n$($initialization.StandardError)"
        }
        Assert-Match -Value $initialization.StandardOutput -Pattern 'signing-key-(?:already-)?initialized' -Message 'Initialization child returned no successful result.'

        $build = Invoke-CheckedProcess -FilePath $pwshPath -ArgumentList ($commonArguments + '-Clean') -WorkingDirectory $script:RepositoryRoot -TimeoutSeconds 14400 -AllowNonZero
        if ($build.ExitCode -ne 0) {
            throw "QEMU build child failed.`nSTDOUT:`n$($build.StandardOutput)`nSTDERR:`n$($build.StandardError)"
        }

        $latestPath = Join-Path $script:RepositoryRoot 'dist\LATEST.json'
        Assert-True -Condition ([System.IO.File]::Exists($latestPath)) -Message 'QEMU build did not publish dist/LATEST.json.'
        $latest = Get-Content -Raw -LiteralPath $latestPath | ConvertFrom-Json -Depth 32
        Assert-Match -Value $latest.build_id -Pattern '^p01-[0-9a-f]{12}$' -Message 'Published build ID is not request-hash-qualified.'
        Assert-Match -Value $latest.iso_file -Pattern '^300k-bootstrap-x86_64-[0-9a-f]{12}\.iso$' -Message 'Published ISO name is not hash-qualified.'
        Assert-Match -Value $latest.iso_sha256 -Pattern '^[0-9a-f]{64}$' -Message 'Published ISO SHA-256 is malformed.'
        Assert-True -Condition ([long]$latest.iso_bytes -gt 0) -Message 'Published ISO is empty.'

        $artifactRoot = Join-Path $script:RepositoryRoot (Join-Path 'dist' $latest.directory)
        foreach ($name in @(
            'build-request.json', 'resolved-build-lock.json', 'builder-packages.lock', 'apk-files.sha256',
            $latest.iso_file, 'boot-layout.txt', 'qemu-image-info.json', 'environment-report.json',
            'serial-evidence.log', 'repository-evidence.json', 'resource-inventory.json', 'artifact-manifest.json'
        )) {
            $path = Join-Path $artifactRoot $name
            Assert-True -Condition ([System.IO.File]::Exists($path)) -Message "Required QEMU evidence is absent: $name"
            Assert-True -Condition ((Get-Item -LiteralPath $path).Length -gt 0) -Message "Required QEMU evidence is empty: $name"
        }

        $isoPath = Join-Path $artifactRoot $latest.iso_file
        $isoHash = (Get-FileHash -LiteralPath $isoPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Equal -Expected $latest.iso_sha256 -Actual $isoHash -Message 'Published ISO bytes do not match LATEST.json.'
        Assert-Equal -Expected ([long]$latest.iso_bytes) -Actual ([long](Get-Item -LiteralPath $isoPath).Length) -Message 'Published ISO size does not match LATEST.json.'

        $requestPath = Join-Path $artifactRoot 'build-request.json'
        $request = Get-Content -Raw -LiteralPath $requestPath | ConvertFrom-Json -Depth 64
        $requestHash = (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $lock = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'resolved-build-lock.json') | ConvertFrom-Json -Depth 64
        Assert-Equal -Expected $requestHash -Actual $lock.build_request_sha256 -Message 'Guest ResolvedBuildLock belongs to a different BuildRequest.'
        Assert-Equal -Expected $sourceCommit -Actual $request.source.git_commit -Message 'Build evidence does not preserve the clean source commit.'
        Assert-False -Condition ([bool]$request.source.dirty) -Message 'BuildRequest marked the committed source dirty.'
        Assert-Match -Value $lock.repository_object_id -Pattern '^[0-9a-f]{64}$' -Message 'Content-addressed repository ID is malformed.'
        Assert-True -Condition ([bool]$lock.offline_install.apk_no_network) -Message 'Resolved lock does not prove apk --no-network.'
        Assert-True -Condition ([bool]$lock.offline_install.network_disabled) -Message 'Resolved lock does not prove networking was disabled before assembly.'
        Assert-True -Condition ([bool]$lock.offline_install.complete_manifest_verified) -Message 'Resolved lock does not prove complete manifest verification.'
        Assert-Equal -Expected @('file:///repo') -Actual @($lock.offline_install.repositories) -Message 'Offline build consumed a non-local repository.'

        $expectedFormats = @('gzip', 'xz', 'zstd', 'lz4', 'cpio', 'squashfs', 'iso')
        $commands = @($lock.inspection_commands)
        Assert-Equal -Expected $expectedFormats.Count -Actual $commands.Count -Message 'Resolved lock has an incomplete inspection command set.'
        Assert-Equal -Expected $expectedFormats -Actual @($commands.format) -Message 'Resolved lock inspection formats differ from public input.'
        foreach ($command in $commands) {
            Assert-Match -Value $command.package -Pattern '^[a-z0-9+_.-]+=[0-9][A-Za-z0-9._-]*-r\d+$' -Message 'Inspection package is not exactly pinned.'
            Assert-Match -Value $command.command -Pattern '^/' -Message 'Inspection command is not an exact absolute path.'
            Assert-Match -Value $command.command_sha256 -Pattern '^[0-9a-f]{64}$' -Message 'Inspection command hash is malformed.'
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($command.version)) -Message 'Inspection command version is absent.'
            foreach ($field in @('package_ownership_verified', 'path_verified', 'round_trip_verified')) {
                Assert-True -Condition ([bool]$command.$field) -Message "Inspection command '$($command.format)' did not prove $field."
            }
        }

        $repository = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'repository-evidence.json') | ConvertFrom-Json -Depth 32
        Assert-Equal -Expected $requestHash -Actual $repository.build_request_sha256 -Message 'Repository evidence belongs to a different request.'
        Assert-Equal -Expected $lock.repository_object_id -Actual $repository.repository_object_id -Message 'Repository evidence names a different content object.'
        Assert-True -Condition ([long]$repository.apk_count -gt 0) -Message 'Retained repository contains no APKs.'
        foreach ($field in @('official_indexes_verified', 'official_signatures_verified', 'content_addressed_snapshot_verified')) {
            Assert-True -Condition ([bool]$repository.$field) -Message "Repository evidence did not prove $field."
        }

        $environment = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'environment-report.json') | ConvertFrom-Json -Depth 32
        Assert-Equal -Expected 'qemu' -Actual $environment.backend
        Assert-Equal -Expected 'executed' -Actual $environment.backend_status
        Assert-Equal -Expected 'linux' -Actual $environment.guest_os
        Assert-Equal -Expected 'x86_64' -Actual $environment.guest_arch
        Assert-Equal -Expected '3.24.1' -Actual $environment.alpine_release
        Assert-Equal -Expected '8d756f6fc7653daa4fb4e2e213d8a66007bcb1e5a846e28891af62c47b90685c694486c2746099ad99e9e8f5278db76b69d11dfe1e9361aa4c8406df16929a9c' -Actual $environment.qemu_cloud_image_sha512
        Assert-Equal -Expected 'unverified-unavailable' -Actual $environment.docker_status -Message 'Absent Docker daemon was not recorded honestly.'
        Assert-Equal -Expected $sourceCommit -Actual $environment.source_commit
        Assert-Match -Value $environment.serial_host_fingerprint -Pattern '^SHA256:[A-Za-z0-9+/]+$' -Message 'Serial-derived SSH fingerprint is malformed.'
        Assert-True -Condition ([bool]$environment.cleanup_complete) -Message 'Environment report does not prove QEMU cleanup.'
        foreach ($stage in @('ssh-readiness-live', 'prepare-guest-live', 'input-transfer-live', 'private-key-tmpfs-live', 'prepare-repository-and-build-live', 'artifact-export-live', 'shutdown-complete')) {
            Assert-True -Condition (@($environment.live_management_stages) -ccontains $stage) -Message "Owned QEMU lease was not proven live at '$stage'."
        }

        $serial = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'serial-evidence.log')
        Assert-Match -Value $serial -Pattern '(?m)^300K_SSH_HOST_KEY ssh-ed25519 [A-Za-z0-9+/]+=* SHA256:[A-Za-z0-9+/]+$' -Message 'Sanitized serial evidence lacks the accepted SSH trust milestone.'
        Assert-Match -Value $serial -Pattern '(?m)^300K_BUILD_COMPLETE [0-9a-f]{64}$' -Message 'Sanitized serial evidence lacks the real build completion milestone.'

        $inventory = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'resource-inventory.json') | ConvertFrom-Json -Depth 16
        Assert-True -Condition ([bool]$inventory.cleanup_complete) -Message 'Resource inventory reports incomplete cleanup.'
        foreach ($property in $inventory.resources.PSObject.Properties) {
            Assert-False -Condition ([bool]$property.Value) -Message "Owned QEMU resource '$($property.Name)' remains after the tracer."
        }

        $cleanAfter = Invoke-CheckedProcess -FilePath $gitPath -ArgumentList @('status', '--porcelain', '--untracked-files=all') -WorkingDirectory $script:RepositoryRoot -TimeoutSeconds 30
        Assert-True -Condition ([string]::IsNullOrEmpty($cleanAfter.StandardOutput)) -Message "QEMU tracer dirtied the source tree.`n$($cleanAfter.StandardOutput)"
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
