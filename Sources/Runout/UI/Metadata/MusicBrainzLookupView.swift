import SwiftUI

/// Sheet presented from Screen 3's "Look Up on MusicBrainz" button — see docs/UI_SPEC.md.
struct MusicBrainzLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lookup: MusicBrainzLookupSession
    let onApply: (MusicBrainzReleaseDetail, _ fetchCoverArt: Bool) -> Void

    init(
        initialArtist: String,
        initialAlbum: String,
        onApply: @escaping (MusicBrainzReleaseDetail, Bool) -> Void
    ) {
        _lookup = StateObject(wrappedValue: MusicBrainzLookupSession(initialArtist: initialArtist, initialAlbum: initialAlbum))
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Look Up on MusicBrainz")
                .font(.title2.bold())

            searchRow

            if lookup.isSearching {
                ProgressView()
            }

            if let error = lookup.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            resultsList

            if lookup.isFetchingDetail {
                ProgressView("Loading track listing…")
            }

            if let detail = lookup.selectedDetail {
                Divider()
                detailPreview(detail)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 520)
    }

    private var searchRow: some View {
        HStack {
            TextField("Artist", text: $lookup.artistQuery)
                .textFieldStyle(.roundedBorder)
            TextField("Album", text: $lookup.albumQuery)
                .textFieldStyle(.roundedBorder)
            Button("Search") {
                Task { await lookup.search() }
            }
            .disabled(lookup.isSearching || (lookup.artistQuery.isEmpty && lookup.albumQuery.isEmpty))
        }
    }

    private var resultsList: some View {
        List(lookup.results) { result in
            Button {
                Task { await lookup.selectRelease(result) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.headline)
                    Text(resultSubtitle(for: result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 160)
    }

    private func resultSubtitle(for result: MusicBrainzReleaseSummary) -> String {
        var parts: [String] = [result.artist]
        if let date = result.date { parts.append(date) }
        if let country = result.country { parts.append(country) }
        if let trackCount = result.trackCount { parts.append("\(trackCount) tracks") }
        return parts.joined(separator: " · ")
    }

    private func detailPreview(_ detail: MusicBrainzReleaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(detail.title) — \(detail.artist)")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(detail.tracks, id: \.position) { track in
                        Text("\(track.position). \(track.title)")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)

            HStack {
                if detail.hasCoverArt {
                    Label("Cover art available", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Use This Release") {
                    onApply(detail, detail.hasCoverArt)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
