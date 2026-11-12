# Troubleshooting

Start with **Settings › Models › Verify**: it checks each step with your key and model and tells you which one fails and why.

## Holding Fn does nothing

- **Accessibility is off.** diVoice needs it to see the key. **System Settings › Privacy & Security › Accessibility**: turn diVoice on. If it's already on, turn it off and on again (macOS sometimes keeps a stale entry after an update from a differently signed build).
- **The 🌐 key does something else.** In **System Settings › Keyboard**, set **Press 🌐 key to** to **Do Nothing**. Otherwise macOS opens the emoji picker or switches input source.
- **A double tap of Fn also opens macOS's dictation.** That's the **Start Dictation (Press 🌐 Key Twice)** choice of the same setting: set **Press 🌐 key to** to **Do Nothing**.
- **Hands-free doesn't start.** The two taps must be quick: each shorter than about a third of a second, and the second within 0.4 s of the first. A slower first tap counts as a short dictation.
- **External keyboard without Fn.** Hold **right ⌘** instead (changeable to right ⌥ in **Settings › General**).
- **You tapped instead of holding.** A single quick tap is ignored, so a tap of Fn keeps working as before. Two quick taps start hands-free dictation: press Fn once more to finish.
- **The first words are cut.** Turn on **Settings › General › Keep the microphone ready**. With a Bluetooth headset it stays off, so wait for the start sound, or choose the Mac's microphone in **Settings › General**.
- **Another key was pressed with Fn.** Fn plus another key is a shortcut (Fn+arrows, Fn+F keys), so diVoice cancels the dictation.

## The overlay shows an error

| Message | What to do |
|---|---|
| **Microphone not available** | Allow diVoice in **System Settings › Privacy & Security › Microphone**, and check that an input device is connected. |
| **Mistral API key missing** (or OpenAI) | Paste your key in **Settings › Models**. |
| **OpenAI-compatible server address missing** | Type your server's address in **Settings › Models › API keys**, for example `http://localhost:4000`. |
| **… HTTP 401** | The key is wrong or revoked. Paste it again in **Settings › Models** (in an organization, tell your admin). |
| **… HTTP 404** | The model name is misspelled or your account can't use it. Pick one from the list, then Verify. |
| **… HTTP 429** | The provider is limiting your account. Wait a minute, or raise your limits in the provider's console. |
| **I didn't hear anything** | The recording was silent. Check the input device in **System Settings › Sound** and the microphone chosen in **Settings › General**. |
| **The organization's server did not answer in time** | Check your network; if it persists, tell your admin. |
| **Scribe didn't answer: I inserted your dictation without rewriting it** | Scribe ran out of time or failed, so your dictation went in as you said it, tidied but not rewritten. History marks it **Not rewritten**. Select the text and ask Scribe again. If Scribe was editing a selection, nothing is inserted: what you said is in History. |
| A network error | Dictations aren't queued: dictate again once you're online. |

When the text was produced but didn't land where you wanted, **Paste last dictation** in the menu bar inserts it again. Once the transcription is done, a dictation isn't lost even if the cleanup or Scribe fails: the transcript goes in instead, and it's in **History**.

## The text doesn't appear

- **Password fields** don't accept typed text: diVoice copies it and shows "Text copied: press ⌘V".
- Some apps (remote desktops, a few games and terminals) ignore synthesized input. Press ⌘V: the text is on the clipboard.
- If nothing appears anywhere, check **Accessibility** as above.

## The text is wrong

- **Names and terms misspelled:** add them to **Settings › Dictionary**, with the forms they're misheard as in **Heard as**. See [Your first dictionary](tutorials/your-first-dictionary.md).
- **The cleanup changed too much or too little:** the cleanup keeps your words and only fixes what speech recognition and speaking add. If it rewrites, try the other provider's model in **Settings › Models**. For a deeper edit, use Scribe (Ctrl+Fn).
- **The language changed:** diVoice tells the cleanup the language it detected and falls back to the raw transcript if the result looks translated. If it happens often, please [open an issue](https://github.com/tommasoseita/divoice/issues/new/choose) with the app and the language.

## It's slow

**Settings › Latency** shows the timings of your last dictations, and Verify measures each step.

- **Connection** over 300 ms: a slow network or VPN.
- **First token** over 1.5 s in cleanup: try fast processing (OpenAI) or predicted outputs (Mistral), or a smaller model.
- Very long dictations take longer to transcribe at release; for long dictations, the **Streaming** mode finishes sooner.

See [Latency](latency.md) for what to expect.

## Creating an organization

- **"No server answers at this address yet"**: a new `workers.dev` address can take up to an hour to start working (until then Cloudflare shows "error code: 1042"). Check that you pasted the address Cloudflare showed at the end of the deploy, wait a few minutes and click **Check** again.
- **"SERVER_SECRET isn't set on this server yet"**: the deploy form's secret field was left empty. In Cloudflare, open your Worker › **Settings › Variables and Secrets**, add `SERVER_SECRET` with the secret diVoice shows, and check again.
- **"The server was deployed with a different secret"**: set `SERVER_SECRET` in the same place to the secret diVoice shows (`DIVOICE_SECRET` on servers set up before diServer), then try again.
- **"This server already has an admin"**: someone created the organization first. Ask them for an invite. If it was you on another Mac, see [Recovering admin access](https://github.com/tommasoseita/diServer/blob/main/docs/setup.md#recovering-admin-access) in diServer's guide.

## Joining an organization

- **diVoice didn't offer to join after installing:** it reads the invite from the disk image's name, so the image must still be open at the first launch. Open the invite link again and click **I already have diVoice: open it**.
- **"This invite can't be used"**, with the reason ("has expired", "was already used", "was revoked"): ask your admin for a new one. Personal links work once.
- **"This email is already a member"**: team links can't reconnect an existing member. Ask your admin for a **personal link**.
- **"This invite is for other addresses"**: an email invite works only with the addresses it was sent to. Check the email you typed.
- **"You are no longer a member"**: an admin removed your account, and diVoice is back in personal mode.

## Updates

- **"Move diVoice to the Applications folder":** quit diVoice, drag it from the disk image (or Downloads) onto **Applications**, and open it from there. macOS runs apps outside Applications from a temporary copy that can't be updated.
- **Permissions asked again after an update:** this shouldn't happen with official builds, which keep the same signature. If you built diVoice yourself, each build with a different certificate looks like a new app to macOS.

## Collecting logs

diVoice logs versions, permissions, timings and errors, never what you dictated:

```bash
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "app.wibo.divoice"'
```

To watch them live while you reproduce a problem:

```bash
/usr/bin/log stream --style compact --predicate 'subsystem == "app.wibo.divoice"'
```

Attach the output to your [bug report](https://github.com/tommasoseita/divoice/issues/new/choose). Read it first: it contains app names and your organization's server address.

## Starting over

To reset diVoice completely, quit it and run:

```bash
defaults delete app.wibo.divoice
```

```bash
rm -rf ~/Library/Application\ Support/DiVoice
```

Then remove its keys in **Keychain Access** (search for "divoice") and turn its permissions off in **System Settings › Privacy & Security**. This deletes your dictionary, history and statistics.
