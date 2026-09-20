//
//  LogView.swift
//  ValidationRelay
//
//  Created by James Gill on 3/26/24.
//

import SwiftUI
import UIKit

struct LogItem: Identifiable, Hashable {
    var id = UUID()
    var message: String
    var isError: Bool
    var date: Date
}

class LogItems: ObservableObject {
    private let maximumItemCount = 5_000
    @Published private(set) var items: [LogItem] = []
    
    func log(_ message: String, isError: Bool = false) {
        let item = LogItem(message: message, isError: isError, date: Date())
        items.append(item)
        if items.count > maximumItemCount {
            items.removeFirst(items.count - maximumItemCount)
        }
    }

    func clear() {
        items.removeAll(keepingCapacity: true)
    }
}

private struct LogExport: Identifiable {
    let id = UUID()
    let text: String
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct LogView: View {
    @ObservedObject var logItems: LogItems
    @State private var logExport: LogExport?
    
    var body: some View {
        List {
            ForEach(logItems.items, id: \.self) { item in
                HStack {
                    Text(item.message)
                        .foregroundColor(item.isError ? .red : .primary)
                        .lineLimit(4)
                    Spacer()
                    Text(item.date, style: .time)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }.listStyle(.grouped)
            .navigationTitle("Event Log")
            // Clear log button
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") {
                        logItems.clear()
                    }
                }
                // Export log button
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Pop up a share sheet, use share sheet icon for button
                    Button(action: {
                        // Create a string of the log items
                        let logString = logItems.items.map { item in
                            "\(item.date): \(item.message)"
                        }.joined(separator: "\n")
                        logExport = LogExport(text: logString)
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: $logExport) { export in
                ActivityView(activityItems: [export.text])
            }
    }
}

#Preview {
    NavigationView {
        LogView(logItems: {
            let testLog = LogItems()
            testLog.log("Test message")
            testLog.log("Test error", isError: true)
            return testLog
        }())
    }
}
