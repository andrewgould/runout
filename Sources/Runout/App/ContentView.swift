import SwiftUI

struct ContentView: View {
    @ObservedObject var document: RunoutDocument
    @State private var selection: AppSection = .record
    @State private var selectedSideID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            NavigationRail(selection: $selection, enabledSections: enabledSections)

            Group {
                switch selection {
                case .record:
                    RecordingView(document: document, onRecordingFinished: { sideID in
                        selectedSideID = sideID
                        selection = .edit
                    })
                case .edit:
                    EditorView(document: document, sideID: selectedSideID)
                case .tag:
                    MetadataView(document: document, sideID: selectedSideID)
                case .export:
                    ExportView(document: document, sideID: selectedSideID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            if selectedSideID == nil {
                selectedSideID = document.project.sides.first?.id
            }
        }
    }

    /// Later stages only make sense once there's something for them to work on — see
    /// docs/UI_SPEC.md.
    private var enabledSections: Set<AppSection> {
        selectedSideID == nil ? [.record] : [.record, .edit, .tag, .export]
    }
}

#Preview {
    ContentView(document: RunoutDocument())
}
