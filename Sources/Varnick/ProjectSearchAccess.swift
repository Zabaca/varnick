import Foundation
import VarnickPeer

// `project_search` (option 07 of `sessions-cant-start-sessions-in-other-projects`), the running Varnick's half: a session lists the Projects of this Mac, a paired Mac or the headless
// host, each with the word `tab_open` takes, its group, its path there, when Claude last used it and whether that machine's Claude Code trusts it. The request is Panel access's
// (`PanelRequest`); `PanelAccess.run` routes it here; the relay half is `PaneMCP`, and the lines are `ProjectSearch` (Packages/VarnickPeer), checked by `make check-open`. It only
// reads. The rules are in docs/agents/where-it-breaks.md, Panel access.

extension PanelAccess {
    /// In order: the arguments, the machine (as `tab_open` names it), then the list read fresh: this Mac scans its folders again, another machine answers its `projects` request,
    /// which scans fresh there. A machine that does not answer, or whose Varnick is not running, is refused in words.
    func projectSearch(_ args: PanelArguments, _ model: LauncherModel) async throws -> Answered {
        try args.allowOnly(["machine", "search"])
        var peer: Peer?
        if let word = args.text("machine") {
            switch try Self.machine(named: word) {
            case .thisMac: break
            case .peer(let found): peer = found
            }
        }
        let items: [ProjectSearch.Item]
        if let peer {
            switch await PeerManager.shared.projects(on: peer.id) {
            case .failure(let refusal): throw PanelRefusal.bad(Self.words(for: refusal, from: peer.name))
            case .success(let found):
                items = found.map { ProjectSearch.Item(project: Project(path: $0.path, lastUsed: $0.lastUsed), trusted: $0.trusted) }
            }
        } else {
            let found = await model.freshProjects()
            let listed = await Task.detached { PeerProject.listing(of: found) }.value
            items = listed.map { ProjectSearch.Item(project: Project(path: $0.path, lastUsed: $0.lastUsed), trusted: $0.trusted) }
        }
        let text = ProjectSearch.answer(machine: peer?.name, search: args.text("search"), items: items)
        // The log's words: whether another machine was asked, never its name, a search word, a project or a path.
        return Answered(text: text, action: peer == nil ? "this mac" : "remote")
    }
}
