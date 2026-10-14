import AppKit

/// The screenshots `scripts/capture-screenshots.sh` takes, each saved as
/// `site/assets/screens/<rawValue>-dark.png` and `<rawValue>-light.png`.
/// Adding a screen is a case here (and fixture data if it needs some): the
/// script asks the app for this list and the app poses each one itself.
enum DemoShot: String, CaseIterable {
    case workload
    case pullRequest = "pull-request"
    case delivery
    case session

    /// Where the shot is: a main window on a sidebar item, with a drawer
    /// over it if any, or a session's tab in the Claude Code window.
    enum Pose {
        case main(SidebarItem, drawer: DetailSelection? = nil)
        case session(UUID)
    }

    var pose: Pose {
        switch self {
        case .workload: .main(.tab(.dashboard))
        case .pullRequest: .main(.tab(.dashboard), drawer: .pullRequest(DemoFixture.featured.id))
        case .delivery: .main(.tab(.delivery))
        case .session: .session(DemoSessions.workingID)
        }
    }

    /// The window's content size, in points.
    var size: CGSize {
        switch self {
        case .session: CGSize(width: 1360, height: 860)
        default: CGSize(width: 1440, height: 900)
        }
    }
}
