import Foundation
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

/// Activity rows for the Mac Activity popover and sidebar presentation.
struct WiltedMacActivitySummary: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        var id: String
        var label: String
        var value: String
        var tone: WiltedStatusTone

        init(id: String, label: String, value: String, tone: WiltedStatusTone = .neutral) {
            self.id = id
            self.label = label
            self.value = value
            self.tone = tone
        }
    }

    struct Group: Identifiable, Equatable, Sendable {
        var id: String { title }
        var title: String
        var rows: [Row]

        init(title: String, rows: [Row]) {
            self.title = title
            self.rows = rows
        }
    }

    struct Input: Equatable, Sendable {
        var headline: String
        var tone: WiltedStatusTone
        var deviceChangesRead: String
        var media: WiltedMacMediaActivity?
        var uploadingTitle: String?
        var requestLine: String?
        var directDownloadsOn: Bool
        var preparing: Int
        var preparationWaiting: Int
        var automationStatus: String

        init(
            headline: String,
            tone: WiltedStatusTone = .neutral,
            deviceChangesRead: String,
            media: WiltedMacMediaActivity? = nil,
            uploadingTitle: String? = nil,
            requestLine: String? = nil,
            directDownloadsOn: Bool,
            preparing: Int = 0,
            preparationWaiting: Int = 0,
            automationStatus: String
        ) {
            self.headline = headline
            self.tone = tone
            self.deviceChangesRead = deviceChangesRead
            self.media = media
            self.uploadingTitle = uploadingTitle
            self.requestLine = requestLine
            self.directDownloadsOn = directDownloadsOn
            self.preparing = preparing
            self.preparationWaiting = preparationWaiting
            self.automationStatus = automationStatus
        }
    }

    var groups: [Group]

    init(groups: [Group]) {
        self.groups = groups
    }

    /// Builds the structured activity summary from inputs using the provided time formatter.
    static func make(_ input: Input, time: (Date) -> String) -> WiltedMacActivitySummary {
        // 1. iCloud group
        var iCloudRows: [Row] = []

        // library row: headline and its tone
        iCloudRows.append(Row(id: "library", label: "Library", value: input.headline, tone: input.tone))

        // device-changes row: label "Device changes read", the input string
        iCloudRows.append(Row(id: "device-changes", label: "Device changes read", value: input.deviceChangesRead, tone: .neutral))

        // uploaded-ahead row: label "Uploaded ahead"
        let (uploadedAheadValue, uploadedAheadTone) = resolveUploadedAhead(
            media: input.media,
            uploadingTitle: input.uploadingTitle,
            time: time
        )
        iCloudRows.append(Row(id: "uploaded-ahead", label: "Uploaded ahead", value: uploadedAheadValue, tone: uploadedAheadTone))

        // requests row: label "iPhone requests": "None queued" or "N queued"
        let requestsValue: String
        let queuedCount = input.media?.requestsQueued ?? 0
        if queuedCount == 0 {
            requestsValue = "None queued"
        } else {
            requestsValue = "\(queuedCount) queued"
        }
        iCloudRows.append(Row(id: "requests", label: "iPhone requests", value: requestsValue, tone: .neutral))

        // rate row: label "Requests": requestLine without a leading "iCloud: ", omitted when nil
        if let line = input.requestLine {
            let stripped: String
            if line.hasPrefix("iCloud: ") {
                stripped = String(line.dropFirst("iCloud: ".count))
            } else {
                stripped = line
            }
            iCloudRows.append(Row(id: "rate", label: "Requests", value: stripped, tone: .neutral))
        }

        // direct row: label "Direct downloads": "On" or "Off"
        let directValue = input.directDownloadsOn ? "On" : "Off"
        iCloudRows.append(Row(id: "direct", label: "Direct downloads", value: directValue, tone: .neutral))

        let iCloudGroup = Group(title: "iCloud", rows: iCloudRows)

        // 2. This Mac group
        var macRows: [Row] = []

        // preparation row: counts only; the live stage stays on the Larder's Active work rows.
        let prepValue: String
        if input.preparing == 0 {
            prepValue = input.preparationWaiting > 0 ? "\(input.preparationWaiting) waiting" : "Idle"
        } else if input.preparationWaiting > 0 {
            prepValue = "\(input.preparing) preparing, \(input.preparationWaiting) waiting"
        } else {
            prepValue = "\(input.preparing) preparing"
        }
        macRows.append(Row(id: "preparation", label: "Preparation", value: prepValue, tone: .neutral))

        // automation row: label "Automation": the input string
        macRows.append(Row(id: "automation", label: "Automation", value: input.automationStatus, tone: .neutral))

        let macGroup = Group(title: "This Mac", rows: macRows)

        return WiltedMacActivitySummary(groups: [iCloudGroup, macGroup])
    }

    private static func resolveUploadedAhead(
        media: WiltedMacMediaActivity?,
        uploadingTitle: String?,
        time: (Date) -> String
    ) -> (value: String, tone: WiltedStatusTone) {
        guard let preupload = media?.preupload else {
            return ("Waiting for library sync", .neutral)
        }

        let baseValue: String
        let tone: WiltedStatusTone

        if preupload.isStopped {
            baseValue = "Stopped until library sync restarts"
            tone = .neutral
        } else if let pausedUntil = preupload.pausedUntil, preupload.pauseReason == .storageFull {
            baseValue = "Paused until \(time(pausedUntil)): iCloud storage is full"
            tone = .caution
        } else if let pausedUntil = preupload.pausedUntil, preupload.pauseReason == .retrying {
            baseValue = "Retrying at \(time(pausedUntil))"
            tone = .neutral
        } else if preupload.uploadingID != nil {
            let k = preupload.uploadedCount + 1
            let m = preupload.targetCount
            if let title = uploadingTitle, !title.isEmpty {
                baseValue = "Sending \(k) of \(m): \(title)"
            } else {
                baseValue = "Sending \(k) of \(m)"
            }
            tone = .neutral
        } else if preupload.targetCount == 0 {
            baseValue = "Nothing to upload"
            tone = .neutral
        } else {
            baseValue = "\(preupload.uploadedCount) of \(preupload.targetCount) in iCloud"
            tone = .neutral
        }

        let fullValue: String
        if preupload.setAsideCount > 0 {
            fullValue = "\(baseValue), \(preupload.setAsideCount) set aside"
        } else {
            fullValue = baseValue
        }

        return (fullValue, tone)
    }
}
