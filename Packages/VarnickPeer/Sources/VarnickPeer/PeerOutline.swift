import Foundation

// The Outline on a Mac's Phone page (option 03 of `outline-out-of-reach-from-the-phone`, ADR 0046; protocol 34): the relay requests `outlineRead` and
// `outlineEdit`, and what they carry. Only a Mac's running Varnick answers, and only for a listed device; a headless host refuses. The listing and the
// edits are the app's (`OutlinePhone`, `OutlineRemote`); this file is the wire. Foundation only, with no tree, so the relay builds it on a Linux host. Nothing
// here is logged: a bullet's text and note travel in these structs and nowhere else.

public enum PeerOutlineLimits {
    /// The most rows a reply lists; the rest are left for a continuing read (`PeerOutlineView.after`).
    public static let rowLimit = 400
    /// The most bytes of rows a reply lists, as JSON. A reply line is 1,000,000 bytes at most (`PeerSocket.maxLine`).
    public static let replyBytes = 700_000
    /// The longest text the page can edit, in characters (`OutlineActing.textLimit`). A longer one is listed cut and can't be edited there.
    public static let textLimit = 10_000
    /// The longest note a reply lists whole, in UTF-8 bytes (a session's note limit is 100,000 characters, and four bytes a character would not fit a reply
    /// line); a longer one is listed cut.
    public static let noteBytes = 100_000
    /// The most a reply may be, as JSON, after its rows are trimmed: a reply line is 1,000,000 bytes at most, and an edit's reply holds the Mac's version of a
    /// field besides the title and the rows.
    public static let replyLimit = 900_000
    /// The most a text, a note or pasted lines may be in a request, as the UTF-8 bytes of the JSON string (quotes included). The request is one base64
    /// argument of at most 120,000 bytes (`argumentLimit` in relay.ts), a third bigger than its JSON, and the rest of a request (the view's lists,
    /// two row paths) is at most about 20,000 bytes. A note over this is shown, and the page says it is too long to edit there.
    public static let fieldBytes = 60_000
    /// The most bullets the phone's view may have opened or closed in one request, and the most levels a path may have.
    public static let toggleLimit = 300
    public static let pathLimit = 64
    /// The width a crumb is cut to, in characters.
    public static let crumbLimit = 80
    /// The text of a row listed cut: how much of it shows.
    public static let cutShown = 500
}

/// The phone's view of the tree, sent with every request so the reply lists the rows it shows (nothing is kept per phone). Paths are placement ids from
/// the top bullet, which hold no text. All of it belongs to the phone and none of it is saved on the Mac.
public struct PeerOutlineView: Codable, Equatable, Sendable {
    /// The bullet zoomed into; nil or empty is Home. One that leads nowhere opens at Home, and the reply says so.
    public var zoom: [String]?
    /// Placements the phone has opened and closed, over the Mac's saved collapse. A placement's collapse is its own, so a mirror's rows differ.
    public var opened: [String]?
    public var closed: [String]?
    /// Show completed. Nil is the Mac's own, which the reply names so the phone keeps it.
    public var completed: Bool?
    /// A continuing read: the row path the last reply ended at (`PeerOutlineReply.next`).
    public var after: [String]?

    public init(zoom: [String]? = nil, opened: [String]? = nil, closed: [String]? = nil, completed: Bool? = nil, after: [String]? = nil) {
        self.zoom = zoom
        self.opened = opened
        self.closed = closed
        self.completed = completed
        self.after = after
    }
}

/// A text or note save. The stamp is the field's as the phone read it: the Mac refuses the save if the field differs now.
public struct PeerOutlineSave: Codable, Equatable, Sendable {
    public var row: [String]
    /// `text` or `note`.
    public var field: String
    public var text: String
    public var stamp: String

    public init(row: [String], field: String, text: String, stamp: String) {
        self.row = row
        self.field = field
        self.text = text
        self.stamp = stamp
    }
}

/// One thing done to the tree, after the save in the same request if there is one.
public struct PeerOutlineAct: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// New bullets from `lines` (the Mac's paste rules), at `place` of `row`: `after` it, `inside` it (last), `replace` it when it is an empty bullet (else after it, as a paste is), or `end` of the zoom (no row: Home or the view's zoom).
        case add
        /// Set `row` completed or not, as `done` says, so a request sent twice cannot flip it.
        case complete
        /// ↩ at the UTF-16 `offset` of the row's saved text: the tree's split, or for the phone's title the first nested bullet.
        case enter
        /// This placement and everything nested under it.
        case delete
        case indent
        case outdent
        /// `by` is -1 or 1.
        case move
    }

    public var kind: Kind
    public var row: [String]?
    public var offset: Int?
    public var done: Bool?
    public var by: Int?
    public var lines: String?
    public var place: String?

    public init(_ kind: Kind, row: [String]? = nil, offset: Int? = nil, done: Bool? = nil, by: Int? = nil, lines: String? = nil, place: String? = nil) {
        self.kind = kind
        self.row = row
        self.offset = offset
        self.done = done
        self.by = by
        self.lines = lines
        self.place = place
    }
}

/// `outlineRead`'s body is `view`; `outlineEdit`'s is a `save`, an `act` or both, and the view the reply lists the rows for.
public struct PeerOutlineAsk: Codable, Equatable, Sendable {
    public var view: PeerOutlineView?
    public var save: PeerOutlineSave?
    public var act: PeerOutlineAct?

