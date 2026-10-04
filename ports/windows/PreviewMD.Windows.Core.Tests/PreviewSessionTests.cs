using System.Text.Json;
using PreviewMD.Windows.Core;
using Xunit;

namespace PreviewMD.Windows.Core.Tests;

public class PreviewSessionTests
{
    [Fact]
    public async Task OpeningASecondFileReplacesTheFirstPath()
    {
        var directory = Path.Combine(Path.GetTempPath(), "previewmd-replace-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var first = Path.Combine(directory, "first.md");
        var second = Path.Combine(directory, "second.md");
        var showcase = Path.Combine(directory, "showcase.md");
        await File.WriteAllTextAsync(first, "first-body");
        await File.WriteAllTextAsync(second, "second-body");
        await File.WriteAllTextAsync(showcase, "showcase-body");
        var renderer = new RecordingRenderer();
        var session = new PreviewSession(renderer, showcase, directory);

        try
        {
            await session.OpenFileAsync(first);
            await session.OpenFileAsync(second);

            var file = Assert.IsType<DocumentSession.File>(session.Current);
            Assert.Equal(second, file.AbsolutePath);
            Assert.Equal("second-body", file.Markdown);
            Assert.Equal(directory, file.ImageRoot);
            Assert.Equal(2, file.Revision);
            Assert.Equal(2, renderer.Payloads.Count);

            using var json = JsonDocument.Parse(RenderPayloadJson.Serialize(renderer.Payloads[1]));
            var payload = json.RootElement;
            Assert.Equal(second, payload.GetProperty("documentID").GetString());
            Assert.Equal("second-body", payload.GetProperty("markdown").GetString());
            Assert.Equal(2, payload.GetProperty("revision").GetInt32());
            Assert.False(payload.GetProperty("editable").GetBoolean());
            Assert.Equal("system", payload.GetProperty("theme").GetString());
            Assert.Equal("modern", payload.GetProperty("readingStyle").GetString());
            Assert.Equal(JsonValueKind.Null, payload.GetProperty("customReadingPreset").ValueKind);
            Assert.False(payload.GetProperty("systemDark").GetBoolean());
            Assert.Equal(820, payload.GetProperty("readingWidth").GetInt32());
            Assert.False(payload.GetProperty("readingWidthIsFluid").GetBoolean());
            Assert.False(payload.GetProperty("paperCanvas").GetBoolean());
            Assert.Equal(1, payload.GetProperty("zoom").GetDouble());
            Assert.Equal("", payload.GetProperty("searchText").GetString());
            Assert.Equal(JsonValueKind.Null, payload.GetProperty("outlineTarget").ValueKind);
            Assert.Equal(0, payload.GetProperty("externalChanges").GetArrayLength());
            Assert.Equal(JsonValueKind.Null, payload.GetProperty("externalChangeSelection").ValueKind);
            Assert.Equal(0, payload.GetProperty("topInset").GetDouble());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private sealed class RecordingRenderer : IDocumentRenderer
    {
        public bool SystemDark => false;

        public List<RenderPayload> Payloads { get; } = new();

        public Task RenderAsync(RenderPayload payload, CancellationToken cancellationToken)
        {
            Payloads.Add(payload);
            return Task.CompletedTask;
        }
    }
}
