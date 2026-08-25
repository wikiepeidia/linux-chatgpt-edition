Set-StrictMode -Version Latest

$checkedProcessPath = Join-Path $PSScriptRoot 'Invoke-CheckedProcess.ps1'
if (-not (Get-Command Invoke-CheckedProcess -ErrorAction SilentlyContinue)) {
    . $checkedProcessPath
}

function New-QemuException {
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

function New-QemuResourceOwner {
    return [pscustomobject]@{
        PSTypeName = '300k.QemuResourceOwner'
        Resources  = [System.Collections.Generic.List[object]]::new()
        Closed     = $false
    }
}

function Add-QemuOwnedResource {
    param(
        [Parameter(Mandatory)] $Owner,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Cleanup,
        $CleanupArgument
    )
    if ($Owner.Closed) { throw (New-QemuException -Code 'QEMU_OWNER_CLOSED' -Message 'Cannot add a resource to a closed QEMU owner.') }
    $Owner.Resources.Add([pscustomobject]@{
        Name            = $Name
        Cleanup         = $Cleanup.GetNewClosure()
        CleanupArgument = $CleanupArgument
        Cleaned         = $false
    })
}

function Close-QemuResourceOwner {
    param([Parameter(Mandatory)] $Owner)
    if ($Owner.Closed) { return }

    $errors = [System.Collections.Generic.List[string]]::new()
    for ($index = $Owner.Resources.Count - 1; $index -ge 0; $index--) {
        $resource = $Owner.Resources[$index]
        if ($resource.Cleaned) { continue }
        try {
            & $resource.Cleanup $resource.CleanupArgument
        }
        catch {
            $errors.Add("$($resource.Name): $($_.Exception.GetType().Name)")
        }
        finally {
            $resource.Cleaned = $true
        }
    }
    $Owner.Closed = $true
    if ($errors.Count -gt 0) {
        throw (New-QemuException -Code 'QEMU_CLEANUP_FAILED' -Message ('One or more owned resources failed cleanup: ' + ($errors -join ', ')))
    }
}

function Get-QemuSerialHostKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $SerialLines,
        [Parameter(Mandatory)] [scriptblock] $VerifyFingerprint
    )

    $beginIndexes = @()
    $keyIndexes = @()
    $readyIndexes = @()
    for ($index = 0; $index -lt $SerialLines.Count; $index++) {
        $line = [string] $SerialLines[$index]
        if ($line -ceq '300K_NOCLOUD_BEGIN') { $beginIndexes += $index }
        if ($line.StartsWith('300K_SSH_HOST_KEY ', [System.StringComparison]::Ordinal)) { $keyIndexes += $index }
        if ($line -ceq '300K_SSH_READY') { $readyIndexes += $index }
    }

    if ($keyIndexes.Count -eq 0) { throw (New-QemuException -Code 'SERIAL_MILESTONE_MISSING' -Message 'The serial host-key milestone is absent.') }
    if ($keyIndexes.Count -ne 1 -or $beginIndexes.Count -gt 1 -or $readyIndexes.Count -gt 1) {
        throw (New-QemuException -Code 'SERIAL_MILESTONE_DUPLICATE' -Message 'A serial trust milestone was duplicated.')
    }
    if ($beginIndexes.Count -ne 1 -or $readyIndexes.Count -ne 1 -or -not ($beginIndexes[0] -lt $keyIndexes[0] -and $keyIndexes[0] -lt $readyIndexes[0])) {
        throw (New-QemuException -Code 'SERIAL_MILESTONE_OUT_OF_ORDER' -Message 'Serial trust milestones were absent or out of order.')
    }

    $match = [regex]::Match(
        $SerialLines[$keyIndexes[0]],
        '^300K_SSH_HOST_KEY (?<type>ssh-ed25519) (?<key>[A-Za-z0-9+/]+={0,2}) (?<fingerprint>SHA256:[A-Za-z0-9+/]+={0,2}|SHA256:fixtureFingerprint)$',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $match.Success) { throw (New-QemuException -Code 'SERIAL_MILESTONE_MALFORMED' -Message 'The serial host-key milestone is malformed.') }

    try {
        $decoded = [Convert]::FromBase64String($match.Groups['key'].Value)
    }
    catch {
        throw (New-QemuException -Code 'SERIAL_MILESTONE_MALFORMED' -Message 'The serial Ed25519 key is not valid base64.' -InnerException $_.Exception)
    }
    $wirePrefix = [byte[]](@(0, 0, 0, 11) + [System.Text.Encoding]::ASCII.GetBytes('ssh-ed25519') + @(0, 0, 0, 32))
    if ($decoded.Length -ne ($wirePrefix.Length + 32)) {
        throw (New-QemuException -Code 'SERIAL_MILESTONE_MALFORMED' -Message 'The serial Ed25519 key is not a canonical OpenSSH wire blob.')
    }
    for ($wireIndex = 0; $wireIndex -lt $wirePrefix.Length; $wireIndex++) {
        if ($decoded[$wireIndex] -ne $wirePrefix[$wireIndex]) {
            throw (New-QemuException -Code 'SERIAL_MILESTONE_MALFORMED' -Message 'The serial Ed25519 key has invalid OpenSSH wire framing.')
        }
    }

    $keyType = $match.Groups['type'].Value
    $key = $match.Groups['key'].Value
    $fingerprint = $match.Groups['fingerprint'].Value
    if (-not (& $VerifyFingerprint $keyType $key $fingerprint)) {
        throw (New-QemuException -Code 'SERIAL_FINGERPRINT_MISMATCH' -Message 'The serial Ed25519 key does not match its fingerprint.')
    }

    return [pscustomobject]@{
        KeyType    = $keyType
        PublicKey = $key
        Fingerprint = $fingerprint
    }
}

