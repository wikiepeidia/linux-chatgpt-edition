[CmdletBinding()]
param(
    [string] $CandidateManifest,
    [string] $EvidenceDirectory,
    [string] $QemuRoot = 'D:\VM\qemu',
    [ValidateRange(60, 900)] [int] $TimeoutSeconds = 900,
    [switch] $RecoverHostObservationFailure,
    [switch] $Promote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DeadlineRepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $script:DeadlineRepositoryRoot 'build.ps1')

function New-DeadlineAttemptRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AttemptRoot,
        [Parameter(Mandatory)] [string] $BuildId,
        [Parameter(Mandatory)] [string] $CandidateSha256,
        [Parameter(Mandatory)] [string] $EvidenceDirectory
    )
    if ($BuildId -cnotmatch '^deadline-[0-9a-f]{12}$' -or $CandidateSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw (New-BuildException -Code 'DEADLINE_ATTEMPT_IDENTITY_INVALID' -Message 'Attempt identity is malformed.')
    }
    $root = [System.IO.Path]::GetFullPath($AttemptRoot)
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    Assert-NoReparseAncestors $root
    $attemptId = [Guid]::NewGuid().ToString('N')
    $path = Join-Path $root ($BuildId + '.json')
    $record = [ordered]@{
        schema='DeadlineSmokeAttempt'; schema_version=1; build_id=$BuildId; candidate_sha256=$CandidateSha256
        attempt_id=$attemptId; status='started'; started_utc=[System.DateTimeOffset]::UtcNow.ToString('o')
        completed_utc=$null; evidence_directory=[System.IO.Path]::GetFullPath($EvidenceDirectory); failure_code=$null
    }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-CanonicalJsonText $record))
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch [System.IO.IOException] {
        throw (New-BuildException -Code 'DEADLINE_ATTEMPT_ALREADY_EXISTS' -Message 'This candidate already consumed its single smoke attempt.' -InnerException $_.Exception)
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    return [pscustomobject]@{ Path=$path; AttemptId=$attemptId; Record=$record }
}

function Update-DeadlineAttemptRecord {
    param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] [string] $Status, [string] $FailureCode)
    $record = $Attempt.Record
    $record.status = $Status
    $record.completed_utc = [System.DateTimeOffset]::UtcNow.ToString('o')
    $record.failure_code = if ([string]::IsNullOrWhiteSpace($FailureCode)) { $null } else { $FailureCode }
    $partial = $Attempt.Path + '.' + [Guid]::NewGuid().ToString('N') + '.partial'
    Write-CanonicalJson $record $partial
    [System.IO.File]::Move($partial, $Attempt.Path, $true)
}

function Get-DeadlineOwnedQemuProcessCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $QemuExecutable,
        [Parameter(Mandatory)] [string] $CandidateIsoPath,
        [Parameter(Mandatory)] [string] $SerialPath
    )
    if (-not $IsWindows) { throw (New-BuildException -Code 'DEADLINE_RECOVERY_PROCESS_CHECK_FAILED' -Message 'Deadline recovery process ownership can be verified only on the Windows build host.') }
    $expectedQemu = [System.IO.Path]::GetFullPath($QemuExecutable)
    $expectedIso = [System.IO.Path]::GetFullPath($CandidateIsoPath)
    $expectedSerial = [System.IO.Path]::GetFullPath($SerialPath)
    try { $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-x86_64.exe'" -ErrorAction Stop) }
    catch { throw (New-BuildException -Code 'DEADLINE_RECOVERY_PROCESS_CHECK_FAILED' -Message 'Owned QEMU process state could not be queried.' -InnerException $_.Exception) }
    $owned = 0
    foreach ($process in $processes) {
        if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or [System.IO.Path]::GetFullPath([string]$process.ExecutablePath) -ine $expectedQemu) { continue }
        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) { throw (New-BuildException -Code 'DEADLINE_RECOVERY_PROCESS_CHECK_FAILED' -Message 'A supplied-path QEMU process has an unreadable command line.') }
        if (
            $commandLine.IndexOf($expectedIso, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $commandLine.IndexOf($expectedSerial, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        ) { $owned++ }
    }
    return $owned
}

