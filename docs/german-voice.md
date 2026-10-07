# German calls

German calls need three things that English calls get by default: a German voice, multilingual speech
recognition, and a fast Hermes route for the phone. This page explains how each one is set up, how to
deploy and roll back on an existing Proxmox container, and what was measured.

```
phone ⇄ bridge: Silero VAD → faster-whisper small (de, beam 2) → Hermes "voice-fast" (no reasoning)
                                                                    ↓ first clause, then sentences
             phone ← aiortc ← hermes-call-tts 127.0.0.1:8881 (Kokoro German, dm_thorsten, 24 kHz PCM)
```

## The German voice

Kokoro-FastAPI cannot speak German, for two reasons:

- Kokoro-82M's official languages are a/b (English), e, f, h, i, p, j and z. There is no German.
- Kokoro-FastAPI checks `lang_code` against that list.

`bm_george` reading German therefore uses English phonemes, which is why German calls sounded wrong.

German Kokoro fine-tunes do exist. Each one is a full 82M model, served by `tts/` (`hermes-call-tts`) through the same OpenAI-style
`/v1/audio/speech` the bridge already speaks (16-bit mono PCM, 24 kHz):

| Voice | Model (pinned revision) | Trained on | Notes |
|---|---|---|---|
| `dm_thorsten` (default) | Thorsten-Voice/Kokoro `734e593d…`, epoch 5 | 12,283 real recordings (Thorsten-Voice, CC0) | neutral male; its author judged epoch 5 the most natural |
| `df_victoria` | kikiri-tts/kikiri-german-victoria `ce81e200…` | 455 synthetic samples | female |
| `dm_martin` | kikiri-tts/kikiri-german-martin `1e9dcd16…` | 627 synthetic samples | male |

How the voice is built and pinned:

- **G2P.** Text becomes phonemes through misaki's German G2P. It spells out numbers, dates, times, currency and abbreviations, then runs espeak-ng from the distribution.
- **Short ü.** The phoneme `ʏ` is mapped to `y`, because Kokoro has no symbol for it.
- **Pinning.** The kokoro and misaki forks (semidark) are pinned by commit. The wheels are pinned by SHA-256 (`tts/requirements.lock`). Every model file is pinned by revision and SHA-256.
- **Network.** The service listens on loopback only. Its systemd unit denies all IP traffic except localhost.

Alternatives considered:

- **Piper.** Its German voices are the lower-risk fallback: `thorsten-medium` is 22 kHz, and the female voices are 16 kHz only. They sound noticeably more synthetic, and Piper has no OpenAI-compatible endpoint of its own.
- **ONNX exports.** The German Kokoro ONNX exports have no streaming API and pin a single voice.

**Streaming.** Kokoro-FastAPI synthesizes text in chunks of 175–250 tokens and yields each chunk only once it is complete, so a short reply arrives in one piece. The bridge therefore never sends a whole answer. It sends the first clause as soon as the agent has written it, then one sentence per request. The time to the first audio is the synthesis time of that first clause.

The German chunker has two rules:

- It does not cut after ordinals or abbreviations ("am 3. Oktober", "Dr. Schneider").
- A long first sentence is cut before a joining word ("und", "weil", "dass" …), not after six words. German verbs often come last, so a cut in the middle sounds broken.

## Install on the existing container (CT107)

Steps 1–5 run on the Proxmox host. Nothing here opens a port; the German speech service listens on 127.0.0.1:8881. Run them in order.

1. Snapshot the container and back up the configuration:

   ```bash
   pct snapshot 107 pre-german-voice
   ```

   ```bash
   pct exec 107 -- cp -a /etc/hermes-call-bridge/bridge.toml /root/bridge.toml.pre-german
   ```

2. Fetch this version into the container. Until it is in a signed release, use the main branch:

   ```bash
   pct exec 107 -- git clone --depth 1 https://github.com/Quavon-dev/hermes-call.git /root/hermes-call-main
   ```

3. Install the German speech service. It loads one voice, about 1–1.3 GB of memory. Add `,df_victoria` to `--voices` to load the female voice as well.

   ```bash
   pct exec 107 -- bash /root/hermes-call-main/tts/install.sh install --voices dm_thorsten --threads 4
   ```

