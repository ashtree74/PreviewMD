using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Web.WebView2.Core;
using PreviewMD.Windows.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;
using Windows.System;
using WinRT.Interop;

namespace PreviewMD.Windows;

public sealed partial class MainWindow : Window, IDocumentRenderer
{
    private readonly PreviewSession _session;
    private readonly string _webAssetsPath;
    private bool _rendererReady;

    public MainWindow()
    {
        InitializeComponent();
        _webAssetsPath = Path.Combine(AppContext.BaseDirectory, "WebAssets");
        _session = new PreviewSession(
            this,
            Path.Combine(_webAssetsPath, "renderer", "welcome.md"),
            _webAssetsPath);

        var openShortcut = new KeyboardAccelerator
        {
            Key = VirtualKey.O,
            Modifiers = VirtualKeyModifiers.Control,
        };
        openShortcut.Invoked += OpenShortcutInvoked;
        Root.KeyboardAccelerators.Add(openShortcut);

        var closeShortcut = new KeyboardAccelerator
        {
            Key = VirtualKey.W,
            Modifiers = VirtualKeyModifiers.Control,
        };
        closeShortcut.Invoked += CloseShortcutInvoked;
        Root.KeyboardAccelerators.Add(closeShortcut);
        Activated += OnFirstActivation;
    }

    bool _shellAttached;

    void OnFirstActivation(object sender, WindowActivatedEventArgs args)
    {
        if (_shellAttached)
            return;
        _shellAttached = true;
        var hwnd = WindowNative.GetWindowHandle(this);
        ShellIntegration.AttachWindow(hwnd, path => _ = OpenPathAsync(path));
    }

    public bool SystemDark => (Content as FrameworkElement)?.ActualTheme == ElementTheme.Dark;

    public async Task RenderAsync(RenderPayload payload, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await EnsureRendererAsync();
        cancellationToken.ThrowIfCancellationRequested();
        var script = "window.previewmdRender(" + RenderPayloadJson.Serialize(payload) + ")";
        await Preview.CoreWebView2.ExecuteScriptAsync(script);
        if (_session.Current is DocumentSession.Empty)
            return;

        EmptyState.Visibility = Visibility.Collapsed;
    }

    private async Task EnsureRendererAsync()
    {
        if (_rendererReady)
            return;

        var registration = new CoreWebView2CustomSchemeRegistration("previewmd-local-image")
        {
            HasAuthorityComponent = true,
            // This projection exposes the secure-scheme flag as an int.
            TreatAsSecure = 1,
        };
        registration.AllowedOrigins.Add("https://previewmd.assets");

        var options = new CoreWebView2EnvironmentOptions();
        options.CustomSchemeRegistrations.Add(registration);
        var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, null, options);
        await Preview.EnsureCoreWebView2Async(environment);

        var core = Preview.CoreWebView2;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.SetVirtualHostNameToFolderMapping(
            "previewmd.assets",
            _webAssetsPath,
            CoreWebView2HostResourceAccessKind.DenyCors);
        core.AddWebResourceRequestedFilter(
            "previewmd-local-image://*",
            CoreWebView2WebResourceContext.All,
            CoreWebView2WebResourceRequestSourceKinds.All);
        core.WebResourceRequested += OnImageRequested;
        core.NavigationStarting += OnNavigationStarting;
        core.NewWindowRequested += OnNewWindowRequested;
        core.WebMessageReceived += OnWebMessageReceived;
        core.ContextMenuRequested += OnContextMenuRequested;

        var loaded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void Completed(object? sender, CoreWebView2NavigationCompletedEventArgs args)
        {
            core.NavigationCompleted -= Completed;
            loaded.TrySetResult(args.IsSuccess);
        }

        core.NavigationCompleted += Completed;
        core.Navigate("https://previewmd.assets/index.html");
        if (!await loaded.Task)
            throw new InvalidOperationException("The renderer shell did not load.");

