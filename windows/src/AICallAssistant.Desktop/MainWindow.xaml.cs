using System.ComponentModel;
using System.IO;
using System.Windows;
using AICallAssistant.Desktop.Platform;
using AICallAssistant.Desktop.ViewModels;
using Microsoft.Win32;

namespace AICallAssistant.Desktop;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private readonly IDisposable _captureProtection;
    private LiveWindow? _liveWindow;
    private bool _allowClose;
    private bool _closeAfterCall;

    public MainWindow(MainViewModel viewModel)
    {
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        InitializeComponent();
        DataContext = viewModel;
        _captureProtection = WindowCaptureProtection.Attach(this);

        Loaded += OnLoaded;
        _viewModel.LiveWindowRequested += OnLiveWindowRequested;
        _viewModel.AudioExportRequested += OnAudioExportRequested;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OnLoaded;
        if (_viewModel.InitializeCommand.CanExecute(null))
        {
            _viewModel.InitializeCommand.Execute(null);
        }
    }

    private void OnLiveWindowRequested(object? sender, EventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => OnLiveWindowRequested(sender, e));
            return;
        }

        if (_liveWindow is not null)
        {
            _liveWindow.Activate();
            return;
        }

        _liveWindow = new LiveWindow(_viewModel);
        _liveWindow.Closed += OnLiveWindowClosed;
        Hide();
        _liveWindow.Show();
        _liveWindow.Activate();
    }

    private void OnLiveWindowClosed(object? sender, EventArgs e)
    {
        if (_liveWindow is not null)
        {
            _liveWindow.Closed -= OnLiveWindowClosed;
            _liveWindow = null;
        }

        if (_closeAfterCall)
        {
            _allowClose = true;
            Close();
            return;
        }

        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private async void OnAudioExportRequested(object? sender, AudioExportRequestedEventArgs e)
    {
        var extension = Path.GetExtension(e.SuggestedFileName);
        var dialog = new SaveFileDialog
        {
            Title = "Сохранить аудиодорожку",
            FileName = e.SuggestedFileName,
            DefaultExt = string.IsNullOrWhiteSpace(extension) ? ".m4a" : extension,
            AddExtension = true,
            OverwritePrompt = true,
            Filter = "Аудиофайлы|*.m4a;*.wav;*.mp3|Все файлы|*.*"
        };

        if (dialog.ShowDialog(this) == true)
        {
            await _viewModel.CompleteAudioExportAsync(e, dialog.FileName).ConfigureAwait(true);
        }
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_allowClose && _viewModel.IsCallActive)
        {
            var result = MessageBox.Show(
                this,
                "Звонок ещё записывается. Завершить его и закрыть приложение?",
                "Callya",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (result == MessageBoxResult.No)
            {
                e.Cancel = true;
                base.OnClosing(e);
                return;
            }

            e.Cancel = true;
            _closeAfterCall = true;
            if (_viewModel.EndCallCommand.CanExecute(null))
            {
                _viewModel.EndCallCommand.Execute(null);
            }
        }

        base.OnClosing(e);
    }

    protected override void OnClosed(EventArgs e)
    {
        _viewModel.LiveWindowRequested -= OnLiveWindowRequested;
        _viewModel.AudioExportRequested -= OnAudioExportRequested;
        _captureProtection.Dispose();
        _viewModel.Dispose();
        base.OnClosed(e);
    }
}
