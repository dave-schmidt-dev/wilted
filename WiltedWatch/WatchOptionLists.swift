import SwiftUI

/// The speed choices, pushed from Now Playing. watchOS has no `Menu`, so the
/// options live on their own list; picking one sends it and returns.
struct SpeedListView: View {
    /// The state the list reads the current rate from and sends through.
    let model: WatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(WatchSpeeds.all, id: \.self) { rate in
            Button {
                model.setSpeed(rate)
                dismiss()
            } label: {
                HStack {
                    Text(NowPlayingView.speedText(rate))
                    Spacer()
                    if rate == model.currentSpeed {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityAddTraits(rate == model.currentSpeed ? .isSelected : [])
        }
        .navigationTitle("Speed")
    }
}

/// The sleep timer choices, pushed from Now Playing: fixed durations, end of
/// episode, and cancel. Picking one sends it and returns.
struct SleepListView: View {
    /// The state the list sends through.
    let model: WatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(WatchViewModel.sleepMinutes, id: \.self) { minutes in
                Button("\(minutes) minutes") {
                    model.startSleep(minutes: minutes)
                    dismiss()
                }
            }
            Button("End of episode") {
                model.sleepAtEndOfEpisode()
                dismiss()
            }
            Button("Cancel sleep timer", role: .destructive) {
                model.cancelSleep()
                dismiss()
            }
        }
        .navigationTitle("Sleep Timer")
    }
}
