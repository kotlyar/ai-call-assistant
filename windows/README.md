# Callya для Windows

Нативная Windows-версия Callya с тем же основным сценарием, что и macOS-клиент:

- запись системного звука и выбранного микрофона в отдельные дорожки;
- выбор всего системного звука или конкретного приложения;
- два независимых live-потока распознавания OpenAI;
- контексты звонка и подсказки на вопросы собеседника;
- always-on-top суфлёр, исключаемый из стандартного screen capture;
- локальная библиотека записей, транскрипт и итоговый AI-анализ;
- пользователь самостоятельно вводит OpenAI Platform API key.

## Системные требования

- Windows 11, x64;
- для сборки: .NET 10 SDK и Visual Studio с workload **.NET desktop development**;
- доступ к микрофону в **Settings → Privacy & security → Microphone**.

Windows 11 является осознанным минимумом. Режим «выбранное приложение» использует process-loopback WASAPI, доступный начиная с Windows build 20348. Режим «весь системный звук» использует обычный WASAPI loopback.

## Запуск из исходников

```powershell
cd windows
dotnet restore '.\Callya.slnx'
dotnet run --project '.\src\AICallAssistant.Desktop\AICallAssistant.Desktop.csproj'
```

API key вводится в разделе **Настройки**. Он шифруется Windows DPAPI в контексте текущего пользователя и не записывается в исходники, настройки JSON, логи или publish-артефакт.

## Portable-сборка

```powershell
cd windows
.\scripts\publish-windows.ps1 -Runtime win-x64
```

Результат:

```text
windows\artifacts\package\Callya-Windows-win-x64.zip
windows\artifacts\package\Callya-Windows-win-x64.zip.sha256
```

Это self-contained приложение: пользователю не нужно отдельно устанавливать .NET. Распакуйте ZIP в обычную папку и запустите `Callya.exe`.

## Локальные данные

```text
%LOCALAPPDATA%\com.aicallassistant.desktop\contexts.json
%LOCALAPPDATA%\com.aicallassistant.desktop\settings.json
%LOCALAPPDATA%\com.aicallassistant.desktop\Secrets\openai-api-key.dpapi
%USERPROFILE%\Documents\AI Call Assistant\<timestamp_uuid>\
```

Имена папок данных сохранены прежними, чтобы Callya видела контексты, настройки, ключ и записи из уже установленной версии.

Запись работает и без ключа. В этом случае аудиофайлы сохраняются локально, а сетевые этапы ждут, пока пользователь добавит ключ и нажмёт повторную обработку.

## Скрытие при демонстрации экрана

Ко всем окнам приложения применяется `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`. В стандартных Windows Graphics Capture-сценариях окно не попадает в запись/шаринг. Microsoft определяет это как best-effort защиту: нестандартный рекордер или захват камерой монитора обойти её может. Перед распространением сборки прогоните матрицу из [ACCEPTANCE_TESTS.md](docs/ACCEPTANCE_TESTS.md) на реальном Windows 11 ПК.

## Проверки

```powershell
dotnet test '.\Callya.slnx' -c Release
dotnet build '.\Callya.slnx' -c Release
```

Кроссплатформенный Core и его тесты также можно собирать на macOS/Linux. WPF, WASAPI, DPAPI и реальный publish проверяются на Windows runner и физическом Windows 11 компьютере.
