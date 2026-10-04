namespace PreviewMD.Windows.Core;

public abstract class DocumentSession
{
    private DocumentSession() { }

    public abstract T Match<T>(Func<Empty, T> empty, Func<File, T> file, Func<Showcase, T> showcase);

    public sealed class Empty : DocumentSession
    {
        public override T Match<T>(Func<Empty, T> empty, Func<File, T> file, Func<Showcase, T> showcase) => empty(this);
    }

    public sealed class File : DocumentSession
    {
        public File(string absolutePath, string markdown, int revision, string imageRoot)
        {
            AbsolutePath = absolutePath;
            Markdown = markdown;
            Revision = revision;
            ImageRoot = imageRoot;
        }

        public string AbsolutePath { get; }

        public string Markdown { get; }

        public int Revision { get; }

        public string ImageRoot { get; }

        public override T Match<T>(Func<Empty, T> empty, Func<File, T> file, Func<Showcase, T> showcase) => file(this);
    }

    public sealed class Showcase : DocumentSession
    {
        public Showcase(string markdown, int revision, string imageRoot)
        {
            Markdown = markdown;
            Revision = revision;
            ImageRoot = imageRoot;
        }

        public string Markdown { get; }

        public int Revision { get; }

        public string ImageRoot { get; }

        public override T Match<T>(Func<Empty, T> empty, Func<File, T> file, Func<Showcase, T> showcase) => showcase(this);
    }
}
