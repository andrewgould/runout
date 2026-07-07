import SwiftUI

/// M0 scaffolding placeholder. Recording/editing/tagging/export screens land in M1-M6 — see docs/ROADMAP.md.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Runout")
                .font(.largeTitle.bold())
            Text("Scaffolding milestone (M0). Recording, splitting, tagging, and export land in later milestones — see docs/ROADMAP.md.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
