using PreviewMD.Windows.Core;
using Xunit;

namespace PreviewMD.Windows.Core.Tests;

public class RecentDocumentsTests
{
    [Fact]
    public void NewestPathIsFirstAndARepeatDoesNotDuplicate()
    {
        var first = RecentDocuments.Remember(Array.Empty<string>(), @"C:\docs\a.md");
        var second = RecentDocuments.Remember(first, @"C:\docs\b.md");
        var repeated = RecentDocuments.Remember(second, @"C:\docs\a.md");

        Assert.Equal(new[] { @"C:\docs\a.md" }, first);
        Assert.Equal(new[] { @"C:\docs\b.md", @"C:\docs\a.md" }, second);
        Assert.Equal(new[] { @"C:\docs\a.md", @"C:\docs\b.md" }, repeated);
    }

    [Fact]
    public void RememberKeepsTenPaths()
    {
        IReadOnlyList<string> current = Array.Empty<string>();
        for (var index = 0; index < 12; index++)
            current = RecentDocuments.Remember(current, $@"C:\docs\n{index}.md");

        Assert.Equal(10, current.Count);
        Assert.Equal(@"C:\docs\n11.md", current[0]);
        Assert.Equal(@"C:\docs\n2.md", current[9]);
    }

    [Fact]
    public void FirstMarkdownSkipsOtherFiles()
    {
        var chosen = RecentDocuments.FirstMarkdown(new[] { @"C:\docs\pic.png", @"C:\docs\note.md" });

        Assert.Equal(@"C:\docs\note.md", chosen);
        Assert.Null(RecentDocuments.FirstMarkdown(new[] { @"C:\docs\pic.png" }));
    }
}
