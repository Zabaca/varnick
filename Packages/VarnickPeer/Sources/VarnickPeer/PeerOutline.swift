import Foundation

// The Outline on a Mac's Phone page (protocol 34): the relay requests `outlineRead` and `outlineEdit`, and what they carry. The mechanism, the caps and the
// privacy rule are in docs/agents/where-it-breaks.md, The Outline on the phone. Foundation only, with no tree, so a Linux host builds it. A bullet's text
// and note travel in these structs and are never logged.

public enum PeerOutlineLimits {
    /// A reply lists at most this many rows and this many bytes of rows (title included), then `more`; `replyLimit` is the most a reply may be after `fit`.
    public static let rowLimit = 400
    public static let replyBytes = 700_000
    public static let replyLimit = 900_000
    /// A text is listed whole to this many characters (`OutlineActing.textLimit`), a note to this many UTF-8 bytes; a longer one is listed cut.
    public static let textLimit = 10_000
    public static let noteBytes = 100_000
    /// The most a text, a note or pasted lines may be in a request, as the UTF-8 bytes of its JSON string: the request is one base64 argument of 120,000 bytes.
    public static let fieldBytes = 60_000
    /// The most placements the view may have opened or closed, and the most levels a path may have.
    public static let toggleLimit = 300
    public static let pathLimit = 64
    /// A crumb is cut to this many characters; a row listed cut shows this many.
    public static let crumbLimit = 80
    public static let cutShown = 500
}

/// The phone's view of the tree, sent with every request. Paths are placement ids from the top bullet, which hold no text. None of it is saved on the Mac.
public struct PeerOutlineView: Codable, Equatable, Sendable {
    /// The bullet zoomed into; nil or empty is Home.
    public var zoom: [String]?
    /// Placements the phone opened and closed, over the Mac's saved collapse.
    public var opened: [String]?
    public var closed: [String]?
    /// Show completed; nil is the Mac's own, which the reply names.
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
        /// New bullets from `lines` (the Mac's paste rules) at `place` of `row`: `after` it, `inside` it (last), `replace` it when it is an empty bullet (else after it),
        /// or `end` of the view's zoom (no row).
        case add
        /// Sets `row` completed or not, as `done` says.
        case complete
        /// ↩ at the UTF-16 `offset` of the row's text, by the phone's collapse of it.
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
    /// Enter and delete: the stamp of the row's text as the phone read it. Checked right before the edit, unless a save in the same request put the text there.
    public var stamp: String?
    /// Delete: refuse unless the row is still empty, with no note and nothing nested (⌫ in an empty bullet).
    public var empty: Bool?
    /// Delete: whether the phone showed bullets nested under the row. Refused if some are there and it showed none, so the phone asks again.
    public var nested: Bool?

    public init(_ kind: Kind, row: [String]? = nil, offset: Int? = nil, done: Bool? = nil, by: Int? = nil, lines: String? = nil, place: String? = nil,
                stamp: String? = nil, empty: Bool? = nil, nested: Bool? = nil) {
        self.kind = kind
        self.row = row
        self.offset = offset
        self.done = done
        self.by = by
        self.lines = lines
        self.place = place
        self.stamp = stamp
        self.empty = empty
        self.nested = nested
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
    /// Whole up to `textLimit` characters; past that, its first `cutShown` and `textLength` says how long it was.
    public var text: String
    public var textLength: Int?
    /// A digest of the whole text (`OutlinePhone.stamp`); the page sends it back and never makes one.
    public var textStamp: String
    public var note: String?
    public var noteLength: Int?
    public var noteStamp: String
    public var done: Bool?
    /// Dimmed: under a completed bullet.
    public var dim: Bool?
    public var nested: Bool?
    /// Those nested bullets are hidden in this view.
    public var collapsed: Bool?
    /// How many places the bullet is in, when more than one.
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

/// Where the Mac's key would put the caret after an edit: a row of the reply and a UTF-16 offset in its text.
public struct PeerOutlineCaret: Codable, Equatable, Sendable {
    public var path: [String]
    public var offset: Int

    public init(path: [String], offset: Int) {
        self.path = path
        self.offset = offset
    }
}

/// Why an edit changed nothing. `changed` is a save over a field that differs from what the phone read: `current` and `stamp` are the field now. `gone` is a row
/// that left the tree. Anything else is `other`. `message` never holds a bullet's text.
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

/// An `outlineRead` or `outlineEdit` reply's body (`PeerReply.outline`): the view's rows, and for an edit what it did. The Outline being off or unreadable, or an
/// asker that isn't a listed device, is a failed reply instead.
public struct PeerOutlineReply: Codable, Equatable, Sendable {
    public var crumbs: [PeerOutlineCrumb]
    /// The bullet zoomed into, with its stamps; nil at Home.
    public var title: PeerOutlineRow?
    public var rows: [PeerOutlineRow]
    /// How many rows are left, and the path to ask `after` for the next of them.
    public var more: Int?
    public var next: [String]?
    /// Show completed as the rows were listed.
    public var completed: Bool
    /// The phone's zoom led nowhere, so the rows are Home's.
    public var zoomLost: Bool?

    /// `outlineEdit`: whether the save and the act took (a step the tree found already so counts), and the saved field's stamp as the edit left it.
    public var saved: Bool?
    public var savedStamp: String?
    public var acted: Bool?
    public var refused: PeerOutlineRefusal?
    /// Where the caret goes, the acted row's new path (indent, outdent, move) and the top-level rows an add made.
    public var caret: PeerOutlineCaret?
    public var moved: [String]?
    public var added: [[String]]?

    public init(crumbs: [PeerOutlineCrumb] = [], title: PeerOutlineRow? = nil, rows: [PeerOutlineRow] = [], more: Int? = nil, next: [String]? = nil,
                completed: Bool = false, zoomLost: Bool? = nil, saved: Bool? = nil, savedStamp: String? = nil, acted: Bool? = nil,
                refused: PeerOutlineRefusal? = nil, caret: PeerOutlineCaret? = nil, moved: [String]? = nil, added: [[String]]? = nil) {
        self.crumbs = crumbs
        self.title = title
        self.rows = rows
        self.more = more
        self.next = next
        self.completed = completed
        self.zoomLost = zoomLost
        self.saved = saved
        self.savedStamp = savedStamp
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
