import SwiftUI

struct ContentView: View {
    @ObservedObject var document: RunoutDocument
    @State private var selection: AppSection = .record
    @State private var selectedSideID: UUID?
    @State private var isRenamingSide = false
    @State private var sideRenameText = ""

    var body: some View {
        HStack(spacing: 0) {
            NavigationRail(selection: $selection, enabledSections: enabledSections)

            VStack(spacing: 0) {
                if selection != .record && !document.project.sides.isEmpty {
                    sideBar
                }
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
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            if selectedSideID == nil {
                selectedSideID = document.project.sides.first?.id
            }
        }
        .alert("Rename Side", isPresented: $isRenamingSide) {
            TextField("Name", text: $sideRenameText)
            Button("Rename") { commitSideRename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only changes the side's display name, not any exported files.")
        }
    }

    /// Switch between recorded sides and rename them (docs/FEATURES.md §1 side management) —
    /// without this, only the most recently recorded side was ever reachable in the editor,
    /// metadata, and export screens.
    private var sideBar: some View {
        HStack(spacing: 12) {
            if document.project.sides.count > 1 {
                sidePicker
            } else if let side = currentSide {
                Text(side.label)
                    .font(.callout.bold())
            }

            Button("Rename…") {
                sideRenameText = currentSide?.label ?? ""
                isRenamingSide = true
            }
            .disabled(selectedSideID == nil)

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var sidePicker: some View {
        let picker = Picker("Side", selection: $selectedSideID) {
            ForEach(document.project.sides) { side in
                Text(side.label).tag(Optional(side.id))
            }
        }
        .labelsHidden()

        if document.project.sides.count <= 4 {
            picker.pickerStyle(.segmented).frame(maxWidth: 360)
        } else {
            picker.pickerStyle(.menu).frame(maxWidth: 220)
        }
    }

    private var currentSide: RecordingSide? {
        document.project.sides.first(where: { $0.id == selectedSideID })
    }

    private func commitSideRename() {
        let trimmed = sideRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = document.project.sides.firstIndex(where: { $0.id == selectedSideID })
        else { return }
        document.project.sides[index].label = trimmed
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
