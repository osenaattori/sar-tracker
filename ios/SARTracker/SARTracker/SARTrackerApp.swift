import SwiftUI

@main
struct SARTrackerApp: App {
    @State private var store = FeedStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}

struct RootView: View {
    @Environment(FeedStore.self) private var store
    @AppStorage("feedURL") private var feedURL = AppConfig.defaultFeedURL
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView {
            Tab("Map", systemImage: "globe.europe.africa") { MapScreen() }
            Tab("Latest", systemImage: "list.bullet.rectangle") { SceneListScreen() }
                .badge(store.newSceneIDs.count)
            Tab("Status", systemImage: "waveform.path.ecg") { StatusScreen() }
            Tab("About", systemImage: "info.circle") { AboutScreen() }
        }
        .task(id: feedURL) { await store.load(feedURLString: feedURL) }
        .onChange(of: phase) { _, new in
            if new == .active { Task { await store.load(feedURLString: feedURL) } }
        }
    }
}

enum AppConfig {
    /// Baked in at build time (SAR_DEFAULT_FEED_URL, see install-on-device.sh):
    /// your Mac's local server, or the CloudFront `feed_url` from Terraform.
    /// Empty = read ICEYE's catalog directly. Users can change it in About.
    static let defaultFeedURL: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "SARDefaultFeedURL") as? String ?? ""
        return v.hasPrefix("http") ? v : ""
    }()
}
