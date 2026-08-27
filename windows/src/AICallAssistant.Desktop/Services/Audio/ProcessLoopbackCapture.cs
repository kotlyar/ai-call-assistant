using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace AICallAssistant.Desktop.Services.Audio;

/// <summary>
/// Creates the Windows process-loopback virtual endpoint exposed by NAudio 3.
/// NAudio owns both ActivateAudioInterfaceAsync and the activated IAudioClient.
/// </summary>
internal static class ProcessLoopbackCapture
{
    private const int MinimumWindowsBuild = 20_348;

    private static readonly Lazy<bool> HasActivationApi = new(HasActivateAudioInterfaceAsync);

    public static bool IsSupported =>
        OperatingSystem.IsWindowsVersionAtLeast(10, 0, MinimumWindowsBuild) &&
        HasActivationApi.Value;

    public static async Task<WasapiRecorder> CreateAsync(int processId)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(processId);
        if (!IsSupported)
        {
            throw new PlatformNotSupportedException(
                "Захват звука отдельного приложения требует Windows build 20348 " +
                "или новее. Используйте Windows 11 либо выберите «Весь системный звук».");
        }

        try
        {
            using var process = Process.GetProcessById(processId);
            if (process.HasExited)
            {
                throw new ArgumentException(
                    "Выбранное приложение уже завершилось.",
                    nameof(processId));
            }
        }
        catch (ArgumentException exception) when (exception.ParamName is null)
        {
            throw new ArgumentException(
                "Выбранное приложение уже завершилось.",
                nameof(processId),
                exception);
        }

        var builder = new WasapiRecorderBuilder()
            .WithProcessLoopback(
                checked((uint)processId),
                ProcessLoopbackMode.IncludeTargetProcessTree)
            .WithEventSync()
            .WithBufferLength(50)
            .WithMmcssThreadPriority("Audio");

        return await builder.BuildAsync().ConfigureAwait(false);
    }

    private static bool HasActivateAudioInterfaceAsync()
    {
        if (!NativeLibrary.TryLoad("Mmdevapi.dll", out var libraryHandle))
        {
            return false;
        }

        try
        {
            return NativeLibrary.TryGetExport(
                libraryHandle,
                "ActivateAudioInterfaceAsync",
                out _);
        }
        finally
        {
            NativeLibrary.Free(libraryHandle);
        }
    }
}
