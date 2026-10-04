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
    public void LengthAboveOneHundredMegabytesIsTooLarge()
    {
        var decision = ImagePolicy.Decide(
            "big.png",
            Root,
            _ => new FileFacts(true, 100L * 1024 * 1024 + 1, ".png"));

        Assert.Equal(new ImageDecision.Refused(ImageRefusal.FileTooLarge), decision);
    }
}
