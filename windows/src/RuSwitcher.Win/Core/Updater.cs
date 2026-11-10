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
/// to use the download page. Automatic checks are opt-in and throttled to once per day.
/// </summary>
internal static class Updater
{
#if NORMALSWITCHER_UPDATE_SMOKE
    // Only the disposable first build in the Windows integration test uses the fixture server.
    private const string FeedUrl = "http://127.0.0.1:18443/version.json";
    private const string ReleaseUrl = "http://127.0.0.1:18443/tag/win-v";
    private const string InstallerUrl = "http://127.0.0.1:18443/download/win-v";
#else
    private const string FeedUrl = "https://raw.githubusercontent.com/antonjas/NormalSwitcher/windows-preview/windows/version.json";

    private const string ReleaseUrl = "https://github.com/antonjas/NormalSwitcher/releases/tag/win-v";
    private const string InstallerUrl = "https://github.com/antonjas/NormalSwitcher/releases/download/win-v";
#endif
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{D729A5A6-DE1C-5068-A3B9-97BED831D11B}_is1";
    private const long MaxInstallerBytes = 256L * 1024 * 1024;

    // Single-flight: repeated tray clicks / an overlapping launch check must not spawn concurrent
    // HTTP checks that each write Settings and stack message boxes.
    private static int _busy;

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

    /// <summary>Kick off a silent auto-check on launch, on a background task after a short delay,
    /// respecting the once-a-day throttle and the setting. Never blocks startup.</summary>
    public static void CheckOnLaunch(SynchronizationContext ui)
    {
        if (!ShouldAutoCheck()) return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(5000);
            QueueCheck(silent: true, ui);
        });
    }

    /// <summary>Manual check (from the tray/menu) — always reports the result.</summary>
    public static void CheckNow(SynchronizationContext ui) => QueueCheck(silent: false, ui);

    private static void QueueCheck(bool silent, SynchronizationContext ui) =>
        ui.Post(state => { _ = CheckAsync(silent); }, null);

    private static bool ShouldAutoCheck()
    {
        var s = Settings.Current;
        if (!s.CheckUpdatesEnabled) return false;
        if (s.LastUpdateCheckTicks != 0)
        {
            var last = new DateTime(s.LastUpdateCheckTicks, DateTimeKind.Utc);
            if (DateTime.UtcNow - last < TimeSpan.FromHours(24)) return false;
        }
        return true;
    }

    private static async Task CheckAsync(bool silent)
    {
        if (Interlocked.Exchange(ref _busy, 1) == 1) return;   // a check is already in flight
        try
        {
            Feed? feed = null;
            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
                http.DefaultRequestHeaders.UserAgent.ParseAdd("NormalSwitcher-Win-Updater");
                string json = await http.GetStringAsync(FeedUrl);
                feed = JsonSerializer.Deserialize<Feed>(json);
            }
            catch
            {
                if (!silent) MessageBox.Show(
                    L10n.T("upd.error"), L10n.T("app.name"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            if (feed == null || !Version.TryParse(feed.version, out var latest)
                || latest.Build < 0 || latest.Revision >= 0 || latest.ToString(3) != feed.version
                || !string.Equals(feed.url, ReleaseUrl + feed.version, StringComparison.Ordinal))
            {
                if (!silent) MessageBox.Show(L10n.T("upd.error"), L10n.T("app.name"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            Settings.Current.LastUpdateCheckTicks = DateTime.UtcNow.Ticks;
            Settings.Current.Save();

            if (latest > Current)
            {
                if (silent && Settings.Current.SkippedVersion == feed.version) return;   // user skipped this one
                await PromptUpdateAsync(feed);
            }
            else if (!silent)
            {
                MessageBox.Show(
                    L10n.T("upd.uptodate", Current.ToString(3)),
                    L10n.T("app.name"), MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }
        finally { Interlocked.Exchange(ref _busy, 0); }
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

        string body = L10n.T("upd.available.body", feed.version, Current.ToString(3));
        if (!string.IsNullOrWhiteSpace(feed.notes)) body += "\n\n" + feed.notes;
        body += "\n\n" + L10n.T("upd.open");
        if (MessageBox.Show(body, L10n.T("upd.available.title"),
                MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes)
            OpenRelease(feed.url);
    }

    internal static bool RunHelper(string[] args)
    {
        if (args.Length == 0 || args[0] != UpdateMode) return false;
        if (args.Length != 5 || !int.TryParse(args[1], out int pid) || pid <= 0 ||
            !Version.TryParse(args[2], out var version) || version.Build < 0 ||
            version.Revision >= 0 || version.ToString(3) != args[2] || version <= Current ||
            !IsInstallerHash(args[3]) ||
            !string.Equals(Environment.ProcessPath, HelperPath, StringComparison.OrdinalIgnoreCase) ||
            InstalledExecutable() is not { } installed)
            return true;

        ApplicationConfiguration.Initialize();
        using var dialog = new UpdateForm(args[2], Current.ToString(3), args[4]);
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
