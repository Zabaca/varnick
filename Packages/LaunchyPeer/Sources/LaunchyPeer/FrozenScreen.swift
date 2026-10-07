import Foundation

/// A session's last screen, as zmx's `history --vt` prints it, made safe to draw in a pane that
/// isn't the session's client (ADR 0007). Pure text work, so it runs on the host before the screen
/// is sent and needs no terminal.
enum FrozenScreen {
    /// Private modes the history replays that would make a terminal talk back to its process:
    /// mouse tracking and its encodings (9 is the X10 form), focus reports, bracketed paste,
    /// colour-scheme reports and in-band size reports (2048). The
    /// alternate screen goes too, so a pane smaller than the host's keeps the lines it scrolls off
    /// instead of dropping them. Spike, 2026-10-04: replayed into a live shell they arrived as text.
    static let strippedModes: Set<Int> = [
        9, 1000, 1001, 1002, 1003, 1005, 1006, 1015, 1016, 1004, 2004, 2031, 2048, 47, 1047, 1049,
    ]

    /// Newlines kept: the screen as the host drew it plus a tail of what scrolled off. Claude draws
    /// on the alternate screen, which has no scrollback, so the cut mostly matters for long output.
    static let tailLines = 500

    /// The screen to send: cut to the tail, then without the mode sets.
    static func prepare(_ vt: String) -> String { stripModes(from: tail(of: vt)) }

    /// The last `lines` lines. What was cut leaves the colours of its last line behind, so a reset
    /// starts the rest.
    static func tail(of vt: String, lines: Int = tailLines) -> String {
        let bytes = Array(vt.utf8)
        var seen = 0
        var index = bytes.count
        while index > 0 {
            index -= 1
            if bytes[index] == 0x0A {
                seen += 1
                if seen > lines { return "\u{1B}[0m" + String(decoding: bytes[(index + 1)...], as: UTF8.self) }
            }
        }
        return vt
    }

    /// Takes the modes in `strippedModes` out of every `CSI ? … h`, including from a sequence that
    /// sets several (`CSI ? 1000 ; 25 h` keeps the 25), and drops a sequence left with none. Resets
    /// (`l`) and every other sequence stay as they are.
    static func stripModes(from vt: String) -> String {
        let bytes = Array(vt.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1B, i + 2 < bytes.count, bytes[i + 1] == 0x5B, bytes[i + 2] == 0x3F else {
                out.append(bytes[i])
                i += 1
                continue
            }
            var j = i + 3
            while j < bytes.count, (bytes[j] >= 0x30 && bytes[j] <= 0x39) || bytes[j] == 0x3B { j += 1 }
            guard j < bytes.count, bytes[j] == 0x68 else {
                out.append(bytes[i])
                i += 1
                continue
            }
            let parameters = String(decoding: bytes[(i + 3)..<j], as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
            let kept = parameters.filter { Int($0).map { !strippedModes.contains($0) } ?? true }
            if kept.count == parameters.count {
                out.append(contentsOf: bytes[i...j])
            } else if !kept.isEmpty {
                out.append(contentsOf: Array(("\u{1B}[?" + kept.joined(separator: ";") + "h").utf8))
            }
            i = j + 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
