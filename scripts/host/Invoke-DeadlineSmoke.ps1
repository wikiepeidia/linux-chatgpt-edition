[CmdletBinding()]
param(
    [string] $CandidateManifest,
    [string] $EvidenceDirectory,
    [string] $QemuRoot = 'D:\VM\qemu',
    [ValidateRange(60, 900)] [int] $TimeoutSeconds = 900,
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
    $attempt = New-DeadlineAttemptRecord -AttemptRoot (Join-Path $dist '.deadline-attempts') -BuildId $candidate.BuildId -CandidateSha256 $candidate.IsoSha256 -EvidenceDirectory $evidence
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
        $result = Invoke-DeadlineSmoke -CandidateManifestPath $CandidateManifest -OutputDirectory $EvidenceDirectory -SelectedQemuRoot $QemuRoot -BoundSeconds $TimeoutSeconds -EnablePromotion:$Promote
        Write-Output (ConvertTo-CanonicalJsonText $result)
        exit 0
    }
    catch {
        $code=[string]$_.Exception.Data['Code']; if ([string]::IsNullOrWhiteSpace($code)) { $code='DEADLINE_SMOKE_FAILED' }
        [Console]::Error.WriteLine("$code`: $($_.Exception.Message)")
        exit 1
    }
}
