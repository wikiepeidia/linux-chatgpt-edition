[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Docker', 'Qemu')]
    [string] $Backend = 'Auto',

    [ValidateSet('Bootstrap')]
    [string] $Target = 'Bootstrap',

    [string] $StateRoot = (Join-Path $env:LOCALAPPDATA '300k-linux'),
    [string] $QemuRoot = 'D:\VM\qemu',
    [Nullable[long]] $SourceDateEpoch,
    [switch] $InitializeSigningKey,
    [switch] $PreflightOnly,
    [switch] $Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BuildRepositoryRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
. (Join-Path $PSScriptRoot 'scripts/host/Invoke-CheckedProcess.ps1')
. (Join-Path $PSScriptRoot 'scripts/host/Invoke-QemuBackend.ps1')

function New-BuildException {
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

function Get-ObjectProperty {
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-LowerFileSha256 {
    param([Parameter(Mandatory)] [string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-CanonicalJsonText {
    param([Parameter(Mandatory)] $Value)
    $text = $Value | ConvertTo-Json -Depth 64
    $text = $text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    return $text
}

function Write-CanonicalJson {
    param([Parameter(Mandatory)] $Value, [Parameter(Mandatory)] [string] $Path)
    $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    [System.IO.File]::WriteAllText($Path, (ConvertTo-CanonicalJsonText -Value $Value), [System.Text.UTF8Encoding]::new($false))
}

function Get-CanonicalGuestRoles {
    return [ordered]@{
        source    = '/workspace'
        request   = '/inputs/build-request.json'
        work      = '/work'
        apk_cache = '/var/cache/apk'
        secrets   = '/run/300k-secrets'
        export    = '/export'
        entry     = '/workspace/scripts/linux/run-build.sh'
    }
}

function Assert-PublicInputs {
    param([Parameter(Mandatory)] $Inputs)
    if ([int]$Inputs.schema_version -ne 1 -or $Inputs.alpine.release -cne '3.24.1' -or $Inputs.target.arch -cne 'x86_64') {
        throw (New-BuildException -Code 'INPUT_SCHEMA_INVALID' -Message 'Public builder inputs have an unsupported schema, release, or architecture.')
    }
    if ($Inputs.aports.commit -cnotmatch '^[0-9a-f]{40}$') {
        throw (New-BuildException -Code 'INPUT_APORTS_PIN_INVALID' -Message 'The aports commit must be exact lowercase hex.')
    }
    if ($Inputs.docker.image_index_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or $Inputs.docker.linux_amd64_manifest_digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw (New-BuildException -Code 'INPUT_DOCKER_PIN_INVALID' -Message 'Docker pins must be sha256 digests.')
    }
    if ($Inputs.qemu.cloud_image_sha512 -cnotmatch '^[0-9a-f]{128}$') {
        throw (New-BuildException -Code 'INPUT_QEMU_PIN_INVALID' -Message 'The QEMU cloud-image SHA-512 is malformed.')
    }
    $repositoryKeys = @($Inputs.alpine.repository_keys.PSObject.Properties)
    if ($repositoryKeys.Count -ne 3) {
        throw (New-BuildException -Code 'INPUT_REPOSITORY_KEYS_INVALID' -Message 'Exactly three Alpine x86_64 repository keys must be pinned.')
    }
    foreach ($key in $repositoryKeys) {
        if ($key.Name -cnotmatch '^alpine-devel@lists\.alpinelinux\.org-[0-9a-f]{8}\.rsa\.pub$' -or [string]$key.Value -cnotmatch '^[0-9a-f]{64}$') {
            throw (New-BuildException -Code 'INPUT_REPOSITORY_KEYS_INVALID' -Message 'An Alpine repository-key basename or SHA-256 is malformed.')
        }
    }

    $approvedOrigins = @('https://dl-cdn.alpinelinux.org/', 'https://gitlab.alpinelinux.org/')
    foreach ($repository in @($Inputs.alpine.repositories)) {
        $uri = [uri]$repository.url
        if ($uri.Scheme -cne 'https' -or -not ($approvedOrigins | Where-Object { $uri.AbsoluteUri.StartsWith($_, [System.StringComparison]::Ordinal) })) {
            throw (New-BuildException -Code 'INPUT_REPOSITORY_INVALID' -Message 'An Alpine repository origin is not approved.')
        }
        if ($repository.apkindex_sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw (New-BuildException -Code 'INPUT_REPOSITORY_HASH_INVALID' -Message 'An Alpine repository index hash is malformed.')
        }
    }
    if (-not ([uri]$Inputs.aports.remote).AbsoluteUri.StartsWith('https://gitlab.alpinelinux.org/', [System.StringComparison]::Ordinal)) {
        throw (New-BuildException -Code 'INPUT_APORTS_ORIGIN_INVALID' -Message 'The aports origin is not approved.')
    }
    if (-not ([uri]$Inputs.qemu.cloud_image_url).AbsoluteUri.StartsWith('https://dl-cdn.alpinelinux.org/', [System.StringComparison]::Ordinal)) {
        throw (New-BuildException -Code 'INPUT_QEMU_ORIGIN_INVALID' -Message 'The cloud-image origin is not approved.')
    }
}

function New-KeyInitRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inputs,
        [Parameter(Mandatory)] [string] $RunNonce
    )
    Assert-PublicInputs -Inputs $Inputs
    if ($RunNonce -cnotmatch '^[0-9a-f]{32}$') {
        throw (New-BuildException -Code 'KEY_INIT_NONCE_INVALID' -Message 'Key initialization nonce must be 32 lowercase hexadecimal characters.')
    }
    return [ordered]@{
        schema = 'KeyInitRequest'
        schema_version = 1
        operation = 'init-signing-key'
        run_nonce = $RunNonce
        target_identity = '300k-apk-signing'
        alpine_release = $Inputs.alpine.release
        architecture = $Inputs.target.arch
        cloud_image = [ordered]@{
            file = $Inputs.qemu.cloud_image_name
            sha512 = $Inputs.qemu.cloud_image_sha512
        }
        aports_commit = $Inputs.aports.commit
        build_script = 'scripts/linux/run-build.sh'
    }
}

function Test-SigningPublicIdentity {
    param(
        [Parameter(Mandatory)] $SigningPublic,
        [string] $BaseDirectory
    )
    if ($SigningPublic.schema -cne 'SigningPublic' -or $SigningPublic.public_key_file -cnotmatch '^[A-Za-z0-9._-]+\.rsa\.pub$|^300k\.rsa\.pub$' -or $SigningPublic.public_key_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw (New-BuildException -Code 'SIGNING_PUBLIC_INVALID' -Message 'The signing public identity is malformed.')
    }
    if (-not [string]::IsNullOrWhiteSpace($BaseDirectory)) {
        $path = Join-Path $BaseDirectory $SigningPublic.public_key_file
        if (-not [System.IO.File]::Exists($path) -or (Get-LowerFileSha256 -Path $path) -cne $SigningPublic.public_key_sha256) {
            throw (New-BuildException -Code 'SIGNING_PUBLIC_HASH_MISMATCH' -Message 'The public signing identity bytes do not match signing-public.json.')
        }
    }
    return $true
}

function New-BuildRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inputs,
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] $InputHashes,
        $SigningPublic
    )
    Assert-PublicInputs -Inputs $Inputs
    if ($null -eq $SigningPublic) {
        throw (New-BuildException -Code 'SIGNING_PUBLIC_REQUIRED' -Message 'Create and validate signing-public.json before constructing BuildRequest.')
    }
    [void](Test-SigningPublicIdentity -SigningPublic $SigningPublic)
    if ($Source.git_commit -cnotmatch '^[0-9a-f]{40}$' -or $Source.archive_sha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$Source.source_date_epoch -le 0 -or [bool]$Source.dirty) {
        throw (New-BuildException -Code 'BUILD_SOURCE_INVALID' -Message 'BuildRequest source identity must be clean, exact, and positive-epoch.')
    }
    foreach ($name in @('inputs_sha256', 'run_build_sha256', 'profile_sha256')) {
        if ([string](Get-ObjectProperty -Object $InputHashes -Name $name) -cnotmatch '^[0-9a-f]{64}$') {
            throw (New-BuildException -Code 'BUILD_INPUT_HASH_INVALID' -Message "Build input hash '$name' is malformed.")
        }
    }

    return [ordered]@{
        schema = 'BuildRequest'
        schema_version = 1
        target = [ordered]@{
            name = 'Bootstrap'
            os = 'linux'
            arch = 'x86_64'
            format = 'iso'
            profile = '300k_bootstrap'
        }
        source = [ordered]@{
            git_commit = $Source.git_commit
            archive_sha256 = $Source.archive_sha256
            source_date_epoch = [long]$Source.source_date_epoch
            dirty = $false
        }
        public_inputs = [ordered]@{
            inputs_sha256 = [string](Get-ObjectProperty -Object $InputHashes -Name 'inputs_sha256')
            run_build_sha256 = [string](Get-ObjectProperty -Object $InputHashes -Name 'run_build_sha256')
            profile_sha256 = [string](Get-ObjectProperty -Object $InputHashes -Name 'profile_sha256')
        }
        builder = [ordered]@{
            alpine_release = $Inputs.alpine.release
            image_index_digest = $Inputs.docker.image_index_digest
            linux_amd64_manifest_digest = $Inputs.docker.linux_amd64_manifest_digest
        }
        aports = [ordered]@{
            remote = $Inputs.aports.remote
            commit = $Inputs.aports.commit
        }
        repositories = @($Inputs.alpine.repositories | ForEach-Object {
            [ordered]@{ name = $_.name; url = $_.url; apkindex_sha256 = $_.apkindex_sha256 }
        })
        requested_packages = @($Inputs.builder_packages)
        requested_image_packages = @($Inputs.requested_image_packages)
        signing = [ordered]@{
            public_key_file = $SigningPublic.public_key_file
            public_key_sha256 = $SigningPublic.public_key_sha256
        }
        canonical_guest_roles = Get-CanonicalGuestRoles
    }
}

function Test-ResolvedBuildLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Lock,
        [Parameter(Mandatory)] [string] $ExpectedBuildRequestSha256,
        [switch] $AllowEmptyArtifacts
    )
    if ($ExpectedBuildRequestSha256 -cnotmatch '^[0-9a-f]{64}$' -or $Lock.schema -cne 'ResolvedBuildLock') {
        throw (New-BuildException -Code 'RESOLVED_LOCK_INVALID' -Message 'ResolvedBuildLock schema or expected request hash is invalid.')
    }
    if ($Lock.build_request_sha256 -cne $ExpectedBuildRequestSha256) {
        throw (New-BuildException -Code 'RESOLVED_LOCK_REQUEST_MISMATCH' -Message 'ResolvedBuildLock belongs to a different BuildRequest.')
    }
    if ($Lock.repository_object_id -cnotmatch '^[0-9a-f]{64}$') {
        throw (New-BuildException -Code 'RESOLVED_LOCK_REPOSITORY_INVALID' -Message 'ResolvedBuildLock repository object identity is malformed.')
    }
    if (-not $AllowEmptyArtifacts -and @($Lock.artifacts).Count -eq 0) {
        throw (New-BuildException -Code 'RESOLVED_LOCK_ARTIFACTS_MISSING' -Message 'ResolvedBuildLock contains no output artifacts.')
    }
    return $true
}

