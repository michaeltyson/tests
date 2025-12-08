//
//  TestsCLI.swift
//  TestsCLI
//
//  Created by Michael Tyson on 9/12/2025.
//

import Foundation
import AppKit

let triggerNotificationName = "com.atastypixel.Tests.TriggerRun"

@main
struct TestsCLI {
    static func main() {
        let args = CommandLine.arguments
        
        guard args.count > 1 else {
            print("Usage: TestsCLI trigger [--branch <branch-name>]")
            exit(1)
        }
        
        let command = args[1]
        
        switch command {
        case "trigger":
            var branchName: String? = nil
            if let branchIndex = args.firstIndex(of: "--branch"),
               branchIndex + 1 < args.count {
                branchName = args[branchIndex + 1]
            }
            triggerTestRun(branchName: branchName)
        default:
            print("Unknown command: \(command)")
            print("Usage: TestsCLI trigger [--branch <branch-name>]")
            exit(1)
        }
    }
    
    static func triggerTestRun(branchName: String? = nil) {
        // Check if app is running
        let runningApps = NSWorkspace.shared.runningApplications
        let appBundleId = "com.atastypixel.Tests"
        
        let isRunning = runningApps.contains { app in
            app.bundleIdentifier == appBundleId
        }
        
        if !isRunning {
            // Launch the app
            if let appURL = findAppBundle() {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                var launchError: Error?
                let semaphore = DispatchSemaphore(value: 0)
                
                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
                    launchError = error
                    semaphore.signal()
                }
                
                // Wait for launch to complete
                _ = semaphore.wait(timeout: .now() + 5.0)
                
                if let error = launchError {
                    print("Failed to launch app: \(error)")
                    exit(1)
                }
                
                // Wait for app to actually be running and ready
                var attempts = 0
                let maxAttempts = 20 // 2 seconds total
                while attempts < maxAttempts {
                    Thread.sleep(forTimeInterval: 0.1)
                    let runningApps = NSWorkspace.shared.runningApplications
                    if runningApps.contains(where: { $0.bundleIdentifier == appBundleId }) {
                        // App is running, wait a bit more for it to be ready to receive notifications
                        Thread.sleep(forTimeInterval: 0.5)
                        break
                    }
                    attempts += 1
                }
                
                if attempts >= maxAttempts {
                    print("Warning: App may not have started properly")
                }
            } else {
                print("Could not find Tests.app bundle")
                exit(1)
            }
        }
        
        // Send notification with branch info
        var userInfo: [String: Any] = [:]
        if let branch = branchName {
            userInfo["branch"] = branch
        }
        print("TestsCLI: Posting notification '\(triggerNotificationName)' with userInfo: \(userInfo)")
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(triggerNotificationName),
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo,
            deliverImmediately: true
        )
    }
    
    static func findAppBundle() -> URL? {
        // Try to find the app bundle
        // First, check if we're inside an app bundle
        let currentExecutable = ProcessInfo.processInfo.arguments[0]
        var executableURL = URL(fileURLWithPath: currentExecutable)
        
        // Navigate up to find .app bundle
        while executableURL.path != "/" {
            if executableURL.pathExtension == "app" {
                return executableURL
            }
            executableURL = executableURL.deletingLastPathComponent()
        }
        
        // Try common locations
        let commonPaths = [
            "/Applications/Tests.app",
            NSHomeDirectory() + "/Applications/Tests.app",
            NSHomeDirectory() + "/Desktop/Tests.app"
        ]
        
        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        
        return nil
    }
}

