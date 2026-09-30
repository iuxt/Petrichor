import AppKit
import SwiftUI

struct ArtworkSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ArtworkSearchViewModel

    init(track: Track) {
        _model = StateObject(wrappedValue: ArtworkSearchViewModel(track: track))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: String(appLocalized: "Search Artwork Online..."))
                .font(.headline)
            Text(verbatim: model.track.url.lastPathComponent)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.track.url.path)
            Text(verbatim: String(appLocalized: "Search sends the title and artist to the selected music source. Selecting a result loads its cover preview. Audio files are not uploaded."))
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
                    Picker(String(appLocalized: "Source"), selection: $model.source) {
                        ForEach(OnlineTagProvider.allCases) { source in
                            Text(verbatim: source.displayName).tag(source)
                        }
                    }.labelsHidden()
                }.frame(width: 190)
                Button(String(appLocalized: "Search")) { model.search() }
                    .disabled(!model.canSearch)
            }
            .textFieldStyle(.roundedBorder)
            .disabled(model.isSaving)

            HStack {
                if model.isSearching || model.isCheckingArtwork {
                    ProgressView().controlSize(.small)
                    Text(verbatim: String(appLocalized: "Searching for artwork..."))
                } else if model.hasSearched && model.candidates.isEmpty {
                    Text(verbatim: String(appLocalized: "No matching songs. Try changing the title, artist or source."))
                } else {
                    Text(verbatim: String(appLocalized: "Select a song to preview its artwork."))
                }
                Spacer()
                Text(verbatim: String.localizedStringWithFormat(
                    String(appLocalized: "Local duration: %1$@"),
                    HelperUtils.formattedShortDuration(model.track.duration)
                )).monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(minHeight: 20)

            Table(model.candidates, selection: $model.selection) {
                TableColumn(String(appLocalized: "Title"), value: \.title)
                TableColumn(String(appLocalized: "Artist"), value: \.artist)
                TableColumn(String(appLocalized: "Album"), value: \.album)
                TableColumn(String(appLocalized: "Duration")) { candidate in
                    Text(verbatim: candidate.duration.map(HelperUtils.formattedShortDuration) ?? "—")
                        .monospacedDigit()
                }.width(65)
            }
            .frame(minHeight: 155)
            .disabled(model.isSaving)

            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let data = model.previewData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else if model.isLoadingPreview {
                        ProgressView()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 165, height: 165)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    if let candidate = model.selectedCandidate {
                        Text(verbatim: candidate.album.isEmpty ? candidate.title : candidate.album)
                            .font(.headline)
                        Text(verbatim: candidate.artist)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: String(appLocalized: "Select a song to preview its artwork."))
                            .foregroundStyle(.secondary)
                    }
                    if model.hasEmbeddedArtwork {
                        Text(verbatim: String(appLocalized: "This song has embedded artwork. External artwork cannot replace it here."))
                            .foregroundStyle(.orange)
                    } else if model.hasExistingArtwork {
                        Text(verbatim: String(appLocalized: "Saving another cover will use it for this song. Shared folder artwork is kept."))
                            .foregroundStyle(.secondary)
                    }
                    if let error = model.errorMessage {
                        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
                    } else if let url = model.savedURL {
                        Text(verbatim: String.localizedStringWithFormat(
                            String(appLocalized: "Artwork saved: %1$@"), url.path
                        )).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(verbatim: String(appLocalized: "The selected cover is saved as a same-name JPEG beside this song. It takes priority over shared folder artwork; the audio file is unchanged."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(String(appLocalized: "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSaving)
                Button(String(appLocalized: "Save Artwork")) { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.previewData == nil || model.isSaving || model.isCheckingArtwork ||
                              model.hasEmbeddedArtwork || model.savedURL != nil)
            }
        }
        .padding(16)
        .frame(width: 820, height: 620)
        .interactiveDismissDisabled(model.isSaving)
        .task { model.checkLocalArtwork() }
        .onDisappear { model.cancel() }
        .alert(String(appLocalized: "Use the downloaded artwork for this song?"),
               isPresented: $model.needsOverwriteConfirmation) {
            Button(String(appLocalized: "Cancel"), role: .cancel) {}
            Button(String(appLocalized: "Replace"), role: .destructive) { model.save(overwrite: true) }
        } message: {
            Text(verbatim: String(appLocalized: "The selected cover will take priority for this song. A same-name JPEG file may be replaced; shared folder artwork and the audio file are kept."))
        }
    }
}
