# Contributing to Callya

Thanks for helping make Callya better. Bug reports, focused feature proposals,
documentation improvements, tests, and code contributions are welcome.

## Before opening a pull request

1. Search existing issues and pull requests.
2. Open an issue first for large product or architecture changes.
3. Keep the change focused and avoid unrelated formatting rewrites.
4. Never commit API keys, recordings, transcripts, call contexts, or other
   personal data.

## Development checks

### macOS

Requirements: macOS 14.2+, Swift 5.9+, and Xcode 15.1+.

```bash
swift test
./Scripts/build-app.sh
```

Real system-audio capture should be tested from the generated app bundle so
macOS can apply its privacy usage descriptions correctly.

### Windows

Requirements: Windows 11 x64 and the .NET 10 SDK.

```powershell
dotnet restore "windows/Callya.slnx"
dotnet test "windows/Callya.slnx" --configuration Release
dotnet build "windows/Callya.slnx" --configuration Release
```

### Landing page

```bash
cd website
npm ci
npm run build
```

## Pull requests

Describe the problem, the chosen approach, and how you tested it. Include UI
screenshots for visible changes. By contributing, you agree that your work is
licensed under the repository's MIT License.
