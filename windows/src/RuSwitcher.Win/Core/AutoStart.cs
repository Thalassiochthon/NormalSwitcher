using Microsoft.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>Launch-at-login via the per-user Run registry key — the Windows counterpart of the
/// macOS login item. Fully defensive (registry access can fail under policy).</summary>
internal static class AutoStart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "NormalSwitcher";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string command && File.Exists(ExecutablePath(command));
        }
        catch { return false; }
    }

    public static void RepairMissingExecutable()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key?.GetValue(ValueName) is string command && !File.Exists(ExecutablePath(command))
                && Environment.ProcessPath is { } executable)
                key.SetValue(ValueName, $"\"{executable}\"");
        }
        catch { /* Registry may be managed by Windows policy. */ }
    }

    private static string ExecutablePath(string command) => command.Trim().Trim('"');

    public static bool SetEnabled(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true)
                            ?? Registry.CurrentUser.CreateSubKey(RunKey);
            if (key is null) return false;
            if (on)
            {
                string? exe = Environment.ProcessPath;
                if (string.IsNullOrEmpty(exe)) return false;
                key.SetValue(ValueName, $"\"{exe}\"");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
            return true;
        }
        catch { return false; }
    }
}
