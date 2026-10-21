---
paths:
  - "Gannin/RDTime/**"
---

# R&D time

- Never store or ask for money (salaries, rates, costs): the feature is time only, and turning hours into a claim value stays with the claimant.
- Never hard-code one country's scheme or its terms; scheme wording goes through `RDConfig.name` and what counts through `RDQualification`.
- Add new strategies as new cases (`RDQualification`, `RDTimeSource`, the activity options' enums) and new optional fields, never by changing what an existing case means: saved `rnd.json` files must keep decoding to the same report.
- A mark set by hand wins over the qualification, and a "doesn't count" mark isn't overridden by the parent; keep that order in `RDConfig.status`, or an adviser's exclusion silently comes back.
- Keep every allocation traceable: it carries its source, its basis (events or an open PR) and the item's URL, and the exports must keep those columns.
- Never fetch R&D activity from Refresh, a sync or opening the page: only `RDActivityStore.fetch` after the user confirms a priced `Plan` on the page. A year is a search per week, too costly to spend unasked.
- Never call `IssueStore.loadCached` or `WorkLogStore.sync` from R&D Time: loading either opts the org into the regular Refresh. Read the issue history only if it's already loaded.
- Keep coverage contiguous: top up first, then backfill newest week first, moving `coveredFrom` and saving after each, so a cancelled or budget-stopped fetch keeps its weeks and the next carries on.
- Count only working days (`RDActivityAllocator.hours`): a claim is of working time, so weekend activity adds no hours and leave removes them.

## Testing
- `RDTimeTests.swift` covers the allocator, qualification, accounting ranges, fetch planning and CSV quoting. The page and settings have no tests; check by hand with a range that covers leave and a bank holiday.
