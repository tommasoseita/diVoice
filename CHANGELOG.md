# Changelog

All notable changes to diVoice. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [semantic versioning](https://semver.org).

## 0.6.1 — Long dictations are never lost

### Fixed

- **A long Scribe dictation could be lost.** Scribe had one minute to answer, however long the dictation. When it ran out, the transcript was thrown away. Now:
  - Scribe gets more time for longer dictations, up to five minutes.
  - If Scribe still fails, diVoice inserts your dictation as you said it, tidied but not rewritten. History marks it **Not rewritten**.
  - If Scribe was rewriting a selection, nothing replaces it: what you said stays in History.
  - The cleanup of long dictations also gets more time.
  - The app waits longer for long recordings before giving up.

  Through an organization's server, Scribe also stops at the server's own limit: 90 seconds up to diServer 0.6.0. Past it, the dictation goes in as above.

## 0.6.0 — Your own AI server

Cleanup and Scribe on any OpenAI-compatible server, and the transcription provider at the first launch. Contributed by Luca Sartoni ([#1](https://github.com/tommasoseita/diVoice/pull/1)).

### Added

- **OpenAI-compatible servers for cleanup and Scribe.** Point diVoice at a LiteLLM proxy, Ollama or any other server with OpenAI's chat completions API: type its address and key in Settings › Models, choose **OpenAI-compatible** for Cleanup or Scribe and type the model name. Personal mode only.
- **ElevenLabs at the first launch.** The setup now asks which provider transcribes, so you can choose ElevenLabs and paste its key there, without opening the settings.

## 0.5.3 — Scribe v3

ElevenLabs's newest transcription models.

### Changed

- **ElevenLabs transcribes with Scribe v3**, released on 10 November 2026: `scribe_v3_live` while you speak and `scribe_v3` at release. Settings still on the old Scribe v2 defaults move to v3; a model you typed yourself stays. Scribe v2 remains available in the model fields. It works through an organization's server too, with no change to diServer.

## 0.5.2 — Hands-free fix

### Fixed

- **The double tap of Fn didn't start hands-free dictation.** Right after a quick tap of 🌐/Fn, macOS reports that tap as a key of its own, which diVoice took for typing and so ended the double tap. It's now ignored.

## 0.5.1 — Hands-free

Dictate without holding Fn.

### Added

- **Hands-free dictation.** Double-tap Fn and speak without holding it; press Fn once to finish and the text is processed as usual. With Ctrl held, the double tap starts Scribe hands-free. The overlay shows which key finishes it, Esc cancels, and it ends by itself just before 10 minutes.

## 0.5.0 — Context and style

diVoice reads the conversation, writes in the tone you choose for each kind of app, and learns from your corrections.

### Added

- **The conversation on screen as context.** When you start dictating, diVoice reads the text before the cursor and the window around the field (the thread, the recipient, the subject), to spell names as they appear there, keep the conversation's "tu" or "Lei" and continue what you've written. Names on screen also guide the transcription. The text goes only to the AI provider and is never saved; password fields are never read. **Settings › General › Use the text on screen as context** turns it off.
- **Settings › Style:** a tone for each kind of app (email: Formal, Cordial or Direct; work chat: Professional, Direct or Informal; personal chat: Natural or Informal; documents: Polished or Notes), your own instructions for each, and apps or websites assigned to a kind.
- **Learning from your corrections.** Fix a name after a dictation and it joins your dictionary; after five corrections in a kind of app, diVoice notes how you like to write there and writes that way. The learned lines can be edited or forgotten in Settings › Style.
- **ElevenLabs Scribe v2** for transcription, with your dictionary as keyterms (at most 100, so no request pays ElevenLabs' 20-second minimum). In an organization it needs [diServer](https://github.com/tommasoseita/diServer) 0.6.0 or later, which also counts Scribe dictations in the team statistics.
- History shows the kind of app diVoice recognized, and Latency how much context each dictation read on screen.

### Changed

- **Scribe rewrites for real:** even a short message comes out rephrased and better written, in the app's tone and fitting the conversation. It still adds no facts and never carries out what you dictate.

### Fixed

- The Team page kept showing the numbers of the first time it opened: it now reloads after each dictation and when diVoice comes back to the front.

## 0.4.2 — Pilot update

Emails that read like emails, a history of your dictations, and team statistics that no longer miss dictations.

### Added

- **History:** **Settings › History** (also **History…** in the menu bar) lists your dictations from the last 7 days. Copy a text again, or take back what you said before the cleanup to rewrite it. **Clear history…** deletes it. The history stays on your Mac, as before.

### Changed

- **Emails read like emails.** In an email app the cleanup lays the text out with the greeting, paragraphs and closing on their own lines, and turns spoken phrasing into written sentences, without adding anything you didn't say.

### Fixed

- Gmail with Google Workspace, whose window shows the company's name instead of "Gmail", wasn't recognized as email once you opened a conversation.
- With an organization, a dictation's counts could get lost when the connection closed, and the dictation was then missing from the team statistics.

## 0.4.1 — Pilot update

Scribe types straight into your app, and you can create an organization from diVoice.

### Added

- **Create an organization from the app:** in the setup window, **With my team › Create an organization…** generates the server's secret, opens the Deploy to Cloudflare button and makes you the first admin. It needs [diServer](https://github.com/tommasoseita/diServer) 0.5.0 or later. See [Setting up a team](docs/tutorials/setting-up-a-team.md).

### Changed

- The organization server is now [diServer](https://github.com/tommasoseita/diServer), shared with diMail, with its own repository, releases and documentation. Existing servers keep working unchanged.
- **Scribe's text goes straight into your app.** The overlay no longer shows it while it arrives: it says "Scribe is rewriting", and the finished text is inserted where you are typing.
- **The overlay disappears as soon as the text is in.** It no longer shows how long the dictation took; the menu bar menu still does.

## 0.4.0 — Pilot

Organizations, and a new Scribe.

### Added

- **Organizations:** a self-hosted server on Cloudflare Workers that holds the AI keys and the models for a team. Members join with an invite link, with no setup of their own. See [Organizations](docs/organizations.md).
- **Invites:** team links, email invites limited to given addresses, and personal links that also reconnect a member on a new Mac. The downloaded app recognizes its invite at the first launch and moves itself to Applications.
- **Admin panel:** provider keys (encrypted on the server, never shown again), models for everyone, invites, members and roles, the team dictionary, the leaderboard.
- **Team view:** words, time saved, speaking speed and day streak, from every Mac, with an optional leaderboard. Members can hide from the team. Statistics never include text.
- **Movable overlay:** drag it anywhere; the position is kept across restarts and screen changes. **Settings › General › Reset position** brings it back.
- **Scribe's text appears as it's written**, in the overlay card.
- `divoice-bench --scribe`: a quality bench for Scribe, and `--server` to measure through an organization's server.

### Changed

- **The product is now called diVoice**: the app, its windows and menus, the disk image and the invite pages. The bundle identifier, permissions, keys and data on your Mac are unchanged.
- **Scribe is now an editor.** Without a selection it rewrites what you dictated so it reads clearly, keeping its content, language, person and intent, and never carries out what it asks: a prompt for an AI stays a prompt. With a selection, your dictation still says how to change it.
- **Scribe defaults to Mistral Medium 3.5**, the best result on the editing bench, with the first word in about 0.4 s.
- **New look:** warm backgrounds, rounded cards, pill selectors, and a single orange accent for recording and errors, in light and dark mode. Settings has a sidebar.

### Fixed

- Scribe answers were cut off when a reasoning model used up the response length.

## 0.3.0 — Internal

Personal mode: diVoice works on its own with your API key.

### Added

- **Mistral and OpenAI** for transcription, cleanup and Scribe, with any model, chosen per step.
- **Verify:** tests each step with your key and model, with timings.
- **Hybrid transcription** (Mistral): streaming while you speak, plus the whole recording at release when it's more accurate.
- **Personal dictionary** with "heard as" forms, and **statistics** (words, time saved, words per minute, streak).
- **English interface** with Italian translation.
- `divoice-bench`: latency and accuracy with the app's own engine.

### Changed

- Cleanup prompts in English, with the transcript's language detected on the Mac: Italian quality unchanged, mixed Italian and English kept as spoken.
- OpenAI's fast processing is on by default for cleanup.
- Build numbers derive from the version (0.3.0 → 300).

### Fixed

- ⌘V, ⌘C, ⌘A and ⌘Z in text fields, including the API key field.
- The cleanup could translate the dictation into English; it now falls back to the raw transcript when the result looks translated.

## 0.2.1 and earlier — Internal

Internal builds for a single team, through a hosted backend: hold-to-dictate, cleanup per app category, Scribe, team dictionary, signed and notarized builds with automatic updates.
