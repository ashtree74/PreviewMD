using PreviewMD.Windows.Core;
using Xunit;

namespace PreviewMD.Windows.Core.Tests;

public class RendererChecksumTests
{
    [Fact]
    public void VerifyThrowsWhenOneCopiedByteDiffers()
    {
        var root = Directory.CreateTempSubdirectory("previewmd-checksum-");
        var copied = Path.Combine(root.FullName, "renderer");
        var badges = Path.Combine(copied, "badges");
        Directory.CreateDirectory(badges);
        var file = Path.Combine(badges, "one.svg");
        File.WriteAllBytes(file, new byte[] { 1, 2, 3, 4 });
        var manifest = Path.Combine(root.FullName, "renderer.sha256");

        try
        {
            var text = RendererChecksum.Format(copied);
            Assert.Equal(
                "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a  badges/one.svg\n",
                text);
            File.WriteAllText(manifest, text);
            var bytes = File.ReadAllBytes(file);
            bytes[0] = 9;
            File.WriteAllBytes(file, bytes);

            var exception = Assert.Throws<RendererChecksumException>(() => RendererChecksum.Verify(copied, manifest));
            Assert.Equal("renderer checksum mismatch for badges/one.svg", exception.Message);
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    [Fact]
    public void BundledRendererMatchesTheManifest()
    {
        var repo = RepoRoot();
        var directory = Path.Combine(repo, "Sources", "PreviewMD", "Resources", "Renderer");
        var manifest = Path.Combine(repo, "ports", "windows", "renderer.sha256");
        var expected = File.ReadAllText(manifest).Replace("\r\n", "\n", StringComparison.Ordinal);

        Assert.Equal(expected, RendererChecksum.Format(directory));
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var renderer = Path.Combine(dir.FullName, "Sources", "PreviewMD", "Resources", "Renderer");
            if (File.Exists(Path.Combine(dir.FullName, "Package.swift")) && Directory.Exists(renderer))
                return dir.FullName;
            dir = dir.Parent;
        }

        throw new InvalidOperationException("The PreviewMD repo root was not found from the test output.");
    }
}
