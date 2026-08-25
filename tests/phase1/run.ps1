[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Docker', 'Qemu', 'Artifact', 'Security', 'All')]
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

if ($Scope -in @('Unit', 'Qemu', 'Artifact', 'Security', 'All')) {
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

Add-TestCase -Name 'BUILD-03 inspection policy pins every decoder and bounded graph limit' -Scopes @('Unit') -Requirements @('BUILD-03') -Body {
    $inputsPath = Join-Path $script:RepositoryRoot 'builder/inputs.json'
    $inputs = Get-Content -Raw -LiteralPath $inputsPath | ConvertFrom-Json -Depth 64
    $formats = @($inputs.inspection_toolchain.PSObject.Properties)

    Assert-Equal -Expected @('gzip', 'xz', 'zstd', 'lz4', 'cpio', 'squashfs', 'iso', 'tar', 'apk') -Actual @($formats.Name) -Message 'The complete nested decoder graph must be closed and ordered.'
    foreach ($format in $formats) {
        Assert-Match -Value ([string] $format.Value.package) -Pattern '^[a-z0-9][a-z0-9+_.-]*=[0-9][a-zA-Z0-9.+_~-]*-r[0-9]+$' -Message "Decoder '$($format.Name)' must name an exact APK package version."
        Assert-Match -Value ([string] $format.Value.command) -Pattern '^/[A-Za-z0-9._+/-]+$' -Message "Decoder '$($format.Name)' must use an absolute command path."
    }

    $limits = $inputs.inspection_policy.limits
    foreach ($name in @('max_depth', 'max_members', 'max_file_bytes', 'max_total_expanded_bytes')) {
        Assert-True -Condition ($null -ne $limits.$name -and [int64] $limits.$name -gt 0) -Message "Inspection limit '$name' must be explicit and positive."
    }
    Assert-True -Condition ([int64] $limits.max_total_expanded_bytes -ge [int64] $limits.max_file_bytes) -Message 'The total expansion budget must cover at least one maximum-size file.'
    Assert-Equal -Expected @('regular') -Actual @($inputs.inspection_policy.materialized_types) -Message 'Only regular files may ever be materialized.'
    Assert-Equal -Expected $false -Actual ([bool] $inputs.inspection_policy.follow_links) -Message 'Inspection must never follow links.'

    $builderPackages = @($inputs.builder_packages)
    foreach ($format in $formats) {
        Assert-True -Condition ($builderPackages -ccontains [string] $format.Value.package) -Message "Decoder package '$($format.Value.package)' is outside the retained builder closure."
    }
}

Add-TestCase -Name 'BUILD-03 hostile fixture matrix preflights before no-follow streaming' -Scopes @('Unit') -Requirements @('BUILD-03') -Body {
    $inspectorPath = Join-Path $script:RepositoryRoot 'scripts/linux/inspect-iso.sh'
    Assert-True -Condition (Test-Path -LiteralPath $inspectorPath -PathType Leaf) -Message 'The Linux ISO inspector is missing.'
    $source = Get-Content -Raw -LiteralPath $inspectorPath

    foreach ($contract in @(
        'preflight_graph',
        'stream_regular_member',
        'assert_root_confined_path',
        'assert_toolchain_identity',
        'run_hostile_fixture_self_test',
        'write_iso_audit'
    )) {
        Assert-Match -Value $source -Pattern ([regex]::Escape($contract)) -Message "Inspector contract '$contract' is absent."
    }
    foreach ($layer in @('iso9660', 'apkovl', 'initramfs', 'cpio', 'squashfs', 'apk', 'tar', 'gzip', 'xz', 'zstd', 'lz4')) {
        Assert-Match -Value $source -Pattern ([regex]::Escape($layer)) -Message "Hostile fixture coverage for '$layer' is absent."
    }
    foreach ($guard in @('max_depth', 'max_members', 'max_file_bytes', 'max_total_expanded_bytes', 'outside_scratch_sentinel', 'compressed_secret_fixture')) {
        Assert-Match -Value $source -Pattern ([regex]::Escape($guard)) -Message "Inspector guard '$guard' is absent."
    }
    Assert-Match -Value $source -Pattern 'preflight_graph[\s\S]{0,4000}stream_regular_member' -Message 'The source must make preflight precede any regular-file streaming.'
    Assert-False -Condition ($source -match '(?m)^\s*(eval\s|source\s|\.\s+\$)') -Message 'The inspector must not evaluate ambient or computed shell source.'
    Assert-False -Condition ($source -match '(?m)\b(mount|losetup)\b') -Message 'The unprivileged inspector must not mount images or allocate loop devices.'
}

Add-TestCase -Name 'BUILD-03 offline build proves decoder identity before inspecting and publishing' -Scopes @('Unit') -Requirements @('BUILD-03') -Body {
    $linuxCore = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/linux/run-build.sh')

    Assert-Match -Value $linuxCore -Pattern 'assert_inspection_toolchain_identity[\s\S]*disable_network[\s\S]*run_inspector_self_test[\s\S]*mkimage' -Message 'Tool identity and hostile fixtures must pass before network-off ISO construction.'
    Assert-Match -Value $linuxCore -Pattern 'mkimage[\s\S]*inspect_iso_artifact[\s\S]*iso-audit\.json[\s\S]*SHA256SUMS' -Message 'The finished ISO must be decoded and audited before its checksum is staged.'
    Assert-Match -Value $linuxCore -Pattern 'inspection_toolchain[\s\S]*retained_repository' -Message 'Decoder evidence must bind back to the retained repository closure.'
    Assert-Match -Value $linuxCore -Pattern ([regex]::Escape('"package": "tar=1.35-r5"')) -Message 'The Linux public-contract guard must require the exact retained GNU tar decoder package.'
    Assert-Match -Value $linuxCore -Pattern 'readlink -f "\$command_path"[\s\S]*apk info -W "\$resolved_command"' -Message 'Configured applet paths must resolve inside the chroot before APK Tools 3 exact package ownership is accepted.'
    Assert-Match -Value $linuxCore -Pattern 'scripts/linux/inspect-iso\.sh' -Message 'The inspector must be included in the normalized source archive contract.'
}

function New-ClosedSecurityFixture {
    param([Parameter(Mandatory)] [string] $Root)

    $staging = Join-Path $Root 'staging'
    [System.IO.Directory]::CreateDirectory($staging) | Out-Null
    $inputs = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'builder/inputs.json') | ConvertFrom-Json -Depth 64
    $projectKeyHash = 'b' * 64
    $request = New-BuildRequest -Inputs $inputs `
        -Source ([pscustomobject]@{ git_commit = ('e' * 40); archive_sha256 = ('7' * 64); source_date_epoch = 1; dirty = $false }) `
        -InputHashes ([ordered]@{ inputs_sha256 = ('1' * 64); run_build_sha256 = ('2' * 64); inspect_iso_sha256 = ('3' * 64); profile_sha256 = ('4' * 64) }) `
        -SigningPublic ([pscustomobject]@{ schema = 'SigningPublic'; public_key_file = '300k.rsa.pub'; public_key_sha256 = $projectKeyHash })
    Write-CanonicalJson -Value $request -Path (Join-Path $staging 'build-request.json')
    $requestHash = Get-LowerFileSha256 -Path (Join-Path $staging 'build-request.json')

    $isoSeed = [byte[]]::new(4096)
    for ($index = 0; $index -lt $isoSeed.Length; $index++) { $isoSeed[$index] = [byte]($index % 251) }
    $temporaryIso = Join-Path $staging 'fixture.iso'
    [System.IO.File]::WriteAllBytes($temporaryIso, $isoSeed)
    $isoHash = Get-LowerFileSha256 -Path $temporaryIso
    $isoName = "300k-bootstrap-x86_64-$($isoHash.Substring(0,12)).iso"
    [System.IO.File]::Move($temporaryIso, (Join-Path $staging $isoName))

    [System.IO.File]::WriteAllText((Join-Path $staging 'builder-packages.lock'), "busybox-1.37.0-r31 x86_64`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $staging 'apk-files.sha256'), "$('c' * 64)  busybox-1.37.0-r31.apk`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $staging 'boot-layout.txt'), "El Torito BIOS`nEFI/BOOT/BOOTX64.EFI`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $staging 'serial-diagnostic.log'), "300K_BUILD_COMPLETE $isoHash`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $staging 'SHA256SUMS'), "$isoHash  $isoName`n", [System.Text.UTF8Encoding]::new($false))
    foreach ($record in @(
        [pscustomobject]@{ Name = 'repository-evidence.json'; Value = [ordered]@{ schema = 'RepositoryEvidence'; schema_version = 1; build_request_sha256 = $requestHash; repository_object_id = ('d' * 64); apk_count = 1; official_indexes_verified = $true; official_signatures_verified = $true; content_addressed_snapshot_verified = $true } },
        [pscustomobject]@{ Name = 'resource-inventory.json'; Value = [ordered]@{ schema_version = 1; cleanup_complete = $true; resources = [ordered]@{ qemu_lease_live = $false; seed_listener_live = $false; serial_listener_live = $false; port_reservation_live = $false; ssh_identity_present = $false; known_hosts_present = $false; overlay_present = $false; management_scratch_present = $false } } },
        [pscustomobject]@{ Name = 'qemu-image-info.json'; Value = [ordered]@{ format = 'raw'; virtual_size = 4096; actual_size = 4096 } },
        [pscustomobject]@{ Name = 'environment-report.json'; Value = [ordered]@{ schema_version = 1; backend = 'qemu'; backend_status = 'executed'; guest_os = 'linux'; guest_arch = 'x86_64'; alpine_release = '3.24.1'; qemu_cloud_image_sha512 = $inputs.qemu.cloud_image_sha512; docker_status = 'unverified-unavailable'; docker_reason = 'fixture'; serial_host_fingerprint = 'SHA256:fixtureFingerprint'; live_management_stages = @('shutdown-complete'); cleanup_complete = $true; source_commit = ('e' * 40) } }
    )) { Write-CanonicalJson -Value $record.Value -Path (Join-Path $staging $record.Name) }

    $toolItems = @($inputs.inspection_toolchain.PSObject.Properties | ForEach-Object {
        [ordered]@{
            format = $_.Name; package = $_.Value.package; command = $_.Value.command
            command_sha256 = ('f' * 64); version = 'fixture'; package_ownership_verified = $true
            path_verified = $true; round_trip_verified = $true; retained_apk_verified = $true
            retained_apk_file = ($_.Value.package.Replace('=', '-') + '.apk'); retained_apk_sha256 = ('a' * 64)
            contract_source = 'builder/inputs.json:inspection_toolchain'; retained_repository = ('d' * 64)
        }
    })
    $toolchainHash = '9' * 64
    $audit = [ordered]@{
        schema = 'IsoAudit'; schema_version = 1; iso_sha256 = $isoHash; iso_bytes = 4096
        inspection_toolchain_sha256 = $toolchainHash
        accepted_decoders = @('gzip', 'xz', 'zstd', 'lz4', 'cpio', 'squashfs', 'iso', 'tar', 'apk')
        limits = [ordered]@{ max_depth = 8; max_members = 200000; max_path_bytes = 4096; max_file_bytes = 1073741824; max_total_expanded_bytes = 4294967296 }
        counts = [ordered]@{ members = 10; regular_files = 5; containers = 4; expanded_bytes = 2048; max_observed_depth = 4 }
        structural_boot_findings = [ordered]@{ bios_tree_present = $true; uefi_tree_present = $true; classification = 'structural' }
        public_key_allowance = [ordered]@{ closed_key_count = 4; manifest_sha256 = ('8' * 64) }
        preflight_before_materialization = $true; links_materialized = $false; hostile_fixture_self_test = $true; result = 'pass'
    }
    Write-CanonicalJson -Value $audit -Path (Join-Path $staging 'iso-audit.json')

    $trustedKeys = @($inputs.alpine.repository_keys.PSObject.Properties | ForEach-Object {
        [ordered]@{ file = $_.Name; sha256 = [string]$_.Value; trust = 'alpine-x86_64' }
    }) + @([ordered]@{ file = '300k.rsa.pub'; sha256 = $projectKeyHash; trust = 'project-signing' })
    $builderRecordPath = Join-Path $staging 'builder-packages.lock'
    $apkRecordPath = Join-Path $staging 'apk-files.sha256'
    $auditPath = Join-Path $staging 'iso-audit.json'
    $checksumsPath = Join-Path $staging 'SHA256SUMS'
    $lock = [ordered]@{
        schema = 'ResolvedBuildLock'; schema_version = 1; build_request_sha256 = $requestHash; repository_object_id = ('d' * 64)
        repository_indexes = @($inputs.alpine.repositories | ForEach-Object { [ordered]@{ name = $_.name; sha256 = $_.apkindex_sha256; signature_verified = $true } })
        aports = [ordered]@{ commit = '52643b7a176095362fd87fe73cdb994cb2e5ffae'; archive_sha256 = ('3' * 64) }
        trusted_keys = $trustedKeys; trust_policy = [ordered]@{ mkimage_hostkeys = $true; closed_keyring_verified = $true; signature_bypass = $false }
        builder_packages_record = [ordered]@{ file = 'builder-packages.lock'; sha256 = (Get-LowerFileSha256 -Path $builderRecordPath); bytes = (Get-Item $builderRecordPath).Length; producer = 'run-build.sh:prepare-repository'; validator = 'build.ps1:Test-GeneratedFileRecord' }
        apk_files_record = [ordered]@{ file = 'apk-files.sha256'; sha256 = (Get-LowerFileSha256 -Path $apkRecordPath); bytes = (Get-Item $apkRecordPath).Length; producer = 'run-build.sh:prepare-repository'; validator = 'build.ps1:Test-GeneratedFileRecord' }
        inspection_commands = $toolItems; inspection_toolchain_sha256 = $toolchainHash
        offline_install = [ordered]@{ repositories = @('file:///repo'); apk_no_network = $true; network_disabled = $true; complete_manifest_verified = $true }
        artifacts = @(
            [ordered]@{ role = 'bootstrap_iso'; file = $isoName; sha256 = $isoHash; bytes = 4096 },
            [ordered]@{ role = 'decoded_iso_audit'; file = 'iso-audit.json'; sha256 = (Get-LowerFileSha256 -Path $auditPath); bytes = (Get-Item $auditPath).Length },
            [ordered]@{ role = 'iso_checksums'; file = 'SHA256SUMS'; sha256 = (Get-LowerFileSha256 -Path $checksumsPath); bytes = (Get-Item $checksumsPath).Length }
        )
    }
    Write-CanonicalJson -Value $lock -Path (Join-Path $staging 'resolved-build-lock.json')
    return [pscustomobject]@{ Staging = $staging; Inputs = $inputs; Request = $request; RequestHash = $requestHash; IsoName = $isoName; IsoHash = $isoHash }
}

Add-TestCase -Name 'BUILD-03 closed staging rejects paths schemas hashes sizes links secrets and extras' -Scopes @('Unit') -Requirements @('BUILD-03') -Body {
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-closed-staging-' + [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($scratch) | Out-Null
    try {
        foreach ($unsafe in @('../escape', '/absolute', 'C:\escape', '\\server\share', 'nested/file', 'file..json')) {
            Assert-ThrowsCode -Code 'ARTIFACT_NAME_INVALID' -Body { Assert-ClosedRelativeArtifactName -Name $unsafe | Out-Null }
        }
        Assert-Equal -Expected 'iso-audit.json' -Actual (Assert-ClosedRelativeArtifactName -Name 'iso-audit.json')

        $fixture = New-ClosedSecurityFixture -Root $scratch
        $validated = Test-ClosedStagingBundle -StagingDirectory $fixture.Staging -ExpectedBuildRequestSha256 $fixture.RequestHash -Inputs $fixture.Inputs -BuildRequest $fixture.Request
        Assert-Equal -Expected $fixture.IsoHash -Actual $validated.IsoSha256
        Assert-Equal -Expected $fixture.IsoName -Actual $validated.IsoFile

        $extra = Join-Path $fixture.Staging 'unexpected.bin'
        [System.IO.File]::WriteAllText($extra, 'unexpected')
        Assert-ThrowsCode -Code 'STAGING_FILE_SET_INVALID' -Body { Test-ClosedStagingBundle -StagingDirectory $fixture.Staging -ExpectedBuildRequestSha256 $fixture.RequestHash -Inputs $fixture.Inputs -BuildRequest $fixture.Request | Out-Null }
        Remove-Item -LiteralPath $extra

        $auditPath = Join-Path $fixture.Staging 'iso-audit.json'
        $auditBytes = [System.IO.File]::ReadAllBytes($auditPath)
        $audit = Get-Content -Raw -LiteralPath $auditPath | ConvertFrom-Json -Depth 64
        $audit.iso_sha256 = '0' * 64
        Write-CanonicalJson -Value $audit -Path $auditPath
        Assert-ThrowsCode -Code 'ISO_REFERENCE_MISMATCH' -Body { Test-ClosedStagingBundle -StagingDirectory $fixture.Staging -ExpectedBuildRequestSha256 $fixture.RequestHash -Inputs $fixture.Inputs -BuildRequest $fixture.Request | Out-Null }
        [System.IO.File]::WriteAllBytes($auditPath, $auditBytes)

        $serialPath = Join-Path $fixture.Staging 'serial-diagnostic.log'
        $serialBytes = [System.IO.File]::ReadAllBytes($serialPath)
        [System.IO.File]::WriteAllText($serialPath, 'FICT' + 'IONAL_300K_SECRET_TOKEN=' + ('Z' * 32))
        Assert-ThrowsCode -Code 'STAGING_SECRET_FOUND' -Body { Test-ClosedStagingBundle -StagingDirectory $fixture.Staging -ExpectedBuildRequestSha256 $fixture.RequestHash -Inputs $fixture.Inputs -BuildRequest $fixture.Request | Out-Null }
        [System.IO.File]::WriteAllBytes($serialPath, $serialBytes)
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

Add-TestCase -Name 'BUILD-03 atomic publication preserves the prior pointer at every transition' -Scopes @('Unit') -Requirements @('BUILD-03') -Body {
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-publication-' + [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($scratch) | Out-Null
    try {
        $fixture = New-ClosedSecurityFixture -Root $scratch
        $validated = Test-ClosedStagingBundle -StagingDirectory $fixture.Staging -ExpectedBuildRequestSha256 $fixture.RequestHash -Inputs $fixture.Inputs -BuildRequest $fixture.Request
        $dist = Join-Path $scratch 'dist'
        $prior = Join-Path $dist 'prior-build'
        [System.IO.Directory]::CreateDirectory($prior) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $prior 'sentinel'), 'prior-complete')
        $latestPath = Join-Path $dist 'LATEST.json'
        $priorPointer = [System.Text.Encoding]::UTF8.GetBytes('{"schema_version":1,"build_id":"prior-build","directory":"prior-build"}' + "`n")
        [System.IO.File]::WriteAllBytes($latestPath, $priorPointer)

        foreach ($stage in @('after-partial-create', 'after-partial-copy', 'after-copy-rehash', 'after-manifest-write', 'after-directory-revalidation', 'after-final-rename', 'after-pointer-temp-write', 'before-pointer-replace', 'after-pointer-replace')) {
            $buildId = 'failure-' + $stage
            Assert-ThrowsCode -Code 'PUBLICATION_INJECTED_FAILURE' -Body {
                Publish-ValidatedArtifactBundle -StagingDirectory $fixture.Staging -DistRoot $dist -BuildId $buildId -ValidatedBundle $validated -FailureStage $stage | Out-Null
            }
            Assert-Equal -Expected ([Convert]::ToHexString($priorPointer)) -Actual ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($latestPath))) -Message "LATEST changed at '$stage'."
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $prior 'sentinel') -PathType Leaf) -Message "Prior completed bundle disappeared at '$stage'."
            Assert-False -Condition (Test-Path -LiteralPath (Join-Path $dist $buildId)) -Message "Failed bundle survived at '$stage'."
            Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $dist -Directory -Filter '.partial-*').Count -Message "Partial publication survived at '$stage'."
        }

        $published = Publish-ValidatedArtifactBundle -StagingDirectory $fixture.Staging -DistRoot $dist -BuildId 'successful-build' -ValidatedBundle $validated
        Assert-Equal -Expected $fixture.IsoHash -Actual $published.IsoSha256
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $published.Directory 'artifact-manifest.json') -PathType Leaf)
        $latest = Get-Content -Raw -LiteralPath $latestPath | ConvertFrom-Json -Depth 16
        Assert-Equal -Expected 'successful-build' -Actual $latest.build_id
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