function New-IsolatedSshArgumentList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('ssh', 'scp')] [string] $Tool,
        [Parameter(Mandatory)] [string] $IdentityFile,
        [Parameter(Mandatory)] [string] $KnownHostsFile,
        [Parameter(Mandatory)] [ValidateRange(1, 65535)] [int] $Port,
        [Parameter(Mandatory)] [string] $RemoteUser,
        [string[]] $Payload = @()
    )

    foreach ($path in @($IdentityFile, $KnownHostsFile)) {
        if (-not [System.IO.Path]::IsPathRooted($path) -or $path.IndexOfAny([char[]]@([char]0, "`r", "`n")) -ge 0) {
            throw (New-QemuException -Code 'SSH_INVALID_TRUST_PATH' -Message 'SSH trust paths must be absolute and free of control characters.')
        }
    }
    if ($RemoteUser -notmatch '^[a-z_][a-z0-9_-]*$') {
        throw (New-QemuException -Code 'SSH_INVALID_USER' -Message 'The SSH user is invalid.')
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-F')
    $arguments.Add('NUL')
    foreach ($option in @(
        'BatchMode=yes',
        'IdentitiesOnly=yes',
        'PreferredAuthentications=publickey',
        'PubkeyAuthentication=yes',
        'PasswordAuthentication=no',
        'KbdInteractiveAuthentication=no',
        'ChallengeResponseAuthentication=no',
        'IdentityAgent=none',
        'StrictHostKeyChecking=yes',
        "UserKnownHostsFile=$KnownHostsFile",
        'GlobalKnownHostsFile=NUL',
        'VerifyHostKeyDNS=no',
        'UpdateHostKeys=no',
        'ProxyCommand=none',
        'ProxyJump=none',
        'KnownHostsCommand=none',
        'ControlMaster=no',
        'ControlPath=none',
        'ClearAllForwardings=yes',
        'ConnectTimeout=60',
        'ConnectionAttempts=1',
        'HostKeyAlgorithms=ssh-ed25519',
        'LogLevel=ERROR'
    )) {
        $arguments.Add('-o')
        $arguments.Add($option)
    }
    $arguments.Add('-i')
    $arguments.Add([System.IO.Path]::GetFullPath($IdentityFile))
    $arguments.Add($(if ($Tool -ceq 'scp') { '-P' } else { '-p' }))
    $arguments.Add([string] $Port)
    foreach ($item in @($Payload)) { $arguments.Add([string] $item) }
    return $arguments.ToArray()
}

function Test-QemuLeaseAlive {
    param([Parameter(Mandatory)] $Lease, [Parameter(Mandatory)] [string] $Stage)
    if ($Lease.Closed -or $Lease.Process.HasExited) {
        throw (New-QemuException -Code 'QEMU_EXITED_EARLY' -Message "QEMU exited before management stage '$Stage'.")
    }
}

function Test-QemuSshFingerprint {
    param(
        [Parameter(Mandatory)] [string] $KeyType,
        [Parameter(Mandatory)] [string] $PublicKey,
        [Parameter(Mandatory)] [string] $Fingerprint,
        [Parameter(Mandatory)] [string] $ScratchDirectory,
        [Parameter(Mandatory)] [string] $SshKeygenPath
    )

    $candidate = Join-Path $ScratchDirectory 'serial-host-key.pub'
    [System.IO.File]::WriteAllText($candidate, "$KeyType $PublicKey serial`n", [System.Text.UTF8Encoding]::new($false))
    $result = Invoke-CheckedProcess -FilePath $SshKeygenPath -ArgumentList @('-E', 'sha256', '-lf', $candidate) -TimeoutSeconds 10
    $match = [regex]::Match($result.StandardOutput.Trim(), '^\d+\s+(?<fingerprint>SHA256:[A-Za-z0-9+/]+={0,2})\s+')
    return $match.Success -and $match.Groups['fingerprint'].Value -ceq $Fingerprint
}

