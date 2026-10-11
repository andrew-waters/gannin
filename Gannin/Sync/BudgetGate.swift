import Foundation

/// The check every fetcher makes before spending API budget on its own, in
/// one place. Fetching by hand (`force`) never waits, and with nothing yet
/// cached (`hasData` false) there's nothing to show meanwhile, so it doesn't
/// wait either.
extension AuthStore {
    /// Whether an automatic fetch should wait for the budget: under the
    /// reserve, or GitHub refused a request. With `rest`, the REST budget
    /// counts too (only the Actions sync spends it). Distinct from
    /// `SessionStore.holdsOff` and `EngineerWatch.holdsOff`, the pollers'
    /// own closures onto `shouldHoldOff`, which take no `force` or `hasData`.
    func shouldWaitForBudget(force: Bool = false, hasData: Bool = true, rest: Bool = false) -> Bool {
        guard !force, hasData else { return false }
        return shouldHoldOff || (rest && shouldHoldOffREST)
    }

    /// Whether `source`'s data, fetched at `date`, should be fetched now:
    /// asked for by hand, or due and the budget allows. `force` is already
    /// handled here, so it's never passed on; there's no way to ask for the
    /// REST budget, so a REST source still has to call `shouldWaitForBudget`
    /// itself with `rest: true`, as `ActionsStore` does.
    func shouldFetch(_ source: SyncSource, since date: Date?, now: Date = .now, force: Bool = false, hasData: Bool = true) -> Bool {
        force || (SyncSettings.isDue(source, since: date, now: now) && !shouldWaitForBudget(hasData: hasData))
    }
}
