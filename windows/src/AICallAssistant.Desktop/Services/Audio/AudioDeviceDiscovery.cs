using AICallAssistant.Core.Models;
using NAudio.CoreAudioApi;

namespace AICallAssistant.Desktop.Services.Audio;

internal static class AudioDeviceDiscovery
{
    public static IReadOnlyList<AudioSourceOption> GetIncomingSources(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var sources = new List<AudioSourceOption> { AudioSourceOption.SystemAudio };
        if (ProcessLoopbackCapture.IsSupported)
        {
            sources.AddRange(TopLevelProcessEnumerator.GetVisibleProcesses(cancellationToken));
        }
        return sources;
    }

    public static IReadOnlyList<AudioSourceOption> GetMicrophones(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindows())
        {
            return [];
        }

        using var enumerator = new MMDeviceEnumerator();
        string? defaultDeviceId = null;
        if (enumerator.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Communications))
        {
            using var defaultDevice = enumerator.GetDefaultAudioEndpoint(
                DataFlow.Capture,
                Role.Communications);
            defaultDeviceId = defaultDevice.ID;
        }

        var microphones = new List<AudioSourceOption>();
        using var devices = enumerator.EnumerateAudioEndPoints(
            DataFlow.Capture,
            DeviceState.Active);
        foreach (var device in devices)
        {
            using (device)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var deviceId = device.ID;
                var title = string.Equals(deviceId, defaultDeviceId, StringComparison.Ordinal)
                    ? $"{device.FriendlyName} (по умолчанию)"
                    : device.FriendlyName;

                microphones.Add(new AudioSourceOption(
                    $"microphone:{deviceId}",
                    title,
                    AudioSourceKind.Microphone,
                    DeviceId: deviceId));
            }
        }

        return microphones
            .OrderByDescending(option => string.Equals(
                option.DeviceId,
                defaultDeviceId,
                StringComparison.Ordinal))
            .ThenBy(option => option.Title, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }
}
