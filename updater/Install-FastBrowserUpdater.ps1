param(
    [string]$BaselineVersion = '1.2.0',
    [string]$CosignSource = ''
)

$ErrorActionPreference = 'Stop'
$UpdaterDir = Join-Path $env:LOCALAPPDATA 'Fast Sector\Fast Browser\Updater'
$UpdaterPath = Join-Path $UpdaterDir 'FastBrowserUpdater.ps1'
$CosignPath = Join-Path $UpdaterDir 'cosign.exe'
$StatePath = Join-Path $UpdaterDir 'state.json'
$ExpectedCosignSha256 = '9fe59be0eca1271873ce019061335eb1ac419b7059202e797828467ddabe33be'
$UpdaterUrl = 'https://raw.githubusercontent.com/mustad450-pixel/fast-browser-releases/main/updater/FastBrowserUpdater.ps1'
$CosignUrl = 'https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign-windows-amd64.exe'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Path $UpdaterDir -Force | Out-Null
Invoke-WebRequest -Uri $UpdaterUrl -OutFile $UpdaterPath -UseBasicParsing -TimeoutSec 120

if ($CosignSource -and (Test-Path -LiteralPath $CosignSource -PathType Leaf)) {
    Copy-Item -LiteralPath $CosignSource -Destination $CosignPath -Force
} elseif (-not (Test-Path -LiteralPath $CosignPath -PathType Leaf)) {
    Invoke-WebRequest -Uri $CosignUrl -OutFile $CosignPath -UseBasicParsing -TimeoutSec 600
}

$cosignHash = (Get-FileHash -LiteralPath $CosignPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($cosignHash -ne $ExpectedCosignSha256) { throw "Cosign SHA-256 mismatch: $cosignHash" }
$versionText = (& $CosignPath version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch 'GitVersion:\s+v3\.1\.3\b') { throw 'Expected Cosign v3.1.3.' }

$chrome = Join-Path $env:LOCALAPPDATA 'Fast Sector\Fast Browser\Application\chrome.exe'
$chromiumVersion = '0.0.0.0'
if (Test-Path -LiteralPath $chrome -PathType Leaf) {
    $rawChromeVersion = (Get-Item -LiteralPath $chrome).VersionInfo.FileVersion
    $m = [regex]::Match([string]$rawChromeVersion, '\d+(?:\.\d+){1,3}')
    if (-not $m.Success) { throw "Cannot determine installed Chromium version from: $rawChromeVersion" }
    $chromiumVersion = ([version]$m.Value).ToString()
}

$state = [ordered]@{
    schema = 1
    releaseVersion = $BaselineVersion
    chromiumVersion = $chromiumVersion
    installerSha256 = ''
    installedUtc = [DateTimeOffset]::UtcNow.ToString('o')
} | ConvertTo-Json
[IO.File]::WriteAllText($StatePath, $state + [Environment]::NewLine, $Utf8NoBom)

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskName = 'Fast Browser Update Check'
$taskRun = '"' + $psExe + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $UpdaterPath + '"'
& schtasks.exe /Create /TN $taskName /TR $taskRun /SC HOURLY /MO 1 /ST 00:47 /F | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to create Fast Browser Update Check scheduled task.' }

$protocolRoot = 'HKCU:\Software\Classes\fastbrowser-update'
New-Item -Path $protocolRoot -Force | Out-Null
Set-Item -Path $protocolRoot -Value 'URL:Fast Browser Update Protocol'
New-ItemProperty -Path $protocolRoot -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
$commandKey = Join-Path $protocolRoot 'shell\open\command'
New-Item -Path $commandKey -Force | Out-Null
$protocolCommand = '"' + $psExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $UpdaterPath + '" -Interactive "%1"'
Set-Item -Path $commandKey -Value $protocolCommand

$programs = [Environment]::GetFolderPath('Programs')
$shortcutDir = Join-Path $programs 'Fast Browser'
New-Item -ItemType Directory -Path $shortcutDir -Force | Out-Null
$shortcutPath = Join-Path $shortcutDir 'Check for Fast Browser Updates.lnk'
$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $psExe
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $UpdaterPath + '" -Interactive'
$shortcut.WorkingDirectory = $UpdaterDir
if (Test-Path -LiteralPath $chrome -PathType Leaf) { $shortcut.IconLocation = $chrome + ',0' }
$shortcut.Save()

Write-Host 'FAST BROWSER UPDATER INSTALLED' -ForegroundColor Green
Write-Host "Task: $taskName"
Write-Host "Manual shortcut: $shortcutPath"