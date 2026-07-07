import Foundation

/// See docs/DATA_MODEL.md. Markers must be kept sorted by `sampleOffset` by whoever mutates a project's marker list.
struct Marker: Codable, Identifiable, Equatable {
    var id: UUID
    var sampleOffset: Int64
    var label: String?

    init(id: UUID = UUID(), sampleOffset: Int64, label: String? = nil) {
        self.id = id
        self.sampleOffset = sampleOffset
        self.label = label
    }
}
