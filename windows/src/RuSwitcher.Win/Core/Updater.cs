using Microsoft.Win32;
using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows.Forms;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Installs verified updates through Inno Setup for installed copies. Portable copies continue
/// to use the download page. Automatic checks are opt-in and throttled to once per day.
/// </summary>
internal static class Updater
{
    private const string FeedUrl = "https://raw.githubusercontent.com/antonjas/NormalSwitcher/windows-preview/windows/version.json";

    private const string ReleaseUrl = "https://github.com/antonjas/NormalSwitcher/releases/tag/win-v";
    private const string InstallerUrl = "https://github.com/antonjas/NormalSwitcher/releases/download/win-v";
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

    private static async Task PromptUpdateAsync(Feed feed)
    {
        string? directory = InstalledDirectory();
        bool canInstall = directory != null && IsInstallerHash(feed.sha256);
        string body = L10n.T("upd.available.body", feed.version, Current.ToString(3));
        if (!string.IsNullOrWhiteSpace(feed.notes)) body += "\n\n" + feed.notes;
        body += "\n\n" + L10n.T(canInstall ? "upd.install" : "upd.open");

        var r = MessageBox.Show(body, L10n.T("upd.available.title"),
            MessageBoxButtons.YesNo, MessageBoxIcon.Information);
        if (r == DialogResult.Yes)
        {
            if (!canInstall)
            {
                OpenRelease(feed.url);
                return;
            }
            try
            {
                string installer = await DownloadInstallerAsync(feed.version, feed.sha256!);
                var start = new ProcessStartInfo(installer) { UseShellExecute = true };
                start.ArgumentList.Add("/SILENT");
                start.ArgumentList.Add("/SP-");
                start.ArgumentList.Add("/NORESTART");
                start.ArgumentList.Add("/NORESTARTAPPLICATIONS");
                start.ArgumentList.Add("/NORMALSWITCHERUPDATE=1");
                start.ArgumentList.Add("/DIR=" + directory);
                using var setup = Process.Start(start) ?? throw new IOException("Could not start setup");
                Native.Win32.PostQuitMessage(0);
            }
            catch
            {
                if (MessageBox.Show(L10n.T("upd.install.error"), L10n.T("app.name"),
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
                    OpenRelease(feed.url);
            }
        }
        else
        {
            // "No" = skip this version until a newer one appears.
            Settings.Current.SkippedVersion = feed.version;
            Settings.Current.Save();
        }
    }

    private static void OpenRelease(string url)
    {
        try { using var browser = Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { /* The update remains available for a later check. */ }
    }

    private static string? InstalledDirectory()
    {
        try
        {
            using var entry = Registry.CurrentUser.OpenSubKey(UninstallKey);
            if (entry?.GetValue("InstallLocation") is not string directory || !Path.IsPathFullyQualified(directory))
                return null;
            string installedExe = Path.GetFullPath(Path.Combine(directory, "NormalSwitcher.exe"));
            return string.Equals(installedExe, Environment.ProcessPath, StringComparison.OrdinalIgnoreCase)
                ? directory : null;
        }
        catch { return null; }
    }

    private static bool IsInstallerHash(string? hash) =>
        hash is { Length: 64 } && hash.All(Uri.IsHexDigit);

    private static async Task<string> DownloadInstallerAsync(string version, string expectedHash)
    {
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "NormalSwitcher", "Updates");
        Directory.CreateDirectory(directory);
        string installer = Path.Combine(directory, "NormalSwitcher-Setup.exe");
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
                await CopyVerifiedInstallerAsync(source, output, expectedHash, deadline.Token).ConfigureAwait(false);
            }
            File.Move(partial, installer, overwrite: true);
            return installer;
        }
        finally
        {
            try { File.Delete(partial); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    internal static async Task CopyVerifiedInstallerAsync(Stream source, Stream output, string expectedHash,
        CancellationToken cancellationToken = default)
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
        }
        if (!CryptographicOperations.FixedTimeEquals(hash.GetHashAndReset(), Convert.FromHexString(expectedHash)))
            throw new IOException("Installer checksum does not match");
    }
}
