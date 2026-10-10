import Foundation
import Testing
@testable import Gannin

/// Writing Settings' prompts with Claude (andrew-waters/gannin#145): what
/// Claude is asked, and reading what it says back.
struct PromptWritingTests {
    @Test func firstPromptStartsFromWhatsThere() {
        let prompt = PromptWriting.firstPrompt(.houseRules, ask: "Add attribution", current: "Use British English.\n")
        #expect(prompt.contains("house rules for Claude in sandboxes"))
        #expect(prompt.contains("What's there now, to improve on rather than start over:\n\nUse British English."))
        #expect(prompt.contains("What I want:\n\nAdd attribution"))
        #expect(prompt.hasSuffix(#"{"message": "what you say to me", "draft": "the whole text, only when you've written or changed it"}."#))
        #expect(!prompt.contains("Gannin's default, for reference"))
    }

    @Test func firstPromptWithNothingWritten() {
        let prompt = PromptWriting.firstPrompt(.houseRules, ask: "Help", current: "  \n")
        #expect(prompt.contains("Nothing's written yet."))
        #expect(!prompt.contains("What's there now"))
    }

    @Test func savedPromptsAskForAName() {
        let prompt = PromptWriting.firstPrompt(.savedPrompt, ask: "Fix the checks", current: "", title: "Checks")
        #expect(prompt.contains("Its name now: Checks"))
        #expect(prompt.contains(#""title": "a short name"#))
    }

    @Test func authoringShowsTheDefaultOnlyWhenItDiffers() {
        let custom = PromptWriting.firstPrompt(.authoring(.skills), ask: "Shorter", current: "Write skills briefly.")
        #expect(custom.contains("Gannin's default, for reference:\n\n\(HarnessAuthoring.defaultGuidance(.skills))"))
        #expect(custom.contains("{{org}}, {{harness}}, {{today}}"))
        let unchanged = PromptWriting.firstPrompt(.authoring(.skills), ask: "Shorter", current: HarnessAuthoring.defaultGuidance(.skills))
        #expect(!unchanged.contains("Gannin's default, for reference"))
        #expect(PromptWriting.Purpose.authoring(.plans).name == "a planning session's first prompt")
    }

    @Test func followUpCarriesTheDraft() {
        let prompt = PromptWriting.followUp("Make it shorter", current: "Rule one.\nRule two.")
        #expect(prompt.hasPrefix("Make it shorter\n\nThe draft as it stands (I may have edited it):\n\nRule one.\nRule two."))
        #expect(prompt.hasSuffix("Reply with only the JSON, as before."))
        #expect(PromptWriting.followUp("Go on", current: "").contains("The draft is empty now."))
    }

    @Test func readsReplies() {
        #expect(PromptWriting.reply(in: #"{"message": "Done", "draft": "Rules"}"#) == .init(message: "Done", draft: "Rules"))
        #expect(PromptWriting.reply(in: "Here:\n```json\n{\"message\": \"Which repo?\"}\n```") == .init(message: "Which repo?"))
        #expect(PromptWriting.reply(in: "Just talking {not json}") == .init(message: "Just talking {not json}"))
        #expect(PromptWriting.reply(in: "{}") == .init(message: "{}"))
    }
}