function Test-ResolvedTrustedKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $TrustedKeys,
        [Parameter(Mandatory)] $RepositoryKeys,
        [Parameter(Mandatory)] [string] $SigningPublicSha256
    )
    if ($SigningPublicSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw (New-BuildException -Code 'RESOLVED_LOCK_TRUSTED_KEYS_INVALID' -Message 'The expected project signing-key hash is malformed.')
    }

    $expected = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    foreach ($property in @($RepositoryKeys.PSObject.Properties)) {
        if ($property.Name -cnotmatch '^alpine-devel@lists\.alpinelinux\.org-[0-9a-f]{8}\.rsa\.pub$' -or [string]$property.Value -cnotmatch '^[0-9a-f]{64}$') {
            throw (New-BuildException -Code 'RESOLVED_LOCK_TRUSTED_KEYS_INVALID' -Message 'The expected Alpine repository-key contract is malformed.')
        }
        $expected.Add($property.Name, "$([string]$property.Value)|alpine-x86_64")
    }
    $expected.Add('300k.rsa.pub', "$SigningPublicSha256|project-signing")

    $actual = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    foreach ($record in @($TrustedKeys)) {
        $file = [string](Get-ObjectProperty -Object $record -Name 'file')
        $sha256 = [string](Get-ObjectProperty -Object $record -Name 'sha256')
        $trust = [string](Get-ObjectProperty -Object $record -Name 'trust')
        if ($file -cnotmatch '^[A-Za-z0-9@._-]+\.rsa\.pub$' -or $sha256 -cnotmatch '^[0-9a-f]{64}$' -or $trust -notin @('alpine-x86_64', 'project-signing') -or $actual.ContainsKey($file)) {
            throw (New-BuildException -Code 'RESOLVED_LOCK_TRUSTED_KEYS_INVALID' -Message 'ResolvedBuildLock contains a malformed or duplicated trusted-key record.')
        }
        $actual.Add($file, "$sha256|$trust")
    }
    if ($actual.Count -ne $expected.Count) {
        throw (New-BuildException -Code 'RESOLVED_LOCK_TRUSTED_KEYS_INVALID' -Message 'ResolvedBuildLock trusted-key set is not closed.')
    }
    foreach ($entry in $expected.GetEnumerator()) {
        if (-not $actual.ContainsKey($entry.Key) -or $actual[$entry.Key] -cne $entry.Value) {
            throw (New-BuildException -Code 'RESOLVED_LOCK_TRUSTED_KEYS_INVALID' -Message 'ResolvedBuildLock trusted-key bytes differ from the pinned allowlist.')
        }
    }
    return $true
}

