import SwiftUI

@main
struct RunoutApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { RunoutDocument() }) { configuration in
            ContentView(document: configuration.document)
        }
    }
}
