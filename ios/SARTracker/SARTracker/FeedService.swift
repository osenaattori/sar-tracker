import Foundation
import Observation

/// Loads scenes either from your AWS pipeline (feed.json via CloudFront)
/// or - when no feed URL is set - straight from ICEYE's public STAC catalog.
@Observable
final class FeedStore {
    enum Source: Equatable {
        case pipeline(URL)
        case direct

        var title: String {
            switch self {
            case .direct: "ICEYE STAC (direct)"
            case .pipeline(let url): url.scheme == "http" ? "Mac local server" : "AWS pipeline"
            }
        }
    }

    static let iceyeBase = URL(string: "https://iceye-open-data-catalog.s3.amazonaws.com")!
    static let footprintSummary = iceyeBase
        .appending(path: "stac-items/summary/footprint-summary-points.geojson")
    static let defaultAttribution =
        "Contains ICEYE SAR Open Data (CC BY 4.0), accessed via registry.opendata.aws/iceye-opendata"

    private(set) var scenes: [SARScene] = []
    private(set) var status: PipelineStatus?
    private(set) var feedGeneratedAt: Date?
    private(set) var attribution = FeedStore.defaultAttribution
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastLoadedAt: Date?
    private(set) var loadDuration: TimeInterval?
    private(set) var source: Source = .direct

    /// Scene IDs that appeared since the user last opened the app.
    private(set) var newSceneIDs: Set<String> = []

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadRevalidatingCacheData
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    private let seenKey = "seenSceneIDs"

    func load(feedURLString: String) async {
        let trimmed = feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        // https = AWS/CloudFront; http is only allowed by iOS for local-network hosts (your Mac).
        source = URL(string: trimmed).flatMap { ["https", "http"].contains($0.scheme) ? Source.pipeline($0) : nil } ?? .direct

        isLoading = true
        lastError = nil
        let started = Date()
        defer {
            isLoading = false
            loadDuration = Date().timeIntervalSince(started)
        }

        do {
            switch source {
            case .pipeline(let url):
                let feed: Feed = try await fetch(url)
                apply(feed.scenes)
                attribution = feed.attribution ?? FeedStore.defaultAttribution
                feedGeneratedAt = DateParsing.parse(feed.generatedAt)
                let statusURL = url.deletingLastPathComponent().appending(path: "status.json")
                status = try? await fetch(statusURL) as PipelineStatus
            case .direct:
                let fc: FeatureCollection = try await fetch(FeedStore.footprintSummary)
                apply(fc.features.compactMap(\.scene))
                attribution = FeedStore.defaultAttribution
                feedGeneratedAt = nil
                status = nil
            }
            lastLoadedAt = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fills in details (video, polarisation...) from the scene's STAC item.
    /// Direct mode only has the summary, so the detail screen calls this.
    func enrich(_ scene: SARScene) async -> SARScene {
        guard let stac = scene.stac, scene.instrumentMode == nil else { return scene }
        guard let (data, _) = try? await session.data(from: stac),
              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return scene }

        var s = scene
        let props = item["properties"] as? [String: Any] ?? [:]
        let assets = item["assets"] as? [String: [String: Any]] ?? [:]
        func href(_ k: String) -> URL? { (assets[k]?["href"] as? String).flatMap(URL.init(string:)) }

        s.instrumentMode = props["sar:instrument_mode"] as? String
        s.polarizations = props["sar:polarizations"] as? [String]
        s.orbitState = props["sat:orbit_state"] as? String
        s.incidenceAngle = props["view:incidence_angle"] as? Double
        s.video = href("vid-mp4")
        s.quicklook = href("qlk-cog")
        s.thumbnail = s.thumbnail ?? href("graphic")
        if let i = scenes.firstIndex(where: { $0.id == s.id }) { scenes[i] = s }
        return s
    }

    func markAllSeen() {
        UserDefaults.standard.set(scenes.map(\.id), forKey: seenKey)
        newSceneIDs = []
    }

    // MARK: - Private

    private func apply(_ incoming: [SARScene]) {
        scenes = incoming.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let seen = UserDefaults.standard.stringArray(forKey: seenKey)
        if let seen {
            newSceneIDs = Set(scenes.map(\.id)).subtracting(seen)
        } else {
            // First launch: nothing is "new" yet.
            UserDefaults.standard.set(scenes.map(\.id), forKey: seenKey)
            newSceneIDs = []
        }
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from \(url.host() ?? "server")",
            ])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - ICEYE footprint summary (GeoJSON)

private struct FeatureCollection: Decodable {
    struct Feature: Decodable {
        struct Geometry: Decodable {
            var type: String
            var coordinates: [[[Double]]]?
        }

        struct Properties: Decodable {
            var id: String?
            var datetime: String?
            var platform: String?
            var href: URL?
            var thumbnail: URL?
        }

        var geometry: Geometry?
        var properties: Properties

        var scene: SARScene? {
            guard let id = properties.id else { return nil }
            let ring = geometry?.type == "Polygon" ? geometry?.coordinates?.first ?? [] : []
            let pts = ring.count > 1 && ring.first == ring.last ? Array(ring.dropLast()) : ring
            let centroid: LatLon? = pts.isEmpty ? nil : LatLon(
                lat: pts.map { $0[1] }.reduce(0, +) / Double(pts.count),
                lon: pts.map { $0[0] }.reduce(0, +) / Double(pts.count)
            )
            return SARScene(
                id: id,
                datetime: properties.datetime,
                platform: properties.platform,
                mode: Self.mode(from: properties.thumbnail),
                centroid: centroid,
                footprint: ring,
                thumbnail: properties.thumbnail,
                stac: properties.href
            )
        }

        /// .../data/<mode>/<scene>/... -> <mode>
        static func mode(from url: URL?) -> String? {
            guard let parts = url?.pathComponents, let i = parts.firstIndex(of: "data"),
                  i + 1 < parts.count else { return nil }
            return parts[i + 1]
        }
    }

    var features: [Feature]
}
