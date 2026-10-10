import Foundation
import Security

/// Move to Applications: what Varnick.app does when it runs from a temporary copy macOS made of a download, or off a disk image.
/// Foundation and Security only, every place a parameter, so a harness compiles it alone (where-it-breaks, The installed app).
enum MoveToApplications {
    static let targetName = "Varnick.app"
    static let quarantineAttribute = "com.apple.quarantine"

    enum Situation: Equatable {
        case translocated
        case onDiskImage
    }

    /// A disk image attached now: where its volume is mounted, and the device `hdiutil detach` takes.
    struct AttachedImage: Equatable {
        var mountPoint: String
        var device: String
    }

    /// What a moved copy must be: signed by the running copy's own team and satisfying its designated requirement.
    struct Trust {
        var team: String
        var requirement: SecRequirement
    }

    /// A quarantine attribute that was removed, to put back if the move fails. `path` is relative to the bundle, "" for the bundle.
    struct Cleared {
        var path: String
        var value: Data
    }

    enum Outcome: Equatable {
        /// The bundle now at the target, signature checked and quarantine cleared.
        case moved(URL)
        /// A Varnick of this account holds the lock; the offer shows again.
        case alreadyRunning(path: String)
        /// Nothing was left half done; the reason follows today's message.
        case stopped(String)
    }

    struct Places {
        var applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        var support: URL
        /// Puts a copy where the user can recover it, and says where it went.
        var trash: (URL) throws -> URL? = {
            var result: NSURL?
            try FileManager.default.trashItem(at: $0, resultingItemURL: &result)
            return result as URL?
        }
        /// Whether the first can be renamed into the second's folder: a rename leaves nothing behind, a copy leaves the original.
        var sameVolume: (URL, URL) -> Bool = MoveToApplications.onSameVolume
    }

    // MARK: When it's offered

    /// Today's refusal line, with the reason after it, for every stop that falls back to it.
    static func stopLine(_ reason: String) -> String { InstalledApp.translocatedLine + ". " + reason }

    static let notWritable = "This account can't add apps to Applications; Finder will ask for an administrator when you drag Varnick there."

    /// Why the app is offered a move, or nil when it runs as it is. The image list is asked only for a bundle under `volumesRoot`.
    static func situation(executablePath: String, bundle: URL, volumesRoot: String = "/Volumes",
                          images: () -> [AttachedImage] = { attachedImages() }) -> Situation? {
        if InstalledApp.isTranslocated(executablePath: executablePath) { return .translocated }
        let root = URL(fileURLWithPath: volumesRoot).resolvingSymlinksInPath().path
        guard bundle.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { return nil }
        return image(containing: bundle, in: images()) == nil ? nil : .onDiskImage
    }

    // MARK: Attached images

    /// The mounted volumes of `hdiutil info -plist`'s images, each with its whole disk's device when the list names one.
    static func parseImages(_ plist: Data) -> [AttachedImage] {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        return images.flatMap { image -> [AttachedImage] in
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let whole = entities.compactMap { $0["dev-entry"] as? String }.first { $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil }
            return entities.compactMap { entity in
                guard let mount = entity["mount-point"] as? String, let device = entity["dev-entry"] as? String else { return nil }
                return AttachedImage(mountPoint: mount, device: whole ?? device)
            }
        }
    }

    /// The images attached now, as the system lists them (`hdiutil info`); empty when it can't be asked.
    static func attachedImages() -> [AttachedImage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? parseImages(data) : []
    }

    /// The image whose volume holds `url`, which must exist (a missing path resolves differently from the mount point).
    static func image(containing url: URL, in images: [AttachedImage]) -> AttachedImage? {
        let path = url.resolvingSymlinksInPath().path
        return images.first { image in
            let mount = URL(fileURLWithPath: image.mountPoint).resolvingSymlinksInPath().path
            return path == mount || path.hasPrefix(mount.hasSuffix("/") ? mount : mount + "/")
        }
    }

    // MARK: The original

    /// Where the app was before macOS made its temporary copy, or the bundle itself off an image. Nil when the lookup fails.
    static func original(of bundle: URL, situation: Situation, lookup: (URL) -> URL? = { translocatedOriginal(of: $0) }) -> URL? {
        switch situation {
        case .onDiskImage: return bundle
        case .translocated: return lookup(bundle)
        }
    }

