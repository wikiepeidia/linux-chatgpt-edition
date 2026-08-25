Set-StrictMode -Version Latest

function New-CheckedProcessException {
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [string] $Message,
        [System.Exception] $InnerException
    )

    $exception = if ($null -eq $InnerException) {
        [System.InvalidOperationException]::new($Message)
    }
    else {
        [System.InvalidOperationException]::new($Message, $InnerException)
    }
    $exception.Data['Code'] = $Code
    return $exception
}

function ConvertTo-CheckedProcessSafeText {
    param(
        [AllowEmptyString()] [string] $Value,
        [string[]] $RedactValue = @()
    )

    $result = [string] $Value
    foreach ($secret in @($RedactValue)) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $result = $result.Replace($secret, '[REDACTED]', [System.StringComparison]::Ordinal)
        }
    }
    return $result
}

function Resolve-CheckedExecutable {
    param([Parameter(Mandatory)] [string] $FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath) -or $FilePath.IndexOfAny([char[]]@([char]0, "`r", "`n")) -ge 0) {
        throw (New-CheckedProcessException -Code 'PROCESS_INVALID_FILE' -Message 'Executable path is empty or contains a control character.')
    }
    if ([System.IO.Path]::IsPathRooted($FilePath)) {
        $resolved = [System.IO.Path]::GetFullPath($FilePath)
        if (-not [System.IO.File]::Exists($resolved)) {
            throw (New-CheckedProcessException -Code 'PROCESS_FILE_NOT_FOUND' -Message "Executable was not found: $resolved")
        }
        return $resolved
    }

    $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw (New-CheckedProcessException -Code 'PROCESS_FILE_NOT_FOUND' -Message "Executable was not found: $FilePath")
    }
    return [System.IO.Path]::GetFullPath($command.Source)
}

function Start-CheckedProcessLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 60,
        [string] $WorkingDirectory,
        [hashtable] $Environment = @{},
        [string[]] $AllowedEnvironmentVariables = @(
            'SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT', 'PATH',
            'TEMP', 'TMP', 'LOCALAPPDATA', 'PROGRAMDATA'
        ),
        [string[]] $RedactValue = @()
    )

    $resolvedExecutable = Resolve-CheckedExecutable -FilePath $FilePath
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    foreach ($argument in @($ArgumentList)) {
        if ($null -eq $argument -or ([string]$argument).IndexOf([char]0) -ge 0) {
            throw (New-CheckedProcessException -Code 'PROCESS_INVALID_ARGUMENT' -Message 'A process argument was null or contained a NUL character.')
        }
        [void] $startInfo.ArgumentList.Add([string] $argument)
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $resolvedWorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
        if (-not [System.IO.Directory]::Exists($resolvedWorkingDirectory)) {
            throw (New-CheckedProcessException -Code 'PROCESS_WORKING_DIRECTORY_NOT_FOUND' -Message "Working directory was not found: $resolvedWorkingDirectory")
        }
        $startInfo.WorkingDirectory = $resolvedWorkingDirectory
    }

    # Child processes receive only this explicit, non-secret allowlist plus caller
    # overrides. Ambient agents, proxies, credentials, and tool configuration do
    # not cross the process boundary accidentally.
    $startInfo.Environment.Clear()
    foreach ($name in @($AllowedEnvironmentVariables | Select-Object -Unique)) {
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw (New-CheckedProcessException -Code 'PROCESS_INVALID_ENVIRONMENT_NAME' -Message "Invalid environment variable name: $name")
        }
        $value = [System.Environment]::GetEnvironmentVariable($name, [System.EnvironmentVariableTarget]::Process)
        if ($null -ne $value) { $startInfo.Environment[$name] = $value }
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $name = [string] $entry.Key
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $null -eq $entry.Value -or ([string]$entry.Value).IndexOf([char]0) -ge 0) {
            throw (New-CheckedProcessException -Code 'PROCESS_INVALID_ENVIRONMENT' -Message 'An explicit environment entry was invalid.')
        }
        $startInfo.Environment[$name] = [string] $entry.Value
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw (New-CheckedProcessException -Code 'PROCESS_START_FAILED' -Message "Process did not start: $resolvedExecutable")
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
    }
    catch {
        $process.Dispose()
        if ($_.Exception.Data['Code']) { throw }
        throw (New-CheckedProcessException -Code 'PROCESS_START_FAILED' -Message "Failed to start process: $resolvedExecutable" -InnerException $_.Exception)
    }

    $started = [System.DateTimeOffset]::UtcNow
    return [pscustomobject]@{
        PSTypeName         = '300k.CheckedProcessLease'
        Process            = $process
        StandardOutputTask = $stdoutTask
        StandardErrorTask  = $stderrTask
        FilePath           = $resolvedExecutable
        TimeoutSeconds     = $TimeoutSeconds
        StartedUtc         = $started
        DeadlineUtc        = $started.AddSeconds($TimeoutSeconds)
        RedactValue        = @($RedactValue)
        Closed             = $false
        Result             = $null
    }
}

function Stop-CheckedProcessLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Lease,
        [ValidateRange(1, 300)] [int] $TimeoutSeconds = 10
    )

    if ($Lease.Closed) { return }
    $process = $Lease.Process
    try {
        if (-not $process.HasExited) {
            # The captured Process is the sole termination authority. Never look
            # up an executable name or enumerate unrelated processes.
            $process.Kill($true)
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                throw (New-CheckedProcessException -Code 'PROCESS_STOP_TIMEOUT' -Message "Owned process tree did not stop within $TimeoutSeconds seconds.")
            }
        }
    }
    catch [System.InvalidOperationException] {
        if (-not $process.HasExited) { throw }
    }
}

