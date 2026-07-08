import SwiftUI

struct ContentView: View {
    @State private var selection: AppSection = .record

    var body: some View {
        HStack(spacing: 0) {
            NavigationRail(selection: $selection, enabledSections: [.record])

            Group {
                switch selection {
                case .record:
                    RecordingView()
                case .edit:
                    EditorView()
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
}

#Preview {
    ContentView()
}