4. Add the fast phone route to Hermes. As the Hermes user, add the following to `~/.hermes/config.yaml`. The regular Hermes model stays as it is; only calls use `voice-fast`. Use your fast model and provider.

   ```yaml
   gateway:
     platforms:
       api_server:
         model_routes:
           voice-fast:
             model: <fast model id>
             provider: <provider slug>
   ```

   Then restart Hermes' gateway the way you normally do. Check that the route is live: `GET /v1/models` on 127.0.0.1:8642 must list `voice-fast`.

   With a route alias, the bridge must not send a provider of its own (Hermes answers 400 when they disagree), so keep `provider = ""`.

5. Switch the bridge to German. Everything not named here keeps its installed value:

   ```bash
   pct exec 107 -- bash /root/hermes-call-main/bridge/install.sh update --language de \
     --tts-url http://127.0.0.1:8881 --voice dm_thorsten --tts-speed 1.05 \
     --stt-model small --stt-beam-size 2 --end-silence-ms 500 --barge-in false \
     --ack-after-ms 1800 --hermes-model voice-fast --reasoning-effort none
   ```

6. Verify:

   ```bash
   pct exec 107 -- hermes-call-bridge doctor
   ```

   ```bash
   pct exec 107 -- hermes-call-bridge voice-bench --speed 1.0 --speed 1.05 --speed 1.1 --hermes 10
   ```

   ```bash
   pct exec 107 -- journalctl -u hermes-call-bridge -f
   ```

   - `doctor` must show `voice ok` and `language ok`.
   - `voice-bench` prints first-audio and real-time factor per speed, the recognition round trip per beam size, and Hermes' time to first text.
   - During a call, every turn logs `turn timings: utterance … stt … llm first text … end of speech to first answer audio …`.
   - To try the female voice, install it (step 3) and compare: `voice-bench --voice dm_thorsten --voice df_victoria`. The voice that sounds more natural on your phone becomes `--voice`.

## Roll back

- **Configuration only.** This brings back `bm_george`, port 8880 and the previous Hermes model:

  ```bash
  pct exec 107 -- bash -c "cp -a /root/bridge.toml.pre-german /etc/hermes-call-bridge/bridge.toml && systemctl restart hermes-call-bridge"
  ```

  The older configuration still loads: `stt.language = "de"` counts as the call language. `doctor` warns that `bm_george` is an English voice.

- **Code.** Reinstall the last release:

  ```bash
  pct exec 107 -- bash -c "curl -fsSL https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/bridge/get.sh | HC_ALLOW_DOWNGRADE=1 bash"
  ```

  Then restore the backed-up `bridge.toml` as above.

- **German speech service.** Remove it. Add `--purge` to delete the models as well:

  ```bash
  pct exec 107 -- bash /root/hermes-call-main/tts/install.sh uninstall
  ```

- **Everything at once:**

  ```bash
  pct rollback 107 pre-german-voice
  ```

- **Hermes.** Remove the `voice-fast` block and restart the gateway. The rest of Hermes was not changed.

## Recommended production configuration

```toml
[hermes]
url = "http://127.0.0.1:8642"
session_id = "hermes-call-phone"
model = "voice-fast"
provider = ""
reasoning_effort = "none"

[tts]
url = "http://127.0.0.1:8881"
voice = "dm_thorsten"
speed = 1.05

[stt]
model = "small"
model_dir = "/var/lib/hermes-call-bridge/models"
threads = 4
beam_size = 2
initial_prompt = ""

[voice]
language = "de"
end_silence_ms = 500
barge_in = false
acknowledgement_after_ms = 1800
acknowledgement_text = ""
```

Settings worth confirming on the host:

- **Speed.** Confirm 1.05 with `voice-bench` and by listening. Natural German conversation is about 13–16 characters per second.
- **Vocabulary prompt.** Use `initial_prompt` only if names keep being misheard, for example `"Hermes, Home Assistant, Enclessa, Quavon"`.

## Measurements

What was measured where:

- **Measured off the container.** Speech recognition, on an M1 Max with 4 threads (`cpu_threads=4`, int8) and the pinned `small` model.
- **Corpus.** 16 German phrases, each spoken by 4 macOS German voices, 64 turns in total:
  - The phrases are the requested ones plus numbers, times, names and smart-home commands.
  - "Anna" is the natural voice. The other three are deliberately poor novelty voices, used as a stress test.
  - Each clip had about 0.3 s of silence around the speech.
