import SwiftUI

/// Compact metadata editor for one track or a batch selection.
///
/// The ViewModel owns file IO and playback restoration. This view only projects its
/// phases and form state, which keeps mixed fields untouched until the user actually
/// changes their corresponding controls.
struct TrackMetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playlistManager: PlaylistManager
    @EnvironmentObject private var playbackManager: PlaybackManager

    @StateObject private var model: TrackMetadataEditorViewModel
    @State private var didFinishSuccessfully = false

    init(request: TrackMetadataEditorRequest) {
        _model = StateObject(
            wrappedValue: TrackMetadataEditorViewModel(tracks: request.tracks)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(
            minWidth: 700,
            idealWidth: 740,
            minHeight: 540,
            idealHeight: 620
        )
        .interactiveDismissDisabled(model.phase == .saving)
        .task {
            model.load()
        }
        .onChange(of: model.allSelectedItemsSaved) { completed in
            finishAfterSuccessfulSave(completed)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: Icons.xmarkCircleFill)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape)
            .focusable(false)
            .disabled(model.phase == .saving)
            .help(String(appLocalized: "Close"))
            .accessibilityLabel(String(appLocalized: "Close"))

            Text(verbatim: headerTitle)
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            loadingContent
        case .editing:
            editorContent(isDisabled: false)
        case .saving:
            savingContent
        case .results:
            resultsContent
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .loading:
            HStack {
                Spacer()
                Button(String(appLocalized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)

        case .editing:
            HStack {
                Spacer()
                Button(String(appLocalized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(appLocalized: "Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
            .padding(12)

        case .saving:
            HStack {
                Text(verbatim: savingProgressText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                Button(String(appLocalized: "Cancel")) {}
                    .keyboardShortcut(.cancelAction)
                    .disabled(true)

                Button(String(appLocalized: "Save")) {}
                    .keyboardShortcut(.defaultAction)
                    .disabled(true)
            }
            .padding(12)

        case .results:
            HStack {
                Spacer()

                if model.hasFailuresToRetry {
                    Button(String(appLocalized: "Retry Failed")) {
                        retryFailed()
                    }
                }

                Button(String(appLocalized: "Close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
    }

    // MARK: - Phase Content

    private var loadingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(verbatim: String(appLocalized: "Reading Tags..."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(appLocalized: "Reading Tags..."))
    }

    private var savingContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verbatim: savingProgressText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .monospacedDigit()
                    Spacer()
                    Text(verbatim: "\(model.currentProgress) / \(model.totalProgress)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                ProgressView(
                    value: Double(model.currentProgress),
                    total: Double(max(model.totalProgress, 1))
                )
                .accessibilityLabel(String(appLocalized: "Save"))
                .accessibilityValue(savingProgressText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            editorContent(isDisabled: true)
        }
    }

    private func editorContent(isDisabled: Bool) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                fileInformationGroup
                    .frame(minWidth: 245, idealWidth: 265, maxWidth: 285)

                tagInformationGroup
                    .frame(minWidth: 390, maxWidth: .infinity)
            }
            .padding(16)
        }
        .disabled(isDisabled)
    }

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            resultSummary

            if let playbackError = model.playbackRestorationError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(verbatim: playbackError)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.orange.opacity(0.08))
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(appLocalized: "Failed"))
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(unsuccessfulResults) { result in
                        resultRow(result)
                        if result.id != unsuccessfulResults.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - File Information

    private var fileInformationGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                if model.tracks.count > 1 {
                    informationRow(
                        String(appLocalized: "Selected Tracks"),
                        value: String(model.tracks.count)
                    )
                    Divider()
                }

                informationRow(
                    String(appLocalized: "Filename"),
                    value: aggregate(
                        model.tracks.map { Optional($0.url.lastPathComponent) },
                        expectedCount: model.tracks.count
                    )
                )
                informationRow(
                    String(appLocalized: "File Path"),
                    value: aggregate(
                        model.tracks.map { Optional($0.url.path) },
                        expectedCount: model.tracks.count
                    )
                )
                informationRow(
                    String(appLocalized: "Format"),
                    value: aggregate(
                        model.snapshots.map { Optional($0.file.format.uppercased()) },
                        expectedCount: model.tracks.count
                    )
                )
                informationRow(
                    String(appLocalized: "Duration"),
                    value: aggregate(
                        model.snapshots.map(\.file.duration),
                        expectedCount: model.tracks.count,
                        format: HelperUtils.formattedShortDuration
                    )
                )
                informationRow(
                    String(appLocalized: "File Size"),
                    value: aggregate(
                        model.snapshots.map(\.file.fileSize),
                        expectedCount: model.tracks.count,
                        format: Self.formattedFileSize
                    )
                )

                if !model.unavailableResults.isEmpty {
                    Divider()
                    HStack {
                        Text(verbatim: String(appLocalized: "Skipped"))
                        Spacer()
                        Text(verbatim: String(model.unavailableResults.count))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)

                    ForEach(model.unavailableResults) { result in
                        if case .skipped(let reason) = result.outcome {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: result.target.displayName)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(verbatim: reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(verbatim: String(appLocalized: "File Information"))
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    private func informationRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.subheadline)
                .lineLimit(label == String(appLocalized: "File Path") ? 2 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    // MARK: - Tag Information

    private var tagInformationGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    textRow(String(appLocalized: "Title"), field: .title)
                    textRow(String(appLocalized: "Artist"), field: .artist)
                    textRow(String(appLocalized: "Album"), field: .album)
                    textRow(String(appLocalized: "Album Artist"), field: .albumArtist)
                    textRow(String(appLocalized: "Composer"), field: .composer)
                    textRow(String(appLocalized: "Genre"), field: .genre)
                    textRow(
                        String(appLocalized: "Release Date"),
                        field: .releaseDate,
                        prompt: String(appLocalized: "YYYY or YYYY-MM-DD")
                    )
                    pairedNumberRow(
                        String(appLocalized: "Track Number"),
                        field: .trackNumber,
                        totalField: .trackTotal,
                        totalAccessibilityLabel: String(appLocalized: "Total Tracks")
                    )
                    pairedNumberRow(
                        String(appLocalized: "Disc Number"),
                        field: .discNumber,
                        totalField: .discTotal,
                        totalAccessibilityLabel: String(appLocalized: "Total Discs")
                    )
                    narrowTextRow(String(appLocalized: "BPM"), field: .bpm)
                    compilationRow
                    commentRow
                }

                if let validationMessage = model.validationMessage {
                    Text(verbatim: validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(String(appLocalized: "Failed"))
                        .accessibilityValue(validationMessage)
                }
            }
        } label: {
            Text(verbatim: String(appLocalized: "Tag Information"))
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    private func textRow(
        _ label: String,
        field: TrackMetadataEditableField,
        prompt: String? = nil
    ) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            fieldLabel(label)
            metadataTextField(
                field: field,
                accessibilityLabel: label,
                prompt: prompt
            )
        }
    }

    private func narrowTextRow(
        _ label: String,
        field: TrackMetadataEditableField
    ) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            fieldLabel(label)
            HStack {
                metadataTextField(
                    field: field,
                    accessibilityLabel: label,
                    prompt: nil
                )
                .frame(width: 90)
                Spacer(minLength: 0)
            }
        }
    }

    private func pairedNumberRow(
        _ label: String,
        field: TrackMetadataEditableField,
        totalField: TrackMetadataEditableField,
        totalAccessibilityLabel: String
    ) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            fieldLabel(label)
            HStack(spacing: 7) {
                metadataTextField(
                    field: field,
                    accessibilityLabel: label,
                    prompt: nil
                )
                .frame(width: 72)

                Text(verbatim: "/")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                metadataTextField(
                    field: totalField,
                    accessibilityLabel: totalAccessibilityLabel,
                    prompt: nil
                )
                .frame(width: 72)

                Spacer(minLength: 0)
            }
        }
    }

    private var compilationRow: some View {
        GridRow(alignment: .center) {
            fieldLabel(String(appLocalized: "Compilation"))
            MixedStateCheckbox(
                title: "",
                value: model.compilationValue,
                isEnabled: model.phase != .saving,
                accessibilityLabel: String(appLocalized: "Compilation"),
                onChange: model.setCompilation
            )
            .fixedSize()
        }
    }

    private var commentRow: some View {
        GridRow(alignment: .top) {
            fieldLabel(String(appLocalized: "Comment"))
                .padding(.top, 5)

            ZStack(alignment: .topLeading) {
                TextEditor(text: fieldBinding(.comment))
                    .font(.body)
                    .frame(minHeight: 64, idealHeight: 76)
                    .padding(2)
                    .accessibilityLabel(String(appLocalized: "Comment"))
                    .accessibilityValue(commentAccessibilityValue)

                if model.showsMixedPlaceholder(for: .comment),
                   model.text(for: .comment).isEmpty {
                    Text(verbatim: String(appLocalized: "Multiple Values"))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        isInvalid(.comment)
                            ? Color.red
                            : Color(nsColor: .separatorColor),
                        lineWidth: isInvalid(.comment) ? 1.5 : 1
                    )
            }
        }
    }

    private var commentAccessibilityValue: String {
        if model.showsMixedPlaceholder(for: .comment) {
            return String(appLocalized: "Multiple Values")
        }
        return model.text(for: .comment)
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(verbatim: label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(width: 96, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func metadataTextField(
        field: TrackMetadataEditableField,
        accessibilityLabel: String,
        prompt: String?
    ) -> some View {
        TextField(
            "",
            text: fieldBinding(field),
            prompt: Text(
                verbatim: model.showsMixedPlaceholder(for: field)
                    ? String(appLocalized: "Multiple Values")
                    : (prompt ?? "")
            )
        )
        .textFieldStyle(.roundedBorder)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isInvalid(field) ? Color.red : Color.clear,
                    lineWidth: 1.5
                )
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func fieldBinding(
        _ field: TrackMetadataEditableField
    ) -> Binding<String> {
        Binding(
            get: { model.text(for: field) },
            set: { model.setText($0, for: field) }
        )
    }

    private func isInvalid(_ field: TrackMetadataEditableField) -> Bool {
        model.validationError?.field == field
    }

    // MARK: - Results

    private var resultSummary: some View {
        HStack(spacing: 18) {
            resultCount(
                String(appLocalized: "Saved"),
                count: model.savedCount,
                color: .green
            )
            resultCount(
                String(appLocalized: "Skipped"),
                count: model.skippedCount,
                color: .orange
            )
            resultCount(
                String(appLocalized: "Failed"),
                count: model.failedCount,
                color: .red
            )
            Spacer()
        }
    }

    private func resultCount(
        _ label: String,
        count: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(verbatim: label)
                .foregroundStyle(.secondary)
            Text(verbatim: String(count))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(String(count))
    }

    private var unsuccessfulResults: [TrackMetadataBatchResult] {
        model.saveResults.filter { result in
            switch result.outcome {
            case .saved:
                return false
            case .skipped, .failed:
                return true
            }
        }
    }

    private func resultRow(_ result: TrackMetadataBatchResult) -> some View {
        let presentation = resultPresentation(result.outcome)

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: presentation.icon)
                .foregroundStyle(presentation.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: result.target.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(verbatim: presentation.status)
                        .font(.caption)
                        .foregroundStyle(presentation.color)
                }
                Text(verbatim: presentation.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func resultPresentation(
        _ outcome: TrackMetadataBatchOutcome
    ) -> (icon: String, color: Color, status: String, reason: String) {
        switch outcome {
        case .saved:
            return (
                "checkmark.circle.fill",
                .green,
                String(appLocalized: "Saved"),
                ""
            )
        case .skipped(let reason):
            return (
                "minus.circle.fill",
                .orange,
                String(appLocalized: "Skipped"),
                reason
            )
        case .failed(let reason):
            return (
                "xmark.circle.fill",
                .red,
                String(appLocalized: "Failed"),
                reason
            )
        }
    }

    // MARK: - Actions and Formatting

    private var headerTitle: String {
        guard model.tracks.count != 1 else {
            return String(appLocalized: "Track Info")
        }

        return String.localizedStringWithFormat(
            String(appLocalized: "Track Info (%1$lld Tracks)"),
            Int64(model.tracks.count)
        )
    }

    private var savingProgressText: String {
        String.localizedStringWithFormat(
            String(appLocalized: "Saving %1$lld of %2$lld"),
            Int64(model.currentProgress),
            Int64(model.totalProgress)
        )
    }

    private func save() {
        model.save(
            libraryManager: libraryManager,
            playlistManager: playlistManager,
            playbackManager: playbackManager
        )
    }

    private func retryFailed() {
        model.retryFailed(
            libraryManager: libraryManager,
            playlistManager: playlistManager,
            playbackManager: playbackManager
        )
    }

    private func finishAfterSuccessfulSave(_ completed: Bool) {
        guard completed,
              !model.isAwaitingPlaybackRestoration,
              !didFinishSuccessfully else {
            return
        }
        didFinishSuccessfully = true
        NotificationManager.shared.addMessage(
            .info,
            String(appLocalized: "Saved")
        )
        dismiss()
    }

    private func aggregate(
        _ values: [String?],
        expectedCount: Int
    ) -> String {
        let result = aggregate(
            values,
            expectedCount: expectedCount,
            format: { $0 }
        )
        return result.isEmpty ? "—" : result
    }

    private func aggregate<Value: Equatable>(
        _ values: [Value?],
        expectedCount: Int,
        format: (Value) -> String
    ) -> String {
        guard values.count == expectedCount, let first = values.first else {
            return expectedCount > 1
                ? String(appLocalized: "Multiple Values")
                : "—"
        }

        guard values.dropFirst().allSatisfy({ $0 == first }) else {
            return String(appLocalized: "Multiple Values")
        }

        guard let first else { return "—" }
        return format(first)
    }

    private static func formattedFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
