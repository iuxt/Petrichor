import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showingOnlineTagLookup = false
    @State private var didStartOnlineArtworkDownload = false
    @State private var embeddedTarget: TrackMetadataEditTarget?
    @State private var selectedTab: EditorTab = .details
    @State private var showingEmbeddedImporter = false
    @State private var embeddedImportTarget: TrackMetadataEditTarget?
    @State private var importingArtwork = false

    private enum EditorTab: CaseIterable, Hashable {
        case details
        case tags
        case artwork
        case lyrics

        var title: String {
            switch self {
            case .details: String(appLocalized: "Details")
            case .tags: String(appLocalized: "Tags")
            case .artwork: String(appLocalized: "Embedded Artwork")
            case .lyrics: String(appLocalized: "Embedded Lyrics")
            }
        }
    }

    private enum EmbeddedContent {
        case artwork
        case lyrics

        var title: String {
            switch self {
            case .artwork: String(appLocalized: "Embedded Artwork")
            case .lyrics: String(appLocalized: "Embedded Lyrics")
            }
        }
    }

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
        .onChange(of: model.allSelectedItemsSaved) { _, completed in
            finishAfterSuccessfulSave(completed)
        }
        .onChange(of: model.savedCount) { _, count in
            if count > 0 { startOnlineArtworkDownloadIfNeeded() }
        }
        .sheet(isPresented: $showingOnlineTagLookup) {
            if let form = model.form, let snapshot = model.snapshots.first {
                OnlineTagLookupSheet(
                    form: form,
                    filename: snapshot.file.filename,
                    duration: snapshot.file.duration
                ) { candidate, fields in
                    model.applyOnlineTags(candidate, fields: fields)
                    selectedTab = .tags
                }
            }
        }
        .fileImporter(
            isPresented: $showingEmbeddedImporter,
            allowedContentTypes: importingArtwork ? [.jpeg, .png] : [
                .plainText,
                UTType(filenameExtension: "lrc") ?? .plainText,
                UTType(filenameExtension: "ttml") ?? .xml,
                UTType(filenameExtension: "srt") ?? .plainText,
                UTType(filenameExtension: "ksc") ?? .plainText
            ]
        ) { result in
            switch result {
            case .success(let url):
                if let target = embeddedImportTarget {
                    let artwork = importingArtwork
                    Task { await model.importEmbeddedContent(from: url, for: target, artwork: artwork) }
                }
            case .failure(let error):
                model.embeddedImportError = error.localizedDescription
            }
        }
        .alert(String(appLocalized: "Could Not Embed Content"), isPresented: Binding(
            get: { model.embeddedImportError != nil },
            set: { if !$0 { model.embeddedImportError = nil } }
        )) {
            Button(String(appLocalized: "OK")) { model.embeddedImportError = nil }
        } message: {
            Text(verbatim: model.embeddedImportError ?? "")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            if model.tracks.count == 1, let track = model.tracks.first {
                AsyncArtworkImage(request: .thumbnail(track.artworkSourceURL, albumTitle: track.album, cueSheetURL: track.cueSegment?.sheetURL)) {
                    headerSymbol("music.note")
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: track.title.isEmpty ? track.filename : track.title)
                        .font(.title3.weight(.semibold))
                    Text(verbatim: [track.displayArtist, track.displayAlbum].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            } else {
                headerSymbol("music.note.list")
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(verbatim: headerTitle)
                    .font(.title3.weight(.semibold))
            }

            Spacer(minLength: 12)
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
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private func headerSymbol(_ symbol: String) -> some View {
        ZStack {
            Color.accentColor.opacity(0.10)
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
        }
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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

        case .editing:
            HStack {
                Button(String(appLocalized: "Get Tags Online")) {
                    showingOnlineTagLookup = true
                }
                .disabled(!model.canLookUpTags)
                .help(String(appLocalized: "Search online tags for a single writable track."))

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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
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
        VStack(spacing: 0) {
            Picker(headerTitle, selection: $selectedTab) {
                ForEach(EditorTab.allCases, id: \.self) { tab in
                    Text(verbatim: tab.title).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)
            .padding(.vertical, 12)

            Group {
                switch selectedTab {
                case .details, .tags:
                    ScrollView {
                        if selectedTab == .details {
                            fileInformationGroup
                        } else {
                            tagInformationGroup
                        }
                    }
                case .artwork:
                    embeddedInformationGroup(for: .artwork)
                case .lyrics:
                    embeddedInformationGroup(for: .lyrics)
                }
            }
            .id(selectedTab)
            .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
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

    // MARK: - Embedded Content

    private var embeddedSnapshot: TrackMetadataSnapshot? {
        model.snapshots.first { $0.target == embeddedTarget } ?? model.snapshots.first
    }

    private func embeddedInformationGroup(for content: EmbeddedContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.tracks.count > 1, !model.snapshots.isEmpty {
                Picker(String(appLocalized: "Selected Tracks"), selection: Binding(
                    get: { embeddedSnapshot?.target },
                    set: { embeddedTarget = $0 }
                )) {
                    ForEach(model.snapshots, id: \.target) { snapshot in
                        Text(verbatim: snapshot.file.filename).tag(Optional(snapshot.target))
                    }
                }
                .frame(maxWidth: 400, alignment: .leading)
            }

            if let snapshot = embeddedSnapshot {
                let isArtwork = content == .artwork
                let artwork = model.pendingArtwork[snapshot.target].map { [$0] } ?? snapshot.embeddedArtwork
                let lyrics = model.pendingLyrics[snapshot.target] ?? snapshot.embeddedLyrics
                let isPresent = isArtwork ? !artwork.isEmpty : lyrics != nil
                let isRemoving = isArtwork ? model.artworkRemovalTargets.contains(snapshot.target)
                    : model.lyricsRemovalTargets.contains(snapshot.target)
                let isEmbedding = isArtwork ? model.pendingArtwork[snapshot.target] != nil
                    : model.pendingLyrics[snapshot.target] != nil

                VStack(spacing: 0) {
                    embeddedContentControls(
                        title: content.title, isPresent: isPresent, isRemoving: isRemoving,
                        isEmbedding: isEmbedding, isWritable: snapshot.isWritable,
                        embed: { beginEmbeddedImport(for: snapshot.target, artwork: isArtwork) },
                        undoEmbedding: { model.undoEmbedding(for: snapshot.target, artwork: isArtwork) },
                        toggleRemoval: {
                            if isArtwork { model.toggleArtworkRemoval(for: snapshot.target) }
                            else { model.toggleLyricsRemoval(for: snapshot.target) }
                        }
                    )
                    .padding(12)
                    Divider()

                    if !isPresent {
                        embeddedPlaceholder(
                            symbol: isArtwork ? "photo" : "text.quote",
                            title: isArtwork ? String(appLocalized: "No embedded artwork") : String(appLocalized: "No embedded lyrics")
                        )
                    } else if isArtwork {
                        ScrollView {
                            LazyVStack(spacing: 18) {
                                ForEach(artwork.indices, id: \.self) { index in
                                    EmbeddedArtworkPreview(data: artwork[index])
                                }
                            }
                            .padding(18)
                        }
                        .background(.quaternary.opacity(0.3))
                    } else if let lyrics {
                        ScrollView {
                            Text(verbatim: lyrics)
                                .font(.body)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .frame(maxWidth: 540, alignment: .leading)
                                .padding(20)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .editorPanel()

                Text(verbatim: String(appLocalized: "Embedding replaces the existing embedded content. Changes are written only when you save. External lyrics and artwork files are kept."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                embeddedPlaceholder(symbol: "doc.questionmark", title: String(appLocalized: "File information unavailable"))
                    .editorPanel()
            }
        }
    }

    private func embeddedPlaceholder(symbol: String, title: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginEmbeddedImport(for target: TrackMetadataEditTarget, artwork: Bool) {
        embeddedImportTarget = target
        importingArtwork = artwork
        showingEmbeddedImporter = true
    }

    private func embeddedContentControls(
        title: String,
        isPresent: Bool,
        isRemoving: Bool,
        isEmbedding: Bool,
        isWritable: Bool,
        embed: @escaping () -> Void,
        undoEmbedding: @escaping () -> Void,
        toggleRemoval: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(verbatim: title)
                .font(.headline)
            if isRemoving || isEmbedding {
                Text(verbatim: String(appLocalized: isRemoving ? "Pending Deletion" : "Pending Embedding"))
                    .font(.caption)
                    .foregroundStyle(isRemoving ? Color.orange : Color.accentColor)
            }
            Spacer()
            if model.isImportingEmbeddedContent {
                ProgressView().controlSize(.small)
            }
            Button(String(appLocalized: "Embed…"), action: embed)
                .disabled(!isWritable || model.isImportingEmbeddedContent)
                .controlSize(.small)
            if isEmbedding {
                Button(String(appLocalized: "Undo Embedding"), action: undoEmbedding)
                    .disabled(model.isImportingEmbeddedContent)
                    .controlSize(.small)
            }
            if isPresent {
                Button(String(appLocalized: isRemoving ? "Undo Deletion" : "Delete"), action: toggleRemoval)
                    .disabled(!isWritable || model.isImportingEmbeddedContent)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - File Information

    private var fileInformationGroup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: String(appLocalized: "File Information"))
                .font(.headline)
            HStack(alignment: .top, spacing: 16) {
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
            }
            .padding(16)
            .editorPanel()

            VStack(alignment: .leading, spacing: 12) {
                informationRow(
                    String(appLocalized: "Filename"),
                    value: aggregate(
                        model.tracks.map { Optional($0.url.lastPathComponent) },
                        expectedCount: model.tracks.count
                    )
                )
                Divider()
                informationRow(
                    String(appLocalized: "File Path"),
                    value: aggregate(
                        model.tracks.map { Optional($0.url.path) },
                        expectedCount: model.tracks.count
                    )
                )
            }
            .padding(16)
            .editorPanel()

            if !model.unavailableResults.isEmpty {
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
        .padding(1)
    }

    private func informationRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    // MARK: - Tag Information

    private var tagInformationGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: String(appLocalized: "Tag Information"))
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        tagField(String(appLocalized: "Title"), field: .title)
                        tagField(String(appLocalized: "Artist"), field: .artist)
                    }
                    GridRow {
                        tagField(String(appLocalized: "Album"), field: .album)
                        tagField(String(appLocalized: "Album Artist"), field: .albumArtist)
                    }
                    GridRow {
                        tagField(String(appLocalized: "Composer"), field: .composer)
                        tagField(String(appLocalized: "Genre"), field: .genre)
                    }
                }
            }
            .padding(14)
            .editorPanel()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(verbatim: String(appLocalized: "Release Details"))
                        .font(.headline)
                    Spacer()
                    MixedStateCheckbox(
                        title: String(appLocalized: "Compilation"),
                        value: model.compilationValue,
                        isEnabled: model.phase != .saving,
                        accessibilityLabel: String(appLocalized: "Compilation"),
                        onChange: model.setCompilation
                    )
                    .fixedSize()
                }
                HStack(alignment: .top, spacing: 20) {
                    tagField(
                        String(appLocalized: "Release Date"), field: .releaseDate,
                        prompt: String(appLocalized: "YYYY or YYYY-MM-DD")
                    )
                    .frame(maxWidth: 178)
                    pairedNumberRow(
                        String(appLocalized: "Track Number"), field: .trackNumber, totalField: .trackTotal,
                        totalAccessibilityLabel: String(appLocalized: "Total Tracks")
                    )
                    pairedNumberRow(
                        String(appLocalized: "Disc Number"), field: .discNumber, totalField: .discTotal,
                        totalAccessibilityLabel: String(appLocalized: "Total Discs")
                    )
                    tagField(String(appLocalized: "BPM"), field: .bpm)
                        .frame(width: 58)
                }
            }
            .padding(14)
            .editorPanel()

            commentRow

            if let validationMessage = model.validationMessage {
                Text(verbatim: validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(String(appLocalized: "Failed"))
                    .accessibilityValue(validationMessage)
            }
        }
        .padding(1)
    }

    private func tagField(
        _ label: String, field: TrackMetadataEditableField, prompt: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            fieldLabel(label)
            metadataTextField(field: field, accessibilityLabel: label, prompt: prompt)
        }
    }

    private func pairedNumberRow(
        _ label: String,
        field: TrackMetadataEditableField,
        totalField: TrackMetadataEditableField,
        totalAccessibilityLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            fieldLabel(label)
            HStack(spacing: 4) {
                metadataTextField(field: field, accessibilityLabel: label, prompt: nil)
                Text(verbatim: "/")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                metadataTextField(field: totalField, accessibilityLabel: totalAccessibilityLabel, prompt: nil)
            }
            .frame(width: 114)
        }
    }

    private var commentRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(String(appLocalized: "Comment"))

            ZStack(alignment: .topLeading) {
                TextEditor(text: fieldBinding(.comment))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 54)
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
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
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
        startOnlineArtworkDownloadIfNeeded()
        didFinishSuccessfully = true
        NotificationManager.shared.addMessage(
            .info,
            String(appLocalized: "Saved")
        )
        dismiss()
    }

    private func startOnlineArtworkDownloadIfNeeded() {
        guard !didStartOnlineArtworkDownload,
              let candidate = model.appliedOnlineTagCandidate,
              let snapshot = model.snapshots.first,
              let coordinator = AppCoordinator.shared else { return }
        didStartOnlineArtworkDownload = true
        coordinator.automaticArtworkDownloader.downloadAfterTagSave(
            candidate, audioURL: snapshot.target.url,
            album: snapshot.tags.album ?? "", playbackManager: playbackManager
        )
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

private extension View {
    func editorPanel() -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator.opacity(0.55))
                    .allowsHitTesting(false)
            }
    }
}

private struct EmbeddedArtworkPreview: View {
    let data: Data
    @State private var image: NSImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 300)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    .accessibilityLabel(String(appLocalized: "Embedded Artwork"))
            } else if didLoad {
                Text(verbatim: String(appLocalized: "This embedded artwork cannot be displayed."))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: data) {
            image = nil
            didLoad = false
            let preview = await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
            guard !Task.isCancelled else { return }
            image = preview
            didLoad = true
        }
    }
}