Add-TestCase -Name 'BUILD-03 exact clean removes only incomplete publication state' -Scopes @('Unit') -Requirements @('BUILD-03') -Body {
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-clean-scope-' + [Guid]::NewGuid().ToString('N'))
    $buildId = 'p01-' + ('a' * 12)
    [System.IO.Directory]::CreateDirectory($scratch) | Out-Null
    try {
        $completed = Join-Path $scratch $buildId
        $sibling = Join-Path $scratch ('p01-' + ('b' * 12))
        $partial = Join-Path $scratch ('.partial-' + $buildId + '-' + ('c' * 32))
        foreach ($directory in @($completed, $sibling, $partial)) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $completed 'sentinel'), 'completed')
        [System.IO.File]::WriteAllText((Join-Path $sibling 'sentinel'), 'sibling')
        [System.IO.File]::WriteAllText((Join-Path $partial 'transient'), 'partial')
        $latest = Join-Path $scratch 'LATEST.json'
        $latestBytes = [System.Text.Encoding]::UTF8.GetBytes('{"schema_version":1,"build_id":"prior"}' + "`n")
        [System.IO.File]::WriteAllBytes($latest, $latestBytes)

        Clear-IncompleteBuildNamespace -DistRoot $scratch -BuildId $buildId

        Assert-False -Condition (Test-Path -LiteralPath $partial) -Message 'Exact incomplete publication survived clean.'
        Assert-Equal -Expected 'completed' -Actual ([System.IO.File]::ReadAllText((Join-Path $completed 'sentinel'))) -Message 'Clean removed or changed a completed artifact.'
        Assert-Equal -Expected 'sibling' -Actual ([System.IO.File]::ReadAllText((Join-Path $sibling 'sentinel'))) -Message 'Clean crossed into a sibling build.'
        Assert-Equal -Expected ([Convert]::ToHexString($latestBytes)) -Actual ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($latest))) -Message 'Clean changed LATEST bytes.'
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

