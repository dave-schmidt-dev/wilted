import Foundation
import Darwin

/// Only XCTest roots minted below a live runner-owned parent outlive per-case teardown.
@MainActor
enum WiltedMacTestRootOwnership {
    private static var managedRoots: [String: Data] = [:]
    static let receiptName = ".wilted-managed-test-root"
    private enum OwnershipError: Error { case invalidParent, invalidProcess, unsafeMarker, invalidOwnerShape, invalidOwner, invalidOwnerPath(String, String), invalidOwnerStarted(String, String), invalidCreatedRoot, invalidReceipt }

    static func parent(rawValue: String?) throws -> URL {
        guard let rawValue else { return FileManager.default.temporaryDirectory }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard rawValue.hasPrefix("/"), realpath(rawValue, &buffer) != nil,
              String(cString: buffer) == rawValue else { throw OwnershipError.invalidParent }
        let supplied = URL(fileURLWithPath: rawValue, isDirectory: true)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rawValue, isDirectory: &directory), directory.boolValue,
              (try supplied.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw OwnershipError.invalidParent
        }
        return supplied
    }

    private static func started(_ pid: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "lstart=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !value.isEmpty else { throw OwnershipError.invalidProcess }
        return value
    }

    private static func owner(at directory: URL, environment: [String: String]) throws -> [String: Any]? {
        let marker = directory.appendingPathComponent(".wilted-temp-owned")
        var metadata = stat()
        let status = marker.path.withCString { lstat($0, &metadata) }
        if status != 0 {
            guard errno == ENOENT else { throw OwnershipError.unsafeMarker }
            return nil
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw OwnershipError.unsafeMarker
        }
        let lines = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        var values: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, values[String(parts[0])] == nil else { throw OwnershipError.invalidOwnerShape }
            values[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        guard values.count == 3 else { throw OwnershipError.invalidOwnerShape }
        guard values["path"] == directory.path else {
            throw OwnershipError.invalidOwnerPath(values["path"] ?? "<missing>", directory.path)
        }
        guard let pid = values["pid"].flatMap(Int.init), pid > 0,
              let start = values["started"] else { throw OwnershipError.invalidOwner }
        let observedStart = try started(pid)
        guard observedStart == start else { throw OwnershipError.invalidOwnerStarted(start, observedStart) }
        guard environment["WILTED_TEST_OWNER_PID"] == String(pid),
              environment["WILTED_TEST_OWNER_STARTED"] == start,
              environment["WILTED_TEST_OWNER_PATH"] == directory.path else {
            throw OwnershipError.invalidOwner
        }
        return ["owner_path": directory.path, "owner_pid": pid, "owner_started": start]
    }

    static func bindCreatedRoot(_ root: URL, parent: URL,
                                environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard root.deletingLastPathComponent().path == parent.path else {
            throw OwnershipError.invalidCreatedRoot
        }
        var candidate = parent
        while candidate.path != "/" {
            if var receipt = try owner(at: candidate, environment: environment) {
                guard let configured = environment["WILTED_TEST_TMPDIR"],
                      try self.parent(rawValue: configured).path == configured,
                      root.path.hasPrefix(configured + "/"),
                      try self.parent(rawValue: root.path).path == root.path else {
                    throw OwnershipError.invalidCreatedRoot
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
                receipt["path"] = root.path
                receipt["device"] = attributes[.systemNumber]
                receipt["inode"] = attributes[.systemFileNumber]
                let pid = Int(ProcessInfo.processInfo.processIdentifier)
                receipt["host_pid"] = pid
                receipt["host_started"] = try started(pid)
                let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                try data.write(to: root.appendingPathComponent(receiptName), options: [.withoutOverwriting])
                let refreshed = try owner(at: candidate, environment: environment)
                let current = try FileManager.default.attributesOfItem(atPath: root.path)
                guard NSDictionary(dictionary: refreshed ?? [:]).isEqual(to: receipt.filter { $0.key.hasPrefix("owner_") }),
                      current[.systemNumber] as? NSNumber == attributes[.systemNumber] as? NSNumber,
                      current[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber] as? NSNumber,
                      try Data(contentsOf: root.appendingPathComponent(receiptName)) == data else {
                    throw OwnershipError.invalidReceipt
                }
                managedRoots[root.path] = data
                return
            }
            candidate.deleteLastPathComponent()
        }
        guard ["WILTED_TEST_OWNER_PID", "WILTED_TEST_OWNER_STARTED", "WILTED_TEST_OWNER_PATH"].allSatisfy({ environment[$0] == nil }) else {
            throw OwnershipError.invalidOwner
        }
    }

    static func isManaged(_ root: URL) throws -> Bool {
        let marker = root.appendingPathComponent(receiptName)
        guard let expected = managedRoots[root.path] else {
            guard (try? marker.resourceValues(forKeys: [.isSymbolicLinkKey])) == nil else {
                throw OwnershipError.invalidReceipt
            }
            return false
        }
        guard try Data(contentsOf: marker) == expected else { throw OwnershipError.invalidReceipt }
        guard try parent(rawValue: root.path).path == root.path,
              (try marker.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any],
              receipt.count == 8, receipt["path"] as? String == root.path,
              let ownerPath = receipt["owner_path"] as? String,
              root.path.hasPrefix(ownerPath + "/"),
              let liveOwner = try owner(at: parent(rawValue: ownerPath), environment: ProcessInfo.processInfo.environment),
              NSDictionary(dictionary: liveOwner).isEqual(to: receipt.filter { $0.key.hasPrefix("owner_") }),
              receipt["host_pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier),
              receipt["host_started"] as? String == (try started(Int(ProcessInfo.processInfo.processIdentifier))) else {
            throw OwnershipError.invalidReceipt
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard receipt["device"] as? NSNumber == attributes[.systemNumber] as? NSNumber,
              receipt["inode"] as? NSNumber == attributes[.systemFileNumber] as? NSNumber else {
            throw OwnershipError.invalidReceipt
        }
        return true
    }
}

extension WiltedMacModel {
    /// One created, identity-bound root shared by the XCTest-hosted app composition.
    static let testHostStateDirectory: URL = {
        do {
            let parent = try WiltedMacTestRootOwnership.parent(rawValue: ProcessInfo.processInfo.environment["WILTED_TEST_TMPDIR"])
            let root = parent.appendingPathComponent("wilted-test-host-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try WiltedMacTestRootOwnership.bindCreatedRoot(root, parent: parent)
            return root
        } catch {
            fatalError("Invalid XCTest temporary root ownership: \(error)")
        }
    }()
}
