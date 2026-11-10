using System.Security.Cryptography;
using RuSwitcher.Win.Core;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class LayoutSoundTests
{
    [Fact]
    public void AllSelectableSoundsHaveDistinctBundledWaveData()
    {
        var fingerprints = new HashSet<string>();
        foreach (string sound in Sound.Choices.Where(sound => sound != Sound.Default))
        {
            using var stream = typeof(Sound).Assembly.GetManifestResourceStream($"LayoutSounds.{sound}.wav");
            Assert.NotNull(stream);
            using var reader = new BinaryReader(stream);
            Assert.Equal("RIFF", new string(reader.ReadChars(4)));
            reader.ReadUInt32();
            Assert.Equal("WAVE", new string(reader.ReadChars(4)));
            Assert.True(fingerprints.Add(Convert.ToHexString(SHA256.HashData(stream))), sound);
        }
    }

    [Theory]
    [InlineData("beep", "tap")]
    [InlineData("exclamation", "drop")]
    [InlineData("question", "rise")]
    [InlineData("hand", "wood")]
    [InlineData(null, "default")]
    public void OlderSettingsStillResolve(string? previous, string expected) =>
        Assert.Equal(expected, Sound.Resolve(previous));
}
