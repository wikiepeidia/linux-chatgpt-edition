[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Docker', 'Qemu')]
    [string] $Backend = 'Auto',

    [ValidateSet('Bootstrap', 'DeadlineMvp')]
    [string] $Target = 'Bootstrap',

    [string] $StateRoot = (Join-Path $env:LOCALAPPDATA '300k-linux'),
    [string] $QemuRoot = 'D:\VM\qemu',
    [Nullable[long]] $SourceDateEpoch,
    [switch] $InitializeSigningKey,
    [switch] $BuilderReadinessProbe,
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
    $isoTool = $Inputs.inspection_toolchain.iso
    $expectedBanner = ([string]$isoTool.version_identity + ' : RockRidge filesystem manipulator, libburnia project.')
    $bannerBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(([string]$isoTool.stderr_banner + "`n`n"))
    $bannerHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bannerBytes)).ToLowerInvariant()
    if ($isoTool.version_identity -cne 'xorriso 1.5.8' -or $isoTool.stderr_banner -cne $expectedBanner -or
        $isoTool.stderr_banner_framing -cne 'lf-lf' -or [long]$isoTool.stderr_banner_bytes -ne [long]$bannerBytes.Length -or
        $isoTool.stderr_banner_sha256 -cnotmatch '^[0-9a-f]{64}$' -or $isoTool.stderr_banner_sha256 -cne $bannerHash) {
        throw (New-BuildException -Code 'INPUT_INSPECTION_TOOLCHAIN_INVALID' -Message 'The xorriso identity and exact framed stderr banner pins are inconsistent.')
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
        $SigningPublic,
        [ValidateSet('Bootstrap', 'DeadlineMvp')] [string] $SelectedTarget = 'Bootstrap'
    )
    Assert-PublicInputs -Inputs $Inputs
    if ($null -eq $SigningPublic) {
        throw (New-BuildException -Code 'SIGNING_PUBLIC_REQUIRED' -Message 'Create and validate signing-public.json before constructing BuildRequest.')
    }
    [void](Test-SigningPublicIdentity -SigningPublic $SigningPublic)
    if ($Source.git_commit -cnotmatch '^[0-9a-f]{40}$' -or $Source.archive_sha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$Source.source_date_epoch -le 0 -or [bool]$Source.dirty) {
        throw (New-BuildException -Code 'BUILD_SOURCE_INVALID' -Message 'BuildRequest source identity must be clean, exact, and positive-epoch.')
    }
    $requiredHashNames = @('inputs_sha256', 'run_build_sha256', 'inspect_iso_sha256', 'profile_sha256')
    if ($SelectedTarget -ceq 'DeadlineMvp') { $requiredHashNames += @('inspect_deadline_iso_sha256', 'apkovl_sha256') }
    foreach ($name in $requiredHashNames) {
        if ([string](Get-ObjectProperty -Object $InputHashes -Name $name) -cnotmatch '^[0-9a-f]{64}$') {
            throw (New-BuildException -Code 'BUILD_INPUT_HASH_INVALID' -Message "Build input hash '$name' is malformed.")
        }
    }

    $targetSpec = if ($SelectedTarget -ceq 'DeadlineMvp') {
        [ordered]@{ name = 'DeadlineMvp'; os = 'linux'; arch = 'x86_64'; format = 'iso'; profile = '300k_deadline' }
    }
    else {
        [ordered]@{ name = 'Bootstrap'; os = 'linux'; arch = 'x86_64'; format = 'iso'; profile = '300k_bootstrap' }
    }
    $publicInputs = [ordered]@{
        inputs_sha256 = [string](Get-ObjectProperty -Object $InputHashes -Name 'inputs_sha256')
        run_build_sha256 = [string](Get-ObjectProperty -Object $InputHashes -Name 'run_build_sha256')
        inspect_iso_sha256 = [string](Get-ObjectProperty -Object $InputHashes -Name 'inspect_iso_sha256')
        profile_sha256 = [string](Get-ObjectProperty -Object $InputHashes -Name 'profile_sha256')
    }
    if ($SelectedTarget -ceq 'DeadlineMvp') {
        $publicInputs.inspect_deadline_iso_sha256 = [string](Get-ObjectProperty -Object $InputHashes -Name 'inspect_deadline_iso_sha256')
        $publicInputs.apkovl_sha256 = [string](Get-ObjectProperty -Object $InputHashes -Name 'apkovl_sha256')
    }

    return [ordered]@{
        schema = 'BuildRequest'
        schema_version = 1
        target = $targetSpec
        source = [ordered]@{
            git_commit = $Source.git_commit
            archive_sha256 = $Source.archive_sha256
            source_date_epoch = [long]$Source.source_date_epoch
            dirty = $false
        }
        public_inputs = $publicInputs
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
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ([System.IO.Directory]::Exists($current) -or [System.IO.File]::Exists($current)) {
            $attributes = [System.IO.File]::GetAttributes($current)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw (New-BuildException -Code 'STATE_PATH_REPARSE_POINT' -Message 'State root may not traverse a reparse point.')
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
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
    foreach ($entryName in @(
        'scripts/linux/run-build.sh', 'scripts/linux/inspect-iso.sh', 'scripts/linux/inspect-deadline-iso.sh',
        'builder/profiles/mkimg.300k.sh', 'builder/apkovl/genapkovl-300k.sh',
        'builder/apkovl/rootfs/etc/local.d/300k.start', 'builder/apkovl/rootfs/etc/profile.d/300k-session.sh',
        'builder/apkovl/rootfs/home/chatgpt/.xinitrc', 'builder/apkovl/rootfs/usr/local/bin/300k-runtime',
        'builder/apkovl/rootfs/usr/local/sbin/300k-power'
    )) {
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

function Assert-ClosedObjectKeys {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string[]] $ExpectedKeys,
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [string] $Label
    )
    if ($null -eq $Object) { throw (New-BuildException -Code $Code -Message "$Label is null.") }
    $actual = if ($Object -is [System.Collections.IDictionary]) { @($Object.Keys | ForEach-Object { [string]$_ }) } else { @($Object.PSObject.Properties.Name) }
    $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $actualSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $ExpectedKeys) { [void]$expectedSet.Add($key) }
    foreach ($key in $actual) { [void]$actualSet.Add($key) }
    if ($actual.Count -ne $ExpectedKeys.Count -or -not $actualSet.SetEquals($expectedSet)) {
        throw (New-BuildException -Code $Code -Message "$Label has missing or unexpected keys.")
    }
}

function Assert-ClosedRelativeArtifactName {
    param([Parameter(Mandatory)] [string] $Name)
    if (
        [string]::IsNullOrWhiteSpace($Name) -or
        $Name.Length -gt 160 -or
        $Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
        $Name.Contains('..', [System.StringComparison]::Ordinal) -or
        [System.IO.Path]::IsPathRooted($Name) -or
        $Name.IndexOfAny([char[]]@([char]0, [char]47, [char]92, "`r", "`n", "`t")) -ge 0
    ) { throw (New-BuildException -Code 'ARTIFACT_NAME_INVALID' -Message 'Artifact names must be flat, relative, normalized, and separator-free.') }
    return $Name
}

function Assert-NoReparseAncestors {
    param([Parameter(Mandatory)] [string] $Path)
    $current = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ([System.IO.Directory]::Exists($current) -or [System.IO.File]::Exists($current)) {
            if (([System.IO.File]::GetAttributes($current) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw (New-BuildException -Code 'STAGING_REPARSE_POINT' -Message 'Artifact paths may not traverse a reparse point.')
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
}

function Get-ClosedRegularArtifact {
    param([Parameter(Mandatory)] [string] $BaseDirectory, [Parameter(Mandatory)] [string] $Name)
    $safeName = Assert-ClosedRelativeArtifactName -Name $Name
    $root = [System.IO.Path]::GetFullPath($BaseDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    Assert-NoReparseAncestors -Path $root
    $path = [System.IO.Path]::GetFullPath((Join-Path $root $safeName))
    if (-not $path.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-BuildException -Code 'STAGING_PATH_ESCAPE' -Message 'Artifact path escaped its staging root.')
    }
    if (-not [System.IO.File]::Exists($path)) { throw (New-BuildException -Code 'STAGING_FILE_MISSING' -Message "Required artifact '$safeName' is absent.") }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0) {
        throw (New-BuildException -Code 'STAGING_FILE_INVALID' -Message "Artifact '$safeName' is not one positive regular no-follow file.")
    }
    return $item
}

function Read-ClosedJsonArtifact {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Code)
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 64 }
    catch { throw (New-BuildException -Code $Code -Message "JSON artifact '$([System.IO.Path]::GetFileName($Path))' is malformed." -InnerException $_.Exception) }
}

function Assert-StagingTextSecretFree {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Name)
    $text = [System.IO.File]::ReadAllText($Path)
    $secretPattern = '(?i)(FICT[A-Z0-9_]*SECRET_TOKEN[=:]|BEGIN [A-Z0-9 ]*PRIVATE KEY|[A-Za-z]:\\Users\\|\\\\[^\\\s]+\\[^\\\s]+|wikiepeidia|management_ed25519|/run/300k-secrets)'
    if ($text -match $secretPattern) { throw (New-BuildException -Code 'STAGING_SECRET_FOUND' -Message "Artifact '$Name' contains private management material.") }
    if ($Name -ceq 'serial-diagnostic.log') {
        $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrEmpty($_) })
        if ($lines.Count -eq 0 -or @($lines | Where-Object { $_ -cnotmatch '^300K_[A-Z0-9_]+(?:\s+[A-Za-z0-9_./:+=-]+)*$' }).Count -ne 0) {
            throw (New-BuildException -Code 'STAGING_SERIAL_INVALID' -Message 'Sanitized serial diagnostic is empty or contains a non-allowlisted line.')
        }
    }
}

function Assert-IsoAuditNonVacuous {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Audit,
        [Parameter(Mandatory)] $Inputs
    )

    $code = if ([long]$Audit.counts.members -le 0) {
        'ISO_AUDIT_MEMBERS_ZERO'
    }
    elseif ([long]$Audit.counts.regular_files -le 0) {
        'ISO_AUDIT_REGULAR_FILES_ZERO'
    }
    elseif ([long]$Audit.counts.regular_files -gt [long]$Audit.counts.members) {
        'ISO_AUDIT_REGULAR_FILES_EXCEED_MEMBERS'
    }
    elseif ([long]$Audit.counts.containers -le 0) {
        'ISO_AUDIT_CONTAINERS_ZERO'
    }
    elseif ([long]$Audit.counts.expanded_bytes -le 0) {
        'ISO_AUDIT_EXPANDED_BYTES_ZERO'
    }
    elseif ([long]$Audit.counts.expanded_bytes -gt [long]$Inputs.inspection_policy.limits.max_total_expanded_bytes) {
        'ISO_AUDIT_EXPANDED_BYTES_EXCEED_LIMIT'
    }
    elseif (
        [int]$Audit.counts.max_observed_depth -lt 0 -or
        [int]$Audit.counts.max_observed_depth -gt [int]$Inputs.inspection_policy.limits.max_depth
    ) {
        'ISO_AUDIT_DEPTH_OUT_OF_RANGE'
    }
    elseif ([int]$Audit.public_key_allowance.closed_key_count -ne 4) {
        'ISO_AUDIT_CLOSED_KEY_COUNT_INVALID'
    }
    elseif ($Audit.public_key_allowance.manifest_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        'ISO_AUDIT_KEY_MANIFEST_HASH_INVALID'
    }
    elseif ($Audit.structural_boot_findings.classification -cne 'structural') {
        'ISO_AUDIT_CLASSIFICATION_INVALID'
    }
    elseif (-not [bool]$Audit.structural_boot_findings.bios_tree_present) {
        'ISO_AUDIT_BIOS_TREE_MISSING'
    }
    elseif (-not [bool]$Audit.structural_boot_findings.uefi_tree_present) {
        'ISO_AUDIT_UEFI_TREE_MISSING'
    }
    else { $null }

    if ($null -ne $code) {
        throw (New-BuildException -Code $code -Message 'Decoded ISO audit invariant failed.')
    }
}

