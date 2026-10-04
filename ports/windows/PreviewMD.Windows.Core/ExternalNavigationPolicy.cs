namespace PreviewMD.Windows.Core;

public static class ExternalNavigationPolicy
{
    public static bool ShouldLaunchExternally(string? uri)
    {
        if (string.IsNullOrWhiteSpace(uri))
            return false;
        if (!Uri.TryCreate(uri, UriKind.Absolute, out var parsed))
            return false;

        if (parsed.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase)
            || parsed.Scheme.Equals("mailto", StringComparison.OrdinalIgnoreCase))
            return true;

        if (!parsed.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase))
            return false;

        return !parsed.Host.Equals("previewmd.assets", StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsAssetsShell(string? uri)
    {
        if (!Uri.TryCreate(uri, UriKind.Absolute, out var parsed))
            return false;
        if (!parsed.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase))
            return false;
        if (!parsed.Host.Equals("previewmd.assets", StringComparison.OrdinalIgnoreCase))
            return false;

        var path = parsed.AbsolutePath;
        return path == "/" || path.Equals("/index.html", StringComparison.OrdinalIgnoreCase);
    }
}
