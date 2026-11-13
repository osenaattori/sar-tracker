import SwiftUI

/// Shows the health of the AWS pipeline - the "DevOps" part of the project.
struct StatusScreen: View {
    @Environment(FeedStore.self) private var store
    @AppStorage("feedURL") private var feedURL = AppConfig.defaultFeedURL

    private enum Health { case ok, warning, down, direct }

    private var health: Health {
        if store.source == .direct { return .direct }
        if store.lastError != nil { return .down }
        guard let last = DateParsing.parse(store.status?.lastRunAt) else { return .warning }
        return Date().timeIntervalSince(last) < 26 * 3600 ? .ok : .warning
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: icon)
                            .font(.largeTitle)
                            .foregroundStyle(color)
                            .symbolEffect(.pulse, isActive: store.isLoading)
                        VStack(alignment: .leading) {
                            Text(headline).font(.headline)
                            Text(subline).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Feed") {
                    LabeledContent("Source", value: store.source.title)
                    LabeledContent("Scenes", value: "\(store.scenes.count)")
                    LabeledContent("New since last visit", value: "\(store.newSceneIDs.count)")
                    if let g = store.feedGeneratedAt { relative("Feed generated", g) }
                    if let l = store.lastLoadedAt { relative("Loaded on phone", l) }
                    if let d = store.loadDuration {
                        LabeledContent("Load time", value: String(format: "%.0f ms", d * 1000))
                    }
                }

                if let s = store.status {
                    Section("Pipeline (status.json)") {
                        if let r = DateParsing.parse(s.lastRunAt) { relative("Last pipeline run", r) }
                        if let n = DateParsing.parse(s.lastNewSceneAt) { relative("Last new scene", n) }
                        if let e = s.lastEvent {
                            LabeledContent("Triggered by", value: [
                                "backfill": "Full re-sync", "poll": "Mac poll", "notification": "ICEYE notification",
                            ][e] ?? e)
                        }
                        if let f = s.backfillFailed {
                            LabeledContent("Items failed in last re-sync", value: "\(f)")
                        }
                    }
                }

                if let e = store.lastError {
                    Section("Last error") { Text(e).font(.callout.monospaced()).foregroundStyle(.red) }
                }

                Section {
                    PipelineDiagram()
                } header: {
                    Text("How it works")
                }
            }
            .navigationTitle("Status")
            .refreshable { await store.load(feedURLString: feedURL) }
        }
    }

    private func relative(_ title: String, _ date: Date) -> some View {
        LabeledContent(title) { Text("\(Text(date, style: .relative)) ago") }
    }

    private var icon: String {
        switch health {
        case .ok: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .down: "xmark.octagon.fill"
        case .direct: "antenna.radiowaves.left.and.right"
        }
    }

    private var color: Color {
        switch health {
        case .ok: .green
        case .warning: .orange
        case .down: .red
        case .direct: .blue
        }
    }

    private var headline: String {
        switch health {
        case .ok: "Pipeline healthy"
        case .warning: "Pipeline stale"
        case .down: "Feed unreachable"
        case .direct: "Direct mode"
        }
    }

    private var subline: String {
        switch health {
        case .ok: "Updated within the last day"
        case .warning: "No pipeline run in over 26 hours"
        case .down: "Feed unreachable. Is the server running? See runbook"
        case .direct: "Reading ICEYE's catalog. Add your feed URL in About."
        }
    }
}

struct PipelineDiagram: View {
    private let steps: [(String, String, String)] = [
        ("satellite", "ICEYE uploads", "New scene lands in ICEYE's public S3 bucket"),
        ("bell.badge", "SNS notification", "ICEYE's topic announces the new file"),
        ("tray.full", "SQS queue + DLQ", "Buffers bursts, retries 3×, keeps failures"),
        ("function", "Lambda", "Reads the STAC item, updates the feed safely"),
        ("externaldrive", "S3 + CloudFront", "Private bucket, HTTPS, cached at the edge"),
        ("iphone", "This app", "Map, list, video and pipeline health"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Image(systemName: step.0)
                            .frame(width: 30, height: 30)
                            .background(.tint.opacity(0.15), in: Circle())
                            .foregroundStyle(.tint)
                        if i < steps.count - 1 {
                            Rectangle().fill(.tint.opacity(0.3)).frame(width: 2, height: 18)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.1).font(.subheadline.weight(.semibold))
                        Text(step.2).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            Text("Plus: daily EventBridge re-sync, CloudWatch alarms, budget alert - all in Terraform.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .padding(.vertical, 4)
    }
}
