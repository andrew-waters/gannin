import SwiftUI

/// Targets for delivery, for the whole org and per team, set in the org's
/// Settings and shown on the Dashboard as on track or not. Every target is
/// optional; a team without its own uses the org's.
struct MetricGoals: Codable, Hashable {
    struct Targets: Codable, Hashable {
        /// Median cycle time, in hours.
        var cycleTimeHours: Double?
        /// Median time to first review, in hours.
        var firstReviewHours: Double?
        /// Share of PRs with rework, 0 to 1.
        var reworkShare: Double?
        /// Share of PRs merged without review, 0 to 1.
        var unreviewedShare: Double?
        /// Median PR size, in lines changed.
        var prSizeLines: Int?
        /// Share of review requests answered, 0 to 1 (higher is better).
        var answeredShare: Double?

        var isEmpty: Bool {
            cycleTimeHours == nil && firstReviewHours == nil && reworkShare == nil && unreviewedShare == nil
                && prSizeLines == nil && answeredShare == nil
        }
    }

    var org = Targets()
    /// By team slug.
    var teams: [String: Targets] = [:]

    var isEmpty: Bool { org.isEmpty && teams.values.allSatisfy(\.isEmpty) }

    /// A team's targets, each falling back to the org's.
    func targets(for team: Team?) -> Targets {
        guard let team, let own = teams[team.slug] else { return org }
        return Targets(
            cycleTimeHours: own.cycleTimeHours ?? org.cycleTimeHours,
            firstReviewHours: own.firstReviewHours ?? org.firstReviewHours,
            reworkShare: own.reworkShare ?? org.reworkShare,
            unreviewedShare: own.unreviewedShare ?? org.unreviewedShare,
            prSizeLines: own.prSizeLines ?? org.prSizeLines,
            answeredShare: own.answeredShare ?? org.answeredShare
        )
    }
}

/// One goal against the window's numbers.
struct GoalResult: Identifiable, Hashable {
    let name: String
    let target: String
    let actual: String
    /// Nil when there's nothing to measure yet.
    let onTrack: Bool?
    /// Where it was in the period before, when that's known.
    let previous: String?
    let drill: MetricDrill?

    var id: String { name }
}

extension MetricGoals.Targets {
    func results(for metrics: OrgMetrics) -> [GoalResult] {
        var results: [GoalResult] = []
        func hours(_ value: Double) -> String { (value * 3600).compactDuration }
        func share(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
        if let target = cycleTimeHours {
            let actual = metrics.cycleTime.median
            results.append(.init(
                name: "Cycle time", target: "≤ \(hours(target))", actual: actual?.compactDuration ?? "-",
                onTrack: actual.map { $0 <= target * 3600 }, previous: metrics.previous?.cycleTime.median?.compactDuration, drill: .cycleTime
            ))
        }
        if let target = firstReviewHours {
            let actual = metrics.timeToFirstReview.median
            results.append(.init(
                name: "First review", target: "≤ \(hours(target))", actual: actual?.compactDuration ?? "-",
                onTrack: actual.map { $0 <= target * 3600 }, previous: metrics.previous?.timeToFirstReview.median?.compactDuration, drill: .timeToFirstReview
            ))
        }
        if let target = reworkShare {
            let actual = metrics.stages[.rework]?.share
            results.append(.init(
                name: "PRs with rework", target: "≤ \(share(target))", actual: actual.map(share) ?? "-",
                onTrack: metrics.merged.isEmpty ? nil : actual.map { $0 <= target }, previous: metrics.previous?.reworkShare.map(share), drill: nil
            ))
        }
        if let target = unreviewedShare {
            let actual = metrics.merged.isEmpty ? nil : Double(metrics.mergedWithoutReview.count) / Double(metrics.merged.count)
            results.append(.init(
                name: "Merged without review", target: "≤ \(share(target))", actual: actual.map(share) ?? "-",
                onTrack: actual.map { $0 <= target }, previous: metrics.previous?.unreviewedShare.map(share), drill: .mergedWithoutReview
            ))
        }
        if let target = prSizeLines {
            let actual = metrics.prSize.median
            results.append(.init(
                name: "PR size", target: "≤ \(target) lines", actual: actual.map { "\($0) lines" } ?? "-",
                onTrack: actual.map { $0 <= target }, previous: metrics.previous?.prSizeMedian.map { "\($0) lines" }, drill: nil
            ))
        }
        if let target = answeredShare {
            let actual = metrics.answeredShare
            results.append(.init(
                name: "Review requests answered", target: "≥ \(share(target))", actual: actual.map(share) ?? "-",
                onTrack: actual.map { $0 >= target }, previous: metrics.previous?.answeredShare.map(share), drill: .unansweredRequests
            ))
        }
        return results
    }
}
