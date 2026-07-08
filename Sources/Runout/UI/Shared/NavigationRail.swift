import SwiftUI

/// The four workflow stages, left-to-right in time — see docs/UI_SPEC.md.
enum AppSection: String, CaseIterable, Identifiable {
    case record, edit, tag, export

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .record: return "record.circle"
        case .edit: return "waveform"
        case .tag: return "tag"
        case .export: return "square.and.arrow.up"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .record: return "Record"
        case .edit: return "Split into tracks"
        case .tag: return "Track and album metadata"
        case .export: return "Export"
        }
    }
}

/// Shared left-hand icon rail (Record / Edit / Tag / Export) — see docs/UI_SPEC.md.
/// A project only reaches later stages once it has something for them to work on, so
/// `enabledSections` lets the caller disable stages that don't apply yet.
struct NavigationRail: View {
    @Binding var selection: AppSection
    var enabledSections: Set<AppSection> = Set(AppSection.allCases)

    var body: some View {
        VStack(spacing: 20) {
            ForEach(AppSection.allCases) { section in
                let isSelected = selection == section
                let isEnabled = enabledSections.contains(section)

                Button {
                    selection = section
                } label: {
                    Image(systemName: section.symbolName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .frame(width: 44, height: 44)
                        .background(isSelected ? Color.orange : Color.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.35)
                .accessibilityLabel(section.accessibilityLabel)
            }
        }
        .padding(.vertical, 24)
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
}

/// Generic "not built yet" body for screens whose milestone hasn't landed.
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
