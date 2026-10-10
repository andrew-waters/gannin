// Fails when a control in the Settings views isn't named on its Settings
// reference page, naming the label and the page, so a pull request that adds,
// renames or removes a setting updates the docs with it.
//
// Each pane maps its Swift files (or the structs within a shared file) to the
// pages that may name its controls. Every literal label of a Toggle, Picker,
// Stepper, TextField, SecureField, LabeledContent, Button or Menu there, and
// every Sync row's title, must appear on one of them. Labels built at run
// time (interpolated, or from enums other than SyncSource's) can't be seen,
// and are accepted as a gap. Run from docs-site/: node scripts/check-settings.mjs

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const repo = new URL('../..', import.meta.url).pathname;
const pages = join(repo, 'docs-site/src/content/docs/settings');

// [Swift file, structs within it (none for the whole file), pages]
const panes = [
  ['Gannin/Views/SettingsView.swift', ['GeneralSettings'], ['app/general']],
  ['Gannin/Sessions/SessionViews.swift', ['SessionSettingsSection'], ['app/general']],
  ['Gannin/Sessions/SessionRules.swift', ['SessionRulesSection'], ['app/general']],
  ['Gannin/Sessions/SessionOverview.swift', ['SessionPromptSettingsSection'], ['app/general']],
  ['Gannin/Views/SyncSettingsView.swift', null, ['app/sync']],
  ['Gannin/Sandbox/SandboxSettings.swift', ['SandboxSettingsSection', 'RemoteMachinesSection'], ['app/sandbox']],
  ['Gannin/Views/StorageSettings.swift', null, ['app/storage']],
  ['Gannin/Views/OrgSettingsView.swift', null, ['org/repositories', 'org/people', 'org/hidden']],
  ['Gannin/Workload/RepoProjects.swift', ['ProjectsSettingsSection'], ['org/projects']],
  ['Gannin/WorkLog/WorkWeek.swift', ['WorkWeekSection'], ['org/working-time']],
  ['Gannin/WorkLog/Leave.swift', ['LeavePolicySection'], ['org/working-time']],
  ['Gannin/WorkLog/PeopleDates.swift', ['PeopleDatesSection'], ['org/working-time']],
  ['Gannin/Issues/IssueWorkflowSettings.swift', null, ['org/issues']],
  ['Gannin/Investments/InvestmentSettings.swift', null, ['org/investments']],
  ['Gannin/Metrics/DeliveryInsights.swift', ['GoalsSettingsSection'], ['org/goals']],
  ['Gannin/Harness/HarnessViews.swift', ['HarnessSettingsSection', 'FirstHarnessSection'], ['org/harness']],
  ['Gannin/Harness/HarnessTeamViews.swift', null, ['org/harness']],
  ['Gannin/Harness/HarnessPromptViews.swift', null, ['org/harness', 'org/projects']],
  ['Gannin/Harness/HarnessEditors.swift', ['HarnessAuthoringSection'], ['org/harness']],
  ['Gannin/Sessions/SessionViews.swift', ['HarnessCheckoutSection'], ['org/harness']],
  ['Gannin/Sandbox/SandboxSettings.swift', ['SandboxGitHubTokenSection'], ['org/harness', 'app/sandbox']],
];

// Labels that aren't settings, reviewed: generic actions every editor has, a
// person row's context menu (Open on GitHub) and a target field's placeholder
// (none, in Investments).
const ignored = new Set(['Cancel', 'Done', 'Save', 'OK', 'Delete', 'Remove', 'Edit', 'Add', 'Close', 'Open on GitHub', 'none']);

const controls = /\b(?:Toggle|Picker|Stepper|TextField|SecureField|LabeledContent|Button|Menu)\(\s*"((?:[^"\\]|\\.)*)"/g;
const topLevel = /^(?:(?:private|fileprivate|public)\s+)?(?:final\s+)?(?:struct|class|enum|extension)\s/;

/** The source of the named top-level structs, or the whole file. */
function scope(source, structs) {
  if (!structs) return source;
  const lines = source.split('\n');
  const parts = [];
  for (const name of structs) {
    const start = lines.findIndex((l) => new RegExp(`^(?:\\w+\\s+)*struct ${name}\\b`).test(l));
    if (start < 0) throw new Error(`struct ${name} not found; update check-settings.mjs`);
    let end = lines.findIndex((l, i) => i > start && topLevel.test(l));
    if (end < 0) end = lines.length;
    parts.push(lines.slice(start, end).join('\n'));
  }
  return parts.join('\n');
}

const normalise = (s) => s.replace(/(…|\.\.\.)$/, '').replace(/\\"/g, '"').replace(/[‘’]/g, "'").trim();
const pageText = new Map();
const read = (page) => {
  if (!pageText.has(page)) pageText.set(page, normalise(readFileSync(join(pages, `${page}.md`), 'utf8')));
  return pageText.get(page);
};

const missing = [];
const check = (label, onPages, from) => {
  label = normalise(label);
  if (!label || label.includes('\\(') || ignored.has(label)) return;
  if (!onPages.some((page) => read(page).includes(label))) missing.push({ label, pages: onPages, from });
};

for (const [file, structs, onPages] of panes) {
  const source = scope(readFileSync(join(repo, file), 'utf8'), structs);
  for (const [, label] of source.matchAll(controls)) check(label, onPages, file);
}

// Sync's rows are built from SyncSource, so their titles are read from it.
const sync = readFileSync(join(repo, 'Gannin/Sync/SyncSettings.swift'), 'utf8');
const titles = sync.slice(sync.indexOf('var title'));
for (const [, title] of titles.slice(0, titles.indexOf('\n    }\n')).matchAll(/case \.\w+: "((?:[^"\\]|\\.)*)"/g)) {
  check(title, ['app/sync'], 'Gannin/Sync/SyncSettings.swift');
}

if (missing.length) {
  console.error(`${missing.length} setting(s) aren't in the Settings reference (docs-site/src/content/docs/settings/):`);
  for (const { label, pages: p, from } of missing) console.error(`  "${label}" (${from}) belongs on ${p.map((x) => `${x}.md`).join(' or ')}`);
  console.error('Name each on its page as the app labels it, or add it to the ignore list in docs-site/scripts/check-settings.mjs if it isn\'t a setting.');
  process.exit(1);
}
console.log('Every Settings control is in the Settings reference.');
