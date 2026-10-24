import Foundation
import Testing
@testable import Gannin

/// Decision records in the harness: `decisions/`, front matter type
/// `decision`, with a status and what superseded them.
struct HarnessDecisionsTests {
    static func decision(_ path: String, status: String, supersededBy: String? = nil, plans: [String] = [], key: Bool = false) -> HarnessDocument {
        var front = ["---", "type: decision", "status: \(status)", "summary: >", "  Sessions run in the harness root."]
        if let supersededBy { front.append("superseded_by: \(supersededBy)") }
        if !plans.isEmpty { front.append("plans: [\(plans.joined(separator: ", "))]") }
        if key { front.append("key: true") }
        front += ["domains: [sessions]", "---", "", "# Run sessions in the harness", "", "## Context", "", "Why."]
        return HarnessDocument(path: path, sha: "abc", kind: HarnessKind(path: path) ?? .plans, text: front.joined(separator: "\n"))
    }

    static func index(_ documents: [HarnessDocument]) -> HarnessIndex {
        HarnessIndex(parserVersion: HarnessDocument.parserVersion, repo: "acme/harness", requestedBranch: nil, branch: "main", commit: "c1", fetchedAt: .now, documents: documents, dataFiles: [])
    }

    @Test func decisionsFolderIndexesAsDecisions() {
        #expect(HarnessKind(path: "decisions/2026-10-12-harness-root.md") == .decisions)
        #expect(HarnessKind(path: "decisions/README.md") == nil)
        #expect(HarnessKind(path: "decisions/_template.md") == nil)
        #expect(HarnessKind(type: "decision") == .decisions)
        #expect(!HarnessKind.decisions.isRecord)
    }

    @Test func frontMatterTypeMakesADecisionAnywhere() {
        let text = "---\ntype: decision\nstatus: accepted\nsummary: x\n---\n\n# X\n"
        let document = HarnessDocument(path: "requirements/sessions/x.md", sha: "abc", kind: .requirements, text: text)
        #expect(document.kind == .decisions)
    }

    @Test func readsStatusSupersessionAndKey() {
        let old = Self.decision("decisions/2026-01-01-old.md", status: "superseded", supersededBy: "decisions/2026-10-12-new.md", plans: ["plans/2025-12-01-x.md"], key: true)
        #expect(old.followsStandard)
        #expect(old.statusLabel == "Superseded")
        #expect(old.supersededBy == "decisions/2026-10-12-new.md")
        #expect(old.citedPlans == ["plans/2025-12-01-x.md"])
        #expect(old.isKey)
        #expect(old.isRetiredDecision)
        #expect(!Self.decision("decisions/a.md", status: "accepted").isRetiredDecision)
        #expect(!Self.decision("decisions/a.md", status: "accepted").isKey)
    }

    @Test func supersededByLinksToItsSuccessor() {
        let new = Self.decision("decisions/2026-10-12-new.md", status: "accepted")
        let old = Self.decision("decisions/2026-01-01-old.md", status: "superseded", supersededBy: "./2026-10-12-new.md")
        let index = Self.index([new, old])
        #expect(index.resolve(old.supersededBy ?? "", from: old) == new.path)
        #expect(index.supersedes(new).map(\.path) == [old.path])
        #expect(index.supersedes(old).isEmpty)
    }

    @Test func pathsResolveWithinTheirOwnHarness() {
        let other = Self.decision("decisions/a.md", status: "accepted").prefixed("acme/other")
        let index = Self.index([other])
        #expect(index.resolve("decisions/b.md", from: other) == "acme/other:decisions/b.md")
        #expect(index.resolve("/plans/c.md", from: other) == "acme/other:plans/c.md")
        #expect(index.resolve("../plans/c.md", from: other) == "acme/other:plans/c.md")
        #expect(index.resolve("../plans/my plan.md", from: other) == "acme/other:plans/my plan.md")
    }

    @Test func newDecisionWritesItsFrontMatter() {
        var draft = HarnessDocumentDraft(kind: .decisions)
        draft.title = "Run sessions in the harness"
        draft.status = "superseded"
        draft.summary = "Sessions start in the harness root."
        draft.supersededBy = "decisions/2026-10-12-new.md"
        draft.plans = ["plans/2026-10-01-x.md"]
        draft.isKey = true
        draft.body = HarnessDocumentDraft.decisionTemplate
        let document = HarnessDocument(path: "decisions/2026-10-12-run.md", sha: "abc", kind: .decisions, text: draft.fileText)
        #expect(document.kind == .decisions)
        #expect(document.followsStandard)
        #expect(document.supersededBy == "decisions/2026-10-12-new.md")
        #expect(document.citedPlans == ["plans/2026-10-01-x.md"])
        #expect(document.isKey)
        #expect(document.body.contains("## Alternatives considered"))
        #expect(HarnessDocumentDraft.statuses(.decisions) == ["proposed", "accepted", "rejected", "superseded"])
    }

    @Test func editDetailsSetsAndClearsSupersededBy() {
        let accepted = "---\ntype: decision\nstatus: accepted\nsummary: x\n---\n\n# X\n"
        let superseded = HarnessFrontMatter.setting([("status", .text("superseded")), ("superseded_by", .text("decisions/2026-10-12-new.md"))], in: accepted)
        let document = HarnessDocument(path: "decisions/x.md", sha: "abc", kind: .decisions, text: superseded)
        #expect(document.supersededBy == "decisions/2026-10-12-new.md")
        let back = HarnessFrontMatter.setting([("status", .text("accepted")), ("superseded_by", nil)], in: superseded)
        #expect(HarnessDocument(path: "decisions/x.md", sha: "abc", kind: .decisions, text: back).supersededBy == nil)
        #expect(!back.contains("superseded_by"))
    }

