//
//  TestProgressView.swift
//  Tests
//
//  Created by Michael Tyson on 9/12/2025.
//

import SwiftUI

struct TestProgressView: View {
    @ObservedObject var testRunner: TestRunner
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if testRunner.isRunning {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Running tests...")
                        .font(.headline)
                } else if testRunner.isPaused {
                    Image(systemName: "pause.circle.fill")
                        .foregroundColor(.orange)
                    Text("Tests paused")
                        .font(.headline)
                } else {
                    Text("No tests running")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Output
            TerminalOutputView(text: testRunner.output)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

