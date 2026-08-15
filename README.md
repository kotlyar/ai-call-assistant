# AI Call Assistant

Native macOS call copilot prototype built with SwiftUI.

The current version focuses on the product experience:

- separate incoming and outgoing audio source selection;
- reusable call contexts with create, edit, delete, and per-call selection;
- a compact floating live teleprompter with the current answer, advice, and previous answers;
- a recordings library with separate audio export options and generated transcript files.

Audio capture, transcription, AI generation, and media export are represented by mock service boundaries for now. They can be replaced without rewriting the interface.

## Requirements

- macOS 13 or newer
- Swift 5.9 or newer
- Xcode 15 or newer for IDE development

## Run the prototype

```bash
swift run AICallAssistant
```

Or open `Package.swift` in Xcode.

## Build an app bundle

```bash
./Scripts/build-app.sh
open "dist/AI Call Assistant.app"
```

The local bundle is ad-hoc signed for development. Distribution will require Developer ID signing and notarization.
