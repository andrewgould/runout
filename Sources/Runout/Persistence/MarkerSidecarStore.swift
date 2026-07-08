import Foundation

/// Reads/writes the `<recording>.markers.json` sidecar — a temporary bridge until M7's real
/// `.runout` project package lands (see docs/DATA_MODEL.md). Shared by `EditorSession` (which
/// owns the live editing session) and `MetadataSession` (which only needs to know the current
/// track boundaries, without opening its own editing session).
enum MarkerSidecarStore {
    static func sidecarURL(forRecordingAt recordingURL: URL) -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension("markers.json")
    }

    static func load(forRecordingAt recordingURL: URL) -> [Marker] {
        let url = sidecarURL(forRecordingAt: recordingURL)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Marker].self, from: data)
        else { return [] }
        return decoded.sorted { $0.sampleOffset < $1.sampleOffset }
    }

    static func save(_ markers: [Marker], forRecordingAt recordingURL: URL) {
        guard let data = try? JSONEncoder().encode(markers) else { return }
        try? data.write(to: sidecarURL(forRecordingAt: recordingURL), options: .atomic)
    }
}
