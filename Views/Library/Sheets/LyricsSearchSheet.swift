import SwiftUI

struct LyricsSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: LyricsSearchViewModel

    init(track: Track) {
        _model = StateObject(wrappedValue: LyricsSearchViewModel(track: track))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: String(appLocalized: "Search Lyrics Online..."))
                .font(.headline)
            Text(verbatim: model.track.url.lastPathComponent)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.track.url.path)
            Text(verbatim: String(appLocalized: "Search sends the title and artist below to the selected provider. Preview fetches lyrics for the selected song; audio files are not uploaded."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(appLocalized: "Title"))
                    TextField(String(appLocalized: "Title"), text: $model.title).onSubmit { model.search() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(appLocalized: "Artist"))
                    TextField(String(appLocalized: "Artist"), text: $model.artist).onSubmit { model.search() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(appLocalized: "Source"))
                    Picker(String(appLocalized: "Source"), selection: $model.provider) {
                        Text(verbatim: String(appLocalized: "NetEase Cloud Music")).tag(OnlineTagProvider.netease)
                        Text(verbatim: String(appLocalized: "QQ Music")).tag(OnlineTagProvider.qqMusic)
                    }.labelsHidden()
                }.frame(width: 190)
                Button(String(appLocalized: "Search")) { model.search() }.disabled(!model.canSearch)
            }
            .textFieldStyle(.roundedBorder)
            .disabled(model.isSaving)

            HStack {
                if model.isSearching || model.isDownloading || model.isSaving {
                    ProgressView().controlSize(.small)
                    Text(verbatim: String(appLocalized: "Loading lyrics"))
                } else if model.hasSearched && model.candidates.isEmpty {
                    Text(verbatim: String(appLocalized: "No matching songs. Try changing the title, artist or source."))
                } else {
                    Text(verbatim: String(appLocalized: "Select a song, preview its lyrics, then save."))
                }
                Spacer()
                Text(verbatim: String.localizedStringWithFormat(String(appLocalized: "Local duration: %1$@"), HelperUtils.formattedShortDuration(model.track.duration)))
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(minHeight: 20)

            Table(model.candidates, selection: $model.selection) {
                TableColumn(String(appLocalized: "Title"), value: \.title)
                TableColumn(String(appLocalized: "Artist"), value: \.artist)
                TableColumn(String(appLocalized: "Album"), value: \.album)
                TableColumn(String(appLocalized: "Duration")) { candidate in
                    Text(verbatim: candidate.duration.map(HelperUtils.formattedShortDuration) ?? "—").monospacedDigit()
                }.width(65)
            }
            .frame(minHeight: 160)
            .disabled(model.isSaving)

            HStack {
                Toggle(String(appLocalized: "Include lyric translations"), isOn: $model.includeTranslation)
                    .toggleStyle(.checkbox)
                    .disabled(model.isSaving)
                Spacer()
                Button(String(appLocalized: "Preview Lyrics")) { model.fetchPreview() }
                    .disabled(model.selectedCandidate == nil || model.isDownloading || model.isSaving)
            }
            GroupBox(String(appLocalized: "Lyrics Preview")) {
                ScrollView {
                    Text(verbatim: model.preview?.lrc ?? String(appLocalized: "Select a song and click Preview Lyrics."))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 170)
            }

            if let error = model.errorMessage {
                Text(verbatim: error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let url = model.savedURL {
                Text(verbatim: String.localizedStringWithFormat(String(appLocalized: "Lyrics saved: %1$@"), url.path))
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(verbatim: String(appLocalized: "Save creates a same-name .lrc file beside the audio file. Existing KSC files keep playback priority."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(appLocalized: "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSaving)
                Button(String(appLocalized: "Save Lyrics")) { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.preview == nil || model.isSaving || model.savedURL != nil)
            }
        }
        .padding(16)
        .frame(width: 820, height: 750)
        .interactiveDismissDisabled(model.isSaving)
        .onDisappear { model.cancel() }
        .alert(String(appLocalized: "Replace the existing LRC file?"), isPresented: $model.needsOverwriteConfirmation) {
            Button(String(appLocalized: "Cancel"), role: .cancel) {}
            Button(String(appLocalized: "Replace"), role: .destructive) { model.save(overwrite: true) }
        } message: {
            Text(verbatim: model.track.url.deletingPathExtension().appendingPathExtension("lrc").path)
        }
    }
}
