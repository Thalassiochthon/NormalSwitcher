using System.Drawing;
using System.Windows.Forms;
using RuSwitcher.Win.Core;
using RuSwitcher.Win.UI;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class SettingsFormTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SettingsUsesTopTabsAndKeepsEverySectionAccessible(bool largerNavigationText)
    {
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ui = new Thread(() =>
        {
            try
            {
                CheckLayouts(largerNavigationText);
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

    private static void CheckLayouts(bool largerNavigationText)
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
                var tabs = Assert.IsType<TabControl>(Assert.Single(form.Controls.Find("settingsTabs", true)));
                using var largerFont = new Font("Segoe UI", 17F, FontStyle.Bold);
                if (largerNavigationText)
                {
                    foreach (TabPage page in tabs.TabPages) page.Font = form.Font;
                    tabs.Font = largerFont;
                }

                form.Show();
                Application.DoEvents();
                Assert.Equal(FormBorderStyle.FixedDialog, form.FormBorderStyle);
                Assert.False(form.MaximizeBox);
                Assert.True(form.ControlBox);
                Assert.Null(form.AcceptButton);
                Assert.Null(form.CancelButton);
                Assert.DoesNotContain(Descendants(form).OfType<Button>(), button => button.Text == L10n.T("settings.close"));

                Assert.Equal(TabAlignment.Top, tabs.Alignment);
                var hint = Assert.IsType<Label>(Assert.Single(form.Controls.Find("settingsSaveHint", true)));
                Assert.Equal(L10n.T("settings.autosave"), hint.Text);
                Assert.True(hint.Visible);
                Assert.True(hint.Top >= tabs.Bottom);
                var normal = form.ClientSize;
                CheckNavigation(tabs);
                // Multiple tab rows reduce the content height at larger navigation font sizes.
                CheckPages(tabs, expectFit: !largerNavigationText && normal.Height >= form.LogicalToDeviceUnits(570));

                // Reduced working areas keep the footer visible and let pages scroll independently.
                form.ClientSize = new Size(normal.Width, normal.Height - form.LogicalToDeviceUnits(160));
                CheckPages(tabs, expectFit: false);
                Assert.True(hint.Visible);
                Assert.True(hint.Bottom <= hint.Parent!.ClientSize.Height);

                form.ClientSize = new Size(form.LogicalToDeviceUnits(480), normal.Height);
                Application.DoEvents();
                Assert.True(tabs.RowCount > 1);
                CheckNavigation(tabs);
            }
        }
        finally
        {
            settings.UiLanguage = previousLanguage;
        }
    }

    private static void CheckNavigation(TabControl tabs)
    {
        using var graphics = tabs.CreateGraphics();
        Assert.Equal(7, tabs.TabCount);
        for (int index = 0; index < tabs.TabCount; index++)
        {
            var tab = tabs.TabPages[index];
            var bounds = tabs.GetTabRect(index);
            var text = TextRenderer.MeasureText(graphics, tab.Text, tabs.Font, Size.Empty,
                TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
            Assert.True(tabs.ClientRectangle.Contains(bounds), $"{tab.Text}: tab {bounds} outside {tabs.ClientRectangle}");
            Assert.True(bounds.Width >= text.Width && bounds.Height >= text.Height,
                $"{tab.Text}: tab {bounds.Size}, requires {text}");
        }
    }

    private static void CheckPages(TabControl tabs, bool expectFit)
    {
        foreach (string section in new[] { "general", "hotkeys", "automatic", "clipboard", "indicators", "advanced", "about" })
        {
            string title = L10n.T("settings.tab." + section);
            TabPage page = Assert.IsType<TabPage>(tabs.TabPages[section]);
            Assert.Equal(title, page.Text);
            tabs.SelectedTab = page;
            Application.DoEvents();
            Assert.True(page.Visible, title);
            Assert.False(page.HorizontalScroll.Visible, title);
            if (expectFit)
                Assert.False(page.VerticalScroll.Visible, title);
        }
    }

    private static IEnumerable<Control> Descendants(Control container) =>
        container.Controls.Cast<Control>().SelectMany(child => new[] { child }.Concat(Descendants(child)));
}
