import SwiftUI

struct ContentView: View {
    @State private var selection: AppSection = .record
    @State private var lastRecordingURL: URL?

    var body: some View {
        HStack(spacing: 0) {
            NavigationRail(selection: $selection, enabledSections: enabledSections)

            Group {
                switch selection {
                case .record:
                    RecordingView(onRecordingFinished: { url in
                        lastRecordingURL = url
                        selection = .edit
                    })
                case .edit:
                    EditorView(recordingURL: lastRecordingURL)
                case .tag:
                    MetadataView()
                case .export:
                    ExportView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    /// Later stages only make sense once there's something for them to work on — see
    /// docs/UI_SPEC.md. Tag/Export land in M5/M6; only Record/Edit exist so far.
    private var enabledSections: Set<AppSection> {
        lastRecordingURL == nil ? [.record] : [.record, .edit]
    }
}

#Preview {
    ContentView()
}
