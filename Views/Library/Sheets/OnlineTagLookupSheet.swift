import SwiftUI

struct OnlineTagLookupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: OnlineTagLookupViewModel
    @State private var selectedFields = Set<TrackMetadataEditableField>()

    private let currentForm: TrackMetadataEditForm
    private let localDuration: Double?
    private let onApply: (OnlineTagCandidate, Set<TrackMetadataEditableField>) -> Void

    init(
        form: TrackMetadataEditForm,
        filename: String,
        duration: Double?,
        onApply: @escaping (OnlineTagCandidate, Set<TrackMetadataEditableField>) -> Void
    ) {
        currentForm = form
        localDuration = duration
        self.onApply = onApply
        let title = form.text(for: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        _model = StateObject(wrappedValue: OnlineTagLookupViewModel(
            title: title.isEmpty ? (filename as NSString).deletingPathExtension : title,
            artist: form.text(for: .artist)
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: String(appLocalized: "Get Tags Online"))
                .font(.headline)

            Text(verbatim: String(appLocalized: "Search sends only the title and artist entered below to the selected provider. Audio files are not uploaded."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(appLocalized: "Title"))
                    TextField(String(appLocalized: "Title"), text: $model.title)
                        .onSubmit { model.search() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(appLocalized: "Artist"))
                    TextField(String(appLocalized: "Artist"), text: $model.artist)
                        .onSubmit { model.search() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(appLocalized: "Source"))
                    Picker(String(appLocalized: "Source"), selection: $model.provider) {
                        Text(verbatim: String(appLocalized: "NetEase Cloud Music")).tag(OnlineTagProvider.netease)
                        Text(verbatim: String(appLocalized: "QQ Music")).tag(OnlineTagProvider.qqMusic)
                    }.labelsHidden()
                }.frame(width: 190)
                Button(String(appLocalized: "Search")) { model.search() }
                    .disabled(!model.canSearch)
            }
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                if model.isSearching {
                    ProgressView().controlSize(.small)
                    Text(verbatim: String(appLocalized: "Searching for tags..."))
                } else if let error = model.errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(verbatim: error)
                } else if model.hasSearched && model.candidates.isEmpty {
                    Text(verbatim: String(appLocalized: "No matching songs. Try changing the title, artist or source."))
                } else {
                    Text(verbatim: String(appLocalized: "Select a song to preview its tags."))
                }
                Spacer()
                if let localDuration {
                    Text(verbatim: String.localizedStringWithFormat(
                        String(appLocalized: "Local duration: %1$@"),
                        HelperUtils.formattedShortDuration(localDuration)
                    ))
                    .monospacedDigit()
                }
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
                }
                .width(65)
            }
            .frame(minHeight: 185)

            preview

            Text(verbatim: String(appLocalized: "Selected tags fill the properties form. Click Save there to write them to the audio file."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(String(appLocalized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(appLocalized: "Use Selected Tags")) {
                    guard let candidate = model.selectedCandidate, !selectedFields.isEmpty else { return }
                    onApply(candidate, selectedFields)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedCandidate == nil || selectedFields.isEmpty || model.isSearching)
            }
        }
        .padding(16)
        .frame(width: 800, height: 660)
        .onChange(of: model.selection) { _, _ in
            selectedFields = Set(changedFields.map(\.field))
        }
        .onDisappear { model.invalidateSearch() }
    }

    private var changedFields: [(field: TrackMetadataEditableField, value: String)] {
        model.selectedCandidate?.fields.filter { currentForm.text(for: $0.field) != $0.value } ?? []
    }

    private var preview: some View {
        GroupBox(String(appLocalized: "Tag Preview")) {
            ScrollView {
                if model.selectedCandidate == nil {
                    Text(verbatim: String(appLocalized: "Select a song to preview its tags."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if changedFields.isEmpty {
                    Text(verbatim: String(appLocalized: "These tags already match the current form."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Color.clear.frame(width: 125, height: 1)
                            Text(verbatim: String(appLocalized: "Current Value"))
                            Text(verbatim: String(appLocalized: "Online Value"))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(changedFields, id: \.field) { entry in
                            GridRow {
                                Toggle(fieldName(entry.field), isOn: Binding(
                                    get: { selectedFields.contains(entry.field) },
                                    set: { enabled in
                                        if enabled { selectedFields.insert(entry.field) }
                                        else { selectedFields.remove(entry.field) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .frame(width: 125, alignment: .leading)
                                previewValue(currentForm.text(for: entry.field))
                                    .foregroundStyle(.secondary)
                                previewValue(entry.value)
                            }
                        }
                    }
                }
            }
            .padding(6)
            .frame(height: 140)
        }
    }

    private func previewValue(_ value: String) -> some View {
        Text(verbatim: value.isEmpty ? "—" : value)
            .lineLimit(2)
            .help(value)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldName(_ field: TrackMetadataEditableField) -> String {
        switch field {
        case .title: String(appLocalized: "Title")
        case .artist: String(appLocalized: "Artist")
        case .album: String(appLocalized: "Album")
        case .trackNumber: String(appLocalized: "Track Number")
        default: field.englishDisplayName
        }
    }
}
