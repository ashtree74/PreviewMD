using System.Security;

namespace PreviewMD.Windows.Core;

public readonly record struct FileFacts(bool IsRegularFile, long Length, string Extension);

public enum ImageRefusal
{
    InvalidRequest,
    EscapesJail,
    NotRegularFile,
    UnsupportedType,
    FileTooLarge,
}

public abstract record ImageDecision
{
    private ImageDecision() { }

    public sealed record Allowed(string Path) : ImageDecision;

    public sealed record Refused(ImageRefusal Reason) : ImageDecision;
}

public static class ImagePolicy
{
    public const long MaximumBytes = 100L * 1024 * 1024;

    internal static Func<string, FileSystemInfo?> DirectoryLinkTarget { get; set; } =
        static path => Directory.ResolveLinkTarget(path, returnFinalTarget: true);

    internal static Func<string, FileSystemInfo?> FileLinkTarget { get; set; } =
        static path => File.ResolveLinkTarget(path, returnFinalTarget: true);

    private static readonly HashSet<string> AllowedExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "svg",
        "png",
        "jpg",
        "jpeg",
        "gif",
        "webp",
        "bmp",
        "ico",
    };

    public static ImageDecision Decide(string encodedSource, string imageRoot, Func<string, FileFacts?> inspect)
    {
        ArgumentNullException.ThrowIfNull(inspect);
        if (!TryDecodeSource(encodedSource, out var source) || string.IsNullOrWhiteSpace(imageRoot))
            return new ImageDecision.Refused(ImageRefusal.InvalidRequest);

        string fullPath;
        try
        {
            var rootFull = Path.GetFullPath(imageRoot);
            fullPath = Resolve(source, rootFull);
            if (!IsInside(rootFull, fullPath))
                return new ImageDecision.Refused(ImageRefusal.EscapesJail);

            var canonicalRoot = Canonicalize(rootFull);
            var canonicalPath = Canonicalize(fullPath);
            if (!IsInside(canonicalRoot, canonicalPath))
                return new ImageDecision.Refused(ImageRefusal.EscapesJail);
            fullPath = canonicalPath;
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException or IOException or UnauthorizedAccessException)
        {
            return new ImageDecision.Refused(ImageRefusal.InvalidRequest);
        }

        var facts = inspect(fullPath);
        if (facts is null || !facts.Value.IsRegularFile)
            return new ImageDecision.Refused(ImageRefusal.NotRegularFile);

        var extension = facts.Value.Extension.Trim();
        if (extension.StartsWith('.'))
            extension = extension[1..];
        if (!AllowedExtensions.Contains(extension))
            return new ImageDecision.Refused(ImageRefusal.UnsupportedType);

        if (facts.Value.Length > MaximumBytes)
            return new ImageDecision.Refused(ImageRefusal.FileTooLarge);

        return new ImageDecision.Allowed(fullPath);
    }

    private static bool IsInside(string rootFull, string candidate)
    {
        var rootPrefix = rootFull.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;
        return candidate.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase);
    }

    private static string Canonicalize(string fullPath)
    {
        fullPath = Path.GetFullPath(fullPath);
        var root = Path.GetPathRoot(fullPath);
        if (string.IsNullOrEmpty(root))
            throw new IOException("The path has no root.");

        var current = FollowLink(root);
        var relative = Path.GetRelativePath(root, fullPath);
        if (relative == ".")
            return current;

        foreach (var segment in relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))
        {
            if (segment.Length == 0 || segment == ".")
                continue;
            current = FollowLink(Path.Combine(current, segment));
        }

        return current;
    }

    private static string FollowLink(string path)
    {
        var fullPath = Path.GetFullPath(path);
        if (IsVolumeRoot(fullPath))
            return fullPath;

        try
        {
            FileSystemInfo? link = null;
            if (Directory.Exists(fullPath))
                link = DirectoryLinkTarget(fullPath);
            else if (File.Exists(fullPath))
                link = FileLinkTarget(fullPath);

            if (link is null || link.FullName.Length == 0)
                return fullPath;

            return Path.GetFullPath(link.FullName);
        }
        catch (DirectoryNotFoundException)
        {
            return fullPath;
        }
    }

    private static bool IsVolumeRoot(string fullPath)
    {
        var root = Path.GetPathRoot(fullPath);
        if (string.IsNullOrEmpty(root))
            return false;

        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        return string.Equals(
            Path.TrimEndingDirectorySeparator(fullPath),
            Path.TrimEndingDirectorySeparator(root),
            comparison);
    }

    private static string Resolve(string source, string rootFull)
    {
        if (source.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
        {
            if (!Uri.TryCreate(source, UriKind.Absolute, out var fileUri) || !fileUri.IsFile)
                throw new ArgumentException("The file URI is invalid.");
            return Path.GetFullPath(fileUri.LocalPath);
        }

        if (HasNonFileScheme(source))
            throw new ArgumentException("The image source is not a local path.");

        return Path.GetFullPath(Path.Combine(rootFull, source));
    }

    private static bool HasNonFileScheme(string source)
    {
        var colon = source.IndexOf(':');
        if (colon <= 0)
            return false;
        if (colon == 1 && Path.IsPathRooted(source))
            return false;
        return true;
    }

    private static bool TryDecodeSource(string? encodedSource, out string source)
    {
        source = "";
        if (string.IsNullOrWhiteSpace(encodedSource))
            return false;

        var value = encodedSource.Trim();
        if (value.Contains("://", StringComparison.Ordinal))
        {
            const string marker = "source=";
            var index = value.IndexOf(marker, StringComparison.Ordinal);
            if (index < 0)
                return false;
            value = value[(index + marker.Length)..];
            var amp = value.IndexOf('&');
            if (amp >= 0)
                value = value[..amp];
            var hash = value.IndexOf('#');
            if (hash >= 0)
                value = value[..hash];
        }

        try
        {
            source = Uri.UnescapeDataString(value);
        }
        catch (UriFormatException)
        {
            return false;
        }

        return source.Length > 0;
    }
}

public static class ImageInspection
{
    public static FileFacts? Read(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists)
                return null;
            var isDirectory = (info.Attributes & FileAttributes.Directory) != 0;
            var length = isDirectory ? 0 : info.Length;
            return new FileFacts(!isDirectory, length, info.Extension);
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or UnauthorizedAccessException or NotSupportedException or SecurityException)
        {
            return null;
        }
    }
}
