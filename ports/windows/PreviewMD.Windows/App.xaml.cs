using System;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace PreviewMD.Windows;

public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        ShellIntegration.SetProcessId();
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var instance = AppInstance.FindOrRegisterForKey("PreviewMD.Windows.Main");
        if (!instance.IsCurrent)
        {
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            instance.RedirectActivationToAsync(activation).AsTask().GetAwaiter().GetResult();
            Environment.Exit(0);
            return;
        }

        var window = new MainWindow();
        _window = window;
        instance.Activated += OnInstanceActivated;
        window.Activate();
        window.HandleCommandLine(Environment.GetCommandLineArgs().Skip(1).ToArray());
    }

    void OnInstanceActivated(object? sender, AppActivationArguments arguments)
    {
        var window = _window;
        if (window is null)
            return;

        var command = arguments.Data is global::Windows.ApplicationModel.Activation.LaunchActivatedEventArgs launch
            ? SplitArguments(launch.Arguments)
            : Array.Empty<string>();
        window.DispatcherQueue.TryEnqueue(() =>
        {
            window.Activate();
            window.HandleCommandLine(command);
        });
    }

    static string[] SplitArguments(string arguments)
    {
        if (string.IsNullOrWhiteSpace(arguments))
            return Array.Empty<string>();

        var parsed = CommandLineToArgvW(arguments, out var count);
        if (parsed == IntPtr.Zero || count <= 0)
            return Array.Empty<string>();

        try
        {
            var result = new string[count];
            for (var index = 0; index < count; index++)
            {
                var pointer = Marshal.ReadIntPtr(parsed, index * IntPtr.Size);
                result[index] = Marshal.PtrToStringUni(pointer) ?? "";
            }

            return result;
        }
        finally
        {
            LocalFree(parsed);
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr handle);
}