function Test-GeneratedFileRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)] [string] $BaseDirectory,
        [Parameter(Mandatory)] [string] $ExpectedProducer
    )
    $file = [string]$Record.file
    if ($file -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $Record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$Record.bytes -le 0 -or $Record.producer -cne $ExpectedProducer -or $Record.validator -cne 'build.ps1:Test-GeneratedFileRecord') {
        throw (New-BuildException -Code 'GENERATED_RECORD_INVALID' -Message 'Generated file record is not closed, relative, positive, lowercase, and singly owned.')
    }
    $path = Join-Path $BaseDirectory $file
    if (-not [System.IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -ne [long]$Record.bytes -or (Get-LowerFileSha256 -Path $path) -cne $Record.sha256) {
        throw (New-BuildException -Code 'GENERATED_RECORD_INVALID' -Message 'Generated file record does not match independent host validation.')
    }
    return $true
}

function Test-RepositorySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepositoryDirectory,
        [Parameter(Mandatory)] [string] $ManifestFile
    )
    $root = [System.IO.Path]::GetFullPath($RepositoryDirectory)
    $manifest = [System.IO.Path]::GetFullPath($ManifestFile)
    if (-not [System.IO.File]::Exists($manifest)) {
        throw (New-BuildException -Code 'REPOSITORY_DRIFT' -Message 'Repository byte manifest is absent.')
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in [System.IO.File]::ReadAllLines($manifest)) {
        $match = [regex]::Match($line, '^(?<hash>[0-9a-f]{64})  (?<file>[A-Za-z0-9][A-Za-z0-9._-]*)$')
        if (-not $match.Success -or -not $seen.Add($match.Groups['file'].Value)) {
            throw (New-BuildException -Code 'REPOSITORY_DRIFT' -Message 'Repository byte manifest is malformed or duplicated.')
        }
        $path = Join-Path $root $match.Groups['file'].Value
        if (-not [System.IO.File]::Exists($path) -or (Get-LowerFileSha256 -Path $path) -cne $match.Groups['hash'].Value) {
            throw (New-BuildException -Code 'REPOSITORY_DRIFT' -Message 'A verified repository byte changed before use.')
        }
    }
    if ($seen.Count -eq 0) { throw (New-BuildException -Code 'REPOSITORY_DRIFT' -Message 'Repository byte manifest is empty.') }
    return $true
}

