# Marra: design

Marra (Geordie: your working partner down the pit) is one assistant for all my work, across every
harness and server. Its job is attention: with several streams running, building and reviewing in
equal measure, I lose track of what needs me. Marra keeps that list so I don't have to, tells me,
brings things back when I've parked them, and says where I left off when I return. Chat is for
everything else: ad hoc questions, data, investigations.

The clickable prototype is `gannin-gpui-pilot --assistant-preview` (branch `assistant-prototype`):
canned data, nothing runs claude or calls GitHub.

## The window

- **Floating** by default: a small window of its own (460 wide), kept above other apps while undocked,
  on every Space, so it follows me around.
- **Docked**: a panel down the right of a Gannin window, moving with it. Undock to float again.
- **Command-J** brings it forward (and focuses the input); a notification's click does too.
- The title bar holds the unread filter (with its count), the scope and the menu (Done today, Compact
  now, New conversation, Edit notes, Mark all read, Focus).

## Needs you

What I have to act on, at the top.

- **One thing at a time.** The top item is a card: what it is, the task as a verb ("Review ready to
  post", "Wants to run the e2e suite", "Asked you a question"), a line of detail, its actions, then
  Open and Remind me. The rest are behind "N more".
- **Order:** blocked first (a session waiting on me wastes time), then decisions (a review to post),
  then responses (comments on my PRs), then reminders that came back; oldest first within each.
- **Times say what they are:** "waiting 40m", never a bare "40m".
- **Remind me:** 5, 10, 15 or 30 minutes, an hour, tomorrow, or when CI passes. The item leaves the
  top and comes back by itself, at the top, with a notification.
- **Lanes** (Build, Review, Ask) filter it from the keyboard (B, R, A) and show as a chip only while on.
- **Sources:** blocked sessions, reviews ready, comments and change requests on my PRs, investigations
  finished, reminders due, and review requests with no session yet ("Start review").
- Doing the item marks its thread read; reading the thread doesn't clear the item.

## Threads

Every stream is a thread: **Main** (me and Marra), each **Question**, **Investigation**, and each
**Build** or **Review** session.

- **Rows** as iOS Messages: the unread dot in a fixed margin, a round icon for the kind (sparkle,
  database, magnifying glass, hammer, pull request), the name, the time as "2m ago", a chevron, and the
  last line. No kind text: the icon says it. No lines between rows.
- **Colour means new.** An icon has its kind's colour only while the thread is unread; read, it's grey.
  Titles, times and the last line are neutral.
- **Working** threads show a turning ring (no arrows) where the time goes.
- **Pinned** threads sit first, two lines each like the rest, above one inset rule.
- **Muted** threads show a bell-off icon and never count as unread; a blocked one still reaches
  Needs you.
- **Right-click** a thread: Pin or Unpin, Mute or Unmute, Mark as Read or Unread.
- **Unread:** a thread is read once its newest message has been on screen a moment. New messages and
  events make it unread; progress ("reading traces") updates the last line but doesn't.
- **Archive:** done and read for a day, it's archived; searchable, and a new event brings it back.

## In a thread

- A navigation bar: "‹ Threads", the icon and title, an expand button (Open) and the menu.
- **Bubbles:** mine on the right in blue, Marra's and the worker's on the left in grey, named when the
  sender changes. Events are small centred text that wraps.
- **Long replies:** the point in a bubble, then the rest as Markdown, folded with a fade and Show all.
- **Cards:** an answer (the answer in a sentence, figures, a small chart, the caveat, "How I got it" with
  the query and environment, then Copy, Follow up, Save to findings, Save as /command, Open session);
  findings (cause, evidence, confidence, what's unknown, then Start fix, Comment on ticket, Dig further);
  "Where you left off" at the top of a session's thread (what it is, what's happened since I looked,
  what it wants from me), written from Gannin's own log, no model call.
- While a worker's busy, a bubble with the ring and what it's doing.

## The input

The focus of the window: it's focused on open, grows to ten lines, Return makes a new line and
Command-Return sends. In a thread it goes to that thread's worker or session, and says so above it.

- **/** offers commands as I type: `/waiting`, `/catch-up`, `/ask`, `/investigate`, `/review`,
  `/standup`, `/open`, `/later`. Arrows move, Return or Tab takes one, Escape closes.
- **@** offers threads, PRs, people and skills (`@mono#1539`, `@sam`, `@ch/analytics`, `@mongo`), sent
  to the model as exact IDs.
- **Instant commands** (`/waiting`, `/open`, `/review`) are answered by Gannin from its own state, with
  no model call. **Prompted commands** (`/standup`, `/catch-up`) are saved prompts, kept in the harness
  so the team can share them. Any answer can be saved as a command.

## Notifications

They say what to do, not what happened, with buttons for the usual answers.

| Kind | Example | Notifies |
| --- | --- | --- |
| Blocked | "clients#2466 is waiting for you to allow the e2e run" | at once |
| Decide | "mono#1539: review ready to post (approve, 2 nits)" | yes |
| Respond | "Sam asked for changes on api#1544" | yes |
| Back | "mono#1528 is back: CI passed" | yes |
| Answer ready | "SGN 1,284 permits last week (+18%)" | yes |
| FYI | finished, merged, CI green | never; a line in the thread |

- **Reminders:** a blocked item still waiting is mentioned again at 15 minutes and at an hour, then left
  at the top of Needs you.
- **Focus:** while it's on, everything but blocked items is held and summed up in one notification when
  it goes off ("3 things while you were busy"), listing them. On by itself while I'm typing in a
  session, and with macOS Focus. The moon in the title bar switches it; while it's on, the title bar is
  purple. Nothing else changes.
- **Quiet hours,** with a morning digest instead.

## Open

Open (on the card, a notification, the expand button) brings the main Gannin window forward on that
item's tab.

- **A session** opens its own tab as it is today (the review panel; terminal and Changes), under a
  "where you left off" strip that goes once read. Never a copy.
- **A question or investigation** opens a new kind of tab: the thread at full width beside its
  evidence, the skills used, Show Terminal and (for an investigation) Start fix. The conversation is the
  same component as Marra's.

## The engine

- **Marra is headless claude** kept running: `claude -p --input-format stream-json --output-format
  stream-json --session-id <id> --mcp-config <gannin> --permission-prompt-tool mcp__gannin__approve`.
  Its events become the chat: text streams into a bubble, tool calls into small cards.
- **Gannin is its toolbox,** a local MCP server: `list_sessions`, `read_session`, `send_to_session`,
  `answer_question`, `start_session`, `open_tab`, `workload`, `list_skills`, `show` (draws a card with
  live state and real buttons) and `notes` (reads and writes its notes).
- **Permissions become cards:** Allow, Allow always, Deny.
- **State comes from tools,** never from what it remembers, so compacting loses nothing that matters.
- **Persistent:** one conversation, resumed after a relaunch. Claude Code compacts it near the limit;
  Compact now and New conversation are in the menu, with a context meter. `marra-notes.md` (my
  preferences, open threads) is loaded into every new conversation and can be edited by hand.
- **Events cost nothing:** Gannin writes them into threads itself; the model wakes only when I ask, or
  for a nudge I've switched on.

## Workers and how they talk

Marra routes; workers do the work. A question or investigation is an **errand**: a short-lived session
in the right harness, with its skills and access (the harness's `.mcp.json`, `skills/`), edits off.

- **Down, a brief:** the goal, the scope, the skills, read only, and the reply contract.
- **Up, only the contract,** never the raw transcript:

  ```json
  { "point": "one sentence you could say out loud",
    "body": "the whole of it, Markdown, any length",
    "needs_you": { "task": "Post the review", "actions": ["Post", "Look"] },
    "cards": [] }
  ```

- **Each place reads what fits:** a notification and the thread list show `point`; Needs you shows
  `needs_you`; the thread shows `point` as a bubble and `body` folded.
- **Prompt rules:** lead with the answer or verdict, never with what you did; `point` is one sentence;
  `needs_you` only for a real decision, never "let me know if"; `body` is evidence, never needed to act.
  Marra's own messages in Main follow the same rule.

## Data questions and investigations

- **Questions** ("how many permits did SGN create last week?") pick a harness and skill (`ch/analytics`,
  `mongo`), shown on the card and changeable. Read-only skills start at once.
- **Investigations** ("investigate product#4251") plan with `triage` and use what the evidence calls for
  (`hyperdx`, `mongo`, `grafana`, `k8s`). Read only until Start fix, which starts Work on This with the
  findings in its brief.
- **Customer data:** workers summarise and count; they never quote raw documents in a card. The detail
  stays in the worker's session.
- **Save to findings** writes the harness's `findings/` format and leaves it for me to commit.

## Scope and servers

- **Scope** (All, a harness, a server) narrows Needs you, the threads and the instant commands, and goes
  with each message. Defaults to All, per window.
- **Server sessions** read from the local mirror Gannin already keeps (hook files and transcript lines
  copied back every two seconds), so the tools never need ssh.
- **Ownership:** Marra acts only on sessions whose terminal this Gannin holds; others it can read, and
  their card says where they run.

## The API and a phone

- **Local network only.** Nothing is exposed beyond the LAN; no Tailscale.
- **Marra is a service** with one event model; the window is its first client and an HTTP API is the
  second. REST for actions, Server-Sent Events for everything live, under `/v1`:
  `GET/POST /assistant/messages`, `POST /assistant/stop|compact|new`, `POST /approvals/:id`,
  `GET /sessions`, `GET /sessions/:id`, `POST /sessions/:id/answer|message`, `GET /workload`,
  `POST /commands/:name`, `GET /events`.
- **Paired devices:** Gannin shows a QR code; each device gets its own token, kept in the keychain,
  listed and revocable. Never through the API: the GitHub token, claude's login, a raw terminal.
- **Types** generate an OpenAPI spec, and the phone's Swift client is generated from it.
- **Host:** the Mac first; the headless Linux Gannin on the server later, when it should run while the
  Mac sleeps.

## Safety

- Every write to GitHub is confirmed by me; on the phone, the confirmation is my tap.
- Sending to a session needs my OK at first (a confirm card); kinds I trust (answering with the
  recommended option, "carry on") can be allowed later.
- Workers run read only, with the harness's own limits (Atlas's read-only user, the MCP server's guards).

## Build order

1. The engine: headless claude, its events as chat, permission cards, resume.
2. The MCP server: `list_sessions`, `read_session`, `show`, `open_tab`, with the ownership rule.
3. The window: Needs you, threads, the input with / and @; floating and docked.
4. Instant commands and Gannin's event log (unread, "where you left off").
5. Errands: the brief, the reply contract, questions, then investigations.
6. Notifications, Remind me, Focus.
7. `send_to_session` behind its confirm card; saved prompts; `marra-notes.md`.
8. The service split and the HTTP API, pairing; then the phone.

## Defaults taken

Not discussed in detail; change any of them.

- Return on the top item does its main action straight away; GitHub writes still confirm.
- Phone notifications are LAN only to begin with; APNs (which leaves the network) is a later choice.
- Review requests with no session yet go in Needs you.
- Which harness, when a question doesn't say: Marra guesses from the question and shows its guess on
  the card.
