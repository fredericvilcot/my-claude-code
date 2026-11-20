<div align="center">

# My Claude Code

**A macOS menu bar companion for [Claude Code](https://claude.com/claude-code).**
Plan quotas and when they will run out, what every session is doing right now, a live mirror of its
terminal, an in-app notification center and a voice-ready quick command — one click away.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-lightgrey)
![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-orange)
![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue)

</div>

> The user interface is in French. Everything stays on your Mac: the app reads your local `~/.claude`
> folder and sends nothing anywhere else.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Getting started](#getting-started)
- [User guide](#user-guide)
- [Settings](#settings)
- [Privacy](#privacy)
- [FAQ](#faq)
- [Building from source](#building-from-source)
- [Project structure](#project-structure)
- [License](#license)

## Features

| | |
|---|---|
| **Plan quotas** | 5-hour session, weekly and per-model limits, read from `/usage` every minute and from Claude Code's status line on every reply. |
| **Forecasts** | Hour-by-hour projection of when each quota runs out, based on your usual working hours over the last four weeks and this week's intensity. |
| **Live sessions** | Open sessions sorted by state (working, waiting for you, idle), what the agent is doing right now, context usage and one-click compaction. |
| **Terminal mirror** | The exact screen of a session's iTerm tab, live. Click it to take the keyboard: arrows, Return, Esc, Tab and text go straight to the session, choice menus included. |
| **Notification center** | Session finished, waiting for your answer, context nearly full, quota at risk, evening summary — inside the app only. |
| **Agent messaging** | Message any session — open, or closed and relaunched in the background with its history — from another session or from the quick command. |
| **Quick command** | Start a new project in an iTerm tab, message a session, or hand a task to an ephemeral agent — typed or dictated. |
| **Floating windows** | Quotas, notifications, sessions and the quick command detach into small always-on-top windows, even over full-screen apps. |
| **Statistics** | API-equivalent costs, tokens, models, projects and an activity calendar. |

## Requirements

- An Apple Silicon Mac (M1 or later) running **macOS 14 Sonoma or later**.
- **Claude Code** installed, with `claude` on your `PATH`.
- **[iTerm2](https://iterm2.com)** *(recommended)* for the terminal mirror, new projects, compaction and
  resuming sessions. Everything else works without it.
- No administrator rights are needed.

## Installation

1. Get the app: [build it from source](#building-from-source), or open the `.dmg` you were given.
2. Drag **My Claude Code** into your **personal** Applications folder
   (Finder › Go › Home › Applications — create it if it does not exist).
   The system-wide `/Applications` folder requires administrator rights; this one does not.
3. Prebuilt copies are not notarized by Apple: on first launch, **right-click the app › Open**, or allow it
   in System Settings › Privacy & Security.

The icon appears in the menu bar; click it to open the panel.

## Getting started

1. **Connect the status line** — *Réglages › Connecter à Claude Code*. The app installs a small status line
   script in `~/.claude/settings.json` (backing it up first) so percentages update on every Claude Code reply.
   If you already use your own status line, the app asks before replacing it. Without it, quotas still
   refresh every minute.
2. **Permissions** — macOS asks once, on first use: microphone and speech recognition (dictation), and
   control of iTerm (terminal mirror, new projects, compaction).
3. **Launch at login** — *Réglages › Général*.

## User guide

### Menu bar

The icon shows your **session** and **weekly** usage, or **today's cost** if you prefer
(*Réglages › Barre des menus*). Figures turn red past your alert threshold, and a small dot means a
notification is waiting.

Click to open the panel; click outside or press <kbd>Esc</kbd> to close it. Reopened within two minutes,
it comes back where you left it. Over a full-screen app it opens as a menu, so the menu bar stays visible.

### Header

- **Bell** — opens the [notification center](#notification-center); a red badge counts what is waiting.
- **⚡ Rapide** — opens the [quick command](#quick-command).
- **Summary line** — plan, model and effort level, open sessions (details on hover).

### Direct tab — what matters, live

- **Quotas** — the session ring, weekly and per-model quotas with their reset time and a forecast:
  *“épuisé lun. 11:37”* in orange when a quota will run out before its reset at your current pace,
  otherwise *“≈ 44 % à la réinit.”*. Recomputed every five seconds.
- **Open sessions** — one card per session, most active first: state dot (green working, orange waiting
  for you, sage idle), what the agent is doing (*“modifie report.ts · depuis 12 s”*) with a precise detail
  (*“+12 −3 lignes”*), and its context. A **Compacter** button appears from 50 % context. Click a card to
  open the session.

### Sessions tab

- Pick a period: today, 7 days, 30 days or all.
- Sessions are grouped by state — **Actives**, **Attendent votre réponse**, **Au repos** — then
  **Inactives** by day.
- **Swipe a card left** to *stop* an open session or *delete* it (its transcript goes to the Trash and
  can be restored). Right-click offers the same actions.
- **Tout supprimer**, next to the *Inactives* badge, deletes every inactive session of the period after
  confirmation.

### Session view

A fixed header keeps the session's name, folder, state, branch and messaging name (click to copy) in view.
Below it:

- **Terminal** — the live screen of the session's iTerm tab (*direct*), coloured like a real terminal.
  **Click it to take the keyboard** (clay border, *clavier* in its bar): every key goes to the session as if
  you typed in iTerm — text, Return, Esc, Tab, ⌃C, and the arrow keys to move through Claude Code's choice
  menus. Sessions without an iTerm tab (closed, or running in the background) are rebuilt from their
  transcript (*journal*).
- **Messages entre agents** — what the session exchanged with your other Claude Code sessions and with the
  app (not its terminal, not your prompts). Pick any session in **À** — open, or closed in the last seven
  days — to write to it: a closed session is relaunched in the background with its history.
- *Terminal* and *Messages entre agents* are foldable cards that work as an accordion: opening one folds
  the other.
- **Contexte** — context size and **Compacter**: the session writes a synthesis note (goal, progress,
  decisions, key files, next steps) to `~/.claude/session-notes/`, then `/compact` runs and keeps it.
  Requires iTerm.
- **Coût**, **Tokens**, **Détails** *(folded)* — click a card title to fold or unfold it; the app remembers.
- **Actions** — resume a closed session in a new iTerm tab, copy its resume command, reveal its transcript
  in Finder, delete it.

### Notification center

Opened from the bell, grouped by day:

- a session **finished** its work;
- a session is **waiting for your answer**;
- a session's **context is nearly full** (85 %) — with a *Compacter* action;
- a quota **crossed your threshold**, or **will run out before it resets**;
- the **daily summary**, every evening at the time you choose.

Click a notification to open its session; it is cleared. Swipe left or use the ✕ on hover to clear one,
the ✓ icon to clear all. Opening a session also clears its *finished* and *waiting* notifications.
Nothing is ever posted to macOS Notification Center.

### Quick command

Type or **dictate** (microphone button) an instruction, pick a destination in **Vers**, press
<kbd>Return</kbd>:

| Destination | What happens |
|---|---|
| **Agent éphémère** | An ephemeral Claude Code agent runs the task in the background with your settings, reports back in the history, then exits. |
| **Message to a session** (or all) | The message is delivered through Claude Code's inter-session messaging; the reply shows in the session's *Messages entre agents*. Closed sessions are listed too: they are relaunched in the background with their history. |
| **Nouveau chantier** | A new tab opens in your iTerm hotkey window and Claude Code starts in the chosen folder with your instruction as its first message. |

The destination always resets to the ephemeral agent, so a new project never starts by accident. The
history keeps every command and its report; swipe left to delete one.

### Floating windows

Quotas, the notification center, any session and the quick command can be **detached** into small windows
that stay visible on every Space, including over full-screen apps — handy during a video call.

- Click the **⧉** icon at the top right of an element to detach it; it turns clay while detached, and
  clicking it again closes the floating window.
- Move a window by its top bar, resize it from its edges, close it with ✕.
- Open windows are restored, in place, the next time the app starts.

A detached session shows its summary (model, replies, cost, duration), context with *Compacter*, its live
terminal (click to type) and its agent-to-agent messages, as an accordion.

### Stats and Statut tabs

- **Stats** — API-equivalent costs, tokens, replies, models, projects, activity calendar, hourly and
  weekday breakdowns.
- **Statut** — Claude Code status and version, configuration and MCP servers.

## Settings

| Section | Options |
|---|---|
| **Général** | Launch at login; menu bar content (session + week, or today's cost). |
| **Alertes** | One switch per notification type; time of the daily summary (17:30 to 20:30). |
| **Limites et alertes** | Status line connection, quota alert threshold, open the panel when a threshold is crossed, `/usage` refresh interval (1, 2 or 5 minutes). |

## Privacy

- The app reads `~/.claude` (transcripts, sessions, settings) and runs the local `claude` CLI.
- Its own settings and history live in `~/Library/Application Support/MyClaudeCode` and its preferences.
- No telemetry, no network calls of its own. Reading `/usage` and transcripts does not consume your quota;
  messaging a session or running an ephemeral agent goes through Claude Code like any other exchange.

## FAQ

**Percentages don't move.** Connect the status line (*Réglages*); otherwise they refresh on every `/usage`
read (every minute by default).

**The terminal says *journal* instead of *direct*.** The session has no iTerm tab (closed, background, or
started in another terminal), or the app is not yet allowed to control iTerm
(System Settings › Privacy & Security › Automation).

**“Fenêtre à raccourci d'iTerm introuvable”.** New projects and resumed sessions open in iTerm's hotkey
window: set one up in iTerm › Settings › Keys › Hotkey, then open it once.

**Does the app work without iTerm?** Yes: quotas, forecasts, sessions, notifications, statistics and
inter-session messages all work; terminals are rebuilt from transcripts.

## Building from source

Requires Apple's developer tools (Xcode, or `xcode-select --install`). No other dependency.

```sh
git clone https://github.com/fredericvilcot/my-claude-code.git
cd my-claude-code
./build.sh            # builds "build/My Claude Code.app"
./build.sh --install  # builds, copies it to ~/Applications and launches it
```

**Code signing.** If a code signing identity named *Local Menu Apps Signing* exists in your keychain, the
script uses it, so macOS keeps granted permissions across rebuilds. Otherwise the app is signed ad hoc,
which works too (macOS will ask for permissions again after each rebuild).

## Project structure

```
Sources/App/     AppKit entry point, menu bar panel, floating windows
Sources/Data/    transcripts, /usage, forecasts, sessions, notifications, iTerm mirror
Sources/Views/   SwiftUI views: tabs, cards, terminal, notification center, quick command
Resources/       Info.plist, app icon
build.sh         build, sign, install
```

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md) © 2026 Frédéric Vilcot.

You may use, study, modify and share this software for any **noncommercial** purpose (personal use,
research, education, hobby projects, charitable and public organizations). Any commercial use requires a
separate license from the author.
