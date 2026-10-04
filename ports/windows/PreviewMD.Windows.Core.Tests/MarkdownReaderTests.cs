using System.Text;
using PreviewMD.Windows.Core;
using Xunit;

namespace PreviewMD.Windows.Core.Tests;

public class MarkdownReaderTests
{
    [Fact]
    public void ReadStripsTheBomAndNormalizesNewlines()
    {
        var body = Encoding.UTF8.GetBytes("a\r\nb\rc");
        var bytes = new byte[body.Length + 3];
        bytes[0] = 0xEF;
        bytes[1] = 0xBB;
        bytes[2] = 0xBF;
        body.CopyTo(bytes, 3);

        Assert.Equal("a\nb\nc", MarkdownReader.Read(bytes));
    }
}