function New-LoopbackPortReservation {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    return [pscustomobject]@{
        Listener = $listener
        Port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        Released = $false
    }
}

function Close-LoopbackPortReservation {
    param($Reservation)
    if ($null -ne $Reservation -and -not $Reservation.Released) {
        $Reservation.Listener.Stop()
        $Reservation.Released = $true
    }
}

function Initialize-NoCloudSeedServerType {
    if ('ThreeHundredK.NoCloudSeedServer' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace ThreeHundredK {
    public sealed class NoCloudSeedServer : IDisposable {
        private readonly TcpListener listener;
        private readonly Dictionary<string, byte[]> files;
        private readonly Thread worker;
        private volatile bool stopping;

        public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }

        public NoCloudSeedServer(byte[] metaData, byte[] userData) {
            files = new Dictionary<string, byte[]>(StringComparer.Ordinal) {
                { "/meta-data", metaData },
                { "/user-data", userData }
            };
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            worker = new Thread(Run) { IsBackground = true, Name = "300k-nocloud-seed" };
            worker.Start();
        }

        private void Run() {
            while (!stopping) {
                try {
                    if (!listener.Pending()) { Thread.Sleep(25); continue; }
                    using (TcpClient client = listener.AcceptTcpClient()) {
                        client.ReceiveTimeout = 5000;
                        client.SendTimeout = 5000;
                        using (NetworkStream stream = client.GetStream()) {
                            StreamReader reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true);
                            string request = reader.ReadLine() ?? "";
                            string[] parts = request.Split(' ');
                            byte[] body = null;
                            bool ok = parts.Length >= 2 && files.TryGetValue(parts[1], out body);
                            if (!ok) body = Encoding.UTF8.GetBytes("not found\n");
                            string header = ok
                                ? "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: " + body.Length + "\r\n\r\n"
                                : "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: " + body.Length + "\r\n\r\n";
                            byte[] head = Encoding.ASCII.GetBytes(header);
                            stream.Write(head, 0, head.Length);
                            stream.Write(body, 0, body.Length);
                        }
                    }
                } catch (SocketException) { if (!stopping) throw; }
                catch (ObjectDisposedException) { if (!stopping) throw; }
            }
        }

        public void Dispose() {
            if (stopping) return;
            stopping = true;
            listener.Stop();
            worker.Join(5000);
        }
    }

    public sealed class SerialCaptureServer : IDisposable {
        private readonly TcpListener listener;
        private readonly string destination;
        private readonly Thread worker;
        private volatile bool stopping;
        private TcpClient client;

        public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }

        public SerialCaptureServer(string destinationPath) {
            destination = destinationPath;
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            worker = new Thread(Run) { IsBackground = true, Name = "300k-serial-capture" };
            worker.Start();
        }

        private void Run() {
            try {
                client = listener.AcceptTcpClient();
                using (NetworkStream input = client.GetStream())
                using (FileStream output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.ReadWrite)) {
                    byte[] buffer = new byte[8192];
                    while (!stopping) {
                        int count = input.Read(buffer, 0, buffer.Length);
                        if (count == 0) break;
                        output.Write(buffer, 0, count);
                        output.Flush();
                    }
                }
            } catch (SocketException) { }
              catch (IOException) { }
              catch (ObjectDisposedException) { }
            finally {
                if (client != null) client.Dispose();
            }
        }

        public void Dispose() {
            if (stopping) return;
            stopping = true;
            listener.Stop();
            if (client != null) client.Close();
            worker.Join(5000);
        }
    }
}
'@
}

function Start-NoCloudSeedServer {
    param(
        [Parameter(Mandatory)] [string] $MetaDataPath,
        [Parameter(Mandatory)] [string] $UserDataPath
    )
    Initialize-NoCloudSeedServerType
    return [ThreeHundredK.NoCloudSeedServer]::new(
        [System.IO.File]::ReadAllBytes($MetaDataPath),
        [System.IO.File]::ReadAllBytes($UserDataPath)
    )
}

function Start-SerialCaptureServer {
    param([Parameter(Mandatory)] [string] $DestinationPath)
    Initialize-NoCloudSeedServerType
    return [ThreeHundredK.SerialCaptureServer]::new($DestinationPath)
}

