//
//  MenuBarView.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import SwiftUI
import AppKit
import Combine

class MenuBarManager: ObservableObject {
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var isBuilding = false
    @Published var status: TestRunStatus?
    @Published var failingCount: Int = 0
    @Published var passingCount: Int = 0
    @Published var totalCount: Int = 0
    @Published var queuedRunCount: Int = 0
    @Published var reportsWindowOpen = false
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var statusMenuItem: NSMenuItem?
    private var progressView: ProgressMenuView?
    private var originalAnchorPoint: CGPoint?
    private var originalPosition: CGPoint?
    
    func setup() {
        // Remove existing status item if any
        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
        }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let statusItem = statusItem else {
            print("MenuBarManager: ERROR - Failed to create status item")
            return
        }
        
        guard statusItem.button != nil else {
            print("MenuBarManager: ERROR - Failed to get status item button")
            return
        }
        
        // Set up menu first
        menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
        menu?.addItem(statusMenuItem!)
        menu?.addItem(NSMenuItem.separator())
        
        // Run Tests Now / Cancel item (same item, changes title/action based on state)
        menu?.addItem(NSMenuItem(title: "Run Tests Now", action: #selector(runTests), keyEquivalent: "r"))
        
        // Pause/Resume item (always visible, toggles to ignore incoming notifications)
        menu?.addItem(NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: ""))
        
        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(NSMenuItem(title: "Test Reports", action: #selector(showHistory), keyEquivalent: "h"))
        menu?.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        
        for item in menu?.items ?? [] {
            item.target = self
        }
        
        statusItem.menu = menu
        
        // Ensure status item is visible
        statusItem.isVisible = true
        
        // Now set the icon
        updateIcon()
    }
    
    func updateIcon() {
        guard let statusItem = statusItem else { return }
        guard let button = statusItem.button else { return }
        
        let iconName: String
        if isPaused {
            iconName = "pause.fill"
        } else if isRunning {
            iconName = "flask.fill"
        } else if reportsWindowOpen {
            // When reports window is open, always show flask
            iconName = "flask"
        } else if let status = status {
            // Show status icon persistently until reports window is opened
            switch status {
            case .success:
                iconName = "checkmark.circle.fill"
            case .failed, .error:
                iconName = "xmark.circle.fill"
            case .warnings:
                iconName = "checkmark.circle.fill"
            case .paused:
                iconName = "pause.fill"
            default:
                iconName = "flask"
            }
        } else {
            // No status set - show default flask icon
            iconName = "flask"
        }
        
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) else {
            print("MenuBarManager: Failed to create image for icon: \(iconName)")
            return
        }
        
        // Use template mode for all icons (default system color)
        image.isTemplate = true
        let configuredImage = image.withSymbolConfiguration(config) ?? image
        
        // Ensure button is visible and properly configured
        button.isHidden = false
        button.appearsDisabled = false
        
        // Set the image
        button.image = configuredImage
        
        // Ensure status item has proper length and is visible
        statusItem.length = NSStatusItem.variableLength
        statusItem.isVisible = true
        
        if isRunning && !isPaused {
                // Add rotation jiggle animation
                button.wantsLayer = true
                
                // Use dispatch_async to ensure button is laid out before modifying layer
                DispatchQueue.main.async { [weak self, weak button] in
                    guard let button = button else { return }
                    guard let layer = button.layer else { return }
                    
                    let bounds = button.bounds
                    let oldAnchor = layer.anchorPoint
                    let newAnchor = CGPoint(x: 0.5, y: 0.5)
                    
                    // Store original values if not already stored
                    if self?.originalAnchorPoint == nil {
                        self?.originalAnchorPoint = oldAnchor
                        self?.originalPosition = layer.position
                    }
                    
                    // Only adjust if anchor point is different
                    if oldAnchor != newAnchor {
                        // Calculate the offset needed to maintain visual position
                        let offsetX = (newAnchor.x - oldAnchor.x) * bounds.width
                        let offsetY = (newAnchor.y - oldAnchor.y) * bounds.height
                        
                        // Get current position
                        let currentPosition = layer.position
                        
                        // Set new anchor point
                        layer.anchorPoint = newAnchor
                        
                        // Adjust position to compensate for anchor point change
                        layer.position = CGPoint(
                            x: currentPosition.x + offsetX,
                            y: currentPosition.y + offsetY
                        )
                    }
                    
                    // Create a rotation jiggle animation (small back-and-forth rotation)
                    let jiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                    jiggle.values = [0, -0.1, 0.1, -0.1, 0.1, 0]
                    jiggle.duration = 0.4
                    jiggle.repeatCount = .infinity
                    jiggle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    layer.add(jiggle, forKey: "jiggle")
                }
            } else {
                // Not running - ensure button is visible and properly configured
                // Treat paused exactly the same as stopped - no special handling
                button.isHidden = false
                button.appearsDisabled = false
                statusItem.length = NSStatusItem.variableLength
                statusItem.isVisible = true
                
                // Only manipulate layer if we previously had animation running
                if originalAnchorPoint != nil || originalPosition != nil {
                    if let layer = button.layer,
                       let originalAnchor = originalAnchorPoint,
                       let originalPos = originalPosition {
                        layer.removeAllAnimations()
                        
                        // Restore original anchor point and position
                        let bounds = button.bounds
                        let currentAnchor = layer.anchorPoint
                        
                        if currentAnchor != originalAnchor {
                            // Calculate offset to restore original position
                            let offsetX = (originalAnchor.x - currentAnchor.x) * bounds.width
                            let offsetY = (originalAnchor.y - currentAnchor.y) * bounds.height
                            
                            layer.anchorPoint = originalAnchor
                            layer.position = CGPoint(
                                x: layer.position.x + offsetX,
                                y: layer.position.y + offsetY
                            )
                        } else {
                            // Just restore position
                            layer.position = originalPos
                        }
                        
                        // Reset stored values
                        originalAnchorPoint = nil
                        originalPosition = nil
                    }
                }
            }
    }
    
    @objc func runTests(_ sender: AnyObject?) {
        // Check for modifier keys (Option or Command)
        let event = NSApp.currentEvent
        let modifierFlags = event?.modifierFlags ?? []
        
        if modifierFlags.contains(.option) || modifierFlags.contains(.command) {
            // Show branch selection dialog
            NotificationCenter.default.post(name: NSNotification.Name("ShowBranchSelection"), object: nil)
        } else {
            // Normal run without branch selection
            NotificationCenter.default.post(name: NSNotification.Name("RunTests"), object: nil)
        }
    }
    
    @objc func pauseTests() {
        NotificationCenter.default.post(name: NSNotification.Name("PauseTests"), object: nil)
    }
    
    @objc func resumeTests() {
        NotificationCenter.default.post(name: NSNotification.Name("ResumeTests"), object: nil)
    }
    
    @objc func cancelTests() {
        NotificationCenter.default.post(name: NSNotification.Name("CancelTests"), object: nil)
    }
    
    @objc func togglePause() {
        if isPaused {
            NotificationCenter.default.post(name: NSNotification.Name("ResumeTests"), object: nil)
        } else {
            NotificationCenter.default.post(name: NSNotification.Name("PauseTests"), object: nil)
        }
    }
    
    @objc func showHistory() {
        NotificationCenter.default.post(name: NSNotification.Name("ShowHistoryWindow"), object: nil)
    }
    
    @objc func showSettings() {
        NotificationCenter.default.post(name: NSNotification.Name("ShowSettingsWindow"), object: nil)
    }
    
    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    func updateMenuItems() {
        guard let menu = menu, let statusMenuItem = statusMenuItem else { return }
        
        if isRunning && !isPaused {
            // Show progress bar view when running
            if progressView == nil {
                progressView = ProgressMenuView()
                statusMenuItem.view = progressView
            }
            
            let currentCount = passingCount + failingCount
            let progress: Double
            let statusText: String
            let queueText = queuedRunCount > 0 ? " (\(queuedRunCount) queued)" : ""
            
            if isBuilding {
                // Building phase - show indeterminate progress
                statusText = "Building\(queueText)"
                progress = 0.0
            } else {
                // Test phase - show actual progress
                statusText = "Running\(queueText)"
                if totalCount > 0 {
                    progress = Double(currentCount) / Double(totalCount)
                } else {
                    progress = 0.0
                }
            }
            
            progressView?.update(
                progress: progress,
                status: statusText,
                count: currentCount,
                total: totalCount > 0 ? totalCount : nil
            )
        } else {
            // Show regular text when not running
            statusMenuItem.view = nil
            
            let statusText: String
            if isPaused {
                statusText = "Status: Paused"
            } else {
                if let status = status {
                    switch status {
                    case .success:
                        if passingCount > 0 || failingCount > 0 {
                            statusText = "Status: \(passingCount) passed, \(failingCount) failed"
                        } else {
                            statusText = "Status: Success"
                        }
                    case .failed:
                        if passingCount > 0 || failingCount > 0 {
                            statusText = "Status: \(passingCount) passed, \(failingCount) failed"
                        } else {
                            statusText = "Status: Failed"
                        }
                    case .error:
                        statusText = "Status: Error"
                    case .warnings:
                        statusText = "Status: Warnings"
                    case .paused:
                        statusText = "Status: Paused"
                    default:
                        statusText = "Status: Ready"
                    }
                } else {
                    statusText = "Status: Ready"
                }
            }
            statusMenuItem.title = statusText
        }
        
        // Update Run Tests Now / Cancel item
        if let runCancelItem = menu.items.first(where: { $0.action == #selector(runTests) || $0.action == #selector(cancelTests) }) {
            if isRunning {
                runCancelItem.title = "Cancel"
                runCancelItem.action = #selector(cancelTests)
            } else {
                runCancelItem.title = "Run Tests Now"
                runCancelItem.action = #selector(runTests)
            }
        }
        
        // Update Pause/Resume item title based on state
        if let pauseResumeItem = menu.items.first(where: { $0.action == #selector(togglePause) }) {
            pauseResumeItem.title = isPaused ? "Resume" : "Pause"
        }
    }
}

class ProgressMenuView: NSView {
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    private func setupViews() {
        // Configure progress bar
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0.0
        progressBar.maxValue = 1.0
        progressBar.doubleValue = 0.0
        progressBar.controlSize = .small
        
        // Configure status label
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .left
        
        // Configure count label
        countLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        
        // Add subviews
        addSubview(progressBar)
        addSubview(statusLabel)
        addSubview(countLabel)
        
        // Set up constraints
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            // Progress bar at top
            progressBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            progressBar.heightAnchor.constraint(equalToConstant: 8),
            
            // Status label below progress bar
            statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),
            
            // Count label right-aligned
            countLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            
            // Bottom constraint
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            countLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        
        // Set fixed width for menu item
        frame = NSRect(x: 0, y: 0, width: 300, height: 50)
    }
    
    func update(progress: Double, status: String, count: Int, total: Int?) {
        if status == "Building" {
            // Building phase - always show indeterminate progress
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            countLabel.stringValue = ""
        } else if let total = total, total > 0 {
            // Test phase with known total - show determinate progress
            progressBar.isIndeterminate = false
            progressBar.doubleValue = progress
            countLabel.stringValue = "\(count) of \(total)"
        } else {
            // Test phase without total - show indeterminate progress
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            countLabel.stringValue = "\(count)"
        }
        statusLabel.stringValue = status
    }
}

struct MenuBarView: View {
    var body: some View {
        EmptyView()
    }
}
