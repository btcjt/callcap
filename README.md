# callcap

Records a call as **two separate audio channels** — the far end and your
microphone — and turns it into a speaker-attributed transcript.

Works with any macOS app that plays audio: Signal, Zoom, a Google Meet tab,
a phone call bridged through the Mac, a podcast you want notes on. Everything
runs locally — whisper.cpp on the GPU, no audio and no transcript leaves the
machine.

Speaker attribution is **not** diarisation. The two parties are captured on
physically separate streams, so who said what is known exactly rather than
inferred — which is what makes the transcripts trustworthy enough to feed to
an LLM without reading them first.

## Install

Requires macOS 13+, Xcode command line tools, and:

```bash
brew install whisper-cpp ffmpeg jq
curl -L --create-dirs -o ~/.cache/whisper-cpp/ggml-large-v3.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin

./setup-signing-identity.sh   # once per machine
./build.sh                    # after any source change
```

Add `~/.local/bin` to `PATH`, then grant **Screen & System Audio Recording**
and **Microphone** to *Call Capture* in System Settings › Privacy & Security.
The first run triggers both prompts.

```bash
callcap-rec --permissions     # reports both grants; requests what is missing
callcap-check                 # 20s smoke test, per-channel levels
```

## Use

```bash
callcap --with "David"                      # capture all system audio
callcap --with "David" --app "Google Chrome"  # just one app
callcap --with "Ana" --mic "USB audio"        # pick the input device
callcap --with "Sam" --no-transcribe          # record now, transcribe later
callcap-transcribe latest --them "Sam"        # transcribe an earlier recording
```

Ctrl-C stops the recording; transcription then runs automatically (~9× realtime
per channel, so a 30-minute call takes about 7 minutes for both).

Output lands in one directory per call:

| File | What |
| ---- | ---- |
| `transcript.md` | speaker-labelled, timestamped — the thing you feed an LLM |
| `transcript.json` | same content structured, plus the speaking-time split |
| `call.m4a` | stereo archive, **left = far end, right = you** |
| `recording.json` | capture metadata + the inter-stream clock offset |

Capturing **all system audio is the default** because it works without knowing
which app owns the call — the failure mode of guessing wrong is a silent
recording you discover afterwards. `--app` is more precise when you do know:
it excludes music and notification sounds, but a browser call still picks up
every other tab.

## Configure

`~/.config/callcap/config.env`, created on first build from
[`config.env.example`](config.env.example) and never overwritten:

| Setting | Default |
| ------- | ------- |
| `CALLCAP_DIR` | `~/Documents/call-recordings` |
| `CALLCAP_ME` | first word of your account's full name |
| `CALLCAP_MIC` | system default input |
| `CALLCAP_APP` | empty — all system audio |
| `CALLCAP_SILENCE_TIMEOUT` | `5` minutes (`0` disables) |
| `CALLCAP_MAX_DURATION` | `180` minutes (`0` disables) |
| `CALLCAP_MODEL` / `CALLCAP_LANGUAGE` / `CALLCAP_THREADS` | large-v3 / `en` / performance cores |

`~/.config/callcap/vocabulary.txt` holds jargon, product names and people that
whisper should expect. Add anything that transcribes wrong twice.

## Stopping

Ctrl-C, always. Failing that it stops itself after **5 minutes with no audio on
either channel**, and unconditionally at **3 hours** — so a forgotten recording
cannot fill the disk. Both are tunable per-run (`--silence-timeout`,
`--max-duration`, in minutes) or disabled together with `--no-auto-stop`.

Silence means below −45 dBFS on both channels, so room tone is not mistaken for
conversation. A noisy room can hold a recording open, which fails safe.

## Housekeeping

```bash
callcap-rec --list-apps            # bundle ids of running apps
callcap-rec --list-audio-devices   # flags removable aggregate/multi-output devices
callcap-rec --remove-aggregate "Multi-Output Device"
./selftest.sh                      # end-to-end, on synthesised audio
```

## Caveats

- **You start it manually.** No auto-detection; nothing records unless you ran
  a command.
- **Closing the terminal ends the recording**, though SIGHUP is handled so what
  was captured is finalised rather than lost.
- **Nothing is captured if the call happens on your phone.** This records what
  the Mac plays.
- **Idle sleep would end a capture**, so recordings run under `caffeinate -i`.
  Closing the lid still sleeps the machine.
