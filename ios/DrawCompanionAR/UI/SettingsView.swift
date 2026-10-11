import SwiftUI

/// UserDefaults keys for settings the UX owns.
enum AppSettings {
    /// The welcome screens have been seen (or skipped).
    static let onboarded = "dc.onboarded"
    /// Use the sample AI even when an API key is saved (no API calls).
    static let mockMode = "dc.mockMode"
    /// Base pause that ends a spoken phrase, in seconds.
    static let speechPause = SpeechListener.pauseKey
}

/// Headset adjustments shown in Settings. The headset renderer reads these
/// keys from UserDefaults; to add one, add a line to `all`.
struct HeadsetOption: Identifiable {
    let key: String
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    let format: (Double) -> String
    var id: String { key }

    static let all: [HeadsetOption] = [
        HeadsetOption(key: "headset.zoom", title: "Zoom", range: 1.0...2.5, step: 0.05, defaultValue: 1.6) { String(format: "%.2f×", $0) },
        HeadsetOption(key: "headset.eyeOffset", title: "Eye spacing", range: -8...8, step: 0.5, defaultValue: 0) { String(format: "%+.1f mm", $0) },
        HeadsetOption(key: "headset.k1", title: "Lens correction", range: 0...0.8, step: 0.01, defaultValue: 0.441) { String(format: "%.2f", $0) },
    ]

