namespace PreviewMD.Windows.Core;

public interface IDocumentRenderer
{
    bool SystemDark { get; }

    Task RenderAsync(RenderPayload payload, CancellationToken cancellationToken);
}

public sealed class PreviewSession
{
    private readonly DocumentSessionController _controller = new();
    private readonly IDocumentRenderer _renderer;
    private readonly string _showcasePath;
    private readonly string _showcaseImageRoot;
    private readonly SemaphoreSlim _renderGate = new(1, 1);
    private int _renderedRevision;

    public PreviewSession(IDocumentRenderer renderer, string showcasePath, string showcaseImageRoot)
    {
        ArgumentNullException.ThrowIfNull(renderer);
        ArgumentNullException.ThrowIfNull(showcasePath);
        ArgumentNullException.ThrowIfNull(showcaseImageRoot);
        _renderer = renderer;
        _showcasePath = showcasePath;
        _showcaseImageRoot = showcaseImageRoot;
    }

    public DocumentSession Current => _controller.Current;

    public string? ImageRoot => Current.Match<string?>(
        empty: _ => null,
        file: file => file.ImageRoot,
        showcase: showcase => showcase.ImageRoot);

    public async Task OpenFileAsync(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        var markdown = MarkdownReader.ReadFile(path);
        _controller.ReplaceFile(path, markdown);
        await RenderCurrentAsync();
    }

    public async Task OpenShowcaseAsync()
    {
        var markdown = MarkdownReader.ReadFile(_showcasePath);
        _controller.ReplaceShowcase(markdown, _showcaseImageRoot);
        await RenderCurrentAsync();
    }

    public void CloseDocument()
    {
        _controller.Clear();
    }

    private async Task RenderCurrentAsync()
    {
        await _renderGate.WaitAsync();
        try
        {
            while (true)
            {
                var snapshot = _controller.Current;
                var revision = Revision(snapshot);
                if (revision == 0 || revision == _renderedRevision)
                    return;

                var payload = RenderPayloadFactory.Create(snapshot, _renderer.SystemDark);
                await _renderer.RenderAsync(payload, CancellationToken.None);

                if (Revision(_controller.Current) == revision)
                {
                    _renderedRevision = revision;
                    return;
                }
            }
        }
        finally
        {
            _renderGate.Release();
        }
    }

    private static int Revision(DocumentSession session) => session.Match(
        empty: _ => 0,
        file: file => file.Revision,
        showcase: showcase => showcase.Revision);
}
