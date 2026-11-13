import CoreLocation
import SwiftUI

/// feed.json written by the AWS feed-builder Lambda.
struct Feed: Codable {
    var version: Int?
    var generatedAt: String?
    var sceneCount: Int?
    var attribution: String?
    var scenes: [SARScene]
}

/// status.json written by the Lambda after every run.
struct PipelineStatus: Codable {
    var lastRunAt: String?
    var lastNewSceneAt: String?
    var lastEvent: String?
    var sceneCount: Int?
    var backfillFailed: Int?
}

struct LatLon: Codable, Hashable {
    var lat: Double
    var lon: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct SARScene: Codable, Identifiable, Hashable {
    var id: String
    var datetime: String?
    var platform: String?
    var mode: String?
    var instrumentMode: String?
    var polarizations: [String]?
    var orbitState: String?
    var incidenceAngle: Double?
    var centroid: LatLon?
    var footprint: [[Double]]?
    var thumbnail: URL?
    var quicklook: URL?
    var video: URL?
    var stac: URL?

    var date: Date? { DateParsing.parse(datetime) }

    var family: ModeFamily { ModeFamily(mode: mode ?? instrumentMode) }

    /// "dwell-fine" -> "Dwell Fine"
    var modeName: String {
        (mode ?? instrumentMode ?? "unknown")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    var satellite: String { platform ?? "ICEYE" }

    var footprintCoordinates: [CLLocationCoordinate2D] {
        (footprint ?? []).compactMap { p in
            p.count >= 2 ? CLLocationCoordinate2D(latitude: p[1], longitude: p[0]) : nil
        }
    }
}

/// Acquisition modes grouped into families for colours and filters.
enum ModeFamily: String, CaseIterable, Identifiable {
    case spot, strip, scan, dwell, stack, other

    var id: String { rawValue }

    init(mode: String?) {
        let m = (mode ?? "").lowercased()
        if m.hasPrefix("dwell") { self = .dwell }
        else if m.hasPrefix("spot") { self = .spot }
        else if m.hasPrefix("strip") { self = .strip }
        else if m.hasPrefix("scan") { self = .scan }
        else if m.hasPrefix("stack") { self = .stack }
        else { self = .other }
    }

    var title: String {
        switch self {
        case .spot: "Spotlight"
        case .strip: "Strip"
        case .scan: "Scan"
        case .dwell: "Dwell"
        case .stack: "Stacks"
        case .other: "Other"
        }
    }

    var color: Color {
        switch self {
        case .spot: .orange
        case .strip: .teal
        case .scan: .indigo
        case .dwell: .pink
        case .stack: .green
        case .other: .gray
        }
    }

    var symbol: String {
        switch self {
        case .spot: "scope"
        case .strip: "road.lanes"
        case .scan: "square.grid.3x3"
        case .dwell: "video"
        case .stack: "square.stack.3d.up"
        case .other: "circle"
        }
    }

    var explanation: String {
        switch self {
        case .spot: "The satellite steers its beam to stare at one spot, giving the sharpest detail over a small area."
        case .strip: "A continuous strip along the satellite's path. Good balance of detail and coverage."
        case .scan: "Wide-area imaging, great for floods, ice and ships over large regions."
        case .dwell: "Very long look at one place. Enables SAR \"video\" that shows movement."
        case .stack: "Repeated images of the same place over time, used to detect change."
        case .other: "Other acquisition mode."
        }
    }
}

enum DateParsing {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}
