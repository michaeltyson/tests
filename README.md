# Tests

A macOS menu bar app for running and monitoring Xcode test suites from a Git repository.

## Features

- Menu bar interface with status indicators
- Automatic test execution triggered by git post-commit hooks
- Test history with detailed output viewing
- Pause/resume test execution
- Branch and commit selection from the reports window
- Configurable repository, workspace, scheme, and build options
- Persistent test results storage
- Colored output display

## Building

### Prerequisites

- XcodeGen (install via Homebrew: `brew install xcodegen`)
- Xcode 16.0+
- macOS 15.0+
- Optional: xcbeautify (install via Homebrew: `brew install xcbeautify`)

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

Open the app from the built bundle, click the menu bar icon, and choose **Settings...**.

Configure:

- Repository path: the Git repository to clone into the app's disposable workspace
- Workspace and scheme: inferred from the repository, with editable overrides for ambiguous projects
- Default branch: used for manual runs when no branch or commit is selected

### Post-Commit Hook

To trigger tests automatically after commits, use the bundled post-commit hook:

```bash
ln -s /path/to/Tests.app/Contents/Resources/post-commit /path/to/repo/.git/hooks/post-commit
```

Or update your git post-commit hook to call the CLI tool directly:

```bash
#!/bin/sh
branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || exit 0
/path/to/Tests.app/Contents/MacOS/TestsCLI trigger --branch "$branch"
```

Replace `/path/to/` with the actual path to your Tests.app bundle.

## Usage

- Click the menu bar icon to access options
- "Run Tests Now" - Manually trigger a test run
- "Pause" - Stop the currently running tests
- "Test History" - View past test runs and their output
- Option-click "Run Tests Now" - Choose a branch before running
- "Quit" - Exit the app

## Architecture

- **Menu Bar App**: SwiftUI-based menu bar application
- **CLI Tool**: Command-line interface for git hooks
- **Test Runner**: Manages xcodebuild process execution
- **Test Result Store**: JSON-based persistence for test history
- **Workspace Finder**: Auto-detects the configured repository workspace

## Storage Locations

- Test results: `~/Library/Application Support/Tests/`
- Temporary workspace: `~/Library/Application Support/Tests/TempWorkspace`
