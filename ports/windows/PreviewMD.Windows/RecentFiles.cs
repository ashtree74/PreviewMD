using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using PreviewMD.Windows.Core;

namespace PreviewMD.Windows;

static class RecentFiles
{
    static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PreviewMD.Windows.Experiment");

    static readonly string ListPath = Path.Combine(DirectoryPath, "recent.txt");

    public static IReadOnlyList<string> Read()
    {
        if (!File.Exists(ListPath))
            return Array.Empty<string>();

        return File.ReadAllLines(ListPath)
            .Where(path => RecentDocuments.IsMarkdownPath(path) && File.Exists(path))
            .Take(RecentDocuments.Limit)
            .ToArray();
    }

    public static async Task<IReadOnlyList<string>> RememberAsync(string path)
    {
        var remembered = RecentDocuments.Remember(Read(), path);
        Directory.CreateDirectory(DirectoryPath);
        await File.WriteAllLinesAsync(ListPath, remembered);
        return remembered;
    }
}
