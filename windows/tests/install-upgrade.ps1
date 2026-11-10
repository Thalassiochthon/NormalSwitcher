$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Join-Path $env:RUNNER_TEMP 'NormalSwitcher-smoke'
$destination = Join-Path $root 'Installed App'
New-Item -ItemType Directory -Force $root | Out-Null
$iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) { choco install innosetup --no-progress -y }

function Build-Installer($version, $binary) {
    & $iscc "/O$root" "/DSmokeBuild=1" "/DMyAppVersion=$version" "/DSourceExe=$binary" windows/installer/RuSwitcher.iss | Out-Host
    return Join-Path $root "NormalSwitcher-Setup-$version.exe"
}
function Wait-ForWindow($class, $title) {
    for ($i = 0; $i -lt 30; $i++) {
        $window = if ($null -eq $class) {
            [NormalSwitcherSmoke]::FindWindowByTitle([IntPtr]::Zero, $title)
        } else { [NormalSwitcherSmoke]::FindWindow($class, $title) }
        if ($window -ne [IntPtr]::Zero) { return $window }
        Start-Sleep -Seconds 1
    }
    throw "Window did not appear: $title"
}

$previous = Join-Path $root 'previous'
dotnet publish windows/src/RuSwitcher.Win/RuSwitcher.Win.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:Version=0.0.1 -p:DefineConstants=NORMALSWITCHER_UPDATE_SMOKE -o $previous --nologo
$first = Build-Installer '0.0.1' (Join-Path $previous 'NormalSwitcher.exe')
$next = Build-Installer '0.1.0' (Resolve-Path 'publish/NormalSwitcher.exe').Path
$settingsDir = Join-Path $env:LOCALAPPDATA 'NormalSwitcher'
$settingsPath = Join-Path $settingsDir 'settings.json'
$exe = Join-Path $destination 'NormalSwitcher.exe'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NormalSwitcherSmoke {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW", ExactSpelling = true)]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
'@

$server = $null
try {
    $installer = Start-Process $first -ArgumentList @('/VERYSILENT', '/SP-', '/NORESTART', "/DIR=`"$destination`"") -PassThru
    if (-not $installer.WaitForExit(60000) -or $installer.ExitCode -ne 0) { throw 'First installation failed' }
    if ((Get-Item $exe).VersionInfo.FileVersion -ne '0.0.1.0') { throw 'Initial version mismatch' }
    $uninstall = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{D729A5A6-DE1C-5068-A3B9-97BED831D11B}_is1'
    if ($uninstall.InstallLocation.TrimEnd('\') -ne $destination) { throw 'Updater cannot find the registered install directory' }

    $web = New-Item -ItemType Directory -Force (Join-Path $root 'web')
    $download = New-Item -ItemType Directory -Force (Join-Path $web.FullName 'download/win-v0.1.0')
    Copy-Item $next $download.FullName
    @{
        version = '0.1.0'
        url = 'http://127.0.0.1:18443/tag/win-v0.1.0'
        sha256 = (Get-FileHash $next -Algorithm SHA256).Hash
    } | ConvertTo-Json | Set-Content -Encoding ascii (Join-Path $web.FullName 'version.json')
    $server = Start-Process python -WorkingDirectory $web.FullName -ArgumentList @('-m', 'http.server', '18443', '--bind', '127.0.0.1') -PassThru
    for ($i = 0; $i -lt 20; $i++) {
        try { Invoke-WebRequest 'http://127.0.0.1:18443/version.json' -TimeoutSec 2 | Out-Null; break }
        catch { if ($i -eq 19) { throw }; Start-Sleep -Seconds 1 }
    }

    New-Item -ItemType Directory -Force $settingsDir | Out-Null
    @{
        ConvertWholeLine = $true
        CheckUpdatesEnabled = $true
        UiLanguage = 'en'
        WordEndOnEnter = $true
        WordEndOnTab = $true
        RemoteDesktopMode = $true
        Abbreviations = @{ zz = 'NormalSwitcher' }
        ClipboardHistoryEnabled = $true
        ClipboardHistoryPersistent = $true
        ClipboardCustomShortcut = @{ Key = 120; Modifiers = 6 }
        DebugLogging = $true
        GlobalShortcuts = @{ ChangeCase = @{ Key = 119; Modifiers = 6 } }
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding ascii $settingsPath
    $running = Start-Process -FilePath $exe -PassThru
    Wait-ForWindow 'NormalSwitcherTrayWindow' 'NormalSwitcher' | Out-Null
    $prompt = Wait-ForWindow '#32770' 'NormalSwitcher — Update available'
    if (-not [NormalSwitcherSmoke]::PostMessage($prompt, 0x0111, [IntPtr]6, [IntPtr]::Zero)) {
        throw 'Could not confirm the update'
    }
    if (-not $running.WaitForExit(60000)) { throw 'The updater did not hand off to the installer' }

    $restarted = $null
    for ($i = 0; $i -lt 60 -and -not $restarted; $i++) {
        $restarted = Get-Process NormalSwitcher -ErrorAction SilentlyContinue | Where-Object Path -eq $exe
        if (-not $restarted) { Start-Sleep -Seconds 1 }
    }
    if (-not $restarted) { throw 'NormalSwitcher did not restart after the update' }
    Wait-ForWindow 'NormalSwitcherTrayWindow' 'NormalSwitcher' | Out-Null
    if ((Get-Item $exe).VersionInfo.FileVersion -ne '0.1.0.0') { throw 'Updated version mismatch' }
    $saved = Get-Content -Raw $settingsPath | ConvertFrom-Json
    if (-not $saved.ConvertWholeLine -or -not $saved.CheckUpdatesEnabled -or $saved.UiLanguage -ne 'en') {
        throw 'Update changed user settings'
    }

    Write-Host 'Update prompt, download, installer handoff, restart and settings preservation verified.'
    $secondLaunch = Start-Process -FilePath $exe -PassThru
    if (-not $secondLaunch.WaitForExit(10000)) { throw 'A second instance did not exit' }
    $settingsWindow = Wait-ForWindow $null 'NormalSwitcher — Settings'
    [NormalSwitcherSmoke]::PostMessage($settingsWindow, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Write-Host 'Update prompt, download, installer handoff, restart, settings preservation and reopening Settings verified.'
    try { dotnet run --project windows/tests/NativeInputSmoke/NativeInputSmoke.csproj -c Release }
    finally {
        $debugLog = Join-Path $settingsDir 'debug.log'
        if (Test-Path $debugLog) { Get-Content $debugLog }
    }
}
finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Get-Process NormalSwitcher -ErrorAction SilentlyContinue | Where-Object Path -eq $exe | Stop-Process -Force
}