function Complete-CheckedProcessDrains {
    param(
        [Parameter(Mandatory)] $Lease,
        [ValidateRange(1, 300)] [int] $TimeoutSeconds
    )

    $tasks = [System.Threading.Tasks.Task[]]@(
        [System.Threading.Tasks.Task] $Lease.StandardOutputTask,
        [System.Threading.Tasks.Task] $Lease.StandardErrorTask
    )
    $all = [System.Threading.Tasks.Task]::WhenAll($tasks)
    if (-not $all.Wait($TimeoutSeconds * 1000)) {
        throw (New-CheckedProcessException -Code 'PROCESS_DRAIN_TIMEOUT' -Message "Process streams did not drain within $TimeoutSeconds seconds.")
    }

    return [pscustomobject]@{
        StandardOutput = ConvertTo-CheckedProcessSafeText -Value $Lease.StandardOutputTask.Result -RedactValue $Lease.RedactValue
        StandardError  = ConvertTo-CheckedProcessSafeText -Value $Lease.StandardErrorTask.Result -RedactValue $Lease.RedactValue
    }
}

function Wait-CheckedProcessLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Lease,
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 60,
        [switch] $AllowNonZero
    )

    if ($Lease.Closed) {
        throw (New-CheckedProcessException -Code 'PROCESS_LEASE_CLOSED' -Message 'Cannot wait on a closed process lease.')
    }
    if ($null -ne $Lease.Result) { return $Lease.Result }

    $remainingLeaseMilliseconds = [Math]::Max(1, [int][Math]::Floor(($Lease.DeadlineUtc - [System.DateTimeOffset]::UtcNow).TotalMilliseconds))
    $requestedMilliseconds = $TimeoutSeconds * 1000
    $waitMilliseconds = [Math]::Min($remainingLeaseMilliseconds, $requestedMilliseconds)
    if (-not $Lease.Process.WaitForExit($waitMilliseconds)) {
        Stop-CheckedProcessLease -Lease $Lease -TimeoutSeconds ([Math]::Min(10, $TimeoutSeconds))
        throw (New-CheckedProcessException -Code 'PROCESS_TIMEOUT' -Message "Owned process exceeded its bounded wait of $TimeoutSeconds seconds.")
    }

    $drains = Complete-CheckedProcessDrains -Lease $Lease -TimeoutSeconds ([Math]::Min(30, [Math]::Max(1, $TimeoutSeconds)))
    $result = [pscustomobject]@{
        PSTypeName     = '300k.CheckedProcessResult'
        FilePath       = $Lease.FilePath
        ProcessId      = $Lease.Process.Id
        ExitCode       = $Lease.Process.ExitCode
        StandardOutput = $drains.StandardOutput
        StandardError  = $drains.StandardError
        StartedUtc     = $Lease.StartedUtc
        CompletedUtc   = [System.DateTimeOffset]::UtcNow
    }
    $Lease.Result = $result

    if (-not $AllowNonZero -and $result.ExitCode -ne 0) {
        $message = "Process exited with code $($result.ExitCode): $($result.FilePath)"
        $exception = New-CheckedProcessException -Code 'PROCESS_EXIT_NONZERO' -Message $message
        $exception.Data['ExitCode'] = $result.ExitCode
        $exception.Data['StandardOutput'] = $result.StandardOutput
        $exception.Data['StandardError'] = $result.StandardError
        throw $exception
    }
    return $result
}

function Close-CheckedProcessLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Lease,
        [ValidateRange(1, 300)] [int] $TimeoutSeconds = 10
    )

    if ($Lease.Closed) { return }
    try {
        if (-not $Lease.Process.HasExited) {
            Stop-CheckedProcessLease -Lease $Lease -TimeoutSeconds $TimeoutSeconds
        }
        try {
            [void](Complete-CheckedProcessDrains -Lease $Lease -TimeoutSeconds $TimeoutSeconds)
        }
        catch {
            if ($_.Exception.Data['Code'] -ne 'PROCESS_DRAIN_TIMEOUT') { throw }
        }
    }
    finally {
        $Lease.Process.Dispose()
        $Lease.Closed = $true
    }
}

function Invoke-CheckedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 60,
        [string] $WorkingDirectory,
        [hashtable] $Environment = @{},
        [string[]] $AllowedEnvironmentVariables = @(
            'SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT', 'PATH',
            'TEMP', 'TMP', 'LOCALAPPDATA', 'PROGRAMDATA'
        ),
        [string[]] $RedactValue = @(),
        [switch] $AllowNonZero
    )

    $lease = $null
    try {
        $lease = Start-CheckedProcessLease -FilePath $FilePath -ArgumentList $ArgumentList `
            -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $WorkingDirectory `
            -Environment $Environment -AllowedEnvironmentVariables $AllowedEnvironmentVariables `
            -RedactValue $RedactValue
        return Wait-CheckedProcessLease -Lease $lease -TimeoutSeconds $TimeoutSeconds -AllowNonZero:$AllowNonZero
    }
    finally {
        if ($null -ne $lease) { Close-CheckedProcessLease -Lease $lease -TimeoutSeconds ([Math]::Min(10, $TimeoutSeconds)) }
    }
}
