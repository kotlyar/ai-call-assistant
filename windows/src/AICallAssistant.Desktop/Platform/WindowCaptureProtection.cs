using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace AICallAssistant.Desktop.Platform;

public static class WindowCaptureProtection
{
    private const uint WdaMonitor = 0x00000001;
    private const uint WdaExcludeFromCapture = 0x00000011;

    public static IDisposable Attach(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        return new Registration(window);
    }

    private sealed class Registration : IDisposable
    {
        private readonly Window _window;
        private bool _disposed;

        public Registration(Window window)
        {
            _window = window;
            _window.SourceInitialized += OnWindowReady;
            _window.ContentRendered += OnWindowReady;
            _window.Activated += OnWindowReady;
            _window.StateChanged += OnWindowReady;
            _window.Closed += OnWindowClosed;

            _window.Dispatcher.BeginInvoke(
                DispatcherPriority.Loaded,
                new Action(Apply));
        }

        private void OnWindowReady(object? sender, EventArgs e) => Apply();

        private void OnWindowClosed(object? sender, EventArgs e) => Dispose();

        private void Apply()
        {
            if (_disposed ||
                !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
            {
                return;
            }

            try
            {
                var handle = new WindowInteropHelper(_window).Handle;
                if (handle == IntPtr.Zero)
                {
                    return;
                }

                if (!SetWindowDisplayAffinity(handle, WdaExcludeFromCapture))
                {
                    if (!SetWindowDisplayAffinity(handle, WdaMonitor))
                    {
                        Trace.TraceWarning(
                            "Windows rejected capture protection for window {0}; Win32 error {1}.",
                            _window.Title,
                            Marshal.GetLastWin32Error());
                    }
                }
            }
            catch (Exception exception) when (
                exception is DllNotFoundException or
                    EntryPointNotFoundException or
                    PlatformNotSupportedException)
            {
                // Capture protection is deliberately best-effort: unsupported
                // systems must still be able to run and record calls.
            }
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _window.SourceInitialized -= OnWindowReady;
            _window.ContentRendered -= OnWindowReady;
            _window.Activated -= OnWindowReady;
            _window.StateChanged -= OnWindowReady;
            _window.Closed -= OnWindowClosed;
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
}
