using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class AutoStartTests
{
    [Fact]
    public void LogonCommandQuotesTheExecutablePathAndMarksTheLaunch()
    {
        const string path = @"C:\Installed App\NormalSwitcher.exe";
        string command = AutoStart.CommandFor(path);
        Assert.Equal($"\"{path}\" --startup", command);
        Assert.Equal(path, AutoStart.ExecutablePath(command));
    }

    [Theory]
    [InlineData("\"C:\\Installed App\\NormalSwitcher.exe\" ")]
    [InlineData("C:\\Installed App\\NormalSwitcher.exe")]
    public void ReadsExistingLogonRegistrations(string command) =>
        Assert.Equal(@"C:\Installed App\NormalSwitcher.exe", AutoStart.ExecutablePath(command));
}
