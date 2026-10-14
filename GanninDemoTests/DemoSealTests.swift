import Foundation
import Testing
@testable import Gannin_Demo

/// The demo build reaches neither GitHub nor the keychain, starts no
/// claude, git, gh or shell, and keeps its files apart from the real app's.
@MainActor
struct DemoSealTests {

    @Test func graphQLIsSealed() async {
        await #expect(throws: NetworkGate.Sealed.self) { try await GitHubAPI(token: "demo").viewer() }
    }

    @Test func restWritesAreSealed() async {
        await #expect(throws: NetworkGate.Sealed.self) { () async throws -> Void in try await GitHubAPI(token: "demo").restWrite("POST", "user/repos") }
    }

    @Test func requestLimiterSendsNothing() async {
        let sent = Counter()
        let limiter = RequestLimiter(limit: 1) { request in
            await sent.add()
            return (Data(), URLResponse())
        }
        await #expect(throws: NetworkGate.Sealed.self) {
            try await limiter.data(for: URLRequest(url: URL(string: "https://api.github.com/graphql")!))
        }
        #expect(await sent.value == 0)
    }

    @Test func deviceFlowIsSealed() async {
        await #expect(throws: NetworkGate.Sealed.self) { try await DeviceFlow.requestCode() }
    }

    @Test func bankHolidaysFetchNothing() async {
        let store = BankHolidayStore()
        await store.loadCountries()
        #expect(store.countries.isEmpty)
    }

    @Test func keychainReadsAndWritesNothing() {
        Keychain.setValue("x", service: "dev.andon.gannin.demo.tests", account: "probe")
        #expect(Keychain.value(service: "dev.andon.gannin.demo.tests", account: "probe") == nil)
        #expect(Keychain.token() == nil)
    }

    @Test func signedInAsTheFixtureWithNoAPI() {
        let auth = AuthStore()
        #expect(auth.isSignedIn)
        #expect(auth.viewer == DemoFixture.viewer)
        #expect(auth.api == nil)
    }

    @Test func claudeIsNeverAsked() async {
        await #expect(throws: NetworkGate.Sealed.self) { try await ClaudeRunner.ask("hello", org: DemoFixture.org) }
    }

    @Test func claudeScriptsDontRun() {
        let result = ClaudeRunner.run("echo ran", place: .local)
        #expect(result.status == -1)
        #expect(result.output.isEmpty)
        #expect(result.error == NetworkGate.Sealed.process)
    }

    @Test func shellCommandsDontRun() {
        let result = Shell.run("echo ran", .local)
        #expect(!result.ok)
        #expect(result.output.isEmpty)
        #expect(result.error == NetworkGate.Sealed.process)
    }

    @Test func filesAreTheDemosOwn() {
        #expect(AppPaths.support.path.contains("dev.andon.gannin.demo"))
        #expect(UserDatabase.storeURL.path.hasPrefix(AppPaths.support.path))
    }
}

private actor Counter {
    private(set) var value = 0
    func add() { value += 1 }
}
