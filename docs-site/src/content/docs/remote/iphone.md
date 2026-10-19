---
title: Control sessions from your iPhone
description: Answer Claude's questions and permission prompts, send a prompt, stop a session or switch its mode from your iPhone, over your local network.
sidebar:
  order: 1
---

Gannin Remote is an iPhone app that shows the Claude Code sessions running on your Mac and lets you decide what they are waiting on: answer a question, allow or deny a permission prompt, send a message, stop a session, or switch it between Attended and Unattended. It talks to your Mac directly over your local network. Nothing goes through a Gannin server.

## What it does

- Lists your Mac's sessions with the ones that need you first.
- Shows a permission prompt with the tool and the whole command, so you can read what you are allowing. A command cut short for the phone says so.
- Answers Claude's questions with their options, or an answer of your own.
- Sends a message to a session, interrupts it, and switches it between Attended and Unattended.

It does not approve PRs, approve plans, start sessions or show diffs. For those, use Gannin on your Mac.

## What you need

- Gannin on your Mac and Gannin Remote on your iPhone, on the same Wi-Fi network. A Mac you reach over a VPN you run works too, if the phone can find it.
- A passcode set on the iPhone. The app asks for Face ID or the passcode when it opens, and again after it has been away for a minute.

## Pair your iPhone with your Mac

1. On your Mac, open Settings › Remote and turn on Allow iPhones to control sessions.
2. Choose Pair a Phone. Gannin shows a code and the same code as text. It works once, for two minutes.
3. On your iPhone, open Gannin Remote, choose Add a Mac, and scan the code. To type it instead, pick your Mac from the list and enter the code.
4. Gannin on the Mac asks "Pair" followed by the phone's name. Choose Pair only for a phone you just set up yourself. Don't Pair is the default button.

You pair once. After that the phone reconnects by itself whenever it is on the same network. You can pair several Macs with one phone, and several phones with one Mac.

Each device has its own key, and pairing ties the two together. If you reinstall Gannin Remote, or reset the key Gannin keeps in your Mac's keychain, the pairing is lost and you pair again.

## Lose a phone

Open Settings › Remote on your Mac and choose Revoke beside the phone. It is disconnected at once and cannot reach your sessions again unless you pair it again.

A paired phone can approve commands that run as you, so treat it like your logged-in Mac.

## Limits

- **No push notifications.** iOS suspends the app soon after you leave it, so you only see "Needs you" while the app is open. Keep it open, or check the Mac's own notifications.
- **Your Mac has to be awake** and on the network. Gannin does not keep it awake.
- A prompt you answer on the Mac first is refused on the phone with a message, so a late tap never lands on a different prompt.
- Switching to Unattended is refused when Claude Code's auto mode isn't available for the session, as on the Mac.
- The phone shows up to 60 sessions, with those needing you first, within a 256 KB update budget. Large prompts can reduce that number; a session whose question or options cannot fit is available on the Mac.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| "Can't look for Macs" | Allow Local Network for Gannin Remote in the iPhone's Settings. |
| "Can't find your Mac on this network" | Check both are on the same Wi-Fi and that Allow iPhones to control sessions is on. |
| "That code has expired or been used" | A code works once, for two minutes. On the Mac, close the window and choose Pair a Phone again. |
| "That code isn't right" | Check what you typed. The attempt used up the code, so start again on the Mac. |
| "That isn't the Mac whose code you scanned" | Another Mac answered. Scan the code from the Mac you meant, or check which network you are on. |
| "The Mac didn't prove it knows the code" | Something between the phone and the Mac interfered, or the code was wrong. Use your own network and start again. |
| "The Mac declined" | You chose Don't Pair on the Mac. |
| "Runs a different version of Gannin" | Update Gannin on whichever of the Mac and the iPhone is older. |
| "Set a passcode on this iPhone" | The app needs a passcode to unlock. Set one in the iPhone's Settings. |
