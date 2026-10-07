namespace PreviewMD.Windows.Core;

internal sealed class DocumentSessionController
{
    private int _revision;

    public DocumentSession Current { get; private set; } = new DocumentSession.Empty();

    public DocumentSession ReplaceFile(string path, string markdown)
    {
        var fullPath = Path.GetFullPath(path);
        var imageRoot = Path.GetDirectoryName(fullPath)
            ?? throw new InvalidOperationException("The document has no parent directory.");
        Current = new DocumentSession.File(fullPath, markdown, NextRevision(), imageRoot);
        return Current;
    }

    public DocumentSession ReplaceShowcase(string markdown, string imageRoot)
    {
        Current = new DocumentSession.Showcase(markdown, NextRevision(), Path.GetFullPath(imageRoot));
        return Current;
    }

    public DocumentSession Clear()
    {
        Current = new DocumentSession.Empty();
        return Current;
    }

    private int NextRevision() => ++_revision;
}
