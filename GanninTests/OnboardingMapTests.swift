import Foundation
import Testing
@testable import Gannin

/// Harness › Onboarding: decisions, requirements and plans by area, in
/// reading order, with retired decisions folded under Older.
struct OnboardingMapTests {
    static func document(_ path: String, type: String, status: String = "draft", domains: [String]? = nil, key: Bool = false, summary: Bool = true) -> HarnessDocument {
        var lines = ["---", "type: \(type)", "status: \(status)"]
        if summary { lines.append("summary: Why it is the way it is.") }
        if let domains { lines.append("domains: [\(domains.joined(separator: ", "))]") }
        if key { lines.append("key: true") }
        lines += ["---", "", "# \(path)", ""]
        return HarnessDocument(path: path, sha: "abc", kind: HarnessKind(path: path) ?? .plans, text: lines.joined(separator: "\n"))
    }

    static func map(_ documents: [HarnessDocument]) -> OnboardingMap {
        OnboardingMap(HarnessDecisionsTests.index(documents))
    }

    @Test func groupsByEveryDomainElseModuleElseOther() {
        let map = Self.map([
            Self.document("plans/2026-10-01-a.md", type: "plan", domains: ["sessions", "harness"]),
            Self.document("requirements/billing/b.md", type: "requirement"),
            Self.document("plans/2026-10-02-c.md", type: "plan"),
        ])
        #expect(map.areas.map(\.name) == ["billing", "harness", "sessions", "Other"])
        #expect(map.areas.first { $0.name == "harness" }?.documents.map(\.path) == ["plans/2026-10-01-a.md"])
        #expect(map.areas.first { $0.name == "sessions" }?.documents.map(\.path) == ["plans/2026-10-01-a.md"])
        #expect(map.areas.last?.documents.map(\.path) == ["plans/2026-10-02-c.md"])
    }

    @Test func leavesOutOtherKindsAndDocumentsWithoutTheStandard() {
        let map = Self.map([
            Self.document("findings/2026-10-01-f.md", type: "finding", domains: ["sessions"]),
            Self.document("skills/s.md", type: "skill", domains: ["sessions"]),
            Self.document("plans/2026-10-01-old.md", type: "plan", domains: ["sessions"], summary: false),
        ])
        #expect(map.areas.isEmpty)
    }

    @Test func readingOrderIsKeyThenDecisionsRequirementsPlansNewestFirst() throws {
        let area = ["sessions"]
        let map = Self.map([
            Self.document("plans/2026-10-05-new-plan.md", type: "plan", status: "done", domains: area),
            Self.document("plans/2026-01-01-old-plan.md", type: "plan", status: "abandoned", domains: area),
            Self.document("requirements/sessions/r.md", type: "requirement", domains: area),
            Self.document("decisions/2026-03-01-d1.md", type: "decision", status: "accepted", domains: area),
            Self.document("decisions/2026-09-01-d2.md", type: "decision", status: "proposed", domains: area),
            Self.document("decisions/2026-02-01-gone.md", type: "decision", status: "superseded", domains: area),
            Self.document("decisions/2026-02-02-no.md", type: "decision", status: "rejected", domains: area),
            Self.document("plans/2025-06-01-key.md", type: "plan", domains: area, key: true),
        ])
        let sessions = try #require(map.areas.first)
        #expect(sessions.documents.map(\.path) == [
            "plans/2025-06-01-key.md",
            "decisions/2026-09-01-d2.md",
            "decisions/2026-03-01-d1.md",
            "requirements/sessions/r.md",
            "plans/2026-10-05-new-plan.md",
            // Plans are never folded, whatever their status.
            "plans/2026-01-01-old-plan.md",
        ])
        #expect(sessions.older.map(\.path) == ["decisions/2026-02-02-no.md", "decisions/2026-02-01-gone.md"])
        #expect(sessions.all.count == 8)
    }

    @Test func searchKeepsMatchingAreasWhole() {
        let map = Self.map([
            Self.document("plans/2026-10-01-a.md", type: "plan", domains: ["sessions"]),
            Self.document("plans/2026-10-02-b.md", type: "plan", domains: ["billing"]),
        ])
        #expect(map.filtered("sess").map(\.name) == ["sessions"])
        #expect(map.filtered("2026-10-02-b").map(\.name) == ["billing"])
        #expect(map.filtered("nothing").isEmpty)
        #expect(map.filtered("").count == 2)
    }

    @Test func suggestDecisionsUsesTheMapsAreas() {
        let plan = Self.document("plans/2026-10-01-a.md", type: "plan", domains: [" sessions", "sessions", "harness"])
        #expect(OnboardingMap.areas(of: plan) == ["sessions", "harness"])
        #expect(DecisionSuggestions.areas(of: plan) == OnboardingMap.areas(of: plan))
        #expect(DecisionSuggestions.areas(HarnessDecisionsTests.index([plan])) == ["harness", "sessions"])
    }

    @Test func readMarksStayOnThisMacAndNoticeChanges() throws {
        let defaults = try #require(UserDefaults(suiteName: "OnboardingMapTests.\(UUID().uuidString)"))
        let marks = HarnessReadMarks(defaults: defaults)
        let plan = Self.document("plans/2026-10-01-a.md", type: "plan", domains: ["sessions"])
        #expect(marks.state(of: plan, primary: "acme/harness") == .unread)
        marks.markRead(plan, primary: "acme/harness")
        #expect(marks.state(of: plan, primary: "acme/harness") == .read)
        // Kept across launches, by the harness's repo and the document's own path.
        #expect(HarnessReadMarks(defaults: defaults).state(of: plan, primary: "acme/harness") == .read)
        #expect(HarnessReadMarks(defaults: defaults).state(of: plan.prefixed("acme/harness"), primary: "acme/other") == .read)
        #expect(marks.state(of: plan, primary: "acme/other") == .unread)

        let changed = HarnessDocument(path: plan.path, sha: "def", kind: .plans, text: plan.text)
        #expect(marks.state(of: changed, primary: "acme/harness") == .updated)
        #expect(marks.readCount([changed, Self.document("plans/2026-10-02-b.md", type: "plan")], primary: "acme/harness") == 1)
        marks.markRead(changed, primary: "acme/harness")
        #expect(marks.state(of: changed, primary: "acme/harness") == .read)
    }
}
