---
type: plan
status: done
summary: "Measure with _printChanges() whether BoardTableView rows re-run when only another row changed (andrew-waters/gannin#396), and only if they do, give each row, cell and header its own comparable view."
issues: [andrew-waters/gannin#396]
touches: [andrew-waters/gannin]
owner: dwrss
---

# Stop board table rows re-evaluating when only another row changed

## Approach

The issue gates the fix on a measurement, so the measurement comes first.

1. [x] Measure (done on the Ctrl Hub board; result on #396: unchanged rows re-ran). Add `let _ = Self._printChanges()` to the row drawn by `BoardTableView.rowView` (`Gannin/Projects/BoardLayouts.swift`) and run it on the 3,057-item Ctrl Hub board. Sort, collapse a group and let a sync stream items in. Record what re-runs on andrew-waters/gannin#396. This needs the signed app, the keychain token and someone driving the UI, so an unattended scheduled run can't do it.
2. [x] Only if unchanged rows re-run: add a row view that takes the `BoardItem`, the striping flag, the visible field names and the `Board`, and draws each cell with one concrete view instead of `StatsColumn.cell`'s `AnyView`. `BoardTableView` keeps each column's sort key, width and title. Group and column headers become views of their own.
3. [x] Move any pure logic out of the views and cover it with Swift Testing tests in `GanninTests`.
4. [x] Check layout, sorting, grouping, collapsing and opening an item behave as before (exercised by hand on the Ctrl Hub board; row evaluations went from 774 to 87, recorded on #396). `StatsTable` and its pages stay unchanged.

## Decisions

- No code change is made without the measurement from step 1: the issue says the fix is conditional, and the cost on a large board is unmeasured.
- Docs: none expected, since what the page shows doesn't change.