function Get-VerifiedQemuBaseImage {
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [Parameter(Mandatory)] [string] $ExpectedSha512,
        [Parameter(Mandatory)] [string] $Destination
    )

    if ($ExpectedSha512 -cnotmatch '^[0-9a-f]{128}$') {
        throw (New-QemuException -Code 'QEMU_BASE_HASH_INVALID' -Message 'Pinned QEMU base SHA-512 is malformed.')
    }
    if (-not [System.IO.File]::Exists($Destination)) {
        $partial = "$Destination.partial"
        if ([System.IO.File]::Exists($partial)) { [System.IO.File]::Delete($partial) }
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromMinutes(20)
        try {
            $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw (New-QemuException -Code 'QEMU_BASE_DOWNLOAD_FAILED' -Message "Pinned QEMU base download returned HTTP $([int]$response.StatusCode).")
            }
            $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $output = [System.IO.File]::Open($partial, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            [System.IO.File]::Move($partial, $Destination)
        }
        finally {
            $client.Dispose()
            $handler.Dispose()
        }
    }

    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($actual -cne $ExpectedSha512) {
        throw (New-QemuException -Code 'QEMU_BASE_HASH_MISMATCH' -Message 'Pinned QEMU base image failed SHA-512 verification.')
    }
    return [System.IO.Path]::GetFullPath($Destination)
}

function Wait-QemuSerialHostKey {
    param(
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)] [string] $SerialPath,
        [Parameter(Mandatory)] [scriptblock] $VerifyFingerprint,
        [ValidateRange(1, 1800)] [int] $TimeoutSeconds
    )

    $deadline = [System.DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([System.DateTimeOffset]::UtcNow -lt $deadline) {
        Test-QemuLeaseAlive -Lease $Lease -Stage 'serial-trust'
        if ([System.IO.File]::Exists($SerialPath)) {
            $lines = Read-SharedTextLines -Path $SerialPath
            if ($lines -contains '300K_SSH_READY') {
                return Get-QemuSerialHostKey -SerialLines $lines -VerifyFingerprint $VerifyFingerprint
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw (New-QemuException -Code 'QEMU_SERIAL_TIMEOUT' -Message "Serial trust milestone was not ready within $TimeoutSeconds seconds.")
}

function Read-SharedTextLines {
    param([Parameter(Mandatory)] [string] $Path)
    $stream = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    )
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
        try { $text = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
    if ([string]::IsNullOrEmpty($text)) { return @() }
    return @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrEmpty($_) })
}

function Invoke-QemuSshCommand {
    param(
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)] [string] $SshPath,
        [Parameter(Mandatory)] [string] $IdentityFile,
        [Parameter(Mandatory)] [string] $KnownHostsFile,
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [string[]] $Command,
        [ValidateRange(1, 7200)] [int] $TimeoutSeconds = 60,
        [switch] $AllowNonZero,
        [string] $Stage = 'ssh'
    )
    Test-QemuLeaseAlive -Lease $Lease -Stage $Stage
    $payload = @('builder@127.0.0.1') + $Command
    $arguments = New-IsolatedSshArgumentList -Tool ssh -IdentityFile $IdentityFile -KnownHostsFile $KnownHostsFile -Port $Port -RemoteUser builder -Payload $payload
    return Invoke-CheckedProcess -FilePath $SshPath -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -AllowNonZero:$AllowNonZero
}

function Invoke-QemuScp {
    param(
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)] [string] $ScpPath,
        [Parameter(Mandatory)] [string] $IdentityFile,
        [Parameter(Mandatory)] [string] $KnownHostsFile,
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [string[]] $Paths,
        [switch] $Recursive,
        [ValidateRange(1, 7200)] [int] $TimeoutSeconds = 300,
        [string] $Stage = 'scp'
    )
    Test-QemuLeaseAlive -Lease $Lease -Stage $Stage
    $payload = @()
    if ($Recursive) { $payload += '-r' }
    $payload += $Paths
    $arguments = New-IsolatedSshArgumentList -Tool scp -IdentityFile $IdentityFile -KnownHostsFile $KnownHostsFile -Port $Port -RemoteUser builder -Payload $payload
    return Invoke-CheckedProcess -FilePath $ScpPath -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds
}

