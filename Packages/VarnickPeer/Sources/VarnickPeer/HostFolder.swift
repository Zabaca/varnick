import Foundation

/// Where a session with no folder runs on a headless host: the pure decision, so a check can pin it. Claude Code never saves trust for an account's own
/// home folder (its answer holds for one session), so a session started there asks the trust question every time, and the test of messages, which refuses
/// to start in an untrusted folder, could never pass. The host's Home (`VarnickHome`) is marked trusted, so it is where a session with no folder starts, as
/// on a Mac. A folder the user set in the host's `config.json` (`configured`, already expanded, nil when none) still wins over Home.
public enum HostFolder {
    /// A session asked for, with `asked` (a path, already expanded) or none: the folder asked, else the configured one, else Home.
    public static func start(asked: String?, configured: String?, home: String) -> String {
        asked ?? configured ?? home
    }

    /// The receiver of a messages test: the folder asked, else Home, whatever `config.json` says, since the test is about messages and its folder must be one
    /// Claude Code trusts (a configured `~` never is).
    public static func messageTest(asked: String?, home: String) -> String {
        asked ?? home
    }

    /// A saved record's folder. A record that has one keeps it, even the home folder: its conversation lives under that folder's project folder and
    /// `--resume` finds it only from there. A record with none (saved by a build that left the folder to the default) resumes where its conversation
    /// is: under the folder that build used (`configured`, else the account's home folder `userHome`), else under Home; one with no transcript yet
    /// takes the folder a new session takes.
    ///
    /// - Parameter hasConversation: whether the folder's project folder holds a transcript for the record's conversation.
    public static func saved(folder: String?, configured: String?, home: String, userHome: String, hasConversation: (String) -> Bool) -> String {
        if let folder { return folder }
        let earlier = configured ?? userHome
        if hasConversation(earlier) { return earlier }
        if hasConversation(home) { return home }
        return configured ?? home
    }
}