function Test-ClosedStagingBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StagingDirectory,
        [Parameter(Mandatory)] [string] $ExpectedBuildRequestSha256,
        [Parameter(Mandatory)] $Inputs,
        [Parameter(Mandatory)] $BuildRequest
    )
    $root = [System.IO.Path]::GetFullPath($StagingDirectory)
    if (-not [System.IO.Directory]::Exists($root)) { throw (New-BuildException -Code 'STAGING_DIRECTORY_MISSING' -Message 'Backend staging directory is absent.') }
    Assert-NoReparseAncestors -Path $root
    $entries = @(Get-ChildItem -LiteralPath $root -Force)
    if (@($entries | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) {
        throw (New-BuildException -Code 'STAGING_FILE_SET_INVALID' -Message 'Staging contains a directory, link, or reparse point.')
    }
    $isoEntries = @($entries | Where-Object { $_.Name -cmatch '^300k-bootstrap-x86_64-[0-9a-f]{12}[.]iso$' })
    if ($isoEntries.Count -ne 1) { throw (New-BuildException -Code 'BUILD_ISO_MISSING' -Message 'Staging must contain exactly one hash-qualified ISO.') }
    $isoName = $isoEntries[0].Name
    $requiredNames = @(
        'build-request.json', 'resolved-build-lock.json', 'builder-packages.lock', 'apk-files.sha256',
        $isoName, 'boot-layout.txt', 'iso-audit.json', 'SHA256SUMS', 'qemu-image-info.json',
        'environment-report.json', 'serial-diagnostic.log', 'repository-evidence.json', 'resource-inventory.json'
    )
    $actualNames = @($entries.Name | Sort-Object -CaseSensitive)
    $expectedNames = @($requiredNames | Sort-Object -CaseSensitive)
    if ((ConvertTo-Json $actualNames -Compress) -cne (ConvertTo-Json $expectedNames -Compress)) {
        throw (New-BuildException -Code 'STAGING_FILE_SET_INVALID' -Message 'Staging file set is missing, duplicated, or contains an unexpected artifact.')
    }
    $items = [ordered]@{}
    foreach ($name in $requiredNames) { $items[$name] = Get-ClosedRegularArtifact -BaseDirectory $root -Name $name }
    foreach ($name in @('boot-layout.txt', 'serial-diagnostic.log', 'builder-packages.lock', 'apk-files.sha256', 'SHA256SUMS')) {
        Assert-StagingTextSecretFree -Path $items[$name].FullName -Name $name
    }

    $requestPath = $items['build-request.json'].FullName
    if ((Get-LowerFileSha256 -Path $requestPath) -cne $ExpectedBuildRequestSha256 -or [System.IO.File]::ReadAllText($requestPath) -cne (ConvertTo-CanonicalJsonText -Value $BuildRequest)) {
        throw (New-BuildException -Code 'BUILD_REQUEST_EVIDENCE_INVALID' -Message 'Staged BuildRequest does not match the immutable host request bytes.')
    }
    $lock = Read-ClosedJsonArtifact -Path $items['resolved-build-lock.json'].FullName -Code 'RESOLVED_LOCK_INVALID'
    Assert-ClosedObjectKeys -Object $lock -ExpectedKeys @('schema','schema_version','build_request_sha256','repository_object_id','repository_indexes','aports','trusted_keys','trust_policy','builder_packages_record','apk_files_record','inspection_commands','inspection_toolchain_sha256','offline_install','artifacts') -Code 'RESOLVED_LOCK_INVALID' -Label 'ResolvedBuildLock'
    [void](Test-ResolvedBuildLock -Lock $lock -ExpectedBuildRequestSha256 $ExpectedBuildRequestSha256)
    if ([int]$lock.schema_version -ne 1) { throw (New-BuildException -Code 'RESOLVED_LOCK_INVALID' -Message 'ResolvedBuildLock version is unsupported.') }
    Assert-ClosedObjectKeys -Object $lock.aports -ExpectedKeys @('commit','archive_sha256') -Code 'RESOLVED_LOCK_INVALID' -Label 'ResolvedBuildLock.aports'
    Assert-ClosedObjectKeys -Object $lock.trust_policy -ExpectedKeys @('mkimage_hostkeys','closed_keyring_verified','signature_bypass') -Code 'RESOLVED_LOCK_INVALID' -Label 'ResolvedBuildLock.trust_policy'
    Assert-ClosedObjectKeys -Object $lock.offline_install -ExpectedKeys @('repositories','apk_no_network','network_disabled','complete_manifest_verified') -Code 'RESOLVED_LOCK_INVALID' -Label 'ResolvedBuildLock.offline_install'
    if ($lock.aports.commit -cne $Inputs.aports.commit -or $lock.aports.archive_sha256 -cnotmatch '^[0-9a-f]{64}$' -or -not [bool]$lock.trust_policy.mkimage_hostkeys -or -not [bool]$lock.trust_policy.closed_keyring_verified -or [bool]$lock.trust_policy.signature_bypass -or
        (ConvertTo-Json @($lock.offline_install.repositories) -Compress) -cne '["file:///repo"]' -or -not [bool]$lock.offline_install.apk_no_network -or -not [bool]$lock.offline_install.network_disabled -or -not [bool]$lock.offline_install.complete_manifest_verified) {
        throw (New-BuildException -Code 'RESOLVED_LOCK_INVALID' -Message 'ResolvedBuildLock trust, aports, or offline-install contract is invalid.')
    }
    $indexes = @($lock.repository_indexes)
    if ($indexes.Count -ne @($Inputs.alpine.repositories).Count) { throw (New-BuildException -Code 'RESOLVED_LOCK_INVALID' -Message 'Repository index set is not closed.') }
    for ($index = 0; $index -lt $indexes.Count; $index++) {
        Assert-ClosedObjectKeys -Object $indexes[$index] -ExpectedKeys @('name','sha256','signature_verified') -Code 'RESOLVED_LOCK_INVALID' -Label 'ResolvedBuildLock.repository_indexes record'
        if ($indexes[$index].name -cne $Inputs.alpine.repositories[$index].name -or $indexes[$index].sha256 -cne $Inputs.alpine.repositories[$index].apkindex_sha256 -or -not [bool]$indexes[$index].signature_verified) { throw (New-BuildException -Code 'RESOLVED_LOCK_INVALID' -Message 'Repository index evidence differs from public inputs.') }
    }
    foreach ($trustedKey in @($lock.trusted_keys)) {
        Assert-ClosedObjectKeys -Object $trustedKey -ExpectedKeys @('file','sha256','trust') -Code 'RESOLVED_LOCK_TRUSTED_KEYS_INVALID' -Label 'ResolvedBuildLock.trusted_keys record'
    }
    [void](Test-ResolvedTrustedKeys -TrustedKeys @($lock.trusted_keys) -RepositoryKeys $Inputs.alpine.repository_keys -SigningPublicSha256 $BuildRequest.signing.public_key_sha256)
    foreach ($recordName in @('builder_packages_record', 'apk_files_record')) {
        $generatedRecord = Get-ObjectProperty -Object $lock -Name $recordName
        Assert-ClosedObjectKeys -Object $generatedRecord -ExpectedKeys @('file','sha256','bytes','producer','validator') -Code 'GENERATED_RECORD_INVALID' -Label $recordName
        [void](Test-GeneratedFileRecord -Record $generatedRecord -BaseDirectory $root -ExpectedProducer 'run-build.sh:prepare-repository')
    }
    if ($lock.inspection_toolchain_sha256 -cnotmatch '^[0-9a-f]{64}$') { throw (New-BuildException -Code 'INSPECTION_TOOLCHAIN_INVALID' -Message 'Inspection toolchain identity is malformed.') }
    $expectedFormats = @($Inputs.inspection_toolchain.PSObject.Properties.Name)
    $commands = @($lock.inspection_commands)
    if ($commands.Count -ne $expectedFormats.Count -or (ConvertTo-Json @($commands.format) -Compress) -cne (ConvertTo-Json $expectedFormats -Compress)) {
        throw (New-BuildException -Code 'INSPECTION_TOOLCHAIN_INVALID' -Message 'Resolved inspection command set is not closed and ordered.')
    }
    for ($index = 0; $index -lt $commands.Count; $index++) {
        $command = $commands[$index]
        $expected = @($Inputs.inspection_toolchain.PSObject.Properties)[$index].Value
        $commandKeys = @('format','package','command','command_sha256','version','retained_apk_file','retained_apk_sha256','package_ownership_verified','path_verified','round_trip_verified','retained_apk_verified','contract_source','retained_repository')
        $isIso = [string]$command.format -ceq 'iso'
        if ($isIso) {
            $commandKeys = @($commandKeys + @('version_stdout_hex','version_stdout_sha256','version_stdout_bytes','stderr_banner','stderr_banner_framing','stderr_banner_bytes','stderr_banner_sha256'))
        }
        Assert-ClosedObjectKeys -Object $command -ExpectedKeys $commandKeys -Code 'INSPECTION_TOOLCHAIN_INVALID' -Label 'inspection command'
        if ($command.package -cne $expected.package -or $command.command -cne $expected.command -or $command.command_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            -not [bool]$command.package_ownership_verified -or -not [bool]$command.path_verified -or -not [bool]$command.round_trip_verified -or -not [bool]$command.retained_apk_verified -or
            $command.retained_apk_sha256 -cnotmatch '^[0-9a-f]{64}$' -or $command.retained_apk_file -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*[.]apk$' -or
            $command.contract_source -cne 'builder/inputs.json:inspection_toolchain' -or $command.retained_repository -cne $lock.repository_object_id -or [string]::IsNullOrWhiteSpace([string]$command.version)) {
            throw (New-BuildException -Code 'INSPECTION_TOOLCHAIN_INVALID' -Message 'A decoder lacks exact package, path, retained APK, or round-trip evidence.')
        }
        if ($isIso) {
            $versionHex = [string]$command.version_stdout_hex
            if ([string]$command.version -cne [string]$expected.version_identity -or
                [string]$command.stderr_banner -cne [string]$expected.stderr_banner -or
                [string]$command.stderr_banner -cne ([string]$command.version + ' : RockRidge filesystem manipulator, libburnia project.') -or
                [string]$command.stderr_banner_framing -cne [string]$expected.stderr_banner_framing -or
                [long]$command.stderr_banner_bytes -ne [long]$expected.stderr_banner_bytes -or
                [string]$command.stderr_banner_sha256 -cne [string]$expected.stderr_banner_sha256 -or
                $versionHex -cnotmatch '^(?:[0-9a-f]{2})+$' -or [string]$command.version_stdout_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                [long]$command.version_stdout_bytes -le 0 -or [long]$command.version_stdout_bytes -gt 65536) {
                throw (New-BuildException -Code 'INSPECTION_TOOLCHAIN_INVALID' -Message 'The ISO decoder lacks separated exact version stdout and stderr banner evidence.')
            }
            try {
                $versionBytes = [Convert]::FromHexString($versionHex)
                $versionText = [System.Text.UTF8Encoding]::new($false, $true).GetString($versionBytes)
            } catch {
                throw (New-BuildException -Code 'INSPECTION_TOOLCHAIN_INVALID' -Message 'The xorriso version stdout serialization is not strict UTF-8 hexadecimal evidence.')
            }
            $versionHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($versionBytes)).ToLowerInvariant()
            $firstLf = $versionText.IndexOf("`n", [System.StringComparison]::Ordinal)
            if ([long]$versionBytes.Length -ne [long]$command.version_stdout_bytes -or $versionHash -cne [string]$command.version_stdout_sha256 -or
                -not $versionText.EndsWith("`n", [System.StringComparison]::Ordinal) -or $versionText -cmatch '[^\x0A\x20-\x7E]' -or
                $firstLf -le 0 -or $versionText.Substring(0, $firstLf) -cne [string]$command.version) {
                throw (New-BuildException -Code 'INSPECTION_TOOLCHAIN_INVALID' -Message 'The complete xorriso version stdout is not byte-bound to its canonical first-line identity.')
            }
        }
    }

    $isoItem = $items[$isoName]
    $isoHash = Get-LowerFileSha256 -Path $isoItem.FullName
    if ($isoName -cne "300k-bootstrap-x86_64-$($isoHash.Substring(0,12)).iso") { throw (New-BuildException -Code 'ISO_REFERENCE_MISMATCH' -Message 'ISO basename does not identify its host-measured bytes.') }
    $audit = Read-ClosedJsonArtifact -Path $items['iso-audit.json'].FullName -Code 'ISO_AUDIT_INVALID'
    Assert-ClosedObjectKeys -Object $audit -ExpectedKeys @('schema','schema_version','iso_sha256','iso_bytes','inspection_toolchain_sha256','accepted_decoders','limits','counts','structural_boot_findings','public_key_allowance','preflight_before_materialization','links_materialized','hostile_fixture_self_test','result') -Code 'ISO_AUDIT_INVALID' -Label 'IsoAudit'
    Assert-ClosedObjectKeys -Object $audit.limits -ExpectedKeys @('max_depth','max_members','max_path_bytes','max_file_bytes','max_total_expanded_bytes') -Code 'ISO_AUDIT_INVALID' -Label 'IsoAudit.limits'
    Assert-ClosedObjectKeys -Object $audit.counts -ExpectedKeys @('members','regular_files','containers','expanded_bytes','max_observed_depth') -Code 'ISO_AUDIT_INVALID' -Label 'IsoAudit.counts'
    Assert-ClosedObjectKeys -Object $audit.structural_boot_findings -ExpectedKeys @('bios_tree_present','uefi_tree_present','classification') -Code 'ISO_AUDIT_INVALID' -Label 'IsoAudit.structural_boot_findings'
    Assert-ClosedObjectKeys -Object $audit.public_key_allowance -ExpectedKeys @('closed_key_count','manifest_sha256') -Code 'ISO_AUDIT_INVALID' -Label 'IsoAudit.public_key_allowance'
    if ($audit.schema -cne 'IsoAudit' -or [int]$audit.schema_version -ne 1 -or $audit.result -cne 'pass' -or -not [bool]$audit.preflight_before_materialization -or [bool]$audit.links_materialized -or -not [bool]$audit.hostile_fixture_self_test) {
        throw (New-BuildException -Code 'ISO_AUDIT_INVALID' -Message 'Decoded ISO audit result or safety flags are invalid.')
    }
    if ($audit.iso_sha256 -cne $isoHash -or [long]$audit.iso_bytes -ne [long]$isoItem.Length -or $audit.inspection_toolchain_sha256 -cne $lock.inspection_toolchain_sha256) {
        throw (New-BuildException -Code 'ISO_REFERENCE_MISMATCH' -Message 'Audit, lock, and host-measured ISO identity disagree.')
    }
    if ((ConvertTo-Json @($audit.accepted_decoders) -Compress) -cne (ConvertTo-Json $expectedFormats -Compress)) {
        throw (New-BuildException -Code 'ISO_AUDIT_INVALID' -Message 'Audit decoder set differs from public inputs.')
    }
    foreach ($limit in @('max_depth','max_members','max_path_bytes','max_file_bytes','max_total_expanded_bytes')) {
        if ([long](Get-ObjectProperty -Object $audit.limits -Name $limit) -ne [long](Get-ObjectProperty -Object $Inputs.inspection_policy.limits -Name $limit)) {
            throw (New-BuildException -Code 'ISO_AUDIT_INVALID' -Message "Audit limit '$limit' differs from public inputs.")
        }
    }
    Assert-IsoAuditNonVacuous -Audit $audit -Inputs $Inputs
    $checksumLine = [System.IO.File]::ReadAllText($items['SHA256SUMS'].FullName).Replace("`r`n", "`n")
    if ($checksumLine -cne "$isoHash  $isoName`n") { throw (New-BuildException -Code 'ISO_REFERENCE_MISMATCH' -Message 'SHA256SUMS does not contain the one exact ISO record.') }
    $artifactMap = [ordered]@{ bootstrap_iso = $isoName; decoded_iso_audit = 'iso-audit.json'; iso_checksums = 'SHA256SUMS' }
    if (@($lock.artifacts).Count -ne 3) { throw (New-BuildException -Code 'ISO_REFERENCE_MISMATCH' -Message 'ResolvedBuildLock artifact set is not closed.') }
    foreach ($record in @($lock.artifacts)) {
        Assert-ClosedObjectKeys -Object $record -ExpectedKeys @('role','file','sha256','bytes') -Code 'ISO_REFERENCE_MISMATCH' -Label 'ResolvedBuildLock artifact'
        if (-not $artifactMap.Contains([string]$record.role) -or $artifactMap[[string]$record.role] -cne [string]$record.file) { throw (New-BuildException -Code 'ISO_REFERENCE_MISMATCH' -Message 'ResolvedBuildLock artifact role or filename is unexpected.') }
        $recordItem = $items[[string]$record.file]
        if ($record.sha256 -cne (Get-LowerFileSha256 -Path $recordItem.FullName) -or [long]$record.bytes -ne [long]$recordItem.Length) { throw (New-BuildException -Code 'ISO_REFERENCE_MISMATCH' -Message 'ResolvedBuildLock artifact bytes differ from host measurement.') }
    }
    $inventory = Read-ClosedJsonArtifact -Path $items['resource-inventory.json'].FullName -Code 'RESOURCE_INVENTORY_INVALID'
    Assert-ClosedObjectKeys -Object $inventory -ExpectedKeys @('schema_version','cleanup_complete','resources') -Code 'RESOURCE_INVENTORY_INVALID' -Label 'ResourceInventory'
    Assert-ClosedObjectKeys -Object $inventory.resources -ExpectedKeys @('qemu_lease_live','seed_listener_live','serial_listener_live','port_reservation_live','ssh_identity_present','known_hosts_present','overlay_present','management_scratch_present') -Code 'RESOURCE_INVENTORY_INVALID' -Label 'ResourceInventory.resources'
    if (-not [bool]$inventory.cleanup_complete -or @($inventory.resources.PSObject.Properties | Where-Object { [bool]$_.Value }).Count -ne 0) { throw (New-BuildException -Code 'RESOURCE_INVENTORY_INVALID' -Message 'QEMU resource inventory is not completely drained.') }

    $repositoryEvidence = Read-ClosedJsonArtifact -Path $items['repository-evidence.json'].FullName -Code 'REPOSITORY_EVIDENCE_INVALID'
    Assert-ClosedObjectKeys -Object $repositoryEvidence -ExpectedKeys @('schema','schema_version','build_request_sha256','repository_object_id','apk_count','official_indexes_verified','official_signatures_verified','content_addressed_snapshot_verified') -Code 'REPOSITORY_EVIDENCE_INVALID' -Label 'RepositoryEvidence'
    if ($repositoryEvidence.schema -cne 'RepositoryEvidence' -or [int]$repositoryEvidence.schema_version -ne 1 -or $repositoryEvidence.build_request_sha256 -cne $ExpectedBuildRequestSha256 -or $repositoryEvidence.repository_object_id -cne $lock.repository_object_id -or [long]$repositoryEvidence.apk_count -le 0 -or -not [bool]$repositoryEvidence.official_indexes_verified -or -not [bool]$repositoryEvidence.official_signatures_verified -or -not [bool]$repositoryEvidence.content_addressed_snapshot_verified) { throw (New-BuildException -Code 'REPOSITORY_EVIDENCE_INVALID' -Message 'Repository evidence is malformed or refers to different bytes.') }
    $qemuInfo = Read-ClosedJsonArtifact -Path $items['qemu-image-info.json'].FullName -Code 'QEMU_IMAGE_INFO_INVALID'
    Assert-ClosedObjectKeys -Object $qemuInfo -ExpectedKeys @('format','virtual_size','actual_size') -Code 'QEMU_IMAGE_INFO_INVALID' -Label 'QEMU image info'
    if ($qemuInfo.format -cne 'raw' -or [long]$qemuInfo.actual_size -ne [long]$isoItem.Length -or [long]$qemuInfo.virtual_size -lt [long]$isoItem.Length) { throw (New-BuildException -Code 'QEMU_IMAGE_INFO_INVALID' -Message 'QEMU image report differs from the ISO bytes.') }
    $environment = Read-ClosedJsonArtifact -Path $items['environment-report.json'].FullName -Code 'ENVIRONMENT_REPORT_INVALID'
    Assert-ClosedObjectKeys -Object $environment -ExpectedKeys @('schema_version','backend','backend_status','guest_os','guest_arch','alpine_release','qemu_cloud_image_sha512','docker_status','docker_reason','serial_host_fingerprint','live_management_stages','cleanup_complete','source_commit') -Code 'ENVIRONMENT_REPORT_INVALID' -Label 'EnvironmentReport'
    if ([int]$environment.schema_version -ne 1 -or $environment.backend -cne 'qemu' -or $environment.backend_status -cne 'executed' -or $environment.guest_os -cne 'linux' -or $environment.guest_arch -cne 'x86_64' -or $environment.alpine_release -cne '3.24.1' -or $environment.qemu_cloud_image_sha512 -cne $Inputs.qemu.cloud_image_sha512 -or $environment.serial_host_fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]+={0,2}$' -or -not [bool]$environment.cleanup_complete -or $environment.source_commit -cnotmatch '^[0-9a-f]{40}$') { throw (New-BuildException -Code 'ENVIRONMENT_REPORT_INVALID' -Message 'Environment report has an invalid enum, hash, fingerprint, or cleanup result.') }

    return [pscustomobject]@{ IsoFile = $isoName; IsoSha256 = $isoHash; IsoBytes = [long]$isoItem.Length; BuildRequestSha256 = $ExpectedBuildRequestSha256; Files = @($requiredNames) }
}

