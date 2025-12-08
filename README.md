# Loopy Pro Test Runner

A menu bar app for running and monitoring Loopy Pro unit tests.

## Features

- Menu bar interface with status indicators
- Automatic test execution triggered by git post-commit hooks
- Test history with detailed output viewing
- Pause/resume test execution
- Persistent test results storage
- Colored output display

## Building

### Prerequisites

- XcodeGen (install via Homebrew: `brew install xcodegen`)
- Xcode 16.0+
- macOS 15.0+

### Build Steps

1. Generate Xcode project:
   ```bash
   xcodegen generate
   ```

2. Build the app:
   ```bash
   xcodebuild -project Tests.xcodeproj -scheme Tests -configuration Debug build
   ```

3. Build the CLI tool (automatically built with app):
   ```bash
   xcodebuild -project Tests.xcodeproj -scheme TestsCLI -configuration Debug build
   ```

The built app will be at: `.DerivedData/Products/Debug/Tests.app`

The CLI tool will be bundled at: `Tests.app/Contents/MacOS/TestsCLI`

## Setup

### Post-Commit Hook

Update your git post-commit hook to use the CLI tool:

```bash
#!/bin/sh
/path/to/Tests.app/Contents/MacOS/TestsCLI trigger
```

Replace `/path/to/` with the actual path to your Tests.app bundle.

## Usage

- Click the menu bar icon to access options
- "Run Tests Now" - Manually trigger a test run
- "Pause" - Stop the currently running tests
- "Test History" - View past test runs and their output
- "Quit" - Exit the app

## Architecture

- **Menu Bar App**: SwiftUI-based menu bar application
- **CLI Tool**: Command-line interface for git hooks
- **Test Runner**: Manages xcodebuild process execution
- **Test Result Store**: JSON-based persistence for test history
- **Workspace Finder**: Auto-detects Loopy Pro workspace location

## Storage Locations

- Test results: `~/Library/Application Support/Tests/`
- Temporary workspace: `~/Library/Application Support/Tests/TempWorkspace`

