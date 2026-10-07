using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using PreviewMD.Windows.Core;
using Windows.UI.StartScreen;

namespace PreviewMD.Windows;

static class ShellIntegration
{
    public const string AppUserModelId = "PreviewMD.Windows.Experiment";

    const uint WM_DROPFILES = 0x0233;
    const int GWLP_WNDPROC = -4;

    static IntPtr _previousProc;
    static WNDPROC? _windowProc;
    static Action<string>? _openMarkdown;
    static DispatcherQueue? _dropQueue;
    static MarkdownDropTarget? _dropTarget;

    public static void SetProcessId()
    {
        SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
    }

    public static void AttachWindow(IntPtr hwnd, Action<string> openMarkdown, DispatcherQueue queue)
    {
        _openMarkdown = openMarkdown;
        _dropQueue = queue;
        SetWindowAppUserModelId(hwnd);
        _windowProc ??= WindowProc;
        var current = GetWindowLongPtr(hwnd, GWLP_WNDPROC);
        var ours = Marshal.GetFunctionPointerForDelegate(_windowProc);
        if (current != ours)
        {
            _previousProc = current;
            SetWindowLongPtr(hwnd, GWLP_WNDPROC, ours);
        }

        DragAcceptFiles(hwnd, true);
        RegisterFileDrop(hwnd);
        EnumChildWindows(hwnd, (child, _) =>
        {
            RegisterFileDrop(child);
            return true;
        }, IntPtr.Zero);
    }