function Invoke-PublicationFailureStage {
    param([string] $FailureStage, [Parameter(Mandatory)] [string] $Stage)
    if (-not [string]::IsNullOrWhiteSpace($FailureStage) -and $FailureStage -ceq $Stage) {
        throw (New-BuildException -Code 'PUBLICATION_INJECTED_FAILURE' -Message "Injected publication failure at '$Stage'.")
    }
}

function Test-PublishedArtifactDirectory {
    param([Parameter(Mandatory)] [string] $Directory, [Parameter(Mandatory)] $ValidatedBundle, [Parameter(Mandatory)] [string] $BuildId)
    $manifestPath = Join-Path $Directory 'artifact-manifest.json'
    $expectedNames = @(@($ValidatedBundle.Files) + 'artifact-manifest.json' | Sort-Object -CaseSensitive)
    $actualNames = @(Get-ChildItem -LiteralPath $Directory -Force | ForEach-Object {
        if ($_.PSIsContainer -or ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $_.Length -le 0) { throw (New-BuildException -Code 'PUBLICATION_DIRECTORY_INVALID' -Message 'Published directory contains a non-regular artifact.') }
        $_.Name
    } | Sort-Object -CaseSensitive)
    if ((ConvertTo-Json $actualNames -Compress) -cne (ConvertTo-Json $expectedNames -Compress)) { throw (New-BuildException -Code 'PUBLICATION_DIRECTORY_INVALID' -Message 'Published directory file set is not closed.') }
    $manifest = Read-ClosedJsonArtifact -Path $manifestPath -Code 'PUBLICATION_MANIFEST_INVALID'
    Assert-ClosedObjectKeys -Object $manifest -ExpectedKeys @('schema','schema_version','build_id','build_request_sha256','artifacts') -Code 'PUBLICATION_MANIFEST_INVALID' -Label 'ArtifactManifest'
    if ($manifest.schema -cne 'ArtifactManifest' -or [int]$manifest.schema_version -ne 1 -or $manifest.build_id -cne $BuildId -or $manifest.build_request_sha256 -cne $ValidatedBundle.BuildRequestSha256 -or @($manifest.artifacts).Count -ne @($ValidatedBundle.Files).Count) {
        throw (New-BuildException -Code 'PUBLICATION_MANIFEST_INVALID' -Message 'ArtifactManifest identity or count is invalid.')
    }
    $recordNames = @()
    foreach ($record in @($manifest.artifacts)) {
        Assert-ClosedObjectKeys -Object $record -ExpectedKeys @('file','sha256','bytes') -Code 'PUBLICATION_MANIFEST_INVALID' -Label 'ArtifactManifest.artifacts record'
        $name = Assert-ClosedRelativeArtifactName -Name ([string]$record.file)
        $recordNames += $name
        $item = Get-ClosedRegularArtifact -BaseDirectory $Directory -Name $name
        if ($record.sha256 -cne (Get-LowerFileSha256 -Path $item.FullName) -or [long]$record.bytes -ne [long]$item.Length) { throw (New-BuildException -Code 'PUBLICATION_MANIFEST_INVALID' -Message "Manifest record '$name' differs from final bytes.") }
    }
    if ((ConvertTo-Json @($recordNames | Sort-Object -CaseSensitive) -Compress) -cne (ConvertTo-Json @($ValidatedBundle.Files | Sort-Object -CaseSensitive) -Compress)) {
        throw (New-BuildException -Code 'PUBLICATION_MANIFEST_INVALID' -Message 'ArtifactManifest record set is missing, duplicated, or unexpected.')
    }
    return $true
}

function Clear-IncompleteBuildNamespace {
    param(
        [Parameter(Mandatory)] [string] $DistRoot,
        [Parameter(Mandatory)] [string] $BuildId
    )
    if ($BuildId -cnotmatch '^[a-z0-9][a-z0-9-]{2,95}$') { throw (New-BuildException -Code 'BUILD_ID_INVALID' -Message 'Build identity is not a safe relative namespace.') }
    $dist = [System.IO.Path]::GetFullPath($DistRoot)
    if (-not [System.IO.Directory]::Exists($dist)) { return }
    Assert-NoReparseAncestors -Path $dist
    $pattern = '^' + [regex]::Escape('.partial-' + $BuildId + '-') + '[0-9a-f]{32}$'
    foreach ($entry in @(Get-ChildItem -LiteralPath $dist -Force | Where-Object { $_.Name -cmatch $pattern })) {
        if (-not $entry.PSIsContainer -or ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw (New-BuildException -Code 'CLEAN_NAMESPACE_INVALID' -Message 'Exact incomplete publication namespace contains a non-directory or reparse point.')
        }
        [System.IO.Directory]::Delete($entry.FullName, $true)
    }
}