    private typealias OriginalPathFunction = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    /// `SecTranslocateCreateOriginalPathForURL`: exported by Security but declared in no public header, so looked up at run time.
    static func translocatedOriginal(of bundle: URL) -> URL? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(symbol, to: OriginalPathFunction.self)
        var error: Unmanaged<CFError>?
        guard let result = function(bundle as CFURL, &error) else {
            error?.release()
            return nil
        }
        return result.takeRetainedValue() as URL
    }

    // MARK: The move

    /// The checks, then the move, in the option's order. Any stop leaves what was there as it was, quarantine included.
    static func move(original: URL, places: Places, bundleIdentifier: String, trust: Trust?) -> Outcome {
        let fm = FileManager.default
        let target = places.applications.appendingPathComponent(targetName, isDirectory: true)

        // Before any file step: with no team on the running copy there is nothing to check the new copy against.
        guard let trust else { return .stopped("The running copy has no team signature to compare the new copy with.") }
        // A standard account can't add to Applications; no prompt of ours.
        guard fm.isWritableFile(atPath: places.applications.path) else { return .stopped(notWritable) }
        // A running Varnick is never replaced.
        if let stop = runningStop(places) { return stop }

        // Something that is not Varnick is at the target. A link there, even a dangling one, is not replaced.
        let existing = entry(at: target)
        if existing.isLink { return .stopped("\(target.path) is a link; remove it, then try again.") }
        let isTarget = samePath(original, target)
        if existing.exists, !isTarget {
            let found = Bundle(url: target)?.bundleIdentifier
            guard found == bundleIdentifier else {
                return .stopped("\(target.path) is not Varnick (\(found.map { "bundle id \($0)" } ?? "no bundle id")); move or rename it, then try again.")
            }
        }

        // Already there, moved by something other than Finder, so still quarantined: nothing to move.
        if isTarget {
            if let reason = clearQuarantineIfSigned(target, trust: trust) { return .stopped(reason) }
            return .moved(target)
        }

        // The new copy lands under a hidden name of its own, is checked, and only then does the old one go to the Trash.
        let temporary = places.applications.appendingPathComponent(".Varnick-moving-\(UUID().uuidString).app", isDirectory: true)
        var renamed = places.sameVolume(original, places.applications) && rename(original.path, temporary.path) == 0
        if !renamed, let reason = copy(original, to: temporary) {
            try? fm.removeItem(at: temporary)
            return .stopped("Varnick couldn't be copied to Applications: \(reason).")
        }
        var cleared: [Cleared] = []
        func undo() {
            if renamed {
                if rename(temporary.path, original.path) == 0 { restoreQuarantine(cleared, in: original) }
            } else {
                try? fm.removeItem(at: temporary)
            }
            renamed = false
        }

        if let reason = checkAndClear(temporary, trust: trust, cleared: &cleared) {
            undo()
            return .stopped(reason)
        }
        var trashed: URL?
        if existing.exists {
            if let stop = runningStop(places) {
                undo()
                return stop
            }
            do { trashed = try places.trash(target) } catch {
                undo()
                return .stopped("The Varnick in Applications couldn't be moved to the Trash: \(error.localizedDescription).")
            }
        }
        guard rename(temporary.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            var note = "Nothing was changed."
            if existing.exists, trashed.map({ rename($0.path, target.path) }) != 0 { note = "The previous copy is in the Trash." }
            undo()
            return .stopped("The new copy couldn't be put in place (\(reason)). \(note)")
        }
        return .moved(target)
    }

    private static func runningStop(_ places: Places) -> Outcome? {
        switch AccountLock.probe(in: places.support) {
        case nil: return nil
        case .busy(_, let path)?: return .alreadyRunning(path: path ?? "an unknown path")
        case .failed(let reason)?: return .stopped("Varnick can't tell whether it is already running: \(reason).")
        }
    }

    /// Whether anything is at `url`, a dangling link included, and whether it is a link.
    static func entry(at url: URL) -> (exists: Bool, isLink: Bool) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return (false, false) }
        return (true, (info.st_mode & S_IFMT) == S_IFLNK)
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool { a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }

    static func onSameVolume(_ a: URL, _ b: URL) -> Bool {
        var first = stat(), second = stat()
        return stat(a.path, &first) == 0 && stat(b.path, &second) == 0 && first.st_dev == second.st_dev
    }

    /// `ditto`, which keeps a bundle's links, attributes and signature as they are. Nil when it worked, else why not.
    private static func copy(_ source: URL, to destination: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : (said.isEmpty ? "ditto exited with \(process.terminationStatus)" : said)
    }

    // MARK: Signature and quarantine

    /// Checks the bundle's signature and, only if it passes, removes the download's quarantine from it. Nil when both worked.
    /// A failure puts back what it had removed.
    static func clearQuarantineIfSigned(_ bundle: URL, trust: Trust) -> String? {
        var cleared: [Cleared] = []
        guard let reason = checkAndClear(bundle, trust: trust, cleared: &cleared) else { return nil }
        restoreQuarantine(cleared, in: bundle)
        return reason
    }

    /// The same, leaving to the caller what was removed, so a later failure in the move can put it back.
    private static func checkAndClear(_ bundle: URL, trust: Trust, cleared: inout [Cleared]) -> String? {
        if let reason = verifySignature(of: bundle, trust: trust) { return reason }
        return clearQuarantine(in: bundle, cleared: &cleared)
    }

    /// Nil when the bundle's signature is valid, strictly and with its nested code, and satisfies the running copy's requirement.
    static func verifySignature(of bundle: URL, trust: Trust) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            return "The new copy's signature couldn't be read."
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, trust.requirement, nil)
        switch status {
        case errSecSuccess: return nil
        case errSecCSReqFailed: return "The new copy isn't signed as the running one is."
        default: return "The new copy's signature isn't valid (status \(status))."
        }
    }

    /// The running copy's team and designated requirement; nil when it has no team (ad hoc) or they can't be read.
    static func runningTrust() -> Trust? {
        var running: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code else { return nil }
        return trust(of: code)
    }

    /// A bundle's team and designated requirement, nil when it has no team or they can't be read.
    static func trust(of bundle: URL) -> Trust? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return trust(of: code)
    }

    private static func trust(of code: SecStaticCode) -> Trust? {
        var information: CFDictionary?
        var requirement: SecRequirement?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any], let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { return nil }
        return Trust(team: team, requirement: requirement)
    }

    /// Removes the quarantine attribute from the bundle and every item in it (links themselves, never what they point at),
    /// adding each value removed to `cleared`. Nil when it worked, else why not.
    static func clearQuarantine(in bundle: URL, cleared: inout [Cleared]) -> String? {
        func clear(_ relative: String) -> String? {
            let path = relative.isEmpty ? bundle.path : bundle.appendingPathComponent(relative).path
            let size = getxattr(path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return errno == ENOATTR ? nil : "The download's quarantine couldn't be read on \(path): \(String(cString: strerror(errno)))." }
            var value = Data(count: size)
            let read = value.withUnsafeMutableBytes { getxattr(path, quarantineAttribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            guard read == size else { return "The download's quarantine couldn't be read on \(path)." }
            guard removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) == 0 else {
                return "The download's quarantine couldn't be removed from \(path): \(String(cString: strerror(errno)))."
            }
            cleared.append(Cleared(path: relative, value: value))
            return nil
        }
        if let failure = clear("") { return failure }
        if let items = FileManager.default.enumerator(atPath: bundle.path) {
            for case let relative as String in items { if let failure = clear(relative) { return failure } }
        }
        return nil
    }

    /// Writes back what `clearQuarantine` removed, so a move that failed leaves the original as quarantined as it was.
    static func restoreQuarantine(_ cleared: [Cleared], in bundle: URL) {
        for item in cleared {
            let path = item.path.isEmpty ? bundle.path : bundle.appendingPathComponent(item.path).path
            _ = item.value.withUnsafeBytes { setxattr(path, quarantineAttribute, $0.baseAddress, item.value.count, 0, XATTR_NOFOLLOW) }
        }
    }

    // MARK: Afterwards

    /// `/usr/bin/open -n <bundle>`, a new instance as Restart opens one. Not BuildUpgrade's: the harness compiles this file alone.
    static func open(_ bundle: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundle.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : "open exited with \(process.terminationStatus)"
    }

    /// Starts a detached helper that waits for `pid` to end, then detaches the image by `device`, never forced.
    @discardableResult
    static func ejectAfterExit(of pid: Int32, device: String) -> Bool {
        let script = """
        n=0; while kill -0 "$1" 2>/dev/null && [ "$n" -lt 150 ]; do n=$((n+1)); sleep 0.2; done
        for i in 1 2 3 4 5; do /usr/bin/hdiutil detach "$2" >/dev/null 2>&1 && exit 0; sleep 1; done
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MPOSIX", "-e", "POSIX::setsid(); exec @ARGV", "/bin/sh", "-c", script, "sh", String(pid), device]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return true
    }
}
