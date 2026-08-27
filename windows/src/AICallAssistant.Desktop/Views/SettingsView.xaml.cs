using System.ComponentModel;
using System.Windows.Controls;
using AICallAssistant.Desktop.ViewModels;

namespace AICallAssistant.Desktop.Views;

public partial class SettingsView : UserControl
{
    private MainViewModel? _subscribedViewModel;

    public SettingsView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void ApiKeyBox_PasswordChanged(object sender, System.Windows.RoutedEventArgs e)
    {
        if (sender is PasswordBox passwordBox && DataContext is MainViewModel viewModel)
        {
            viewModel.ApiKeyDraft = passwordBox.Password;
        }
    }

    private void OnDataContextChanged(
        object sender,
        System.Windows.DependencyPropertyChangedEventArgs eventArgs)
    {
        if (_subscribedViewModel is not null)
        {
            _subscribedViewModel.PropertyChanged -= OnViewModelPropertyChanged;
        }

        _subscribedViewModel = eventArgs.NewValue as MainViewModel;
        if (_subscribedViewModel is not null)
        {
            _subscribedViewModel.PropertyChanged += OnViewModelPropertyChanged;
        }
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs eventArgs)
    {
        if (eventArgs.PropertyName == nameof(MainViewModel.ApiKeyDraft) &&
            sender is MainViewModel viewModel &&
            string.IsNullOrEmpty(viewModel.ApiKeyDraft) &&
            ApiKeyBox.Password.Length > 0)
        {
            ApiKeyBox.Clear();
        }
    }
}
