import Foundation

/// Generates default names and package-relative slugs for new recording sides. Spreadsheet-style
/// lettering (A…Z, AA, AB, …) rather than clamping at Z — the old clamp gave side 27+ the same
/// "side-z" slug, silently overwriting side 26's audio in the package
/// (docs/IMPROVEMENT_PLAN.md P1-1).
enum SideNaming {
    static func slugAndLabel(forIndex index: Int) -> (slug: String, label: String) {
        var letters = ""
        var value = index
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + value % 26))) + letters
            value = value / 26 - 1
        } while value >= 0
        return ("side-\(letters.lowercased())", "Side \(letters)")
    }

    /// The first naming from `startingIndex` upward whose master-file path collides with nothing
    /// in `existingMasterPaths` — a second line of defense so a naming bug (or a future
    /// side-deletion feature changing `sides.count`) can never silently overwrite another side's
    /// audio.
    static func nextAvailable(existingMasterPaths: Set<String>, startingIndex: Int) -> (slug: String, label: String) {
        var index = startingIndex
        while true {
            let candidate = slugAndLabel(forIndex: index)
            if !existingMasterPaths.contains("\(candidate.slug).flac") {
                return candidate
            }
            index += 1
        }
    }
}
