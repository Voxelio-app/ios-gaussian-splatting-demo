// Copyright 2026 Voxelio.
// Licensed under the PolyForm Noncommercial License 1.0.0.

import MetalSplatter
import Msplat
import SplatIO
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Spacer()

                Image(systemName: "view.3d")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 8) {
                    Text("On-device Gaussian Splatting")
                        .font(.largeTitle.bold())

                    Text("Capture with ARKit, train with msplat, and render with MetalSplatter.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    pipelineRow(number: 1, title: "Capture", detail: "ARKit images and camera poses")
                    pipelineRow(number: 2, title: "Train", detail: "Metal-powered on-device 3DGS")
                    pipelineRow(number: 3, title: "Render", detail: "Real-time Gaussian splats")
                }

                Spacer()

                Label("Source packages connected", systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .navigationTitle("Voxelio 3DGS")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func pipelineRow(number: Int, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Text(number.formatted())
                .font(.caption.monospacedDigit().bold())
                .frame(width: 28, height: 28)
                .background(.quaternary, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