function Publish-ValidatedArtifactBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StagingDirectory,
        [Parameter(Mandatory)] [string] $DistRoot,
        [Parameter(Mandatory)] [string] $BuildId,
        [Parameter(Mandatory)] $ValidatedBundle,
        [string] $FailureStage
    )
    if ($BuildId -cnotmatch '^[a-z0-9][a-z0-9-]{2,95}$') { throw (New-BuildException -Code 'BUILD_ID_INVALID' -Message 'Build identity is not a safe relative namespace.') }
    $dist = [System.IO.Path]::GetFullPath($DistRoot)
    [System.IO.Directory]::CreateDirectory($dist) | Out-Null
    Assert-NoReparseAncestors -Path $dist
    $totalBytes = [long]0
    foreach ($name in @($ValidatedBundle.Files)) { $totalBytes += (Get-ClosedRegularArtifact -BaseDirectory $StagingDirectory -Name $name).Length }
    $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($dist))
    if ($drive.AvailableFreeSpace -lt ($totalBytes * 2 + 1048576)) { throw (New-BuildException -Code 'PUBLICATION_SPACE_INSUFFICIENT' -Message 'Publication volume lacks the bounded copy allowance.') }
    $partialDirectory = Join-Path $dist ('.partial-' + $BuildId + '-' + [Guid]::NewGuid().ToString('N'))
    $finalDirectory = Join-Path $dist $BuildId
    $latestPath = Join-Path $dist 'LATEST.json'
    $latestPartial = Join-Path $dist ('LATEST.json.' + [Guid]::NewGuid().ToString('N') + '.partial')
    if ([System.IO.Directory]::Exists($finalDirectory) -or [System.IO.File]::Exists($finalDirectory)) { throw (New-BuildException -Code 'BUILD_ALREADY_PUBLISHED' -Message "Build '$BuildId' is already published.") }
    $priorLatest = if ([System.IO.File]::Exists($latestPath)) { [System.IO.File]::ReadAllBytes($latestPath) } else { $null }
    $renamed = $false
    $pointerReplaced = $false
    try {
        [System.IO.Directory]::CreateDirectory($partialDirectory) | Out-Null
        Invoke-PublicationFailureStage -FailureStage $FailureStage -Stage 'after-partial-create'
        $copyIndex = 0
        foreach ($name in @($ValidatedBundle.Files)) {
            $source = (Get-ClosedRegularArtifact -BaseDirectory $StagingDirectory -Name $name).FullName
            $destination = Join-Path $partialDirectory $name
            $copyPartial = "$destination.partial"
            [System.IO.File]::Copy($source, $copyPartial, $false)
            if ($copyIndex++ -eq 0) { Invoke-PublicationFailureStage -FailureStage $FailureStage -Stage 'after-partial-copy' }
            if ((Get-LowerFileSha256 -Path $source) -cne (Get-LowerFileSha256 -Path $copyPartial)) { throw (New-BuildException -Code 'PUBLICATION_HASH_MISMATCH' -Message "Artifact copy '$name' changed bytes.") }
            if ($copyIndex -eq 1) { Invoke-PublicationFailureStage -FailureStage $FailureStage -Stage 'after-copy-rehash' }
            [System.IO.File]::Move($copyPartial, $destination)
        }
        $records = @($ValidatedBundle.Files | Sort-Object -CaseSensitive | ForEach-Object {
            $item = Get-ClosedRegularArtifact -BaseDirectory $partialDirectory -Name $_
            [ordered]@{ file = $_; sha256 = Get-LowerFileSha256 -Path $item.FullName; bytes = [long]$item.Length }
        })
        Write-CanonicalJson -Value ([ordered]@{ schema = 'ArtifactManifest'; schema_version = 1; build_id = $BuildId; build_request_sha256 = $ValidatedBundle.BuildRequestSha256; artifacts = $records }) -Path (Join-Path $partialDirectory 'artifact-manifest.json')
        Invoke-PublicationFailureStage -FailureStage $FailureStage -Stage 'after-manifest-write'
        [void](Test-PublishedArtifactDirectory -Directory $partialDirectory -ValidatedBundle $ValidatedBundle -BuildId $BuildId)
        Invoke-PublicationFailureStage -FailureStage $FailureStage -Stage 'after-directory-revalidation'
        [System.IO.Directory]::Move($partialDirectory, $finalDirectory)
        $renamed = $true
        Invoke-PublicationFailureStage -FailureStage $FailureStage -Stage 'after-final-rename'
        Write-CanonicalJson -Value ([ordered]@{ schema_version = 1; build_id = $BuildId; directory = $BuildId; iso_file = $ValidatedBundle.IsoFile; iso_sha256 = $ValidatedBundle.IsoSha256; iso_bytes = [long]$ValidatedBundle.IsoBytes }) -Path $latestPartial
        Invoke-PublicationFailureStage -FailureStage $FailureStage -Stage 'after-pointer-temp-write'
        [void](Test-PublishedArtifactDirectory -Directory $finalDirectory -ValidatedBundle $ValidatedBundle -BuildId $BuildId)
        Invoke-PublicationFailureStage -FailureStage $FailureStage -Stage 'before-pointer-replace'
        [System.IO.File]::Move($latestPartial, $latestPath, $true)
        $pointerReplaced = $true
        Invoke-PublicationFailureStage -FailureStage $FailureStage -Stage 'after-pointer-replace'
        return [pscustomobject]@{ BuildId = $BuildId; Directory = $finalDirectory; IsoFile = $ValidatedBundle.IsoFile; IsoSha256 = $ValidatedBundle.IsoSha256; IsoBytes = [long]$ValidatedBundle.IsoBytes }
    }
    catch {
        if ($pointerReplaced) {
            if ($null -eq $priorLatest) { [System.IO.File]::Delete($latestPath) }
            else {
                $rollback = Join-Path $dist ('LATEST.json.rollback-' + [Guid]::NewGuid().ToString('N') + '.partial')
                [System.IO.File]::WriteAllBytes($rollback, $priorLatest)
                [System.IO.File]::Move($rollback, $latestPath, $true)
            }
        }
        if ([System.IO.File]::Exists($latestPartial)) { [System.IO.File]::Delete($latestPartial) }
        if ([System.IO.Directory]::Exists($partialDirectory)) { [System.IO.Directory]::Delete($partialDirectory, $true) }
        if ($renamed -and [System.IO.Directory]::Exists($finalDirectory)) { [System.IO.Directory]::Delete($finalDirectory, $true) }
        throw
    }
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
    if (-not [bool]$BackendResult.CleanupComplete) {
        throw (New-BuildException -Code 'QEMU_CLEANUP_INCOMPLETE' -Message 'QEMU cleanup did not complete, so artifact publication is forbidden.')
    }
    $isoCandidates = @(Get-ChildItem -LiteralPath $StagingDirectory -Force | Where-Object { -not $_.PSIsContainer -and $_.Name -cmatch '^300k-bootstrap-x86_64-[0-9a-f]{12}[.]iso$' })
    if ($isoCandidates.Count -ne 1) { throw (New-BuildException -Code 'BUILD_ISO_MISSING' -Message 'Backend staging did not return one hash-qualified ISO.') }
    $iso = $isoCandidates[0]
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
    $validated = Test-ClosedStagingBundle -StagingDirectory $StagingDirectory -ExpectedBuildRequestSha256 $BuildRequestHash -Inputs $Inputs -BuildRequest $BuildRequest
    $distRoot = Join-Path $script:BuildRepositoryRoot 'dist'
    return Publish-ValidatedArtifactBundle -StagingDirectory $StagingDirectory -DistRoot $distRoot -BuildId $BuildId -ValidatedBundle $validated
}

function New-DeadlineQemuArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $QemuExecutable,
        [Parameter(Mandatory)] [string] $IsoPath,
        [Parameter(Mandatory)] [string] $SerialPath,
        [ValidateRange(1024,65535)] [int] $QmpPort
    )
    $expectedQemu = [System.IO.Path]::GetFullPath('D:\VM\qemu\qemu-system-x86_64.exe')
    if ([System.IO.Path]::GetFullPath($QemuExecutable) -cne $expectedQemu) {
        throw (New-BuildException -Code 'DEADLINE_QEMU_PATH_INVALID' -Message 'Deadline smoke must use the supplied D:\VM\qemu executable.')
    }
    return @(
        '-machine','pc',
        '-accel','tcg',
        '-m','1024',
        '-boot','order=d,strict=on',
        '-cdrom',[System.IO.Path]::GetFullPath($IsoPath),
        '-vga','std',
        '-display','none',
        '-serial',('file:' + [System.IO.Path]::GetFullPath($SerialPath)),
        '-qmp',("tcp:127.0.0.1:$QmpPort,server=on,wait=off"),
        '-monitor','none',
        '-nic','none',
        '-no-reboot'
    )
}

function Test-DeadlineQemuArguments {
    param(
        [Parameter(Mandatory)] [string] $QemuExecutable,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $IsoPath,
        [Parameter(Mandatory)] [string] $SerialPath
    )
    $qmp = @($Arguments | Where-Object { $_ -cmatch '^tcp:127[.]0[.]0[.]1:([1-9][0-9]{3,4}),server=on,wait=off$' })
    if ($qmp.Count -ne 1) { throw (New-BuildException -Code 'DEADLINE_QEMU_ARGV_INVALID' -Message 'QMP must use one dynamic loopback-only endpoint.') }
    $port = [int]([regex]::Match($qmp[0], ':([0-9]+),').Groups[1].Value)
    $expected = New-DeadlineQemuArguments -QemuExecutable $QemuExecutable -IsoPath $IsoPath -SerialPath $SerialPath -QmpPort $port
    if ((ConvertTo-Json @($Arguments) -Compress) -cne (ConvertTo-Json @($expected) -Compress)) {
        throw (New-BuildException -Code 'DEADLINE_QEMU_ARGV_INVALID' -Message 'QEMU argv differs from the exact BIOS optical no-NIC contract.')
    }
    foreach ($forbidden in @('-drive','-hda','-hdb','-hdc','-hdd','-netdev','-snapshot')) {
        if (@($Arguments) -ccontains $forbidden) { throw (New-BuildException -Code 'DEADLINE_QEMU_ARGV_INVALID' -Message "QEMU argv contains forbidden token '$forbidden'.") }
    }
    return $true
}

function Get-DeadlineSerialFacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not [System.IO.File]::Exists($Path)) { throw (New-BuildException -Code 'DEADLINE_SERIAL_MISSING' -Message 'Deadline serial evidence is absent.') }
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrEmpty($text) -or -not $text.EndsWith("`n", [System.StringComparison]::Ordinal)) {
        throw (New-BuildException -Code 'DEADLINE_SERIAL_INCOMPLETE' -Message 'Deadline serial evidence has an incomplete final line.')
    }
    $lines = $text.Replace("`r`n", "`n").Split("`n")
    $stageNames = [System.Collections.Generic.List[string]]::new()
    $markers = [System.Collections.Generic.List[object]]::new()
    $terminal = $null
    for ($index = 0; $index -lt $lines.Count - 1; $index++) {
        $line = $lines[$index]
        if (-not $line.StartsWith('300K_STAGE=', [System.StringComparison]::Ordinal)) { continue }
        if ($line -cmatch '^300K_STAGE=(ROOTFS_READY|X_READY|UI_READY)$') {
            $stage = $Matches[1]
        }
        elseif ($line -cmatch '^300K_STAGE=TERM_EXEC_OK uid=([1-9][0-9]*) user=chatgpt tty=(/dev/pts/[0-9]+) command=ok file=ok exit=1$') {
            $stage = 'TERM_EXEC_OK'
            $terminal = [pscustomobject]@{ uid=[int]$Matches[1]; user='chatgpt'; tty=$Matches[2]; command='ok'; file='ok'; exit=1 }
        }
        else {
            throw (New-BuildException -Code 'DEADLINE_SERIAL_MARKER_INVALID' -Message 'A deadline stage line has invalid grammar or root terminal facts.')
        }
        if ($stageNames.Contains($stage)) { throw (New-BuildException -Code 'DEADLINE_SERIAL_MARKER_DUPLICATE' -Message "Stage '$stage' was emitted more than once.") }
        $stageNames.Add($stage)
        $markers.Add([pscustomobject]@{ stage=$stage; line=$index + 1 })
    }
    $expected = @('ROOTFS_READY','X_READY','UI_READY','TERM_EXEC_OK')
    if ((ConvertTo-Json @($stageNames) -Compress) -cne (ConvertTo-Json $expected -Compress) -or $null -eq $terminal) {
        throw (New-BuildException -Code 'DEADLINE_SERIAL_MARKER_ORDER' -Message 'Required ROOTFS/X/UI/TERM markers are missing, duplicated, or out of order.')
    }
    return [pscustomobject]@{ Markers=@($markers); Terminal=$terminal }
}