        _rendererReady = true;
        ShellIntegration.AttachWindow(
            WindowNative.GetWindowHandle(this),
            path => _ = OpenPathAsync(path));
    }

    private void OnImageRequested(object? sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        var deferral = args.GetDeferral();
        var uri = args.Request.Uri;
        var environment = Preview.CoreWebView2.Environment;
        _ = CompleteImageRequestAsync();

        async Task CompleteImageRequestAsync()
        {
            try
            {
                var root = _session.ImageRoot;
                var decision = root is null
                    ? new ImageDecision.Refused(ImageRefusal.InvalidRequest)
                    : ImagePolicy.Decide(uri, root, ImageInspection.Read);
                if (decision is not ImageDecision.Allowed allowed)
                {
                    args.Response = NotFound(environment);
                    return;
                }

                var bytes = await File.ReadAllBytesAsync(allowed.Path);
                var stream = new InMemoryRandomAccessStream();
                var writer = new DataWriter(stream);
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
                writer.DetachStream();
                writer.Dispose();
                stream.Seek(0);
                args.Response = environment.CreateWebResourceResponse(
                    stream,
                    200,
                    "OK",
                    "Content-Type: " + MimeType(allowed.Path));
            }
            catch (Exception)
            {
                args.Response = NotFound(environment);
            }
            finally
            {
                deferral.Complete();
            }
        }
    }

    private static CoreWebView2WebResourceResponse NotFound(CoreWebView2Environment environment)
    {
        return environment.CreateWebResourceResponse(
            new InMemoryRandomAccessStream(),
            404,
            "Not Found",
            "Content-Type: text/plain");
    }

    private static string MimeType(string path)
    {
        return Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".png" => "image/png",
            ".jpg" or ".jpeg" => "image/jpeg",
            ".gif" => "image/gif",
            ".webp" => "image/webp",
            ".bmp" => "image/bmp",
            ".ico" => "image/x-icon",
            ".svg" => "image/svg+xml",
            _ => "application/octet-stream",
        };
    }

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs args)
    {
        if (ExternalNavigationPolicy.ShouldLaunchExternally(args.Uri))
        {
            args.Cancel = true;
            _ = Launcher.LaunchUriAsync(new Uri(args.Uri));
            return;
        }

        if (ExternalNavigationPolicy.IsAssetsShell(args.Uri))
            return;

        args.Cancel = true;
    }

    private void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs args)
    {
        args.Handled = true;
        if (ExternalNavigationPolicy.ShouldLaunchExternally(args.Uri))
            _ = Launcher.LaunchUriAsync(new Uri(args.Uri));
    }

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        var message = args.TryGetWebMessageAsString();
        if (message == "open")
            _ = OpenFromPickerAsync();
        else if (message == "close")
            CloseCurrent();
    }

    private void OnContextMenuRequested(object? sender, CoreWebView2ContextMenuRequestedEventArgs args)
    {
        var environment = Preview.CoreWebView2.Environment;
        var open = environment.CreateContextMenuItem("Open", null, CoreWebView2ContextMenuItemKind.Command);
        open.CustomItemSelected += (_, _) => DispatcherQueue.TryEnqueue(() => _ = OpenFromPickerAsync());
        var close = environment.CreateContextMenuItem("Close document", null, CoreWebView2ContextMenuItemKind.Command);
        close.CustomItemSelected += (_, _) => DispatcherQueue.TryEnqueue(CloseCurrent);
        args.MenuItems.Insert(0, environment.CreateContextMenuItem("", null, CoreWebView2ContextMenuItemKind.Separator));
        args.MenuItems.Insert(0, close);
        args.MenuItems.Insert(0, open);
    }

    public void OpenRequestedPath(string path) => _ = OpenPathAsync(path);

    public void OpenRequestedShowcase() => _ = ShowShowcaseAsync();

    public void HandleCommandLine(string[] command)
    {
        if (command.Any(argument => argument.Equals("--showcase", StringComparison.OrdinalIgnoreCase)))
        {
            OpenRequestedShowcase();
            return;
        }

        var path = command.FirstOrDefault(RecentDocuments.IsMarkdownPath);
        if (path is not null)
            OpenRequestedPath(path);
    }

    private void OpenClicked(object sender, RoutedEventArgs args) => _ = OpenFromPickerAsync();

    private void ShowcaseClicked(object sender, RoutedEventArgs args) => _ = ShowShowcaseAsync();

    private void OpenShortcutInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        _ = OpenFromPickerAsync();
    }

    private void CloseShortcutInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        CloseCurrent();
    }

    private void CloseCurrent()
    {
        if (_session.Current is DocumentSession.Empty)
        {
            Close();
            return;
        }

        _session.CloseDocument();
        EmptyState.Visibility = Visibility.Visible;
        ClearStatus();
    }

    private void RootDragOver(object sender, DragEventArgs args)
    {
        args.AcceptedOperation = DataPackageOperation.Copy;
        args.Handled = true;
    }

    private async void RootDrop(object sender, DragEventArgs args)
    {
        if (!args.DataView.Contains(StandardDataFormats.StorageItems))
            return;

        var items = await args.DataView.GetStorageItemsAsync();
        var paths = new List<string>();
        foreach (var item in items)
            paths.Add(item.Path);
        var markdown = RecentDocuments.FirstMarkdown(paths);
        if (markdown is not null)
            await OpenPathAsync(markdown);
    }

    private async Task OpenFromPickerAsync()
    {
        try
        {
            var picker = new FileOpenPicker();
            picker.FileTypeFilter.Add(".md");
            picker.FileTypeFilter.Add(".markdown");
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            var file = await picker.PickSingleFileAsync();
            if (file is null)
                return;

            await OpenPathAsync(file.Path);
        }
        catch (Exception exception)
        {
            ShowStatus(exception.Message);
        }
    }

    private async Task OpenPathAsync(string path)
    {
        try
        {
            ClearStatus();
            await _session.OpenFileAsync(path);
            var remembered = await RecentFiles.RememberAsync(path);
            try
            {
                await ShellIntegration.PublishJumpListAsync(remembered);
            }
            catch (Exception exception)
            {
                var folder = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "PreviewMD.Windows.Experiment");
                Directory.CreateDirectory(folder);
                await File.WriteAllTextAsync(Path.Combine(folder, "jumplist-error.txt"), exception.ToString());
            }
        }
        catch (Exception exception)
        {
            ShowStatus(exception.Message);
        }
    }

    private async Task ShowShowcaseAsync()
    {
        try
        {
            ClearStatus();
            await _session.OpenShowcaseAsync();
        }
        catch (Exception exception)
        {
            ShowStatus(exception.Message);
        }
    }

    private void ClearStatus()
    {
        StatusText.Text = "";
    }

    private void ShowStatus(string message)
    {
        EmptyState.Visibility = Visibility.Visible;
        StatusText.Text = message;
    }
}
