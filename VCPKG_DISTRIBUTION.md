# Shared vcpkg source releases

Owner: Sev. Producer: the maintained vcpkg-SevIQ checkout. Audience: development
clients with independently installed operating systems, compilers and SDKs.
Authoritative source: this Git repository; each release records its exact commit.
Git remotes: <https://github.com/espensev/vcpkg-SevIQ> and
<https://github.com/microsoft/vcpkg>.

Resolve the shared collection with
`Join-Path $env:pCloudShared 'Resources\Development\vcpkg-SevIQ'`.
On snd-desk this currently resolves below `P:\SND-Shared`; other clients must
resolve their own binding and rclone account/root mapping. A directory named
shared does not itself configure account access or a public sharing link.

```text
Resources/Development/vcpkg-SevIQ/
  README.md                         entry point and retention policy
  current.json                      latest verified source release
  releases/
    <UTC>-<commit>/
      source.bundle                 committed source with reachable Git history
      manifest.json                 source identity and payload SHA-256 hashes
      CLIENT.md                     this guide for that release
      verification.json             checks and their limits for that publication
```

The cloud copy contains completed artifacts. Download them to local storage
before use. Each client keeps its checkout, `installed`, `vcpkg_installed`,
`buildtrees`, `packages`, downloads, build tools and binary cache local.
No compiler, SDK, prebuilt library or `vcpkg.exe` is bundled. Full Git history
is retained because manifest versioning needs historical port tree objects.
The older snd-desk whole-tree snapshots remain recovery captures.

## Install on a client

1. Read `current.json` and its selected release's manifest and verification.
   Use rclone to download the selected release into a new local directory.
   On each machine first verify the configured remote's account/root mapping
   against its resolved `pCloudShared` binding. The producer's remote name is
   not a requirement on clients. Do not run a checkout on the cloud drive.
2. Check every payload hash in the manifest before using the bundle or helper.
   The release pointer also records the manifest hash. Download verification
   proves transport integrity; the producer and shared account must be trusted.
3. Clone locally and confirm HEAD equals the manifest's `SourceRevision`:

   ```powershell
   # Explicit client choices: downloaded release folder and new local checkout.
   $release = 'C:\LocalArtifacts\vcpkg-release'
   $root = 'C:\DevTools\vcpkg-SevIQ'
   $manifest = Get-Content (Join-Path $release 'manifest.json') -Raw | ConvertFrom-Json
   foreach ($file in $manifest.Files) {
       $path = Join-Path $release $file.Name
       if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.SHA256) {
           throw "Release hash mismatch: $($file.Name)"
       }
   }
   $branch = $manifest.SourceRef -replace '^refs/heads/', ''
   git clone --branch $branch (Join-Path $release 'source.bundle') $root
   if ($LASTEXITCODE -ne 0) { throw 'Clone failed' }
   if ((git -C $root rev-parse HEAD) -ne $manifest.SourceRevision) {
       throw 'Unexpected source revision'
   }
   git -C $root remote set-url origin https://github.com/espensev/vcpkg-SevIQ.git
   if ($LASTEXITCODE -ne 0) { throw 'Remote configuration failed' }
   & (Join-Path $root 'bootstrap-vcpkg.bat') -disableMetrics
   if ($LASTEXITCODE -ne 0) { throw 'Bootstrap failed' }
   ```

   These example paths are client choices, not required locations. On Linux or
   macOS clone the same bundle with Git, then run `./bootstrap-vcpkg.sh
   -disableMetrics` in the checkout. Install the platform's build prerequisites.
   Bootstrapping and package builds may require network downloads.