function Read-DeadlinePpmToken {
    param([Parameter(Mandatory)] [byte[]] $Bytes, [Parameter(Mandatory)] [ref] $Index)
    while ($Index.Value -lt $Bytes.Length) {
        $value = $Bytes[$Index.Value]
        if ($value -eq 35) {
            while ($Index.Value -lt $Bytes.Length -and $Bytes[$Index.Value] -ne 10) { $Index.Value++ }
            continue
        }
        if ($value -in @(9,10,13,32)) { $Index.Value++; continue }
        break
    }
    $start = $Index.Value
    while ($Index.Value -lt $Bytes.Length -and $Bytes[$Index.Value] -notin @(9,10,13,32,35)) { $Index.Value++ }
    if ($Index.Value -le $start) { throw (New-BuildException -Code 'DEADLINE_SCREENSHOT_INVALID' -Message 'PPM header token is missing.') }
    return [System.Text.Encoding]::ASCII.GetString($Bytes, $start, $Index.Value - $start)
}

function Read-DeadlinePpm {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not [System.IO.File]::Exists($Path)) { throw (New-BuildException -Code 'DEADLINE_SCREENSHOT_MISSING' -Message 'Deadline screenshot is absent.') }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $index = 0
    $magic = Read-DeadlinePpmToken -Bytes $bytes -Index ([ref]$index)
    $widthText = Read-DeadlinePpmToken -Bytes $bytes -Index ([ref]$index)
    $heightText = Read-DeadlinePpmToken -Bytes $bytes -Index ([ref]$index)
    $maxText = Read-DeadlinePpmToken -Bytes $bytes -Index ([ref]$index)
    if ($magic -cne 'P6' -or $widthText -cnotmatch '^[1-9][0-9]*$' -or $heightText -cnotmatch '^[1-9][0-9]*$' -or $maxText -cne '255') {
        throw (New-BuildException -Code 'DEADLINE_SCREENSHOT_INVALID' -Message 'Screenshot is not a positive binary P6/255 PPM.')
    }
    if ($index -ge $bytes.Length -or $bytes[$index] -notin @(9,10,13,32)) { throw (New-BuildException -Code 'DEADLINE_SCREENSHOT_INVALID' -Message 'PPM header is not separated from pixels.') }
    if ($bytes[$index] -eq 13 -and $index + 1 -lt $bytes.Length -and $bytes[$index + 1] -eq 10) { $index += 2 } else { $index++ }
    $width = [int]$widthText
    $height = [int]$heightText
    $expectedPixelBytes = [long]$width * [long]$height * 3L
    if ($bytes.Length - $index -ne $expectedPixelBytes) { throw (New-BuildException -Code 'DEADLINE_SCREENSHOT_INVALID' -Message 'PPM pixel payload length differs from its dimensions.') }
    $colors = [System.Collections.Generic.HashSet[int]]::new()
    for ($offset = $index; $offset -lt $bytes.Length; $offset += 3) {
        $color = ([int]$bytes[$offset] -shl 16) -bor ([int]$bytes[$offset + 1] -shl 8) -bor [int]$bytes[$offset + 2]
        [void]$colors.Add($color)
        if ($colors.Count -ge 4096) { break }
    }
    return [pscustomobject]@{ width=$width; height=$height; max_value=255; distinct_pixels=$colors.Count; nonblank=($colors.Count -ge 2); bytes=[long]$bytes.Length; sha256=Get-LowerFileSha256 -Path $Path }
}

function Get-DeadlineDeferredClaims {
    return [ordered]@{
        runtime_uefi = 'not-executed'
        raw_usb = 'not-executed'
        broad_hardware_support = 'not-executed'
        docker_parity = 'not-executed'
        second_build_reproducibility = 'not-executed'
        size_optimization = 'not-executed'
        exhaustive_security = 'not-executed'
        general_release_certification = 'not-executed'
    }
}

function Assert-DeadlineDeferredClaims {
    param([Parameter(Mandatory)] $Deferred, [Parameter(Mandatory)] [string] $Code)
    $expected = Get-DeadlineDeferredClaims
    Assert-ClosedObjectKeys -Object $Deferred -ExpectedKeys @($expected.Keys) -Code $Code -Label 'Deadline deferred claims'
    foreach ($key in $expected.Keys) {
        if ([string](Get-ObjectProperty $Deferred $key) -cne 'not-executed') { throw (New-BuildException -Code $Code -Message "Deferred claim '$key' was overstated.") }
    }
}

function Test-DeadlineStagingBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StagingDirectory,
        [Parameter(Mandatory)] [string] $ExpectedBuildRequestSha256,
        [Parameter(Mandatory)] $Inputs,
        [Parameter(Mandatory)] $BuildRequest
    )
    $root = [System.IO.Path]::GetFullPath($StagingDirectory)
    if (-not [System.IO.Directory]::Exists($root)) { throw (New-BuildException -Code 'DEADLINE_STAGING_MISSING' -Message 'Deadline backend staging is absent.') }
    Assert-NoReparseAncestors -Path $root
    $entries = @(Get-ChildItem -LiteralPath $root -Force)
    if (@($entries | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) { throw (New-BuildException -Code 'DEADLINE_STAGING_SET_INVALID' -Message 'Deadline staging contains a directory or link.') }
    $isoEntries = @($entries | Where-Object { $_.Name -cmatch '^300k-deadline-x86_64-[0-9a-f]{12}[.]iso$' })
    if ($isoEntries.Count -ne 1) { throw (New-BuildException -Code 'DEADLINE_ISO_MISSING' -Message 'Deadline staging must contain one hash-qualified ISO.') }
    $isoName = $isoEntries[0].Name
    $requiredNames = @(
        'build-request.json','resolved-build-lock.json','builder-packages.lock','apk-files.sha256',$isoName,
        'boot-layout.txt','deadline-inspection.json','SHA256SUMS','qemu-image-info.json','environment-report.json',
        'serial-diagnostic.log','repository-evidence.json','resource-inventory.json'
    )
    $actualNames = @($entries.Name | Sort-Object -CaseSensitive)
    if ((ConvertTo-Json $actualNames -Compress) -cne (ConvertTo-Json @($requiredNames | Sort-Object -CaseSensitive) -Compress)) { throw (New-BuildException -Code 'DEADLINE_STAGING_SET_INVALID' -Message 'Deadline staging file set is not closed.') }
    $items = [ordered]@{}
    foreach ($name in $requiredNames) { $items[$name] = Get-ClosedRegularArtifact -BaseDirectory $root -Name $name }
    foreach ($name in @('boot-layout.txt','serial-diagnostic.log','builder-packages.lock','apk-files.sha256','SHA256SUMS')) { Assert-StagingTextSecretFree -Path $items[$name].FullName -Name $name }

    $requestPath = $items['build-request.json'].FullName
    if ((Get-LowerFileSha256 $requestPath) -cne $ExpectedBuildRequestSha256 -or [System.IO.File]::ReadAllText($requestPath) -cne (ConvertTo-CanonicalJsonText $BuildRequest) -or $BuildRequest.target.name -cne 'DeadlineMvp' -or $BuildRequest.target.profile -cne '300k_deadline') { throw (New-BuildException -Code 'DEADLINE_REQUEST_INVALID' -Message 'Staged deadline request differs from the immutable host request.') }
    $lock = Read-ClosedJsonArtifact -Path $items['resolved-build-lock.json'].FullName -Code 'DEADLINE_LOCK_INVALID'
    Assert-ClosedObjectKeys -Object $lock -ExpectedKeys @('schema','schema_version','build_request_sha256','repository_object_id','repository_indexes','aports','trusted_keys','trust_policy','builder_packages_record','apk_files_record','inspection_commands','inspection_toolchain_sha256','offline_install','artifacts') -Code 'DEADLINE_LOCK_INVALID' -Label 'Deadline ResolvedBuildLock'
    [void](Test-ResolvedBuildLock -Lock $lock -ExpectedBuildRequestSha256 $ExpectedBuildRequestSha256)
    if (-not [bool]$lock.trust_policy.mkimage_hostkeys -or -not [bool]$lock.trust_policy.closed_keyring_verified -or [bool]$lock.trust_policy.signature_bypass -or (ConvertTo-Json @($lock.offline_install.repositories) -Compress) -cne '["file:///repo"]' -or -not [bool]$lock.offline_install.apk_no_network -or -not [bool]$lock.offline_install.network_disabled -or -not [bool]$lock.offline_install.complete_manifest_verified) { throw (New-BuildException -Code 'DEADLINE_LOCK_INVALID' -Message 'Deadline lock weakened repository, keyring, or offline policy.') }
    [void](Test-ResolvedTrustedKeys -TrustedKeys @($lock.trusted_keys) -RepositoryKeys $Inputs.alpine.repository_keys -SigningPublicSha256 $BuildRequest.signing.public_key_sha256)
    foreach ($recordName in @('builder_packages_record','apk_files_record')) { [void](Test-GeneratedFileRecord -Record (Get-ObjectProperty $lock $recordName) -BaseDirectory $root -ExpectedProducer 'run-build.sh:prepare-repository') }

    $iso = $items[$isoName]
    $isoHash = Get-LowerFileSha256 $iso.FullName
    if ($isoName -cne "300k-deadline-x86_64-$($isoHash.Substring(0,12)).iso") { throw (New-BuildException -Code 'DEADLINE_ISO_REFERENCE_MISMATCH' -Message 'Deadline ISO basename differs from its bytes.') }
    $inspection = Read-ClosedJsonArtifact -Path $items['deadline-inspection.json'].FullName -Code 'DEADLINE_INSPECTION_INVALID'
    Assert-ClosedObjectKeys -Object $inspection -ExpectedKeys @('schema','schema_version','scope','iso_sha256','iso_bytes','required_paths','bios','uefi','recursive_content_audit','runtime_uefi_boot','result') -Code 'DEADLINE_INSPECTION_INVALID' -Label 'DeadlineIsoInspection'
    Assert-ClosedObjectKeys -Object $inspection.bios -ExpectedKeys @('catalog','loader','bootable') -Code 'DEADLINE_INSPECTION_INVALID' -Label 'DeadlineIsoInspection.bios'
    Assert-ClosedObjectKeys -Object $inspection.uefi -ExpectedKeys @('image','loader','structural_bootable') -Code 'DEADLINE_INSPECTION_INVALID' -Label 'DeadlineIsoInspection.uefi'
    $paths = @('/boot/vmlinuz-virt','/boot/initramfs-virt','/300k.apkovl.tar.gz','/apks/x86_64/APKINDEX.tar.gz','/boot/syslinux/isolinux.bin','/efi/boot/bootx64.efi')
    if ($inspection.schema -cne 'DeadlineIsoInspection' -or [int]$inspection.schema_version -ne 1 -or $inspection.scope -cne 'deadline-fast-structural' -or $inspection.result -cne 'pass' -or $inspection.iso_sha256 -cne $isoHash -or [long]$inspection.iso_bytes -ne [long]$iso.Length -or (ConvertTo-Json @($inspection.required_paths) -Compress) -cne (ConvertTo-Json $paths -Compress) -or $inspection.bios.catalog -cne '/boot/syslinux/boot.cat' -or $inspection.bios.loader -cne '/boot/syslinux/isolinux.bin' -or -not [bool]$inspection.bios.bootable -or $inspection.uefi.image -cne '/boot/grub/efi.img' -or $inspection.uefi.loader -cne '/efi/boot/bootx64.efi' -or -not [bool]$inspection.uefi.structural_bootable -or $inspection.recursive_content_audit -cne 'not-executed' -or $inspection.runtime_uefi_boot -cne 'not-executed') { throw (New-BuildException -Code 'DEADLINE_INSPECTION_INVALID' -Message 'Deadline structural inspection is malformed or overstated.') }
    if ([System.IO.File]::ReadAllText($items['SHA256SUMS'].FullName).Replace("`r`n","`n") -cne "$isoHash  $isoName`n") { throw (New-BuildException -Code 'DEADLINE_ISO_REFERENCE_MISMATCH' -Message 'Deadline SHA256SUMS differs from ISO bytes.') }
    $artifactMap = [ordered]@{ deadline_mvp_iso=$isoName; deadline_fast_inspection='deadline-inspection.json'; iso_checksums='SHA256SUMS' }
    if (@($lock.artifacts).Count -ne 3) { throw (New-BuildException -Code 'DEADLINE_LOCK_INVALID' -Message 'Deadline artifact role set is not closed.') }
    foreach ($record in @($lock.artifacts)) {
        Assert-ClosedObjectKeys -Object $record -ExpectedKeys @('role','file','sha256','bytes') -Code 'DEADLINE_LOCK_INVALID' -Label 'Deadline artifact record'
        if (-not $artifactMap.Contains([string]$record.role) -or $artifactMap[[string]$record.role] -cne [string]$record.file) { throw (New-BuildException -Code 'DEADLINE_LOCK_INVALID' -Message 'Deadline artifact role is unexpected.') }
        $recordItem = $items[[string]$record.file]
        if ($record.sha256 -cne (Get-LowerFileSha256 $recordItem.FullName) -or [long]$record.bytes -ne [long]$recordItem.Length) { throw (New-BuildException -Code 'DEADLINE_LOCK_INVALID' -Message 'Deadline artifact record differs from staged bytes.') }
    }
    $inventory = Read-ClosedJsonArtifact -Path $items['resource-inventory.json'].FullName -Code 'DEADLINE_RESOURCE_INVALID'
    if (-not [bool]$inventory.cleanup_complete -or @($inventory.resources.PSObject.Properties | Where-Object { [bool]$_.Value }).Count -ne 0) { throw (New-BuildException -Code 'DEADLINE_RESOURCE_INVALID' -Message 'Builder QEMU resources are not fully drained.') }
    $repoEvidence = Read-ClosedJsonArtifact -Path $items['repository-evidence.json'].FullName -Code 'DEADLINE_REPOSITORY_INVALID'
    if ($repoEvidence.build_request_sha256 -cne $ExpectedBuildRequestSha256 -or $repoEvidence.repository_object_id -cne $lock.repository_object_id -or [long]$repoEvidence.apk_count -le 0 -or -not [bool]$repoEvidence.official_indexes_verified -or -not [bool]$repoEvidence.official_signatures_verified -or -not [bool]$repoEvidence.content_addressed_snapshot_verified) { throw (New-BuildException -Code 'DEADLINE_REPOSITORY_INVALID' -Message 'Deadline repository evidence is invalid.') }
    $qemuInfo = Read-ClosedJsonArtifact -Path $items['qemu-image-info.json'].FullName -Code 'DEADLINE_QEMU_INFO_INVALID'
    if ($qemuInfo.format -cne 'raw' -or [long]$qemuInfo.actual_size -ne [long]$iso.Length) { throw (New-BuildException -Code 'DEADLINE_QEMU_INFO_INVALID' -Message 'QEMU image measurement differs from the deadline ISO.') }
    $environment = Read-ClosedJsonArtifact -Path $items['environment-report.json'].FullName -Code 'DEADLINE_ENVIRONMENT_INVALID'
    if ($environment.backend -cne 'qemu' -or $environment.backend_status -cne 'executed' -or -not [bool]$environment.cleanup_complete -or $environment.source_commit -cne $BuildRequest.source.git_commit) { throw (New-BuildException -Code 'DEADLINE_ENVIRONMENT_INVALID' -Message 'Deadline builder environment report is invalid.') }
    return [pscustomobject]@{ IsoFile=$isoName; IsoSha256=$isoHash; IsoBytes=[long]$iso.Length; BuildRequestSha256=$ExpectedBuildRequestSha256; SourceCommit=$BuildRequest.source.git_commit; Files=@($requiredNames) }
}

