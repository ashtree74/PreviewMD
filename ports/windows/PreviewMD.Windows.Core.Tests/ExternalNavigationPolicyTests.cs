using PreviewMD.Windows.Core;
using Xunit;

namespace PreviewMD.Windows.Core.Tests;

public class ExternalNavigationPolicyTests
{
    [Fact]
    public void HttpAndMailtoLaunchExternally()
    {
        Assert.True(ExternalNavigationPolicy.ShouldLaunchExternally("http://example.com/notes"));
        Assert.True(ExternalNavigationPolicy.ShouldLaunchExternally("mailto:adam@jesion.pl"));
        Assert.True(ExternalNavigationPolicy.ShouldLaunchExternally("https://example.com/image.png"));
    }

    [Fact]
    public void AssetsShellFileAndLocalImageDoNotLaunchExternally()
    {
        Assert.False(ExternalNavigationPolicy.ShouldLaunchExternally("https://previewmd.assets/index.html"));
        Assert.False(ExternalNavigationPolicy.ShouldLaunchExternally("https://previewmd.assets/index.html#section"));
        Assert.False(ExternalNavigationPolicy.ShouldLaunchExternally("file:///C:/notes/other.md"));
        Assert.False(ExternalNavigationPolicy.ShouldLaunchExternally("previewmd-local-image://resource?source=pic.png"));
        Assert.False(ExternalNavigationPolicy.ShouldLaunchExternally("other.md"));
    }

    [Fact]
    public void OnlyTheAssetsShellDocumentStays()
    {
        Assert.True(ExternalNavigationPolicy.IsAssetsShell("https://previewmd.assets/index.html"));
        Assert.True(ExternalNavigationPolicy.IsAssetsShell("https://previewmd.assets/index.html#section"));
        Assert.False(ExternalNavigationPolicy.IsAssetsShell("https://previewmd.assets/other.md"));
        Assert.False(ExternalNavigationPolicy.IsAssetsShell("file:///C:/notes/other.md"));
    }
}
