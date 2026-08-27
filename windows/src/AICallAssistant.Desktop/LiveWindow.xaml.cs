using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using AICallAssistant.Desktop.Platform;
using AICallAssistant.Desktop.ViewModels;

namespace AICallAssistant.Desktop;

public partial class LiveWindow : Window
{
    private readonly MainViewModel _viewModel;
    private readonly IDisposable _captureProtection;
    private bool _allowClose;

    public LiveWindow(MainViewModel viewModel)
    {
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        DataContext = viewModel;
        InitializeComponent();
        _captureProtection = WindowCaptureProtection.Attach(this);
        _viewModel.LiveWindowCloseRequested += OnLiveWindowCloseRequested;
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left)
        {
            DragMove();
        }
    }

    private void Minimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    private void Close_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.EndCallCommand.CanExecute(null))
        {
            _viewModel.EndCallCommand.Execute(null);
        }
        else
        {
            RequestClose();
        }
    }

    private void OnLiveWindowCloseRequested(object? sender, EventArgs e) => RequestClose();

    private void RequestClose()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(RequestClose);
            return;
        }

        _allowClose = true;
        Close();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_allowClose && _viewModel.IsCallActive)
        {
            e.Cancel = true;
            if (_viewModel.EndCallCommand.CanExecute(null))
            {
                _viewModel.EndCallCommand.Execute(null);
            }
        }

        base.OnClosing(e);
    }

    protected override void OnClosed(EventArgs e)
    {
        _viewModel.LiveWindowCloseRequested -= OnLiveWindowCloseRequested;
        _captureProtection.Dispose();
        base.OnClosed(e);
    }
}