    public init(view: PeerOutlineView? = nil, save: PeerOutlineSave? = nil, act: PeerOutlineAct? = nil) {
        self.view = view
        self.save = save
        self.act = act
    }
}

/// One row of the view, or its title. The flags are absent when false.
public struct PeerOutlineRow: Codable, Equatable, Sendable {
    public var path: [String]
    public var depth: Int
    /// The text, whole up to `PeerOutlineLimits.textLimit` characters; past that, its first `cutShown` and `textLength` says how long it is.
    public var text: String
    public var textLength: Int?
    /// A digest of the whole text, the same across launches (`OutlinePhone.stamp`); the page sends it back with a save and never makes one.
    public var textStamp: String
    public var note: String?
    public var noteLength: Int?
    public var noteStamp: String
    public var done: Bool?
    /// Dimmed: under a completed bullet.
    public var dim: Bool?
    /// Bullets are nested under it.
    public var nested: Bool?
    /// Those bullets are hidden in this view.
    public var collapsed: Bool?
    /// How many places the bullet is in, when more than one (a mirror).
    public var places: Int?

    public init(path: [String], depth: Int, text: String, textLength: Int? = nil, textStamp: String, note: String? = nil, noteLength: Int? = nil,
                noteStamp: String, done: Bool? = nil, dim: Bool? = nil, nested: Bool? = nil, collapsed: Bool? = nil, places: Int? = nil) {
        self.path = path
        self.depth = depth
        self.text = text
        self.textLength = textLength
        self.textStamp = textStamp
        self.note = note
        self.noteLength = noteLength
        self.noteStamp = noteStamp
        self.done = done
        self.dim = dim
        self.nested = nested
        self.collapsed = collapsed
        self.places = places
    }
}

/// One bullet zoomed through, its text cut as a crumb's is.
public struct PeerOutlineCrumb: Codable, Equatable, Sendable {
    public var path: [String]
    public var text: String
    public var done: Bool?

    public init(path: [String], text: String, done: Bool? = nil) {
        self.path = path
        self.text = text
        self.done = done
    }
}

/// Where the Mac's key would put the caret after an edit: a row of the reply, and a UTF-16 offset in its text.
public struct PeerOutlineCaret: Codable, Equatable, Sendable {
    public var path: [String]
    public var offset: Int

    public init(path: [String], offset: Int) {
        self.path = path
        self.offset = offset
    }
}

/// Why an edit changed nothing. `changed` is a save over a field that differs from what the phone read: `current` and `stamp` are the field now, for
/// the phone to show beside what it typed and to save over (Use mine). `gone` is a row that has left the tree. Anything else is `other`, in words for the
/// user, never holding a bullet's text.
public struct PeerOutlineRefusal: Codable, Equatable, Sendable {
    public var kind: String
    public var message: String
    public var row: [String]?
    public var field: String?
    public var current: String?
    public var stamp: String?

    public static let changed = "changed"
    public static let gone = "gone"
    public static let other = "other"

    public init(kind: String, message: String, row: [String]? = nil, field: String? = nil, current: String? = nil, stamp: String? = nil) {
        self.kind = kind
        self.message = message
        self.row = row
        self.field = field
        self.current = current
        self.stamp = stamp
    }
}

/// An `outlineRead` or `outlineEdit` reply's body (`PeerReply.outline`): the view's rows again, and for an edit what it did. The Outline being off or
/// unreadable, or the asker not being a listed device, is a failed reply with the Outline's own words instead.
public struct PeerOutlineReply: Codable, Equatable, Sendable {
    public var crumbs: [PeerOutlineCrumb]
    /// The bullet zoomed into, with its stamps; nil at Home.
    public var title: PeerOutlineRow?
    public var rows: [PeerOutlineRow]
    /// How many rows are left, and the path to ask `after` for the next of them.
    public var more: Int?
    public var next: [String]?
    /// Show completed as the rows were listed: the phone's, or the Mac's when the phone sent none.
    public var completed: Bool
    /// The phone's zoom led nowhere, so the rows are Home's.
    public var zoomLost: Bool?

    /// `outlineEdit`: whether the save and the act took. A step the tree found already so counts as taken.
    public var saved: Bool?
    public var acted: Bool?
    public var refused: PeerOutlineRefusal?
    /// Where the caret goes, the acted row's new path (indent, outdent, move) and the top-level rows an add made.
    public var caret: PeerOutlineCaret?
    public var moved: [String]?
    public var added: [[String]]?

    public init(crumbs: [PeerOutlineCrumb] = [], title: PeerOutlineRow? = nil, rows: [PeerOutlineRow] = [], more: Int? = nil, next: [String]? = nil,
                completed: Bool = false, zoomLost: Bool? = nil, saved: Bool? = nil, acted: Bool? = nil, refused: PeerOutlineRefusal? = nil,
                caret: PeerOutlineCaret? = nil, moved: [String]? = nil, added: [[String]]? = nil) {
        self.crumbs = crumbs
        self.title = title
        self.rows = rows
        self.more = more
        self.next = next
        self.completed = completed
        self.zoomLost = zoomLost
        self.saved = saved
        self.acted = acted
        self.refused = refused
        self.caret = caret
        self.moved = moved
        self.added = added
    }
}

extension PeerProtocol {
    /// The two Outline requests (protocol 34): for a listed device only, answered by a Mac's running Varnick.
    public static func isOutlineRequest(_ op: PeerOp) -> Bool { op == .outlineRead || op == .outlineEdit }
}
