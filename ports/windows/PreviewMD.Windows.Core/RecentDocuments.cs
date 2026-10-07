namespace PreviewMD.Windows.Core;

public static class RecentDocuments
{
    public const int Limit = 10;

    public static bool IsMarkdownPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return false;

        var extension = Path.GetExtension(path);
        return extension.Equals(".md", StringComparison.OrdinalIgnoreCase)
            || extension.Equals(".markdown", StringComparison.OrdinalIgnoreCase);
    }

    public static string? FirstMarkdown(IEnumerable<string> paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        foreach (var path in paths)
        {
            if (IsMarkdownPath(path))
                return Path.GetFullPath(path);
        }

        return null;
    }

    public static IReadOnlyList<string> Remember(IReadOnlyList<string> current, string path)
    {
        ArgumentNullException.ThrowIfNull(current);
        var fullPath = Path.GetFullPath(path);
        var remembered = new List<string> { fullPath };
        foreach (var existing in current)
        {
            if (remembered.Count == Limit)
                break;
            if (!existing.Equals(fullPath, StringComparison.OrdinalIgnoreCase))
                remembered.Add(existing);
        }

        return remembered;
    }
}
