# Installing on a new Mac

Step-by-step guide to set up `monitor-speakers` on a fresh machine, including
the gotchas that are easy to miss. See `README.md` for how it works and the
full command reference.

> This is what merges the three LG monitor speakers into one output device
> called **LG TriSpeakers**. Apple Silicon (arm64) binary.

## 0. Prerequisites

- **Apple Silicon Mac** (the prebuilt `bin/monitor-speakers` is arm64; on Intel,
  rebuild with `make`).
- **Xcode Command Line Tools** — only needed if you rebuild from source:
  `xcode-select --install`
- The **LG monitors physically connected** so their speakers show up as audio
  output devices. `setup` fails without them (`no output devices matching 'LG'`).

## 1. Install BlackHole 2ch (virtual audio driver)

```sh
brew install --cask blackhole-2ch
```

No source? Download the installer from https://existential.audio/blackhole/

## 2. Restart CoreAudio so it sees BlackHole  ← easy to miss

A freshly installed HAL plugin is not picked up until `coreaudiod` restarts.
Without this, `setup` fails with `BlackHole device 'BlackHole 2ch' not found`
even though the driver file is present.

```sh
sudo killall coreaudiod        # audio blips for ~1s; equivalent to a re-login
```

Verify it is now recognized:

```sh
system_profiler SPAudioDataType | grep -i BlackHole
```

## 3. Get the binary

Use the prebuilt one in `bin/`, or rebuild:

```sh
make            # produces bin/monitor-speakers
```

## 4. Create the aggregate device

With the LG monitors connected:

```sh
bin/monitor-speakers setup             # creates "LG TriSpeakers"
bin/monitor-speakers test              # plays a tone per channel pair (2,4,6)
bin/monitor-speakers map 2 4 6         # only if left/center/right came out wrong
```

## 5. Auto-start at login (launchd agent)

```sh
bin/monitor-speakers install
```

This copies the binary to `~/Library/Application Support/monitor-speakers/`
(launchd must **not** point at an iCloud-synced path) and installs
`~/Library/LaunchAgents/com.monitor-speakers.router.plist`. Logs go to
`/tmp/monitor-speakers.log`.

## 6. Select the output

**System Settings → Sound → Output → LG TriSpeakers.**

On first run macOS prompts for **microphone** access (reading the BlackHole
loopback counts as audio input) — click **Allow**.

Done. From now on the agent auto-starts at login and, with autoswitch on,
flips the default output to the monitors when the dock/monitors connect.

---

## Config

`~/.config/monitor-speakers/config.json` — created/updated by the CLI, editable
by hand. Reference (the LG TriSpeakers setup):

```json
{
  "aggregateName"     : "LG TriSpeakers",
  "aggregateUID"      : "com.monitor-speakers.aggregate",
  "blackholeName"     : "BlackHole 2ch",
  "monitorNameFilter" : "LG",
  "leftPair"          : 4,
  "centerPair"        : 6,
  "rightPair"         : 2,
  "centerStereo"      : true,
  "masterGain"        : 1
}
```

- `monitorNameFilter` — substring used to find the monitors. Change if the new
  displays are not LG.
- `leftPair` / `centerPair` / `rightPair` — channel-pair start indices; fix with
  `test` + `map` if positions are swapped.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `BlackHole device 'BlackHole 2ch' not found` | CoreAudio hasn't loaded the driver → `sudo killall coreaudiod` (or re-login), then retry `setup`. |
| `no output devices matching 'LG' found` | Monitors not connected, or names don't contain "LG" → connect them / edit `monitorNameFilter`. |
| `aggregate not found — run 'monitor-speakers setup' first` (looping in log) | `setup` hasn't succeeded yet; the launchd agent restart-loops until it does. Run `setup` (needs monitors + BlackHole), then reload the agent. |
| No mic prompt / silent output | Grant microphone permission (System Settings → Privacy → Microphone). |

## Removing

```sh
bin/monitor-speakers uninstall     # remove the launchd agent
bin/monitor-speakers teardown      # destroy the aggregate device
brew uninstall --cask blackhole-2ch
```

## Moving between Macs without rebuilding

The three runtime files are: the binary
(`~/Library/Application Support/monitor-speakers/monitor-speakers`),
`~/.config/monitor-speakers/config.json`, and the LaunchAgent plist. But the
aggregate device itself is CoreAudio state that is **not** a file — always run
`setup` on the target machine after installing BlackHole. Simplest path on a new
Mac: copy this folder, then follow steps 1-6 above.
