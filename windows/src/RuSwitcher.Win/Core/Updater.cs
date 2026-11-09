using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Windows.Forms;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Checks GitHub for a newer version — the Windows counterpart of the macOS <c>UpdateChecker</c>.
/// Reads the same kind of feed (windows/version.json) and, when a newer version exists, offers to
/// open the download page. It does NOT self-replace the running exe (Windows makes in-place swap of a
/// running file awkward and risky); it defers to the signed installer, mirroring the macOS
/// browser-download fallback. Auto-check is throttled to once per 24h and can be turned off; the
/// manual check always runs. Fully defensive: a network/parse failure is silent on auto-check.
/// </summary>
internal static class Updater
{
    private const string FeedUrl = "https://raw.githubusercontent.com/rashn/RuSwitcher/main/windows/version.json";

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
            await CheckAsync(silent: true, ui);
        });
    }

    /// <summary>Manual check (from the tray/menu) — always reports the result.</summary>
    public static void CheckNow(SynchronizationContext ui) => _ = CheckAsync(silent: false, ui);

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

    private static async Task CheckAsync(bool silent, SynchronizationContext ui)
    {
        if (Interlocked.Exchange(ref _busy, 1) == 1) return;   // a check is already in flight
        try
        {
            Feed? feed = null;
            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
                http.DefaultRequestHeaders.UserAgent.ParseAdd("RuSwitcher-Win-Updater");
                string json = await http.GetStringAsync(FeedUrl);
                feed = JsonSerializer.Deserialize<Feed>(json);
            }
            catch
            {
                if (!silent) ui.Post(_ => MessageBox.Show(
                    L10n.T("upd.error"), L10n.T("app.name"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning), null);
                return;
            }

            if (feed == null || string.IsNullOrWhiteSpace(feed.version)) return;

            // All Settings mutation happens on the UI (message-loop) thread — never race the
            // hook/tray/winevent writers from this background task.
            ui.Post(_ => { Settings.Current.LastUpdateCheckTicks = DateTime.UtcNow.Ticks; Settings.Current.Save(); }, null);

            if (!Version.TryParse(feed.version, out var latest)) return;

            if (latest > Current)
            {
                if (silent && Settings.Current.SkippedVersion == feed.version) return;   // user skipped this one
                ui.Post(_ => PromptUpdate(feed), null);
            }
            else if (!silent)
            {
                ui.Post(_ => MessageBox.Show(
                    L10n.T("upd.uptodate", Current.ToString(3)),
                    L10n.T("app.name"), MessageBoxButtons.OK, MessageBoxIcon.Information), null);
            }
        }
        finally { Interlocked.Exchange(ref _busy, 0); }
    }

    private static void PromptUpdate(Feed feed)
    {
        string body = L10n.T("upd.available.body", feed.version, Current.ToString(3));
        if (!string.IsNullOrWhiteSpace(feed.notes)) body += "\n\n" + feed.notes;
        body += "\n\n" + L10n.T("upd.open");

        var r = MessageBox.Show(body, L10n.T("upd.available.title"),
            MessageBoxButtons.YesNo, MessageBoxIcon.Information);
        if (r == DialogResult.Yes)
        {
            string open = string.IsNullOrWhiteSpace(feed.url)
                ? "https://github.com/rashn/RuSwitcher/releases/latest" : feed.url;
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(open) { UseShellExecute = true }); }
            catch { /* ignore */ }
        }
        else
        {
            // "No" = skip this version until a newer one appears.
            Settings.Current.SkippedVersion = feed.version;
            Settings.Current.Save();
        }
    }
}
