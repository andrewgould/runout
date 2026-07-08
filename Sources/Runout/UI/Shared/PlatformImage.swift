import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Reads an image (PNG preferred) off the system pasteboard/clipboard, if one is present.
enum PasteboardImage {
    static func read() -> (data: Data, fileExtension: String)? {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) { return (data, "png") }
        if let tiffData = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return (pngData, "png")
        }
        return nil
        #else
        guard let image = UIPasteboard.general.image, let data = image.pngData() else { return nil }
        return (data, "png")
        #endif
    }
}