- **Expected on the container.** A 4-vCPU container is roughly 1.5–2.5× slower per core, so absolute times there will be higher. The comparisons between settings hold.
- **Not measured off the container.** Speech synthesis, Hermes and the end-to-end latency need the container's own Kokoro, German model and Hermes route. `voice-bench` and the per-turn log line measure them there.

| Recognition (small, de) | Word errors, Anna (16) | Word errors, all (64) | Latency median | p95 | max |
|---|---|---|---|---|---|
| before: beam 3, temperature fallback | 4.9 % | 18.9 % (15.6 % in a second run) | 863 ms | 1108 ms | 3825 ms |
| beam 1 | 4.9 % | 18.4 % | 791 ms | 1264 ms | 2950 ms |
| beam 2, temperature fallback | 4.9 % | 16.4 % | 914 ms | 1575 ms | 4010 ms |
| **after: beam 2, one greedy decode** | 4.9 % | 16.4 % | 849 ms | 1049 ms | 1687 ms |
| beam 2 + vocabulary prompt | 3.3 % | 13.9 % | 889 ms | 2760 ms | 4500 ms |

What the numbers show:

- **Beam size.** No beam size is meaningfully more accurate than another. Beam 3 even varied between runs (CTranslate2 threading), while beam 2 gave the same result twice. Beam 2 is the default.
- **Temperature fallback.** For short live utterances, the fallback only re-decodes doubtful audio. It cut no errors but caused every slow outlier: the maximum dropped from 4.0 s to 1.7 s without it. Live turns now decode once; voice notes keep the fallback.
- **Vocabulary prompt.** It fixed "Enclessa" and "Quavon". It also made Whisper insert a name ("Livia") into two noisy clips and tripled p95, so it stays optional.
- **Remaining errors with the natural voice:**
  - "morgen" heard as "morden"/"Norden", mostly in the short first word of a clip.
  - "Schreib" heard as "Schreibt".
  - The two invented names.
- **Speculative recognition.** It starts 250 ms into the closing silence. With a 500 ms end of utterance, about 250 ms of recognition is already done when the turn ends.

Turn-taking before and after, all on the same code paths:

| Stage | Before | After |
|---|---|---|
| End of utterance | 550 ms | 500 ms; a pause followed by more speech before the answer plays still joins one turn |
| Recognition tail | beam 3 with fallback, outliers to ~4 s | beam 2, one decode |
| Hermes | regular model with reasoning | `voice-fast`, reasoning off (measure with `voice-bench --hermes 10`) |
| First audio | English Kokoro reading German; first clause of at most 6 words | German Kokoro; first clause up to a joining word |
| Slow turn | silence, unless configured otherwise | "Einen Moment." once, 1.8 s after you stopped, or when a tool starts |
| Speakerphone echo | ignored while the bridge was sending audio | also ignored for 400 ms afterwards, and in phone transcripts |

The target is the first answer audio within about 2–3 s of the end of speech for a simple turn. It is reached when `voice-fast` answers in under about 1.2 s; `voice-bench --hermes 10` shows whether it does.

## Speaker echo and full-duplex barge-in

`barge_in = false` stays the recommended speakerphone setting.

- **AEC is not enough.** The phone's voice-processing echo cancellation (AVAudioEngine) removes most of the agent's voice, but on loud speakerphone enough remains for Silero VAD to detect speech and for Whisper to transcribe it.
- **The tail.** The leakage continues after the bridge's buffer empties: the phone's jitter buffer and the network delay the last ~100–300 ms, plus room reverberation. That is the reason for the 400 ms echo tail.

Options for full-duplex barge-in that is not fooled by echo, roughly in order of promise:

1. **Reference-based echo detection on the bridge.** The bridge knows exactly what it played. Correlate the incoming microphone audio with that output, delayed by the measured round trip. Count a frame as owner speech only when its energy clearly exceeds the predicted leak, for example by 10 dB, for at least about 200 ms.
2. **Phone-side decision.** The phone has the cleanest signal: after AEC, with its own voice-processing VAD and `isVoiceProcessingInputMuted`. It could send an explicit "owner speech" event instead of the bridge guessing from leaked audio.
3. **Confirmation window.** On a suspected interruption, duck the agent's audio first and stop it only when recognition of the first ~500 ms yields words that are not in the agent's current sentence.

None of these is safe as a default without field data from real phones and rooms. They belong behind a separate setting, after `voice-bench`-style recordings of actual leakage.
