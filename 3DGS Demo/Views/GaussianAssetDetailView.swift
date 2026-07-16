// Copyright 2026 Voxelio.
// Licensed under the PolyForm Noncommercial License 1.0.0.

import SwiftUI
import UIKit

struct GaussianAssetDetailView: View {
    let assetID: UUID
    @ObservedObject var library: LocalGaussianLibrary

    @Environment(\.dismiss) private var dismiss
    @StateObject private var processor = LocalGaussianProcessor()
    @State private var showsViewer = false
    @State private var asksToDelete = false

    private var asset: LocalGaussianAsset? {
        library.asset(id: assetID)
    }

    var body: some View {
        Group {
            if let asset {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        preview(asset)
                        captureSummary(asset)

                        if processor.isRunning || !asset.hasSplat || !availableQualities(for: asset).isEmpty {
                            trainingPanel(asset)
                        }

                        if asset.hasSplat {
                            resultActions(asset)
                        }

                        Button("Delete project", systemImage: "trash", role: .destructive) {
                            asksToDelete = true
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    }
                    .padding()
                }
                .navigationTitle(asset.title)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear { processor.synchronize(with: asset) }
                .onChange(of: asset.updatedAt) { _, _ in
                    processor.synchronize(with: asset)
                }
                .fullScreenCover(isPresented: $showsViewer) {
                    GaussianFullScreenViewer(asset: asset)
                }
                .alert("Delete this project?", isPresented: $asksToDelete) {
                    Button("Delete", role: .destructive) {
                        library.remove(asset)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The source images, checkpoint, and trained splat will be removed from this device.")
                }
            } else {
                ContentUnavailableView(
                    "Project unavailable",
                    systemImage: "questionmark.folder",
                    description: Text("The local project could not be loaded.")
                )
            }
        }
    }

    @ViewBuilder
    private func preview(_ asset: LocalGaussianAsset) -> some View {
        ZStack {
            Color.black

            if processor.isRunning, let image = processor.trainingPreviewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if asset.hasSplat {
                LocalGaussianViewer(fileURL: asset.splatURL)
                    .allowsHitTesting(false)
            } else if let image = UIImage(contentsOfFile: asset.thumbnailURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.65))
            }

            if asset.hasSplat, !processor.isRunning {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label("Open viewer", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard asset.hasSplat, !processor.isRunning else { return }
            showsViewer = true
        }
    }

    private func captureSummary(_ asset: LocalGaussianAsset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture")
                .font(.title3.bold())

            LabeledContent("Views", value: asset.sampleCount.formatted())
            LabeledContent("Seed points", value: asset.seedPointCount.formatted())
            LabeledContent("Status", value: stageLabel(asset.stage))
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func trainingPanel(_ asset: LocalGaussianAsset) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(asset.hasSplat ? "Extend training" : "On-device training")
                .font(.title3.bold())

            if processor.isRunning {
                ProgressView(
                    value: Double(processor.completedIterations),
                    total: Double(processor.quality.iterations)
                )

                HStack {
                    Text("Iteration \(processor.completedIterations) / \(processor.quality.iterations)")
                    Spacer()
                    if processor.splatCount > 0 {
                        Text("\(processor.splatCount) splats")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Picker("Quality", selection: $processor.quality) {
                    ForEach(availableQualities(for: asset)) { quality in
                        Text("\(quality.label) · \(quality.detail)").tag(quality)
                    }
                }

                Button {
                    processor.process(asset, library: library)
                } label: {
                    Label(
                        asset.hasSplat ? "Continue to \(processor.quality.label)" : "Start training",
                        systemImage: "cpu"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(availableQualities(for: asset).isEmpty)
            }

            if case .failed(let message) = processor.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text("Training runs locally with msplat. Keep the app open until the selected target completes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func resultActions(_ asset: LocalGaussianAsset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result")
                .font(.title3.bold())

            Button("Open interactive viewer", systemImage: "view.3d") {
                showsViewer = true
            }
            .buttonStyle(.borderedProminent)

            ShareLink(item: asset.splatURL) {
                Label("Share SPZ", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)

            if let steps = asset.completedSteps {
                Text("SPZ · \(steps.formatted()) training iterations")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func availableQualities(for asset: LocalGaussianAsset) -> [LocalGaussianQuality] {
        LocalGaussianQuality.extensionTargets(after: asset.completedSteps ?? 0)
    }

    private func stageLabel(_ stage: LocalGaussianStage) -> String {
        switch stage {
        case .captured: "Captured"
        case .processing: "Training"
        case .ready: "Ready"
        case .failed: "Needs attention"
        }
    }
}

private struct GaussianFullScreenViewer: View {
    let asset: LocalGaussianAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            LocalGaussianViewer(fileURL: asset.splatURL)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
        }
    }
}
