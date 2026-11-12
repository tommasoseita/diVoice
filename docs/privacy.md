# Privacy

diVoice is built so that your words go only where they must: to the AI provider that turns them into text. There is no diVoice cloud service, no account, no analytics and no telemetry.

## What leaves your Mac

Only while you hold the dictation key, and only for that dictation, plus the occasional short request that learns from your corrections (see below).

| Sent to | In personal mode | In an organization |
|---|---|---|
| **Transcription provider** | The audio of the dictation, your dictionary terms and the names found on screen (to spell them right); with ElevenLabs while streaming, also the text already in the field | The same, through your organization's server |
| **Cleanup provider** | The transcript, the name of the app you're typing in and its category (email, chat, code…), the style for it (with your own instructions and learned preferences), your dictionary, whether the text goes mid-sentence, and the **text on screen** (below) | The same, through your organization's server |
| **Scribe provider** (Ctrl+Fn) | Your dictation, your name and organization, the app and its window title, the **selected text** if any, the **text on screen**, your dictionary, and the previous turns of the same Scribe session | The same, through your organization's server |
| **Cleanup provider, to learn** | A word you corrected and the sentence around it, or five of your corrections in one kind of app (as diVoice wrote them and as you left them), to sum up how you like to write | The same, through your organization's server, during your next dictation |
| **Your organization's server** | Nothing | For each dictation: word count, audio length, local day, typing speed, app category, timings. Never the text. |

Your API keys are sent only to their own provider. If you choose an OpenAI-compatible server for cleanup or Scribe, what the table lists for those steps goes to the address you typed, with the key you saved for it: where it goes from there depends on that server. Over plain `http`, which diVoice accepts only for your Mac and private network addresses, they travel unencrypted on that network.

The audio is captured only while the key is held; diVoice never listens in the background. The overlay shows a recording indicator whenever the microphone is in use.

## What diVoice reads on your Mac

With the Accessibility permission, when you start a dictation diVoice reads:

- the **active app** and its **window title**, to pick a style (an email is not a chat message);
- the **selected text**, used only by Scribe;
- up to **three characters before the cursor**, to decide spacing and capitalization. They are never sent anywhere.
- the **text on screen** (unless you turn off **Settings › General › Use the text on screen as context**): up to 1,000 characters before the cursor in the field you're typing in, and up to 2,000 characters of the window around it, such as the thread you're replying to, its recipient and subject. It goes to the AI provider with that dictation only, to spell names and match the conversation, and is never saved or logged. Password fields are never read. In Chrome-based browsers and in apps such as Slack and Notion, diVoice asks the app to expose its page to Accessibility, as screen readers do.

Each read has a short timeout and happens only at the start of a dictation. Then diVoice pastes the text into the app and restores your clipboard as soon as the app has read it.

**After the insertion**, if **Learn from my corrections** is on (Settings › Style), diVoice reads the same field once a second until you move to another field or app, for two minutes at most, to see what you changed in the dictated text. Only that change is kept.

## What stays on your Mac

| What | Where | Kept for |
|---|---|---|
| API keys, organization token | macOS Keychain, readable only by diVoice | Until you remove them |
| History (text of recent dictations) | `~/Library/Application Support/DiVoice/history.json` | 7 days, at most 500 dictations |
| Personal dictionary | `~/Library/Application Support/DiVoice/dictionary.json` | Until you delete the terms |
| Corrections waiting to be learned (the dictated text and your corrected version) | `~/Library/Application Support/DiVoice/learning.json` | 7 days at most, deleted once learned |
| Preferences learned from your corrections (a few lines per kind of app) | `~/Library/Application Support/DiVoice/learning.json` | Until you **Forget** them in Settings › Style |
| Statistics (daily counts, no text) | `~/Library/Application Support/DiVoice/stats.json` | Indefinitely |
| Settings | macOS preferences | Until you change them |

The history is what **Paste last dictation** and **Settings › History** use. To delete it, click **Clear history…** on that page. Your statistics stay, since they hold no text.

diVoice's logs (in macOS's unified log) record versions, permissions, timings and errors. They never contain what you dictated or your keys.

## Organizations

In an organization, the server run by your organization relays dictations to the provider, so your organization, not the diVoice project, is responsible for it.

- It keeps the audio **in memory for the length of the dictation**, then discards it. It never stores audio, transcripts or the cleaned text.
- It stores your name and email, your role, and the counts listed above.
- Admins see the member list. Your statistics are visible to the others only if the admin enabled the leaderboard and you haven't chosen **Hide me from the team**.

See [What the server stores](https://github.com/tommasoseita/diServer/blob/main/docs/setup.md#what-the-server-stores) in diServer's documentation for the exact tables.

## The AI providers

What happens to your data at the provider is governed by their terms for API use. Read them before choosing:

- Mistral: [legal terms](https://mistral.ai/terms/) and [privacy policy](https://mistral.ai/terms/#privacy-policy)
- OpenAI: [API data usage](https://openai.com/policies/api-data-usage-policies) and [privacy policy](https://openai.com/policies/privacy-policy)
- ElevenLabs (transcription only, if you choose it): [terms](https://elevenlabs.io/terms-of-use) and [privacy policy](https://elevenlabs.io/privacy-policy). ElevenLabs keeps request logs unless an enterprise agreement turns that off.

Both offer EU data processing options for business accounts. An organization can point the server at Mistral's EU endpoint (`MISTRAL_BASE_URL`) and keep its database in the EU (see [Where the data lives](https://github.com/tommasoseita/diServer/blob/main/docs/setup.md#where-the-data-lives) in diServer's guide).

## Updates

diVoice checks for updates every 6 hours with [Sparkle](https://sparkle-project.org): it downloads a list of versions (the appcast) from GitHub, or from your organization's server for builds it hosts. The request carries no identifier beyond what any web request does. Updates are verified with an EdDSA signature and Apple notarization before they install.

## Reporting a problem

If you find a way diVoice exposes more than described here, please report it privately: see [SECURITY.md](../SECURITY.md).
