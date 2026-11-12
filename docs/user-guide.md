# User guide

## Dictation

**Hold Fn, speak, release.** The text appears where your cursor is, in any app.

- **Start speaking right away.** With **Keep the microphone ready** (Settings › General, on by default), the microphone is already on and the dictation includes the half second before you pressed the key, so the first words aren't cut. With it off, or with a Bluetooth headset, the microphone turns on at the key press: start when you hear the sound.
- **Speak naturally.** Hesitations ("um", "ehm") and filler words go away. Self-corrections are applied to the part you corrected: "on Thursday at three, actually four" becomes "on Thursday at four".
- **Dictate punctuation when you want it:** "comma", "period", "question mark", "new line", "new paragraph" (also in Italian: "virgola", "punto", "a capo"…). Otherwise diVoice punctuates for you.
- **Numbers, dates, times, amounts and email addresses** come out in their written form ("at 3:30 pm", "20%", "name@example.com").
- **Your language is kept.** diVoice never translates: Italian stays Italian, English stays English, and English words in an Italian sentence stay as you said them. Choose the dictation language in **Settings › General**, or let diVoice detect it.
- **The tone follows the app.** diVoice recognizes the app you are writing in:

  | Category | Examples | Style |
  |---|---|---|
  | Email | Mail, Outlook, Gmail (also with Google Workspace), Spark | Laid out as an email: greeting, paragraphs and closing on their own lines, spoken phrasing turned into written sentences |
  | Work chat | Slack, Teams, Google Chat, Linear | Direct and concise |
  | Personal chat | Messages, WhatsApp, Discord | Informal, no final period |
  | Documents and notes | Notes, Pages, Word, Craft | Careful punctuation, paragraphs and lists |
  | Code and AI assistants | Editors, terminals, Claude, ChatGPT | Literal: terms, file names and commands untouched |

  Choose a different tone for each kind of app, add your own instructions, or assign an app or website to a kind in [Settings › Style](#style).

- **The conversation on screen helps.** When you start dictating, diVoice reads the text around the cursor and the conversation in the window: the thread you're replying to, the recipient, the subject. It uses them to spell names as they appear there, to keep "tu" or "Lei" as the conversation does, and to continue what you've already written. The text goes only to the AI provider and is never saved; password fields are never read. Turn it off in **Settings › General › Use the text on screen as context**.
- **Spacing is automatic.** When you dictate in the middle of a sentence, diVoice starts with a lowercase letter and adds the space it needs.

If a password field has the focus, macOS doesn't allow typing into it: the text stays on the clipboard and the overlay says "Text copied: press ⌘V". The same happens in the rare apps that don't accept pasted text.

**Hands-free:** double-tap Fn, quickly, and speak without holding anything. The overlay shows **Fn to finish**; press Fn once when you're done, and the text is cleaned up and inserted as usual. Meanwhile you can type or click elsewhere; <kbd>Esc</kbd> cancels. A hands-free dictation ends by itself just before 10 minutes.

![Hands-free](images/overlay-recording-hands-free-light.png)

**To cancel**, press <kbd>Esc</kbd> while holding the key. A single quick tap does nothing, and pressing another key together with Fn (for example Fn+→) is treated as a shortcut, not a dictation.

## Scribe

Hold <kbd>Ctrl</kbd>+<kbd>Fn</kbd>, or press Ctrl while you are already holding Fn. For Scribe hands-free, hold Ctrl and double-tap Fn; press Fn once when you're done, and Scribe rewrites what you said.

**Without a selection, Scribe rewrites what you dictate** as you would have written it by hand, taking your time: it rephrases freely, picks better words, restructures sentences, puts ideas in a logical order, removes repetitions and uses lists where you enumerate things. Even a short message comes out clearly better written. It follows the tone you chose for the app and the conversation on screen. It keeps:

- **your content and intent:** it adds no facts, names or numbers;
- **your language,** each part of a mixed sentence in the language you spoke it in;
- **your voice:** if you speak in the first person, the text stays in the first person; whoever you address, it still addresses;
- **your requests as requests:** Scribe never carries out what you dictate. "Write a short email to Marco to move the call" comes out as that same request, better written, not as the email. A question stays a question.

That makes Scribe ideal for dictating prompts for Claude, ChatGPT or any assistant: speak your thoughts in any order, and paste a clean prompt. See [Dictating prompts for an AI](tutorials/dictating-prompts.md).

**With text selected, your dictation says how to change it:** "shorter", "more formal", "turn it into a list", "fix the typos", "translate it into English". The selected text is replaced by the new version.

While Scribe writes, the overlay says so; the text goes straight into your app when it is complete.

![Scribe rewriting](images/overlay-scribe-rewriting-light.png)

## Shortcuts

| Shortcut | Action |
|---|---|
| Hold <kbd>Fn</kbd> | Dictate |
| Double-tap <kbd>Fn</kbd> | Dictate hands-free; press <kbd>Fn</kbd> again to finish |
| Hold <kbd>Ctrl</kbd>+<kbd>Fn</kbd> | Scribe |
| Hold <kbd>Ctrl</kbd> and double-tap <kbd>Fn</kbd> | Scribe hands-free; press <kbd>Fn</kbd> again to finish |
| Hold right <kbd>⌘</kbd> | Dictate, on keyboards without Fn (changeable to right <kbd>⌥</kbd> or off) |
| Hold <kbd>Ctrl</kbd>+right <kbd>⌘</kbd> | Scribe, on keyboards without Fn |
| <kbd>Esc</kbd> while holding, or hands-free | Cancel |

On some keyboard layouts right ⌥ types characters such as @ and #: prefer right ⌘ there.

## The overlay

The small pill at the bottom of the screen shows what diVoice is doing:

| | |
|---|---|
| ![Recording](images/overlay-recording-light.png) | Recording: orange dot and waveform |
| ![Recording for Scribe](images/overlay-recording-scribe-light.png) | Recording for Scribe |
| ![Hands-free](images/overlay-recording-hands-free-light.png) | Hands-free, after a double tap: press Fn to finish |
| ![Transcribing](images/overlay-transcribing-light.png) | Transcribing and cleaning up |
| ![Scribe rewriting](images/overlay-scribe-rewriting-light.png) | Scribe rewriting |
| ![Text copied](images/overlay-copied-light.png) | The app doesn't accept typing, such as a password field: press ⌘V to paste |

As soon as the text is in your app, the overlay disappears. The menu bar menu shows how long the last dictation took.

**Drag it anywhere** while it is visible. It never takes the focus from the app you are typing in, its position is remembered across restarts, and if its screen goes away (you unplug a monitor) it moves back onto a visible one. **Settings › General › Reset position** puts it back at the bottom center.

## Style

**Settings › Style** decides how diVoice writes in each kind of app, for dictation and for Scribe.

![Style](images/settings-style-light.png)

- **Tone:** for email, Formal, Cordial (the default) or Direct; for work chat, Professional, Direct (the default) or Informal; for personal chat, Natural or Informal; for documents and notes, Polished or Notes. Code and AI assistants always stay literal.
- **Your instructions:** a few words for each kind of app, such as "I use Lei with clients, and I sign Ada". They win over the tone.
- **Apps and websites:** diVoice recognizes most apps by itself. Assign any other app to a kind of app with **Add app…**, or a website by a word of its window title (for example "hubspot") with **Add website**.
- **Learned from your corrections:** when you fix a dictated text right after it's inserted, diVoice learns from it. A name or a term you correct goes into your dictionary, and the overlay says "Added to the dictionary". In a chat, what you change before pressing Return is caught just before the message is sent. After five corrections in a kind of app, diVoice notes in a few lines how you like to write there (greetings, sign-off, punctuation, formality), and from then on writes that way. You can edit those lines, **Forget** them, or turn learning off. The corrections stay on your Mac for 7 days at most.

## The dictionary

**Settings › Dictionary** holds the names, brands and terms diVoice should always spell right, with the forms it mishears them as.

![Dictionary](images/settings-dictionary-light.png)

- **Term:** the correct spelling, for example "Zentrix".
- **Heard as:** the wrong forms, separated by commas ("centrix, zen trix"). They are replaced automatically.
- **Note:** optional context for the AI ("product", "colleague").

Terms also guide the speech recognition itself, together with the names diVoice reads on screen when you start dictating. With a team, you also get your organization's dictionary, which the admin maintains. See [Your first dictionary](tutorials/your-first-dictionary.md).

## Statistics

**Settings › Statistics** (or **Team**, in an organization) shows, for today, the last 7 or 30 days, or all time:

- **Words dictated**;
- **Time saved:** typing the same words at your typing speed, minus the time spent speaking (set your speed at the bottom of the page; 40 words per minute by default);
- **Words per minute** while speaking;
- **Day streak**: consecutive days with at least one dictation.

![Statistics](images/settings-statistics-light.png)

Statistics count words and time, never what you said. In personal mode they stay on your Mac. In an organization they are kept by its server, so they follow you across Macs, and you can choose to **hide from the team**. See [Organizations](organizations.md#statistics-and-privacy).

## Settings

| Page | What's there |
|---|---|
| General | Shortcuts, dictation language, microphone and keeping it ready, sounds, clipboard, overlay position, login item, permission status |
| Models | Provider and model for transcription, cleanup and Scribe, your API keys, Verify (with an organization: its models, read-only) |
| Style | Tone and your own instructions for each kind of app, apps and websites assigned to a kind, what diVoice learned from your corrections |
| Dictionary | Your terms, and your organization's |
| History | Your dictations from the last 7 days, to copy one again or take back what you said before the cleanup |
| Statistics / Team | Your statistics, and with an organization the leaderboard |
| Organization | Your membership; for admins, the admin panel |
| Latency | The last dictations' timings: total, transcription, cleanup, and how many characters of context each one read on screen |

![General settings](images/settings-general-light.png)

**History** lists your dictations from the last 7 days, newest first, with the app they went into and the kind of app diVoice recognized (it decides the tone). **Copy** takes the text again; **What you said** shows the transcript before the cleanup or Scribe, to rewrite a dictation that came out badly: paste it, select it, and ask Scribe to rewrite it. The history stays on your Mac, and **Clear history…** deletes it.

![History](images/settings-history-light.png)

## The menu bar

The waveform icon in the menu bar shows diVoice's status ("Ready: hold Fn", or what's missing), how long your last dictation took and the median of the recent ones, and offers:

- **Paste last dictation**, if the text didn't land where you wanted;
- **History…**, to find an earlier dictation;
- **Settings…** and **Setup and permissions…**;
- **Check for Updates…**;
- the version, and **Quit**.

## Updates

diVoice checks for updates every six hours and offers them in a window; click **Install and Relaunch**. Updates are signed, notarized by Apple and verified before they install, and your permissions, keys and settings stay. Keep diVoice in the Applications folder: from anywhere else macOS doesn't let it update itself.

Builds distributed by an organization update from that organization's server; public builds update from GitHub Releases.
