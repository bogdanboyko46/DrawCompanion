import SwiftUI

/// What's happening while the server works: the drawing turning into its
/// painted concept, the character's name once it's known, and each stage.
struct GenerationCard: View {
    @Environment(AppModel.self) private var model
    @State private var started = Date()

    var body: some View {
        let job = model.job
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                preview
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.15)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(job?.character.map { "Meet \($0.name)" } ?? "Reading your drawing")
                        .font(.title3.weight(.bold))
                        .contentTransition(.opacity)
                    if let summary = job?.character?.summary {
                        Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let colors = job?.character?.colors, !colors.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(colors.prefix(6), id: \.self) { c in
                                Circle().fill(Color(hex: c.hex)).frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.5))
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            ProgressView(value: job?.progress ?? 0.02)
                .tint(Color(red: 1, green: 0.55, blue: 0.2))
                .animation(.easeInOut, value: job?.progress)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.stages) { stage in
                    StageRow(stage: stage, state: state(of: stage, job: job))
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(elapsed(at: context.date)) · This usually takes 2–4 minutes. Keep the app open.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .onAppear { started = Date() }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            Color.white
            if let drawing = model.drawingImage {
                Image(uiImage: drawing).resizable().scaledToFill()
            }
            if let concept = model.conceptImage {
                Image(uiImage: concept).resizable().scaledToFill()
                    .transition(.opacity.animation(.easeInOut(duration: 1.2)))
            }
        }
    }

    enum RowState { case done, active, waiting }

    private func state(of stage: GenerationStage, job: CharacterJob?) -> RowState {
        guard let job, let current = GenerationStage(rawValue: job.stage) else {
            return stage == .read ? .active : .waiting
        }
        let all = model.stages
        guard let i = all.firstIndex(of: stage), let c = all.firstIndex(of: current) else { return .waiting }
        return i < c ? .done : (i == c ? .active : .waiting)
    }

    private func elapsed(at date: Date) -> String {
        let s = Int(date.timeIntervalSince(started))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct StageRow: View {
    let stage: GenerationStage
    let state: GenerationCard.RowState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .active:
                    Image(systemName: stage.symbol)
                        .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.25))
                        .symbolEffect(.pulse, options: .repeating)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(.quaternary)
                }
            }
            .frame(width: 20)
            Text(stage.title)
                .font(.subheadline.weight(state == .active ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
