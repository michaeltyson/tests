//
//  WorkspaceFinder.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import Foundation

class WorkspaceFinder {
    /// Find the first .xcworkspace file in the given directory (searches root level only)
    static func findWorkspace(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        
        // Look for .xcworkspace files in the root directory
        for fileURL in contents {
            if fileURL.pathExtension == "xcworkspace" {
                return fileURL
            }
        }
        
        return nil
    }
}

