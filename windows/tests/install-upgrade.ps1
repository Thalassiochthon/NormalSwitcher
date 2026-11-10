$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Join-Path $env:RUNNER_TEMP 'NormalSwitcher-smoke'
$destination = Join-Path $root 'Installed App'
New-Item -ItemType Directory -Force $root | Out-Null
$iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) { choco install innosetup --no-progress -y }

function Run-Installer($file, [bool] $update) {
    $arguments = @('/VERYSILENT', '/SP-', '/NORESTART', '/NORESTARTAPPLICATIONS', "/DIR=`"$destination`"")
    if ($update) { $arguments += '/NORMALSWITCHERUPDATE=1' }
    $process = Start-Process -FilePath $file -ArgumentList $arguments -PassThru
    if (-not $process.WaitForExit(60000)) { throw 'Installer did not finish' }
    if ($process.ExitCode -ne 0) { throw "Installer exited with $($process.ExitCode)" }
}
function Build-Installer($version, $binary) {
    & $iscc "/O$root" "/DMyAppVersion=$version" "/DSourceExe=$binary" windows/installer/RuSwitcher.iss | Out-Host
    return Join-Path $root "NormalSwitcher-Setup-$version.exe"
}

$previous = Join-Path $root 'previous'
dotnet publish windows/src/RuSwitcher.Win/RuSwitcher.Win.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:Version=0.0.1 -o $previous --nologo
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
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
'@

function Wait-ForTray {
    for ($i = 0; $i -lt 30; $i++) {
        $window = [NormalSwitcherSmoke]::FindWindow('NormalSwitcherTrayWindow', 'NormalSwitcher')
        if ($window -ne [IntPtr]::Zero) { return $window }
        Start-Sleep -Seconds 1
    }
    throw 'NormalSwitcher did not create its tray window'
}

try {
    Run-Installer $first $false
    if ((Get-Item $exe).VersionInfo.FileVersion -ne '0.0.1.0') { throw 'Initial version mismatch' }
    $uninstall = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{D729A5A6-DE1C-5068-A3B9-97BED831D11B}_is1'
    if ($uninstall.InstallLocation.TrimEnd('\') -ne $destination) { throw 'Updater cannot find the registered install directory' }

    New-Item -ItemType Directory -Force $settingsDir | Out-Null
    '{"ConvertWholeLine":true,"CheckUpdatesEnabled":false}' | Set-Content -Encoding ascii $settingsPath
    $original = Get-FileHash $settingsPath
    $running = Start-Process -FilePath $exe -PassThru
    $window = Wait-ForTray
    if (-not [NormalSwitcherSmoke]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw 'Could not close the installed app'
    }
    if (-not $running.WaitForExit(10000)) { throw 'The app did not exit before upgrade' }

    Run-Installer $next $true
    if ((Get-Item $exe).VersionInfo.FileVersion -ne '0.1.0.0') { throw 'Updated version mismatch' }
    if ((Get-FileHash $settingsPath).Hash -ne $original.Hash) { throw 'Update changed user settings' }
    $restarted = $null
    for ($i = 0; $i -lt 30 -and -not $restarted; $i++) {
        $restarted = Get-Process NormalSwitcher -ErrorAction SilentlyContinue | Where-Object Path -eq $exe
        if (-not $restarted) { Start-Sleep -Seconds 1 }
    }
    if (-not $restarted) { throw 'NormalSwitcher did not restart after the update' }
    Wait-ForTray | Out-Null
    Write-Host 'Installer upgrade, launch of the new version, and settings preservation verified.'
}
finally {
    Get-Process NormalSwitcher -ErrorAction SilentlyContinue | Where-Object Path -eq $exe | Stop-Process -Force
}
