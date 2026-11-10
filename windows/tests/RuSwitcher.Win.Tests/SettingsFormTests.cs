using System.Drawing;
using System.Windows.Forms;
using RuSwitcher.Win.Core;
using RuSwitcher.Win.UI;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class SettingsFormTests
{
    [Fact]
    public async Task FixedSettingsWindowKeepsEverySectionWithinItsWidth()
    {
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ui = new Thread(() =>
        {
            try
            {
                CheckLayouts();
                finished.SetResult();
            }
            catch (Exception error)
            {
                finished.SetException(error);
            }
        }) { IsBackground = true };
        ui.SetApartmentState(ApartmentState.STA);
        ui.Start();
        await finished.Task.WaitAsync(TimeSpan.FromSeconds(30));
    }

    private static void CheckLayouts()
    {
        var settings = Settings.Current;
        string previousLanguage = settings.UiLanguage;
        try
        {
            foreach (string language in new[] { "en", "ru" })
            {
                settings.UiLanguage = language;
                using var history = new ClipboardHistory(IntPtr.Zero, _ => { });
                using var shortcuts = new GlobalShortcuts(IntPtr.Zero);
                using var form = new SettingsForm(history, shortcuts, "", keyboardHookReady: true);
                form.Show();
                Application.DoEvents();
                Assert.Equal(FormBorderStyle.FixedDialog, form.FormBorderStyle);
                Assert.False(form.MaximizeBox);
                var normal = form.ClientSize;
                CheckPages(form, expectFit: normal.Height >= form.LogicalToDeviceUnits(570));

                // Exercise the same layout when the working area leaves less vertical room.
                form.ClientSize = new Size(normal.Width, normal.Height - form.LogicalToDeviceUnits(160));
                CheckPages(form, expectFit: false);
            }
        }
        finally
        {
            settings.UiLanguage = previousLanguage;
        }
    }

    private static void CheckPages(SettingsForm form, bool expectFit)
    {
        foreach (string section in new[] { "general", "hotkeys", "automatic", "clipboard", "advanced", "about" })
        {
            string title = L10n.T("settings.tab." + section);
            Button tab = Descendants(form).OfType<Button>().Single(button => button.Text == title);
            tab.PerformClick();
            Application.DoEvents();
            Panel page = Assert.IsAssignableFrom<Panel>(Assert.Single(form.Controls.Find(section, true)));
            Assert.True(page.Visible, title);
            Assert.False(page.HorizontalScroll.Visible, title);
            if (expectFit)
                Assert.False(page.VerticalScroll.Visible, title);
        }
    }

    private static IEnumerable<Control> Descendants(Control container) =>
        container.Controls.Cast<Control>().SelectMany(child => new[] { child }.Concat(Descendants(child)));
}
