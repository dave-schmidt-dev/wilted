import Foundation
import WiltedDomain

/// Identifies the host application build and preparation engine version that
/// processed an episode.
public struct PodcastPreparationBuildStamp: Equatable, Sendable {
    public let appVersion: String?
    public let engineVersion: String

    public init(appVersion: String?, engineVersion: String) {
        self.appVersion = appVersion
        self.engineVersion = engineVersion
    }

    /// Derives the host application version string from an info dictionary.
    ///
    /// Returns `nil` unless `WiltedSourceCommit` is present as a `String` (which
    /// distinguishes the host application from test runners and other hosts).
    /// Missing version keys fall back to `"?"`, and an empty commit produces
    /// `"<short> (<build>)"`. The result is bounded to 256 characters so it fits
    /// inside a `PreparationEvidence` field.
    public static func hostAppVersion(info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let info, let commit = info["WiltedSourceCommit"] as? String else {
            return nil
        }
        let shortVersion = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        let buildVersion = (info["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        let raw: String
        if commit.isEmpty {
            raw = "\(shortVersion) (\(buildVersion))"
        } else {
            raw = "\(shortVersion) (\(buildVersion), \(commit))"
        }
        return String(raw.prefix(256))
    }
}

extension PreparationRunSummary {
    /// The build and engine version stamp recorded for this run.
    ///
    /// The start row is read first because it exists for every run that reached
    /// the source, success or failure.
    public var buildStamp: PodcastPreparationBuildStamp? {
        for entry in entries {
            guard let evidence = entry.status.evidence,
                  evidence.kind == LocalLibraryStore.pipelineProvenanceEvidenceKind,
                  let engineVersion = evidence.fields["engineVersion"] else {
                continue
            }
            return PodcastPreparationBuildStamp(
                appVersion: evidence.fields["appVersion"],
                engineVersion: engineVersion
            )
        }
        return nil
    }
}
