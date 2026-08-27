using System.Windows.Controls;
using System.Windows.Input;
using AICallAssistant.Desktop.ViewModels;

namespace AICallAssistant.Desktop.Views;

public partial class RecordingsView : UserControl
{
    public RecordingsView()
    {
        InitializeComponent();
    }

    private async void PlaybackSlider_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (sender is Slider slider && DataContext is MainViewModel viewModel)
        {
            await viewModel.SeekPlaybackAsync(slider.Value).ConfigureAwait(true);
        }
    }
}
