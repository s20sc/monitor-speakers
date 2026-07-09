# Codex Code Review — monitor-speakers

- **Date**: 2026-07-09
- **Reviewer**: OpenAI Codex CLI (gpt-5.5, reasoning effort high), read-only sandbox
- **Scope**: `Sources/*.swift` — CoreAudio IOProc safety, aggregate lifecycle, memory, concurrency, error handling
- **Commit**: initial import (`c4ab1dc`)

## Critical

- **`Router.swift:51-53, 78-81, 95-97`** — the audio IOProc enters Swift object/runtime
  paths and allocates every render block (`[weak self]`, optional dispatch to `render`,
  `channelRefs` builds a `[ChannelRef]`, `matrix[index]` uses Swift `Dictionary`). Not
  real-time safe.
  *Fix*: preallocate render state, use a non-weak unmanaged context / C-style IOProc
  trampoline, precompute fixed channel/gain arrays, walk `AudioBufferList` without Swift
  collection allocation or dictionary lookup.
- **`Router.swift:131-133, 155, 164-165`** — `TonePlayer` has the same pattern: weak
  capture, allocated `channelRefs`, `Set.contains` in the render loop, per-frame `sin`.
  *Fix*: same preallocated callback state; replace `Set` with fixed booleans/range checks;
  phase oscillator/table — or keep it explicitly isolated as a non-production diagnostic.

## High

- **`Router.swift:18-19`** — buffers blindly interpreted as `Float32`; frames derived from
  `MemoryLayout<Float32>`. If the aggregate stream format is not 32-bit float interleaved,
  audio corrupts or buffer math is wrong.
  *Fix*: query/validate each stream's `AudioStreamBasicDescription` before start; require/set
  32-bit float PCM; compute frames from actual `mBytesPerFrame`.
- **`Config.swift:76-83`, `main.swift:139-149, 207-210`** — channel mappings never validated
  against aggregate output channel count; bad config or fewer monitors silently routes to
  nonexistent outputs.
  *Fix*: before `map` save and before `run`, require non-negative pair starts,
  `pair + 1 < aggregate.outputChannels`, no unintended duplicates.
- **`main.swift:77-83`** — `setup` creates the aggregate before `config.save()`; if save
  fails, the aggregate leaks while setup reports failure.
  *Fix*: on any post-create failure, destroy the just-created aggregate before returning.

## Medium

- **`AutoSwitch.swift:28-32`** — property listener block is never removable (block/address
  not retained; no `stop`/`deinit` calling `AudioObjectRemovePropertyListenerBlock`).
  *Fix*: store block + address, add `stop()`, remove listener, cancel `pending`, call from shutdown.
- **`main.swift:241-244`** — shutdown only stops the router; auto-switch listener/timer not
  cleaned before `exit`.
  *Fix*: call `autoSwitcher?.stop()` and cancel the diagnostic timer before exit.
- **`Router.swift:40, 93`, `main.swift:231`** — `inputPeak` written by the audio callback,
  read on main queue without atomics; "torn reads acceptable" is still a Swift data race.
  *Fix*: store bit pattern in a lock-free atomic integer, or drop it from the audio path.
- **`main.swift:63-65`** — `setup` proceeds when monitor count ≠ 3 though default mapping
  assumes three pairs.
  *Fix*: fail unless `monitors.count == requiredMonitors`, or generate/validate a mapping
  for the detected count.

## Low

- **`AudioDevices.swift:183-188`, `Router.swift:49`** — buffer-frame-size errors ignored.
  *Fix*: make `setBufferFrameSize` throwing; fail startup or log off the audio thread.
- **`AudioDevices.swift:160-167`** — `defaultOutputDevice()` ignores failure, returns `0`.
  *Fix*: make it throwing/optional; handle failure in `AutoSwitcher`.
- **`Router.swift:156`** — test tone hardcodes `48000.0`.
  *Fix*: query `kAudioDevicePropertyNominalSampleRate` before starting the tone.
