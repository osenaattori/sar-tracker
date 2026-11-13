import MapKit
import SwiftUI

struct MapScreen: View {
    @Environment(FeedStore.self) private var store
    @State private var selected: SARScene?
    @State private var families = Set(ModeFamily.allCases)
    @State private var camera: MapCameraPosition = .automatic

    private var visible: [SARScene] {
        store.scenes.filter { $0.centroid != nil && families.contains($0.family) }
    }

    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                ForEach(visible) { scene in
                    Annotation(scene.satellite, coordinate: scene.centroid!.coordinate, anchor: .center) {
                        Button { selected = scene } label: {
                            SceneDot(family: scene.family, isNew: store.newSceneIDs.contains(scene.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(scene.modeName) scene from \(scene.satellite)")
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.imagery(elevation: .realistic))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .bottom) {
                FamilyFilterBar(selection: $families, counts: counts)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            .navigationTitle("SAR Scenes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading { ProgressView() } else {
                        Text("\(visible.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(item: $selected) { scene in
                NavigationStack { SceneDetailView(scene: scene) }
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var counts: [ModeFamily: Int] {
        Dictionary(grouping: store.scenes, by: \.family).mapValues(\.count)
    }
}

struct SceneDot: View {
    let family: ModeFamily
    var isNew = false

    var body: some View {
        ZStack {
            if isNew {
                Circle().stroke(.white, lineWidth: 2).frame(width: 22, height: 22)
            }
            Circle()
                .fill(family.color.gradient)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
        }
        .frame(width: 30, height: 30) // comfortable tap target
        .contentShape(Circle())
    }
}

struct FamilyFilterBar: View {
    @Binding var selection: Set<ModeFamily>
    let counts: [ModeFamily: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ModeFamily.allCases.filter { (counts[$0] ?? 0) > 0 }) { f in
                    let on = selection.contains(f)
                    Button {
                        if on { selection.remove(f) } else { selection.insert(f) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(f.color).frame(width: 8, height: 8)
                            Text(f.title)
                            Text("\(counts[f] ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .opacity(on ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
        }
    }
}
