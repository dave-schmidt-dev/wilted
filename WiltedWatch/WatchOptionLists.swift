import SwiftUI

/// The speed choices, pushed from Now Playing. watchOS has no `Menu`, so the
/// options live on their own list; picking one sends it and returns.
struct SpeedListView: View {
    /// The state the list reads the current rate from and sends through.
    let model: WatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List { choices }
            .navigationTitle("Speed")
    }

    /// Shipping choices without the native List/navigation chrome.
    var captureContent: some View { VStack { choices } }

    private var choices: some View {
        ForEach(WatchSpeeds.all, id: \.self) { rate in
            Button {
                if model.setSpeed(rate) { dismiss() }
            } label: {
                HStack {
                    Text(NowPlayingView.speedText(rate))
                    Spacer()
                    if model.isPending(.setRate(rate)) {
                        Image(systemName: "hourglass").accessibilityLabel("Pending")
                    } else if rate == model.currentSpeed {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                }
            }
            .disabled(!model.canSend(.setRate(rate)))
            .accessibilityValue(model.isPending(.setRate(rate)) ? "Pending" : "")
            .accessibilityAddTraits(rate == model.currentSpeed ? .isSelected : [])
        }
    }
}

/// The sleep timer choices, pushed from Now Playing: fixed durations, end of
/// episode, and cancel. Picking one sends it and returns.
struct SleepListView: View {
    /// The state the list sends through.
    let model: WatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List { choices }
            .navigationTitle("Sleep Timer")
    }

    /// Shipping choices without the native List/navigation chrome.
    var captureContent: some View { VStack { choices } }

    @ViewBuilder private var choices: some View {
        ForEach(WatchViewModel.sleepMinutes, id: \.self) { minutes in
            choice("\(minutes) minutes", action: .startSleep(minutes: minutes))
        }
        choice("End of episode", action: .startSleepEndOfEpisode)
        choice("Cancel sleep timer", action: .cancelSleep, role: .destructive)
    }

    private func choice(_ title: String, action: WatchCommand.Action, role: ButtonRole? = nil) -> some View {
        Button(role: role) {
            if model.send(action) { dismiss() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                if model.isPending(action) { Image(systemName: "hourglass").accessibilityLabel("Pending") }
            }
        }
        .disabled(!model.canSend(action))
        .accessibilityValue(model.isPending(action) ? "Pending" : "")
    }
}
