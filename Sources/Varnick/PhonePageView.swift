import AppKit
import VarnickPeer
import SwiftUI

/// Settings › Peers › Phone page: the setting, whether the server runs and whether port 8444 is published (`PhonePageServer`).
/// Nothing here waits on a subprocess: the probes run every 20 seconds while it shows, as the peers' do.
struct PhonePageSettingsSection: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var phone = PhonePageServer.shared
    /// Whether the panel is on screen (`PeersSettingsView`'s): closing it only hides it.
    let visible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Phone page")
            SettingRow(title: "Serve the phone page", detail: addressText) {
                if !Zmx.isAvailable { Text("Needs zmx: build with make").font(.system(size: 12)).foregroundStyle(.orange) }
                Toggle("", isOn: $settings.servePhonePage).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!Zmx.isAvailable)
            }
            if settings.servePhonePage || phone.look?.running == true {
                SettingRow(title: "Server", detail: serverText) {
                    if canStartAgain { Button("Start again") { phone.apply() } }
                }
                if case .exited(let tail) = phone.server { logLines(tail) }
                if case .failed(let message) = phone.server, message.contains("\n") { logLines(String(message.split(separator: "\n", maxSplits: 1).last ?? "")) }
                if let look = phone.look { serveRows(look) }
            } else if let note = unpublishNote {
                SettingRow(title: "Tailscale serve", detail: note) {}
            }
        }
        .task(id: visible) {
            while visible, !Task.isCancelled {
                await phone.refresh()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private var addressText: String {
        guard let name = phone.look?.dnsName else { return "The page's address shows once Tailscale answers." }
        return PhonePage.address(dnsName: name)
    }

    private var serverText: String {
        switch phone.server {
        case .checking: "Looking…"
        case .starting: "Starting…"
        case .notRunning: "Not running"
        case .running: "Running"
        case .noBun: "Bun wasn't found. Install it, then Start again."
        case .noFiles: "The server's files aren't next to Varnick: build with make."
        case .exited: "Exited. Its last lines:"
        case .failed(let message): message.split(separator: "\n").first.map(String.init) ?? message
        }
    }

    private var canStartAgain: Bool {
        switch phone.server {
        case .exited, .failed, .noBun, .notRunning: true
        default: false
        }
    }

    @ViewBuilder private func serveRows(_ look: PhonePageServer.Look) -> some View {
        SettingRow(title: "Tailscale serve", detail: serveText(look)) {
            if canTryAgain(look) { Button("Try again") { phone.apply() } }
        }
        // The serve command only where Varnick ran it; the Funnel one it never runs, so that one has Copy.
        if look.serve == .funnelOn, let command = look.funnelOffCommand {
            commandLine(command, copy: true)
        } else if ranServe, let command = look.serveCommand {
            commandLine(command, copy: false)
        }
        if look.mode == .loopback, let reason = look.reason {
            SettingNote(text: PhonePage.loopbackNote(reason, version: look.version))
        }
        // Kept while it runs, when the server is on the socket and the look no longer says loopback.
        if (look.reason == .socketRefused || phone.usingSocket), settings.servePhonePage {
            SettingRow(title: PhonePage.socketButton, detail: phone.usingSocket ? "Waiting for Tailscale and the password prompt…"
                       : "Tries it as you first, and asks for your password to run tailscale serve as root only if Tailscale still refuses.") {
                Button(PhonePage.socketButton) { phone.useSocket() }.disabled(phone.applying)
            }
            if let result = phone.usingSocketResult { SettingNote(text: socketFailure(result)) }
        }
    }

    /// Why the last Use a socket went back to loopback.
    private func socketFailure(_ result: PhonePagePublisher.Outcome) -> String {
        if let note = leftAlone(result) { return note }
        switch result {
        case .failed(let reason), .serveFailed(let reason): return "Couldn't use a socket: \(reason). The page stays on loopback."
        default: return "Couldn't use a socket: serve refused it again. The page stays on loopback."
        }
    }

    /// The refusals to touch a mount that isn't the page's, as the notes under Tailscale serve say them.
    private func leftAlone(_ outcome: PhonePagePublisher.Outcome) -> String? {
        switch outcome {
        case .conflict(let place): "Port \(PhonePage.publishedPort) points at \(place), not the page: left alone"
        case .funnelOn: "Port \(PhonePage.publishedPort) is open to the internet (Funnel is on): left alone"
        default: nil
        }
    }

    /// Nothing retries on its own: a press does, so a refusal doesn't repeat every 20 seconds.
    private func canTryAgain(_ look: PhonePageServer.Look) -> Bool {
        guard settings.servePhonePage, !phone.publishing else { return false }
        switch look.serve {
        case nil, .unreadable?: return true
        case .notPublished?, .ownOther?: return look.running
        default: return false
        }
    }

    private var ranServe: Bool {
        switch phone.publishOutcome {
        case .published?, .serveFailed?: true
        default: false
        }
    }

    /// What the last `serve off` came to, once the section's other rows are gone with the setting.
    private var unpublishNote: String? {
        if phone.unpublishing { return "Unpublishing…" }
        if let outcome = phone.publishOutcome, let note = leftAlone(outcome) { return note }
        switch phone.publishOutcome {
        case .failed(let reason)?, .serveFailed(let reason)?: return "Port \(PhonePage.publishedPort) wasn't taken down: \(reason)"
        default: return nil
        }
    }

    private func serveText(_ look: PhonePageServer.Look) -> String {
        guard look.hasCLI else { return "Tailscale isn't installed here." }
        if phone.publishing { return phone.unpublishing ? "Unpublishing…" : "Publishing…" }
        switch look.serve {
        case nil:
            if let reason = failureReason { return "Not published: \(reason)" }
            return look.dnsName == nil ? "Not published: Tailscale isn't running" : "Looking…"
        case .published?: return "Published, tailnet only"
        case .notPublished?:
            if let reason = failureReason { return "Not published: \(reason)" }
            return look.running ? "Not published" : "Not published (the server isn't running)"
        case .ownOther?: return "Published to the page's other address. Try again moves it."
        case .elsewhere(let place)?: return "Not published: port \(PhonePage.publishedPort) already points at \(place), which Varnick leaves alone"
        case .funnelOn?: return "Not published: port \(PhonePage.publishedPort) is open to the internet (Funnel is on). Turn it off in Terminal:"
        case .unreadable(let message)?: return "Not published: \(message)"
        }
    }

    private var failureReason: String? {
        switch phone.publishOutcome {
        case .failed(let reason)?, .serveFailed(let reason)?: reason
        default: nil
        }
    }

    /// A command in monospace, with Copy only where the user would run it.
    private func commandLine(_ command: String, copy: Bool) -> some View {
        HStack(spacing: 8) {
            Text(command).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 8)
            if copy {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
    }

    private func logLines(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 4)
    }
}
