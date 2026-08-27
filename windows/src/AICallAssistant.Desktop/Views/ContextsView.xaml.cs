using System.Windows;
using System.Windows.Controls;
using AICallAssistant.Desktop.ViewModels;
using Microsoft.Win32;

namespace AICallAssistant.Desktop.Views;

public partial class ContextsView : UserControl
{
    public ContextsView()
    {
        InitializeComponent();
    }

    private MainViewModel? ViewModel => DataContext as MainViewModel;

    private async void AddFiles_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Добавить материалы в контекст",
            Multiselect = true,
            CheckFileExists = true,
            Filter = "Поддерживаемые файлы|*.pdf;*.txt;*.md;*.json;*.html;*.xml;*.doc;*.docx;*.rtf;*.odt;*.ppt;*.pptx;*.csv;*.tsv;*.xls;*.xlsx;*.cs;*.cpp;*.css;*.go;*.java;*.js;*.jsx;*.py;*.rb;*.sh;*.sql;*.swift;*.ts;*.tsx;*.yaml;*.yml|Все файлы|*.*"
        };

        if (dialog.ShowDialog(Window.GetWindow(this)) == true && ViewModel is not null)
        {
            await ViewModel.AddContextFilesAsync(dialog.FileNames).ConfigureAwait(true);
        }
    }

    private void DeleteContext_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ContextItemViewModel context } || ViewModel is null)
        {
            return;
        }

        var result = MessageBox.Show(
            Window.GetWindow(this),
            $"Удалить контекст «{context.Title}»? Это действие нельзя отменить.",
            "Удалить контекст?",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);
        if (result == MessageBoxResult.Yes)
        {
            ViewModel.DeleteContextCommand.Execute(context);
        }
    }
}