    public static void EnsureStartMenuShortcut()
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe))
            return;

        var programs = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Microsoft", "Windows", "Start Menu", "Programs");
        Directory.CreateDirectory(programs);
        var link = Path.Combine(programs, "PreviewMD (Windows experiment).lnk");
        var shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType is null)
            return;

        dynamic shell = Activator.CreateInstance(shellType)!;
        dynamic shortcut = shell.CreateShortcut(link);
        shortcut.TargetPath = exe;
        shortcut.WorkingDirectory = Path.GetDirectoryName(exe);
        shortcut.Description = "PreviewMD (Windows experiment)";
        shortcut.Save();

        var iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        if (SHGetPropertyStoreFromParsingName(link, IntPtr.Zero, 2, ref iid, out var store) != 0 || store is null)
            return;

        var key = AppUserModelIdKey();
        var value = PropVariant.FromString(AppUserModelId);
        try
        {
            store.SetValue(ref key, ref value);
            store.Commit();
        }
        finally
        {
            value.Clear();
        }
    }

    static IntPtr WindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_DROPFILES)
        {
            var paths = ReadDroppedFiles(wParam);
            DragFinish(wParam);
            var markdown = RecentDocuments.FirstMarkdown(paths);
            if (markdown is not null && _openMarkdown is not null)
                _openMarkdown(markdown);
            return IntPtr.Zero;
        }

        return CallWindowProc(_previousProc, hwnd, msg, wParam, lParam);
    }

    public static async Task PublishJumpListAsync(IReadOnlyList<string> paths)
    {
        var jumpList = await JumpList.LoadCurrentAsync();
        jumpList.SystemGroupKind = JumpListSystemGroupKind.None;
        jumpList.Items.Clear();
        foreach (var path in paths)
        {
            var item = JumpListItem.CreateWithArguments(Quote(path), System.IO.Path.GetFileName(path));
            item.GroupName = "Recent";
            item.Description = path;
            jumpList.Items.Add(item);
        }

        await jumpList.SaveAsync();
    }

    static string Quote(string path) => path.Contains(' ') ? "\"" + path + "\"" : path;

    static List<string> ReadDroppedFiles(IntPtr drop)
    {
        var count = DragQueryFile(drop, 0xFFFFFFFF, null, 0);
        var paths = new List<string>();
        for (uint index = 0; index < count; index++)
        {
            var length = DragQueryFile(drop, index, null, 0);
            var builder = new StringBuilder((int)length + 1);
            DragQueryFile(drop, index, builder, length + 1);
            paths.Add(builder.ToString());
        }

        return paths;
    }

    public static void AssignWindowIdentity(IntPtr hwnd) => SetWindowAppUserModelId(hwnd);

    static void SetWindowAppUserModelId(IntPtr hwnd)
    {
        var iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        var result = SHGetPropertyStoreForWindow(hwnd, ref iid, out var store);
        if (result != 0 || store is null)
            return;

        var key = AppUserModelIdKey();
        var value = PropVariant.FromString(AppUserModelId);
        try
        {
            store.SetValue(ref key, ref value);
            store.Commit();
        }
        finally
        {
            value.Clear();
        }
    }

    static PropertyKey AppUserModelIdKey() => new(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);

    static void RegisterFileDrop(IntPtr hwnd)
    {
        OleInitialize(IntPtr.Zero);
        _dropTarget ??= new MarkdownDropTarget();
        var result = RegisterDragDrop(hwnd, _dropTarget);
        if (result == unchecked((int)0x80040101))
        {
            RevokeDragDrop(hwnd);
            RegisterDragDrop(hwnd, _dropTarget);
        }
    }

    static void OpenDroppedPaths(IReadOnlyList<string> paths)
    {
        var markdown = RecentDocuments.FirstMarkdown(paths);
        if (markdown is null || _openMarkdown is null)
            return;
        if (_dropQueue is null)
        {
            _openMarkdown(markdown);
            return;
        }

        _dropQueue.TryEnqueue(() => _openMarkdown(markdown));
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHGetPropertyStoreFromParsingName(
        string path,
        IntPtr bindContext,
        uint flags,
        ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);

    [DllImport("ole32.dll")]
    static extern int OleInitialize(IntPtr reserved);

    [DllImport("ole32.dll")]
    static extern int RegisterDragDrop(IntPtr hwnd, IDropTarget dropTarget);

    [DllImport("ole32.dll")]
    static extern int RevokeDragDrop(IntPtr hwnd);

    [DllImport("ole32.dll")]
    static extern void ReleaseStgMedium(ref STGMEDIUM medium);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr data);

    delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);

    [DllImport("shell32.dll")]
    static extern int SHGetPropertyStoreForWindow(
        IntPtr hwnd,
        ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);

    [DllImport("shell32.dll")]
    static extern void DragAcceptFiles(IntPtr hwnd, bool accept);

    [DllImport("shell32.dll")]
    static extern void DragFinish(IntPtr drop);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern uint DragQueryFile(IntPtr drop, uint index, StringBuilder? file, uint length);

    [DllImport("user32.dll")]
    static extern IntPtr CallWindowProc(IntPtr previous, IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr procedure);

    delegate IntPtr WNDPROC(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;

        public PropertyKey(Guid formatId, uint propertyId)
        {
            FormatId = formatId;
            PropertyId = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    struct PropVariant
    {
        [FieldOffset(0)] public ushort VariantType;
        [FieldOffset(8)] public IntPtr Pointer;

        public static PropVariant FromString(string value)
        {
            return new PropVariant
            {
                VariantType = 31,
                Pointer = Marshal.StringToCoTaskMemUni(value),
            };
        }

        public void Clear()
        {
            if (Pointer != IntPtr.Zero)
                Marshal.FreeCoTaskMem(Pointer);
            Pointer = IntPtr.Zero;
            VariantType = 0;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct POINTL
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct FORMATETC
    {
        public ushort Format;
        public IntPtr TargetDevice;
        public uint Aspect;
        public int Index;
        public uint Medium;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STGMEDIUM
    {
        public uint Medium;
        public IntPtr Data;
        public IntPtr UnknownForRelease;
    }

    [ComImport]
    [Guid("0000010e-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDataObject
    {
        [PreserveSig]
        int GetData(ref FORMATETC format, out STGMEDIUM medium);
    }

    [ComImport]
    [Guid("00000122-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDropTarget
    {
        [PreserveSig]
        int DragEnter(IntPtr data, uint keyState, POINTL point, ref uint effect);
        [PreserveSig]
        int DragOver(uint keyState, POINTL point, ref uint effect);
        [PreserveSig]
        int DragLeave();
        [PreserveSig]
        int Drop(IntPtr data, uint keyState, POINTL point, ref uint effect);
    }

    [ComVisible(true)]
    sealed class MarkdownDropTarget : IDropTarget
    {
        const uint CopyEffect = 1;

        public int DragEnter(IntPtr data, uint keyState, POINTL point, ref uint effect)
        {
            effect = CopyEffect;
            return 0;
        }

        public int DragOver(uint keyState, POINTL point, ref uint effect)
        {
            effect = CopyEffect;
            return 0;
        }

        public int DragLeave() => 0;

        public int Drop(IntPtr data, uint keyState, POINTL point, ref uint effect)
        {
            effect = CopyEffect;
            if (data == IntPtr.Zero)
                return 0;

            var source = (IDataObject)Marshal.GetObjectForIUnknown(data);
            var format = new FORMATETC
            {
                Format = 15,
                Aspect = 1,
                Index = -1,
                Medium = 1,
            };
            var result = source.GetData(ref format, out var medium);
            if (result != 0)
                return result;

            try
            {
                OpenDroppedPaths(ReadDroppedFiles(medium.Data));
            }
            finally
            {
                ReleaseStgMedium(ref medium);
            }

            return 0;
        }
    }
}
