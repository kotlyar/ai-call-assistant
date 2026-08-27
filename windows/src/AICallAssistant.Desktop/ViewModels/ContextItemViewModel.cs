using AICallAssistant.Core.Models;

namespace AICallAssistant.Desktop.ViewModels;

public sealed class ContextItemViewModel : ObservableObject
{
    private readonly CallContext _model;

    public ContextItemViewModel(CallContext model)
    {
        _model = model;
    }

    public CallContext Model => _model;
    public Guid Id => _model.Id;
    public string Title => _model.Title;
    public string Body => _model.Body;
    public string Summary => string.IsNullOrWhiteSpace(_model.Body) ? "Контекст находится во вложениях" : _model.Body;
    public int AttachmentCount => _model.Attachments.Count;
    public string AttachmentText => AttachmentCount switch
    {
        0 => string.Empty,
        1 => "1 файл",
        >= 2 and <= 4 => $"{AttachmentCount} файла",
        _ => $"{AttachmentCount} файлов"
    };

    public bool IsSelected
    {
        get => _model.IsSelected;
        set
        {
            if (_model.IsSelected == value)
            {
                return;
            }

            _model.IsSelected = value;
            OnPropertyChanged();
        }
    }

    public void Refresh()
    {
        OnPropertyChanged(nameof(Title));
        OnPropertyChanged(nameof(Body));
        OnPropertyChanged(nameof(Summary));
        OnPropertyChanged(nameof(AttachmentCount));
        OnPropertyChanged(nameof(AttachmentText));
        OnPropertyChanged(nameof(IsSelected));
    }
}
