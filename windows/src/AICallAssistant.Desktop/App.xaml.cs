using System.Diagnostics;
using System.Windows;
using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Models;
using AICallAssistant.Core.OpenAI;
using AICallAssistant.Core.Persistence;
using AICallAssistant.Desktop.Services;
using AICallAssistant.Desktop.Services.Audio;
using AICallAssistant.Desktop.Services.Security;
using AICallAssistant.Desktop.ViewModels;

namespace AICallAssistant.Desktop;

public partial class App : Application
{
    private UiAppCoordinator? _coordinator;
    private int _exitStarted;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        WindowsAudioCaptureService? audioCapture = null;
        CallSessionController? callSession = null;
        UiAppCoordinator? coordinator = null;
        try
        {
            var paths = ApplicationPaths.ForCurrentUser();
            var jsonStore = new AtomicJsonStore();
            var contextStore = new ContextLibraryStore(paths, jsonStore);
            var settingsStore = new SettingsStore(paths, jsonStore);
            var recordingStore = new RecordingStore(paths, jsonStore);
            var secretStore = new DpapiSecretStore(paths);
            var openAI = new OpenAIService();
            audioCapture = new WindowsAudioCaptureService();
            callSession = new CallSessionController(
                audioCapture,
                secretStore,
                openAI,
                recordingStore,
                static track => new RealtimeTranscriptionSession(track));
            coordinator = new UiAppCoordinator(
                contextStore,
                settingsStore,
                recordingStore,
                secretStore,
                openAI,
                audioCapture,
                callSession);

            _coordinator = coordinator;
            var viewModel = new MainViewModel(coordinator);
            var window = new MainWindow(viewModel);
            MainWindow = window;
            window.Show();
        }
        catch (Exception exception)
        {
            _coordinator = null;
            DisposeFailedStartupGraph(coordinator, callSession, audioCapture);
            MessageBox.Show(
                $"Не удалось запустить Callya.\n\n{exception.Message}",
                "Ошибка запуска",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(-1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (Interlocked.Exchange(ref _exitStarted, 1) == 0)
        {
            var coordinator = Interlocked.Exchange(ref _coordinator, null);
            if (coordinator is not null)
            {
                try
                {
                    coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult();
                }
                catch (Exception exception)
                {
                    Trace.TraceError("Runtime disposal failed: {0}", exception);
                }
            }
        }

        base.OnExit(e);
    }

    private static void DisposeFailedStartupGraph(
        UiAppCoordinator? coordinator,
        CallSessionController? callSession,
        IAudioCaptureService? audioCapture)
    {
        try
        {
            if (coordinator is not null)
            {
                coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult();
            }
            else if (callSession is not null)
            {
                callSession.DisposeAsync().AsTask().GetAwaiter().GetResult();
            }
            else if (audioCapture is not null)
            {
                audioCapture.DisposeAsync().AsTask().GetAwaiter().GetResult();
            }
        }
        catch (Exception exception)
        {
            Trace.TraceError("Startup cleanup failed: {0}", exception);
        }
    }
}
