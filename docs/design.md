# MATBridge design notes

Two parts of MATBridge are not obvious from the code: how it gets the system mix without counting as recording, and
how it lets Apple Music pass Dolby Atmos through. Both are described here with the measurements behind them.

# Getting the system mix to MATBridge

Apps play to the MATBridge virtual device. MATBridge needs that mix, all six channels and bit for bit, on the
device's own clock. It must not count as recording: macOS treats any process running audio input as microphone use.
That means a permanent orange indicator in the menu bar and a Microphone permission prompt, both wrong for a program
that never touches a microphone.

**Design:** the device has no input side. The driver publishes its output mix in shared memory, and MATBridge reads
it from an output-only IOProc on the device. The pieces are `driver/shared-memory-mix.patch`,
`kDevice_HasInput=false` in `scripts/build-driver.sh`, `Sources/CTrueHD/matbridge_shm.h` (the layout both sides
share), `thb_shm_*` in `Sources/CTrueHD/ctruehd.c` and `Capture` in `Sources/MATBridge/Devices.swift`.

## What counts as recording

The HAL publishes `kAudioProcessPropertyIsRunningInput` for each client process, and the microphone indicator follows
it. An IOProc counts as input as soon as the HAL hands it the device's input stream, whether or not it reads it:

| IOProc on the MATBridge device (measured, 1.5 s) | IsRunningInput | IsRunningOutput |
|---|---|---|
| Writes zeros to its output buffer, default stream usage | **1** | 1 |
| Same, with `kAudioDevicePropertyIOProcStreamUsage` (input scope) all off | **0** | 1 |

A loopback device read through its input side (the usual way to use BlackHole) therefore always shows the indicator.

Having input streams at all is enough for the permission check. coreaudiod checks Microphone access
(`kTCCServiceMicrophone`, a real request, not a preflight) for every app that starts IO on a device with input
streams, even an output-only AUHAL that never reads input. An app with a usage string and no decision yet gets the
macOS prompt, and its IO doesn't start until the prompt is answered. Apps without one, such as Music, are refused
silently on every start. Measured with the unified log (`tccd`, `AUTHREQ_CTX ... preflight=no`):

| Output IO started on | Microphone check | Prompt (no decision yet) |
|---|---|---|
| The device with BlackHole's input side: Chrome, AUHAL, plain IOProc, IOProc with input usage off | yes | yes (Chrome, AUHAL) |
| Mac Studio Speakers: Chrome, plain IOProc | no | no |
| The device built with `kDevice_HasInput=false`: Chrome, Music, AUHAL, plain IOProc | no | no |

So the device is output-only. As a result it can't be used to record system audio, and macOS can no longer pick it
as the default input when no microphone is attached.

## The shared mix

**Driver.** The driver already receives the full system mix in `WriteMix`. It copies that buffer into a POSIX
shared-memory ring, `/io.ruiying.matbridge`, applying the device's mute and volume. The ring holds 65 536 frames × 6
channels of Float32, indexed by device sample time. Its header holds:
- `writeEnd`, release-stored after the data;
- an `epoch` that is bumped whenever the device clock restarts;
- the sample rate;
- a write counter.

The driver creates the ring on the device's first `StartIO` and keeps it for the life of the driver process. An
existing ring of the right size is reused, so a reader's mapping survives a coreaudiod restart.

**Sandbox.** Third-party drivers run in "Core Audio Driver (MATBridge.driver)" as `_coreaudiod`, sandboxed by
`/System/Library/Sandbox/Profiles/com.apple.audio.coreaudiod.sb`. That profile contains an unscoped
`(allow ipc-posix-shm)`, and `sandbox_check()` against the running driver host confirms that create, write and read
are allowed, while file writes outside its temp directory are not. So no `AudioServerPlugIn_MachServices` entry,
LaunchDaemon or other helper is needed. The ring is created with mode 0644, so MATBridge, an unprivileged per-user
process, maps it read-only.

**MATBridge.** One output-only IOProc runs on the virtual device. It does three things:
- writes silence, which adds nothing to the mix (x + 0 = x);
- keeps the device's IO and clock running, so the mix is continuous even when nothing plays;
- wakes once per device IO cycle (≈5 ms) and moves every new frame from the ring into the pipeline.

The ring only exists once the device's IO has run. After a reboot or a coreaudiod restart that may not have happened
yet, so `Capture` starts the same kind of IOProc for up to a second before it opens the ring.

Both IOProcs also switch off any input streams for themselves (`kAudioDevicePropertyIOProcStreamUsage`). The
output-only device has none, so this does nothing there. It keeps MATBridge from counting as recording if a driver
built with an input side is installed.

**Properties.**
- **Latency:** about one IO buffer. The driver publishes each mix for an output time about one buffer ahead, and
  MATBridge reads it on its next cycle. That is the "capture 5.0 ms" in the log, part of the 98 ms the driver reports
  to apps.
