import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Screen 3 — see docs/UI_SPEC.md and assets/mockups/03-metadata.png.
struct MetadataView: View {
    @ObservedObject var document: RunoutDocument
    let sideID: UUID?

    @State private var totalSampleCount: Int64?
    @State private var errorMessage: String?
    @State private var loadedForSideID: UUID?

    var body: some View {
        Group {
            if let sideID, let side = document.project.sides.first(where: { $0.id == sideID }) {
                if loadedForSideID == sideID, let totalSampleCount {
                    MetadataWorkspaceView(document: document, sideID: sideID, totalSampleCount: totalSampleCount)
                } else if let errorMessage {
                    PlaceholderScreen(title: "Couldn't Load Recording", systemImage: "exclamationmark.triangle", message: errorMessage)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task(id: sideID) { await load(for: side) }
                }
            } else {
                PlaceholderScreen(
                    title: "Track & Album Metadata",
                    systemImage: "tag",
                    message: "Record and split something into tracks first."
                )
            }
        }
    }

    private func load(for side: RecordingSide) async {
        do {
            let fileURL = try document.materializedFileURL(forRelativePath: side.masterFileRelativePath)
            let length = try await Task.detached(priority: .userInitiated) {
                try AVAudioFile(forReading: fileURL).length
            }.value
            totalSampleCount = length
            loadedForSideID = side.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MetadataWorkspaceView: View {
    let document: RunoutDocument
    let sideID: UUID
    let totalSampleCount: Int64

    @StateObject private var session: MetadataSession
    @State private var selectedTrackID: UUID?
    @State private var isImportingCoverArt = false
    @State private var isShowingMusicBrainzLookup = false
    @State private var musicBrainzCoverArtError: String?

    init(document: RunoutDocument, sideID: UUID, totalSampleCount: Int64) {
        self.document = document
        self.sideID = sideID
        self.totalSampleCount = totalSampleCount
        _session = StateObject(wrappedValue: MetadataSession(document: document, sideID: sideID, totalSampleCount: totalSampleCount))
    }

    private var selectedTrack: Track? {
        guard let selectedTrackID else { return session.tracks.first }
        return session.tracks.first(where: { $0.id == selectedTrackID }) ?? session.tracks.first
    }

    var body: some View {
        HStack(spacing: 0) {
            trackList
                .frame(width: 260)

            Divider()

            if let track = selectedTrack {
                ScrollView {
                    formPanel(for: track)
                        .padding(24)
                }
            } else {
                PlaceholderScreen(title: "No Tracks", systemImage: "tag", message: "Split the recording into tracks first.")
            }
        }
        .fileImporter(isPresented: $isImportingCoverArt, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                session.setCoverArt(fromFileAt: url)
            }
        }
        .sheet(isPresented: $isShowingMusicBrainzLookup) {
            MusicBrainzLookupView(
                initialArtist: session.albumMetadata.albumArtist,
                initialAlbum: session.albumMetadata.albumTitle,
                onApply: { detail, fetchCoverArt in
                    session.applyMusicBrainzRelease(detail)
                    if fetchCoverArt {
                        fetchAndApplyCoverArt(releaseID: detail.id)
                    }
                }
            )
        }
    }

    /// Fire-and-forget from the sheet's callback (which isn't itself async) — errors surface via
    /// `musicBrainzCoverArtError` rather than blocking "Use This Release" on the download.
    private func fetchAndApplyCoverArt(releaseID: String) {
        Task {
            do {
                let client = CoverArtArchiveClient()
                let (data, fileExtension) = try await client.fetchFrontCoverImageData(releaseID: releaseID)
                session.setCoverArt(data: data, fileExtension: fileExtension)
            } catch {
                musicBrainzCoverArtError = "Couldn't fetch cover art from MusicBrainz: \(error.localizedDescription)"
            }
        }
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TRACKS")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top], 12)

            List(session.tracks, selection: $selectedTrackID) { track in
                Text("\(track.trackNumber)  \(track.title)")
                    .tag(track.id)
            }
            .listStyle(.plain)
        }
        .onAppear {
            if selectedTrackID == nil { selectedTrackID = session.tracks.first?.id }
        }
    }

    private func formPanel(for track: Track) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            albumSection

            Divider()

            trackSection(for: track)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Output filename preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.resolvedFilename(for: track))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            if let error = session.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ALBUM")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    labeledField("Album Title", text: $session.albumMetadata.albumTitle)
                    HStack(spacing: 12) {
                        labeledField("Album Artist", text: $session.albumMetadata.albumArtist)
                        labeledField("Year", text: optionalBinding($session.albumMetadata.year), width: 100)
                        labeledField("Genre", text: optionalBinding($session.albumMetadata.genre), width: 140)
                    }
                }

                coverArtDropZone
            }

            HStack(spacing: 12) {
                Button("Apply Album Info to All Tracks") {
                    session.applyAlbumInfoToAllTracks()
                }
                Button {
                    isShowingMusicBrainzLookup = true
                } label: {
                    Label("Look Up on MusicBrainz", systemImage: "magnifyingglass")
                }
            }

            if let musicBrainzCoverArtError {
                Label(musicBrainzCoverArtError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }

    private var coverArtDropZone: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.secondary)
                if let coverArtURL = session.coverArtURL, let platformImage = PlatformImage(contentsOfFile: coverArtURL.path) {
                    Image(platformImage: platformImage)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Drop cover art")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 120)
            .contentShape(Rectangle())
            .onTapGesture { isImportingCoverArt = true }
            .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: nil) { providers in
                handleCoverArtDrop(providers)
            }

            Button("Paste") {
                if let (data, ext) = PasteboardImage.read() {
                    session.setCoverArt(data: data, fileExtension: ext)
                }
            }
            .font(.caption)
        }
    }

    private func handleCoverArtDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in session.setCoverArt(data: data, fileExtension: "png") }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in session.setCoverArt(fromFileAt: url) }
            }
            return true
        }
        return false
    }

    private func trackSection(for track: Track) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRACK \(track.trackNumber)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            labeledField("Title", text: trackBinding(track, \.title, default: ""))

            HStack(spacing: 12) {
                labeledField("Artist", text: optionalTrackBinding(track, \.artist), placeholder: session.albumMetadata.albumArtist)
                labeledField("Track #", text: trackNumberBinding(track), width: 80)
                labeledField("Disc #", text: discNumberBinding(track), width: 80)
            }
        }
    }

    // MARK: - Bindings

    private func labeledField(_ label: String, text: Binding<String>, width: CGFloat? = nil, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }

    private func optionalBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func trackBinding(_ track: Track, _ keyPath: WritableKeyPath<Track, String>, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { session.tracks.first(where: { $0.id == track.id })?[keyPath: keyPath] ?? defaultValue },
            set: { newValue in session.updateTrack(track.id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func optionalTrackBinding(_ track: Track, _ keyPath: WritableKeyPath<Track, String?>) -> Binding<String> {
        Binding(
            get: { session.tracks.first(where: { $0.id == track.id })?[keyPath: keyPath] ?? "" },
            set: { newValue in session.updateTrack(track.id) { $0[keyPath: keyPath] = newValue.isEmpty ? nil : newValue } }
        )
    }

    private func trackNumberBinding(_ track: Track) -> Binding<String> {
        Binding(
            get: { String(session.tracks.first(where: { $0.id == track.id })?.trackNumber ?? track.trackNumber) },
            set: { newValue in
                guard let number = Int(newValue) else { return }
                session.updateTrack(track.id) { $0.trackNumber = number }
            }
        )
    }

    private func discNumberBinding(_ track: Track) -> Binding<String> {
        Binding(
            get: { String(session.tracks.first(where: { $0.id == track.id })?.discNumber ?? track.discNumber) },
            set: { newValue in
                guard let number = Int(newValue) else { return }
                session.updateTrack(track.id) { $0.discNumber = number }
            }
        )
    }
}
