import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Tunnel", value: model.tunnelStateText)
                    Text(model.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !model.debugMessage.isEmpty {
                        Text(model.debugMessage)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Configuration") {
                    Toggle("Verbose logging", isOn: $model.verboseLogging)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DC → IP mapping")
                        TextEditor(text: $model.dcIPText)
                            .frame(minHeight: 180)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.vertical, 4)
                }

                Section("Actions") {
                    Button("Save configuration") {
                        Task { await model.saveConfiguration() }
                    }
                    .disabled(model.isBusy)

                    Button("Install / refresh VPN profile") {
                        Task { await model.installProfile() }
                    }
                    .disabled(model.isBusy)

                    Button(model.isRunning ? "Stop tunnel" : "Start tunnel") {
                        Task {
                            if model.isRunning {
                                await model.stopTunnel()
                            } else {
                                await model.startTunnel()
                            }
                        }
                    }
                    .disabled(model.isBusy)

                    Button("Copy debug") {
                        var lines: [String] = ["status: \(model.statusMessage)"]
                        if !model.debugMessage.isEmpty {
                            lines.append("debug: \(model.debugMessage)")
                        }
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                    }
                    .disabled(model.statusMessage.isEmpty && model.debugMessage.isEmpty)
                }

                Section("Notes") {
                    Text("This prototype uses Network Extension with an App Proxy provider. iOS may still require extra entitlements before the tunnel can run on a real device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("TG WS Proxy")
        }
    }
}
