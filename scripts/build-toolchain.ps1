<#
.SYNOPSIS
    Compile the UltraScan3 dependency toolchain on Windows.

.DESCRIPTION
    The Windows counterpart to scripts/build-toolchain.sh. This is the only
    place Qt is compiled for Windows. It runs in the toolchain pipeline, not on
    the commit path, so it is allowed to be slow and to be retried.

    It produces a vcpkg binary cache directory which the toolchain workflow
    archives and publishes as a release asset. Application builds download that
    archive via scripts/fetch-toolchain.ps1 and restore from it in seconds.

    There are no staged "warm" features here. Staging existed only so a failing
    job on the commit path could bank partial progress before hitting the cache
    quota or the job timeout. A dedicated pipeline installs the real feature
    sets directly, and the caller archives the cache whether or not the build
    succeeded, so a retry resumes from whatever completed.

.PARAMETER CacheDir
    Required. vcpkg binary cache directory to populate.

.PARAMETER QtVariant
    qt6 (default) or qt5-qwt630.

.PARAMETER Profiles
    Profiles to install. Defaults to APP -- Windows ships no HPC build.

.PARAMETER SkipBootstrap
    Skip the OS bootstrap script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CacheDir,
    [ValidateSet('qt6', 'qt5-qwt630')][string]$QtVariant = 'qt6',
    [string[]]$Profiles = @('APP'),
    [switch]$SkipBootstrap
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceDir = Split-Path -Parent $ScriptDir

# Triplet must match admin/cmake/toolchain.cmake, including its host-triplet
# rule: host equals target, so the dependency graph is built once.
$Triplet     = 'x64-windows'
$HostTriplet = $Triplet

Write-Host '=============================================='
Write-Host 'UltraScan3 toolchain build (Windows)'
Write-Host '=============================================='
Write-Host "  qt variant : $QtVariant"
Write-Host "  profiles   : $($Profiles -join ', ')"
Write-Host "  triplet    : $Triplet (host = target)"
Write-Host "  cache dir  : $CacheDir"
Write-Host ''

if (-not $SkipBootstrap) {
    & (Join-Path $ScriptDir 'bootstrap-windows.ps1')
    if ($LASTEXITCODE -ne 0) { throw "bootstrap-windows.ps1 failed ($LASTEXITCODE)" }
}

# -----------------------------------------------------------------------------
# vcpkg at the pinned commit.
#
# The commit pins the ports AND the tool: bootstrap-vcpkg resolves the tool
# version from scripts/vcpkg-tool-metadata.txt at whatever is checked out. An
# unpinned clone lets a vcpkg release silently change ABI hashes and invalidate
# every cached package with no change in this repository.
# -----------------------------------------------------------------------------
$VcpkgCommit = (Get-Content -Raw (Join-Path $SourceDir 'vcpkg.json') |
                ConvertFrom-Json).'builtin-baseline'

# Windows has a 260-character path limit that Qt's deep source trees run into,
# so vcpkg lives at a short root rather than under the workspace.
$VcpkgRoot = if ($env:US3_VCPKG_ROOT) { $env:US3_VCPKG_ROOT } else { 'C:\vcpkg' }

if (-not (Test-Path (Join-Path $VcpkgRoot '.git'))) {
    Write-Host "Cloning vcpkg into $VcpkgRoot..."
    git clone https://github.com/microsoft/vcpkg.git $VcpkgRoot
    if ($LASTEXITCODE -ne 0) { throw 'vcpkg clone failed' }
}

Write-Host "Pinning vcpkg to $VcpkgCommit"
git -C $VcpkgRoot fetch --quiet origin $VcpkgCommit 2>$null
if ($LASTEXITCODE -ne 0) { git -C $VcpkgRoot fetch --quiet origin }
git -C $VcpkgRoot checkout --quiet --detach $VcpkgCommit
if ($LASTEXITCODE -ne 0) { throw "could not check out vcpkg commit $VcpkgCommit" }

# The bootstrapped tool must match the checkout it was built for.
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $VcpkgRoot 'vcpkg.exe')
& (Join-Path $VcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics
if ($LASTEXITCODE -ne 0) { throw 'bootstrap-vcpkg.bat failed' }

$VcpkgExe = Join-Path $VcpkgRoot 'vcpkg.exe'
$env:VCPKG_ROOT = $VcpkgRoot
& $VcpkgExe version

# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$env:VCPKG_BINARY_SOURCES = "clear;files,$CacheDir,readwrite"

$Downloads = if ($env:US3_VCPKG_DOWNLOADS) { $env:US3_VCPKG_DOWNLOADS } else { 'C:\vcpkg-downloads' }
New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
$env:VCPKG_DOWNLOADS = $Downloads

# --clean-after-build is what keeps this inside the runner's disk budget: each
# port's buildtree is discarded as soon as its binary is cached.
$env:VCPKG_INSTALL_OPTIONS = '--clean-after-build'
$env:VCPKG_MAX_CONCURRENCY = "$([Environment]::ProcessorCount)"

$OverlayTriplets = Join-Path $SourceDir 'admin\cmake\triplets'
$OverlayPorts    = Join-Path $SourceDir 'buildsys\vcpkg\overlay-ports'

# -----------------------------------------------------------------------------
# Install each profile's real feature set
# -----------------------------------------------------------------------------
foreach ($ProfileName in $Profiles) {
    $Feature = switch ("$QtVariant-$ProfileName") {
        'qt6-APP'        { 'qt6-app' }
        'qt6-HPC'        { 'qt6-hpc' }
        'qt5-qwt630-APP' { 'qt5-app' }
        'qt5-qwt630-HPC' { 'qt5-hpc' }
        default { throw "no vcpkg feature for $QtVariant/$ProfileName" }
    }

    Write-Host ''
    Write-Host '=============================================='
    Write-Host "Installing $Feature ($ProfileName)"
    Write-Host '=============================================='

    $vcpkgArgs = @(
        'install',
        "--triplet=$Triplet",
        "--host-triplet=$HostTriplet",
        "--overlay-triplets=$OverlayTriplets",
        '--x-no-default-features',
        "--x-feature=$Feature",
        # Manifest mode makes an install tree match the current feature set
        # exactly, so separate trees keep one profile's install from
        # uninstalling the other's packages. Shared binaries come from the
        # binary cache either way.
        "--x-install-root=$VcpkgRoot\installed-toolchain-$ProfileName"
    )
    if (Test-Path $OverlayPorts) { $vcpkgArgs += "--overlay-ports=$OverlayPorts" }

    & $VcpkgExe @vcpkgArgs
    if ($LASTEXITCODE -ne 0) { throw "vcpkg install failed for $Feature ($LASTEXITCODE)" }
}

$pkgCount = (Get-ChildItem -Path $CacheDir -Filter '*.zip' -Recurse -File).Count
Write-Host ''
Write-Host '=============================================='
Write-Host 'Toolchain build complete'
Write-Host '=============================================='
Write-Host "cached packages: $pkgCount"
