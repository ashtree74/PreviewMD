using System.Text;

namespace PreviewMD.Windows.Core;

public static class MarkdownReader
{
    public static string Read(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        var start = 0;
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            start = 3;

        var utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
        var text = utf8.GetString(bytes, start, bytes.Length - start);
        return text.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace("\r", "\n", StringComparison.Ordinal);
    }

    public static string ReadFile(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        return Read(File.ReadAllBytes(path));
    }
}
