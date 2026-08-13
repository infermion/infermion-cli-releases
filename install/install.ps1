[CmdletBinding()]
param(
    [string]$Version = $(if ($env:INFERMION_VERSION) { $env:INFERMION_VERSION } else { "latest" }),
    [ValidateSet("stable", "beta")]
    [string]$Track = $(if ($env:INFERMION_TRACK) { $env:INFERMION_TRACK } else { "stable" }),
    [string]$InstallDir = $(if ($env:INFERMION_INSTALL_DIR) { $env:INFERMION_INSTALL_DIR } else { "$env:LOCALAPPDATA\Infermion\bin" }),
    [string]$ReleaseRepository = $(if ($env:INFERMION_RELEASE_REPOSITORY) { $env:INFERMION_RELEASE_REPOSITORY } else { "infermion/infermion-cli-releases" }),
    [int]$CurrentProcessId = 0,
    [string]$PreviousVersion = "",
    [switch]$DeleteInstaller
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$releaseBase = if ($env:INFERMION_RELEASE_BASE_URL) { $env:INFERMION_RELEASE_BASE_URL } else { "https://github.com/$ReleaseRepository/releases" }
$channelBase = if ($env:INFERMION_CHANNEL_BASE_URL) { $env:INFERMION_CHANNEL_BASE_URL } else { "https://raw.githubusercontent.com/$ReleaseRepository/main/channels" }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($ReleaseRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "ReleaseRepository must be one GitHub owner/repository slug."
}
if (-not [Uri]::IsWellFormedUriString($releaseBase, [UriKind]::Absolute) -or ([Uri]$releaseBase).Scheme -ne "https") {
    throw "The release base URL must be an absolute HTTPS URL."
}
if (-not [Uri]::IsWellFormedUriString($channelBase, [UriKind]::Absolute) -or ([Uri]$channelBase).Scheme -ne "https") {
    throw "The channel base URL must be an absolute HTTPS URL."
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "Infermion requires a 64-bit Windows installation."
}
if ($env:PROCESSOR_ARCHITECTURE -notin @("AMD64", "x86")) {
    throw "Unsupported Windows architecture: $env:PROCESSOR_ARCHITECTURE"
}

$temporaryDir = Join-Path ([IO.Path]::GetTempPath()) ("infermion-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temporaryDir | Out-Null
try {
    $resolveLatest = $Version -eq "latest"
    if ($resolveLatest) {
        $versionFile = Join-Path $temporaryDir "VERSION"
        Invoke-WebRequest -UseBasicParsing "$channelBase/$Track/VERSION" -OutFile $versionFile
        $Version = (Get-Content -Raw $versionFile).Trim()
    } else {
        $Version = $Version.TrimStart("v")
    }
    if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+((a|b|rc)[0-9]+)?$') {
        throw "Invalid release version: $Version"
    }
    $releaseTrack = if ($Version -match '(a|b|rc)[0-9]+$') { "beta" } else { "stable" }
    if ($resolveLatest -and $releaseTrack -ne $Track) {
        throw "$Track channel resolved an unexpected $releaseTrack version: $Version"
    }

    $archiveName = "infermion-v$Version-windows-x86_64.zip"
    $assetBase = "$releaseBase/download/cli-v$Version"
    $archive = Join-Path $temporaryDir $archiveName
    $checksums = Join-Path $temporaryDir "SHA256SUMS"
    Invoke-WebRequest -UseBasicParsing "$assetBase/$archiveName" -OutFile $archive
    Invoke-WebRequest -UseBasicParsing "$assetBase/SHA256SUMS" -OutFile $checksums

    $line = Get-Content $checksums | Where-Object { $_ -match "\s+$([regex]::Escape($archiveName))$" } | Select-Object -First 1
    if (-not $line) { throw "$archiveName is absent from SHA256SUMS" }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "Checksum verification failed for $archiveName" }

    Expand-Archive -Path $archive -DestinationPath $temporaryDir -Force
    $binary = Join-Path $temporaryDir "infermion-v$Version-windows-x86_64\infermion.exe"
    if (-not (Test-Path $binary)) { throw "Release archive did not contain infermion.exe" }
    if ($releaseTrack -eq "stable") {
        $signature = Get-AuthenticodeSignature $binary
        if ($signature.Status -ne "Valid") {
            throw "The Infermion Authenticode signature is invalid: $($signature.StatusMessage)"
        }
    } else {
        Write-Warning "Installing an unsigned Infermion beta; Windows may show an Unknown publisher warning."
    }
    $reportedVersion = (& $binary --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $reportedVersion -ne $Version) {
        throw "The downloaded application reported version '$reportedVersion', expected '$Version'."
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $destination = Join-Path $InstallDir "infermion.exe"
    if ($CurrentProcessId -gt 0) {
        Wait-Process -Id $CurrentProcessId -ErrorAction SilentlyContinue
    }
    $staged = Join-Path $InstallDir (".infermion-" + [guid]::NewGuid() + ".tmp")
    Copy-Item $binary $staged -Force
    Move-Item $staged $destination -Force

    $configDir = Join-Path $env:APPDATA "Infermion"
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    @{
        channel = "standalone"
        release_track = $releaseTrack
        version = $Version
        install_dir = $InstallDir
        release_repository = $ReleaseRepository
    } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $configDir "install.json")

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($userPath -split ';') -notcontains $InstallDir) {
        $newPath = if ($userPath) { "$userPath;$InstallDir" } else { $InstallDir }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "Added $InstallDir to your user PATH. Open a new terminal before running Infermion."
    }
    if ($CurrentProcessId -gt 0) {
        if ($PreviousVersion) {
            Write-Host "Updated Infermion $PreviousVersion to $Version at $destination"
        } else {
            Write-Host "Updated Infermion to $Version at $destination"
        }
        Write-Host "Next: infermion --version"
    } else {
        Write-Host "Installed Infermion $Version to $destination"
    }
} finally {
    Remove-Item -Recurse -Force $temporaryDir -ErrorAction SilentlyContinue
    if ($DeleteInstaller -and $PSCommandPath) {
        Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
    }
}