function Test-BuildSemanticParity {
    param([Parameter(Mandatory)] $Left, [Parameter(Mandatory)] $Right)
    $leftJson = ConvertTo-CanonicalJsonText -Value $Left.content
    $rightJson = ConvertTo-CanonicalJsonText -Value $Right.content
    return $leftJson -ceq $rightJson
}

function Resolve-ExternalStateRoot {
    param([Parameter(Mandatory)] [string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOfAny([char[]]@([char]0, "`r", "`n")) -ge 0) {
        throw (New-BuildException -Code 'STATE_PATH_INVALID' -Message 'State root is empty or contains a control character.')
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    $repo = $script:BuildRepositoryRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ($full.Equals($repo, [System.StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($repo + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-BuildException -Code 'STATE_PATH_INSIDE_REPOSITORY' -Message 'State and secrets must remain outside the repository.')
    }
    $current = $full
    while (-not [System.IO.Directory]::Exists($current)) {
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
    if ([System.IO.Directory]::Exists($current)) {
        $attributes = [System.IO.File]::GetAttributes($current)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw (New-BuildException -Code 'STATE_PATH_REPARSE_POINT' -Message 'State root may not traverse a reparse point.')
        }
    }
    return $full
}

function Assert-CleanRepository {
    $git = (Get-Command git.exe -CommandType Application -ErrorAction Stop).Source
    $status = Invoke-CheckedProcess -FilePath $git -ArgumentList @('status', '--porcelain', '--untracked-files=all') -WorkingDirectory $script:BuildRepositoryRoot -TimeoutSeconds 30
    if (-not [string]::IsNullOrWhiteSpace($status.StandardOutput)) {
        throw (New-BuildException -Code 'SOURCE_TREE_DIRTY' -Message 'Actual builds require an empty tracked and untracked Git status.')
    }
}

function Get-GitSourceIdentity {
    param([Nullable[long]] $RequestedEpoch)
    $git = (Get-Command git.exe -CommandType Application -ErrorAction Stop).Source
    $commit = (Invoke-CheckedProcess -FilePath $git -ArgumentList @('rev-parse', 'HEAD') -WorkingDirectory $script:BuildRepositoryRoot -TimeoutSeconds 30).StandardOutput.Trim()
    $epochText = if ($null -ne $RequestedEpoch) { [string]$RequestedEpoch.Value } else {
        (Invoke-CheckedProcess -FilePath $git -ArgumentList @('show', '-s', '--format=%ct', 'HEAD') -WorkingDirectory $script:BuildRepositoryRoot -TimeoutSeconds 30).StandardOutput.Trim()
    }
    if ($commit -cnotmatch '^[0-9a-f]{40}$' -or $epochText -cnotmatch '^[1-9][0-9]*$') {
        throw (New-BuildException -Code 'SOURCE_IDENTITY_INVALID' -Message 'Git commit or SOURCE_DATE_EPOCH is invalid.')
    }
    return [pscustomobject]@{ git_commit = $commit; source_date_epoch = [long]$epochText }
}

function Assert-SourceArchiveUnixText {
    param([Parameter(Mandatory)] [string] $Path)

    $requiredEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entryName in @('scripts/linux/run-build.sh', 'builder/profiles/mkimg.300k.sh')) {
        [void]$requiredEntries.Add($entryName)
    }

    $archiveStream = [System.IO.File]::OpenRead($Path)
    $reader = [System.Formats.Tar.TarReader]::new($archiveStream, $false)
    try {
        while ($null -ne ($entry = $reader.GetNextEntry())) {
            if (-not $requiredEntries.Contains($entry.Name)) { continue }
            if ($null -eq $entry.DataStream) {
                throw (New-BuildException -Code 'SOURCE_ARCHIVE_ENTRY_INVALID' -Message "Source archive entry '$($entry.Name)' has no file data.")
            }

            $content = [System.IO.MemoryStream]::new()
            try {
                $entry.DataStream.CopyTo($content)
                if ([System.Array]::IndexOf[byte]($content.ToArray(), [byte]13) -ge 0) {
                    throw (New-BuildException -Code 'SOURCE_ARCHIVE_LINE_ENDINGS_INVALID' -Message "Source archive entry '$($entry.Name)' contains a carriage return; guest shell scripts must use LF line endings.")
                }
            }
            finally { $content.Dispose() }
            [void]$requiredEntries.Remove($entry.Name)
        }
    }
    finally {
        $reader.Dispose()
        $archiveStream.Dispose()
    }

    if ($requiredEntries.Count -ne 0) {
        throw (New-BuildException -Code 'SOURCE_ARCHIVE_ENTRY_MISSING' -Message "Source archive is missing required guest shell entries: $(@($requiredEntries) -join ', ').")
    }
}

function New-DeterministicSourceArchive {
    param([Parameter(Mandatory)] [string] $Destination)
    $git = (Get-Command git.exe -CommandType Application -ErrorAction Stop).Source
    [void](Invoke-CheckedProcess -FilePath $git -ArgumentList @('archive', '--format=tar', '--output', $Destination, 'HEAD') -WorkingDirectory $script:BuildRepositoryRoot -TimeoutSeconds 120)
    if (-not [System.IO.File]::Exists($Destination) -or (Get-Item -LiteralPath $Destination).Length -le 0) {
        throw (New-BuildException -Code 'SOURCE_ARCHIVE_FAILED' -Message 'Git did not create a nonempty deterministic source archive.')
    }
    Assert-SourceArchiveUnixText -Path $Destination
    return Get-LowerFileSha256 -Path $Destination
}

function Get-DockerProbe {
    $docker = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $docker) { return [pscustomobject]@{ available = $false; status = 'unverified-unavailable'; reason = 'client-missing' } }
    try {
        $result = Invoke-CheckedProcess -FilePath $docker.Source -ArgumentList @('info', '--format', '{{.OSType}}|{{.Architecture}}') -TimeoutSeconds 10 -AllowNonZero
        if ($result.ExitCode -ne 0) { return [pscustomobject]@{ available = $false; status = 'unverified-unavailable'; reason = 'daemon-unreachable' } }
        $parts = $result.StandardOutput.Trim().Split('|')
        if ($parts.Count -ne 2 -or $parts[0] -cne 'linux' -or $parts[1] -notin @('amd64', 'x86_64')) {
            return [pscustomobject]@{ available = $false; status = 'unverified-unavailable'; reason = 'wrong-platform' }
        }
        return [pscustomobject]@{ available = $true; status = 'unverified-not-implemented'; reason = 'adapter-deferred-to-plan-01-03' }
    }
    catch { return [pscustomobject]@{ available = $false; status = 'unverified-unavailable'; reason = 'probe-failed' } }
}

function Protect-PrivateSigningFile {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite); return }
    $icacls = (Get-Command icacls.exe -CommandType Application -ErrorAction Stop).Source
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    [void](Invoke-CheckedProcess -FilePath $icacls -ArgumentList @($Path, '/inheritance:r', '/grant:r', "${identity}:(R,W)") -TimeoutSeconds 30 -RedactValue @($identity))
}

