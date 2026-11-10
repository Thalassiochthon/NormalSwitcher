using Microsoft.Win32;
using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows.Forms;
using RuSwitcher.Win.Tray;
using RuSwitcher.Win.UI;
using static RuSwitcher.Win.Native.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Installs verified updates through Inno Setup for installed copies. Portable copies continue
/// to use the download page. Automatic checks are opt-in and update the tray menu without opening a dialog.
/// </summary>
internal static class Updater
{
#if NORMALSWITCHER_UPDATE_SMOKE
    // Only the disposable first build in the Windows integration test uses the fixture server.
    private const string FeedUrl = "http://127.0.0.1:18443/version.json";
    private const string ReleaseUrl = "http://127.0.0.1:18443/tag/win-v";
    private const string InstallerUrl = "http://127.0.0.1:18443/download/win-v";
#else
    private const string FeedUrl = "https://raw.githubusercontent.com/Thalassiochthon/NormalSwitcher/windows-preview/windows/version.json";

    private const string ReleaseUrl = "https://github.com/Thalassiochthon/NormalSwitcher/releases/tag/win-v";
    private const string InstallerUrl = "https://github.com/Thalassiochthon/NormalSwitcher/releases/download/win-v";
#endif
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{D729A5A6-DE1C-5068-A3B9-97BED831D11B}_is1";
    private const long MaxInstallerBytes = 256L * 1024 * 1024;

    // Single-flight: repeated tray clicks / an overlapping launch check must not spawn concurrent
    // HTTP checks that each write Settings and stack message boxes.
    private static bool _busy;
    private static bool _showResult;

    private static string? AvailableVersion { get; set; }
    internal static string MenuTitle => AvailableVersion is { } version
        ? L10n.T("tray.update.available", version)
        : L10n.T("tray.update");

    private sealed class Feed
    {
        public string version { get; set; } = "";
        public string url { get; set; } = "";
        public string? notes { get; set; }
        public string? sha256 { get; set; }
    }