function Test-DeadlineRecoveryTimestamp {
    param([Parameter(Mandatory)] $Value)
    if ($Value -is [System.DateTimeOffset] -or $Value -is [System.DateTime]) { return $true }
    if ($Value -isnot [string]) { return $false }
    $parsed = [System.DateTimeOffset]::MinValue
    return [System.DateTimeOffset]::TryParseExact(
        $Value,
        'o',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )
}

function New-DeadlineRecoveryAttemptRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AttemptRoot,
        [Parameter(Mandatory)] [string] $BuildId,
        [Parameter(Mandatory)] [string] $CandidateSha256,
        [Parameter(Mandatory)] [long] $CandidateBytes,
        [Parameter(Mandatory)] [string] $CandidateIsoPath,
        [Parameter(Mandatory)] [string] $EvidenceDirectory,
        [Parameter(Mandatory)] [string] $QemuExecutable,
        [Parameter(Mandatory)] [int] $OwnedProcessCount
    )
    if ($BuildId -cnotmatch '^deadline-[0-9a-f]{12}$' -or $CandidateSha256 -cnotmatch '^[0-9a-f]{64}$' -or $CandidateBytes -le 0) {
        throw (New-BuildException -Code 'DEADLINE_RECOVERY_IDENTITY_INVALID' -Message 'Recovery candidate identity is malformed.')
    }
    $candidateItem = Get-Item -LiteralPath $CandidateIsoPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $candidateItem -or $candidateItem.PSIsContainer -or [long]$candidateItem.Length -ne $CandidateBytes -or (Get-LowerFileSha256 -Path $candidateItem.FullName) -cne $CandidateSha256) {
        throw (New-BuildException -Code 'DEADLINE_RECOVERY_IDENTITY_INVALID' -Message 'Recovery candidate hash or byte count differs from the exact ISO.')
    }
    if ($OwnedProcessCount -ne 0) { throw (New-BuildException -Code 'DEADLINE_RECOVERY_PROCESS_ACTIVE' -Message 'The predecessor still owns a QEMU process.') }

    $root = [System.IO.Path]::GetFullPath($AttemptRoot)
    if ([System.IO.Path]::GetFileName($root) -cne '.deadline-attempts') { throw (New-BuildException -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID' -Message 'Recovery attempt root is outside the closed deadline namespace.') }
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    Assert-NoReparseAncestors -Path $root
    $dist = [System.IO.Directory]::GetParent($root).FullName
    $evidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $dist '.deadline-evidence')).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $predecessorEvidence = [System.IO.Path]::GetFullPath((Join-Path $evidenceRoot $BuildId))
    $successorEvidence = [System.IO.Path]::GetFullPath($EvidenceDirectory)
    if (
        -not $successorEvidence.StartsWith($evidenceRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        $successorEvidence -ieq $predecessorEvidence
    ) { throw (New-BuildException -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID' -Message 'Recovery evidence must use a fresh successor directory under the deadline evidence root.') }
    Assert-NoReparseAncestors -Path $predecessorEvidence
    Assert-NoReparseAncestors -Path $successorEvidence

    $predecessorPath = Join-Path $root ($BuildId + '.json')
    $recoveryPath = Join-Path $root ($BuildId + '.recovery.json')
    if ([System.IO.File]::Exists($recoveryPath)) { throw (New-BuildException -Code 'DEADLINE_RECOVERY_ALREADY_EXISTS' -Message 'This candidate already consumed its single host-observation recovery.') }
    if (-not [System.IO.File]::Exists($predecessorPath) -or -not [System.IO.Directory]::Exists($predecessorEvidence)) {
        throw (New-BuildException -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID' -Message 'Recovery predecessor attempt or evidence is absent.')
    }
    $predecessorItem = Get-Item -LiteralPath $predecessorPath -Force
    if ($predecessorItem.PSIsContainer -or ($predecessorItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $predecessorItem.Length -le 0) {
        throw (New-BuildException -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID' -Message 'Recovery predecessor attempt is not one positive regular no-follow file.')
    }
    $predecessorSha256 = Get-LowerFileSha256 -Path $predecessorPath
    $predecessor = Read-ClosedJsonArtifact -Path $predecessorPath -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID'
    Assert-ClosedObjectKeys $predecessor @('schema','schema_version','build_id','candidate_sha256','attempt_id','status','started_utc','completed_utc','evidence_directory','failure_code') 'DEADLINE_RECOVERY_EVIDENCE_INVALID' 'Deadline recovery predecessor attempt'
    if (
        $predecessor.schema -cne 'DeadlineSmokeAttempt' -or [int]$predecessor.schema_version -ne 1 -or
        $predecessor.build_id -cne $BuildId -or $predecessor.candidate_sha256 -cne $CandidateSha256 -or
        $predecessor.attempt_id -cnotmatch '^[0-9a-f]{32}$' -or $predecessor.status -cne 'failed' -or
        $predecessor.failure_code -cne 'DEADLINE_SMOKE_FAILED' -or
        [System.IO.Path]::GetFullPath([string]$predecessor.evidence_directory) -ine $predecessorEvidence
    ) { throw (New-BuildException -Code 'DEADLINE_RECOVERY_NOT_ALLOWED' -Message 'The predecessor is not the closed host-observation failure eligible for recovery.') }
    if (
        -not (Test-DeadlineRecoveryTimestamp -Value $predecessor.started_utc) -or
        -not (Test-DeadlineRecoveryTimestamp -Value $predecessor.completed_utc)
    ) { throw (New-BuildException -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID' -Message 'Recovery predecessor timestamps are malformed.') }

    $attemptCopy = Get-ClosedRegularArtifact -BaseDirectory $predecessorEvidence -Name 'attempt.json'
    if ((Get-LowerFileSha256 -Path $attemptCopy.FullName) -cne $predecessorSha256) {
        throw (New-BuildException -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID' -Message 'Predecessor attempt copy differs from the immutable root record.')
    }
    $failurePath = (Get-ClosedRegularArtifact -BaseDirectory $predecessorEvidence -Name 'failure.json').FullName
    $failure = Read-ClosedJsonArtifact -Path $failurePath -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID'
    Assert-ClosedObjectKeys $failure @('schema','schema_version','build_id','attempt_id','code','message','completed_utc') 'DEADLINE_RECOVERY_EVIDENCE_INVALID' 'Deadline recovery predecessor failure'
    $serialPath = (Get-ClosedRegularArtifact -BaseDirectory $predecessorEvidence -Name 'serial.log').FullName
    $expectedFailureMessage = 'Exception calling "ReadAllText" with "1" argument(s): "The process cannot access the file ''' + $serialPath + ''' because it is being used by another process."'
    if (
        $failure.schema -cne 'DeadlineSmokeFailure' -or [int]$failure.schema_version -ne 1 -or
        $failure.build_id -cne $BuildId -or $failure.attempt_id -cne $predecessor.attempt_id -or
        $failure.code -cne 'DEADLINE_SMOKE_FAILED' -or $failure.message -cne $expectedFailureMessage
    ) { throw (New-BuildException -Code 'DEADLINE_RECOVERY_NOT_ALLOWED' -Message 'Failure evidence is not the exact live ReadAllText sharing failure.') }
    if (-not (Test-DeadlineRecoveryTimestamp -Value $failure.completed_utc)) {
        throw (New-BuildException -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID' -Message 'Recovery failure timestamp is malformed.')
    }

    $serialText = [System.IO.File]::ReadAllText($serialPath, [System.Text.UTF8Encoding]::new($false, $true))
    if (
        $serialText.Contains('300K_STAGE=', [System.StringComparison]::Ordinal) -or
        $serialText.Contains('TERM_EXEC_OK', [System.StringComparison]::Ordinal) -or
        [System.IO.File]::Exists((Join-Path $predecessorEvidence 'screen.ppm')) -or
        [System.IO.File]::Exists((Join-Path $predecessorEvidence 'deadline-smoke-evidence.json'))
    ) { throw (New-BuildException -Code 'DEADLINE_RECOVERY_NOT_ALLOWED' -Message 'Guest marker, PTY, screenshot, or completed smoke observation already exists.') }

    $qemuArgvPath = (Get-ClosedRegularArtifact -BaseDirectory $predecessorEvidence -Name 'qemu-argv.json').FullName
    $qemuArgv = Read-ClosedJsonArtifact -Path $qemuArgvPath -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID'
    Assert-ClosedObjectKeys $qemuArgv @('executable','argv') 'DEADLINE_RECOVERY_EVIDENCE_INVALID' 'Deadline recovery predecessor QEMU argv'
    if ([System.IO.Path]::GetFullPath([string]$qemuArgv.executable) -ine [System.IO.Path]::GetFullPath($QemuExecutable)) {
        throw (New-BuildException -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID' -Message 'Predecessor used a different QEMU executable.')
    }
    try { [void](Test-DeadlineQemuArguments -QemuExecutable $QemuExecutable -Arguments @($qemuArgv.argv) -IsoPath $candidateItem.FullName -SerialPath $serialPath) }
    catch { throw (New-BuildException -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID' -Message 'Predecessor QEMU argv differs from the exact candidate and serial path.' -InnerException $_.Exception) }
    if ((Get-LowerFileSha256 -Path $predecessorPath) -cne $predecessorSha256) {
        throw (New-BuildException -Code 'DEADLINE_RECOVERY_EVIDENCE_INVALID' -Message 'Predecessor attempt bytes changed during recovery validation.')
    }

    $attemptId = [Guid]::NewGuid().ToString('N')
    $record = [ordered]@{
        schema='DeadlineSmokeRecoveryAttempt'; schema_version=1; build_id=$BuildId; candidate_sha256=$CandidateSha256; candidate_bytes=[long]$CandidateBytes
        attempt_id=$attemptId; status='started'; started_utc=[System.DateTimeOffset]::UtcNow.ToString('o')
        completed_utc=$null; evidence_directory=$successorEvidence; failure_code=$null
        predecessor_attempt_file=[System.IO.Path]::GetFileName($predecessorPath); predecessor_attempt_sha256=$predecessorSha256
    }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-CanonicalJsonText $record))
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($recoveryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch [System.IO.IOException] {
        throw (New-BuildException -Code 'DEADLINE_RECOVERY_ALREADY_EXISTS' -Message 'This candidate already consumed its single host-observation recovery.' -InnerException $_.Exception)
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    return [pscustomobject]@{ Path=$recoveryPath; AttemptId=$attemptId; Record=$record }
}

function Read-DeadlineQmpLine {
    param([Parameter(Mandatory)] [System.IO.StreamReader] $Reader, [ValidateRange(1,60)] [int] $TimeoutSeconds = 10)
    $task = $Reader.ReadLineAsync()
    if (-not $task.Wait($TimeoutSeconds * 1000)) { throw (New-BuildException -Code 'DEADLINE_QMP_TIMEOUT' -Message 'QMP response timed out.') }
    if ($null -eq $task.Result) { throw (New-BuildException -Code 'DEADLINE_QMP_CLOSED' -Message 'QMP closed before returning a response.') }
    try { return $task.Result | ConvertFrom-Json -Depth 32 }
    catch { throw (New-BuildException -Code 'DEADLINE_QMP_INVALID' -Message 'QMP returned malformed JSON.' -InnerException $_.Exception) }
}

function Invoke-DeadlineQmpCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.IO.StreamReader] $Reader,
        [Parameter(Mandatory)] [System.IO.StreamWriter] $Writer,
        [Parameter(Mandatory)] [string] $Execute,
        $Arguments,
        [ValidateRange(1,60)] [int] $TimeoutSeconds = 15
    )
    $command = [ordered]@{ execute=$Execute }
    if ($null -ne $Arguments) { $command.arguments=$Arguments }
    $Writer.WriteLine(($command | ConvertTo-Json -Depth 16 -Compress))
    $Writer.Flush()
    $deadline = [System.DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([System.DateTimeOffset]::UtcNow -lt $deadline) {
        $remaining = [Math]::Max(1, [int][Math]::Ceiling(($deadline - [System.DateTimeOffset]::UtcNow).TotalSeconds))
        $response = Read-DeadlineQmpLine -Reader $Reader -TimeoutSeconds $remaining
        if ($null -ne $response.PSObject.Properties['event']) { continue }
        if ($null -ne $response.PSObject.Properties['error']) { throw (New-BuildException -Code 'DEADLINE_QMP_ERROR' -Message "QMP command '$Execute' failed.") }
        if ($null -ne $response.PSObject.Properties['return']) { return $response.return }
    }
    throw (New-BuildException -Code 'DEADLINE_QMP_TIMEOUT' -Message "QMP command '$Execute' did not complete.")
}

function Connect-DeadlineQmp {
    param([ValidateRange(1024,65535)] [int] $Port, [ValidateRange(1,60)] [int] $TimeoutSeconds = 30)
    $deadline = [System.DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $client = [System.Net.Sockets.TcpClient]::new()
    while ([System.DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $client.Connect([System.Net.IPAddress]::Loopback, $Port)
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $false, 4096, $true)
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false), 4096, $true)
            $writer.NewLine = "`n"
            $writer.AutoFlush = $true
            $greeting = Read-DeadlineQmpLine -Reader $reader -TimeoutSeconds 10
            if ($null -eq $greeting.PSObject.Properties['QMP']) { throw (New-BuildException -Code 'DEADLINE_QMP_INVALID' -Message 'QMP greeting is missing.') }
            [void](Invoke-DeadlineQmpCommand -Reader $reader -Writer $writer -Execute 'qmp_capabilities')
            return [pscustomobject]@{ Client=$client; Stream=$stream; Reader=$reader; Writer=$writer; QuitSent=$false }
        }
        catch {
            if ($client.Connected) { $client.Dispose(); throw }
            Start-Sleep -Milliseconds 250
        }
    }
    $client.Dispose()
    throw (New-BuildException -Code 'DEADLINE_QMP_CONNECT_TIMEOUT' -Message 'QMP did not become ready on its owned loopback endpoint.')
}

function Close-DeadlineQmp {
    param($Connection)
    if ($null -eq $Connection) { return }
    try { $Connection.Writer.Dispose() } catch {}
    try { $Connection.Reader.Dispose() } catch {}
    try { $Connection.Stream.Dispose() } catch {}
    try { $Connection.Client.Dispose() } catch {}
}

function Invoke-DeadlineSmoke {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CandidateManifestPath,
        [Parameter(Mandatory)] [string] $OutputDirectory,
        [Parameter(Mandatory)] [string] $SelectedQemuRoot,
        [ValidateRange(60,900)] [int] $BoundSeconds = 900,
        [switch] $EnableHostObservationRecovery,
        [switch] $EnablePromotion
    )
    $candidate = Test-DeadlineCandidateDirectory $CandidateManifestPath
    $candidateRoot = [System.IO.Directory]::GetParent($candidate.Directory).FullName
    if ([System.IO.Path]::GetFileName($candidateRoot) -cne '.deadline-candidates') { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_LOCATION_INVALID' -Message 'Smoke accepts only quarantined candidates.') }
    $dist = [System.IO.Directory]::GetParent($candidateRoot).FullName
    $evidence = [System.IO.Path]::GetFullPath($OutputDirectory)
    if ([System.IO.Directory]::Exists($evidence) -and @(Get-ChildItem -LiteralPath $evidence -Force).Count -ne 0) { throw (New-BuildException -Code 'DEADLINE_EVIDENCE_NOT_FRESH' -Message 'Evidence directory must be fresh and empty.') }
    [System.IO.Directory]::CreateDirectory($evidence) | Out-Null
    Assert-NoReparseAncestors $evidence
    $expectedEvidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $dist '.deadline-evidence')).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if (-not $evidence.StartsWith($expectedEvidenceRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw (New-BuildException -Code 'DEADLINE_EVIDENCE_LOCATION_INVALID' -Message 'Evidence must be retained under dist/.deadline-evidence.') }

    $qemu = [System.IO.Path]::GetFullPath((Join-Path $SelectedQemuRoot 'qemu-system-x86_64.exe'))
    if (-not [System.IO.File]::Exists($qemu)) { throw (New-BuildException -Code 'DEADLINE_QEMU_MISSING' -Message 'The supplied QEMU executable is absent.') }
    $serialPath = Join-Path $evidence 'serial.log'
    $screenPath = Join-Path $evidence 'screen.ppm'
    $stdoutPath = Join-Path $evidence 'qemu.stdout.log'
    $stderrPath = Join-Path $evidence 'qemu.stderr.log'
    $evidencePath = Join-Path $evidence 'deadline-smoke-evidence.json'
    $attemptRoot = Join-Path $dist '.deadline-attempts'
    if ($EnableHostObservationRecovery) {
        $predecessorSerial = Join-Path (Join-Path (Join-Path $dist '.deadline-evidence') $candidate.BuildId) 'serial.log'
        $ownedProcessCount = Get-DeadlineOwnedQemuProcessCount -QemuExecutable $qemu -CandidateIsoPath $candidate.IsoPath -SerialPath $predecessorSerial
        $attempt = New-DeadlineRecoveryAttemptRecord -AttemptRoot $attemptRoot -BuildId $candidate.BuildId -CandidateSha256 $candidate.IsoSha256 -CandidateBytes $candidate.IsoBytes -CandidateIsoPath $candidate.IsoPath -EvidenceDirectory $evidence -QemuExecutable $qemu -OwnedProcessCount $ownedProcessCount
    }
    else {
        $attempt = New-DeadlineAttemptRecord -AttemptRoot $attemptRoot -BuildId $candidate.BuildId -CandidateSha256 $candidate.IsoSha256 -EvidenceDirectory $evidence
    }
    [System.IO.File]::Copy($attempt.Path, (Join-Path $evidence 'attempt.json'), $false)

    $reservation = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $reservation.Start()
    $qmpPort = ([System.Net.IPEndPoint]$reservation.LocalEndpoint).Port
    $arguments = New-DeadlineQemuArguments -QemuExecutable $qemu -IsoPath $candidate.IsoPath -SerialPath $serialPath -QmpPort $qmpPort
    [void](Test-DeadlineQemuArguments $qemu $arguments $candidate.IsoPath $serialPath)
    Write-CanonicalJson ([ordered]@{ executable=$qemu; argv=@($arguments) }) (Join-Path $evidence 'qemu-argv.json')

    $lease = $null
    $qmp = $null
    $processResult = $null
    $facts = $null
    $ppm = $null
    $failureCode = $null
    try {
        $reservation.Stop()
        $lease = Start-CheckedProcessLease -FilePath $qemu -ArgumentList $arguments -TimeoutSeconds $BoundSeconds -WorkingDirectory $evidence
        $deadline = [System.DateTimeOffset]::UtcNow.AddSeconds($BoundSeconds)
        while ([System.DateTimeOffset]::UtcNow -lt $deadline) {
            if ($lease.Process.HasExited) { throw (New-BuildException -Code 'DEADLINE_QEMU_EXITED_EARLY' -Message 'QEMU exited before all deadline stages.') }
            if ([System.IO.File]::Exists($serialPath)) {
                try { $facts = Get-DeadlineSerialFacts $serialPath; break }
                catch {
                    $code = [string]$_.Exception.Data['Code']
                    if ($code -notin @('DEADLINE_SERIAL_INCOMPLETE','DEADLINE_SERIAL_MARKER_ORDER')) { throw }
                }
            }
            Start-Sleep -Milliseconds 500
        }
        if ($null -eq $facts) { throw (New-BuildException -Code 'DEADLINE_SMOKE_TIMEOUT' -Message 'Ordered ROOTFS/X/UI/TERM readiness did not arrive within the bound.') }

        $qmp = Connect-DeadlineQmp -Port $qmpPort -TimeoutSeconds 30
        [void](Invoke-DeadlineQmpCommand -Reader $qmp.Reader -Writer $qmp.Writer -Execute 'screendump' -Arguments ([ordered]@{ filename=$screenPath }) -TimeoutSeconds 30)
        $screenDeadline = [System.DateTimeOffset]::UtcNow.AddSeconds(15)
        while ([System.DateTimeOffset]::UtcNow -lt $screenDeadline -and (-not [System.IO.File]::Exists($screenPath) -or (Get-Item -LiteralPath $screenPath).Length -le 0)) { Start-Sleep -Milliseconds 200 }
        $ppm = Read-DeadlinePpm $screenPath
        if (-not $ppm.nonblank) { throw (New-BuildException -Code 'DEADLINE_SCREENSHOT_BLANK' -Message 'QMP screenshot contains only one pixel value.') }

        [void](Invoke-DeadlineQmpCommand -Reader $qmp.Reader -Writer $qmp.Writer -Execute 'quit' -TimeoutSeconds 15)
        $qmp.QuitSent = $true
        $processResult = Wait-CheckedProcessLease -Lease $lease -TimeoutSeconds 30 -AllowNonZero
        [System.IO.File]::WriteAllText($stdoutPath, [string]$processResult.StandardOutput, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($stderrPath, [string]$processResult.StandardError, [System.Text.UTF8Encoding]::new($false))

        $smoke = [ordered]@{
            schema='DeadlineSmokeEvidence'; schema_version=1; result='pass'; build_id=$candidate.BuildId; attempt_id=$attempt.AttemptId
            iso=[ordered]@{ file=$candidate.IsoFile; sha256=Get-LowerFileSha256 $candidate.IsoPath; bytes=[long](Get-Item $candidate.IsoPath).Length }
            qemu=[ordered]@{ executable=$qemu; argv=@($arguments); machine='pc'; firmware='bios'; media='optical-read-only'; nic='none'; memory_mib=1024 }
            markers=@($facts.Markers | ForEach-Object { [ordered]@{ stage=$_.stage; line=[int]$_.line } })
            terminal=[ordered]@{ uid=[int]$facts.Terminal.uid; user=$facts.Terminal.user; tty=$facts.Terminal.tty; command=$facts.Terminal.command; file=$facts.Terminal.file; exit=[int]$facts.Terminal.exit }
            serial=[ordered]@{ file='serial.log'; sha256=Get-LowerFileSha256 $serialPath; bytes=[long](Get-Item $serialPath).Length }
            screenshot=[ordered]@{ file='screen.ppm'; sha256=$ppm.sha256; bytes=[long]$ppm.bytes; width=[int]$ppm.width; height=[int]$ppm.height; max_value=255; distinct_pixels=[int]$ppm.distinct_pixels; nonblank=$true }
            deferred=Get-DeadlineDeferredClaims
        }
        Write-CanonicalJson $smoke $evidencePath
        [void](Test-DeadlineSmokeEvidence $evidencePath $candidate.ManifestPath)
        Update-DeadlineAttemptRecord -Attempt $attempt -Status 'smoke-passed'
        [System.IO.File]::Copy($attempt.Path, (Join-Path $evidence 'attempt.json'), $true)
        if ($EnablePromotion) {
            return Complete-DeadlineCandidate -CandidateManifestPath $candidate.ManifestPath -EvidencePath $evidencePath -DistRoot $dist
        }
        return [pscustomobject]@{ status='smoke-passed-not-promoted'; BuildId=$candidate.BuildId; Evidence=$evidencePath; IsoSha256=$candidate.IsoSha256; IsoBytes=$candidate.IsoBytes }
    }
    catch {
        $failureCode = [string]$_.Exception.Data['Code']
        if ([string]::IsNullOrWhiteSpace($failureCode)) { $failureCode='DEADLINE_SMOKE_FAILED' }
        Write-CanonicalJson ([ordered]@{ schema='DeadlineSmokeFailure'; schema_version=1; build_id=$candidate.BuildId; attempt_id=$attempt.AttemptId; code=$failureCode; message=$_.Exception.Message; completed_utc=[System.DateTimeOffset]::UtcNow.ToString('o') }) (Join-Path $evidence 'failure.json')
        Update-DeadlineAttemptRecord -Attempt $attempt -Status 'failed' -FailureCode $failureCode
        [System.IO.File]::Copy($attempt.Path, (Join-Path $evidence 'attempt.json'), $true)
        throw
    }
    finally {
        try { $reservation.Stop() } catch {}
        if ($null -ne $qmp) {
            if (-not $qmp.QuitSent) { try { [void](Invoke-DeadlineQmpCommand -Reader $qmp.Reader -Writer $qmp.Writer -Execute 'quit' -TimeoutSeconds 5); $qmp.QuitSent=$true } catch {} }
            Close-DeadlineQmp $qmp
        }
        if ($null -ne $lease) {
            if (-not $lease.Process.HasExited) { try { Stop-CheckedProcessLease -Lease $lease -TimeoutSeconds 10 } catch {} }
            if ($null -eq $processResult) {
                try {
                    $processResult=Wait-CheckedProcessLease -Lease $lease -TimeoutSeconds 15 -AllowNonZero
                    [System.IO.File]::WriteAllText($stdoutPath,[string]$processResult.StandardOutput,[System.Text.UTF8Encoding]::new($false))
                    [System.IO.File]::WriteAllText($stderrPath,[string]$processResult.StandardError,[System.Text.UTF8Encoding]::new($false))
                } catch {}
            }
            Close-CheckedProcessLease -Lease $lease -TimeoutSeconds 10
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ([string]::IsNullOrWhiteSpace($CandidateManifest) -or [string]::IsNullOrWhiteSpace($EvidenceDirectory)) { throw (New-BuildException -Code 'DEADLINE_SMOKE_ARGUMENT_MISSING' -Message '-CandidateManifest and -EvidenceDirectory are required.') }
        $result = Invoke-DeadlineSmoke -CandidateManifestPath $CandidateManifest -OutputDirectory $EvidenceDirectory -SelectedQemuRoot $QemuRoot -BoundSeconds $TimeoutSeconds -EnableHostObservationRecovery:$RecoverHostObservationFailure -EnablePromotion:$Promote
        Write-Output (ConvertTo-CanonicalJsonText $result)
        exit 0
    }
    catch {
        $code=[string]$_.Exception.Data['Code']; if ([string]::IsNullOrWhiteSpace($code)) { $code='DEADLINE_SMOKE_FAILED' }
        [Console]::Error.WriteLine("$code`: $($_.Exception.Message)")
        exit 1
    }
}
