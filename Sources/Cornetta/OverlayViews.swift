import AppKit
import SwiftUI

/// Pannello mostrato durante la registrazione.
struct RecordingOverlayView: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.callEndedSuggestion {
                HStack(spacing: 8) {
                    Image(systemName: "phone.down.fill").foregroundStyle(.orange)
                    Text("La chiamata sembra finita").font(.callout.weight(.semibold))
                    Spacer()
                    Button("Continua") { model.dismissCallEnded() }.controlSize(.small)
                }
                Divider()
            }
            HStack(spacing: 12) {
                RecordingDot()
                Text(model.elapsedText)
                    .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                    .frame(minWidth: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    LevelBar(label: "Tu", level: model.micLevel, tint: .blue)
                    LevelBar(label: "Altri", level: model.systemLevel, tint: .green)
                }
                .frame(width: 120)
                Button {
                    model.stop()
                } label: {
                    Label("Ferma", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(FilledButtonStyle(color: .red))
                .help("Ferma e salva la registrazione")
            }
            HStack {
                Label(model.microphoneName ?? "Senza microfono: registro solo la chiamata",
                      systemImage: model.microphoneName == nil ? "mic.slash" : "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Microfono in uso")
                Spacer()
                Button {
                    model.openFeedback()
                } label: {
                    Label("Feedback", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                }
                .controlSize(.small)
                .help("Segnala un problema o un'idea a chi sviluppa Cornetta")
            }
        }
        .frame(width: 400)
        .panelStyle()
    }
}

struct RecordingDot: View {
    @State private var on = true

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 12, height: 12)
            .opacity(on ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.8).repeatForever(), value: on)
            .onAppear { on = false }
            .accessibilityLabel("In registrazione")
    }
}

struct LevelBar: View {
    let label: String
    let level: Float
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule().fill(tint).frame(width: proxy.size.width * CGFloat(level))
                }
            }
            .frame(height: 6)
            .animation(.linear(duration: 0.1), value: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): livello \(Int(level * 100)) per cento")
    }
}

/// Avviso generico: chiamata iniziata, aggiornamento disponibile.
struct NoticeView: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    let primary: String
    let secondary: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(secondary, action: onSecondary)
                    Button(primary, action: onPrimary)
                        .buttonStyle(FilledButtonStyle(color: tint))
                }
            }
        }
        .frame(width: 360)
        .panelStyle()
        // Il pannello non prende il focus: senza annuncio VoiceOver non dice che è comparso.
        .onAppear {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(title). \(message)",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}
