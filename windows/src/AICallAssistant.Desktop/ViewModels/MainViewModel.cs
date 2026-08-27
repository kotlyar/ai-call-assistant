using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Threading;
using AICallAssistant.Core.Models;
using AICallAssistant.Desktop.Commands;

namespace AICallAssistant.Desktop.ViewModels;

public sealed class MainViewModel : ObservableObject, IDisposable
{
    private readonly IUiAppCoordinator _coordinator;
    private readonly DispatcherTimer _callTimer;
    private readonly DispatcherTimer _notificationTimer;
    private CancellationTokenSource? _contextSaveCancellation;
    private bool _suspendContextPersistence;
    private bool _disposed;

    private AppSection _currentSection = AppSection.Setup;
    private AudioSourceOption? _selectedIncomingSource;
    private AudioSourceOption? _selectedMicrophone;
    private RecordingItemViewModel? _selectedRecording;
    private ContextItemViewModel? _editingContext;
    private GuidanceCard? _currentGuidance;
    private AppSettings _settingsDraft = new();
    private string _contextSearchText = string.Empty;
    private string _recordingSearchText = string.Empty;
    private string _contextTitleDraft = string.Empty;
    private string _contextBodyDraft = string.Empty;
    private string _apiKeyDraft = string.Empty;
    private string _settingsStatus = string.Empty;
    private string _audioStatusText = "Проверяем доступные источники…";
    private string _audioErrorText = string.Empty;
    private string _incomingLiveStatus = "подключается";
    private string _outgoingLiveStatus = "подключается";
    private string _guidanceStatus = "АНАЛИЗИРУЕТ ОНЛАЙН";
    private string _selectedRecordingTab = "Transcript";
    private string _notificationText = string.Empty;
    private TimeSpan _callElapsed;
    private TimeSpan _playbackElapsed;
    private TimeSpan _playbackDuration;
    private double _playbackProgress;
    private Guid? _playingRecordingId;
    private bool _isInitialized;
    private bool _isBusy;
    private bool _isRefreshingSources;
    private bool _isContextEditorOpen;
    private bool _isExtractingAttachments;
    private bool _isApiKeyAvailable;
    private bool _isCallActive;
    private bool _isNotificationVisible;

    public MainViewModel(IUiAppCoordinator coordinator)
    {
        _coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
        _coordinator.LiveSnapshotChanged += OnLiveSnapshotChanged;
        _coordinator.RecordingChanged += OnRecordingChanged;

        FilteredContexts = CollectionViewSource.GetDefaultView(Contexts);
        FilteredContexts.Filter = FilterContext;
        FilteredRecordings = CollectionViewSource.GetDefaultView(Recordings);
        FilteredRecordings.Filter = FilterRecording;

        _callTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(1)
        };
        _callTimer.Tick += OnCallTimerTick;

