# Design: getting the system mix to MATBridge

Apps play to the MATBridge virtual device. MATBridge needs that mix, all six channels and bit for bit, on the
device's own clock. It must not count as recording: macOS treats any process running audio input as microphone use.
That means a permanent orange indicator in the menu bar and a Microphone permission prompt, both wrong for a program
that never touches a microphone.

**Design:** the driver publishes its output mix in shared memory, and MATBridge reads it from an IOProc on the device
whose input streams are switched off. The pieces are `driver/shared-memory-mix.patch`,
`Sources/CTrueHD/matbridge_shm.h` (the layout both sides share), `thb_shm_*` in `Sources/CTrueHD/ctruehd.c` and
`Capture` in `Sources/MATBridge/Devices.swift`.

## What counts as recording

The HAL publishes `kAudioProcessPropertyIsRunningInput` for each client process, and the microphone indicator follows
it. An IOProc counts as input as soon as the HAL hands it the device's input stream, whether or not it reads it:

| IOProc on the MATBridge device (measured, 1.5 s) | IsRunningInput | IsRunningOutput |
|---|---|---|
| Writes zeros to its output buffer, default stream usage | **1** | 1 |
| Same, with `kAudioDevicePropertyIOProcStreamUsage` (input scope) all off | **0** | 1 |

A loopback device read through its input side (the usual way to use BlackHole) therefore always shows the indicator.

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

**MATBridge.** One IOProc runs on the virtual device with its input streams switched off. It does three things:
- writes silence, which adds nothing to the mix (x + 0 = x);
- keeps the device's IO and clock running, so the mix is continuous even when nothing plays;
- wakes once per device IO cycle (≈5 ms) and moves every new frame from the ring into the pipeline.

The ring only exists once the device's IO has run. After a reboot or a coreaudiod restart that may not have happened
yet, so `Capture` starts the same input-off IOProc for up to a second before it opens the ring.

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
- **Privacy:** the ring is world-readable, so any local process can read what plays through MATBridge without a
  permission prompt. The driver runs as `_coreaudiod` and can't give the object to one user. Restricting it would
  need a root LaunchDaemon brokering a mach memory-entry port, or a reader handshake through a custom device
  property. Both cost far more than they're worth on a single-user Mac.

The device keeps BlackHole's loopback input; MATBridge doesn't use it.

**Verification.**
- **Reader:** a simulated writer (the driver's copy code, a test ring name) against `thb_shm_read` ran 288 000
  frames, 2 clock restarts and a forced 0.9 s reader stall. Result: no wrong samples, frame-exact continuity within
  each epoch, and read + lost + resync = written.
- **Live, on the tested setup in the README:**
  - The MATBridge worker shows `IsRunningInput` 0, and the menu bar shows no microphone indicator.
  - A 1 kHz test tone arrived in the ring with no discontinuity over 352 000 frames, and the pipeline had no
    underruns or lost frames.

## Alternatives

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
