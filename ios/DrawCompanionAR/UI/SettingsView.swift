import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saved = Keychain.apiKey != nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(saved ? "Key saved (paste to replace)" : "sk-ant-…", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        Keychain.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        key = ""
                        saved = Keychain.apiKey != nil
                        model.refreshKey()
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if saved {
                        Button("Remove key", role: .destructive) {
                            Keychain.apiKey = nil
                            saved = false
                            model.refreshKey()
                        }
                    }
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text("Stored in this iPhone's Keychain and sent only to api.anthropic.com. Without a key, a mock AI draws a sample flower so you can try everything else.")
                }
                Section("How it works") {
                    Text("Claude Haiku listens to each phrase and decides if it's a request. Claude Sonnet sees your page and draws the outline, line by line.")
                    Text("In the headset view, double-tap to exit.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
