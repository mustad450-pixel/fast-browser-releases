param(
    [switch]$Interactive,
    [string]$ProtocolUri
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ManifestBase = 'https://raw.githubusercontent.com/mustad450-pixel/fast-browser-releases/main/update.json'
$ExpectedIdentity = 'https://github.com/mustad450-pixel/fast-browser-automation/.github/workflows/sign-fast-browser.yml@refs/heads/main'
$ExpectedIssuer = 'https://token.actions.githubusercontent.com'
$ReleasePathPrefix = '/mustad450-pixel/fast-browser-releases/releases/download/'
$UpdaterDir = Join-Path $env:LOCALAPPDATA 'Fast Sector\Fast Browser\Updater'
$StatePath = Join-Path $UpdaterDir 'state.json'
$LogPath = Join-Path $UpdaterDir 'updater.log'
$Cosign = Join-Path $UpdaterDir 'cosign.exe'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Path $UpdaterDir -Force | Out-Null

function Log([string]$Message) {
    $line = ('{0:u} {1}' -f (Get-Date), $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Notify([string]$Message, [bool]$IsError = $false) {
    if (-not $Interactive) { return }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $icon = if ($IsError) { 16 } else { 64 }
        [void]$shell.Popup($Message, 0, 'Fast Browser Update', $icon)
    }
    catch {
        Write-Host $Message
    }
}

function Parse-Version([string]$Value, [string]$Name) {
    try { return [version]$Value }
    catch { throw "Invalid $Name version: $Value" }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\FastBrowserUpdaterV1')
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        Notify 'Another Fast Browser update check is already running.'
        exit 0
    }

    Log 'Update check started.'
    if (-not (Test-Path -LiteralPath $Cosign -PathType Leaf)) {
        throw "Cosign verifier is missing: $Cosign"
    }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "Updater state is missing: $StatePath"
    }

    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $localRelease = Parse-Version ([string]$state.releaseVersion) 'local release'
    $localChromium = Parse-Version ([string]$state.chromiumVersion) 'local Chromium'

    $manifestUrl = $ManifestBase + '?ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $manifest = Invoke-RestMethod -Uri $manifestUrl -Method Get -TimeoutSec 30 -Headers @{ 'Cache-Control' = 'no-cache' }

    if ([int]$manifest.schema -ne 1) { throw 'Unsupported update manifest schema.' }
    if ($manifest.enabled -ne $true) {
        Log 'Stable update channel is disabled.'
        Notify 'Fast Browser updates are temporarily disabled.'
        exit 0
    }

    $remoteRelease = Parse-Version ([string]$manifest.releaseVersion) 'remote release'
    $remoteChromium = Parse-Version ([string]$manifest.chromiumVersion) 'remote Chromium'

    if ([string]$manifest.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'Update manifest SHA-256 is invalid.'
    }
    $remoteHash = ([string]$manifest.sha256).ToLowerInvariant()
    $localHash = ''
    if ($state.PSObject.Properties.Name -contains 'installerSha256' -and $state.installerSha256) {
        $localHash = ([string]$state.installerSha256).ToLowerInvariant()
    }

    $sameVersionNewBuild = ($remoteRelease -eq $localRelease) -and
                           ($remoteChromium -eq $localChromium) -and
                           ($remoteHash -ne $localHash)
    $needsUpdate = ($remoteRelease -gt $localRelease) -or
                   ($remoteChromium -gt $localChromium) -or
                   $sameVersionNewBuild
    if (-not $needsUpdate) {
        Log "Up to date: release $localRelease, Chromium $localChromium."
        Notify "Fast Browser is up to date.`nRelease: $localRelease`nChromium: $localChromium"
        exit 0
    }

    $installerUri = [uri][string]$manifest.installerUrl
    $bundleUri = [uri][string]$manifest.sigstoreBundleUrl
    foreach ($u in @($installerUri, $bundleUri)) {
        if ($u.Scheme -ne 'https' -or $u.Host -ne 'github.com' -or
            -not $u.AbsolutePath.StartsWith($ReleasePathPrefix, [System.StringComparison]::Ordinal)) {
            throw "Rejected update URL: $u"
        }
    }

    $work = Join-Path $env:TEMP ('FastBrowserUpdate-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $installer = Join-Path $work 'Fast-Browser-Update.exe'
    $bundle = Join-Path $work 'Fast-Browser-Update.sigstore.json'

    try {
        Log "Downloading release $remoteRelease / Chromium $remoteChromium."
        Invoke-WebRequest -Uri $installerUri.AbsoluteUri -OutFile $installer -UseBasicParsing -TimeoutSec 600
        Invoke-WebRequest -Uri $bundleUri.AbsoluteUri -OutFile $bundle -UseBasicParsing -TimeoutSec 120

        $actualHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedHash = $remoteHash
        if ($actualHash -ne $expectedHash) {
            throw "Installer SHA-256 mismatch. Expected $expectedHash, got $actualHash"
        }

        & $Cosign verify-blob $installer --bundle $bundle --certificate-identity $ExpectedIdentity --certificate-oidc-issuer $ExpectedIssuer | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Sigstore verification failed.' }

        Log 'SHA-256 and Sigstore verification passed. Installing update.'
        $process = Start-Process -FilePath $installer -ArgumentList @('--do-not-launch-chrome','--verbose-logging') -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Fast Browser installer exited with code $($process.ExitCode)."
        }

        $newState = [ordered]@{
            schema = 1
            releaseVersion = [string]$manifest.releaseVersion
            chromiumVersion = [string]$manifest.chromiumVersion
            installerSha256 = $actualHash
            installedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        } | ConvertTo-Json
        [IO.File]::WriteAllText($StatePath, $newState + [Environment]::NewLine, $Utf8NoBom)

        Log 'Update installed successfully. Browser restart required.'
        Notify "Fast Browser update installed successfully.`n`nRelease: $($manifest.releaseVersion)`nChromium: $($manifest.chromiumVersion)`n`nClose and reopen Fast Browser to use the new build."
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Log ('ERROR: ' + $_.Exception.Message)
    Notify ("Update check failed:`n" + $_.Exception.Message) $true
    exit 1
}
finally {
    if ($hasMutex) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    $mutex.Dispose()
}

exit 0