function Publish-BuildArtifacts {
    param(
        [Parameter(Mandatory)] [string] $StagingDirectory,
        [Parameter(Mandatory)] [string] $BuildId,
        [Parameter(Mandatory)] [string] $BuildRequestHash,
        [Parameter(Mandatory)] $BackendResult,
        [Parameter(Mandatory)] [string] $QemuImgPath,
        [Parameter(Mandatory)] [string] $SourceCommit,
        [Parameter(Mandatory)] $DockerProbe,
        [Parameter(Mandatory)] $Inputs,
        [Parameter(Mandatory)] $BuildRequest
    )
    $lockPath = Join-Path $StagingDirectory 'resolved-build-lock.json'
    if (-not [System.IO.File]::Exists($lockPath)) { throw (New-BuildException -Code 'BUILD_OUTPUT_MISSING' -Message 'resolved-build-lock.json is absent.') }
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json -Depth 64
    [void](Test-ResolvedBuildLock -Lock $lock -ExpectedBuildRequestSha256 $BuildRequestHash)
    [void](Test-ResolvedTrustedKeys -TrustedKeys @($lock.trusted_keys) -RepositoryKeys $Inputs.alpine.repository_keys -SigningPublicSha256 $BuildRequest.signing.public_key_sha256)
    if (-not [bool]$BackendResult.CleanupComplete) {
        throw (New-BuildException -Code 'QEMU_CLEANUP_INCOMPLETE' -Message 'QEMU cleanup did not complete, so artifact publication is forbidden.')
    }

    foreach ($recordName in @('builder_packages_record', 'apk_files_record')) {
        $record = Get-ObjectProperty -Object $lock -Name $recordName
        [void](Test-GeneratedFileRecord -Record $record -BaseDirectory $StagingDirectory -ExpectedProducer 'run-build.sh:prepare-repository')
    }
    $iso = Get-ChildItem -LiteralPath $StagingDirectory -File -Filter '*.iso' | Select-Object -First 1
    if ($null -eq $iso -or $iso.Length -le 0) { throw (New-BuildException -Code 'BUILD_ISO_MISSING' -Message 'The Linux build produced no nonempty ISO.') }
    $isoHash = Get-LowerFileSha256 -Path $iso.FullName
    $isoName = "300k-bootstrap-x86_64-$($isoHash.Substring(0,12)).iso"
    if ($iso.Name -cne $isoName) {
        $renamed = Join-Path $StagingDirectory $isoName
        [System.IO.File]::Move($iso.FullName, $renamed)
        $iso = Get-Item -LiteralPath $renamed
    }

    $qemuInfoResult = Invoke-CheckedProcess -FilePath $QemuImgPath -ArgumentList @('info', '--output=json', $iso.FullName) -TimeoutSeconds 60
    $qemuInfo = $qemuInfoResult.StandardOutput | ConvertFrom-Json -Depth 10
    $sanitizedQemuInfo = [ordered]@{ format = $qemuInfo.format; virtual_size = [long]$qemuInfo.'virtual-size'; actual_size = [long]$iso.Length }
    Write-CanonicalJson -Value $sanitizedQemuInfo -Path (Join-Path $StagingDirectory 'qemu-image-info.json')

    $environment = [ordered]@{
        schema_version = 1
        backend = 'qemu'
        backend_status = 'executed'
        guest_os = 'linux'
        guest_arch = 'x86_64'
        alpine_release = '3.24.1'
        qemu_cloud_image_sha512 = $BackendResult.CloudImageSha512
        docker_status = $DockerProbe.status
        docker_reason = $DockerProbe.reason
        serial_host_fingerprint = $BackendResult.SerialFingerprint
        live_management_stages = @($BackendResult.ManagementStages)
        cleanup_complete = [bool]$BackendResult.CleanupComplete
        source_commit = $SourceCommit
    }
    Write-CanonicalJson -Value $environment -Path (Join-Path $StagingDirectory 'environment-report.json')

    $allowedFiles = @(
        'build-request.json', 'resolved-build-lock.json', 'builder-packages.lock', 'apk-files.sha256',
        $isoName, 'boot-layout.txt', 'qemu-image-info.json', 'environment-report.json',
        'serial-evidence.log', 'repository-evidence.json', 'resource-inventory.json'
    )
    foreach ($required in @('resolved-build-lock.json', 'builder-packages.lock', 'apk-files.sha256', $isoName, 'boot-layout.txt', 'qemu-image-info.json', 'environment-report.json', 'serial-evidence.log', 'resource-inventory.json')) {
        if (-not [System.IO.File]::Exists((Join-Path $StagingDirectory $required))) { throw (New-BuildException -Code 'BUILD_EVIDENCE_MISSING' -Message "Required evidence '$required' is absent.") }
    }

    $distRoot = Join-Path $script:BuildRepositoryRoot 'dist'
    [System.IO.Directory]::CreateDirectory($distRoot) | Out-Null
    $partialDirectory = Join-Path $distRoot ('.partial-' + $BuildId + '-' + [Guid]::NewGuid().ToString('N'))
    $finalDirectory = Join-Path $distRoot $BuildId
    [System.IO.Directory]::CreateDirectory($partialDirectory) | Out-Null
    try {
        foreach ($name in $allowedFiles) {
            $source = Join-Path $StagingDirectory $name
            if ([System.IO.File]::Exists($source)) {
                $destination = Join-Path $partialDirectory $name
                [System.IO.File]::Copy($source, $destination, $false)
                if ((Get-LowerFileSha256 -Path $source) -cne (Get-LowerFileSha256 -Path $destination)) {
                    throw (New-BuildException -Code 'PUBLICATION_HASH_MISMATCH' -Message "Artifact copy '$name' changed bytes.")
                }
            }
        }
        $requestSource = Join-Path $StagingDirectory 'build-request.json'
        if (-not [System.IO.File]::Exists($requestSource)) { throw (New-BuildException -Code 'BUILD_REQUEST_EVIDENCE_MISSING' -Message 'Staged BuildRequest evidence is absent.') }

        $artifacts = @()
        foreach ($file in Get-ChildItem -LiteralPath $partialDirectory -File | Sort-Object Name) {
            $artifacts += [ordered]@{ file = $file.Name; sha256 = Get-LowerFileSha256 -Path $file.FullName; bytes = [long]$file.Length }
        }
        $manifest = [ordered]@{ schema_version = 1; build_id = $BuildId; build_request_sha256 = $BuildRequestHash; artifacts = $artifacts }
        Write-CanonicalJson -Value $manifest -Path (Join-Path $partialDirectory 'artifact-manifest.json')
        if ([System.IO.Directory]::Exists($finalDirectory)) { throw (New-BuildException -Code 'BUILD_ALREADY_PUBLISHED' -Message "Build '$BuildId' is already published; use -Clean only for its exact namespace.") }
        [System.IO.Directory]::Move($partialDirectory, $finalDirectory)
        $latest = [ordered]@{ schema_version = 1; build_id = $BuildId; directory = $BuildId; iso_file = $isoName; iso_sha256 = $isoHash; iso_bytes = [long]$iso.Length }
        $latestPartial = Join-Path $distRoot 'LATEST.json.partial'
        Write-CanonicalJson -Value $latest -Path $latestPartial
        [System.IO.File]::Move($latestPartial, (Join-Path $distRoot 'LATEST.json'), $true)
        return [pscustomobject]@{ BuildId = $BuildId; Directory = $finalDirectory; IsoFile = $isoName; IsoSha256 = $isoHash; IsoBytes = [long]$iso.Length }
    }
    catch {
        if ([System.IO.Directory]::Exists($partialDirectory)) { [System.IO.Directory]::Delete($partialDirectory, $true) }
        throw
    }
}

