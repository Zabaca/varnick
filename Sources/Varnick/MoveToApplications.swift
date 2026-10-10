import Foundation
import Security

/// Move to Applications: what Varnick.app does when it runs from a temporary copy macOS made of a download (translocation) or straight
/// off a disk image. Foundation and Security only, every place a parameter (the Applications folder, the Trash, the support folder, the
/// list of attached images), so a harness compiles it alone with `InstalledApp.swift`, `AccountLock.swift` and `DatabaseLocation.swift`
/// against temporary folders (where-it-breaks, The installed app). The alert and the exit are `offerMoveToApplications`, beside `stopStart`.
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

    /// What a signature says about whose code it is. The running copy's is what a moved copy must match; no team is written anywhere.
    struct SigningIdentity: Equatable {
        var team: String?
        var identifier: String?
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
        var pid = getpid()
        /// Puts an existing copy where the user can recover it.
        var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        /// Whether the first can be renamed into the second's folder: a rename leaves nothing behind, a copy leaves the original.
        var sameVolume: (URL, URL) -> Bool = MoveToApplications.onSameVolume
    }

    // MARK: When it's offered

    /// Today's refusal line, with the reason after it, for every stop that falls back to it.
    static func stopLine(_ reason: String) -> String { InstalledApp.translocatedLine + ". " + reason }

    static let notWritable = "This account can't add apps to Applications; Finder will ask for an administrator when you drag Varnick there."

    /// Why the app is offered a move, or nil when it runs as it is: macOS translocated it (today's test), or its bundle is under
    /// `volumesRoot` on a volume the system lists as an attached disk image. The list is asked only for a bundle under `/Volumes`: a
    /// bundle on an external disk or a network volume is not an image and runs.
    static func situation(executablePath: String, bundle: URL, volumesRoot: String = "/Volumes",
                          images: () -> [AttachedImage] = { attachedImages() }) -> Situation? {
        if InstalledApp.isTranslocated(executablePath: executablePath) { return .translocated }
        let root = URL(fileURLWithPath: volumesRoot).resolvingSymlinksInPath().path
        guard bundle.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { return nil }
        return image(containing: bundle, in: images()) == nil ? nil : .onDiskImage
    }

    // MARK: Attached images

    /// The mounted volumes of `hdiutil info -plist`'s images. The device is the image's whole disk when the list names one, else the
    /// mounted volume's own.
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

    /// The image whose volume holds `url`.
    static func image(containing url: URL, in images: [AttachedImage]) -> AttachedImage? {
        let path = url.resolvingSymlinksInPath().path
        return images.first { image in
            let mount = URL(fileURLWithPath: image.mountPoint).resolvingSymlinksInPath().path
            return path == mount || path.hasPrefix(mount.hasSuffix("/") ? mount : mount + "/")
        }
    }

    // MARK: The original

    /// Where the app was before macOS made its temporary copy; the bundle itself when it runs off an image. Nil when the lookup fails.
    static func original(of bundle: URL, situation: Situation, lookup: (URL) -> URL? = { translocatedOriginal(of: $0) }) -> URL? {
        switch situation {
        case .onDiskImage: return bundle
        case .translocated: return lookup(bundle)
        }
    }

    private typealias OriginalPathFunction = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    /// `SecTranslocateCreateOriginalPathForURL`: Security exports it, but no public header declares it, so it is looked up at run time
    /// (as LetsMove does). Nil when it is missing or fails.
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

    /// The checks, then the move, in the order the option gives; each stop leaves what was there as it was. See `Outcome`.
    static func move(original: URL, places: Places, bundleIdentifier: String, expected: SigningIdentity) -> Outcome {
        let fm = FileManager.default
        let target = places.applications.appendingPathComponent(targetName, isDirectory: true)

        // 1. A standard account can't add to Applications; no prompt of ours.
        guard fm.isWritableFile(atPath: places.applications.path) else { return .stopped(notWritable) }

        // 2. A running Varnick is never replaced.
        if let held = AccountLock.probe(in: places.support) {
            switch held {
            case .busy(_, let path): return .alreadyRunning(path: path ?? "an unknown path")
            case .failed(let reason): return .stopped("Varnick can't tell whether it is already running: \(reason).")
            case .held: break
            }
        }

        // 3. Something that is not Varnick is at the target.
        let isTarget = samePath(original, target)
        let atTarget = (try? target.checkResourceIsReachable()) == true
        if atTarget, !isTarget {
            let found = Bundle(url: target)?.bundleIdentifier
            guard found == bundleIdentifier else {
                return .stopped("\(target.path) is not Varnick (\(found.map { "bundle id \($0)" } ?? "no bundle id")); move or rename it, then try again.")
            }
        }

        // 4. Already there, moved by something other than Finder, so still quarantined: nothing to move.
        if isTarget {
            if let reason = removeQuarantine(from: target, expected: expected) { return .stopped(reason) }
            return .moved(target)
        }

        // The new copy lands under a hidden name, is checked, and only then does the old one go to the Trash.
        let temporary = places.applications.appendingPathComponent(".Varnick-moving-\(places.pid).app", isDirectory: true)
        try? fm.removeItem(at: temporary)
        var renamed = false
        if places.sameVolume(original, places.applications) { renamed = rename(original.path, temporary.path) == 0 }
        if !renamed {
            if let reason = copy(original, to: temporary) {
                try? fm.removeItem(at: temporary)
                return .stopped("Varnick couldn't be copied to Applications: \(reason).")
            }
        }
        func undo() {
            if renamed { _ = rename(temporary.path, original.path) } else { try? fm.removeItem(at: temporary) }
        }

        if let reason = removeQuarantine(from: temporary, expected: expected) {
            undo()
            return .stopped(reason)
        }
        if atTarget {
            do { try places.trash(target) } catch {
                undo()
                return .stopped("The Varnick in Applications couldn't be moved to the Trash: \(error.localizedDescription).")
            }
        }
        guard rename(temporary.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            return .stopped("The new copy couldn't be put in place (\(reason)); it is at \(temporary.path)." + (atTarget ? " The previous copy is in the Trash." : ""))
        }
        return .moved(target)
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

    /// Checks the bundle's signature and, only if it carries the running copy's own team and identifier, removes the download's
    /// quarantine from it and everything in it. Nil when both worked, else why not; a failed check leaves the attribute.
    static func removeQuarantine(from bundle: URL, expected: SigningIdentity) -> String? {
        if let reason = verifySignature(of: bundle, expected: expected) { return reason }
        return clearQuarantine(in: bundle)
    }

    /// Nil when the bundle's signature is valid, strictly and with its nested code, and is the expected team's and identifier.
    static func verifySignature(of bundle: URL, expected: SigningIdentity) -> String? {
        guard let team = expected.team, let identifier = expected.identifier else {
            return "The running copy has no team signature to compare the new copy with."
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            return "The new copy's signature couldn't be read."
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil)
        guard status == errSecSuccess else { return "The new copy's signature isn't valid (status \(status))." }
        guard let found = identity(of: code), found.team == team, found.identifier == identifier else {
            return "The new copy isn't signed by the same team as the running one."
        }
        return nil
    }

    /// The running copy's own team and identifier.
    static func runningIdentity() -> SigningIdentity? {
        var running: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code else { return nil }
        return identity(of: code)
    }

    /// A bundle's team and identifier, nil when it can't be read.
    static func identity(of bundle: URL) -> SigningIdentity? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return identity(of: code)
    }

    private static func identity(of code: SecStaticCode) -> SigningIdentity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return SigningIdentity(team: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
                               identifier: dictionary[kSecCodeInfoIdentifier as String] as? String)
    }

    /// Removes the quarantine attribute from the bundle and every item inside it (links themselves, never what they point at).
    /// A bundle with none is fine. Nil when it worked, else why not.
    static func clearQuarantine(in bundle: URL) -> String? {
        var failure: String?
        func clear(_ path: String) {
            guard removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR, failure == nil else { return }
            failure = "The download's quarantine couldn't be removed from \(path): \(String(cString: strerror(errno)))."
        }
        clear(bundle.path)
        if let items = FileManager.default.enumerator(atPath: bundle.path) {
            for case let relative as String in items { clear(bundle.appendingPathComponent(relative).path) }
        }
        return failure
    }

    // MARK: Afterwards

    /// `/usr/bin/open -n <bundle>`: a new instance even while this one runs, as Restart opens one. Nil when it was asked, else why not.
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

    /// Starts a detached helper that waits for `pid` to end, then detaches the image by `device`, never forced: something else holding it
    /// keeps it mounted, and the person ejects it. The old copy's executable is on the image, so it can't be detached before it exits.
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
