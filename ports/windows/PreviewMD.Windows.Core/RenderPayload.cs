using System.Text.Json;

namespace PreviewMD.Windows.Core;

public sealed record RenderPayload(
    string documentID,
    string markdown,
    int revision,
    bool editable,
    string theme,
    string readingStyle,
    object? customReadingPreset,
    bool systemDark,
    int readingWidth,
    bool readingWidthIsFluid,
    bool paperCanvas,
    double zoom,
    string searchText,
    string? outlineTarget,
    object[] externalChanges,
    int? externalChangeSelection,
    double topInset);

public static class RenderPayloadFactory
{
    public const int ReadingWidth = 820;

    public static RenderPayload Create(DocumentSession session, bool systemDark)
    {
        return session.Match(
            empty: _ => throw new InvalidOperationException("There is no document to render."),
            file: file => Create(file.AbsolutePath, file.Markdown, file.Revision, systemDark),
            showcase: showcase => Create("showcase", showcase.Markdown, showcase.Revision, systemDark));
    }

    private static RenderPayload Create(string documentID, string markdown, int revision, bool systemDark)
    {
        return new RenderPayload(
            documentID,
            markdown,
            revision,
            editable: false,
            theme: "system",
            readingStyle: "modern",
            customReadingPreset: null,
            systemDark,
            ReadingWidth,
            readingWidthIsFluid: false,
            paperCanvas: false,
            zoom: 1,
            searchText: "",
            outlineTarget: null,
            externalChanges: [],
            externalChangeSelection: null,
            topInset: 0);
    }
}

public static class RenderPayloadJson
{
    public static string Serialize(RenderPayload payload) => JsonSerializer.Serialize(payload);
}
