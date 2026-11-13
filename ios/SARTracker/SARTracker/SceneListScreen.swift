import SwiftUI

struct SceneListScreen: View {
    @Environment(FeedStore.self) private var store
    @AppStorage("feedURL") private var feedURL = AppConfig.defaultFeedURL
    @State private var query = ""
    @State private var family: ModeFamily?

    private var filtered: [SARScene] {
        store.scenes.filter { s in
            (family == nil || s.family == family)
                && (query.isEmpty
                    || s.id.localizedCaseInsensitiveContains(query)
                    || s.satellite.localizedCaseInsensitiveContains(query)
                    || s.modeName.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = store.lastError, store.scenes.isEmpty {
                    ContentUnavailableView("Couldn't load scenes", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                }
                ForEach(filtered) { scene in
                    NavigationLink(value: scene) {
                        SceneRow(scene: scene, isNew: store.newSceneIDs.contains(scene.id))
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if store.scenes.isEmpty && store.isLoading {
                    ProgressView("Loading SAR scenes…")
                }
            }
            .navigationTitle("Latest")
            .navigationDestination(for: SARScene.self) { SceneDetailView(scene: $0) }
            .searchable(text: $query, prompt: "Satellite, mode or scene ID")
            .refreshable { await store.load(feedURLString: feedURL) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Mode", selection: $family) {
                            Text("All modes").tag(ModeFamily?.none)
                            ForEach(ModeFamily.allCases) { Label($0.title, systemImage: $0.symbol).tag(Optional($0)) }
                        }
                    } label: {
                        Label("Filter", systemImage: family == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                if !store.newSceneIDs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Mark seen") { store.markAllSeen() }
                    }
                }
            }
        }
    }
}

struct SceneRow: View {
    let scene: SARScene
    var isNew = false

    var body: some View {
        HStack(spacing: 12) {
            SARThumbnail(url: scene.thumbnail)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(scene.modeName).font(.headline)
                    if isNew {
                        Text("NEW")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Text(scene.satellite).font(.subheadline).foregroundStyle(.secondary)
                if let d = scene.date {
                    Text(d, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: scene.family.symbol)
                .foregroundStyle(scene.family.color)
        }
        .padding(.vertical, 2)
    }
}

struct SARThumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                placeholder(icon: "photo.badge.exclamationmark")
            default:
                placeholder(icon: nil)
            }
        }
        .background(Color(white: 0.12))
    }

    @ViewBuilder private func placeholder(icon: String?) -> some View {
        ZStack {
            Color(white: 0.12)
            if let icon { Image(systemName: icon).foregroundStyle(.secondary) } else { ProgressView() }
        }
    }
}
