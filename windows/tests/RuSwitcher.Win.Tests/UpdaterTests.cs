using System.Security.Cryptography;
using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class UpdaterTests
{
    [Theory]
    [InlineData("https://github.com/antonjas/NormalSwitcher/releases/tag/win-v0.2.7", true)]
    [InlineData("https://github.com/Thalassiochthon/NormalSwitcher/releases/tag/win-v0.2.7", true)]
    [InlineData("https://github.com/Thalassiochthon/NormalSwitcher/releases/tag/win-v0.2.8", false)]
    [InlineData("https://github.com/other/NormalSwitcher/releases/tag/win-v0.2.7", false)]
    public void AcceptsOnlyKnownReleaseUrlsForRequestedVersion(string url, bool accepted)
    {
        Assert.Equal(accepted, Updater.MatchesReleaseUrl(url, "0.2.7"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task StagesInstallerOnlyIfChecksumMatches(bool tampered)
    {
        byte[] expected = "installer bytes"u8.ToArray();
        string checksum = Convert.ToHexString(SHA256.HashData(expected));
        byte[] received = tampered ? "modified bytes!"u8.ToArray() : expected;
        using var source = new MemoryStream(received);
        using var output = new MemoryStream();
        if (tampered)
            await Assert.ThrowsAsync<IOException>(() => Updater.CopyVerifiedInstallerAsync(source, output, checksum));
        else
        {
            await Updater.CopyVerifiedInstallerAsync(source, output, checksum);
            Assert.Equal(expected, output.ToArray());
        }
    }
}
