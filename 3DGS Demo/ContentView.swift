// Copyright 2026 Voxelio.
// Licensed under the PolyForm Noncommercial License 1.0.0.

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var library = LocalGaussianLibrary()
    @State private var path: [UUID] = []
    @State private var showsCapture = false
    @State private var pendingAssetID: UUID?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.assets.isEmpty {
                    ContentUnavailableView {
                        Label("No Gaussian splats", systemImage: "view.3d")
                    } description: {
                        Text("Capture a subject, train it on device, and inspect the result in Metal.")
                    } actions: {
                        Button("New capture", systemImage: "camera") {
                            showsCapture = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(library.assets) { asset in
                                NavigationLink(value: asset.id) {
                                    GaussianAssetRow(asset: asset)
                                }
                            }
                            .onDelete(perform: delete)
                        } header: {
                            Text("Local projects")
                        } footer: {
                            Text("Images, camera poses, checkpoints, and trained splats stay in this app's Documents directory.")
                        }
                    }
                }
            }
            .navigationTitle("Gaussian Splatting")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New capture", systemImage: "plus") {
                        showsCapture = true
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                GaussianAssetDetailView(assetID: id, library: library)
            }
            .fullScreenCover(isPresented: $showsCapture) {
                GaussianCaptureView(library: library) { asset in
                    pendingAssetID = asset.id
                    showsCapture = false
                }
            }
            .onChange(of: showsCapture) { _, isPresented in
                guard !isPresented, let id = pendingAssetID else { return }
                pendingAssetID = nil
                path.append(id)
            }
            .onAppear { library.refresh() }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            library.remove(library.assets[index])
        }
    }
}

private struct GaussianAssetRow: View {
    let asset: LocalGaussianAsset

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
                .frame(width: 72, height: 72)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(asset.title)
                    .font(.headline)

                Text(asset.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Label(asset.sampleCount.formatted(), systemImage: "photo.stack")
                    if let steps = asset.completedSteps {
                        Label(steps.formatted(), systemImage: "cpu")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = UIImage(contentsOfFile: asset.thumbnailURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "view.3d")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
