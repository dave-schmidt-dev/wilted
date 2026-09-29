import Foundation

/// Owns a UI-test-runner-local temporary parent for fixtures.
enum WiltedMacUITemporaryState {
    /// Returns a unique direct child without creating it.
    static func fixtureRoot(prefix: String) throws -> URL {
        guard prefix.hasPrefix("wilted-"),
              prefix.rangeOfCharacter(
                from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").inverted
              ) == nil
        else { throw FixtureRootError.invalidPrefix }

        let parent = try validatedParent()
        let root = parent.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw FixtureRootError.alreadyExists
        }
        print("wilted.ui.fixture.root=\(root.path) parent=\(parent.path)")
        return root
    }

    /// Removes only a direct, non-symlink child beneath the runner's parent.
    static func removeFixtureRoot(_ root: URL) throws {
        let parent = try validatedParent()
        let candidate = root.standardizedFileURL
        guard candidate == root,
              candidate.deletingLastPathComponent().path == parent.path,
              candidate.lastPathComponent.hasPrefix("wilted-"),
              candidate.resolvingSymlinksInPath() == candidate
        else { throw FixtureRootError.notOwned }

        guard FileManager.default.fileExists(atPath: candidate.path) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw FixtureRootError.notOwned }
        try FileManager.default.removeItem(at: candidate)
    }

    private static func validatedParent() throws -> URL {
        let canonical = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? canonical.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw FixtureRootError.invalidParent }
        return canonical
    }
}

private enum FixtureRootError: Error {
    case invalidParent
    case invalidPrefix
    case alreadyExists
    case notOwned
}
