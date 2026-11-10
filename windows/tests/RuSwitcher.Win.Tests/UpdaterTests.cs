using System.Security.Cryptography;
using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class UpdaterTests
{
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
