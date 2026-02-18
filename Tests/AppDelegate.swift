//
//  AppDelegate.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import AppKit
import SwiftUI
import Combine
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let testRunner = TestRunner()
    let testResultStore = TestResultStore()
    var historyWindow: NSWindow?
    var settingsWindow: NSWindow?
    var branchSelectionWindow: NSWindow?
    var menuBarManager: MenuBarManager?
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        super.init()
        print("AppDelegate: init called")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("AppDelegate: applicationDidFinishLaunching called")
        requestNotificationPermissions()
        setupMenuBarIfNeeded()
    }
    
    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        // Request standard notification permissions (criticalAlert requires special entitlements)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("AppDelegate: Failed to request notification permissions: \(error)")
            } else {
                print("AppDelegate: Notification permissions granted: \(granted)")
            }
        }
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        print("AppDelegate: applicationWillFinishLaunching called")
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func setupMenuBarIfNeeded() {
        guard menuBarManager == nil else { 
            print("AppDelegate: Menu bar already set up")
            return 
        }
        setupMenuBar()
    }
    
    private func setupMenuBar() {
        guard menuBarManager == nil else { 
            print("AppDelegate: Menu bar already set up")
            return 
        }
        print("AppDelegate: Setting up menu bar")
        
        // Set up menu bar
        let menuBarManager = MenuBarManager()
        self.menuBarManager = menuBarManager
        menuBarManager.setup()
        print("AppDelegate: Menu bar manager setup complete")
        
        // Set up observers after menu bar is ready
        setupObservers()
    }
    
    private func setupObservers() {
        guard let menuBarManager = menuBarManager else { return }
        
        // Observe test runner changes
        testRunner.$isRunning.sink { [weak menuBarManager] isRunning in
            menuBarManager?.isRunning = isRunning
            menuBarManager?.updateIcon()
            menuBarManager?.updateMenuItems()
        }.store(in: &cancellables)
        
        testRunner.$isPaused.sink { [weak menuBarManager] isPaused in
            menuBarManager?.isPaused = isPaused
            menuBarManager?.updateIcon()
            menuBarManager?.updateMenuItems()
        }.store(in: &cancellables)
        
        testRunner.$isBuilding.sink { [weak menuBarManager] isBuilding in
            menuBarManager?.isBuilding = isBuilding
            menuBarManager?.updateMenuItems()
        }.store(in: &cancellables)
        
        testRunner.$totalCount.sink { [weak menuBarManager] totalCount in
            menuBarManager?.totalCount = totalCount
            menuBarManager?.updateMenuItems()
        }.store(in: &cancellables)
        
        testRunner.$passingCount.sink { [weak menuBarManager] passingCount in
            menuBarManager?.passingCount = passingCount
            menuBarManager?.updateMenuItems()
        }.store(in: &cancellables)
        
        testRunner.$failingCount.sink { [weak menuBarManager] failingCount in
            menuBarManager?.failingCount = failingCount
            menuBarManager?.updateMenuItems()
        }.store(in: &cancellables)
        
        testRunner.$currentTestRun.sink { [weak self, weak menuBarManager] testRun in
            if let testRun = testRun {
                self?.testResultStore.update(testRun)
                // Set status to show appropriate icon (will persist until reports window is opened)
                menuBarManager?.status = testRun.status
                menuBarManager?.failingCount = testRun.failingCount ?? 0
                menuBarManager?.passingCount = testRun.passingCount ?? 0
                // Don't override totalCount here - use testRunner.totalCount to match test report screen
                menuBarManager?.updateIcon()
                menuBarManager?.updateMenuItems()
            } else {
                // Test run cleared - reset to default flask icon
                menuBarManager?.status = nil
                menuBarManager?.failingCount = 0
                menuBarManager?.passingCount = 0
                menuBarManager?.totalCount = 0
                menuBarManager?.updateIcon()
                menuBarManager?.updateMenuItems()
            }
        }.store(in: &cancellables)
        
        // Listen for test run deletion requests (e.g., when cancelled)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeleteTestRunNotification),
            name: NSNotification.Name("DeleteTestRun"),
            object: nil
        )
        
        // Listen for trigger notifications from CLI
        // Use main queue to ensure notifications are processed even when app is backgrounded
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.atastypixel.Tests.TriggerRun"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleTriggerNotification(notification)
        }
        
        // Listen for run tests from menu bar
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRunTestsNotification),
            name: NSNotification.Name("RunTests"),
            object: nil
        )
        
        // Listen for pause tests from menu bar
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePauseTestsNotification),
            name: NSNotification.Name("PauseTests"),
            object: nil
        )
        
        // Listen for resume tests from menu bar
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResumeTestsNotification),
            name: NSNotification.Name("ResumeTests"),
            object: nil
        )
        
        // Listen for cancel tests from menu bar
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCancelTestsNotification),
            name: NSNotification.Name("CancelTests"),
            object: nil
        )
        
        // Listen for show history window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showHistoryWindow),
            name: NSNotification.Name("ShowHistoryWindow"),
            object: nil
        )
        
        // Listen for show settings window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsWindow),
            name: NSNotification.Name("ShowSettingsWindow"),
            object: nil
        )
        
        // Listen for show branch selection window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showBranchSelectionWindow),
            name: NSNotification.Name("ShowBranchSelection"),
            object: nil
        )
        
        // Set up windows
        setupHistoryWindow()
        setupSettingsWindow()
        setupBranchSelectionWindow()
    }
    
    func handleTriggerNotification(_ notification: Notification) {
        print("AppDelegate: Received trigger notification from CLI")
        print("AppDelegate: Notification userInfo: \(notification.userInfo ?? [:])")
        print("AppDelegate: App is active: \(NSApp.isActive)")
        print("AppDelegate: TestRunner isPaused: \(testRunner.isPaused)")
        
        // Activate the app to ensure menu bar updates are visible
        NSApp.activate(ignoringOtherApps: true)
        
        // Only run tests if not paused (paused means ignore incoming notifications)
        if !testRunner.isPaused {
            let branchName = notification.userInfo?["branch"] as? String
            print("AppDelegate: Starting tests with branch: \(branchName ?? "nil")")
            testRunner.runTests(branchName: branchName)
        } else {
            print("AppDelegate: Ignoring trigger notification (tests are paused)")
        }
    }
    
    @objc func handleRunTestsNotification() {
        print("AppDelegate: Received RunTests notification from menu bar")
        // Use branch from settings for manual runs
        let branchName = SettingsStore.shared.branchName
        testRunner.runTests(branchName: branchName, isManualRun: true)
    }
    
    @objc func handlePauseTestsNotification() {
        print("AppDelegate: Received PauseTests notification from menu bar")
        testRunner.pause()
    }
    
    @objc func handleResumeTestsNotification() {
        print("AppDelegate: Received ResumeTests notification from menu bar")
        testRunner.resume()
    }
    
    @objc func handleCancelTestsNotification() {
        print("AppDelegate: Received CancelTests notification from menu bar")
        testRunner.cancel()
    }
    
    @objc func showHistoryWindow() {
        if let window = historyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            setupHistoryWindow()
            historyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        // Notify menu bar manager that reports window is now open
        menuBarManager?.reportsWindowOpen = true
    }
    
    @objc func showSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    @objc func showBranchSelectionWindow() {
        if let window = branchSelectionWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func setupBranchSelectionWindow() {
        let contentView = BranchSelectionView { [weak self] branchName in
            // Close the window
            if let window = self?.branchSelectionWindow {
                window.close()
            }
            
            // Only run tests if a branch was actually selected (not cancelled)
            // If branchName is nil, user cancelled - don't run tests
            if let branch = branchName, !branch.isEmpty {
                self?.testRunner.runTests(branchName: branch, isManualRun: true)
            }
            // If branchName is nil or empty, user cancelled - do nothing
        }
        let hostingView = NSHostingView(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Select Branch"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        
        branchSelectionWindow = window
    }
    
    func setupHistoryWindow() {
        let contentView = TestHistoryView(testResultStore: testResultStore, testRunner: testRunner)
        let hostingView = NSHostingView(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Test Reports"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        
        // Adjust content layout to extend into title bar area
        window.styleMask.insert(.fullSizeContentView)
        
        // Remove toolbar to minimize title bar height
        window.toolbar = nil
        
        // Set content view - SwiftUI will handle safe area with ignoresSafeArea modifier
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView
        
        // Pin to content view, extending into title bar area
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
        
        window.center()
        window.setFrameAutosaveName("TestHistoryWindow")
        window.isReleasedWhenClosed = false
        
        // Set delegate to detect when window closes
        window.delegate = self
        
        historyWindow = window
    }
    
    @objc func windowWillClose(_ notification: Notification) {
        // When reports window closes, clear the status icon
        if let window = notification.object as? NSWindow, window == historyWindow {
            menuBarManager?.reportsWindowOpen = false
            // Clear status to show flask icon
            menuBarManager?.status = nil
        }
    }
    
    func setupSettingsWindow() {
        let contentView = SettingsView()
        let hostingView = NSHostingView(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Settings"
        window.contentView = hostingView
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        window.isReleasedWhenClosed = false
        
        settingsWindow = window
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Kill all running test processes
        testRunner.killAllProcesses()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show reports window when dock icon is clicked (though we're menu bar only)
        showHistoryWindow()
        return true
    }
    
    @objc private func handleDeleteTestRunNotification(_ notification: Notification) {
        if let testRun = notification.object as? TestRun {
            testResultStore.delete(testRun)
        }
    }
}