        _notificationTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(3)
        };
        _notificationTimer.Tick += (_, _) =>
        {
            _notificationTimer.Stop();
            IsNotificationVisible = false;
        };

        InitializeCommand = CreateAsyncCommand(InitializeAsync);
        NavigateCommand = new RelayCommand(Navigate);
        RefreshSourcesCommand = CreateAsyncCommand(RefreshSourcesAsync, () => !IsRefreshingSources && !IsCallActive);
        StartCallCommand = CreateAsyncCommand(StartCallAsync, CanStartCall);
        EndCallCommand = CreateAsyncCommand(EndCallAsync, () => IsCallActive);

        SelectAllContextsCommand = new RelayCommand(SelectAllContexts, () => Contexts.Count > 0 && SelectedContextCount < Contexts.Count);
        ClearContextSelectionCommand = new RelayCommand(ClearContextSelection, () => SelectedContextCount > 0);
        BeginCreateContextCommand = new RelayCommand(BeginCreateContext);
        BeginEditContextCommand = new RelayCommand(BeginEditContext);
        DeleteContextCommand = CreateAsyncCommand(DeleteContextAsync, parameter => parameter is ContextItemViewModel);
        SaveContextCommand = CreateAsyncCommand(SaveContextAsync, CanSaveContext);
        CancelContextEditCommand = new RelayCommand(CancelContextEdit);
        RemoveContextAttachmentCommand = new RelayCommand(RemoveContextAttachment);

        SelectRecordingTabCommand = new RelayCommand(parameter =>
        {
            if (parameter is string tab)
            {
                SelectedRecordingTab = tab;
            }
        });
        TogglePlaybackCommand = CreateAsyncCommand(TogglePlaybackAsync, () => SelectedRecording is not null);
        OpenTranscriptCommand = CreateAsyncCommand(OpenTranscriptAsync, () => SelectedRecording is not null);
        RevealRecordingCommand = CreateAsyncCommand(RevealRecordingAsync, () => SelectedRecording is not null);
        RetryProcessingCommand = CreateAsyncCommand(RetryProcessingAsync, () => SelectedRecording?.CanRetry == true);
        RequestAudioExportCommand = new RelayCommand(RequestAudioExport, parameter => parameter is AudioExportKind && SelectedRecording is not null);

        SaveSettingsCommand = CreateAsyncCommand(SaveSettingsAsync);
        SaveApiKeyCommand = CreateAsyncCommand(SaveApiKeyAsync, () => !string.IsNullOrWhiteSpace(ApiKeyDraft));
        DeleteApiKeyCommand = CreateAsyncCommand(DeleteApiKeyAsync, () => IsApiKeyAvailable);
        TestApiKeyCommand = CreateAsyncCommand(TestApiKeyAsync);
    }

    public ObservableCollection<AudioSourceOption> IncomingSources { get; } = [];
    public ObservableCollection<AudioSourceOption> Microphones { get; } = [];
    public ObservableCollection<ContextItemViewModel> Contexts { get; } = [];
    public ObservableCollection<RecordingItemViewModel> Recordings { get; } = [];
    public ObservableCollection<ContextFileAttachment> ContextAttachmentsDraft { get; } = [];
    public ObservableCollection<TranscriptTurn> LiveTranscriptTurns { get; } = [];
    public ObservableCollection<GuidanceCard> AnswerHistory { get; } = [];
    public ICollectionView FilteredContexts { get; }
    public ICollectionView FilteredRecordings { get; }
    public IReadOnlyList<AnswerStyle> AnswerStyleOptions { get; } = Enum.GetValues<AnswerStyle>();
    public IReadOnlyList<AnswerLanguage> AnswerLanguageOptions { get; } = Enum.GetValues<AnswerLanguage>();

    public ICommand InitializeCommand { get; }
    public ICommand NavigateCommand { get; }
    public ICommand RefreshSourcesCommand { get; }
    public ICommand StartCallCommand { get; }
    public ICommand EndCallCommand { get; }
    public ICommand SelectAllContextsCommand { get; }
    public ICommand ClearContextSelectionCommand { get; }
    public ICommand BeginCreateContextCommand { get; }
    public ICommand BeginEditContextCommand { get; }
    public ICommand DeleteContextCommand { get; }
    public ICommand SaveContextCommand { get; }
    public ICommand CancelContextEditCommand { get; }
    public ICommand RemoveContextAttachmentCommand { get; }
    public ICommand SelectRecordingTabCommand { get; }
    public ICommand TogglePlaybackCommand { get; }
    public ICommand OpenTranscriptCommand { get; }
    public ICommand RevealRecordingCommand { get; }
    public ICommand RetryProcessingCommand { get; }
    public ICommand RequestAudioExportCommand { get; }
    public ICommand SaveSettingsCommand { get; }
    public ICommand SaveApiKeyCommand { get; }
    public ICommand DeleteApiKeyCommand { get; }
    public ICommand TestApiKeyCommand { get; }

    public event EventHandler? LiveWindowRequested;
    public event EventHandler? LiveWindowCloseRequested;
    public event EventHandler<AudioExportRequestedEventArgs>? AudioExportRequested;

    public AppSection CurrentSection
    {
        get => _currentSection;
        set
        {
            if (SetProperty(ref _currentSection, value))
            {
                OnPropertyChanged(nameof(SectionTitle));
            }
        }
    }

    public string SectionTitle => CurrentSection switch
    {
        AppSection.Setup => "Новый звонок",
        AppSection.Contexts => "Контексты",
        AppSection.Recordings => "Записи",
        AppSection.Settings => "Настройки",
        _ => string.Empty
    };

    public AudioSourceOption? SelectedIncomingSource
    {
        get => _selectedIncomingSource;
        set
        {
            if (SetProperty(ref _selectedIncomingSource, value))
            {
                RelayCommand.InvalidateRequerySuggested();
            }
        }
    }

    public AudioSourceOption? SelectedMicrophone
    {
        get => _selectedMicrophone;
        set
        {
            if (SetProperty(ref _selectedMicrophone, value))
            {
                RelayCommand.InvalidateRequerySuggested();
            }
        }
    }

    public RecordingItemViewModel? SelectedRecording
    {
        get => _selectedRecording;
        set
        {
            if (!SetProperty(ref _selectedRecording, value))
            {
                return;
            }

            SelectedRecordingTab = "Transcript";
            OnPropertyChanged(nameof(HasSelectedRecording));
            OnPropertyChanged(nameof(SelectedRecordingTurns));
            OnPropertyChanged(nameof(SelectedAnalysisCards));
            OnPropertyChanged(nameof(IsSelectedRecordingPlaying));
            RelayCommand.InvalidateRequerySuggested();
        }
    }

    public GuidanceCard? CurrentGuidance
    {
        get => _currentGuidance;
        private set
        {
            if (SetProperty(ref _currentGuidance, value))
            {
                OnPropertyChanged(nameof(HasCurrentGuidance));
                OnPropertyChanged(nameof(LiveQuestionText));
                OnPropertyChanged(nameof(LiveAnswerText));
                OnPropertyChanged(nameof(LiveAdviceText));
                OnPropertyChanged(nameof(LiveEvidenceText));
                OnPropertyChanged(nameof(IsCurrentGuidanceLate));
                OnPropertyChanged(nameof(GuidancePlaceholderTitle));
                OnPropertyChanged(nameof(GuidancePlaceholderDetail));
            }
        }
    }

    public AppSettings SettingsDraft
    {
        get => _settingsDraft;
        private set
        {
            if (SetProperty(ref _settingsDraft, value))
            {
                OnPropertyChanged(nameof(IsRussianEnabled));
                OnPropertyChanged(nameof(IsEnglishEnabled));
            }
        }
    }

    public string ContextSearchText
    {
        get => _contextSearchText;
        set
        {
            if (SetProperty(ref _contextSearchText, value))
            {
                FilteredContexts.Refresh();
                OnPropertyChanged(nameof(ContextCountText));
            }
        }
    }

    public string RecordingSearchText
    {
        get => _recordingSearchText;
        set
        {
            if (SetProperty(ref _recordingSearchText, value))
            {
                FilteredRecordings.Refresh();
                OnPropertyChanged(nameof(RecordingCountText));
            }
        }
    }

    public string ContextTitleDraft
    {
        get => _contextTitleDraft;
        set
        {
            if (SetProperty(ref _contextTitleDraft, value))
            {
                RelayCommand.InvalidateRequerySuggested();
            }
        }
    }

    public string ContextBodyDraft
    {
        get => _contextBodyDraft;
        set
        {
            if (SetProperty(ref _contextBodyDraft, value))
            {
                RelayCommand.InvalidateRequerySuggested();
            }
        }
    }

    public string ApiKeyDraft
    {
        get => _apiKeyDraft;
        set
        {
            if (SetProperty(ref _apiKeyDraft, value))
            {
                RelayCommand.InvalidateRequerySuggested();
            }
        }
    }

    public string SettingsStatus
    {
        get => _settingsStatus;
        private set => SetProperty(ref _settingsStatus, value);
    }

    public string AudioStatusText
    {
        get => _audioStatusText;
        private set => SetProperty(ref _audioStatusText, value);
    }

    public string AudioErrorText
    {
        get => _audioErrorText;
        private set
        {
            if (SetProperty(ref _audioErrorText, value))
            {
                OnPropertyChanged(nameof(HasAudioError));
            }
        }
    }

    public string IncomingLiveStatus
    {
        get => _incomingLiveStatus;
        private set => SetProperty(ref _incomingLiveStatus, value);
    }

    public string OutgoingLiveStatus
    {
        get => _outgoingLiveStatus;
        private set => SetProperty(ref _outgoingLiveStatus, value);
    }

    public string GuidanceStatus
    {
        get => _guidanceStatus;
        private set
        {
            if (SetProperty(ref _guidanceStatus, value))
            {
                OnPropertyChanged(nameof(GuidancePlaceholderTitle));
                OnPropertyChanged(nameof(GuidancePlaceholderDetail));
            }
        }
    }

    public string SelectedRecordingTab
    {
        get => _selectedRecordingTab;
        set => SetProperty(ref _selectedRecordingTab, value);
    }

    public string NotificationText
    {
        get => _notificationText;
        private set => SetProperty(ref _notificationText, value);
    }

    public TimeSpan CallElapsed
    {
        get => _callElapsed;
        private set
        {
            if (SetProperty(ref _callElapsed, value))
            {
                OnPropertyChanged(nameof(CallElapsedText));
            }
        }
    }

    public TimeSpan PlaybackElapsed
    {
        get => _playbackElapsed;
        private set
        {
            if (SetProperty(ref _playbackElapsed, value))
            {
                OnPropertyChanged(nameof(PlaybackTimeText));
            }
        }
    }

    public TimeSpan PlaybackDuration
    {
        get => _playbackDuration;
        private set
        {
            if (SetProperty(ref _playbackDuration, value))
            {
                OnPropertyChanged(nameof(PlaybackTimeText));
            }
        }
    }

    public double PlaybackProgress
    {
        get => _playbackProgress;
        set => SetProperty(ref _playbackProgress, Math.Clamp(value, 0, 1));
    }

    public bool IsInitialized
    {
        get => _isInitialized;
        private set => SetProperty(ref _isInitialized, value);
    }

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (SetProperty(ref _isBusy, value))
            {
                RelayCommand.InvalidateRequerySuggested();
            }
        }
    }

    public bool IsRefreshingSources
    {
        get => _isRefreshingSources;
        private set
        {
            if (SetProperty(ref _isRefreshingSources, value))
            {
                RelayCommand.InvalidateRequerySuggested();
            }
        }
    }

    public bool IsContextEditorOpen
    {
        get => _isContextEditorOpen;
        private set => SetProperty(ref _isContextEditorOpen, value);
    }

    public bool IsExtractingAttachments
    {
        get => _isExtractingAttachments;
        private set
        {
            if (SetProperty(ref _isExtractingAttachments, value))
            {
                RelayCommand.InvalidateRequerySuggested();
            }
        }
    }

    public bool IsApiKeyAvailable
    {
        get => _isApiKeyAvailable;
        private set
        {
            if (SetProperty(ref _isApiKeyAvailable, value))
            {
                OnPropertyChanged(nameof(CredentialStatusText));
                RelayCommand.InvalidateRequerySuggested();
            }
        }
    }

    public bool IsCallActive
    {
        get => _isCallActive;
        private set
        {
            if (SetProperty(ref _isCallActive, value))
            {
                RelayCommand.InvalidateRequerySuggested();
            }
        }
    }

    public bool IsNotificationVisible
    {
        get => _isNotificationVisible;
        private set => SetProperty(ref _isNotificationVisible, value);
    }

    public bool IsRussianEnabled
    {
        get => SettingsDraft.TranscriptionLanguages.Contains("ru", StringComparer.OrdinalIgnoreCase);
        set => SetLanguage("ru", value);
    }

    public bool IsEnglishEnabled
    {
        get => SettingsDraft.TranscriptionLanguages.Contains("en", StringComparer.OrdinalIgnoreCase);
        set => SetLanguage("en", value);
    }

    public bool HasSelectedRecording => SelectedRecording is not null;
    public bool HasAudioError => !string.IsNullOrWhiteSpace(AudioErrorText);
    public bool HasCurrentGuidance => CurrentGuidance is not null;
    public bool IsCurrentGuidanceLate => CurrentGuidance?.IsLate == true;
    public bool IsSelectedRecordingPlaying => SelectedRecording?.Id == _playingRecordingId;
    public int SelectedContextCount => Contexts.Count(item => item.IsSelected);
    public string SelectedContextText => SelectedContextCount switch
    {
        0 => "Контексты не выбраны",
        1 => "Выбран 1 контекст",
        >= 2 and <= 4 => $"Выбрано {SelectedContextCount} контекста",
        _ => $"Выбрано {SelectedContextCount} контекстов"
    };

    public string ContextCountText => string.IsNullOrWhiteSpace(ContextSearchText)
        ? $"{Contexts.Count} контекстов"
        : $"Найдено: {FilteredContexts.Cast<object>().Count()} из {Contexts.Count}";

    public string RecordingCountText => string.IsNullOrWhiteSpace(RecordingSearchText)
        ? $"{Recordings.Count} записей"
        : $"Найдено: {FilteredRecordings.Cast<object>().Count()} из {Recordings.Count}";

    public string CredentialStatusText => IsApiKeyAvailable
        ? "OpenAI подключён"
        : "Без API key доступна только запись";

    public string ContextEditorTitle => _editingContext is null ? "Новый контекст" : "Редактировать контекст";
    public string CallElapsedText => RecordingItemViewModel.FormatDuration(CallElapsed);
    public string IncomingSourceTitle => SelectedIncomingSource?.Title ?? "Источник не выбран";
    public string MicrophoneTitle => SelectedMicrophone?.Title ?? "Микрофон не выбран";
    public string LiveQuestionText => CurrentGuidance?.Question ?? string.Empty;
    public string LiveAnswerText => CurrentGuidance?.Answer ?? string.Empty;
    public string LiveAdviceText => CurrentGuidance?.Advice ?? string.Empty;
    public string LiveEvidenceText => CurrentGuidance?.Evidence ?? string.Empty;
    public string LiveTranscriptCountText => $"{LiveTranscriptTurns.Count} реплик";
    public string HistoryCountText => $"{AnswerHistory.Count} ответов";
    public string PlaybackGlyph => IsSelectedRecordingPlaying ? "" : "";
    public string PlaybackTimeText => $"{RecordingItemViewModel.FormatDuration(PlaybackElapsed)} / {RecordingItemViewModel.FormatDuration(PlaybackDuration)}";
    public IReadOnlyList<TranscriptTurn> SelectedRecordingTurns => SelectedRecording?.Turns ?? [];
    public IReadOnlyList<GuidanceCard> SelectedAnalysisCards => SelectedRecording?.AnalysisCards ?? [];

    public string GuidancePlaceholderTitle => GuidanceStatus switch
    {
        "LIVE-СОВЕТЫ ОТКЛЮЧЕНЫ" => "Live-советы выключены",
        "ДОСТИГНУТ ЛИМИТ КОНТЕКСТА" => "Слишком большой полный контекст",
        "ОСТАНОВЛЕНО ЛИМИТОМ" => "Достигнут лимит расходов",
        "АНАЛИЗ НЕДОСТУПЕН" => "Не удалось получить совет",
        _ => "Слушаю разговор…"
    };

    public string GuidancePlaceholderDetail => GuidanceStatus switch
    {
        "LIVE-СОВЕТЫ ОТКЛЮЧЕНЫ" => "Добавьте OpenAI API key в настройках. Запись продолжает работать.",
        "ДОСТИГНУТ ЛИМИТ КОНТЕКСТА" => "Текст не обрезан. Уменьшите выбранные контексты перед следующим звонком.",
        "ОСТАНОВЛЕНО ЛИМИТОМ" => "Запись и локальные аудиодорожки продолжаются.",
        "АНАЛИЗ НЕДОСТУПЕН" => "Запись продолжается; проверьте подключение и API key.",
        _ => "Совет появится здесь, когда собеседник задаст вопрос."
    };

    public async Task InitializeAsync()
    {
        if (IsInitialized)
        {
            return;
        }

        IsBusy = true;
        try
        {
            var bootstrap = await _coordinator.LoadAsync().ConfigureAwait(true);
            ReplaceContexts(bootstrap.Contexts);
            ReplaceRecordings(bootstrap.Recordings);
            SettingsDraft = CloneSettings(bootstrap.Settings);
            IsApiKeyAvailable = bootstrap.HasApiKey;
            IsInitialized = true;
            await RefreshSourcesAsync().ConfigureAwait(true);
        }
        catch (Exception exception)
        {
            ShowNotification($"Не удалось загрузить приложение: {exception.Message}");
        }
        finally
        {
            IsBusy = false;
        }
    }

    public async Task AddContextFilesAsync(IEnumerable<string> paths)
    {
        var normalized = paths.Where(path => !string.IsNullOrWhiteSpace(path)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (normalized.Length == 0)
        {
            return;
        }

        IsExtractingAttachments = true;
        try
        {
            foreach (var path in normalized)
            {
                var attachment = await _coordinator.ExtractContextFileAsync(path).ConfigureAwait(true);
                if (ContextAttachmentsDraft.All(item => item.ContentSha256 != attachment.ContentSha256))
                {
                    ContextAttachmentsDraft.Add(attachment);
                }
            }

            OnPropertyChanged(nameof(ContextAttachmentsDraft));
        }
        catch (Exception exception)
        {
            ShowNotification($"Не удалось обработать файл: {exception.Message}");
        }
        finally
        {
            IsExtractingAttachments = false;
        }
    }

    public async Task SeekPlaybackAsync(double progress)
    {
        if (SelectedRecording is null)
        {
            return;
        }

        try
        {
            var state = await _coordinator.SeekPlaybackAsync(SelectedRecording.Model, progress).ConfigureAwait(true);
            ApplyPlaybackState(state);
        }
        catch (Exception exception)
        {
            ShowNotification($"Не удалось перемотать запись: {exception.Message}");
        }
    }

    public async Task CompleteAudioExportAsync(AudioExportRequestedEventArgs request, string destinationPath)
    {
        try
        {
            await _coordinator.ExportAudioAsync(request.Recording, request.Kind, destinationPath).ConfigureAwait(true);
            ShowNotification($"Файл сохранён: {Path.GetFileName(destinationPath)}");
        }
        catch (Exception exception)
        {
            ShowNotification($"Не удалось сохранить аудио: {exception.Message}");
        }
    }

    private AsyncRelayCommand CreateAsyncCommand(Func<Task> execute, Func<bool>? canExecute = null)
    {
        var command = new AsyncRelayCommand(execute, canExecute);
        command.ExecutionFailed += (_, exception) => ShowNotification(exception.Message);
        return command;
    }

    private AsyncRelayCommand CreateAsyncCommand(Func<object?, Task> execute, Predicate<object?>? canExecute = null)
    {
        var command = new AsyncRelayCommand(execute, canExecute);
        command.ExecutionFailed += (_, exception) => ShowNotification(exception.Message);
        return command;
    }

    private void Navigate(object? parameter)
    {
        if (parameter is AppSection section)
        {
            CurrentSection = section;
        }
    }

    private async Task RefreshSourcesAsync()
    {
        if (IsRefreshingSources || IsCallActive)
        {
            return;
        }

        IsRefreshingSources = true;
        AudioErrorText = string.Empty;
        AudioStatusText = "Обновляем источники…";
        try
        {
            var catalog = await _coordinator.RefreshAudioSourcesAsync().ConfigureAwait(true);
            var incomingId = SelectedIncomingSource?.Id;
            var microphoneId = SelectedMicrophone?.Id;
            ReplaceCollection(IncomingSources, catalog.IncomingSources);
            ReplaceCollection(Microphones, catalog.Microphones);
            SelectedIncomingSource = IncomingSources.FirstOrDefault(item => item.Id == incomingId) ?? IncomingSources.FirstOrDefault();
            SelectedMicrophone = Microphones.FirstOrDefault(item => item.Id == microphoneId) ?? Microphones.FirstOrDefault();
            AudioStatusText = Microphones.Count == 0 ? "Микрофон не найден" : "Источники готовы";
            if (Microphones.Count == 0)
            {
                AudioErrorText = "Подключите микрофон и нажмите «Обновить».";
            }
        }
        catch (Exception exception)
        {
            AudioStatusText = "Источники недоступны";
            AudioErrorText = exception.Message;
        }
        finally
        {
            IsRefreshingSources = false;
        }
    }

    private bool CanStartCall() =>
        !IsBusy && !IsRefreshingSources && !IsCallActive && SelectedIncomingSource is not null && SelectedMicrophone is not null;

    private async Task StartCallAsync()
    {
        if (SelectedIncomingSource is null || SelectedMicrophone is null)
        {
            ShowNotification("Выберите источники звука.");
            return;
        }

        IsBusy = true;
        try
        {
            var selectedContexts = Contexts.Where(item => item.IsSelected).Select(item => item.Model).ToArray();
            await _coordinator.StartCallAsync(new CallStartOptions(
                SelectedIncomingSource,
                SelectedMicrophone,
                selectedContexts,
                CloneSettings(SettingsDraft))).ConfigureAwait(true);

            CurrentGuidance = null;
            LiveTranscriptTurns.Clear();
            AnswerHistory.Clear();
            CallElapsed = TimeSpan.Zero;
            IncomingLiveStatus = IsApiKeyAvailable ? "подключается" : "запись";
            OutgoingLiveStatus = IsApiKeyAvailable ? "подключается" : "запись";
            GuidanceStatus = IsApiKeyAvailable ? "АНАЛИЗИРУЕТ ОНЛАЙН" : "LIVE-СОВЕТЫ ОТКЛЮЧЕНЫ";
            IsCallActive = true;
            _callTimer.Start();
            LiveWindowRequested?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception exception)
        {
            AudioErrorText = exception.Message;
            ShowNotification($"Не удалось начать звонок: {exception.Message}");
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task EndCallAsync()
    {
        if (!IsCallActive)
        {
            return;
        }

        IsBusy = true;
        _callTimer.Stop();
        try
        {
            var recording = await _coordinator.EndCallAsync().ConfigureAwait(true);
            if (recording is not null)
            {
                var item = UpsertRecording(recording);
                SelectedRecording = item;
                CurrentSection = AppSection.Recordings;
            }

            ShowNotification("Запись звонка сохранена");
        }
        catch (Exception exception)
        {
            ShowNotification($"Не удалось завершить звонок: {exception.Message}");
        }
        finally
        {
            IsCallActive = false;
            IsBusy = false;
            LiveWindowCloseRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void SelectAllContexts()
    {
        _suspendContextPersistence = true;
        try
        {
            foreach (var context in Contexts)
            {
                context.IsSelected = true;
            }
        }
        finally
        {
            _suspendContextPersistence = false;
        }

        ContextSelectionChanged();
        ScheduleContextSave();
    }

    private void ClearContextSelection()
    {
        _suspendContextPersistence = true;
        try
        {
            foreach (var context in Contexts)
            {
                context.IsSelected = false;
            }
        }
        finally
        {
            _suspendContextPersistence = false;
        }

        ContextSelectionChanged();
        ScheduleContextSave();
    }

    private void BeginCreateContext()
    {
        CurrentSection = AppSection.Contexts;
        _editingContext = null;
        ContextTitleDraft = string.Empty;
        ContextBodyDraft = string.Empty;
        ContextAttachmentsDraft.Clear();
        OnPropertyChanged(nameof(ContextEditorTitle));
        IsContextEditorOpen = true;
    }

    private void BeginEditContext(object? parameter)
    {
        if (parameter is not ContextItemViewModel context)
        {
            return;
        }

        CurrentSection = AppSection.Contexts;
        _editingContext = context;
        ContextTitleDraft = context.Model.Title;
        ContextBodyDraft = context.Model.Body;
        ReplaceCollection(ContextAttachmentsDraft, context.Model.Attachments.Select(CloneAttachment));
        OnPropertyChanged(nameof(ContextEditorTitle));
        IsContextEditorOpen = true;
    }

    private async Task DeleteContextAsync(object? parameter)
    {
        if (parameter is not ContextItemViewModel context)
        {
            return;
        }

        context.PropertyChanged -= OnContextItemPropertyChanged;
        Contexts.Remove(context);
        FilteredContexts.Refresh();
        ContextSelectionChanged();
        await PersistContextsAsync().ConfigureAwait(true);
        ShowNotification("Контекст удалён");
    }

    private bool CanSaveContext() =>
        !IsExtractingAttachments &&
        !string.IsNullOrWhiteSpace(ContextTitleDraft) &&
        (!string.IsNullOrWhiteSpace(ContextBodyDraft) || ContextAttachmentsDraft.Count > 0);

    private async Task SaveContextAsync()
    {
        if (!CanSaveContext())
        {
            ShowNotification("Добавьте название и содержимое или файл.");
            return;
        }

        if (_editingContext is null)
        {
            var model = new CallContext
            {
                Title = ContextTitleDraft.Trim(),
                Body = ContextBodyDraft.Trim(),
                IsSelected = true,
                Attachments = ContextAttachmentsDraft.Select(CloneAttachment).ToList()
            };
            AddContext(model);
            ShowNotification("Контекст добавлен и выбран");
        }
        else
        {
            _editingContext.Model.Title = ContextTitleDraft.Trim();
            _editingContext.Model.Body = ContextBodyDraft.Trim();
            _editingContext.Model.Attachments = ContextAttachmentsDraft.Select(CloneAttachment).ToList();
            _editingContext.Refresh();
            ShowNotification("Контекст сохранён");
        }

        IsContextEditorOpen = false;
        _editingContext = null;
        FilteredContexts.Refresh();
        ContextSelectionChanged();
        await PersistContextsAsync().ConfigureAwait(true);
    }

    private void CancelContextEdit()
    {
        IsContextEditorOpen = false;
        _editingContext = null;
        ContextAttachmentsDraft.Clear();
    }

    private void RemoveContextAttachment(object? parameter)
    {
        if (parameter is ContextFileAttachment attachment)
        {
            ContextAttachmentsDraft.Remove(attachment);
            RelayCommand.InvalidateRequerySuggested();
        }
    }

    private async Task TogglePlaybackAsync()
    {
        if (SelectedRecording is null)
        {
            return;
        }

        try
        {
            var state = await _coordinator.TogglePlaybackAsync(SelectedRecording.Model).ConfigureAwait(true);
            ApplyPlaybackState(state);
        }
        catch (Exception exception)
        {
            ShowNotification($"Не удалось воспроизвести запись: {exception.Message}");
        }
    }

    private async Task OpenTranscriptAsync()
    {
        if (SelectedRecording is not null)
        {
            await RunRecordingActionAsync(
                () => _coordinator.OpenTranscriptAsync(SelectedRecording.Model),
                "Не удалось открыть transcript.txt").ConfigureAwait(true);
        }
    }

    private async Task RevealRecordingAsync()
    {
        if (SelectedRecording is not null)
        {
            await RunRecordingActionAsync(
                () => _coordinator.RevealRecordingAsync(SelectedRecording.Model),
                "Не удалось открыть папку записи").ConfigureAwait(true);
        }
    }

    private async Task RetryProcessingAsync()
    {
        if (SelectedRecording is null)
        {
            return;
        }

        await RunRecordingActionAsync(
            () => _coordinator.RetryPostCallProcessingAsync(SelectedRecording.Model),
            "Не удалось запустить обработку").ConfigureAwait(true);
        ShowNotification("Повторная обработка запущена");
    }

    private void RequestAudioExport(object? parameter)
    {
        if (SelectedRecording is null || parameter is not AudioExportKind kind)
        {
            return;
        }

        var fileName = kind switch
        {
            AudioExportKind.Combined => SelectedRecording.Model.CombinedAudioFileName ?? "combined.m4a",
            AudioExportKind.Incoming => SelectedRecording.Model.IncomingAudioFileName,
            AudioExportKind.Outgoing => SelectedRecording.Model.OutgoingAudioFileName,
            _ => "audio.m4a"
        };
        AudioExportRequested?.Invoke(this, new AudioExportRequestedEventArgs(SelectedRecording.Model, kind, fileName));
    }

    private async Task SaveSettingsAsync()
    {
        try
        {
            SettingsDraft.Validate();
            await _coordinator.SaveSettingsAsync(CloneSettings(SettingsDraft)).ConfigureAwait(true);
            SettingsStatus = "Настройки сохранены.";
            ShowNotification(SettingsStatus);
        }
        catch (Exception exception)
        {
            SettingsStatus = exception.Message;
        }
    }

    private async Task SaveApiKeyAsync()
    {
        var value = ApiKeyDraft.Trim();
        if (value.Length == 0)
        {
            return;
        }

        try
        {
            await _coordinator.SaveApiKeyAsync(value).ConfigureAwait(true);
            ApiKeyDraft = string.Empty;
            IsApiKeyAvailable = true;
            SettingsStatus = "API key сохранён локально.";
            ShowNotification(SettingsStatus);
        }
        catch (Exception exception)
        {
            SettingsStatus = exception.Message;
        }
    }

    private async Task DeleteApiKeyAsync()
    {
        try
        {
            await _coordinator.DeleteApiKeyAsync().ConfigureAwait(true);
            ApiKeyDraft = string.Empty;
            IsApiKeyAvailable = false;
            SettingsStatus = "API key удалён.";
            ShowNotification(SettingsStatus);
        }
        catch (Exception exception)
        {
            SettingsStatus = exception.Message;
        }
    }

    private async Task TestApiKeyAsync()
    {
        try
        {
            var typed = string.IsNullOrWhiteSpace(ApiKeyDraft) ? null : ApiKeyDraft.Trim();
            await _coordinator.TestApiKeyAsync(typed).ConfigureAwait(true);
            SettingsStatus = "Подключение к OpenAI работает.";
            ShowNotification(SettingsStatus);
        }
        catch (Exception exception)
        {
            SettingsStatus = $"Проверка не прошла: {exception.Message}";
        }
    }

    private async Task RunRecordingActionAsync(Func<Task> action, string errorPrefix)
    {
        try
        {
            await action().ConfigureAwait(true);
        }
        catch (Exception exception)
        {
            ShowNotification($"{errorPrefix}: {exception.Message}");
        }
    }

    private void ApplyPlaybackState(PlaybackUiState state)
    {
        _playingRecordingId = state.IsPlaying ? state.RecordingId : null;
        PlaybackElapsed = state.Elapsed;
        PlaybackDuration = state.Duration;
        PlaybackProgress = state.Progress;
        OnPropertyChanged(nameof(IsSelectedRecordingPlaying));
        OnPropertyChanged(nameof(PlaybackGlyph));
    }

    private void SetLanguage(string language, bool enabled)
    {
        var existing = SettingsDraft.TranscriptionLanguages
            .FirstOrDefault(item => string.Equals(item, language, StringComparison.OrdinalIgnoreCase));
        if (enabled && existing is null)
        {
            SettingsDraft.TranscriptionLanguages.Add(language);
        }
        else if (!enabled && existing is not null && SettingsDraft.TranscriptionLanguages.Count > 1)
        {
            SettingsDraft.TranscriptionLanguages.Remove(existing);
        }

        OnPropertyChanged(language == "ru" ? nameof(IsRussianEnabled) : nameof(IsEnglishEnabled));
    }

    private bool FilterContext(object item)
    {
        if (item is not ContextItemViewModel context || string.IsNullOrWhiteSpace(ContextSearchText))
        {
            return true;
        }

        var query = ContextSearchText.Trim();
        return context.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
               context.Body.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
               context.Model.Attachments.Any(attachment => attachment.FileName.Contains(query, StringComparison.CurrentCultureIgnoreCase));
    }

    private bool FilterRecording(object item)
    {
        if (item is not RecordingItemViewModel recording || string.IsNullOrWhiteSpace(RecordingSearchText))
        {
            return true;
        }

        var query = RecordingSearchText.Trim();
        return recording.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
               recording.FolderName.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
               recording.Turns.Any(turn => turn.Text.Contains(query, StringComparison.CurrentCultureIgnoreCase));
    }

    private void ReplaceContexts(IEnumerable<CallContext> contexts)
    {
        foreach (var existing in Contexts)
        {
            existing.PropertyChanged -= OnContextItemPropertyChanged;
        }

        Contexts.Clear();
        foreach (var context in contexts)
        {
            AddContext(context);
        }

        FilteredContexts.Refresh();
        ContextSelectionChanged();
    }

    private void AddContext(CallContext context)
    {
        var item = new ContextItemViewModel(context);
        item.PropertyChanged += OnContextItemPropertyChanged;
        Contexts.Add(item);
    }

    private void ReplaceRecordings(IEnumerable<Recording> recordings)
    {
        Recordings.Clear();
        foreach (var recording in recordings.OrderByDescending(item => item.StartedAt))
        {
            Recordings.Add(new RecordingItemViewModel(recording));
        }

        SelectedRecording = Recordings.FirstOrDefault();
        FilteredRecordings.Refresh();
        OnPropertyChanged(nameof(RecordingCountText));
    }

    private RecordingItemViewModel UpsertRecording(Recording recording)
    {
        var existing = Recordings.FirstOrDefault(item => item.Id == recording.Id);
        if (existing is null)
        {
            existing = new RecordingItemViewModel(recording);
            var index = Recordings.TakeWhile(item => item.Model.StartedAt > recording.StartedAt).Count();
            Recordings.Insert(index, existing);
        }
        else
        {
            existing.Replace(recording);
        }

        FilteredRecordings.Refresh();
        OnPropertyChanged(nameof(RecordingCountText));
        return existing;
    }

    private void OnContextItemPropertyChanged(object? sender, PropertyChangedEventArgs eventArgs)
    {
        if (eventArgs.PropertyName != nameof(ContextItemViewModel.IsSelected))
        {
            return;
        }

        ContextSelectionChanged();
        if (!_suspendContextPersistence)
        {
            ScheduleContextSave();
        }
    }

    private void ContextSelectionChanged()
    {
        OnPropertyChanged(nameof(SelectedContextCount));
        OnPropertyChanged(nameof(SelectedContextText));
        RelayCommand.InvalidateRequerySuggested();
    }

    private void ScheduleContextSave()
    {
        _contextSaveCancellation?.Cancel();
        _contextSaveCancellation?.Dispose();
        _contextSaveCancellation = new CancellationTokenSource();
        var token = _contextSaveCancellation.Token;
        _ = PersistContextsAfterDelayAsync(token);
    }

    private async Task PersistContextsAfterDelayAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(180, cancellationToken).ConfigureAwait(true);
            await PersistContextsAsync(cancellationToken).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception exception)
        {
            ShowNotification($"Не удалось сохранить контексты: {exception.Message}");
        }
    }

    private async Task PersistContextsAsync(CancellationToken cancellationToken = default) =>
        await _coordinator.SaveContextsAsync(Contexts.Select(item => item.Model).ToArray(), cancellationToken).ConfigureAwait(true);

    private void OnLiveSnapshotChanged(LiveSessionSnapshot snapshot) => DispatchToUi(() =>
    {
        CallElapsed = snapshot.Elapsed;
        IncomingLiveStatus = snapshot.IncomingStatus;
        OutgoingLiveStatus = snapshot.OutgoingStatus;
        GuidanceStatus = snapshot.GuidanceStatus;
        CurrentGuidance = snapshot.CurrentGuidance;
        ReplaceCollection(LiveTranscriptTurns, snapshot.Transcript.TakeLast(6));
        ReplaceCollection(AnswerHistory, snapshot.History.OrderByDescending(item => item.CreatedAt));
        OnPropertyChanged(nameof(LiveTranscriptCountText));
        OnPropertyChanged(nameof(HistoryCountText));

        if (IsCallActive && !snapshot.IsCallActive)
        {
            _callTimer.Stop();
            IsCallActive = false;
            IsBusy = false;
            if (!string.IsNullOrWhiteSpace(snapshot.Error))
            {
                ShowNotification($"Запись аварийно остановлена: {snapshot.Error}");
            }
            LiveWindowCloseRequested?.Invoke(this, EventArgs.Empty);
        }
    });

    private void OnRecordingChanged(Recording recording) => DispatchToUi(() =>
    {
        var item = UpsertRecording(recording);
        if (SelectedRecording?.Id == item.Id)
        {
            SelectedRecording = item;
            OnPropertyChanged(nameof(SelectedRecordingTurns));
            OnPropertyChanged(nameof(SelectedAnalysisCards));
        }
    });

    private void OnCallTimerTick(object? sender, EventArgs eventArgs)
    {
        if (IsCallActive)
        {
            CallElapsed += TimeSpan.FromSeconds(1);
        }
    }

    private void ShowNotification(string text)
    {
        DispatchToUi(() =>
        {
            NotificationText = text;
            IsNotificationVisible = true;
            _notificationTimer.Stop();
            _notificationTimer.Start();
        });
    }

    private static AppSettings CloneSettings(AppSettings source) => new()
    {
        ResponsesModelId = source.ResponsesModelId,
        RealtimeTranscriptionModelId = source.RealtimeTranscriptionModelId,
        FileTranscriptionModelId = source.FileTranscriptionModelId,
        TranscriptionLanguages = [.. source.TranscriptionLanguages],
        AnswerStyle = source.AnswerStyle,
        AnswerLanguage = source.AnswerLanguage,
        BriefAnswerMaxWords = source.BriefAnswerMaxWords,
        DetailedAnswerMaxWords = source.DetailedAnswerMaxWords,
        AdviceMaxWords = source.AdviceMaxWords,
        MaxOutputTokens = source.MaxOutputTokens,
        PerCallSpendLimitUsd = source.PerCallSpendLimitUsd
    };

    private static ContextFileAttachment CloneAttachment(ContextFileAttachment source) => new()
    {
        Id = source.Id,
        FileName = source.FileName,
        MediaType = source.MediaType,
        ByteCount = source.ByteCount,
        ContentSha256 = source.ContentSha256,
        ExtractedText = source.ExtractedText
    };

    private static void ReplaceCollection<T>(ObservableCollection<T> target, IEnumerable<T> values)
    {
        target.Clear();
        foreach (var value in values)
        {
            target.Add(value);
        }
    }

    private static void DispatchToUi(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess())
        {
            action();
            return;
        }

        dispatcher.Invoke(action);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _callTimer.Stop();
        _notificationTimer.Stop();
        _contextSaveCancellation?.Cancel();
        _contextSaveCancellation?.Dispose();
        _coordinator.LiveSnapshotChanged -= OnLiveSnapshotChanged;
        _coordinator.RecordingChanged -= OnRecordingChanged;
        foreach (var context in Contexts)
        {
            context.PropertyChanged -= OnContextItemPropertyChanged;
        }
    }
}
