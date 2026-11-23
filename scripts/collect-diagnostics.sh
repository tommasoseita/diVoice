#!/bin/sh
# Collects what's needed to understand a diVoice problem into diVoice-diagnostics.zip on the
# Desktop: diVoice's and the audio system's log messages of the last day, diVoice's crash and
# hang reports, where a running diVoice is (a 3-second sample, if it's stuck), the audio devices
# and the macOS version. Nothing that was dictated.
#
# For colleagues: open Terminal, type "sh " (with the space), drag this file into the window,
# press Return. Nothing to copy and paste, so chat apps can't spoil it.
#
#   sh collect-diagnostics.sh

D="$HOME/Desktop/diVoice-diagnostics"
rm -rf "$D" "$D.zip"
mkdir -p "$D" || exit 1
echo "Collecting diVoice's diagnostics, about 30 seconds..."

/usr/bin/log show --last 1d --info --predicate \
  'process == "DiVoice" AND (subsystem == "app.wibo.divoice" OR subsystem BEGINSWITH "com.apple.coreaudio" OR subsystem BEGINSWITH "com.apple.avfaudio")' \
  > "$D/log.txt" 2>&1
find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -maxdepth 1 -name 'DiVoice*' \
  -exec cp {} "$D/" \; 2>/dev/null

# A diVoice that's running but stuck: where it waits.
ps -axo pid,stat,etime,comm | grep -i '[d]ivoice' > "$D/processes.txt" 2>&1
if pgrep -x DiVoice > /dev/null; then
  /usr/bin/sample DiVoice 3 -file "$D/sample.txt" > /dev/null 2>&1
fi

/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/diVoice.app/Contents/Info.plist \
  > "$D/divoice-version.txt" 2>&1
system_profiler SPAudioDataType > "$D/audio.txt" 2>&1
sw_vers > "$D/macos.txt" 2>&1

cd "$HOME/Desktop" && zip -qr diVoice-diagnostics.zip diVoice-diagnostics && rm -rf "$D" \
  && echo "Done: diVoice-diagnostics.zip is on your Desktop."
