import AppKit
import CornettaCore
import SwiftUI

/// Invia il feedback al servizio di Cornetta.
enum FeedbackSender {
    struct Response: Decodable {
        let ok: Bool
        let error: String?
    }

    static func send(message: String, name: String, email: String, diagnostics: String?, microphone: String?) async throws {
        var request = URLRequest(url: AppInfo.serviceURL.appendingPathComponent("api/feedback"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "message": message,
            "name": name,
            "email": email,
            "diagnostics": diagnostics ?? "",
            "app": ["version": AppInfo.version, "build": AppInfo.build, "macOS": AppInfo.macOS, "arch": AppInfo.arch,
                    "microphone": microphone ?? ""],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let decoded = try? JSONDecoder().decode(Response.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, decoded?.ok == true else {
            throw NSError(domain: "Cornetta", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: decoded?.error ?? "Il servizio non ha risposto. Riprova tra poco."])
        }
        Diagnostics.log("Feedback inviato (\(message.count) caratteri)")
    }
}

struct FeedbackView: View {
    let microphone: String?
    let close: () -> Void

    @AppStorage("feedbackName") private var name = ""
    @AppStorage("feedbackEmail") private var email = ""
    @State private var message = ""
    @State private var includeDiagnostics = true
    @State private var sending = false
    @State private var error: String?
    @State private var sent = false
    @State private var diagnostics = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sent {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                    Text("Grazie, il feedback è arrivato.").font(.title3.weight(.semibold))
                    Text("Lo leggo e ti scrivo se hai lasciato l'email.").foregroundStyle(.secondary)
                    Button("Chiudi", action: close).keyboardShortcut(.defaultAction).padding(.top, 6)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                Text("Cosa funziona, cosa no, cosa ti manca?")
                    .font(.title3.weight(.semibold))
                Text("Scrivi come ti viene. Se qualcosa non ha funzionato, racconta cosa stavi facendo.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.15)))
                    .accessibilityLabel("Messaggio")
                HStack {
                    TextField("Nome (facoltativo)", text: $name)
                    TextField("Email per la risposta (facoltativa)", text: $email)
                }
                .textFieldStyle(.roundedBorder)
                Toggle("Allega informazioni tecniche (versione, dispositivi audio, log). Nessun audio.", isOn: $includeDiagnostics)
                    .font(.callout)
                if includeDiagnostics {
                    DisclosureGroup("Vedi cosa viene inviato") {
                        ScrollView {
                            Text(diagnostics)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                    }
                    .font(.callout)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                HStack {
                    Spacer()
                    Button("Annulla", action: close).keyboardShortcut(.cancelAction)
                    Button {
                        Task { await submit() }
                    } label: {
                        if sending { ProgressView().controlSize(.small) } else { Text("Invia feedback") }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { diagnostics = AppInfo.diagnostics(microphone: microphone) }
    }

    private func submit() async {
        sending = true
        error = nil
        do {
            try await FeedbackSender.send(message: message, name: name, email: email,
                                          diagnostics: includeDiagnostics ? diagnostics : nil, microphone: microphone)
            sent = true
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }
}
