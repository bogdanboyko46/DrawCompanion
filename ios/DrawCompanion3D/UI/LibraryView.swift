import SwiftUI

/// Every character you've brought to life. Tap one to put it back in the room.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if model.library.isEmpty {
                    ContentUnavailableView(
                        "No characters yet",
                        systemImage: "figure.wave",
                        description: Text("Draw someone on paper, point the camera at it, and tap Bring it to life."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(model.library) { job in
                                Button { model.place(job) } label: { Tile(job: job, thumbnail: model.thumbnail(for: job)) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Remove from this device", systemImage: "trash", role: .destructive) { model.delete(job) }
                                    }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Your characters")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if model.hasCharacters {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear room", role: .destructive) {
                            model.clearRoom()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

private struct Tile: View {
    let job: CharacterJob
    let thumbnail: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: thumbnail) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "cube.transparent").font(.largeTitle).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            Text(job.displayName).font(.headline)
            if let traits = job.character?.personality.traits, !traits.isEmpty {
                Text(traits.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if job.model?.animated == false {
                Label("Static model", systemImage: "cube").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
