[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

function Invoke-ReleaseGit {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowMissing)
    # Git writes successful bundle verification messages to stderr, including on PS 5.1.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& $git -C $repoRoot @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($AllowMissing -and $exitCode -eq 1) { return }
    if ($exitCode -ne 0) {
        throw "git $($Arguments[0]) failed (exit $exitCode): $($result -join [Environment]::NewLine)"
    }
    $result | ForEach-Object { $_.ToString() }
}

function Test-PathWithin {
    param([string]$Path, [string]$Root)
    $boundary = $Root.TrimEnd('\', '/')
    $Path.Equals($boundary, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-LocalOutputPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')) {
        throw 'OutputRoot must be an absolute local drive path; UNC, provider and drive-relative paths are not supported.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (Test-PathWithin $fullPath $repoRoot) {
        throw 'OutputRoot must be outside the source repository.'
    }
    $driveRoot = [IO.Path]::GetPathRoot($fullPath)
    $drive = [IO.DriveInfo]::new($driveRoot)
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed -or
        $drive.VolumeLabel -match '(?i)pcloud|onedrive|google drive|dropbox') {
        throw 'OutputRoot must use a ready fixed local volume, not a cloud or network drive.'
    }
    $psDrive = Get-PSDrive -Name $driveRoot.Substring(0, 1) -PSProvider FileSystem -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($psDrive.DisplayRoot)) {
        throw 'OutputRoot must not use a mapped drive.'
    }
    $substitutions = @(& (Join-Path ([Environment]::SystemDirectory) 'subst.exe'))
    if ($LASTEXITCODE -ne 0) { throw 'Could not verify substituted drive mappings.' }
    if (@($substitutions | Where-Object { $_.StartsWith($driveRoot, [StringComparison]::OrdinalIgnoreCase) }).Count) {
        throw 'OutputRoot must not use a substituted drive.'
    }
    foreach ($scope in @('Process', 'User', 'Machine')) {
        foreach ($name in @('pCloudDrive', 'pCloudShared', 'A_ROOT_PCLOUD_DESK', 'A_ROOT_PCLOUD_HOST',
                'A_ROOT_PCLOUD_SHARED', 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial', 'Dropbox')) {
            $cloudRoot = [Environment]::GetEnvironmentVariable($name, $scope)
            if ([string]::IsNullOrWhiteSpace($cloudRoot)) { continue }
            $cloudRoot = [Environment]::ExpandEnvironmentVariables($cloudRoot)
            if ($cloudRoot -notmatch '^[A-Za-z]:[\\/]') { continue }
            $cloudRoot = [IO.Path]::GetFullPath($cloudRoot)
            # pCloud bindings name machine/shared children of a virtual drive.
            if ($name -match '(?i)pcloud') { $cloudRoot = [IO.Path]::GetPathRoot($cloudRoot) }
            if (Test-PathWithin $fullPath $cloudRoot) {
                throw 'OutputRoot must be outside configured cloud storage.'
            }
        }
    }
    $ancestor = $fullPath
    while (-not [string]::IsNullOrEmpty($ancestor)) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'OutputRoot and its existing ancestors must be ordinary local directories, without links or reparse points.'
            }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    $fullPath
}

function Assert-CleanSource {
    $status = @(Invoke-ReleaseGit -Arguments @('status', '--porcelain=v1', '--untracked-files=normal', '--ignore-submodules=none'))
    if ($status.Count -ne 0) { throw 'Source repository has tracked or untracked changes; commit or preserve them before packaging.' }
    $mergeHead = Invoke-ReleaseGit -Arguments @('rev-parse', '--git-path', 'MERGE_HEAD')
    if (-not [IO.Path]::IsPathRooted($mergeHead)) { $mergeHead = Join-Path $repoRoot $mergeHead }
    if (Test-Path -LiteralPath $mergeHead) { throw 'Finish the active merge before packaging.' }
}