4. Choose the project's target triplet and the triplet for tools running on this
   client. In the current Windows PowerShell session:

   ```powershell
   # Example only: Windows x64 target and Windows x64 build host using MSVC.
   $targetTriplet = 'x64-windows'
   $hostTriplet = 'x64-windows'
   $clientSetup = Join-Path $root 'scripts\seviq\Set-VcpkgClientEnv.ps1'
   & $clientSetup -VcpkgRoot $root -TargetTriplet $targetTriplet -HostTriplet $hostTriplet
   & $clientSetup -Mode Apply -VcpkgRoot $root -TargetTriplet $targetTriplet `
       -HostTriplet $hostTriplet -UseLocalBinaryCache -DisableMetrics
   ```

   Plan is read-only. Apply changes this process and its children only; invoke
   with `&` in the build shell, not in a separate `pwsh -File` process. The helper
   does not install build tools, change PATH or persist environment settings.
   `-UseLocalBinaryCache` explicitly replaces this process's binary-cache setting
   with `clear;default,readwrite`; omit it to retain an intentionally configured
   local cache. Any existing `VCPKG_DEFAULT_BINARY_CACHE` override must also be
   an existing local directory. Review inherited settings before builds. Do not
   configure a live cache on the pCloud virtual drive.
5. Configure the consuming project in a new local build directory. Pass its
   selected triplets and the vcpkg toolchain explicitly (or in project presets):

   ```powershell
   cmake -S $project -B $newBuildDirectory `
       "-DCMAKE_TOOLCHAIN_FILE=$root/scripts/buildsystems/vcpkg.cmake" `
       "-DVCPKG_TARGET_TRIPLET=$targetTriplet" "-DVCPKG_HOST_TRIPLET=$hostTriplet"
   cmake --build $newBuildDirectory --config Release
   ```

   CMake must be installed or selected on that client. Configure its generator
   and compiler environment appropriately; for example, Ninja with MSVC requires
   that client's Visual Studio developer environment. Build and test a real
   consuming project before treating the client as ready.

## Different architectures and toolsets

| Client/project requirement | Configuration owner |
|---|---|
| Windows x64 or ARM64 target | Project's `VCPKG_TARGET_TRIPLET`; choose host separately |
| Linux/macOS target and native host | Suitable platform triplets and locally installed compiler |
| Specific MSVC toolset/CRT/linkage | Project overlay triplet with `VCPKG_PLATFORM_TOOLSET`, `VCPKG_CRT_LINKAGE`, `VCPKG_LIBRARY_LINKAGE` as needed |
| Custom compiler or external toolchain | Project triplet and `VCPKG_CHAINLOAD_TOOLCHAIN_FILE`; supply files locally |
| Reproducible dependency versions | Project `vcpkg.json` and baseline/registry configuration |

Select a toolset that actually exists on the receiving machine. Keep custom
triplets and toolchain files in the consuming project's source, with paths
resolved on that client. Pass overlay directories through the helper's
`-OverlayTriplets` option or the project's vcpkg/CMake configuration. When the
option is omitted, the helper preserves and validates inherited overlay paths.
Do not copy snd-desk's Visual Studio installation path, SDK selection or CMake caches.

A matching triplet name alone does not prove binary compatibility. vcpkg's ABI
identity includes compiler, triplet, toolchain and dependency inputs. Keep
compiler tracking enabled and account for additional custom toolchain inputs.
Build locally when those inputs differ. Any future shared binary acceleration
must use separately designed immutable exports, downloaded into local caches.

The helper is a Windows convenience. Other operating systems use their own
process environment or CMake presets with the same explicit root and triplet
choices; the source release itself contains the upstream cross-platform ports
and bootstrap scripts. Source portability does not guarantee every port supports
every compiler or architecture.

## Update a client

Download and verify the next release as above. Prefer a new local clone when
changing toolsets. For an existing checkout, first preserve any local edits and
verify `git status --porcelain` is empty. Then fetch the manifest's included ref:

```powershell
git -C $root fetch (Join-Path $release 'source.bundle') $manifest.SourceRef
if ($LASTEXITCODE -ne 0) { throw 'Bundle fetch failed' }
if ((git -C $root rev-parse FETCH_HEAD) -ne $manifest.SourceRevision) {
    throw 'Unexpected update revision'
}
git -C $root log --oneline HEAD..FETCH_HEAD
# After reviewing the incoming source changes:
git -C $root merge --ff-only FETCH_HEAD
if ($LASTEXITCODE -ne 0) { throw 'Update needs explicit reconciliation or a fresh clone' }
if ((git -C $root rev-parse HEAD) -ne $manifest.SourceRevision) {
    throw 'Local commits remain beyond this release; reconcile explicitly or use a fresh clone'
}
& (Join-Path $root 'bootstrap-vcpkg.bat') -disableMetrics
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap failed' }
```

Use the shell bootstrap on Linux/macOS. Release bundles are the complete update
transport; a release can precede its publication to the GitHub fork. Do not
assume `origin/master` already contains the selected release commit.

Updating this distribution does not change a consuming project's pinned
baseline or upgrade its installed packages. `vcpkg update` only reports
outdated classic-mode packages against the current local ports. Review project
baseline changes and rebuild separately. When source/toolset changes, use a
fresh project build directory and let vcpkg determine ABI compatibility. Keep
the previous local checkout until the new one passes the consuming build.

## Produce and publish an update

1. Fetch Microsoft upstream, review and merge the chosen revision, preserving
   the fork's changes. Preserve pending work first. Bootstrap if the checked-in
   tool metadata changes. Do not bulk-upgrade existing consumers implicitly.
2. Run the two environment harnesses under PowerShell 7 and Windows PowerShell
   5.1, inspect the diff, and commit the intended source changes. The exporter
   requires a clean, non-shallow checkout on a branch.
3. Create a fresh release locally, outside the repository and cloud storage:

   ```powershell
   & .\scripts\seviq\Export-VcpkgRelease.ps1 -OutputRoot 'C:\LocalArtifacts\vcpkg-releases'
   ```

   The exporter creates a new dated directory with `source.bundle`,
   `manifest.json` and `CLIENT.md`. It packages committed Git objects, not the
   installed machine tree. Verify a fresh local clone, bootstrap and a focused
   consuming build. Add `verification.json` recording commands, results and any
   untested client/toolset boundaries. Hash the manifest and verification file
   for the pointer described below.
4. Resolve `pCloudShared`, validate the configured rclone remote/root mapping,
   and derive `Resources/Development/vcpkg-SevIQ` from that binding. Upload only
   the exact four release files into a previously absent `releases/<release-id>`
   using `rclone copy` with `--files-from` and `--immutable`. No `sync`, overwrite,
   move or deletion is part of publication. Run `rclone check --one-way
   --download` with the same allowlist and require zero differences.
5. Only after release verification, stage `current.json` locally with
   `SchemaVersion`, `ReleaseId`, `RelativePath`, `SourceRevision`,
   `ManifestSHA256` and `VerificationSHA256`. Check any existing pointer for
   concurrent changes before replacing it using `rclone copyto`. Upload the
   collection README the same way when needed. Read back and verify both files.
   A future failed or interrupted upload must leave the previous pointer intact.

Keep release directories immutable. Retain all published versions until Sev
explicitly retires them after checking consumer and recovery needs. No automatic
client updates, scheduled shared publication, retention cleanup, public link or
receiving-machine deployment is configured by these scripts. The fork's existing
upstream-sync GitHub workflow is separate; it does not publish shared releases
or update clients.

References: [manifest mode](https://learn.microsoft.com/en-us/vcpkg/concepts/manifest-mode),
[Git history in CI](https://learn.microsoft.com/en-us/vcpkg/concepts/continuous-integration),
[triplets](https://learn.microsoft.com/en-us/vcpkg/users/triplets),
[binary ABI inputs](https://learn.microsoft.com/en-us/vcpkg/reference/binarycaching),
[update command](https://learn.microsoft.com/en-us/vcpkg/commands/update).
