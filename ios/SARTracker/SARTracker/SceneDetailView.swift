import AVKit
import MapKit
import SwiftUI

struct SceneDetailView: View {
    @Environment(FeedStore.self) private var store
    @State private var scene: SARScene
    @State private var player: AVPlayer?
    @State private var showFullImage = false

    init(scene: SARScene) { _scene = State(initialValue: scene) }

    var body: some View {
        List {
            Section {
                Button { showFullImage = true } label: {
                    SARThumbnail(url: scene.thumbnail)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .accessibilityLabel("SAR image preview. Tap to enlarge.")
            } footer: {
                Text("Radar image preview. SAR sees through clouds and at night.")
            }

            if let player {
                Section("SAR video") {
                    VideoPlayer(player: player)
                        .aspectRatio(1, contentMode: .fit)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section("Acquisition") {
                row("Mode", scene.modeName)
                row("Satellite", scene.satellite)
                if let d = scene.date {
                    LabeledContent("Captured") {
                        Text(d, format: .dateTime.day().month().year().hour().minute().timeZone())
                    }
                }
                if let p = scene.polarizations, !p.isEmpty { row("Polarisation", p.joined(separator: ", ")) }
                if let o = scene.orbitState { row("Orbit", o.capitalized) }
                if let a = scene.incidenceAngle { row("Incidence angle", String(format: "%.1f°", a)) }
                if let c = scene.centroid { row("Centre", String(format: "%.4f, %.4f", c.lat, c.lon)) }
            }

            Section {
                Label {
                    Text(scene.family.explanation).font(.subheadline)
                } icon: {
                    Image(systemName: scene.family.symbol).foregroundStyle(scene.family.color)
                }
            } header: {
                Text("About \(scene.family.title) mode")
            }

            if !scene.footprintCoordinates.isEmpty {
                Section("Footprint") {
                    Map(initialPosition: .automatic, interactionModes: [.zoom, .pan]) {
                        MapPolygon(coordinates: scene.footprintCoordinates)
                            .foregroundStyle(scene.family.color.opacity(0.3))
                            .stroke(scene.family.color, lineWidth: 2)
                    }
                    .mapStyle(.hybrid)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section {
                if let stac = scene.stac { Link("Open STAC metadata", destination: stac) }
                if let q = scene.quicklook { Link("Download quicklook GeoTIFF", destination: q) }
                if let stac = scene.stac {
                    ShareLink(item: stac, subject: Text("ICEYE SAR scene \(scene.id)")) {
                        Label("Share scene", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("\(scene.id)\n\(store.attribution)").font(.caption2).textSelection(.enabled)
            }
        }
        .navigationTitle(scene.modeName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scene.id) {
            scene = await store.enrich(scene)
            if let v = scene.video, player == nil {
                let p = AVPlayer(url: v)
                p.isMuted = true
                player = p
            }
        }
        .onDisappear { player?.pause() }
        .fullScreenCover(isPresented: $showFullImage) {
            ZoomableImage(url: scene.thumbnail) { showFullImage = false }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }
}

struct ZoomableImage: View {
    let url: URL?
    let dismiss: () -> Void
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: { ProgressView().tint(.white) }
                .scaleEffect(scale * pinch)
                .gesture(MagnifyGesture()
                    .updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in scale = min(max(scale * v.magnification, 1), 6) })
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 3 } }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.title3.bold()).padding(12)
            }
            .buttonStyle(.glass)
            .padding()
            .accessibilityLabel("Close")
        }
    }
}