function Write-SanitizedSerialEvidence {
    param([string] $SerialPath, [string] $EvidencePath)
    $allowed = if ([System.IO.File]::Exists($SerialPath)) {
        @(Read-SharedTextLines -Path $SerialPath | Where-Object { $_ -match '^300K_[A-Z0-9_]+(?:\s+[A-Za-z0-9_./:+=-]+)*$' })
    }
    else { @() }
    [System.IO.File]::WriteAllText($EvidencePath, (($allowed -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Invoke-QemuBackend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('init-signing-key', 'build')] [string] $Operation,
        [Parameter(Mandatory)] [string] $QemuRoot,
        [Parameter(Mandatory)] [string] $StateRoot,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $RequestFile,
        [Parameter(Mandatory)] [string] $SourceArchive,
        [Parameter(Mandatory)] [string] $ExportDirectory,
        [Parameter(Mandatory)] [uri] $CloudImageUri,
        [Parameter(Mandatory)] [string] $CloudImageSha512,
        [Parameter(Mandatory)] [string] $CacheIdentity,
        [string] $SigningPrivateFile,
        [string] $SigningPublicFile,
        [ValidateRange(60, 1800)] [int] $BootTimeoutSeconds = 600,
        [ValidateRange(60, 14400)] [int] $BuildTimeoutSeconds = 7200
    )

    $owner = New-QemuResourceOwner
    $qemuLease = $null
    $serialTrust = $null
    $managementStages = [System.Collections.Generic.List[string]]::new()
    $cleanupError = $null
    $operationError = $null
    $serialPath = $null
    $identityPath = $null
    $knownHostsPath = $null
    $overlayPath = $null
    $seedServer = $null
    $serialServer = $null
    $sshReservation = $null
    $resultObject = $null
    $runRoot = [System.IO.Path]::GetFullPath((Join-Path $StateRoot "state\runs\$RunId"))
    $evidenceDirectory = [System.IO.Path]::GetFullPath($ExportDirectory)
    $serialEvidencePath = Join-Path $evidenceDirectory 'serial-evidence.log'
    [System.IO.Directory]::CreateDirectory($evidenceDirectory) | Out-Null

    try {
        $qemuExe = [System.IO.Path]::GetFullPath((Join-Path $QemuRoot 'qemu-system-x86_64.exe'))
        $qemuImgExe = [System.IO.Path]::GetFullPath((Join-Path $QemuRoot 'qemu-img.exe'))
        foreach ($tool in @($qemuExe, $qemuImgExe)) {
            if (-not [System.IO.File]::Exists($tool)) { throw (New-QemuException -Code 'QEMU_TOOL_MISSING' -Message "Required QEMU tool is missing: $tool") }
        }
        $sshPath = (Get-Command ssh.exe -CommandType Application -ErrorAction Stop).Source
        $scpPath = (Get-Command scp.exe -CommandType Application -ErrorAction Stop).Source
        $sshKeygenPath = (Get-Command ssh-keygen.exe -CommandType Application -ErrorAction Stop).Source

        [System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
        Add-QemuOwnedResource -Owner $owner -Name 'management-scratch' -Cleanup { param($path) if ([System.IO.Directory]::Exists($path)) { [System.IO.Directory]::Delete($path, $true) } } -CleanupArgument $runRoot

        $baseDirectory = Join-Path $StateRoot 'state\qemu\base'
        $cacheDirectory = Join-Path $StateRoot 'state\qemu\cache'
        [System.IO.Directory]::CreateDirectory($baseDirectory) | Out-Null
        [System.IO.Directory]::CreateDirectory($cacheDirectory) | Out-Null
        $basePath = Join-Path $baseDirectory ([System.IO.Path]::GetFileName($CloudImageUri.AbsolutePath))
        $basePath = Get-VerifiedQemuBaseImage -Uri $CloudImageUri -ExpectedSha512 $CloudImageSha512 -Destination $basePath

        $overlayPath = Join-Path $runRoot 'overlay.qcow2'
        [void](Invoke-CheckedProcess -FilePath $qemuImgExe -ArgumentList @('create', '-f', 'qcow2', '-F', 'qcow2', '-b', $basePath, $overlayPath) -TimeoutSeconds 60)
        Add-QemuOwnedResource -Owner $owner -Name 'overlay' -Cleanup { param($path) if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) } } -CleanupArgument $overlayPath

        if ($CacheIdentity -cnotmatch '^[0-9a-f]{12,64}$') { throw (New-QemuException -Code 'QEMU_CACHE_ID_INVALID' -Message 'Cache identity must be lowercase content hex.') }
        $cachePath = Join-Path $cacheDirectory "300k-cache-$($CacheIdentity.Substring(0,12)).qcow2"
        if (-not [System.IO.File]::Exists($cachePath)) {
            [void](Invoke-CheckedProcess -FilePath $qemuImgExe -ArgumentList @('create', '-f', 'qcow2', $cachePath, '24G') -TimeoutSeconds 60)
        }

        $sshReservation = New-LoopbackPortReservation
        Add-QemuOwnedResource -Owner $owner -Name 'ports' -Cleanup { param($reservation) Close-LoopbackPortReservation -Reservation $reservation } -CleanupArgument $sshReservation

        $identityPath = Join-Path $runRoot 'management_ed25519'
        [void](Invoke-CheckedProcess -FilePath $sshKeygenPath -ArgumentList @('-q', '-t', 'ed25519', '-N', '', '-C', '300k-ephemeral-management', '-f', $identityPath) -TimeoutSeconds 30)
        Add-QemuOwnedResource -Owner $owner -Name 'ssh-key' -Cleanup {
            param($prefix)
            foreach ($candidate in @($prefix, "$prefix.pub")) { if ([System.IO.File]::Exists($candidate)) { [System.IO.File]::Delete($candidate) } }
        } -CleanupArgument $identityPath
        $managementPublicKey = [System.IO.File]::ReadAllText("$identityPath.pub").Trim()
        if ($managementPublicKey -notmatch '^ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}\s+') { throw (New-QemuException -Code 'QEMU_MANAGEMENT_KEY_INVALID' -Message 'Ephemeral management public key is malformed.') }

        $knownHostsPath = Join-Path $runRoot 'known_hosts'
        [System.IO.File]::WriteAllText($knownHostsPath, '', [System.Text.UTF8Encoding]::new($false))
        Add-QemuOwnedResource -Owner $owner -Name 'known-hosts' -Cleanup { param($path) if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) } } -CleanupArgument $knownHostsPath

        $seedDirectory = Join-Path $runRoot 'seed'
        [System.IO.Directory]::CreateDirectory($seedDirectory) | Out-Null
        $metaTemplate = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\builder\cloud-init\meta-data.template'))
        $userTemplate = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\builder\cloud-init\user-data.template'))
        $instanceId = '300k-' + $RunId
        $metaDataPath = Join-Path $seedDirectory 'meta-data'
        $userDataPath = Join-Path $seedDirectory 'user-data'
        [System.IO.File]::WriteAllText($metaDataPath, $metaTemplate.Replace('@@INSTANCE_ID@@', $instanceId), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($userDataPath, $userTemplate.Replace('@@SSH_PUBLIC_KEY@@', $managementPublicKey), [System.Text.UTF8Encoding]::new($false))
        $seedServer = Start-NoCloudSeedServer -MetaDataPath $metaDataPath -UserDataPath $userDataPath
        Add-QemuOwnedResource -Owner $owner -Name 'seed-listener' -Cleanup { param($server) $server.Dispose() } -CleanupArgument $seedServer

        $serialPath = Join-Path $runRoot 'serial.log'
        $serialServer = Start-SerialCaptureServer -DestinationPath $serialPath
        Add-QemuOwnedResource -Owner $owner -Name 'serial-listener' -Cleanup { param($server) $server.Dispose() } -CleanupArgument $serialServer
        Close-LoopbackPortReservation -Reservation $sshReservation
        $qemuArguments = @(
            '-machine', 'q35',
            '-accel', 'whpx',
            '-accel', 'tcg,thread=multi',
            '-m', '4096',
            '-smp', '4',
            '-drive', "if=none,id=os,format=qcow2,file=$overlayPath",
            '-device', 'virtio-blk-pci,drive=os,bootindex=1,serial=300k-builder',
            '-drive', "if=none,id=cache,format=qcow2,file=$cachePath",
            '-device', 'virtio-blk-pci,drive=cache,serial=300k-cache',
            '-nic', "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$($sshReservation.Port)-:22",
            '-smbios', "type=1,serial=ds=nocloud;s=http://10.0.2.2:$($seedServer.Port)/",
            '-display', 'none',
            '-serial', "tcp:127.0.0.1:$($serialServer.Port)",
            '-monitor', 'none',
            '-no-reboot'
        )
        $qemuLease = Start-CheckedProcessLease -FilePath $qemuExe -ArgumentList $qemuArguments -TimeoutSeconds ($BuildTimeoutSeconds + $BootTimeoutSeconds + 300)
        Add-QemuOwnedResource -Owner $owner -Name 'qemu-lease' -Cleanup { param($lease) Close-CheckedProcessLease -Lease $lease -TimeoutSeconds 20 } -CleanupArgument $qemuLease

        $verifyFingerprint = {
            param($keyType, $key, $fingerprint)
            Test-QemuSshFingerprint -KeyType $keyType -PublicKey $key -Fingerprint $fingerprint -ScratchDirectory $runRoot -SshKeygenPath $sshKeygenPath
        }.GetNewClosure()
        $serialTrust = Wait-QemuSerialHostKey -Lease $qemuLease -SerialPath $serialPath -VerifyFingerprint $verifyFingerprint -TimeoutSeconds $BootTimeoutSeconds
        [System.IO.File]::WriteAllText(
            $knownHostsPath,
            "[127.0.0.1]:$($sshReservation.Port) $($serialTrust.KeyType) $($serialTrust.PublicKey)`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        $sshDeadline = [System.DateTimeOffset]::UtcNow.AddSeconds($BootTimeoutSeconds)
        $sshReady = $false
        $sshAttempt = 0
        $lastSshDiagnostic = 'no SSH diagnostic was returned'
        while (-not $sshReady -and $sshAttempt -lt 3 -and [System.DateTimeOffset]::UtcNow -lt $sshDeadline) {
            $sshAttempt++
            $remainingSeconds = [Math]::Max(30, [int][Math]::Floor(($sshDeadline - [System.DateTimeOffset]::UtcNow).TotalSeconds))
            $attemptTimeout = [Math]::Min(180, $remainingSeconds)
            try {
                $probe = Invoke-QemuSshCommand -Lease $qemuLease -SshPath $sshPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Command @('printf', '300K_SSH_PROBE') -TimeoutSeconds $attemptTimeout -AllowNonZero -Stage 'ssh-readiness'
                $sshReady = $probe.StandardOutput -match '300K_SSH_PROBE'
                if (-not $sshReady) {
                    $lastSshDiagnostic = if (-not [string]::IsNullOrWhiteSpace($probe.StandardError)) { $probe.StandardError.Trim() } else { "ssh exited $($probe.ExitCode) without the readiness token" }
                }
            }
            catch { $lastSshDiagnostic = $_.Exception.Message }
            if (-not $sshReady -and $sshAttempt -lt 3 -and [System.DateTimeOffset]::UtcNow.AddSeconds(30) -lt $sshDeadline) { Start-Sleep -Seconds 30 }
        }
        if (-not $sshReady) {
            $lastSshDiagnostic = $lastSshDiagnostic.Replace($identityPath, '<run-local-identity>').Replace($knownHostsPath, '<run-local-known-hosts>')
            $lastSshDiagnostic = [regex]::Replace($lastSshDiagnostic, '[\r\n]+', ' ')
            if ($lastSshDiagnostic.Length -gt 512) { $lastSshDiagnostic = $lastSshDiagnostic.Substring(0, 512) }
            throw (New-QemuException -Code 'QEMU_SSH_TIMEOUT' -Message "Strict SSH did not become ready within the boot bound. Last diagnostic: $lastSshDiagnostic")
        }
        $managementStages.Add('ssh-readiness-live')

        [void](Invoke-QemuSshCommand -Lease $qemuLease -SshPath $sshPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Command @('doas', 'mkdir', '-p', '/inputs', '/workspace', '/export', '/run/300k-secrets') -TimeoutSeconds 30 -Stage 'prepare-guest')
        $managementStages.Add('prepare-guest-live')
        [void](Invoke-QemuScp -Lease $qemuLease -ScpPath $scpPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Paths @($SourceArchive, 'builder@127.0.0.1:/inputs/source.tar') -TimeoutSeconds 300 -Stage 'source-transfer')
        [void](Invoke-QemuScp -Lease $qemuLease -ScpPath $scpPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Paths @($RequestFile, 'builder@127.0.0.1:/inputs/request.json') -TimeoutSeconds 120 -Stage 'request-transfer')
        $managementStages.Add('input-transfer-live')
        [void](Invoke-QemuSshCommand -Lease $qemuLease -SshPath $sshPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Command @('doas', 'sh', '-ceu', 'rm -rf /workspace/*; tar -xf /inputs/source.tar -C /workspace; chmod +x /workspace/scripts/linux/run-build.sh') -TimeoutSeconds 120 -Stage 'source-extract')

        if ($Operation -ceq 'build') {
            foreach ($keyFile in @($SigningPrivateFile, $SigningPublicFile)) {
                if ([string]::IsNullOrWhiteSpace($keyFile) -or -not [System.IO.File]::Exists($keyFile)) {
                    throw (New-QemuException -Code 'QEMU_SIGNING_INPUT_MISSING' -Message 'The ordinary build requires the external APK key pair.')
                }
            }
            [void](Invoke-QemuScp -Lease $qemuLease -ScpPath $scpPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Paths @($SigningPrivateFile, 'builder@127.0.0.1:/inputs/300k.rsa') -TimeoutSeconds 120 -Stage 'private-key-transfer')
            [void](Invoke-QemuScp -Lease $qemuLease -ScpPath $scpPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Paths @($SigningPublicFile, 'builder@127.0.0.1:/inputs/300k.rsa.pub') -TimeoutSeconds 120 -Stage 'public-key-transfer')
            [void](Invoke-QemuSshCommand -Lease $qemuLease -SshPath $sshPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Command @('doas', 'sh', '-ceu', 'install -m 600 /inputs/300k.rsa /run/300k-secrets/300k.rsa; install -m 644 /inputs/300k.rsa.pub /run/300k-secrets/300k.rsa.pub; rm -f /inputs/300k.rsa') -TimeoutSeconds 30 -Stage 'private-key-stage')
            $managementStages.Add('private-key-tmpfs-live')
        }

        $mode = if ($Operation -ceq 'init-signing-key') { 'init-signing-key' } else { 'prepare-repository-and-build' }
        [void](Invoke-QemuSshCommand -Lease $qemuLease -SshPath $sshPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Command @('doas', '/bin/sh', '/workspace/scripts/linux/run-build.sh', $mode, '/inputs/request.json') -TimeoutSeconds $BuildTimeoutSeconds -Stage $mode)
        $managementStages.Add("$mode-live")

        [void](Invoke-QemuScp -Lease $qemuLease -ScpPath $scpPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Paths @('-r', 'builder@127.0.0.1:/export/.', $evidenceDirectory) -TimeoutSeconds 1200 -Stage 'artifact-export')
        $managementStages.Add('artifact-export-live')

        [void](Invoke-QemuSshCommand -Lease $qemuLease -SshPath $sshPath -IdentityFile $identityPath -KnownHostsFile $knownHostsPath -Port $sshReservation.Port -Command @('doas', 'poweroff') -TimeoutSeconds 30 -AllowNonZero -Stage 'shutdown')
        [void](Wait-CheckedProcessLease -Lease $qemuLease -TimeoutSeconds 90 -AllowNonZero)
        $managementStages.Add('shutdown-complete')

        Write-SanitizedSerialEvidence -SerialPath $serialPath -EvidencePath $serialEvidencePath
        $resultObject = [pscustomobject]@{
            SchemaVersion       = 1
            Backend             = 'qemu'
            GuestOs            = 'linux'
            GuestArch          = 'x86_64'
            AlpineRelease      = '3.24.1'
            CloudImageSha512   = $CloudImageSha512
            SerialFingerprint  = $serialTrust.Fingerprint
            QemuLeaseProcessId = $qemuLease.Process.Id
            ManagementStages   = $managementStages.ToArray()
            ExportDirectory    = $evidenceDirectory
            SerialEvidenceFile = [System.IO.Path]::GetFileName($serialEvidencePath)
            CleanupComplete    = $false
        }
        return $resultObject
    }
    catch {
        $operationError = $_.Exception
        throw
    }
    finally {
        try {
            if ($null -ne $qemuLease -and -not $qemuLease.Closed -and -not $qemuLease.Process.HasExited) {
                Stop-CheckedProcessLease -Lease $qemuLease -TimeoutSeconds 20
            }
        }
        catch { $cleanupError = $_.Exception }
        try {
            if ($null -ne $serialPath -and [System.IO.File]::Exists($serialPath)) {
                Write-SanitizedSerialEvidence -SerialPath $serialPath -EvidencePath $serialEvidencePath
            }
        }
        catch { if ($null -eq $cleanupError) { $cleanupError = $_.Exception } }
        try {
            Close-QemuResourceOwner -Owner $owner
        }
        catch { if ($null -eq $cleanupError) { $cleanupError = $_.Exception } }

        $inventory = [ordered]@{
            schema_version = 1
            cleanup_complete = ($null -eq $cleanupError -and -not [System.IO.Directory]::Exists($runRoot))
            resources = [ordered]@{
                qemu_lease_live = ($null -ne $qemuLease -and -not $qemuLease.Closed)
                seed_listener_live = ($null -ne $cleanupError -and $null -ne $seedServer)
                serial_listener_live = ($null -ne $cleanupError -and $null -ne $serialServer)
                port_reservation_live = ($null -ne $sshReservation -and -not $sshReservation.Released)
                ssh_identity_present = ($null -ne $identityPath -and [System.IO.File]::Exists($identityPath))
                known_hosts_present = ($null -ne $knownHostsPath -and [System.IO.File]::Exists($knownHostsPath))
                overlay_present = ($null -ne $overlayPath -and [System.IO.File]::Exists($overlayPath))
                management_scratch_present = [System.IO.Directory]::Exists($runRoot)
            }
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $evidenceDirectory 'resource-inventory.json'),
            (($inventory | ConvertTo-Json -Depth 8 -Compress) + "`n"),
            [System.Text.UTF8Encoding]::new($false)
        )
        if ($null -ne $resultObject) { $resultObject.CleanupComplete = $inventory.cleanup_complete }
        if ($null -ne $cleanupError -and $null -eq $operationError) { throw $cleanupError }
    }
}
