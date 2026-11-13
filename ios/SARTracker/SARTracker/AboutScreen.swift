import SwiftUI

struct AboutScreen: View {
    @Environment(FeedStore.self) private var store
    @AppStorage("feedURL") private var feedURL = AppConfig.defaultFeedURL
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("A personal learning project that tracks new scenes in ICEYE's public SAR (radar satellite) open dataset, using a serverless AWS pipeline built with Terraform.")
                } header: {
                    Text("SAR Tracker")
                } footer: {
                    Text("Not affiliated with or endorsed by ICEYE.")
                }

                Section {
                    TextField("http://192.168.1.10:8080/feed.json", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                    HStack {
                        Button("Save") { feedURL = draft }
                            .disabled(draft == feedURL || !(draft.isEmpty || draft.hasPrefix("https://") || draft.hasPrefix("http://")))
                        Spacer()
                        if !feedURL.isEmpty {
                            Button("Use ICEYE directly", role: .destructive) { feedURL = ""; draft = "" }
                        }
                    }
                } header: {
                    Text("Data source")
                } footer: {
                    Text("Your Mac: http://<mac-ip>:8080/feed.json (same Wi-Fi). AWS: the feed_url from `terraform output`. Empty: read ICEYE's catalog directly.")
                }

                Section("Data & licence") {
                    Text(store.attribution).font(.callout)
                    Link("ICEYE SAR Open Dataset (AWS)", destination: URL(string: "https://registry.opendata.aws/iceye-opendata/")!)
                    Link("CC BY 4.0 licence", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                    Text("Some open samples may be experimental and may not match ICEYE's current product specifications.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Mode colours") {
                    ForEach(ModeFamily.allCases.filter { $0 != .other }) { f in
                        Label {
                            VStack(alignment: .leading) {
                                Text(f.title)
                                Text(f.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: f.symbol).foregroundStyle(f.color)
                        }
                    }
                }
            }
            .navigationTitle("About")
            .onAppear { draft = feedURL }
        }
    }
}