    /// <summary>Current app version (from the assembly; kept in sync with windows/version.json).</summary>
    public static Version Current =>
        Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0);

    internal static string CurrentRelease
    {
        get
        {
            var information = Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0];
            return information != null && TryRelease(information, out _, out _) ? information : Current.ToString(3);
        }
    }

    private static bool TryRelease(string? value, out Version version, out int beta)
    {
        version = new Version(0, 0, 0);
        beta = 0;
        if (string.IsNullOrEmpty(value)) return false;
        var parts = value.Split("-beta.", StringSplitOptions.None);
        if (parts.Length > 2 || !Version.TryParse(parts[0], out var core) ||
            core.Build < 0 || core.Revision >= 0 || core.ToString(3) != parts[0]) return false;
        if (parts.Length == 2 && (!int.TryParse(parts[1], out beta) || beta <= 0 ||
            beta.ToString(System.Globalization.CultureInfo.InvariantCulture) != parts[1])) return false;
        version = core;
        return true;
    }

    internal static int CompareReleases(string left, string right)
    {
        if (!TryRelease(left, out var a, out int aBeta) || !TryRelease(right, out var b, out int bBeta))
            throw new ArgumentException("Invalid release version");
        int core = a.CompareTo(b);
        if (core != 0 || aBeta == bBeta) return core;
        if (aBeta == 0) return 1;
        if (bBeta == 0) return -1;
        return aBeta.CompareTo(bBeta);
    }

    internal static void UpdatePreferenceChanged()
    {
        if (!Settings.Current.ReceiveBetaUpdates && AvailableVersion?.Contains("-beta.", StringComparison.Ordinal) == true)
            AvailableVersion = null;
        Settings.Current.LastUpdateCheckTicks = 0;
        Settings.Current.Save();
    }

    /// <summary>Checks once shortly after launch and periodically while the app is open.</summary>
    public static void CheckOnLaunch(SynchronizationContext ui)
    {
        if (!Settings.Current.CheckUpdatesEnabled) return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(5000);
            ui.Post(state =>
            {
                if (Settings.Current.CheckUpdatesEnabled) _ = CheckAsync(silent: true);
            }, null);
        });
    }

    public static void CheckPeriodic()
    {
        var settings = Settings.Current;
        long now = DateTime.UtcNow.Ticks;
        long last = settings.LastUpdateCheckTicks;
        if (settings.CheckUpdatesEnabled && (last < 0 || last > now || now - last >= TimeSpan.TicksPerHour))
            _ = CheckAsync(silent: true);
    }

    public static void CheckNow(SynchronizationContext ui) =>
        ui.Post(state => { _ = CheckAsync(silent: false); }, null);

    // Calls and continuations run on the UI thread. A click during a background request
    // reuses that request and asks for the result instead of opening a second request.
    private static async Task CheckAsync(bool silent)
    {
        if (!silent) _showResult = true;
        if (_busy) return;
        _busy = true;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("NormalSwitcher-Win-Updater");
            Task<Feed?> stableRequest = ReadFeedAsync(http, FeedUrl, beta: false);
            Task<Feed?> betaRequest = Settings.Current.ReceiveBetaUpdates
                ? ReadFeedAsync(http, FeedUrl.Replace("/version.json", "/version-beta.json"), beta: true)
                : Task.FromResult<Feed?>(null);
            var feed = await stableRequest;
            var beta = await betaRequest;
            if (Settings.Current.ReceiveBetaUpdates && beta != null &&
                (feed == null || CompareReleases(beta.version, feed.version) > 0))
                feed = beta;

            if (feed == null)
            {
                if (_showResult) MessageBox.Show(L10n.T("upd.error"), L10n.T("app.name"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            Settings.Current.LastUpdateCheckTicks = DateTime.UtcNow.Ticks;
            Settings.Current.Save();

            bool newer = CompareReleases(feed.version, CurrentRelease) > 0;
            AvailableVersion = newer && Settings.Current.SkippedVersion != feed.version
                ? feed.version : null;
            if (_showResult && newer)
            {
                await PromptUpdateAsync(feed);
            }
            else if (_showResult)
            {
                MessageBox.Show(
                    L10n.T("upd.uptodate", CurrentRelease),
                    L10n.T("app.name"), MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }
        finally
        {
            _showResult = false;
            _busy = false;
        }
    }

    private static async Task<Feed?> ReadFeedAsync(HttpClient http, string url, bool beta)
    {
        try
        {
            var feed = JsonSerializer.Deserialize<Feed>(await http.GetStringAsync(url));
            return feed != null && TryRelease(feed.version, out _, out int revision) &&
                (revision > 0) == beta && MatchesReleaseUrl(feed.url, feed.version) ? feed : null;
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or JsonException)
        {
            return null;
        }
    }

    internal static bool MatchesReleaseUrl(string url, string version)
    {
        if (string.Equals(url, ReleaseUrl + version, StringComparison.Ordinal)) return true;
#if NORMALSWITCHER_UPDATE_SMOKE
        return false;
#else
        return string.Equals(url, "https://github.com/antonjas/NormalSwitcher/releases/tag/win-v" + version,
            StringComparison.Ordinal);
#endif
    }

    private const string UpdateMode = "--install-update";
    private static string UpdateDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NormalSwitcher", "Updates");
    private static string HelperPath => Path.Combine(UpdateDirectory, "NormalSwitcher.Update.exe");

    private static async Task PromptUpdateAsync(Feed feed)
    {
        if (InstalledExecutable() is { } installed &&
            string.Equals(installed, Environment.ProcessPath, StringComparison.OrdinalIgnoreCase) &&
            IsInstallerHash(feed.sha256))
        {
            try
            {
                Directory.CreateDirectory(UpdateDirectory);
                await Task.Run(() => File.Copy(installed, HelperPath, overwrite: true));
                var start = new ProcessStartInfo(HelperPath);
                start.ArgumentList.Add(UpdateMode);
                start.ArgumentList.Add(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));
                start.ArgumentList.Add(feed.version);
                start.ArgumentList.Add(feed.sha256!);
                string notes = feed.notes ?? "";
                start.ArgumentList.Add(notes[..Math.Min(notes.Length, 4000)]);
                using var helper = Process.Start(start) ?? throw new IOException("Could not start updater");
                await helper.WaitForExitAsync();
                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
            {
                MessageBox.Show(L10n.T("upd.helper.error"), L10n.T("app.name"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        string body = L10n.T("upd.available.body", feed.version, CurrentRelease);
        if (!string.IsNullOrWhiteSpace(feed.notes)) body += "\n\n" + feed.notes;
        body += "\n\n" + L10n.T("upd.open");
        if (MessageBox.Show(body, L10n.T("upd.available.title"),
                MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes)
            OpenRelease(ReleaseUrl + feed.version);
    }

    internal static bool RunHelper(string[] args)
    {
        if (args.Length == 0 || args[0] != UpdateMode) return false;
        if (args.Length != 5 || !int.TryParse(args[1], out int pid) || pid <= 0 ||
            !TryRelease(args[2], out _, out _) || CompareReleases(args[2], CurrentRelease) <= 0 ||
            !IsInstallerHash(args[3]) ||
            !string.Equals(Environment.ProcessPath, HelperPath, StringComparison.OrdinalIgnoreCase) ||
            InstalledExecutable() is not { } installed)
            return true;

        ApplicationConfiguration.Initialize();
        using var dialog = new UpdateForm(args[2], CurrentRelease, args[4]);
        dialog.DownloadPage += () => OpenRelease(ReleaseUrl + args[2]);
        dialog.Install += async () =>
        {
            bool appClosed = false;
            string? installer = null;
            try
            {
                installer = await DownloadInstallerAsync(args[2], args[3], dialog.ReportDownload);
                dialog.ShowStage("upd.installing");
                appClosed = await CloseForUpdateAsync(pid, installed);
                string directory = Path.GetDirectoryName(installed)!;
                var start = new ProcessStartInfo(installer);
                start.ArgumentList.Add("/VERYSILENT");
                start.ArgumentList.Add("/SUPPRESSMSGBOXES");
                start.ArgumentList.Add("/SP-");
                start.ArgumentList.Add("/NORESTART");
                start.ArgumentList.Add("/NOCLOSEAPPLICATIONS");
                start.ArgumentList.Add("/NORESTARTAPPLICATIONS");
                start.ArgumentList.Add("/DIR=" + directory);
                using var setup = Process.Start(start) ?? throw new IOException("Could not start setup");
                await setup.WaitForExitAsync();
                if (setup.ExitCode != 0) throw new IOException($"Setup exited with code {setup.ExitCode}");
                dialog.ShowStage("upd.restarting");
                StartApp(installed);
                dialog.Complete();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or
                HttpRequestException or OperationCanceledException or InvalidOperationException or System.ComponentModel.Win32Exception)
            {
                if (appClosed)
                {
                    try { StartApp(installed); }
                    catch (Exception restartError) when (restartError is IOException or System.ComponentModel.Win32Exception) { }
                }
                dialog.ShowError();
            }
            finally
            {
                if (installer != null) RemoveUpdateFile(installer);
            }
        };
        dialog.ShowDialog();
        return true;
    }

    private static async Task<bool> CloseForUpdateAsync(int pid, string installed)
    {
        Process original;
        try { original = Process.GetProcessById(pid); }
        catch (ArgumentException) { return true; }
        using (original)
        {
            if (original.HasExited) return true;
            IntPtr tray = FindWindowW(TrayIcon.WindowClass, "NormalSwitcher");
            GetWindowThreadProcessId(tray, out uint windowPid);
            if (windowPid != pid || !string.Equals(original.MainModule?.FileName, installed,
                    StringComparison.OrdinalIgnoreCase) ||
                PostMessageW(tray, WM_UPDATE_QUIT, IntPtr.Zero, IntPtr.Zero) == IntPtr.Zero)
                throw new IOException("Could not close NormalSwitcher");
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await original.WaitForExitAsync(timeout.Token);
            return true;
        }
    }

    private static void StartApp(string installed)
    {
        using var app = Process.Start(new ProcessStartInfo(installed)
        {
            WorkingDirectory = Path.GetDirectoryName(installed)!
        }) ?? throw new IOException("Could not restart NormalSwitcher");
    }

    private static void OpenRelease(string url)
    {
        try { using var browser = Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { /* The update remains available for a later check. */ }
    }

    private static string? InstalledExecutable()
    {
        try
        {
            using var entry = Registry.CurrentUser.OpenSubKey(UninstallKey);
            if (entry?.GetValue("InstallLocation") is not string directory || !Path.IsPathFullyQualified(directory))
                return null;
            return Path.GetFullPath(Path.Combine(directory, "NormalSwitcher.exe"));
        }
        catch { return null; }
    }

    private static bool IsInstallerHash(string? hash) =>
        hash is { Length: 64 } && hash.All(Uri.IsHexDigit);

    private static async Task<string> DownloadInstallerAsync(string version, string expectedHash, Action<int?> report)
    {
        var progress = new Progress<int?>(report);
        string installer = Path.Combine(UpdateDirectory, "NormalSwitcher-Setup.exe");
        string partial = installer + ".part";
        try
        {
            using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(5));
            using var http = new HttpClient();
            using var response = await http.GetAsync(InstallerUrl + version + "/NormalSwitcher-Setup-" + version + ".exe",
                HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength is > MaxInstallerBytes)
                throw new IOException("Update is too large");
            await using var source = await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
            await using (var output = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None,
                65536, useAsync: true))
            {
                long? length = response.Content.Headers.ContentLength;
                int previous = -1;
                await CopyVerifiedInstallerAsync(source, output, expectedHash, deadline.Token, bytes =>
                {
                    if (length is not > 0) return;
                    int percent = (int)Math.Min(100, bytes * 100 / length.Value);
                    if (percent == previous) return;
                    previous = percent;
                    ((IProgress<int?>)progress).Report(percent);
                }).ConfigureAwait(false);
            }
            File.Move(partial, installer, overwrite: true);
            return installer;
        }
        finally { RemoveUpdateFile(partial); }
    }

    private static void RemoveUpdateFile(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    internal static async Task CopyVerifiedInstallerAsync(Stream source, Stream output, string expectedHash,
        CancellationToken cancellationToken = default, Action<long>? report = null)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buffer = new byte[65536];
        long size = 0;
        int read;
        while ((read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
        {
            size += read;
            if (size > MaxInstallerBytes) throw new IOException("Update is too large");
            hash.AppendData(buffer.AsSpan(0, read));
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            report?.Invoke(size);
        }
        if (!CryptographicOperations.FixedTimeEquals(hash.GetHashAndReset(), Convert.FromHexString(expectedHash)))
            throw new IOException("Installer checksum does not match");
    }
}
