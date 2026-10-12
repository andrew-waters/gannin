import SwiftUI
import WebKit

/// Beside the page: what the room has noted so far.
struct RefineFindingsPanel: View {
    let session: CodeSession
    let page: WebPage

    var body: some View {
        ContentUnavailableView("No findings yet", systemImage: "text.badge.plus",
                               description: Text("Step through the page together; what the room notes goes here."))
    }
}
