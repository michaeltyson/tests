//
//  SettingsView.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var repositoryPath: String = ""
    @State private var branchName: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title)
                .padding(.bottom, 10)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Repository Path")
                    .font(.headline)
                Text("Path to the Loopy Pro git repository. The workspace file will be found automatically within this repository.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    TextField("Repository path", text: $repositoryPath)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Browse...") {
                        selectRepositoryPath()
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Branch Name (Optional)")
                    .font(.headline)
                Text("Default branch to test when running tests manually. Leave empty to use current branch. Post-commit hooks can override this.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("Branch name", text: $branchName)
                    .textFieldStyle(.roundedBorder)
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Cancel") {
                    NSApp.sendAction(#selector(NSWindow.close), to: nil, from: nil)
                }
                Button("Save") {
                    saveSettings()
                    NSApp.sendAction(#selector(NSWindow.close), to: nil, from: nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 600, height: 380)
        .onAppear {
            repositoryPath = settings.repositoryPath
            branchName = settings.branchName ?? ""
        }
    }
    
    private func selectRepositoryPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Select Repository Directory"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                repositoryPath = url.path
            }
        }
    }
    
    private func saveSettings() {
        settings.setRepositoryPath(repositoryPath)
        settings.setBranchName(branchName.isEmpty ? nil : branchName)
    }
}