- **Raw audio is bulky while recording** — roughly 1.75 GB/hour across both
  channels — until transcription replaces it with a ~28 MB/hour `call.m4a`.
- **Nothing recovers audio nobody captured.** `callcap-check` before a call
  that matters is the cheap insurance.
- **Recording other people is your responsibility.** Tell them; some
  jurisdictions require it.

## How it works

```
target app ──audio──▶ ScreenCaptureKit  ──▶ far.wav  ─┐
                                                      ├─▶ whisper ×2 ─▶ merge ─▶ transcript.md
microphone ──audio──▶ AVCaptureSession  ──▶ near.wav ─┘
```

`recording.json` carries `nearOffsetSeconds`, the host-clock delta between the
first sample of each stream. [`transcribe.sh`](transcribe.sh) pads the
later-starting track by that amount so both share a `t=0`.

## Decisions + gotchas

Most of these cost real debugging time; they are recorded so they cost it once.

- **No virtual audio driver.** The obvious build — BlackHole plus a
  Multi-Output Device — routes *system-wide* audio through a fake device,
  disables hardware volume control while active, forces an output-device switch
  at the start of every call, and leaves permanent clutter in Audio MIDI Setup.
  ScreenCaptureKit needs no driver and changes nothing about your audio setup.
- **It ships as an `.app`, not a bare binary,** because macOS attributes TCC
  grants to the enclosing bundle. A loose CLI pushes Screen Recording
  permission onto Terminal/VS Code instead — broader than intended, and it
  breaks whenever you switch terminals.
- **TCC attributes the grant to the "responsible process".** A binary spawned
  from a shell inherits the *terminal* as responsible, so macOS checks the
  grant against Terminal and ignores the one on this app — the toggle is on and
  capture is still denied. The binary re-execs itself with
  `responsibility_spawnattrs_setdisclaim` to own its TCC identity. Symptom if
  this regresses: `open -a "Call Capture"` works while the shell command does not.
- **Signed with a local certificate, not ad-hoc.** An ad-hoc signature's
  designated requirement is the cdhash, so *every rebuild* silently revokes the
  permission. If a rebuild ever does revoke it, `tccutil reset ScreenCapture
  com.callcap.recorder` gives a clean prompt rather than a stale entry to fight.
- **Microphone access needs the `com.apple.security.device.audio-input`
  entitlement** under the hardened runtime. Without it the prompt is
  auto-denied and the mic yields silence — indistinguishable from a missing
  grant.
- **The microphone uses AVCaptureSession, not AVAudioEngine.** The engine's
  input tap started without error and delivered zero buffers — a silent
  recording with nothing logged. AVCaptureSession is also the subsystem TCC
  governs, and its buffers share ScreenCaptureKit's host clock.
- **Recording with a Bluetooth mic changes what you hear.** Opening AirPods as
  an *input* forces them out of A2DP into headset mode — measured as their own
  output dropping 48 kHz → 24 kHz — which audibly changes volume mid-call and
  halves the quality of your recorded channel. The profile switch can also take
  tens of seconds, so the microphone stream is started *before* the app stream;
  a residual skew over 2s is reported as a warning. `CALLCAP_MIC` pointing at a
  wired input avoids all of it.
- **Ctrl-C reaches the whole foreground process group.** The wrapper traps it
  with a handler, never `trap ''` — an *ignored* signal is inherited by
  children, which would stop Ctrl-C reaching the recorder and make recordings
  unstoppable. Without any trap, the wrapper died alongside the recorder and a
  finished recording silently never became a transcript.
- **`volumedetect` reports at ffmpeg's *info* level.** Under `-v error` it
  yields no numbers and every channel — however loud — reads as silent.
- **`ffmpeg`'s `join` truncates to its shortest input**, which would clip the
  archive to whichever channel ended first, unrecoverably, since the raw WAVs
  are deleted right after. Both sides are padded and cut at the longer one.
- **Whisper snaps its first segment to `t=0`** regardless of leading silence,
  so `nearOffsetSeconds` shifts the audio but is not visible in the transcript's
  first timestamp.
- **Whisper hallucinates on silence** — "Thank you." and similar appear in long
  quiet stretches, which your own channel has plenty of while the other person
  talks. whisper.cpp's `--vad` largely fixes it and is not yet wired up.
- **The far end leaks into your room mic**, so a sentence can transcribe on both
  channels. `merge_transcript.py` drops the duplicate; the heuristic is text
  identity within a 1s window, so it is conservative and lets echoes through
  occasionally.
