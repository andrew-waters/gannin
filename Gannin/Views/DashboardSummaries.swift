import SwiftUI

/// A dashboard section's title with a link to the section's own page.
struct SummaryHeader: View {
    @Environment(\.showSidebarItem) private var showSidebarItem
    let title: String
    let link: String
    let item: SidebarItem

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            if let showSidebarItem {
                Button("Open \(link)") { showSidebarItem(item) }
                    .linkButton()
                    .font(.body)
            }
        }
    }
}