function Test-DeadlineCandidateDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $CandidateManifestPath)
    $manifestItem = Get-Item -LiteralPath $CandidateManifestPath -Force -ErrorAction Stop
    if ($manifestItem.PSIsContainer -or ($manifestItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_MANIFEST_INVALID' -Message 'Candidate manifest is not one regular file.') }
    $directory = $manifestItem.Directory.FullName
    Assert-NoReparseAncestors $directory
    $manifest = Read-ClosedJsonArtifact -Path $manifestItem.FullName -Code 'DEADLINE_CANDIDATE_MANIFEST_INVALID'
    Assert-ClosedObjectKeys $manifest @('schema','schema_version','build_id','build_request_sha256','source_commit','iso','inspection','deferred','files') 'DEADLINE_CANDIDATE_MANIFEST_INVALID' 'DeadlineCandidateManifest'
    Assert-ClosedObjectKeys $manifest.iso @('file','sha256','bytes') 'DEADLINE_CANDIDATE_MANIFEST_INVALID' 'DeadlineCandidateManifest.iso'
    Assert-ClosedObjectKeys $manifest.inspection @('file','scope') 'DEADLINE_CANDIDATE_MANIFEST_INVALID' 'DeadlineCandidateManifest.inspection'
    Assert-DeadlineDeferredClaims $manifest.deferred 'DEADLINE_CANDIDATE_MANIFEST_INVALID'
    if ($manifest.schema -cne 'DeadlineCandidateManifest' -or [int]$manifest.schema_version -ne 1 -or $manifest.build_id -cnotmatch '^deadline-[0-9a-f]{12}$' -or $manifest.build_request_sha256 -cnotmatch '^[0-9a-f]{64}$' -or $manifest.source_commit -cnotmatch '^[0-9a-f]{40}$' -or $manifest.inspection.file -cne 'deadline-inspection.json' -or $manifest.inspection.scope -cne 'deadline-fast-structural') { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_MANIFEST_INVALID' -Message 'Candidate manifest identity is invalid.') }
    $recordNames = [System.Collections.Generic.List[string]]::new()
    foreach ($record in @($manifest.files)) {
        Assert-ClosedObjectKeys $record @('file','sha256','bytes') 'DEADLINE_CANDIDATE_MANIFEST_INVALID' 'DeadlineCandidateManifest.files record'
        $name = Assert-ClosedRelativeArtifactName ([string]$record.file)
        if ($recordNames.Contains($name)) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_MANIFEST_INVALID' -Message 'Candidate manifest duplicates a file.') }
        $recordNames.Add($name)
        $item = Get-ClosedRegularArtifact $directory $name
        if ($record.sha256 -cne (Get-LowerFileSha256 $item.FullName) -or [long]$record.bytes -ne [long]$item.Length) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_MANIFEST_INVALID' -Message "Candidate file '$name' differs from its manifest.") }
    }
    $actual = @(Get-ChildItem -LiteralPath $directory -Force | ForEach-Object { if ($_.PSIsContainer -or ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_MANIFEST_INVALID' -Message 'Candidate contains a directory or link.') }; $_.Name } | Sort-Object -CaseSensitive)
    $expected = @(@($recordNames) + $manifestItem.Name | Sort-Object -CaseSensitive)
    if ((ConvertTo-Json $actual -Compress) -cne (ConvertTo-Json $expected -Compress)) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_MANIFEST_INVALID' -Message 'Candidate file set is not closed.') }
    $iso = Get-ClosedRegularArtifact $directory ([string]$manifest.iso.file)
    if ($manifest.iso.sha256 -cne (Get-LowerFileSha256 $iso.FullName) -or [long]$manifest.iso.bytes -ne [long]$iso.Length) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_MANIFEST_INVALID' -Message 'Candidate ISO identity differs from its manifest.') }
    $inspection = Read-ClosedJsonArtifact (Join-Path $directory $manifest.inspection.file) 'DEADLINE_CANDIDATE_MANIFEST_INVALID'
    if ($inspection.scope -cne 'deadline-fast-structural' -or $inspection.result -cne 'pass') { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_MANIFEST_INVALID' -Message 'Candidate lacks passing fast inspection.') }
    return [pscustomobject]@{ Manifest=$manifest; ManifestPath=$manifestItem.FullName; Directory=$directory; BuildId=$manifest.build_id; IsoFile=$manifest.iso.file; IsoPath=$iso.FullName; IsoSha256=$manifest.iso.sha256; IsoBytes=[long]$manifest.iso.bytes; SourceCommit=$manifest.source_commit }
}

function Stage-DeadlineCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StagingDirectory,
        [Parameter(Mandatory)] [string] $DistRoot,
        [Parameter(Mandatory)] [string] $BuildId,
        [Parameter(Mandatory)] $ValidatedBundle
    )
    if ($BuildId -cnotmatch '^deadline-[0-9a-f]{12}$') { throw (New-BuildException -Code 'DEADLINE_BUILD_ID_INVALID' -Message 'Deadline build ID is unsafe.') }
    $dist = [System.IO.Path]::GetFullPath($DistRoot)
    [System.IO.Directory]::CreateDirectory($dist) | Out-Null
    Assert-NoReparseAncestors $dist
    $latest = Join-Path $dist 'LATEST.json'
    $priorLatest = if ([System.IO.File]::Exists($latest)) { [System.IO.File]::ReadAllBytes($latest) } else { $null }
    $priorPublished = @(Get-ChildItem -LiteralPath $dist -Force | Where-Object { $_.Name -ne '.deadline-candidates' } | ForEach-Object Name | Sort-Object -CaseSensitive)
    $candidateRoot = Join-Path $dist '.deadline-candidates'
    [System.IO.Directory]::CreateDirectory($candidateRoot) | Out-Null
    $partial = Join-Path $candidateRoot ('.partial-' + $BuildId + '-' + [Guid]::NewGuid().ToString('N'))
    $final = Join-Path $candidateRoot $BuildId
    if ([System.IO.Directory]::Exists($final) -or [System.IO.File]::Exists($final)) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_EXISTS' -Message 'This deadline candidate already exists.') }
    try {
        [System.IO.Directory]::CreateDirectory($partial) | Out-Null
        foreach ($name in @($ValidatedBundle.Files)) {
            $source = (Get-ClosedRegularArtifact $StagingDirectory $name).FullName
            $destination = Join-Path $partial $name
            [System.IO.File]::Copy($source, $destination, $false)
            if ((Get-LowerFileSha256 $source) -cne (Get-LowerFileSha256 $destination)) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_COPY_MISMATCH' -Message "Candidate copy '$name' changed bytes.") }
        }
        $records = @($ValidatedBundle.Files | Sort-Object -CaseSensitive | ForEach-Object { $item=Get-ClosedRegularArtifact $partial $_; [ordered]@{ file=$_; sha256=Get-LowerFileSha256 $item.FullName; bytes=[long]$item.Length } })
        $manifestPath = Join-Path $partial 'deadline-candidate.json'
        Write-CanonicalJson ([ordered]@{
            schema='DeadlineCandidateManifest'; schema_version=1; build_id=$BuildId; build_request_sha256=$ValidatedBundle.BuildRequestSha256; source_commit=$ValidatedBundle.SourceCommit
            iso=[ordered]@{ file=$ValidatedBundle.IsoFile; sha256=$ValidatedBundle.IsoSha256; bytes=[long]$ValidatedBundle.IsoBytes }
            inspection=[ordered]@{ file='deadline-inspection.json'; scope='deadline-fast-structural' }; deferred=Get-DeadlineDeferredClaims; files=$records
        }) $manifestPath
        [void](Test-DeadlineCandidateDirectory $manifestPath)
        [System.IO.Directory]::Move($partial, $final)
        $finalManifest = Join-Path $final 'deadline-candidate.json'
        [void](Test-DeadlineCandidateDirectory $finalManifest)
        $afterPublished = @(Get-ChildItem -LiteralPath $dist -Force | Where-Object { $_.Name -ne '.deadline-candidates' } | ForEach-Object Name | Sort-Object -CaseSensitive)
        if ((ConvertTo-Json $priorPublished -Compress) -cne (ConvertTo-Json $afterPublished -Compress)) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_PUBLICATION_LEAK' -Message 'Candidate staging changed the published namespace.') }
        if ($null -eq $priorLatest) { if ([System.IO.File]::Exists($latest)) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_POINTER_CHANGED' -Message 'Candidate staging created LATEST.') } }
        elseif (-not [System.IO.File]::Exists($latest) -or [Convert]::ToHexString([System.IO.File]::ReadAllBytes($latest)) -cne [Convert]::ToHexString($priorLatest)) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_POINTER_CHANGED' -Message 'Candidate staging changed LATEST bytes.') }
        return [pscustomobject]@{ status='candidate-staged'; BuildId=$BuildId; Directory=$final; Manifest=$finalManifest; IsoFile=$ValidatedBundle.IsoFile; IsoSha256=$ValidatedBundle.IsoSha256; IsoBytes=[long]$ValidatedBundle.IsoBytes }
    }
    catch {
        if ([System.IO.Directory]::Exists($partial)) { [System.IO.Directory]::Delete($partial, $true) }
        if ([System.IO.Directory]::Exists($final)) { [System.IO.Directory]::Delete($final, $true) }
        throw
    }
}

function Test-DeadlineSmokeEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EvidencePath, [Parameter(Mandatory)] [string] $CandidateManifestPath)
    $candidate = Test-DeadlineCandidateDirectory $CandidateManifestPath
    $evidenceItem = Get-Item -LiteralPath $EvidencePath -Force -ErrorAction Stop
    $evidenceRoot = $evidenceItem.Directory.FullName
    $evidence = Read-ClosedJsonArtifact $evidenceItem.FullName 'DEADLINE_SMOKE_EVIDENCE_INVALID'
    Assert-ClosedObjectKeys $evidence @('schema','schema_version','result','build_id','attempt_id','iso','qemu','markers','terminal','serial','screenshot','deferred') 'DEADLINE_SMOKE_EVIDENCE_INVALID' 'DeadlineSmokeEvidence'
    Assert-ClosedObjectKeys $evidence.iso @('file','sha256','bytes') 'DEADLINE_SMOKE_EVIDENCE_INVALID' 'DeadlineSmokeEvidence.iso'
    Assert-ClosedObjectKeys $evidence.qemu @('executable','argv','machine','firmware','media','nic','memory_mib') 'DEADLINE_SMOKE_EVIDENCE_INVALID' 'DeadlineSmokeEvidence.qemu'
    Assert-ClosedObjectKeys $evidence.terminal @('uid','user','tty','command','file','exit') 'DEADLINE_SMOKE_EVIDENCE_INVALID' 'DeadlineSmokeEvidence.terminal'
    Assert-ClosedObjectKeys $evidence.serial @('file','sha256','bytes') 'DEADLINE_SMOKE_EVIDENCE_INVALID' 'DeadlineSmokeEvidence.serial'
    Assert-ClosedObjectKeys $evidence.screenshot @('file','sha256','bytes','width','height','max_value','distinct_pixels','nonblank') 'DEADLINE_SMOKE_EVIDENCE_INVALID' 'DeadlineSmokeEvidence.screenshot'
    Assert-DeadlineDeferredClaims $evidence.deferred 'DEADLINE_SMOKE_EVIDENCE_INVALID'
    if ($evidence.schema -cne 'DeadlineSmokeEvidence' -or [int]$evidence.schema_version -ne 1 -or $evidence.result -cne 'pass' -or $evidence.build_id -cne $candidate.BuildId -or $evidence.attempt_id -cnotmatch '^[0-9a-f]{32}$' -or $evidence.iso.file -cne $candidate.IsoFile -or $evidence.iso.sha256 -cne $candidate.IsoSha256 -or [long]$evidence.iso.bytes -ne $candidate.IsoBytes) { throw (New-BuildException -Code 'DEADLINE_SMOKE_EVIDENCE_INVALID' -Message 'Smoke evidence identity differs from the candidate.') }
    if ($evidence.qemu.executable -cne 'D:\VM\qemu\qemu-system-x86_64.exe' -or $evidence.qemu.machine -cne 'pc' -or $evidence.qemu.firmware -cne 'bios' -or $evidence.qemu.media -cne 'optical-read-only' -or $evidence.qemu.nic -cne 'none' -or [int]$evidence.qemu.memory_mib -ne 1024) { throw (New-BuildException -Code 'DEADLINE_SMOKE_EVIDENCE_INVALID' -Message 'Smoke evidence overstates or changes the executed QEMU lane.') }
    $serialName = Assert-ClosedRelativeArtifactName ([string]$evidence.serial.file)
    $screenName = Assert-ClosedRelativeArtifactName ([string]$evidence.screenshot.file)
    $serial = Get-ClosedRegularArtifact $evidenceRoot $serialName
    $screen = Get-ClosedRegularArtifact $evidenceRoot $screenName
    if ($evidence.serial.sha256 -cne (Get-LowerFileSha256 $serial.FullName) -or [long]$evidence.serial.bytes -ne [long]$serial.Length -or $evidence.screenshot.sha256 -cne (Get-LowerFileSha256 $screen.FullName) -or [long]$evidence.screenshot.bytes -ne [long]$screen.Length) { throw (New-BuildException -Code 'DEADLINE_SMOKE_EVIDENCE_INVALID' -Message 'Serial or screenshot evidence bytes changed.') }
    $facts = Get-DeadlineSerialFacts $serial.FullName
    $expectedStages = @('ROOTFS_READY','X_READY','UI_READY','TERM_EXEC_OK')
    if (@($evidence.markers).Count -ne 4) { throw (New-BuildException -Code 'DEADLINE_SMOKE_EVIDENCE_INVALID' -Message 'Evidence marker set is not closed.') }
    for ($index=0;$index -lt 4;$index++) {
        Assert-ClosedObjectKeys $evidence.markers[$index] @('stage','line') 'DEADLINE_SMOKE_EVIDENCE_INVALID' 'DeadlineSmokeEvidence.marker'
        if ($evidence.markers[$index].stage -cne $expectedStages[$index] -or [int]$evidence.markers[$index].line -ne [int]$facts.Markers[$index].line) { throw (New-BuildException -Code 'DEADLINE_SMOKE_EVIDENCE_INVALID' -Message 'Evidence marker order or line number differs from serial bytes.') }
    }
    if ([int]$evidence.terminal.uid -le 0 -or $evidence.terminal.user -cne 'chatgpt' -or $evidence.terminal.tty -cnotmatch '^/dev/pts/[0-9]+$' -or $evidence.terminal.command -cne 'ok' -or $evidence.terminal.file -cne 'ok' -or [int]$evidence.terminal.exit -ne 1 -or [int]$evidence.terminal.uid -ne [int]$facts.Terminal.uid -or $evidence.terminal.tty -cne $facts.Terminal.tty) { throw (New-BuildException -Code 'DEADLINE_SMOKE_EVIDENCE_INVALID' -Message 'PTY proof fields are missing, root, fake, or inconsistent.') }
    $ppm = Read-DeadlinePpm $screen.FullName
    if (-not [bool]$evidence.screenshot.nonblank -or -not $ppm.nonblank -or [int]$evidence.screenshot.width -ne $ppm.width -or [int]$evidence.screenshot.height -ne $ppm.height -or [int]$evidence.screenshot.max_value -ne 255 -or [int]$evidence.screenshot.distinct_pixels -ne $ppm.distinct_pixels) { throw (New-BuildException -Code 'DEADLINE_SMOKE_EVIDENCE_INVALID' -Message 'Screenshot is blank or its measured geometry/variance differs.') }
    $candidateParent = [System.IO.Directory]::GetParent($candidate.Directory)
    if ($null -eq $candidateParent -or [System.IO.Path]::GetFileName($candidate.Directory) -cne $candidate.BuildId) {
        throw (New-BuildException -Code 'DEADLINE_CANDIDATE_LOCATION_INVALID' -Message 'Candidate directory does not match its build identity.')
    }
    $distRoot = if ($candidateParent.Name -ceq '.deadline-candidates') { $candidateParent.Parent.FullName } else { $candidateParent.FullName }
    $executedIsoPath = [System.IO.Path]::GetFullPath((Join-Path $distRoot ('.deadline-candidates\' + $candidate.BuildId + '\' + $candidate.IsoFile)))
    [void](Test-DeadlineQemuArguments -QemuExecutable $evidence.qemu.executable -Arguments @($evidence.qemu.argv) -IsoPath $executedIsoPath -SerialPath $serial.FullName)
    return [pscustomobject]@{ Candidate=$candidate; Evidence=$evidence; EvidencePath=$evidenceItem.FullName; EvidenceSha256=Get-LowerFileSha256 $evidenceItem.FullName; SerialPath=$serial.FullName; ScreenshotPath=$screen.FullName; Screenshot=$ppm; ExecutedIsoPath=$executedIsoPath }
}

function Complete-DeadlineCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $CandidateManifestPath, [Parameter(Mandatory)] [string] $EvidencePath, [Parameter(Mandatory)] [string] $DistRoot, [string] $FailureStage)
    $validated = Test-DeadlineSmokeEvidence $EvidencePath $CandidateManifestPath
    $candidate = $validated.Candidate
    $dist = [System.IO.Path]::GetFullPath($DistRoot)
    $expectedCandidateRoot = [System.IO.Path]::GetFullPath((Join-Path $dist '.deadline-candidates')).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if (-not $candidate.Directory.StartsWith($expectedCandidateRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw (New-BuildException -Code 'DEADLINE_CANDIDATE_LOCATION_INVALID' -Message 'Candidate is outside the quarantine namespace.') }
    $final = Join-Path $dist $candidate.BuildId
    $latest = Join-Path $dist 'LATEST.json'
    if ([System.IO.Directory]::Exists($final) -or [System.IO.File]::Exists($final)) { throw (New-BuildException -Code 'DEADLINE_ALREADY_PUBLISHED' -Message 'Deadline build already exists in the published namespace.') }
    $priorLatest = if ([System.IO.File]::Exists($latest)) { [System.IO.File]::ReadAllBytes($latest) } else { $null }
    $latestPartial = Join-Path $dist ('LATEST.json.' + [Guid]::NewGuid().ToString('N') + '.partial')
    $renamed = $false
    $pointerChanged = $false
    try {
        [System.IO.Directory]::Move($candidate.Directory, $final)
        $renamed = $true
        Invoke-PublicationFailureStage $FailureStage 'after-final-rename'
        $relativeEvidence = [System.IO.Path]::GetRelativePath($dist, $validated.EvidencePath).Replace('\','/')
        if ($relativeEvidence.StartsWith('../', [System.StringComparison]::Ordinal) -or $relativeEvidence -ceq '..') { throw (New-BuildException -Code 'DEADLINE_EVIDENCE_LOCATION_INVALID' -Message 'Smoke evidence must remain under dist.') }
        Write-CanonicalJson ([ordered]@{
            schema_version=1; build_id=$candidate.BuildId; directory=$candidate.BuildId; iso_file=$candidate.IsoFile; iso_sha256=$candidate.IsoSha256; iso_bytes=[long]$candidate.IsoBytes
            verification='deadline-bios-optical'; smoke_evidence=$relativeEvidence; smoke_evidence_sha256=$validated.EvidenceSha256; screenshot_sha256=$validated.Evidence.screenshot.sha256; serial_sha256=$validated.Evidence.serial.sha256; source_commit=$candidate.SourceCommit
        }) $latestPartial
        Invoke-PublicationFailureStage $FailureStage 'before-pointer-replace'
        if ([System.IO.File]::Exists($latest)) {
            $backup = Join-Path $dist ('LATEST.json.backup-' + [Guid]::NewGuid().ToString('N'))
            [System.IO.File]::Replace($latestPartial, $latest, $backup, $true)
            $pointerChanged = $true
            [System.IO.File]::Delete($backup)
        }
        else {
            [System.IO.File]::Move($latestPartial, $latest)
            $pointerChanged = $true
        }
        Invoke-PublicationFailureStage $FailureStage 'after-pointer-replace'
        [void](Test-DeadlineCandidateDirectory (Join-Path $final 'deadline-candidate.json'))
        return [pscustomobject]@{ status='promoted'; BuildId=$candidate.BuildId; Directory=$final; IsoFile=$candidate.IsoFile; IsoSha256=$candidate.IsoSha256; IsoBytes=[long]$candidate.IsoBytes; Evidence=$validated.EvidencePath; Screenshot=$validated.ScreenshotPath; Serial=$validated.SerialPath }
    }
    catch {
        if ($pointerChanged) {
            if ($null -eq $priorLatest) { [System.IO.File]::Delete($latest) }
            else { $rollback=Join-Path $dist ('LATEST.json.rollback-' + [Guid]::NewGuid().ToString('N') + '.partial'); [System.IO.File]::WriteAllBytes($rollback,$priorLatest); [System.IO.File]::Move($rollback,$latest,$true) }
        }
        if ([System.IO.File]::Exists($latestPartial)) { [System.IO.File]::Delete($latestPartial) }
        if ($renamed -and [System.IO.Directory]::Exists($final) -and -not [System.IO.Directory]::Exists($candidate.Directory)) { [System.IO.Directory]::Move($final,$candidate.Directory) }
        throw
    }
}

function Stage-DeadlineBuildArtifacts {
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
    if (-not [bool]$BackendResult.CleanupComplete) { throw (New-BuildException -Code 'QEMU_CLEANUP_INCOMPLETE' -Message 'Builder QEMU cleanup is incomplete, so deadline staging is forbidden.') }
    $isoCandidates = @(Get-ChildItem -LiteralPath $StagingDirectory -Force | Where-Object { -not $_.PSIsContainer -and $_.Name -cmatch '^300k-deadline-x86_64-[0-9a-f]{12}[.]iso$' })
    if ($isoCandidates.Count -ne 1) { throw (New-BuildException -Code 'DEADLINE_ISO_MISSING' -Message 'Backend did not return one deadline ISO.') }
    $iso=$isoCandidates[0]
    $qemuInfoResult=Invoke-CheckedProcess -FilePath $QemuImgPath -ArgumentList @('info','--output=json',$iso.FullName) -TimeoutSeconds 60
    $qemuInfo=$qemuInfoResult.StandardOutput | ConvertFrom-Json -Depth 10
    Write-CanonicalJson ([ordered]@{ format=$qemuInfo.format; virtual_size=[long]$qemuInfo.'virtual-size'; actual_size=[long]$iso.Length }) (Join-Path $StagingDirectory 'qemu-image-info.json')
    Write-CanonicalJson ([ordered]@{
        schema_version=1; backend='qemu'; backend_status='executed'; guest_os='linux'; guest_arch='x86_64'; alpine_release='3.24.1'; qemu_cloud_image_sha512=$BackendResult.CloudImageSha512
        docker_status=$DockerProbe.status; docker_reason=$DockerProbe.reason; serial_host_fingerprint=$BackendResult.SerialFingerprint; live_management_stages=@($BackendResult.ManagementStages); cleanup_complete=[bool]$BackendResult.CleanupComplete; source_commit=$SourceCommit
    }) (Join-Path $StagingDirectory 'environment-report.json')
    $validated=Test-DeadlineStagingBundle $StagingDirectory $BuildRequestHash $Inputs $BuildRequest
    return Stage-DeadlineCandidate $StagingDirectory (Join-Path $script:BuildRepositoryRoot 'dist') $BuildId $validated
}

function Invoke-300kBuild {
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Docker', 'Qemu')] [string] $SelectedBackend,
        [ValidateSet('Bootstrap', 'DeadlineMvp')] [string] $SelectedTarget,
        [Parameter(Mandatory)] [string] $SelectedStateRoot,
        [Parameter(Mandatory)] [string] $SelectedQemuRoot,
        [Nullable[long]] $RequestedSourceDateEpoch,
        [switch] $InitializeKey,
        [switch] $ProbeBuilderReadiness,
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
    if ($ProbeBuilderReadiness -and ($SelectedBackend -cne 'Qemu' -or $SelectedTarget -cne 'DeadlineMvp' -or $InitializeKey -or $OnlyPreflight -or $CleanExactNamespace)) {
        throw (New-BuildException -Code 'QEMU_READINESS_PROBE_CONFLICT' -Message 'The builder readiness probe requires explicit Qemu + DeadlineMvp and cannot initialize keys, preflight, or clean a build namespace.')
    }

    $dockerProbe = if ($SelectedBackend -ceq 'Qemu') {
        [pscustomobject]@{ available = $false; status = 'not-probed-explicit-qemu'; reason = 'explicit-qemu' }
    }
    else { Get-DockerProbe }
    if ($SelectedBackend -ceq 'Docker') {
        if (-not $dockerProbe.available) { throw (New-BuildException -Code 'DOCKER_PREFLIGHT_FAILED' -Message "Explicit Docker backend failed: $($dockerProbe.reason)") }
        throw (New-BuildException -Code 'DOCKER_BACKEND_NOT_IMPLEMENTED' -Message 'Docker is verified but its adapter is intentionally deferred to Plan 01-03.')
    }
    $deadlineSigning = $null
    if ($OnlyPreflight -and $SelectedTarget -ceq 'DeadlineMvp' -and -not $InitializeKey) {
        $deadlineSecretRoot = Join-Path $state 'secrets\apk'
        $deadlineSigningPath = Join-Path $deadlineSecretRoot 'signing-public.json'
        foreach ($requiredSigningFile in @($deadlineSigningPath, (Join-Path $deadlineSecretRoot '300k.rsa'), (Join-Path $deadlineSecretRoot '300k.rsa.pub'))) {
            if (-not [System.IO.File]::Exists($requiredSigningFile)) {
                throw (New-BuildException -Code 'SIGNING_PUBLIC_REQUIRED' -Message 'Run -InitializeSigningKey before an ordinary build.')
            }
            $signingItem = Get-Item -LiteralPath $requiredSigningFile -Force
            if ($signingItem.PSIsContainer -or ($signingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw (New-BuildException -Code 'SIGNING_PUBLIC_INVALID' -Message 'Signing identity inputs must be regular external files.')
            }
        }
        $deadlineSigning = Get-Content -Raw -LiteralPath $deadlineSigningPath | ConvertFrom-Json
        [void](Test-SigningPublicIdentity -SigningPublic $deadlineSigning -BaseDirectory $deadlineSecretRoot)
    }
    if ($OnlyPreflight) {
        return [pscustomobject]@{
            status = 'preflight-passed'; backend = 'qemu'; docker_status = $dockerProbe.status; qemu = 'available'; target = $SelectedTarget
            signing_public_sha256 = if ($null -eq $deadlineSigning) { $null } else { $deadlineSigning.public_key_sha256 }
        }
    }

    Assert-CleanRepository
    [System.IO.Directory]::CreateDirectory($state) | Out-Null
    if ($ProbeBuilderReadiness) {
        $probeCloudImageUri = [uri]$inputs.qemu.cloud_image_url
        $probeBasePath = Join-Path (Join-Path $state 'state\qemu\base') ([System.IO.Path]::GetFileName($probeCloudImageUri.AbsolutePath))
        if (-not [System.IO.File]::Exists($probeBasePath)) {
            throw (New-BuildException -Code 'QEMU_READINESS_BASE_MISSING' -Message 'Builder readiness probe requires the existing pinned base image and will not download it.')
        }
        if ((Get-FileHash -LiteralPath $probeBasePath -Algorithm SHA512).Hash.ToLowerInvariant() -cne $inputs.qemu.cloud_image_sha512) {
            throw (New-BuildException -Code 'QEMU_READINESS_BASE_HASH_MISMATCH' -Message 'Existing builder base image differs from its pinned SHA-512.')
        }
        $probeNonce = [Guid]::NewGuid().ToString('N')
        $probeRoot = Join-Path $state "state\host-runs\$probeNonce"
        $probeExport = Join-Path $probeRoot 'readiness-evidence'
        [System.IO.Directory]::CreateDirectory($probeExport) | Out-Null
        try {
            $probe = Invoke-QemuBackend -Operation readiness-probe -QemuRoot $SelectedQemuRoot -StateRoot $state -RunId $probeNonce `
                -ExportDirectory $probeExport -CloudImageUri $probeCloudImageUri -CloudImageSha512 $inputs.qemu.cloud_image_sha512 `
                -CacheIdentity (Get-LowerFileSha256 -Path $inputsPath) -BootTimeoutSeconds 300 -BuildTimeoutSeconds 60
            if (
                -not [bool]$probe.CleanupComplete -or
                $probe.Operation -cne 'readiness-probe' -or
                $probe.Machine -cne 'pc' -or
                $probe.Accelerator -cne 'tcg,thread=multi' -or
                $probe.ReadinessMarker -cne '300K_SSH_READY' -or
                @($probe.ManagementStages | Where-Object { $_ -ceq 'ssh-readiness-live' }).Count -ne 1 -or
                @($probe.ManagementStages | Where-Object { $_ -ceq 'builder-readiness-live' }).Count -ne 1 -or
                @($probe.ManagementStages | Where-Object { $_ -ceq 'shutdown-complete' }).Count -ne 1
            ) {
                throw (New-BuildException -Code 'QEMU_READINESS_PROBE_INVALID' -Message 'Builder readiness probe did not prove serial trust, strict SSH, shutdown, and cleanup on the stable transport.')
            }
            return [pscustomobject]@{
                status = 'builder-readiness-passed'
                backend = 'qemu'
                machine = $probe.Machine
                accelerator = $probe.Accelerator
                serial_marker = $probe.ReadinessMarker
                serial_host_fingerprint = $probe.SerialFingerprint
                ssh_probe = 'passed'
                cleanup_complete = $probe.CleanupComplete
            }
        }
        finally {
            $expectedHostRuns = [System.IO.Path]::GetFullPath((Join-Path $state 'state\host-runs')).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            $actualProbeRoot = [System.IO.Path]::GetFullPath($probeRoot)
            if ($actualProbeRoot.StartsWith($expectedHostRuns + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and [System.IO.Directory]::Exists($actualProbeRoot)) {
                [System.IO.Directory]::Delete($actualProbeRoot, $true)
            }
        }
    }
    $sourceIdentity = Get-GitSourceIdentity -RequestedEpoch $RequestedSourceDateEpoch
    $runNonce = [Guid]::NewGuid().ToString('N')
    $runRoot = Join-Path $state "state\host-runs\$runNonce"
    [System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
    try {
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
        inspect_iso_sha256 = Get-LowerFileSha256 -Path (Join-Path $script:BuildRepositoryRoot 'scripts/linux/inspect-iso.sh')
        inspect_deadline_iso_sha256 = Get-LowerFileSha256 -Path (Join-Path $script:BuildRepositoryRoot 'scripts/linux/inspect-deadline-iso.sh')
        profile_sha256 = Get-LowerFileSha256 -Path (Join-Path $script:BuildRepositoryRoot 'builder/profiles/mkimg.300k.sh')
        apkovl_sha256 = Get-LowerFileSha256 -Path (Join-Path $script:BuildRepositoryRoot 'builder/apkovl/genapkovl-300k.sh')
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
    $request = New-BuildRequest -Inputs $inputs -Source $source -InputHashes $hashes -SigningPublic $signing -SelectedTarget $SelectedTarget
    $requestPath = Join-Path $runRoot 'build-request.json'
    Write-CanonicalJson -Value $request -Path $requestPath
    $requestHash = Get-LowerFileSha256 -Path $requestPath
    $buildId = if ($SelectedTarget -ceq 'DeadlineMvp') { 'deadline-' + $requestHash.Substring(0,12) } else { 'p01-' + $requestHash.Substring(0,12) }

    if ($CleanExactNamespace) {
        Clear-IncompleteBuildNamespace -DistRoot (Join-Path $script:BuildRepositoryRoot 'dist') -BuildId $buildId
    }
    [System.IO.File]::Copy($requestPath, (Join-Path $backendExport 'build-request.json'), $true)
    $backendResult = Invoke-QemuBackend -Operation build -QemuRoot $SelectedQemuRoot -StateRoot $state -RunId $runNonce `
        -RequestFile $requestPath -SourceArchive $sourceArchive -ExportDirectory $backendExport `
        -CloudImageUri ([uri]$inputs.qemu.cloud_image_url) -CloudImageSha512 $inputs.qemu.cloud_image_sha512 -CacheIdentity $cacheIdentity `
        -BuildTimeoutSeconds 14400 `
        -SigningPrivateFile (Join-Path $secretRoot '300k.rsa') -SigningPublicFile (Join-Path $secretRoot '300k.rsa.pub')
    [System.IO.File]::Copy($requestPath, (Join-Path $backendExport 'build-request.json'), $true)
    if ($SelectedTarget -ceq 'DeadlineMvp') {
        return Stage-DeadlineBuildArtifacts -StagingDirectory $backendExport -BuildId $buildId -BuildRequestHash $requestHash -BackendResult $backendResult -QemuImgPath $qemuImg -SourceCommit $sourceIdentity.git_commit -DockerProbe $dockerProbe -Inputs $inputs -BuildRequest $request
    }
    return Publish-BuildArtifacts -StagingDirectory $backendExport -BuildId $buildId -BuildRequestHash $requestHash -BackendResult $backendResult -QemuImgPath $qemuImg -SourceCommit $sourceIdentity.git_commit -DockerProbe $dockerProbe -Inputs $inputs -BuildRequest $request
    }
    finally {
        $expectedHostRuns = [System.IO.Path]::GetFullPath((Join-Path $state 'state\host-runs')).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $actualRunRoot = [System.IO.Path]::GetFullPath($runRoot)
        if ($actualRunRoot.StartsWith($expectedHostRuns + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and [System.IO.Directory]::Exists($actualRunRoot)) {
            [System.IO.Directory]::Delete($actualRunRoot, $true)
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-300kBuild -SelectedBackend $Backend -SelectedTarget $Target -SelectedStateRoot $StateRoot -SelectedQemuRoot $QemuRoot `
            -RequestedSourceDateEpoch $SourceDateEpoch -InitializeKey:$InitializeSigningKey -ProbeBuilderReadiness:$BuilderReadinessProbe `
            -OnlyPreflight:$PreflightOnly -CleanExactNamespace:$Clean
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
