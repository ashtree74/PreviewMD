using System.Diagnostics;
using PreviewMD.Windows.Core;
using Xunit;

namespace PreviewMD.Windows.Core.Tests;

public class ImagePolicyTests
{
    private const string Root = @"C:\previewmd-slice-root\notes";

    [Fact]
    public void ParentTraversalOutsideTheRootEscapesTheJail()
    {
        var decision = ImagePolicy.Decide("../pic.png", Root, _ => new FileFacts(true, 4, ".png"));

        Assert.Equal(new ImageDecision.Refused(ImageRefusal.EscapesJail), decision);
    }

    [Fact]
    public void RelativePngUnderTheRootIsAllowed()
    {
        var decision = ImagePolicy.Decide(
            "pic.png",
            Root,
            path => path == @"C:\previewmd-slice-root\notes\pic.png"
                ? new FileFacts(true, 4, ".png")
                : null);

        var allowed = Assert.IsType<ImageDecision.Allowed>(decision);
        Assert.Equal(@"C:\previewmd-slice-root\notes\pic.png", allowed.Path);
    }

    [Fact]
    public void EncodedCustomSchemeSourceResolvesUnderTheRoot()
    {
        var decision = ImagePolicy.Decide(
            "previewmd-local-image://resource?source=Renderer%2Fbadges%2Fmacos%2Fbadge.svg",
            @"C:\previewmd-slice-root\WebAssets",
            _ => new FileFacts(true, 80, ".svg"));

        var allowed = Assert.IsType<ImageDecision.Allowed>(decision);
        Assert.Equal(@"C:\previewmd-slice-root\WebAssets\Renderer\badges\macos\badge.svg", allowed.Path);
    }

    [Fact]
    public void SvgBadgeUnderTheRootIsAllowed()
    {
        var decision = ImagePolicy.Decide(
            "Renderer/badges/macos/badge.svg",
            @"C:\previewmd-slice-root\WebAssets",
            _ => new FileFacts(true, 80, ".svg"));

        var allowed = Assert.IsType<ImageDecision.Allowed>(decision);
        Assert.Equal(@"C:\previewmd-slice-root\WebAssets\Renderer\badges\macos\badge.svg", allowed.Path);
    }

    [Fact]
    public void MarkdownExtensionIsUnsupported()
    {
        var decision = ImagePolicy.Decide("readme.md", Root, _ => new FileFacts(true, 20, ".md"));

        Assert.Equal(new ImageDecision.Refused(ImageRefusal.UnsupportedType), decision);
    }

    [Fact]
    public void DocumentFolderAllowsARelativeImageAndRefusesEscape()
    {
        var parent = Directory.CreateTempSubdirectory("previewmd-jail-");
        var notes = Directory.CreateDirectory(Path.Combine(parent.FullName, "notes"));
        var img = Directory.CreateDirectory(Path.Combine(notes.FullName, "img"));
        var picture = Path.Combine(img.FullName, "pic.png");
        var png = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
        File.WriteAllBytes(picture, png);
        var outside = Path.Combine(parent.FullName, "secret.png");
        File.WriteAllBytes(outside, new byte[] { 1, 2, 3, 4 });
        var fileLink = Path.Combine(img.FullName, "escape.png");
        var directoryLink = Path.Combine(notes.FullName, "out");

        try
        {
            var allowed = ImagePolicy.Decide("img/pic.png", notes.FullName, ImageInspection.Read);
            var allowedPath = Assert.IsType<ImageDecision.Allowed>(allowed);
            Assert.Equal(png, File.ReadAllBytes(allowedPath.Path));

            var parentEscape = ImagePolicy.Decide("../secret.png", notes.FullName, ImageInspection.Read);
            Assert.Equal(new ImageDecision.Refused(ImageRefusal.EscapesJail), parentEscape);

            var absoluteEscape = ImagePolicy.Decide(outside, notes.FullName, ImageInspection.Read);
            Assert.Equal(new ImageDecision.Refused(ImageRefusal.EscapesJail), absoluteEscape);

            CreateDirectoryLink(directoryLink, parent.FullName);
            var directoryEscape = ImagePolicy.Decide("out/secret.png", notes.FullName, ImageInspection.Read);
            Assert.Equal(new ImageDecision.Refused(ImageRefusal.EscapesJail), directoryEscape);

            if (TryCreateFileLink(fileLink, outside))
            {
                var fileEscape = ImagePolicy.Decide("img/escape.png", notes.FullName, ImageInspection.Read);
                Assert.Equal(new ImageDecision.Refused(ImageRefusal.EscapesJail), fileEscape);

                var alias = Path.Combine(notes.FullName, "alias.png");
                Assert.True(TryCreateFileLink(alias, picture));
                var aliased = ImagePolicy.Decide("alias.png", notes.FullName, ImageInspection.Read);
                var aliasPath = Assert.IsType<ImageDecision.Allowed>(aliased);
                Assert.Equal(png, File.ReadAllBytes(aliasPath.Path));
                RemoveLink(alias);
            }
        }
        finally
        {
            RemoveLink(directoryLink);
            RemoveLink(fileLink);
            parent.Delete(recursive: true);
        }
    }

    private static bool TryCreateFileLink(string linkPath, string targetPath)
    {
        try
        {
            File.CreateSymbolicLink(linkPath, targetPath);
            return true;
        }
        catch (IOException) when (OperatingSystem.IsWindows())
        {
            return false;
        }
    }

    private static void CreateDirectoryLink(string linkPath, string targetPath)
    {
        if (!OperatingSystem.IsWindows())
        {
            Directory.CreateSymbolicLink(linkPath, targetPath);
            return;
        }

        using var process = new Process();
        process.StartInfo.FileName = "cmd.exe";
        process.StartInfo.Arguments = "/c mklink /J \"" + linkPath + "\" \"" + targetPath + "\"";
        process.StartInfo.UseShellExecute = false;
        process.StartInfo.CreateNoWindow = true;
        process.Start();
        process.WaitForExit();
        if (process.ExitCode != 0)
            throw new InvalidOperationException("The directory junction was not created.");
    }

    private static void RemoveLink(string linkPath)
    {
        if (Directory.Exists(linkPath))
        {
            Directory.Delete(linkPath, recursive: false);
            return;
        }

        if (File.Exists(linkPath))
            File.Delete(linkPath);
    }

    [Fact]
    public void LengthAboveOneHundredMegabytesIsTooLarge()
    {
        var decision = ImagePolicy.Decide(
            "big.png",
            Root,
            _ => new FileFacts(true, 100L * 1024 * 1024 + 1, ".png"));

        Assert.Equal(new ImageDecision.Refused(ImageRefusal.FileTooLarge), decision);
    }
}
