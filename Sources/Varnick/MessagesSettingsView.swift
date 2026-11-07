import SwiftUI
import VarnickPeer

// The checklist under the Messages between sessions switch in Settings › Claude (option 01 of `sessions-cant-reach-each-other-reliably`). Each line is a tick, a
// button that fixes it, or the reason it can't be fixed from here; the decisions are `ChannelChecklist`'s and the work is `MessagesSetup`'s.

struct MessagesChecklistView: View {
    @ObservedObject var setup: MessagesSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(setup.lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(line.row.mark))
                        .foregroundStyle(color(line.row.mark))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.system(size: 12.5, weight: .medium))
                        Text(line.row.text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        if let action = line.row.action, let button = line.row.button {
                            Button(button) { setup.perform(action) }.disabled(setup.working != nil)
                        }
                        if line.id == 3, setup.hasOwnFile {
                            Button("Remove approval") { setup.removeApproval() }.disabled(setup.working != nil)
                        }
                    }
                }
            }
            if let working = setup.working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(working + "…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } else if let outcome = setup.outcome {
                Text(outcome).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Check again") { setup.refresh() }.disabled(setup.reading)
                if setup.reading { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .onAppear { setup.refresh() }
    }

    private func symbol(_ mark: ChannelChecklist.Mark) -> String {
        switch mark {
        case .pass: "checkmark.circle.fill"
        case .fix: "exclamationmark.circle"
        case .blocked: "xmark.circle"
        case .waiting: "ellipsis.circle"
        }
    }

    private func color(_ mark: ChannelChecklist.Mark) -> Color {
        switch mark {
        case .pass: .green
        case .fix: .orange
        case .blocked: .red
        case .waiting: .secondary
        }
    }
}
