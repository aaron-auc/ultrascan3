<#
.SYNOPSIS
    Resolve the prebuilt dependency toolchain for Windows.

.DESCRIPTION
    Application builds do not compile dependencies. They consume a prebuilt
    vcpkg binary cache produced once by .github/workflows/toolchain-build.yml
    and pinned in buildsys/toolchain.lock.json.

    This script downloads and verifies that archive if it is not already
    present, then reports the directory to use as the vcpkg binary cache.
    build.ps1 consumes it as US3_VCPKG_CACHE.

.PARAMETER Dest
    Where to extract archives. Defaults to a per-user cache directory.

.PARAMETER GitHubEnv
    Append US3_VCPKG_CACHE to $env:GITHUB_ENV (CI convenience).

.PARAMETER AllowMissing
    Exit successfully with no output if the pin has no artifact recorded yet.
    Used by the toolchain workflow itself, which builds what this normally
    downloads.
#>

[CmdletBinding()]
param(
    [string]$Dest,
    [switch]$GitHubEnv,
    [switch]$AllowMissing
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceDir = Split-Path -Parent $ScriptDir
$LockFile  = Join-Path $SourceDir 'buildsys\toolchain.lock.json'

if (-not (Test-Path $LockFile)) { throw "missing $LockFile" }

$Target = 'windows-x64'
$lock   = Get-Content -Raw $LockFile | ConvertFrom-Json

if (-not $lock.targets.PSObject.Properties.Name.Contains($Target)) {
    throw "no toolchain pin for target '$Target'"
}
$pin = $lock.targets.$Target

if ([string]::IsNullOrWhiteSpace($pin.sha256)) {
    if ($AllowMissing) { return }
    throw @"
Toolchain pin for '$Target' has no sha256 recorded.
Run the 'Toolchain' workflow to build and publish it, then merge the pin
update it produces.
"@
}

if (-not $Dest) {
    $Dest = if ($env:US3_TOOLCHAIN_DIR) { $env:US3_TOOLCHAIN_DIR }
            else { Join-Path $env:LOCALAPPDATA 'ultrascan3\toolchain' }
}

$CacheDir = Join-Path $Dest "$Target\$($pin.sha256)"
$Stamp    = Join-Path $CacheDir '.complete'

if (-not (Test-Path $Stamp)) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $TmpArchive = Join-Path $Dest ".$($pin.asset).partial"

    # Repository is derived, never hardcoded: this file is identical upstream and
    # in every fork, and each publishes its toolchain to its own releases.
    $repo = $env:GITHUB_REPOSITORY
    if (-not $repo) {
        $origin = (git -C $SourceDir remote get-url origin 2>$null)
        if ($origin) { $repo = $origin -replace '^git@[^:]+:', '' -replace '^https?://[^/]+/', '' -replace '\.git$', '' }
    }
    if (-not $repo) {
        throw "cannot determine the GitHub repository to download from. Set GITHUB_REPOSITORY=<owner>/<repo> and retry."
    }
    $url  = "https://github.com/$repo/releases/download/$($lock.release_tag)/$($pin.asset)"

    Write-Host "Fetching toolchain for $Target"
    Write-Host "  $url"

    $headers = @{}
    if ($env:GH_TOKEN) { $headers['Authorization'] = "Bearer $env:GH_TOKEN" }

    # Invoke-WebRequest's progress rendering is extraordinarily slow for large
    # files in non-interactive hosts; disabling it is worth several minutes.
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $url -OutFile $TmpArchive -Headers $headers -MaximumRetryCount 5 -RetryIntervalSec 5
    }
    finally {
        $ProgressPreference = $oldProgress
    }

    # Verify BEFORE extracting. A corrupted or substituted archive must never
    # reach the build tree.
    $actual = (Get-FileHash -Path $TmpArchive -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $pin.sha256.ToLower()) {
        Remove-Item -Force $TmpArchive
        throw "checksum mismatch for $($pin.asset)`n  expected $($pin.sha256)`n  actual   $actual"
    }

    if (Test-Path $CacheDir) { Remove-Item -Recurse -Force $CacheDir }
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

    # tar.exe ships with Windows Server 2019+ and handles zstd via the external
    # zstd binary, which bootstrap-windows.ps1 installs.
    & tar.exe --use-compress-program=unzstd -xf $TmpArchive -C $CacheDir
    if ($LASTEXITCODE -ne 0) { throw "extraction failed for $($pin.asset)" }

    Remove-Item -Force $TmpArchive
    New-Item -ItemType File -Path $Stamp -Force | Out-Null
    Write-Host "Toolchain extracted to $CacheDir"
}
else {
    Write-Host "Toolchain already present: $CacheDir"
}

if ($GitHubEnv -and $env:GITHUB_ENV) {
    Add-Content -Path $env:GITHUB_ENV -Value "US3_VCPKG_CACHE=$CacheDir"
}

Write-Output $CacheDir
