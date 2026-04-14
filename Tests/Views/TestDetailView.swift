//
//  TestDetailView.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import SwiftUI
import AppKit

struct TestDetailView: View {
    let testRun: TestRun
    @State private var copied = false
    @State private var failureRanges: [NSRange] = []
    @State private var currentFailureIndex: Int = -1
    @State private var hasAutoScrolled = false
    
    private var outputLog: String? {
        testRun.outputLog
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header section - fixed at top
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 12) {
                        statusBadge
                        
                        // Test counts (if available)
                        if let passingCount = testRun.passingCount, let failingCount = testRun.failingCount {
                            HStack(spacing: 10) {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: 11))
                                    Text("\(passingCount)")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                
                                if failingCount > 0 {
                                    HStack(spacing: 4) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.system(size: 11))
                                        Text("\(failingCount)")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                }
                                
                                if let totalCount = testRun.totalCount {
                                    Text("of \(totalCount)")
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.thinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                            .cornerRadius(6)
                        }
                    }
                    
                    Spacer()
                    Button(action: copyToClipboard) {
                        Text(copied ? "Copied!" : "Copy Output")
                    }
                    .buttonStyle(.bordered)
                }
                
                HStack(spacing: 12) {
                    Text("Timestamp: \(testRun.timestamp.formatted(date: .complete, time: .complete))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let branchName = testRun.branchName {
                        Text("Branch: \(branchName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                
                if let duration = testRun.duration {
                    Text("Duration: \(formatDuration(duration))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let errorDescription = testRun.errorDescription {
                    Text("Error: \(errorDescription)")
                        .font(.headline)
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
            
            // Output section - takes remaining space, pinned to bottom
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Output")
                        .font(.headline)
                    
                    Spacer()
                    
                    // Navigation buttons for failing tests
                    if let output = outputLog, !output.isEmpty, testRun.failingCount ?? 0 > 0 {
                        HStack(spacing: 4) {
                            Button(action: { scrollToPreviousFailure() }) {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .help("Previous failure")
                            
                            Button(action: { scrollToNextFailure() }) {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .help("Next failure")
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top)
                
                if let output = outputLog, !output.isEmpty {
                    TerminalOutputView(
                        text: output,
                        failureRanges: failureRanges,
                        currentFailureIndex: $currentFailureIndex
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .modifier(OutputPaneModifier())
                    .onAppear {
                        // Find ranges in the displayed text (after ANSI parsing simulation)
                        findFailureRangesInDisplayedText(in: output)
                        
                        // Auto-scroll to first failure if there are any
                        if !failureRanges.isEmpty && !hasAutoScrolled {
                            hasAutoScrolled = true
                            // Delay slightly to ensure text view is laid out
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToFailure(at: 0)
                            }
                        }
                    }
                    .onChange(of: outputLog) { _, newOutput in
                        if let newOutput = newOutput {
                            findFailureRangesInDisplayedText(in: newOutput)
                            // Reset auto-scroll flag when output changes
                            hasAutoScrolled = false
                        }
                    }
                    .onChange(of: failureRanges) { _, newRanges in
                        // Auto-scroll to first failure when ranges are found
                        if !newRanges.isEmpty && !hasAutoScrolled {
                            hasAutoScrolled = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToFailure(at: 0)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Text("No output available")
                            .foregroundColor(.secondary)
                        if outputLog == nil {
                            Text("(Output was not saved)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("(Output is empty - length: \(outputLog?.count ?? 0))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text("TestRun ID: \(testRun.id.uuidString)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("outputLog value: \(outputLog != nil ? "exists" : "nil")")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    
    private var statusBadge: some View {
        HStack {
            Image(systemName: iconName)
            Text(testRun.status.rawValue.capitalized)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(backgroundColor)
        .foregroundColor(foregroundColor)
        .cornerRadius(8)
    }
    
    private var iconName: String {
        switch testRun.status {
        case .success:
            return "checkmark.circle.fill"
        case .failed, .error:
            return "xmark.circle.fill"
        case .warnings:
            return "exclamationmark.triangle.fill"
        case .running:
            return "flask.fill"
        case .paused:
            return "pause.circle.fill"
        }
    }
    
    private var backgroundColor: Color {
        switch testRun.status {
        case .success:
            return .green.opacity(0.2)
        case .failed, .error:
            return .red.opacity(0.2)
        case .warnings:
            return .yellow.opacity(0.2)
        case .running:
            return .blue.opacity(0.2)
        case .paused:
            return .orange.opacity(0.2)
        }
    }
    
    private var foregroundColor: Color {
        switch testRun.status {
        case .success:
            return .green
        case .failed, .error:
            return .red
        case .warnings:
            return .yellow
        case .running:
            return .blue
        case .paused:
            return .orange
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
    
    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(testRun.outputLog ?? "", forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
    
    // Find ranges in text after removing ANSI codes (to match what's displayed)
    private func findFailureRangesInDisplayedText(in text: String) {
        // Remove ANSI codes to get the displayed text
        let displayedText = removeANSICodes(from: text)
        findFailureRanges(in: displayedText, originalText: text)
    }
    
    private func removeANSICodes(from text: String) -> String {
        // Remove ANSI escape sequences to match what TerminalOutputView displays
        let pattern = #"\x1B?\[([0-9;]*)m"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsString = text as NSString
            let range = NSRange(location: 0, length: nsString.length)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        return text
    }
    
    private func findFailureRanges(in displayedText: String, originalText: String) {
        var ranges: [NSRange] = []
        let nsString = displayedText as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        
        // Use regex to find failure patterns more accurately
        // Pattern 1: xcbeautify format - find the ✖ marker itself
        let xcbeautifyPattern = #"[✖✗×]"#
        if let regex = try? NSRegularExpression(pattern: xcbeautifyPattern, options: []) {
            let matches = regex.matches(in: displayedText, options: [], range: fullRange)
            for match in matches {
                // Check if this is actually a test failure line
                let lineRange = nsString.lineRange(for: match.range)
                let line = nsString.substring(with: lineRange)
                if line.contains("test") && (line.contains("seconds") || line.contains("failed")) {
                    // Use the position of the failure marker itself (zero-length range)
                    let markerRange = NSRange(location: match.range.location, length: 0)
                    // Only add if not already in ranges (within 50 chars)
                    if !ranges.contains(where: { abs($0.location - markerRange.location) < 50 }) {
                        ranges.append(markerRange)
                    }
                }
            }
        }
        
        // Pattern 2: Standard xcodebuild format - find "failed" keyword
        let testCasePattern = #"Test Case.*?failed"#
        if let regex = try? NSRegularExpression(pattern: testCasePattern, options: []) {
            let matches = regex.matches(in: displayedText, options: [], range: fullRange)
            for match in matches {
                // Find where "failed" appears in the match
                let failedRange = nsString.range(of: "failed", options: [], range: match.range)
                if failedRange.location != NSNotFound {
                    // Use position at start of "failed" (zero-length range)
                    let scrollRange = NSRange(location: failedRange.location, length: 0)
                    // Avoid duplicates
                    if !ranges.contains(where: { abs($0.location - scrollRange.location) < 50 }) {
                        ranges.append(scrollRange)
                    }
                }
            }
        }
        
        // Sort ranges by location
        ranges.sort { $0.location < $1.location }
        
        failureRanges = ranges
        if !ranges.isEmpty {
            currentFailureIndex = 0
        } else {
            currentFailureIndex = -1
        }
    }
    
    private func scrollToPreviousFailure() {
        guard !failureRanges.isEmpty else { return }
        currentFailureIndex = (currentFailureIndex - 1 + failureRanges.count) % failureRanges.count
        scrollToFailure(at: currentFailureIndex)
    }
    
    private func scrollToNextFailure() {
        guard !failureRanges.isEmpty else { return }
        currentFailureIndex = (currentFailureIndex + 1) % failureRanges.count
        scrollToFailure(at: currentFailureIndex)
    }
    
    private func scrollToFailure(at index: Int) {
        guard index >= 0 && index < failureRanges.count else { return }
        let range = failureRanges[index]
        // Post notification that TerminalOutputView can observe
        NotificationCenter.default.post(
            name: NSNotification.Name("ScrollToRange"),
            object: nil,
            userInfo: ["range": range]
        )
    }
    
    private func scrollToRange(_ range: NSRange) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ScrollToRange"),
            object: nil,
            userInfo: ["range": range]
        )
    }
}

struct TerminalOutputView: NSViewRepresentable {
    let text: String
    let failureRanges: [NSRange]
    let followsTail: Bool
    @Binding var currentFailureIndex: Int
    
    init(
        text: String,
        failureRanges: [NSRange] = [],
        followsTail: Bool = false,
        currentFailureIndex: Binding<Int> = .constant(-1)
    ) {
        self.text = text
        self.failureRanges = failureRanges
        self.followsTail = followsTail
        self._currentFailureIndex = currentFailureIndex
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        
        // Configure text view
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor.labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        
        // Enable copy functionality
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        
        // Configure text container for wrapping
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        
        // Configure scroll view
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        
        // Enable frame change notifications for width tracking
        scrollView.contentView.postsFrameChangedNotifications = true
        
        // Set up frame change observer to keep text view width in sync
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { _ in
            updateTextViewWidth(textView: textView, scrollView: scrollView)
        }
        
        // Set delegate for copy handling
        textView.delegate = context.coordinator
        
        // Store observer in context for cleanup
        context.coordinator.frameObserver = observer
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.followsTail = followsTail
        
        // Add key event monitoring for copy command (needed for menu bar apps)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak textView, weak coordinator = context.coordinator] event -> NSEvent? in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
                if let textView = textView, let coordinator = coordinator {
                    coordinator.performCopy(from: textView)
                    return nil // Consume the event
                }
            }
            return event
        }
        context.coordinator.keyEventMonitor = monitor
        
        // Set initial text and layout
        let attributedString = parseANSI(text, failureRanges: failureRanges)
        textView.textStorage?.setAttributedString(attributedString)
        
        // Update width after initial layout
        DispatchQueue.main.async {
            updateTextViewWidth(textView: textView, scrollView: scrollView)
            if followsTail {
                scrollToBottom(textView: textView, scrollView: scrollView)
            }
        }
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        
        // Update coordinator references
        context.coordinator.textView = textView
        context.coordinator.scrollView = nsView
        context.coordinator.failureRanges = failureRanges
        context.coordinator.currentFailureIndex = currentFailureIndex
        context.coordinator.followsTail = followsTail
        
        // Update width to match scroll view
        updateTextViewWidth(textView: textView, scrollView: nsView)
        
        // Update text if it changed
        let currentText = textView.string
        guard currentText != text else { return }
        
        // Check if user is at bottom before updating
        let isAtBottom = isScrolledToBottom(textView: textView, scrollView: nsView)
        
        // Update text content with failure highlighting
        let attributedString = parseANSI(text, failureRanges: failureRanges)
        textView.textStorage?.setAttributedString(attributedString)
        
        // Update layout and frame
        updateTextViewLayout(textView: textView, scrollView: nsView)
        
        // Auto-scroll to bottom if user was already there
        if followsTail && isAtBottom {
            scrollToBottom(textView: textView, scrollView: nsView)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.failureRanges = failureRanges
        coordinator.currentFailureIndex = currentFailureIndex
        
        // Set up notification observer for scroll requests
        coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ScrollToRange"),
            object: nil,
            queue: .main
        ) { [weak coordinator] notification in
            if let range = notification.userInfo?["range"] as? NSRange {
                coordinator?.scrollToRange(range)
            }
        }
        
        return coordinator
    }
    
    // MARK: - Helper Methods
    
    private func updateTextViewWidth(textView: NSTextView, scrollView: NSScrollView) {
        let contentWidth = scrollView.contentView.bounds.width
        guard contentWidth > 0, abs(textView.frame.width - contentWidth) > 1.0 else { return }
        
        let currentHeight = textView.frame.height
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: currentHeight)
        updateTextViewLayout(textView: textView, scrollView: scrollView)
    }
    
    private func updateTextViewLayout(textView: NSTextView, scrollView: NSScrollView) {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        
        let contentWidth = scrollView.contentView.bounds.width
        let finalWidth = contentWidth > 0 ? contentWidth : textView.frame.width
        let textSize = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? NSRect.zero
        let newHeight = max(100, textSize.height + 20)
        
        textView.frame = NSRect(x: 0, y: 0, width: finalWidth, height: newHeight)
    }
    
    private func isScrolledToBottom(textView: NSTextView, scrollView: NSScrollView) -> Bool {
        let clipView = scrollView.contentView
        let documentRect = textView.bounds
        let visibleRect = clipView.bounds
        let currentY = clipView.bounds.origin.y
        let maxY = max(0, documentRect.height - visibleRect.height)
        return abs(currentY - maxY) < 5.0
    }
    
    private func scrollToBottom(textView: NSTextView, scrollView: NSScrollView) {
        DispatchQueue.main.async {
            let clipView = scrollView.contentView
            let documentRect = textView.bounds
            let visibleRect = clipView.bounds
            let maxY = max(0, documentRect.height - visibleRect.height)
            clipView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var frameObserver: NSObjectProtocol?
        var scrollObserver: NSObjectProtocol?
        var keyEventMonitor: Any?
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var failureRanges: [NSRange] = []
        var currentFailureIndex: Int = -1
        var followsTail = false
        
        override init() {
            super.init()
        }
        
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Handle copy command - check for copy selector
            if commandSelector.description.contains("copy") || commandSelector == NSSelectorFromString("copy:") {
                performCopy(from: textView)
                return true
            }
            return false
        }
        
        @objc func performCopy(from textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            if selectedRange.length > 0 {
                let selectedText = (textView.string as NSString).substring(with: selectedRange)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(selectedText, forType: .string)
            }
        }
        
        // Handle key events for copy (Cmd-C)
        func handleKeyEvent(_ event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
                if let textView = textView {
                    performCopy(from: textView)
                    return true
                }
            }
            return false
        }
        
        func scrollToRange(_ range: NSRange) {
            guard let textView = textView, let scrollView = scrollView else { return }
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            
            // Ensure the range is valid
            let textLength = textView.string.utf16.count
            guard range.location < textLength else { return }
            
            DispatchQueue.main.async {
                // Ensure layout is up to date
                layoutManager.ensureLayout(for: textContainer)
                
                // Convert character range to glyph range
                var actualCharRange = NSRange()
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: &actualCharRange)
                
                guard glyphRange.location != NSNotFound else { return }
                
                // Get the bounding rect for the glyph range in text container coordinates
                let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                
                // Get the visible rect
                let clipView = scrollView.contentView
                let visibleRect = clipView.bounds
                
                // Calculate target scroll position
                // We want the rect to appear near the top of the visible area
                // In flipped coordinates (which NSTextView uses), Y=0 is at top
                // The rect.origin.y is relative to the text container
                let targetY = rect.origin.y - 20 // Small offset from top
                
                // Clamp to valid scroll range
                let documentHeight = textView.bounds.height
                let maxY = max(0, documentHeight - visibleRect.height)
                let clampedY = max(0, min(targetY, maxY))
                
                // Scroll the clip view
                clipView.scroll(to: NSPoint(x: 0, y: clampedY))
                scrollView.reflectScrolledClipView(clipView)
                
                // Also use scrollRangeToVisible as a fallback to ensure it's visible
                textView.scrollRangeToVisible(actualCharRange)
                
                // Highlight the range briefly
                textView.setSelectedRange(actualCharRange)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                }
            }
        }
        
        deinit {
            if let observer = frameObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = scrollObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let monitor = keyEventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
    
    static func == (lhs: TerminalOutputView, rhs: TerminalOutputView) -> Bool {
        return lhs.text == rhs.text && lhs.followsTail == rhs.followsTail
    }
    
    private func parseANSI(_ text: String, failureRanges: [NSRange] = []) -> NSAttributedString {
        // Use a more efficient parsing approach
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let defaultColor = NSColor.labelColor
        
        // Pattern to match ANSI escape sequences: [ followed by codes and 'm'
        // Also handle ESC[ format, but match [32m format that xcbeautify outputs
        // Match: optional ESC character, then [, then codes, then m
        let pattern = #"\x1B?\[([0-9;]*)m"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let nsString = text as NSString
        let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length)) ?? []
        
        var lastIndex = 0
        var currentColor = defaultColor
        
        for match in matches {
            // Add text before the escape sequence (this excludes the escape sequence)
            if match.range.location > lastIndex {
                let range = NSRange(location: lastIndex, length: match.range.location - lastIndex)
                let substring = nsString.substring(with: range)
                if !substring.isEmpty {
                    result.append(NSAttributedString(
                        string: substring,
                        attributes: [.foregroundColor: currentColor, .font: font]
                    ))
                }
            }
            
            // Parse the escape code (group 1 contains the actual codes like "32" or "0")
            if match.numberOfRanges > 1 {
                let codeRange = match.range(at: 1)
                let code = nsString.substring(with: codeRange)
                if let newColor = ansiColor(for: code) {
                    currentColor = newColor
                } else if code == "0" || code.isEmpty {
                    currentColor = defaultColor
                }
            }
            
            // Skip past the entire escape sequence (don't include it in output)
            lastIndex = match.range.location + match.range.length
        }
        
        // Add remaining text
        if lastIndex < nsString.length {
            let range = NSRange(location: lastIndex, length: nsString.length - lastIndex)
            let substring = nsString.substring(with: range)
            if !substring.isEmpty {
                result.append(NSAttributedString(
                    string: substring,
                    attributes: [.foregroundColor: currentColor, .font: font]
                ))
            }
        }
        
        // Apply failure line highlighting
        applyFailureHighlighting(to: result, failureRanges: failureRanges)
        
        return result
    }
    
    private func applyFailureHighlighting(to attributedString: NSMutableAttributedString, failureRanges: [NSRange]) {
        guard !failureRanges.isEmpty else { return }
        
        let redBackground = NSColor.systemRed.withAlphaComponent(0.15)
        let string = attributedString.string as NSString
        
        for failureRange in failureRanges {
            // Find the line containing this range
            let lineRange = string.lineRange(for: failureRange)
            
            // Apply background color to the entire line
            if lineRange.location < attributedString.length {
                let clampedRange = NSRange(
                    location: lineRange.location,
                    length: min(lineRange.length, attributedString.length - lineRange.location)
                )
                attributedString.addAttribute(.backgroundColor, value: redBackground, range: clampedRange)
            }
        }
    }
    
    private func parseANSILine(_ line: String) -> NSAttributedString {
        // Simplified - just use the main parseANSI function
        return parseANSI(line)
    }
    
    private func ansiColor(for code: String) -> NSColor? {
        // Parse ANSI color codes (including xcbeautify output)
        // Codes can be semicolon-separated like "31;1" for bold red
        let codes = code.components(separatedBy: ";")
        var color: NSColor?
        
        for codePart in codes {
            let trimmed = codePart.trimmingCharacters(in: .whitespaces)
            
            switch trimmed {
            case "0", "00":
                return .labelColor // Reset
            case "1", "01":
                // Bold - currently not applied, just continue
                continue
            case "30":
                color = .labelColor // Black
            case "31":
                color = .systemRed
            case "32":
                color = .systemGreen
            case "33":
                color = .systemYellow
            case "34":
                color = .systemBlue
            case "35":
                color = .systemPurple
            case "36":
                color = .systemCyan
            case "37":
                color = .labelColor // White
            case "90": // Bright black
                color = .secondaryLabelColor
            case "91": // Bright red
                color = .systemRed
            case "92": // Bright green
                color = .systemGreen
            case "93": // Bright yellow
                color = .systemYellow
            case "94": // Bright blue
                color = .systemBlue
            case "95": // Bright magenta
                color = .systemPurple
            case "96": // Bright cyan
                color = .systemCyan
            case "97": // Bright white
                color = .labelColor
            default:
                break
            }
        }
        
        return color
    }
}

struct OutputPaneModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 6, y: 1)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
    }
}
