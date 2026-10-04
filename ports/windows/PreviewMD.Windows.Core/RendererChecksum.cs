using System.Security.Cryptography;

namespace PreviewMD.Windows.Core;

public sealed class RendererChecksumException : Exception
{
    public RendererChecksumException(string message) : base(message) { }
}

public static class RendererChecksum
{
    public static string Format(string directory)
    {
        var lines = HashDirectory(directory)
            .OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => pair.Value + "  " + pair.Key);
        return string.Join('\n', lines) + "\n";
    }

    public static void Verify(string directory, string manifestPath)
    {
        var expected = Parse(File.ReadAllText(manifestPath));
        var actual = HashDirectory(directory);
        var paths = expected.Keys
            .Concat(actual.Keys)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(path => path, StringComparer.Ordinal);

        foreach (var path in paths)
        {
            expected.TryGetValue(path, out var expectedHash);
            actual.TryGetValue(path, out var actualHash);
            if (!string.Equals(expectedHash, actualHash, StringComparison.Ordinal))
                throw new RendererChecksumException("renderer checksum mismatch for " + path);
        }
    }

    private static Dictionary<string, string> Parse(string manifest)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        var lines = manifest.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        foreach (var raw in lines)
        {
            if (raw.Length == 0)
                continue;
            var split = raw.IndexOf("  ", StringComparison.Ordinal);
            if (split != 64)
                throw new RendererChecksumException("renderer checksum manifest line is invalid: " + raw);
            var hash = raw[..split];
            var path = raw[(split + 2)..];
            if (path.Length == 0 || path.Contains('\\') || !IsLowerHex(hash))
                throw new RendererChecksumException("renderer checksum manifest line is invalid: " + raw);
            map[path] = hash;
        }

        return map;
    }

    private static bool IsLowerHex(string hash)
    {
        foreach (var character in hash)
        {
            var digit = character is >= '0' and <= '9' || character is >= 'a' and <= 'f';
            if (!digit)
                return false;
        }

        return true;
    }

    private static Dictionary<string, string> HashDirectory(string directory)
    {
        var root = Path.GetFullPath(directory);
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            var relative = Path.GetRelativePath(root, file).Replace('\\', '/');
            var hash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(file))).ToLowerInvariant();
            map[relative] = hash;
        }

        return map;
    }
}