Add-TestCase -Name 'BUILD-03 named QEMU failures all flow through the single outer owner' -Scopes @('Unit') -Requirements @('BUILD-03') -Body {
    $qemuSource = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/host/Invoke-QemuBackend.ps1')
    $stages = @('after-key-creation', 'after-seed-start', 'after-qemu-start', 'after-host-key-milestone', 'after-ssh-readiness', 'after-source-transfer', 'after-secret-copy', 'after-repository-preparation', 'after-build', 'after-export', 'after-shutdown')
    foreach ($stage in $stages) {
        Assert-Match -Value $qemuSource -Pattern ("Invoke-QemuFailureStage[\s\S]{0,240}'" + [regex]::Escape($stage) + "'") -Message "QEMU failure seam '$stage' is not wired at its production boundary."
        $owned = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-owned-' + [Guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($owned) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $owned 'ephemeral'), $stage)
        $owner = New-QemuResourceOwner
        Add-QemuOwnedResource -Owner $owner -Name $stage -Cleanup { param($path) if ([System.IO.Directory]::Exists($path)) { [System.IO.Directory]::Delete($path, $true) } } -CleanupArgument $owned
        try { Assert-ThrowsCode -Code 'QEMU_INJECTED_FAILURE' -Body { Invoke-QemuFailureStage -FailureStage $stage -Stage $stage } }
        finally { Close-QemuResourceOwner -Owner $owner }
        Assert-False -Condition (Test-Path -LiteralPath $owned) -Message "Outer owner leaked the '$stage' fixture."
    }
    Assert-Match -Value $qemuSource -Pattern 'finally[\s\S]*Close-QemuResourceOwner' -Message 'QEMU owner is not closed from the unconditional outer finally.'
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
        inspect_iso_sha256 = ('1' * 64)
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
    $imagePackages = @($inputs.requested_image_packages)
    foreach ($package in @('alpine-base', 'apk-cron', 'busybox', 'chrony', 'dhcpcd', 'doas', 'e2fsprogs', 'grub-efi', 'iw', 'kbd-bkeymaps', 'linux-firmware', 'linux-virt', 'network-extras', 'openntpd', 'openssl', 'openssh', 'syslinux', 'tiny-cloud-alpine', 'tzdata', 'wget', 'wireless-regdb', 'wpa_supplicant')) {
        Assert-True -Condition ($imagePackages -ccontains $package) -Message "Pinned profile_virt direct package '$package' is missing from repository resolution."
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

Add-TestCase -Name 'BUILD-04 mkimage trusts only the verified closed x86_64 keyring' -Scopes @('Unit') -Requirements @('BUILD-04') -Body {
    $inputs = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'builder/inputs.json') | ConvertFrom-Json -Depth 30
    $expectedRepositoryKeys = [ordered]@{
        'alpine-devel@lists.alpinelinux.org-4a6a0840.rsa.pub' = '9c102bcc376af1498d549b77bdbfa815ae86faa1d2d82f040e616b18ef2df2d4'
        'alpine-devel@lists.alpinelinux.org-5261cecb.rsa.pub' = '12f899e55a7691225603d6fb3324940fc51cd7f133e7ead788663c2b7eecb00c'
        'alpine-devel@lists.alpinelinux.org-6165ee59.rsa.pub' = '207e4696d3c05f7cb05966aee557307151f1f00217af4143c1bcaf33b8df733f'
    }
    $actualRepositoryKeys = $inputs.alpine.repository_keys
    Assert-Equal -Expected @($expectedRepositoryKeys.Keys) -Actual @($actualRepositoryKeys.PSObject.Properties.Name) -Message 'The Alpine x86_64 repository-key allowlist changed.'
    foreach ($name in $expectedRepositoryKeys.Keys) {
        Assert-Equal -Expected $expectedRepositoryKeys[$name] -Actual ([string]$actualRepositoryKeys.$name) -Message "Repository key '$name' has an unpinned hash."
    }

    $projectKeyHash = 'd' * 64
    $trustedKeys = @(
        $actualRepositoryKeys.PSObject.Properties | ForEach-Object {
            [pscustomobject]@{ file = $_.Name; sha256 = [string]$_.Value; trust = 'alpine-x86_64' }
        }
    ) + @([pscustomobject]@{ file = '300k.rsa.pub'; sha256 = $projectKeyHash; trust = 'project-signing' })
    [void](Test-ResolvedTrustedKeys -TrustedKeys $trustedKeys -RepositoryKeys $actualRepositoryKeys -SigningPublicSha256 $projectKeyHash)
    foreach ($invalid in @(
        @($trustedKeys | Select-Object -Skip 1),
        @($trustedKeys + [pscustomobject]@{ file = 'ambient.rsa.pub'; sha256 = ('e' * 64); trust = 'alpine-x86_64' }),
        @($trustedKeys | ForEach-Object {
            if ($_.file -ceq '300k.rsa.pub') { [pscustomobject]@{ file = $_.file; sha256 = ('f' * 64); trust = $_.trust } }
            else { $_ }
        })
    )) {
        Assert-ThrowsCode -Code 'RESOLVED_LOCK_TRUSTED_KEYS_INVALID' -Body {
            Test-ResolvedTrustedKeys -TrustedKeys $invalid -RepositoryKeys $actualRepositoryKeys -SigningPublicSha256 $projectKeyHash | Out-Null
        }
    }

    $linux = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/linux/run-build.sh')
    Assert-Match -Value $linux -Pattern 'stage_closed_keyring "\$build_root/etc/apk/keys"' -Message 'The build root does not stage the verified closed keyring.'
    Assert-Match -Value $linux -Pattern 'verify_closed_keyring "\$build_root/etc/apk/keys"' -Message 'The closed keyring is not reverified before mkimage.'
    Assert-False -Condition ([bool]($linux -match 'cp /etc/apk/keys/\*')) -Message 'Ambient guest keys are still copied by wildcard.'
    Assert-Match -Value $linux -Pattern 'mkimage_command=.*?mkimage\.sh.*?--hostkeys.*?--repository file:///repo' -Message 'Pinned mkimage argv does not import the closed buildroot keyring.'
    Assert-False -Condition ([bool]($linux -match '(?i)--allow-untrusted|--no-signature|--no-check-signature|--insecure')) -Message 'A package-signature bypass was introduced.'
    Assert-Match -Value $linux -Pattern '"trusted_keys": \[' -Message 'ResolvedBuildLock does not record the exact trusted key set.'
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
                foreach ($entryName in @('scripts/linux/run-build.sh', 'scripts/linux/inspect-iso.sh', 'builder/profiles/mkimg.300k.sh')) {
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
    Assert-Match -Value $linux -Pattern '(?s)mount --bind "\$build_root/repo" /repo.*?--no-network add.*?umount /repo' -Message 'The canonical file:///repo URL is not bounded to the target repository during offline installation.'
    Assert-Match -Value $linux -Pattern 'apk --root "\$build_root" --arch x86_64 --initdb --keys-dir etc/apk/keys' -Message 'APK root-relative key lookup or target architecture is not explicit.'
    Assert-False -Condition ([bool]($linux -match '--keys-dir /etc/apk/keys')) -Message 'A leading slash would bypass the APK target root when loading signing keys.'
    foreach ($pattern in @('/home/\$builder_user/\.mkimage', '\$builder_user:x:\$builder_uid:\$builder_gid:300K build user', 'HOME=/home/\$builder_user', '/bin/su -s /bin/sh -c "\$mkimage_command" "\$builder_user"')) {
        Assert-Match -Value $linux -Pattern $pattern -Message "The pinned mkimage usermode boundary is missing '$pattern'."
    }
    Assert-False -Condition ([bool]($linux -match 'chroot "\$build_root" env -i')) -Message 'Pinned mkimage must not execute as the root chroot identity.'
    Assert-Match -Value $linux -Pattern '(?s)mount --bind /proc "\$build_root/proc".*?mount --bind /dev "\$build_root/dev".*?chroot "\$build_root" /bin/su.*?umount "\$build_root/dev".*?umount "\$build_root/proc"' -Message 'Unprivileged APK usermode lacks its bounded proc/device mount lifecycle.'
    Assert-Match -Value $linux -Pattern '(?s)chmod 0755 "\$build_root".*?chmod -R a-w,a\+rX "\$build_root/repo".*?builder_probe=.*?test -r /repo/x86_64/APKINDEX\.tar\.gz.*?MKIMAGE_IDENTITY_INVALID' -Message 'Builder traversal, immutable inputs, and the pre-mkimage identity probe are not fail-closed.'
    Assert-Match -Value $linux -Pattern '(?s)chmod -R a\+rX "\$build_root/bin".*?builder_probe=.*?/sbin/apk --print-arch.*?x86_64' -Message 'The unprivileged builder does not prove readable package payloads and an executable pinned APK.'
    Assert-Match -Value $linux -Pattern '(?s)chown -R "\$builder_uid:\$builder_gid" "\$build_root/repo".*?verify_repository_snapshot "\$build_root/repo/x86_64".*?mkimage\.sh.*?verify_repository_snapshot "\$build_root/repo/x86_64"' -Message 'Protected hardlink ownership is not bounded by staged repository verification.'
    Assert-Match -Value $linux -Pattern '(?s)mkimage_log=.*?300k-mkimage\.log.*?2>&1.*?tail -n 80 "\$mkimage_log" >&2' -Message 'A bounded mkimage failure tail is not preserved for the host tracer.'
    Assert-Match -Value $linux -Pattern 'env -i HOME=/home/\$builder_user PATH=/usr/sbin:/usr/bin:/sbin:/bin CBUILD=x86_64 SOURCE_DATE_EPOCH=' -Message 'The clean mkimage environment does not pin its build architecture.'
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
    Assert-Match -Value $qemu -Pattern 'Substring\(\$diagnostic\.Length - 512, 512\)' -Message 'Bounded remote diagnostics discard the final command failure.'
}

if ($Scope -in @('Qemu', 'Security', 'All')) {
    Add-TestCase -Name 'BUILD-03 BUILD-04 real clean-tree decoded-security QEMU tracer' -Scopes @('Qemu', 'Security') -Requirements @('BUILD-03', 'BUILD-04') -Body {
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
            'iso-audit.json', 'SHA256SUMS', 'serial-diagnostic.log', 'repository-evidence.json',
            'resource-inventory.json', 'artifact-manifest.json'
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
        $inputs = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'builder/inputs.json') | ConvertFrom-Json -Depth 30
        [void](Test-ResolvedTrustedKeys -TrustedKeys @($lock.trusted_keys) -RepositoryKeys $inputs.alpine.repository_keys -SigningPublicSha256 $request.signing.public_key_sha256)
        Assert-True -Condition ([bool]$lock.trust_policy.mkimage_hostkeys) -Message 'Resolved lock does not prove the exact mkimage --hostkeys path.'
        Assert-True -Condition ([bool]$lock.trust_policy.closed_keyring_verified) -Message 'Resolved lock does not prove the closed keyring was verified.'
        Assert-False -Condition ([bool]$lock.trust_policy.signature_bypass) -Message 'Resolved lock reports a signature bypass.'
        Assert-Equal -Expected $sourceCommit -Actual $request.source.git_commit -Message 'Build evidence does not preserve the clean source commit.'
        Assert-False -Condition ([bool]$request.source.dirty) -Message 'BuildRequest marked the committed source dirty.'
        Assert-Match -Value $lock.repository_object_id -Pattern '^[0-9a-f]{64}$' -Message 'Content-addressed repository ID is malformed.'
        Assert-True -Condition ([bool]$lock.offline_install.apk_no_network) -Message 'Resolved lock does not prove apk --no-network.'
        Assert-True -Condition ([bool]$lock.offline_install.network_disabled) -Message 'Resolved lock does not prove networking was disabled before assembly.'
        Assert-True -Condition ([bool]$lock.offline_install.complete_manifest_verified) -Message 'Resolved lock does not prove complete manifest verification.'
        Assert-Equal -Expected @('file:///repo') -Actual @($lock.offline_install.repositories) -Message 'Offline build consumed a non-local repository.'

        $expectedFormats = @($inputs.inspection_toolchain.PSObject.Properties.Name)
        $commands = @($lock.inspection_commands)
        Assert-Equal -Expected $expectedFormats.Count -Actual $commands.Count -Message 'Resolved lock has an incomplete inspection command set.'
        Assert-Equal -Expected $expectedFormats -Actual @($commands.format) -Message 'Resolved lock inspection formats differ from public input.'
        foreach ($command in $commands) {
            Assert-Match -Value $command.package -Pattern '^[a-z0-9+_.-]+=[0-9][A-Za-z0-9._-]*-r\d+$' -Message 'Inspection package is not exactly pinned.'
            Assert-Match -Value $command.command -Pattern '^/' -Message 'Inspection command is not an exact absolute path.'
            Assert-Match -Value $command.command_sha256 -Pattern '^[0-9a-f]{64}$' -Message 'Inspection command hash is malformed.'
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($command.version)) -Message 'Inspection command version is absent.'
            foreach ($field in @('package_ownership_verified', 'path_verified', 'round_trip_verified', 'retained_apk_verified')) {
                Assert-True -Condition ([bool]$command.$field) -Message "Inspection command '$($command.format)' did not prove $field."
            }
            Assert-Match -Value $command.retained_apk_sha256 -Pattern '^[0-9a-f]{64}$' -Message 'Retained decoder APK hash is malformed.'
            Assert-Equal -Expected $lock.repository_object_id -Actual $command.retained_repository -Message 'Decoder evidence belongs to another retained repository.'
        }

        $audit = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'iso-audit.json') | ConvertFrom-Json -Depth 64
        Assert-Equal -Expected 'IsoAudit' -Actual $audit.schema
        Assert-Equal -Expected 'pass' -Actual $audit.result
        Assert-Equal -Expected $isoHash -Actual $audit.iso_sha256 -Message 'Decoded audit names different ISO bytes.'
        Assert-Equal -Expected ([long](Get-Item -LiteralPath $isoPath).Length) -Actual ([long]$audit.iso_bytes) -Message 'Decoded audit ISO byte count differs.'
        Assert-Equal -Expected $lock.inspection_toolchain_sha256 -Actual $audit.inspection_toolchain_sha256 -Message 'Audit and lock decoder identities disagree.'
        Assert-True -Condition ([bool]$audit.preflight_before_materialization) -Message 'Audit does not prove preflight before writes.'
        Assert-False -Condition ([bool]$audit.links_materialized) -Message 'Audit reports archive link creation.'
        Assert-True -Condition ([bool]$audit.hostile_fixture_self_test) -Message 'Runtime compressed-layer hostile fixtures did not pass.'
        Assert-True -Condition ([long]$audit.counts.members -gt 0 -and [long]$audit.counts.containers -gt 0 -and [long]$audit.counts.expanded_bytes -gt 0) -Message 'Decoded audit coverage is vacuous.'
        Assert-Equal -Expected "$isoHash  $($latest.iso_file)`n" -Actual ((Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'SHA256SUMS')).Replace("`r`n", "`n")) -Message 'SHA256SUMS does not identify exactly the published ISO.'

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
        foreach ($stage in @('ssh-readiness-live', 'prepare-guest-live', 'input-transfer-live', 'private-key-tmpfs-live', 'prepare-repository-live', 'build-from-local-live', 'artifact-export-live', 'shutdown-complete')) {
            Assert-True -Condition (@($environment.live_management_stages) -ccontains $stage) -Message "Owned QEMU lease was not proven live at '$stage'."
        }

        $serial = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'serial-diagnostic.log')
        Assert-Match -Value $serial -Pattern '(?m)^300K_SSH_HOST_KEY ssh-ed25519 [A-Za-z0-9+/]+=* SHA256:[A-Za-z0-9+/]+$' -Message 'Sanitized serial evidence lacks the accepted SSH trust milestone.'
        Assert-Match -Value $serial -Pattern '(?m)^300K_BUILD_COMPLETE [0-9a-f]{64}$' -Message 'Sanitized serial evidence lacks the real build completion milestone.'

        $inventory = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'resource-inventory.json') | ConvertFrom-Json -Depth 16
        Assert-True -Condition ([bool]$inventory.cleanup_complete) -Message 'Resource inventory reports incomplete cleanup.'
        foreach ($property in $inventory.resources.PSObject.Properties) {
            Assert-False -Condition ([bool]$property.Value) -Message "Owned QEMU resource '$($property.Name)' remains after the tracer."
        }

        $artifactManifest = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'artifact-manifest.json') | ConvertFrom-Json -Depth 64
        Assert-Equal -Expected 'ArtifactManifest' -Actual $artifactManifest.schema
        Assert-Equal -Expected $requestHash -Actual $artifactManifest.build_request_sha256
        foreach ($record in @($artifactManifest.artifacts)) {
            $recordPath = Join-Path $artifactRoot $record.file
            Assert-True -Condition ([System.IO.File]::Exists($recordPath)) -Message "Manifest artifact is absent: $($record.file)"
            Assert-Equal -Expected $record.sha256 -Actual ((Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash.ToLowerInvariant()) -Message "Manifest hash differs: $($record.file)"
            Assert-Equal -Expected ([long]$record.bytes) -Actual ([long](Get-Item -LiteralPath $recordPath).Length) -Message "Manifest size differs: $($record.file)"
        }

        $cleanAfter = Invoke-CheckedProcess -FilePath $gitPath -ArgumentList @('status', '--porcelain', '--untracked-files=all') -WorkingDirectory $script:RepositoryRoot -TimeoutSeconds 30
        Assert-True -Condition ([string]::IsNullOrEmpty($cleanAfter.StandardOutput)) -Message "QEMU tracer dirtied the source tree.`n$($cleanAfter.StandardOutput)"
    }

    Add-TestCase -Name 'BUILD-03 isolated post-build failure matrix preserves cleanup and prior publication' -Scopes @('Security') -Requirements @('BUILD-03') -Body {
        $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('300k-security-failures-' + [Guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($scratch) | Out-Null
        try {
            $fixture = New-ClosedSecurityFixture -Root $scratch
            $validated = Test-ClosedStagingBundle -StagingDirectory $fixture.Staging -ExpectedBuildRequestSha256 $fixture.RequestHash -Inputs $fixture.Inputs -BuildRequest $fixture.Request
            $dist = Join-Path $scratch 'dist'
            $prior = Join-Path $dist 'prior-build'
            [System.IO.Directory]::CreateDirectory($prior) | Out-Null
            $priorSentinel = Join-Path $prior 'sentinel'
            [System.IO.File]::WriteAllText($priorSentinel, 'prior-complete', [System.Text.UTF8Encoding]::new($false))
            $latestPath = Join-Path $dist 'LATEST.json'
            $priorPointer = [System.Text.Encoding]::UTF8.GetBytes('{"schema_version":1,"build_id":"prior-build","directory":"prior-build"}' + "`n")
            [System.IO.File]::WriteAllBytes($latestPath, $priorPointer)

            $publicationStages = @(
                'after-partial-create', 'after-partial-copy', 'after-copy-rehash', 'after-manifest-write',
                'after-directory-revalidation', 'after-final-rename', 'after-pointer-temp-write',
                'before-pointer-replace', 'after-pointer-replace'
            )
            foreach ($stage in $publicationStages) {
                $buildId = 'security-' + $stage
                Assert-ThrowsCode -Code 'PUBLICATION_INJECTED_FAILURE' -Body {
                    Publish-ValidatedArtifactBundle -StagingDirectory $fixture.Staging -DistRoot $dist -BuildId $buildId -ValidatedBundle $validated -FailureStage $stage | Out-Null
                }
                Assert-Equal -Expected ([Convert]::ToHexString($priorPointer)) -Actual ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($latestPath))) -Message "LATEST changed at Security stage '$stage'."
                Assert-Equal -Expected 'prior-complete' -Actual ([System.IO.File]::ReadAllText($priorSentinel)) -Message "Prior completed output changed at Security stage '$stage'."
                Assert-False -Condition (Test-Path -LiteralPath (Join-Path $dist $buildId)) -Message "Failed Security publication survived at '$stage'."
                Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $dist -Directory -Filter '.partial-*').Count -Message "Partial Security publication survived at '$stage'."
            }

            $qemuStages = @(
                'after-key-creation', 'after-seed-start', 'after-qemu-start', 'after-host-key-milestone',
                'after-ssh-readiness', 'after-source-transfer', 'after-secret-copy',
                'after-repository-preparation', 'after-build', 'after-export', 'after-shutdown'
            )
            foreach ($stage in $qemuStages) {
                $owned = Join-Path $scratch ('owned-' + $stage)
                [System.IO.Directory]::CreateDirectory($owned) | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $owned 'ephemeral'), $stage, [System.Text.UTF8Encoding]::new($false))
                $owner = New-QemuResourceOwner
                Add-QemuOwnedResource -Owner $owner -Name $stage -Cleanup {
                    param($path)
                    if ([System.IO.Directory]::Exists($path)) { [System.IO.Directory]::Delete($path, $true) }
                } -CleanupArgument $owned
                try {
                    Assert-ThrowsCode -Code 'QEMU_INJECTED_FAILURE' -Body { Invoke-QemuFailureStage -FailureStage $stage -Stage $stage }
                }
                finally { Close-QemuResourceOwner -Owner $owner }
                Assert-False -Condition (Test-Path -LiteralPath $owned) -Message "Outer owner leaked the Security '$stage' resource."
            }

            Assert-Equal -Expected ([Convert]::ToHexString($priorPointer)) -Actual ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($latestPath))) -Message 'QEMU failure matrix changed the prior publication pointer.'
            Assert-Equal -Expected 'prior-complete' -Actual ([System.IO.File]::ReadAllText($priorSentinel)) -Message 'QEMU failure matrix changed the prior completed output.'
        }
        finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
        Assert-False -Condition (Test-Path -LiteralPath $scratch) -Message 'Security failure-matrix scratch survived cleanup.'
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
