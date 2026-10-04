using System;
using System.Linq;
using Microsoft.UI.Xaml;

namespace PreviewMD.Windows;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var window = new MainWindow();
        _window = window;
        window.Activate();

        var command = Environment.GetCommandLineArgs().Skip(1).ToArray();
        if (command.Any(argument => argument.Equals("--showcase", StringComparison.OrdinalIgnoreCase)))
        {
            window.OpenRequestedShowcase();
            return;
        }

        var path = command.FirstOrDefault(argument =>
            argument.EndsWith(".md", StringComparison.OrdinalIgnoreCase)
            || argument.EndsWith(".markdown", StringComparison.OrdinalIgnoreCase));
        if (path is not null)
            window.OpenRequestedPath(path);
    }
}
