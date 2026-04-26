//
//  AppMain.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import AppKit
import SwiftUI

@main
struct AppMain {
    static func main() {
        print("AppMain: Starting application")
        
        // Initialize NSApplication first
        let app = NSApplication.shared
        print("AppMain: NSApplication initialized")
        configureMainMenu(for: app)

        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        
        if isRunningUnitTests {
            print("AppMain: Unit test mode detected; skipping single-instance guard")
        } else {
            // Ensure single instance
            let bundleId = Bundle.main.bundleIdentifier!
            let runningApps = NSWorkspace.shared.runningApplications
            let currentPID = ProcessInfo.processInfo.processIdentifier
            
            print("AppMain: Current PID: \(currentPID)")
            print("AppMain: Checking for other instances...")
            
            // Check all PIDs at once using a single ps command (much faster)
            let allPIDs = runningApps.filter { app in
                app.bundleIdentifier == bundleId && app.processIdentifier != currentPID
            }.map { "\($0.processIdentifier)" }
            
            var zombiePIDs = Set<Int32>()
            if !allPIDs.isEmpty {
                let task = Process()
                task.launchPath = "/bin/ps"
                task.arguments = ["-p", allPIDs.joined(separator: ","), "-o", "pid=,state="]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8) {
                        // Parse output: "PID STATE" format
                        for line in output.components(separatedBy: .newlines) {
                            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
                            if parts.count >= 2, let pid = Int32(parts[0]), parts[1] == "Z" {
                                zombiePIDs.insert(pid)
                            }
                        }
                    }
                } catch {
                    // If we can't check, continue - we'll use other heuristics
                }
            }
            
            let otherInstances = runningApps.filter { app in
                let isSameBundle = app.bundleIdentifier == bundleId
                let isDifferentPID = app.processIdentifier != currentPID
                let pid = app.processIdentifier
                let isZombie = zombiePIDs.contains(pid)
                
                // Only consider it a running instance if it's actually running (not terminated or zombie)
                let isActuallyRunning = app.isFinishedLaunching && !app.isTerminated && !isZombie
                if isSameBundle {
                    print("AppMain: Found app with bundle ID \(bundleId), PID: \(pid), isDifferent: \(isDifferentPID), isZombie: \(isZombie), isRunning: \(isActuallyRunning)")
                }
                return isSameBundle && isDifferentPID && isActuallyRunning
            }
            
            if !otherInstances.isEmpty {
                print("AppMain: Found \(otherInstances.count) other instance(s), terminating")
                for instance in otherInstances {
                    print("AppMain: Other instance PID: \(instance.processIdentifier), finishedLaunching: \(instance.isFinishedLaunching), terminated: \(instance.isTerminated)")
                }
                DistributedNotificationCenter.default().post(
                    name: .showReportsWindowFromRelaunch,
                    object: nil,
                    userInfo: nil
                )
                app.terminate(nil)
                return
            }
            
            print("AppMain: No other instances found, continuing")
        }
        
        print("AppMain: Setting activation policy")
        // Set activation policy for menu bar app
        app.setActivationPolicy(.accessory)
        
        print("AppMain: Creating delegate")
        // Create and set delegate
        let delegate = AppDelegate()
        app.delegate = delegate
        
        print("AppMain: Setting up menu bar")
        // Set up menu bar immediately
        delegate.setupMenuBarIfNeeded()
        
        print("AppMain: Running app")
        // Run the app
        app.run()
    }

    private static func configureMainMenu(for app: NSApplication) {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Application")
        appMenu.addItem(withTitle: "Quit Tests", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(makeFindMenuItem(
            title: "Find...",
            keyEquivalent: "f",
            action: .showFindInterface
        ))
        editMenu.addItem(makeFindMenuItem(
            title: "Find Next",
            keyEquivalent: "g",
            action: .nextMatch
        ))
        editMenu.addItem(makeFindMenuItem(
            title: "Find Previous",
            keyEquivalent: "g",
            modifierMask: [.command, .shift],
            action: .previousMatch
        ))
        editMenuItem.submenu = editMenu

        app.mainMenu = mainMenu
    }

    private static func makeFindMenuItem(
        title: String,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags = [.command],
        action: NSTextFinder.Action
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(NSResponder.performTextFinderAction(_:)),
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifierMask
        item.tag = action.rawValue
        return item
    }
}
