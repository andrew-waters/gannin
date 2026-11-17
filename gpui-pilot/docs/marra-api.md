# Marra's API

For a phone app (or anything else) on the local network. Off until Marra's menu › Phone access is
on; the menu shows the address (`<this Mac>:47870`) and a pairing code. Connections from outside
private, link-local and loopback addresses are refused (so no Tailscale or other overlay range).
"Private" is any 10/8, 172.16/12 or 192.168/16 address, so on a VPN that hands out one of those, its
other users count as local too: keep Phone access off there. A pairing code stops working after five
wrong tries.

Every call but pairing needs `Authorization: Bearer <token>`. Bodies are JSON. Errors are
`{"error": "..."}` with a 4xx or 5xx status; accepted actions reply `202 {}`.

## Pairing

| Call | Body | Reply |
| --- | --- | --- |
| `POST /v1/pair` | `{"code": "123456", "name": "Phone"}` | `{"device": "...", "token": "..."}` |

The code is good for ten minutes and one device. Keep the token in the keychain. Revoke all
devices in Marra's menu.

## Live

`GET /v1/events` is a Server-Sent Events stream: `event: changed` with `{"version": n}` whenever
anything in Marra moves on (a message, a session's state, Needs you). Refetch what's on screen when
it arrives. A comment line every 20 seconds keeps the connection open.

## Calls

| Call | Body | Reply |
| --- | --- | --- |
| `GET /v1/needs` | | `{"needs": [{key, subject, task, detail, since, waiting, blocked, back, thread, lane, actions}]}` |
| `POST /v1/needs/:key/remind` | `{"minutes": 30}` (omit for when CI passes) | 202 |
| `GET /v1/threads` | | `{"threads": [{id, kind, title, last, activity, working, unread, pinned, muted}]}` |
| `POST /v1/threads/:id/read` | `{"read": true}` | 202 |
| `GET /v1/assistant/messages` | | `{messages, busy, streaming, context, pending}` |
| `POST /v1/assistant/messages` | `{"text": "..."}` | 202 |
| `POST /v1/assistant/stop`, `/compact`, `/new` | | 202 |
| `GET /v1/approvals` | | `{"approvals": [{id, kind: "permission" or "send", thread, summary}]}` |
| `POST /v1/approvals/:id` | `{"allow": true, "always": false}` | 202 |
| `GET /v1/sessions` | | `{"sessions": [{id, title, kind, state, since, subject, server, review_ready}]}` |
| `GET /v1/sessions/:id` | | `{id, title, state, since_read, messages: [{who, text}]}` |
| `POST /v1/sessions/:id/message` | `{"text": "..."}` | 202 |
| `GET /v1/workload` | | `{reviews, mine, live}` |
| `GET /v1/errands/:id` | | `{id, title, point, needs_you, conversation}` |
| `POST /v1/errands/:id/messages` | `{"text": "..."}` | 202 |

Ids with a colon (sessions) may be sent escaped (`%3A`). Messages are Marra's chat entries as
`marra.rs` defines them (`kind`: you, marra, tool, permission, event, reply, note).

A tap on the phone is the user's confirmation: allowing a send to a session or a permission there is
the same as on the Mac. Nothing here writes to GitHub.

Not yet: an OpenAPI file generated from the types, `/v1/commands/:name`, and APNs (notifications
reach the phone only while its app holds `/v1/events` open).
