import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var testing = false
    @State private var anthropicKey = ""
    @State private var meshyKey = ""
    @State private var keyStatus: String?
    @State private var testingKeys = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Make characters", selection: $model.useServer) {
                        Text("On this iPhone").tag(false)
                        Text("Mac server").tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(model.useServer
                        ? "Your Mac does the work. Needs the DrawCompanion server running on the same Wi-Fi."
                        : "This iPhone calls Claude and Meshy directly. Keep the app open while a character is being made (2–4 minutes).")
                }

                if !model.useServer {
                    Section {
                        SecureField(model.keysReady ? "Anthropic key (saved)" : "Anthropic API key (sk-ant-…)", text: $anthropicKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(model.keysReady ? "Meshy key (saved)" : "Meshy API key (msy_…)", text: $meshyKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save keys") {
                            model.saveKeys(anthropic: anthropicKey, meshy: meshyKey)
                            anthropicKey = ""
                            meshyKey = ""
                            keyStatus = model.keysReady ? "Saved to the Keychain." : "Add both keys."
                        }
                        .disabled(anthropicKey.isEmpty && meshyKey.isEmpty)
                        Button {
                            testingKeys = true
                            Task {
                                keyStatus = await model.testKeys()
                                testingKeys = false
                            }
                        } label: {
                            HStack {
                                Text("Test keys")
                                if testingKeys { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(!model.keysReady)
                        if let keyStatus {
                            Text(keyStatus).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("API keys")
                    } footer: {
                        Text(model.keysReady
                            ? "Keys are stored in this iPhone's Keychain. Paste a new one to replace it."
                            : "Paste your keys from console.anthropic.com and meshy.ai. They're stored in this iPhone's Keychain.")
                    }
                }

                if model.useServer {
                Section {
                    TextField("http://192.168.1.10:8787", text: $model.serverAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        testing = true
                        Task {
                            status = await model.testConnection()
                            testing = false
                        }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Companion server")
                } footer: {
                    Text("Run `npm start` (or `npm run mock` to try it without API keys) in the DrawCompanion repo on your Mac, then enter the Mac's address on this network. Both devices must be on the same Wi-Fi.")
                }
                }

                Section("Tips for the best characters") {
                    Label("Draw one figure, whole body, with clear outlines.", systemImage: "figure.stand")
                    Label("Arms away from the body make it easier to rig and animate.", systemImage: "figure.arms.open")
                    Label("Color it in, or say the colors in the description.", systemImage: "paintpalette")
                    Label("Even, bright light and the whole page in view.", systemImage: "sun.max")
                }
                .font(.callout)
            }
            .onChange(of: model.serverAddress) { model.saveServerAddress() }
            .onChange(of: model.useServer) { model.saveUseServer() }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
