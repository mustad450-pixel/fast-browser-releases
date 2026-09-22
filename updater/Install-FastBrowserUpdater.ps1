param(
    [string]$UpdaterSource = '',
    [string]$CosignSource = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module ScheduledTasks -ErrorAction Stop

$ReleaseRepo = 'mustad450-pixel/fast-browser-releases'
$ManifestUrl = "https://raw.githubusercontent.com/$ReleaseRepo/main/update.json"
$UpdaterUrl = "https://raw.githubusercontent.com/$ReleaseRepo/main/updater/FastBrowserUpdater.ps1"
$CosignUrl = 'https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign-windows-amd64.exe'
$ExpectedCosignSha256 = '9fe59be0eca1271873ce019061335eb1ac419b7059202e797828467ddabe33be'

$UpdaterDir = Join-Path $env:LOCALAPPDATA 'Fast Sector\Fast Browser\Updater'
$UpdaterPath = Join-Path $UpdaterDir 'FastBrowserUpdater.ps1'
$CosignPath = Join-Path $UpdaterDir 'cosign.exe'
$StatePath = Join-Path $UpdaterDir 'state.json'
$LauncherPath = Join-Path $UpdaterDir 'RunUpdaterHidden.vbs'
$ChromePath = Join-Path $env:LOCALAPPDATA 'Fast Sector\Fast Browser\Application\chrome.exe'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Path $UpdaterDir -Force | Out-Null

if ($UpdaterSource -and (Test-Path -LiteralPath $UpdaterSource -PathType Leaf)) {
    Copy-Item -LiteralPath $UpdaterSource -Destination $UpdaterPath -Force
} else {
    Invoke-WebRequest -Uri ($UpdaterUrl + '?ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -OutFile $UpdaterPath -UseBasicParsing -TimeoutSec 120
}

if ($CosignSource -and (Test-Path -LiteralPath $CosignSource -PathType Leaf)) {
    Copy-Item -LiteralPath $CosignSource -Destination $CosignPath -Force
} elseif (-not (Test-Path -LiteralPath $CosignPath -PathType Leaf)) {
    Invoke-WebRequest -Uri $CosignUrl -OutFile $CosignPath -UseBasicParsing -TimeoutSec 600
}

$cosignHash = (Get-FileHash -LiteralPath $CosignPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($cosignHash -ne $ExpectedCosignSha256) { throw "Cosign SHA-256 mismatch: $cosignHash" }
if (-not (Test-Path -LiteralPath $ChromePath -PathType Leaf)) { throw "Fast Browser is not installed: $ChromePath" }

$manifest = Invoke-RestMethod -Uri ($ManifestUrl + '?ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -TimeoutSec 30 -Headers @{ 'Cache-Control'='no-cache' }
$rawVersion = (Get-Item -LiteralPath $ChromePath).VersionInfo.FileVersion
$m = [regex]::Match([string]$rawVersion,'\d+(?:\.\d+){1,3}')
if (-not $m.Success) { throw "Cannot determine Fast Browser Chromium version from: $rawVersion" }

$localChromium = ([version]$m.Value).ToString()
$remoteChromium = ([version][string]$manifest.chromiumVersion).ToString()
$baselineHash = ''
if ($localChromium -eq $remoteChromium) { $baselineHash = ([string]$manifest.sha256).ToLowerInvariant() }

$state = [ordered]@{
    schema = 1
    releaseVersion = [string]$manifest.releaseVersion
    chromiumVersion = $localChromium
    installerSha256 = $baselineHash
    installedUtc = [DateTimeOffset]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($StatePath,(($state | ConvertTo-Json -Depth 4) + [Environment]::NewLine),$Utf8NoBom)

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$command = '"' + $psExe + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $UpdaterPath + '"'
$escapedCommand = $command.Replace('"','""')
$vbs = @"
Set sh = CreateObject("WScript.Shell")
sh.Run "$escapedCommand", 0, False
Set sh = Nothing
"@
[IO.File]::WriteAllText($LauncherPath,$vbs,$Utf8NoBom)

$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$action = New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "' + $LauncherPath + '"')
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Hours 1)
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName 'Fast Browser Update Check' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

# The native About-page handler replaced the old URL-protocol route.
$protocolRoot = 'HKCU:\Software\Classes\fastbrowser-update'
Remove-Item -LiteralPath $protocolRoot -Recurse -Force -ErrorAction SilentlyContinue

$programs = [Environment]::GetFolderPath('Programs')
$oldShortcut = Join-Path $programs 'Fast Browser\Check for Fast Browser Updates.lnk'
Remove-Item -LiteralPath $oldShortcut -Force -ErrorAction SilentlyContinue

$task = Get-ScheduledTask -TaskName 'Fast Browser Update Check' -ErrorAction Stop
if ([string]$task.Actions[0].Execute -notmatch '(?i)\\wscript\.exe$') {
    throw 'Updater task was not registered with the hidden wscript launcher.'
}
if (Test-Path -LiteralPath $protocolRoot) {
    throw 'Obsolete fastbrowser-update protocol still exists.'
}

Write-Host 'FAST BROWSER UPDATER INSTALLED - SILENT TASK VERIFIED' -ForegroundColor Green