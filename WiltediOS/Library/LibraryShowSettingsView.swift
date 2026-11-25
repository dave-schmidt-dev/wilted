import SwiftUI
import WiltedDomain
import WiltedLibrary

/// Per-show listener controls reachable from an episode in the Larder.
struct LibraryShowSettingsView: View {
    @ObservedObject var model: LibraryAppModel
    let source: LibrarySource
    let defaultSpeed: Double
    @Environment(\.colorScheme) private var colorScheme

    private var speedCommand: LibraryShowPlaybackSpeedOutbox.Command? {
        model.showPlaybackSpeedCommands[source.id.rawValue]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xLarge) {
                WiltedSettingsCard(title: "Playback") {
                    Text("Choose the speed for this show. Saved episode progress and episode-specific speeds keep priority.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: WiltedTheme.Spacing.medium) {
                        Text("Playback speed").wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        Spacer(minLength: WiltedTheme.Spacing.small)
                        Picker("Playback speed for \(source.title)", selection: Binding(
                            get: { model.showPlaybackSpeed(for: source.id) ?? defaultSpeed },
                            set: { value in Task { await model.setShowPlaybackSpeed(value, for: source.id) } }
                        )) {
                            ForEach(PlaybackSpeeds.all, id: \.self) { rate in
                                Text(LibrarySettingsFormat.speed(rate)).tag(rate)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("wilted-library-show-playback-speed-\(source.id.rawValue)")
                        .disabled(model.macSupportsShowPlaybackSpeeds == false
                            || ((speedCommand?.reservedAt != nil || speedCommand?.sentAt != nil
                                 || speedCommand?.appliedRevision != nil) && speedCommand?.conflict == false))
                    }
                    Text("Default: \(LibrarySettingsFormat.speed(defaultSpeed))")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    if model.showPlaybackSpeed(for: source.id) != nil,
                       speedCommand?.conflict != true {
                        Button("Reset to this phone’s default") {
                            Task { await model.setShowPlaybackSpeed(nil, for: source.id) }
                        }
                        .accessibilityIdentifier("wilted-library-show-playback-speed-reset-\(source.id.rawValue)")
                    }
                    if model.macSupportsShowPlaybackSpeeds == false {
                        Text("Update Wilted on your Mac to use show playback speed.")
                            .wiltedFont(.utility)
                            .accessibilityIdentifier("wilted-library-show-playback-speed-update-mac")
                    }
                    if let notice = model.showPlaybackSpeedStatus(for: source.id) {
                        HStack(spacing: WiltedTheme.Spacing.small) {
                            Text(notice).wiltedFont(.utility)
                                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: WiltedTheme.Spacing.small)
                            if speedCommand?.conflict == true {
                                Button("Apply again") {
                                    Task { await model.reapplyShowPlaybackSpeed(for: source.id) }
                                }
                                .font(.footnote)
                                .accessibilityIdentifier("wilted-library-show-playback-speed-reapply-\(source.id.rawValue)")
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("wilted-library-show-playback-\(source.id.rawValue)")

                WiltedSettingsCard(title: "New episode starts") {
                    Text("Saved progress always resumes at its saved position.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: WiltedTheme.Spacing.medium) {
                        Text("Start new episodes at").wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        Spacer(minLength: WiltedTheme.Spacing.small)
                        let selected = model.showStartOffsetSeconds(for: source.id)
                        let options = Array(Set([0.0, 15, 30, 45, 60, 90, 120, 180, 300, 600, selected])).sorted()
                        Picker("Start new episodes at for \(source.title)", selection: Binding(
                            get: { model.showStartOffsetSeconds(for: source.id) },
                            set: { seconds in Task { await model.setShowStartOffset(seconds, for: source.id) } }
                        )) {
                            ForEach(options, id: \.self) { seconds in
                                Text(seconds == 0 ? "Beginning" : "\(Int(seconds)) seconds").tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("wilted-library-show-start-offset-\(source.id.rawValue)")
                        .disabled(model.macSupportsShowStartOffsets == false)
                    }
                    if let notice = model.showStartOffsetStatus(for: source.id) {
                        HStack(spacing: WiltedTheme.Spacing.small) {
                            Text(notice).wiltedFont(.utility)
                                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: WiltedTheme.Spacing.small)
                            if model.showStartOffsetCommands[source.id.rawValue]?.conflict == true {
                                Button("Apply again") {
                                    Task { await model.reapplyShowStartOffset(for: source.id) }
                                }
                                .font(.footnote)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("wilted-library-show-start-\(source.id.rawValue)")
            }
            .padding(WiltedTheme.Spacing.large)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-show-settings-\(source.id.rawValue)")
    }
}
