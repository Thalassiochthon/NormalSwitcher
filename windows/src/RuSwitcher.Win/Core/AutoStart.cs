using Microsoft.Win32;

namespace RuSwitcher.Win.Core;

/// <summary>Launch-at-login via the per-user Run registry key — the Windows counterpart of the
/// macOS login item. Fully defensive (registry access can fail under policy).</summary>
internal static class AutoStart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "NormalSwitcher";
    internal const string LogonArgument = "--startup";

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
            {
                string replacement = CommandFor(executable);
                if (replacement.Length <= 260) key.SetValue(ValueName, replacement);
            }
        }
        catch { /* Registry may be managed by Windows policy. */ }
    }

    internal static string CommandFor(string executable) => $"\"{executable}\" {LogonArgument}";

    internal static string ExecutablePath(string command)
    {
        string trimmed = command.Trim();
        if (!trimmed.StartsWith('"')) return trimmed;
        int endQuote = trimmed.IndexOf('"', 1);
        return endQuote > 0 ? trimmed[1..endQuote] : "";
    }

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
                string command = CommandFor(exe);
                // Run entries accept a command line of up to 260 characters.
                if (command.Length > 260) return false;
                key.SetValue(ValueName, command);
                return Equals(key.GetValue(ValueName), command);
            }
            key.DeleteValue(ValueName, throwOnMissingValue: false);
            return key.GetValue(ValueName) is null;
        }
        catch { return false; }
    }
}