- **Clock:** frames arrive from the device's own IO cycles, so the drift controller sees the virtual device's clock
  against the HDMI output's.
- **Real-time safety:** the driver adds one memcpy (`vDSP_vsmul` when the volume isn't 1) and two atomic stores per
  cycle. Nothing allocates or locks on the IO thread; the mapping is made in `StartIO` under the state mutex. The
  reader is lock-free: it acquire-loads `writeEnd`, copies, then re-checks `writeEnd` and `epoch` in case it was
  lapped mid-copy.
- **Robustness:**
  - *Clock restart:* the reader resyncs to the newest frame.
  - *Reader far behind (more than half the ring):* it skips to now and counts the frames lost (`shared-mix frames
    lost` in the stats).
  - *Driver stops writing:* the health check rebuilds the pipeline.
  - *Failure in the driver:* a shared-memory failure there only skips the copy, so system audio itself is never
    affected.
- **Ownership:** only the driver writes the ring. The driver reuses an existing ring only if it owns it and nobody
  else can write it, and MATBridge refuses a ring that isn't owned by `_coreaudiod` or is writable by others. So
  another local user can't create the ring first and feed MATBridge audio. MATBridge also takes the channel count
  once, when it maps the ring, so a changed header can't make it read past the mapping.
- **Privacy:** the ring is world-readable, so any local process can read what plays through MATBridge without a
  permission prompt. The driver runs as `_coreaudiod` and can't give the object to one user. Restricting it would
  need a root LaunchDaemon brokering a mach memory-entry port, or a reader handshake through a custom device
  property. Both cost far more than they're worth on a single-user Mac.


**Verification.**
- **Reader:** a simulated writer (the driver's copy code, a test ring name) against `thb_shm_read` ran 288 000
  frames, 2 clock restarts and a forced 0.9 s reader stall. Result: no wrong samples, frame-exact continuity within
  each epoch, and read + lost + resync = written.
- **Live, on the tested setup in the README:**
  - The MATBridge worker shows `IsRunningInput` 0, and the menu bar shows no microphone indicator.
  - A 1 kHz test tone arrived in the ring with no discontinuity over 352 000 frames, and the pipeline had no
    underruns or lost frames.

## Other ways to get the mix

**Core Audio process taps** (`AudioHardwareCreateProcessTap`, macOS 14.2+). A tap on the virtual device's output,
read through a private aggregate device, has these drawbacks:
- **Another permission and indicator:** taps are gated by a separate permission, `kTCCServiceAudioCapture` ("System
  Audio Recording Only"), and show a purple recording indicator while running. That swaps one permanent indicator
  for another.
- **More latency:** the aggregate device adds its own buffer and safety offset.
- **More lifecycle handling:** the aggregate device has to be re-created after coreaudiod restarts.
- **Nothing saved:** the virtual device is still needed, because apps must see a 6-channel system output that
  reports the real latency.

Taps were not tried, to avoid granting System Audio Recording permission for an experiment; Apple documents both the
permission and the indicator.

**A mach service from the driver** (`AudioServerPlugIn_MachServices`). The driver host lives in the system bootstrap
domain and can't look up services in the user's GUI domain, where a LaunchAgent registers. It would need a root
LaunchDaemon as a broker and sudo at install. That's only worth it to close the privacy gap above.

**A custom device property** (`kAudioObjectPropertyCustomPropertyInfoList`, CFData values). Every read goes through
coreaudiod's property machinery, with allocations and a mach round-trip, so it isn't usable at audio rate.

**Reading the mix from an output IOProc.** An IOProc only ever sees its own output buffer, never what other clients
play, and the HAL has no public API that exposes the mix to an output client.

# Apple Music passthrough

Apple Music plays Dolby Atmos as a Dolby Digital Plus (E-AC-3 JOC) bitstream, which it can send unchanged to an HDMI
receiver. MATBridge holds the HDMI output exclusively and makes the virtual device the system output, so it has to
step aside for that. And through some USB-C hubs, Music refused to pass Atmos through at all, even without MATBridge.
The pieces are `driver/hdmi-passthrough.patch`, `MusicLog.swift`, `Router.swift` (also `DolbyFormats`) and the
hand-off in `Bridge.swift`.

## What Music checks

All measured on the tested setup in the README, by reading Music's unified log (`log show --process Music`).

- **The system output's transport type and formats.** Music logs a format filter for every track
  (`SupportedAudioFormat ... atmosCanPassthrough:YES/NO`). It says YES only when the *default output device* reports
  HDMI transport (`kAudioDeviceTransportTypeHDMI`) **and** lists Dolby physical formats. A test device that reported
  HDMI with only PCM formats got NO.
- **The real TV only has to accept the stream.** With an HDMI-typed test device as the default output, Music built its
  passthrough queue (`'qc+3'`) on the *TV*, took it exclusively and set it to `cc+3` at 192 kHz. The virtual device
  never received the bitstream. The receiver showed Dolby Atmos.
- **The TV must be free when Music decides.** With MATBridge holding the TV, Music decides against passthrough. It
  still picks the Atmos version of a track, but decodes it to 5.1 PCM (`'qec3'`, 6 channels) into the default output.
- **Music only reconsiders on a default-output change.** Released mid-track, the TV is picked up within about 60 ms,
  but only if the default output device changes at that moment (Music logs
  `ReevaluationReason = DefaultOutputDeviceChange`). Releasing the TV often makes macOS move the default output to it
  (it is the preferred device and just became available), but not always.

## Why it failed through a hub

| | USB-C hub | Mac's HDMI port |
|---|---|---|
| Core Audio transport of the TV | `'dprt'` (DisplayPort) | `'hdmi'` |
| Port type of the hub's converter (ioreg `DFP Type`) | DisplayPort (Synaptics branch device) | HDMI |
| EDID input type | DisplayPort | HDMI |
| Dolby formats the TV offers (`cac3 cc+3 cd+3 cec3 mtc+ mtct`) | identical | identical |
| Music's format filter | `atmosCanPassthrough:NO` | `:YES` |

The hub's converter reports its output as DisplayPort and rewrites the EDID to match, so macOS treats the TV as a
DisplayPort audio device. The TV accepts exactly the same formats either way; only Music's transport check differs.
A display EDID override didn't help: on Apple silicon the display firmware takes the port type from the converter,
not from the EDID, and the Core Audio transport stayed `'dprt'`.

## The design

- **The virtual device reports HDMI** and lists the encoded formats the TV offers right now. MATBridge reads them
  from the TV every second and writes them to a custom device property (`'mbdf'`, a CFData of
  `AudioStreamRangedDescription`); the driver appends them to the output stream's available physical formats and
  asks the HAL for a configuration change so the new list is seen. With no TV, the list is empty. Setting one of these
  formats is refused, so the virtual device never carries a bitstream. Like any device property, any local app can
  change the list; the driver only accepts encoded (non-PCM) entries, at most 32.
- **MATBridge keeps the TV while Music plays**, and Music's stereo and lossless tracks are encoded like any other
  audio. It releases the TV only when Music builds a Dolby queue: `MusicLog` runs
  `log stream --predicate 'process == "Music" AND eventMessage CONTAINS "subaq_buildCAAudioQueue" AND eventMessage CONTAINS "Creating AudioQueue"'`
  and reads `format:'xxxx'` from each line. (The predicate also requires the process to live in
  `/System/Applications/Music.app/`, so another program named "Music" can't trigger a hand-off.) These lines are public at the Default level, so an admin user can stream
  them without sudo. The line arrives when the queue is built, before the audio starts.
- **The nudge.** 150 ms after releasing the TV, if the default output hasn't moved, MATBridge sets it to the TV, and
  its default-output listener moves it straight back to the virtual device. That is the default-output change Music
  needs to reconsider. Keeping the virtual device as the default output is what keeps Music's transport check passing.
- **Taking the TV back** needs no log: a listener on the TV's hog-mode property fires when Music lets go (a pause, or
  the next track has no Atmos), and MATBridge waits `--handoff-delay` so a release and re-take at a track change
  doesn't make it flap. Measured on the hub: Atmos to stereo, the TV is back in about 0.4 s; stereo to Atmos or resume,
  passthrough starts in about 0.4 s; Atmos to Atmos, nothing switches.
- **Other apps during a hand-off** keep playing to the virtual device. The `Router` reads the driver's shared mix,
  folds it to stereo and plays it with an output unit: to the Mac's built-in speakers while Music holds the TV, or to
  the TV (at whatever format it is in; Core Audio converts the rate) in the moments it is free.

## Signals that were ruled out

| Candidate | Why not |
|---|---|
| `com.apple.Music.playerInfo` | No format or Atmos key (name, artist, state, persistent ID, total time). Still used for play, pause and stop. |
| AppleScript `current track` | `bit rate` and `sample rate` describe what plays now, not what the track offers. |
| MediaRemote now-playing info | Returns nothing to an unentitled process on macOS 27. |
| Core Audio process objects and hog mode | Show passthrough only after it started; in the format they look the same for Atmos and stereo. Used to take the TV back. |
| Music changing the device's sample rate | Music on macOS never changes any output's rate, the TV's included; its queue resamples. |

## Other hand-off designs

**Releasing the TV whenever Music plays.** That was the first design, and it is still the fallback when `log stream`
isn't allowed. It works, but stereo tracks and every other app then reach the receiver as stereo PCM for the whole
Music session, instead of TrueHD.

**Letting Music decode Atmos into the virtual device.** With MATBridge holding the TV, Atmos tracks arrive as 5.1 PCM
and are encoded as TrueHD 5.1. That loses the height channels, so it is only what happens when the hand-off fails.
