param(
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
$ChromePath = Join-Path $env:LOCALAPPDATA 'Fast Sector\Fast Browser\Application\chrome.exe'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Path $UpdaterDir -Force | Out-Null
Invoke-WebRequest -Uri ($UpdaterUrl + '?ts=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -OutFile $UpdaterPath -UseBasicParsing -TimeoutSec 120

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
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$actionArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $UpdaterPath + '"'
$action = New-ScheduledTaskAction -Execute $psExe -Argument $actionArgs
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Hours 1)
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName 'Fast Browser Update Check' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

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
$shortcut.IconLocation = $ChromePath + ',0'
$shortcut.Save()

Write-Host 'FAST BROWSER UPDATER INSTALLED' -ForegroundColor Green