function Invoke-300kBuild {
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Docker', 'Qemu')] [string] $SelectedBackend,
        [ValidateSet('Bootstrap')] [string] $SelectedTarget,
        [Parameter(Mandatory)] [string] $SelectedStateRoot,
        [Parameter(Mandatory)] [string] $SelectedQemuRoot,
        [Nullable[long]] $RequestedSourceDateEpoch,
        [switch] $InitializeKey,
        [switch] $OnlyPreflight,
        [switch] $CleanExactNamespace
    )
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw (New-BuildException -Code 'POWERSHELL_VERSION_UNSUPPORTED' -Message 'PowerShell 7 or newer is required.') }
    $inputsPath = Join-Path $script:BuildRepositoryRoot 'builder/inputs.json'
    $inputs = Get-Content -Raw -LiteralPath $inputsPath | ConvertFrom-Json -Depth 64
    Assert-PublicInputs -Inputs $inputs
    $state = Resolve-ExternalStateRoot -Path $SelectedStateRoot
    $qemuExe = [System.IO.Path]::GetFullPath((Join-Path $SelectedQemuRoot 'qemu-system-x86_64.exe'))
    $qemuImg = [System.IO.Path]::GetFullPath((Join-Path $SelectedQemuRoot 'qemu-img.exe'))
    if (-not [System.IO.File]::Exists($qemuExe) -or -not [System.IO.File]::Exists($qemuImg)) {
        throw (New-BuildException -Code 'QEMU_PREFLIGHT_FAILED' -Message 'qemu-system-x86_64.exe and qemu-img.exe are required at -QemuRoot.')
    }

    $dockerProbe = if ($SelectedBackend -ceq 'Qemu') {
        [pscustomobject]@{ available = $false; status = 'not-probed-explicit-qemu'; reason = 'explicit-qemu' }
    }
    else { Get-DockerProbe }
    if ($SelectedBackend -ceq 'Docker') {
        if (-not $dockerProbe.available) { throw (New-BuildException -Code 'DOCKER_PREFLIGHT_FAILED' -Message "Explicit Docker backend failed: $($dockerProbe.reason)") }
        throw (New-BuildException -Code 'DOCKER_BACKEND_NOT_IMPLEMENTED' -Message 'Docker is verified but its adapter is intentionally deferred to Plan 01-03.')
    }
    if ($OnlyPreflight) {
        return [pscustomobject]@{ status = 'preflight-passed'; backend = 'qemu'; docker_status = $dockerProbe.status; qemu = 'available'; target = $SelectedTarget }
    }

    Assert-CleanRepository
    [System.IO.Directory]::CreateDirectory($state) | Out-Null
    $sourceIdentity = Get-GitSourceIdentity -RequestedEpoch $RequestedSourceDateEpoch
    $runNonce = [Guid]::NewGuid().ToString('N')
    $runRoot = Join-Path $state "state\host-runs\$runNonce"
    [System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
    $sourceArchive = Join-Path $runRoot 'source.tar'
    $archiveHash = New-DeterministicSourceArchive -Destination $sourceArchive
    $source = [pscustomobject]@{
        git_commit = $sourceIdentity.git_commit
        archive_sha256 = $archiveHash
        source_date_epoch = $sourceIdentity.source_date_epoch
        dirty = $false
    }
    $hashes = [ordered]@{
        inputs_sha256 = Get-LowerFileSha256 -Path $inputsPath
        run_build_sha256 = Get-LowerFileSha256 -Path (Join-Path $script:BuildRepositoryRoot 'scripts/linux/run-build.sh')
        profile_sha256 = Get-LowerFileSha256 -Path (Join-Path $script:BuildRepositoryRoot 'builder/profiles/mkimg.300k.sh')
    }
    $cacheIdentity = $hashes.inputs_sha256
    $backendExport = Join-Path $runRoot 'export'
    [System.IO.Directory]::CreateDirectory($backendExport) | Out-Null

    if ($InitializeKey) {
        $secretRoot = Join-Path $state 'secrets\apk'
        $existingIdentityPath = Join-Path $secretRoot 'signing-public.json'
        if (
            [System.IO.File]::Exists($existingIdentityPath) -and
            [System.IO.File]::Exists((Join-Path $secretRoot '300k.rsa')) -and
            [System.IO.File]::Exists((Join-Path $secretRoot '300k.rsa.pub'))
        ) {
            $existingIdentity = Get-Content -Raw -LiteralPath $existingIdentityPath | ConvertFrom-Json
            [void](Test-SigningPublicIdentity -SigningPublic $existingIdentity -BaseDirectory $secretRoot)
            return [pscustomobject]@{
                status = 'signing-key-already-initialized'
                backend = 'qemu'
                signing_public_file = 'signing-public.json'
                signing_public_sha256 = $existingIdentity.public_key_sha256
                cleanup_complete = $true
            }
        }
        $request = New-KeyInitRequest -Inputs $inputs -RunNonce $runNonce
        $requestPath = Join-Path $runRoot 'key-init-request.json'
        Write-CanonicalJson -Value $request -Path $requestPath
        $result = Invoke-QemuBackend -Operation init-signing-key -QemuRoot $SelectedQemuRoot -StateRoot $state -RunId $runNonce `
            -RequestFile $requestPath -SourceArchive $sourceArchive -ExportDirectory $backendExport `
            -CloudImageUri ([uri]$inputs.qemu.cloud_image_url) -CloudImageSha512 $inputs.qemu.cloud_image_sha512 -CacheIdentity $cacheIdentity
        [System.IO.Directory]::CreateDirectory($secretRoot) | Out-Null
        foreach ($name in @('300k.rsa', '300k.rsa.pub', 'signing-public.json')) {
            $generated = Join-Path $backendExport $name
            if (-not [System.IO.File]::Exists($generated)) { throw (New-BuildException -Code 'KEY_INIT_OUTPUT_MISSING' -Message "Key initialization did not return '$name'.") }
            [System.IO.File]::Copy($generated, (Join-Path $secretRoot $name), $false)
        }
        Protect-PrivateSigningFile -Path (Join-Path $secretRoot '300k.rsa')
        $publicIdentity = Get-Content -Raw -LiteralPath (Join-Path $secretRoot 'signing-public.json') | ConvertFrom-Json
        [void](Test-SigningPublicIdentity -SigningPublic $publicIdentity -BaseDirectory $secretRoot)
        return [pscustomobject]@{ status = 'signing-key-initialized'; backend = 'qemu'; signing_public_file = 'signing-public.json'; signing_public_sha256 = $publicIdentity.public_key_sha256; cleanup_complete = $true }
    }

    $secretRoot = Join-Path $state 'secrets\apk'
    $signingPublicJson = Join-Path $secretRoot 'signing-public.json'
    if (-not [System.IO.File]::Exists($signingPublicJson)) { throw (New-BuildException -Code 'SIGNING_PUBLIC_REQUIRED' -Message 'Run -InitializeSigningKey before an ordinary build.') }
    $signing = Get-Content -Raw -LiteralPath $signingPublicJson | ConvertFrom-Json
    [void](Test-SigningPublicIdentity -SigningPublic $signing -BaseDirectory $secretRoot)
    $request = New-BuildRequest -Inputs $inputs -Source $source -InputHashes $hashes -SigningPublic $signing
    $requestPath = Join-Path $runRoot 'build-request.json'
    Write-CanonicalJson -Value $request -Path $requestPath
    $requestHash = Get-LowerFileSha256 -Path $requestPath
    $buildId = 'p01-' + $requestHash.Substring(0,12)

    if ($CleanExactNamespace) {
        $exactOutput = Join-Path $script:BuildRepositoryRoot "dist\$buildId"
        if ([System.IO.Directory]::Exists($exactOutput)) { [System.IO.Directory]::Delete($exactOutput, $true) }
    }
    [System.IO.File]::Copy($requestPath, (Join-Path $backendExport 'build-request.json'), $true)
    $backendResult = Invoke-QemuBackend -Operation build -QemuRoot $SelectedQemuRoot -StateRoot $state -RunId $runNonce `
        -RequestFile $requestPath -SourceArchive $sourceArchive -ExportDirectory $backendExport `
        -CloudImageUri ([uri]$inputs.qemu.cloud_image_url) -CloudImageSha512 $inputs.qemu.cloud_image_sha512 -CacheIdentity $cacheIdentity `
        -SigningPrivateFile (Join-Path $secretRoot '300k.rsa') -SigningPublicFile (Join-Path $secretRoot '300k.rsa.pub')
    [System.IO.File]::Copy($requestPath, (Join-Path $backendExport 'build-request.json'), $true)
    return Publish-BuildArtifacts -StagingDirectory $backendExport -BuildId $buildId -BuildRequestHash $requestHash -BackendResult $backendResult -QemuImgPath $qemuImg -SourceCommit $sourceIdentity.git_commit -DockerProbe $dockerProbe -Inputs $inputs -BuildRequest $request
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-300kBuild -SelectedBackend $Backend -SelectedTarget $Target -SelectedStateRoot $StateRoot -SelectedQemuRoot $QemuRoot `
            -RequestedSourceDateEpoch $SourceDateEpoch -InitializeKey:$InitializeSigningKey -OnlyPreflight:$PreflightOnly -CleanExactNamespace:$Clean
        Write-Output (ConvertTo-CanonicalJsonText -Value $result)
        exit 0
    }
    catch {
        $code = [string]$_.Exception.Data['Code']
        if ([string]::IsNullOrWhiteSpace($code)) { $code = 'UNHANDLED_BUILD_ERROR' }
        [Console]::Error.WriteLine("$code`: $($_.Exception.Message)")
        exit 1
    }
}
