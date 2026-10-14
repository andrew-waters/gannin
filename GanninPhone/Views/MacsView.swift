import SwiftUI

/// The Macs this phone can control, and whether each is on the network now.
struct MacsView: View {
    @Environment(PairedMacs.self) private var macs
    @Environment(MacBrowser.self) private var browser
    @State private var adding = false
    @State private var path = NavigationPath()
    @State private var client: RemoteClient?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let problem = browser.problem {
                    Section {
                        Text(problem)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
                if macs.macs.isEmpty {
                    ContentUnavailableView("No Macs paired", systemImage: "desktopcomputer", description: Text("On your Mac, open Settings › Remote and choose Pair a Phone, then add it here."))
                }
                ForEach(macs.macs) { mac in
                    NavigationLink(value: mac) {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading) {
                                Text(mac.name).font(.headline)
                                Text(browser.endpoint(for: mac.name) == nil ? "Not on this network" : "On this network")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { macs.remove(macs.macs[index]) }
                }
            }
            .navigationTitle("Macs")
            .navigationDestination(for: PairedMac.self) { mac in
                SessionsView(mac: mac) { client = $0 }
            }
            .toolbar {
                Button("Add a Mac", systemImage: "plus") { adding = true }
            }
            .sheet(isPresented: $adding) { AddMacView() }
            .onAppear { browser.start() }
        }
        .onChange(of: path.count) { _, count in
            if count == 0 {
                client?.stop()
                client = nil
            }
        }
        .onDisappear {
            client?.stop()
            client = nil
        }
    }
}