    @Test func supersededByIsOnlyWrittenWhenSuperseded() {
        var draft = HarnessDocumentDraft(kind: .decisions)
        draft.title = "X"
        draft.status = "accepted"
        draft.supersededBy = "decisions/y.md"
        #expect(!draft.fileText.contains("superseded_by"))
    }

    @Test func newHarnessesHaveTheFolder() {
        let files = HarnessSkeleton.files(org: "acme", repo: "acme/harness", projects: ["acme/app"])
        #expect(files["decisions/README.md"] != nil)
        let template = files["decisions/_template.md"].flatMap { $0 } ?? ""
        #expect(template.contains("type: decision"))
        #expect(HarnessDocumentDraft.templateBody(template)?.contains("## Alternatives considered") == true)
        #expect(HarnessTour.layout.contains { $0.name == "decisions/" })
        #expect((files["STANDARDS.md"].flatMap { $0 } ?? "").contains("superseded_by"))
    }

    @Test func suggestionsSkipCitedPlansAndGoInBatches() {
        func plan(_ name: String, domains: String) -> HarnessDocument {
            HarnessDocument(path: "plans/\(name).md", sha: "abc", kind: .plans, text: "---\ntype: plan\nstatus: done\nsummary: x\ndomains: [\(domains)]\n---\n\n# \(name)\n")
        }
        let plans = (1...7).map { plan("2026-10-0\($0)-p\($0)", domains: $0 == 7 ? "harness" : "sessions") }
        let cited = Self.decision("decisions/a.md", status: "accepted", plans: [plans[0].path])
        let index = Self.index(plans + [cited])
        #expect(DecisionSuggestions.areas(index) == ["harness", "sessions"])
        let sessions = DecisionSuggestions.uncitedPlans(index, area: "sessions")
        #expect(sessions.count == 5)
        #expect(!sessions.contains { $0.path == plans[0].path })
        #expect(sessions.first?.path == plans[5].path)
        #expect(DecisionSuggestions.uncitedPlans(index, area: nil).count == 6)
        #expect(DecisionSuggestions.batches(DecisionSuggestions.uncitedPlans(index, area: nil)).map(\.count) == [5, 1])
    }

    @Test func suggestionsCommitAsProposedDecisionsWithUnusedNames() throws {
        let plan = HarnessDocument(path: "plans/2026-10-01-p.md", sha: "abc", kind: .plans, text: "---\ntype: plan\nsummary: x\ndomains: [sessions]\n---\n\n# P\n")
        let existing = Self.decision("decisions/2026-10-12-use-the-harness.md", status: "accepted")
        let json = #"{"decisions": [{"title": "Use the harness", "summary": "S", "plan": "plans/2026-10-01-p.md", "context": "C", "decision": "D", "alternatives": "- A", "consequences": "Q"}, {"title": "Use the harness", "plan": "plans/unknown.md"}]}"#
        let reply = try #require(ScriptRunner.json(DecisionSuggestions.Reply.self, in: json))
        var drafts = reply.decisions.map { DecisionSuggestions.Draft($0, batch: [plan]) }
        // A plan it didn't read isn't guessed at: the person picks one, or it cites none.
        #expect(drafts[1].plan == "")
        #expect(drafts[1].choices == [plan.path])
        #expect(drafts[0].domains == "sessions")
        drafts.append(DecisionSuggestions.Draft(reply.decisions[0], batch: [plan]))
        drafts[2].include = false
        let files = DecisionSuggestions.files(for: drafts, index: Self.index([existing]), today: "2026-10-12")
        #expect(Set(files.keys) == ["decisions/2026-10-12-use-the-harness-2.md", "decisions/2026-10-12-use-the-harness-3.md"])
        let text = try #require(files["decisions/2026-10-12-use-the-harness-2.md"] ?? nil)
        let document = HarnessDocument(path: "decisions/x.md", sha: "abc", kind: .decisions, text: text)
        #expect(document.status == "proposed")
        #expect(document.citedPlans == [plan.path])
        #expect(document.body.contains("## Alternatives considered\n\n- A"))
        let uncited = try #require(files["decisions/2026-10-12-use-the-harness-3.md"] ?? nil)
        #expect(HarnessDocument(path: "decisions/y.md", sha: "abc", kind: .decisions, text: uncited).citedPlans.isEmpty)
    }

    @Test func namedPlansMatchByPathOrUniqueFileName() {
        func plan(_ path: String) -> HarnessDocument {
            HarnessDocument(path: path, sha: "abc", kind: .plans, text: "---\ntype: plan\nsummary: x\n---\n\n# P\n")
        }
        let batch = [plan("plans/2026-10-01-a.md"), plan("requirements/x/plans/b.md"), plan("requirements/y/plans/b.md")]
        #expect(DecisionSuggestions.plan(named: "plans/2026-10-01-a.md", in: batch)?.path == "plans/2026-10-01-a.md")
        #expect(DecisionSuggestions.plan(named: "./plans/2026-10-01-a.md", in: batch)?.path == "plans/2026-10-01-a.md")
        #expect(DecisionSuggestions.plan(named: "/plans/2026-10-01-a.md", in: batch)?.path == "plans/2026-10-01-a.md")
        #expect(DecisionSuggestions.plan(named: "2026-10-01-a.md", in: batch)?.path == "plans/2026-10-01-a.md")
        // Two plans share the name, so neither is guessed.
        #expect(DecisionSuggestions.plan(named: "b.md", in: batch) == nil)
        #expect(DecisionSuggestions.plan(named: "plans/other.md", in: batch) == nil)
    }
}
