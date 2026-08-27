using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using AICallAssistant.Core.Models;

namespace AICallAssistant.Desktop.Services.Audio;

internal static class TopLevelProcessEnumerator
{
    private delegate bool EnumWindowsCallback(nint windowHandle, nint parameter);

    public static IReadOnlyList<AudioSourceOption> GetVisibleProcesses(
        CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindows())
        {
            return [];
        }

        var currentProcessId = Environment.ProcessId;
        var optionsByProcessId = new Dictionary<int, AudioSourceOption>();
        var wasCancelled = false;

        EnumWindowsCallback callback = (windowHandle, parameter) =>
        {
            _ = parameter;
            if (cancellationToken.IsCancellationRequested)
            {
                wasCancelled = true;
                return false;
            }

            if (!IsWindowVisible(windowHandle))
            {
                return true;
            }

            var titleLength = GetWindowTextLength(windowHandle);
            if (titleLength <= 0)
            {
                return true;
            }

            GetWindowThreadProcessId(windowHandle, out var rawProcessId);
            if (rawProcessId == 0 || rawProcessId > int.MaxValue)
            {
                return true;
            }

            var processId = (int)rawProcessId;
            if (processId == currentProcessId || optionsByProcessId.ContainsKey(processId))
            {
                return true;
            }

            var titleBuffer = new StringBuilder(titleLength + 1);
            if (GetWindowText(windowHandle, titleBuffer, titleBuffer.Capacity) <= 0)
            {
                return true;
            }

            var windowTitle = NormalizeWhitespace(titleBuffer.ToString());
            if (string.IsNullOrWhiteSpace(windowTitle))
            {
                return true;
            }

            try
            {
                using var process = Process.GetProcessById(processId);
                if (process.HasExited)
                {
                    return true;
                }

                var processName = NormalizeWhitespace(process.ProcessName);
                var displayName = windowTitle.Contains(processName, StringComparison.OrdinalIgnoreCase)
                    ? windowTitle
                    : $"{processName} — {windowTitle}";

                optionsByProcessId[processId] = new AudioSourceOption(
                    $"process:{processId}",
                    displayName,
                    AudioSourceKind.Process,
                    ProcessId: processId);
            }
            catch (ArgumentException)
            {
                // The process exited between EnumWindows and GetProcessById.
            }
            catch (InvalidOperationException)
            {
                // The process became unavailable while its metadata was read.
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // Metadata for a protected process is not readable at this integrity level.
            }

            return true;
        };

        _ = EnumWindows(callback, nint.Zero);
        if (wasCancelled)
        {
            cancellationToken.ThrowIfCancellationRequested();
        }

        return optionsByProcessId.Values
            .OrderBy(option => option.Title, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(option => option.ProcessId)
            .ToArray();
    }

    private static string NormalizeWhitespace(string value) =>
        string.Join(' ', value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsCallback callback, nint parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(nint windowHandle);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(nint windowHandle);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(
        nint windowHandle,
        StringBuilder text,
        int maximumCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(
        nint windowHandle,
        out uint processId);
}