    func value(_ defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: key) as? Double ?? defaultValue
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.onboarded) private var onboarded = true
    @AppStorage(AppSettings.mockMode) private var mockMode = false
    @AppStorage(AppSettings.speechPause) private var pause = SpeechListener.defaultPause
    @ObservedObject private var live = LiveSpeech.shared
    @State private var savedKey = Keychain.apiKey
    @State private var replacing = false
    @State private var checking = false
    @State private var check: APIKeyCheck.Result?
    @State private var headset: [String: Double] = Dictionary(uniqueKeysWithValues: HeadsetOption.all.map { ($0.key, $0.value()) })

    var body: some View {
        NavigationStack {
            Form {
                keySection
                aiSection
                listeningSection
                headsetSection
                helpSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
        }
    }

    // MARK: key

    private var keySection: some View {
        Section {
            if let savedKey, !replacing {
                HStack {
                    Text(Self.masked(savedKey)).font(.body.monospaced())
                    Spacer()
                    if checking {
                        ProgressView()
                    } else if let check {
                        Image(systemName: check == .valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(check == .valid ? .green : .orange)
                    }
                }
                if let check, check != .valid {
                    Text(check.message).font(.footnote).foregroundStyle(.orange)
                }
                Button("Check key") { Task { await verify(savedKey) } }
                    .disabled(checking)
                Button("Replace key") { replacing = true; check = nil }
                Button("Remove key", role: .destructive) {
                    Keychain.apiKey = nil
                    self.savedKey = nil
                    check = nil
                    model.refreshKey()
                }
            } else {
                KeyEntry {
                    savedKey = Keychain.apiKey
                    replacing = false
                    check = .valid
                    model.refreshKey()
                }
                if replacing {
                    Button("Cancel") { replacing = false }
                }
            }
        } header: {
            Text("Claude API key")
        } footer: {
            Text("Get one at console.anthropic.com › API keys. Stored in this iPhone's Keychain and sent only to api.anthropic.com.")
        }
    }

    private func verify(_ key: String) async {
        checking = true
        check = await APIKeyCheck.check(key)
        checking = false
    }

    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        return "sk-ant-••••" + key.suffix(4)
    }

    // MARK: AI

    private var aiSection: some View {
        Section {
            Toggle("Sample AI", isOn: $mockMode)
                .onChange(of: mockMode) { _, _ in model.refreshKey() }
        } footer: {
            Text(savedKey == nil
                 ? "With no key saved, a sample AI draws a flower so you can try everything without API calls."
                 : "Draws a sample flower instead of calling Claude. Handy for testing tracking and tracing without spending anything.")
        }
    }

    // MARK: listening

    private var listeningSection: some View {
        Section {
            VStack(alignment: .leading) {
                HStack {
                    Text("Pause before sending")
                    Spacer()
                    Text(String(format: "%.1f s", pause)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $pause, in: 0.6...2.0, step: 0.1)
            }
        } header: {
            Text("Listening")
        } footer: {
            Text(listeningFooter)
        }
    }

    private var listeningFooter: String {
        var text = "How long you stay quiet before a phrase is sent. Shorter feels snappier; longer lets you pause mid-sentence. Phrases that end mid-thought (“a cat on the…”) wait an extra second."
        let gaps = live.recentGaps.sorted()
        if gaps.count >= 3 {
            let median = gaps[gaps.count / 2]
            text += String(format: " Your longest pauses inside recent phrases: typically %.1f s.", median)
        }
        return text
    }

    // MARK: headset

    private var headsetSection: some View {
        Section {
            ForEach(HeadsetOption.all) { option in
                VStack(alignment: .leading) {
                    HStack {
                        Text(option.title)
                        Spacer()
                        Text(option.format(headset[option.key] ?? option.defaultValue))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: binding(option), in: option.range, step: option.step)
                }
            }
            Button("Reset to defaults") {
                for option in HeadsetOption.all {
                    UserDefaults.standard.removeObject(forKey: option.key)
                    headset[option.key] = option.defaultValue
                }
            }
        } header: {
            Text("Headset")
        } footer: {
            Text("Adjust so the page looks sharp and straight through your viewer's lenses.")
        }
    }

    private func binding(_ option: HeadsetOption) -> Binding<Double> {
        Binding {
            headset[option.key] ?? option.defaultValue
        } set: {
            headset[option.key] = $0
            UserDefaults.standard.set($0, forKey: option.key)
        }
    }

    // MARK: help

    private var helpSection: some View {
        Section {
            Button("Show the welcome screens again") {
                dismiss()
                onboarded = false
            }
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
        } header: {
            Text("Help")
        } footer: {
            Text("Claude Haiku hears each phrase and decides if it's a request. Claude Sonnet sees your page and draws the outline, line by line. In the headset view, double-tap to come back here.")
        }
    }
}

/// Paste a key, check it with the API, save it if it works.
struct KeyEntry: View {
    var onSaved: () -> Void
    @State private var key = ""
    @State private var checking = false
    @State private var result: APIKeyCheck.Result?
    @State private var formatError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SecureField("sk-ant-…", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button {
                    if let pasted = UIPasteboard.general.string { key = APIKeyCheck.normalized(pasted) }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 10) {
                Button(action: save) {
                    if checking {
                        HStack(spacing: 6) { ProgressView(); Text("Checking…") }
                    } else {
                        Text("Check & save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(checking || key.isEmpty)
                if let message {
                    Text(message.text)
                        .font(.footnote)
                        .foregroundStyle(message.ok ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: key) { _, _ in result = nil; formatError = nil }
    }

    private var message: (text: String, ok: Bool)? {
        if let formatError { return (formatError, false) }
        guard let result else { return nil }
        return (result.message, result == .valid)
    }

    private func save() {
        let candidate = APIKeyCheck.normalized(key)
        if let problem = APIKeyCheck.formatProblem(candidate) {
            formatError = problem
            return
        }
        checking = true
        Task {
            let outcome = await APIKeyCheck.check(candidate)
            checking = false
            switch outcome {
            case .rejected:
                result = outcome
            case .offline:
                // Can't tell yet; keep it so it works once the phone is online.
                Keychain.apiKey = candidate
                result = .problem("Saved, but couldn't check it (no connection).")
                onSaved()
            case .valid, .problem:
                Keychain.apiKey = candidate
                result = outcome
                onSaved()
            }
        }
    }
}
