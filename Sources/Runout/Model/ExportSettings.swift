import Foundation

/// See docs/DATA_MODEL.md for the filename template token table.
struct ExportSettings: Codable, Equatable {
    var destinationFolder: URL
    var fileNameTemplate: String
    var overwriteBehavior: OverwriteBehavior

    init(
        destinationFolder: URL,
        fileNameTemplate: String = "{trackNumber} - {title}",
        overwriteBehavior: OverwriteBehavior = .appendNumber
    ) {
        self.destinationFolder = destinationFolder
        self.fileNameTemplate = fileNameTemplate
        self.overwriteBehavior = overwriteBehavior
    }
}

enum OverwriteBehavior: String, Codable {
    case skip
    case overwrite
    case appendNumber
}
