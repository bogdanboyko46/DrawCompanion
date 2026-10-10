import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
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

                Section("Tips for the best characters") {
                    Label("Draw one figure, whole body, with clear outlines.", systemImage: "figure.stand")
                    Label("Arms away from the body make it easier to rig and animate.", systemImage: "figure.arms.open")
                    Label("Color it in, or say the colors in the description.", systemImage: "paintpalette")
                    Label("Even, bright light and the whole page in view.", systemImage: "sun.max")
                }
                .font(.callout)
            }
            .onChange(of: model.serverAddress) { model.saveServerAddress() }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