$outputDirectory = Assert-LocalOutputPath $OutputRoot
$actualRoot = Invoke-ReleaseGit -Arguments @('rev-parse', '--show-toplevel')
if (-not [IO.Path]::GetFullPath($actualRoot).Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The script must be run from its owning vcpkg repository.'
}
if ((Invoke-ReleaseGit -Arguments @('rev-parse', '--is-shallow-repository')) -ne 'false') {
    throw 'A complete, non-shallow Git repository is required for portable version history.'
}
$sourceRef = Invoke-ReleaseGit -Arguments @('symbolic-ref', '-q', 'HEAD') -AllowMissing
if ([string]::IsNullOrWhiteSpace($sourceRef) -or -not $sourceRef.StartsWith('refs/heads/')) {
    throw 'Check out a named branch before packaging; detached HEAD is not supported.'
}
Assert-CleanSource
$sourceRevision = Invoke-ReleaseGit -Arguments @('rev-parse', '--verify', 'HEAD')
$clientSource = Join-Path $repoRoot 'VCPKG_DISTRIBUTION.md'
if (-not (Test-Path -LiteralPath $clientSource -PathType Leaf)) { throw 'VCPKG_DISTRIBUTION.md is missing.' }
$metadataPath = Join-Path $repoRoot 'scripts\vcpkg-tool-metadata.txt'
$toolTagLine = @(Get-Content -LiteralPath $metadataPath | Where-Object { $_ -match '^VCPKG_TOOL_RELEASE_TAG=\S+$' })
if ($toolTagLine.Count -ne 1) { throw 'Expected one vcpkg bootstrap release tag in tool metadata.' }
$toolTag = $toolTagLine[0].Substring('VCPKG_TOOL_RELEASE_TAG='.Length)
$upstreamRevision = Invoke-ReleaseGit -Arguments @('rev-parse', '--verify', '--quiet', 'refs/remotes/upstream/master') -AllowMissing

$createdUtc = [DateTime]::UtcNow
$releaseId = $createdUtc.ToString('yyyyMMddTHHmmssfffZ') + '-' + $sourceRevision.Substring(0, 12)
$releasesDirectory = Join-Path $outputDirectory 'releases'
$releaseDirectory = Join-Path $releasesDirectory $releaseId
# Validate the descendants too: an existing releases directory may itself be a link.
$null = Assert-LocalOutputPath $releaseDirectory
$null = [IO.Directory]::CreateDirectory($releasesDirectory)
$null = Assert-LocalOutputPath $releaseDirectory
if (Test-Path -LiteralPath $releaseDirectory) { throw 'The release directory already exists and will not be overwritten.' }
$null = New-Item -Path $releaseDirectory -ItemType Directory -ErrorAction Stop

try {
    $bundlePath = Join-Path $releaseDirectory 'source.bundle'
    Invoke-ReleaseGit -Arguments @('bundle', 'create', $bundlePath, $sourceRef) | Out-Null
    Invoke-ReleaseGit -Arguments @('bundle', 'verify', $bundlePath) | Out-Null
    $bundleHeads = @(Invoke-ReleaseGit -Arguments @('bundle', 'list-heads', $bundlePath))
    if ($bundleHeads.Count -ne 1 -or $bundleHeads[0] -cne "$sourceRevision $sourceRef") {
        throw 'Bundle does not contain exactly the captured source branch and revision.'
    }
    $clientPath = Join-Path $releaseDirectory 'CLIENT.md'
    [IO.File]::Copy($clientSource, $clientPath, $false)
    $files = @(
        foreach ($path in @($bundlePath, $clientPath)) {
            [ordered]@{
                Name = [IO.Path]::GetFileName($path)
                Bytes = (Get-Item -LiteralPath $path).Length
                SHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
    Assert-CleanSource
    if ((Invoke-ReleaseGit -Arguments @('rev-parse', '--verify', 'HEAD')) -cne $sourceRevision -or
        (Invoke-ReleaseGit -Arguments @('symbolic-ref', '-q', 'HEAD') -AllowMissing) -cne $sourceRef) {
        throw 'Source revision or branch changed during packaging.'
    }
    $manifest = [ordered]@{
        SchemaVersion = 1
        ReleaseId = $releaseId
        CreatedUtc = $createdUtc.ToString('o')
        Owner = 'Sev'
        Producer = [Environment]::MachineName
        SourceRevision = $sourceRevision
        SourceRef = $sourceRef
        RepositoryUrl = 'https://github.com/espensev/vcpkg-SevIQ.git'
        UpstreamUrl = 'https://github.com/microsoft/vcpkg.git'
        UpstreamRevision = $upstreamRevision
        IncludedHistory = 'Complete Git history reachable from the source branch; no other refs or working-tree state.'
        BootstrapToolReleaseTag = $toolTag
        ExcludedLocalContent = @('installed', 'packages', 'buildtrees', 'downloads', 'downloads/tools', 'vcpkg.exe', 'vcpkg')
        Files = $files
        Verification = [ordered]@{
            GitBundleVerified = $true
            SourceUnchanged = $true
            RemoteUploadVerified = $false
            ClientBuildVerified = $false
        }
    }
    $manifestPath = Join-Path $releaseDirectory 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{
        ReleaseId = $releaseId
        ReleaseDirectory = $releaseDirectory
        ManifestPath = $manifestPath
        SourceRevision = $sourceRevision
        SourceRef = $sourceRef
        Files = $files
    }
} catch {
    throw "Packaging failed; partial output remains at '$releaseDirectory' for inspection. $($_.Exception.Message)"
}
