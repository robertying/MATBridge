# MATBridge

MATBridge sends **all of your Mac's audio** to an HDMI TV, receiver or soundbar as **lossless Dolby TrueHD 5.1**, packed in Dolby MAT. The audio is sent bit-exact, with the HDMI output used exclusively.

Apps play to a virtual 5.1 device called **MATBridge**. A background process encodes that audio live to TrueHD with FFmpeg and sends the encoded stream unchanged to the HDMI output. Your receiver or soundbar decodes it, the same way it decodes a TrueHD soundtrack from a Blu-ray player.

> **Status: experimental.** It changes system audio settings and takes your HDMI output exclusively, but every change is undone when it stops or crashes, and `MATBridge recover` undoes it by hand. Please report what happens on your hardware.

## Why

Some Macs scramble **multichannel PCM** over HDMI: the channels come out on the wrong speakers, often in a different order every time the HDMI audio link restarts. **Bitstream** formats (Dolby Digital, Dolby Digital Plus, TrueHD) arrive intact, because the receiver decodes them and puts each channel on the right speaker itself. MATBridge makes everything a bitstream.

It's also useful without that bug if you want lossless 5.1 from every app, not just a few players that can bitstream.

## Requirements

- **A Mac with Apple silicon**, macOS 15 or later.
- **An HDMI output whose connected sink accepts Dolby MAT (TrueHD)**: a TV with eARC passthrough, an AV receiver, or a soundbar. Check with `MATBridge devices` after building; the right output is marked `accepts Dolby MAT (TrueHD)`. macOS only offers that format while a capable sink is connected and switched on.
- **Homebrew FFmpeg** (provides the `truehd` encoder and `spdif` muxer): `brew install ffmpeg`.
- **Xcode**. The Command Line Tools are enough to build MATBridge itself; building the virtual audio device needs full Xcode.
- Optional: an Apple code-signing certificate for the driver. A Developer ID is used if you have one, otherwise an Apple Development certificate, otherwise an ad-hoc signature.

## Quick start

1. Build:
   ```bash
   swift build -c release
   ```
2. Check that your HDMI output accepts Dolby MAT:
   ```bash
   .build/release/MATBridge devices
   ```
3. Test the speaker order without installing anything. Each speaker speaks its own name in turn ("front left", "front right", "center", then a 50 Hz tone from the subwoofer, then "surround left", "surround right"):
   ```bash
   scripts/make-channel-test.sh
   ```
   ```bash
   .build/release/MATBridge run --test-file test/channel-id-48000.s32le
   ```
   Your receiver or soundbar should show **Dolby TrueHD 5.1**. The 12-second clip loops; stop with Ctrl-C. Start and stop it a few times to check the order holds every time the HDMI link restarts.
4. Build and install the MATBridge virtual audio device. The install asks for your password, and audio stops for a moment while macOS reloads its audio drivers:
   ```bash
   scripts/build-driver.sh
   ```
   ```bash
   scripts/install-driver.sh
   ```
5. Run it, then play anything, such as a 5.1 test video:
   ```bash
   .build/release/MATBridge run
   ```
6. Once it sounds right, install it as a background app that starts at login:
   ```bash
   scripts/install.sh
   ```
   Options are passed through, for example `scripts/install.sh --rate 192000`. The log is at `~/Library/Logs/MATBridge.log` and starts over once it passes 10 MB. The app lives in `~/Library/Application Support/MATBridge/MATBridge.app` and appears as MATBridge in System Settings → General → Login Items.

## How it works

```
apps ──► "MATBridge" virtual device (6 ch, the system output; reports the real latency to apps)
            │ output mix, Float32, published by the driver in shared memory
            ▼
   capture ─► PCM ring ─► encoder thread ─────────────────────► MAT ring ─► HDMI output
   (6 channels,           drift control (drop/repeat single      (61 440-byte   (exclusive "hog" mode,
    mapped by the          frames) → libavcodec "truehd"          bursts,        physical format 'mtct':
    speaker layout)        → libavformat "spdif" (MAT framing)    20 ms each)    2ch 16-bit 768 kHz, raw bytes)
```

- **Capture.** The MATBridge driver copies every output mix it receives into a POSIX shared-memory ring, and MATBridge reads that ring from an IOProc on the device. The IOProc keeps the device running and wakes MATBridge once per ~5 ms IO cycle. Its input streams are switched off, so macOS does not treat MATBridge as recording: no microphone indicator, no permission prompt. [docs/design.md](docs/design.md) explains why, and compares the alternatives.
- **Encoder.** FFmpeg's TrueHD encoder is linked directly, not run as the `ffmpeg` command. Piping through the command added 13–97 ms of uneven buffering; the library adds a fixed 15 ms. The output is byte-identical to `ffmpeg -c:a truehd -strict experimental -f spdif`. TrueHD stores 24 bits, so 24-bit audio passes through unchanged. Encoding runs about 140× faster than real time at 48 kHz (about 47× at 192 kHz).
- **Sender.** The HDMI output is opened exclusively ("hog mode") with mixing off and the Dolby MAT format set, then fed raw bytes. When it stops, everything is put back. On an underrun the output gets a pre-encoded *silent* MAT burst instead of nothing, so the receiver stays locked rather than clicking while it re-syncs.
- **Clock drift.** The virtual device and the HDMI output run on different clocks. The difference is absorbed by dropping or repeating single samples before encoding, under a proportional controller capped at ±1000 ppm. In practice that's a few hundred samples while it settles after start, then close to none. This is the only place samples are changed.
- **Real-time.** The capture and output callbacks don't allocate memory or take locks. The encoder thread runs with real-time scheduling and joins the audio device's IO workgroup.
- **Virtual device.** It's [BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.2, built with 6 channels and only 48, 96 and 192 kHz, plus two small patches: `driver/reported-output-latency.patch`, described under [Latency and lip sync](#latency-and-lip-sync), and `driver/shared-memory-mix.patch`, which publishes the mix for capture (layout in `Sources/CTrueHD/matbridge_shm.h`). Its speaker layout defaults to L R C LFE Ls Rs; MATBridge reads it and maps channels by speaker, not by number.

## Apple Music hand-off

Apple Music plays Dolby Atmos itself, as Dolby Digital Plus with Atmos, which beats anything MATBridge can do for music. So by default MATBridge steps aside while Music plays. Turn this off with `--no-music-handoff`.

- **Music starts playing:** MATBridge releases the HDMI output and makes it the system output, so Music takes it.
- **Music pauses or stops:** after `--handoff-delay` (default 0.5 s), MATBridge takes the output back. Music holds it for up to about 2 s after pausing, so MATBridge watches the output and takes it the moment Music lets go.
- **Meanwhile:** other apps' audio goes to the Mac's built-in speakers, which is what macOS does on its own when another app holds the HDMI output exclusively.

The hand-off follows Music's `com.apple.Music.playerInfo` notification. It also happens when Music plays to AirPlay, which isn't necessary. Tracks without Atmos go to the HDMI output as plain PCM, so on a Mac that scrambles multichannel PCM, multichannel non-Atmos tracks can come out on the wrong speakers; stereo is fine.

## Latency and lip sync

Measured at 48 kHz:

| Stage | ms |
|---|---|
| Capture: the driver's shared mix, read once per ~5 ms IO cycle | ~5, logged at start |
| Pipeline: encoder (15) + MAT grouping (up to 20) + safety buffer, held at `--target-ms` | 70 (default) |
| HDMI output; the MAT format fixes its buffer at one 20 ms burst | ~23 |
| **Total before the receiver** | **≈ 98** |
| Receiver's TrueHD decode | unknown, can't be measured from the Mac |

Video players delay the picture by the latency the output device *reports*. Stock BlackHole reports 0, so the picture would run about 100 ms ahead of the sound. BlackHole's own latency setting doesn't help either: it also sets the "safety offset", which really delays the audio. `driver/reported-output-latency.patch` adds a latency that is only reported (output side, scaled to the current sample rate), so players hold the picture back by that much while nothing is actually delayed.

The reported value is fixed when you build the driver: `scripts/build-driver.sh <ms>`, default 98. It's stored in microseconds and scaled to the sample rate, so `--rate` doesn't affect it. If you change `--target-ms`, rebuild the driver with the new total; MATBridge prints the breakdown when it starts. You can lower `--target-ms` at the risk of underruns, each of which is logged and heard as a short silent gap.

## Reliability and recovery

A health check runs every second and on device changes. It rebuilds the pipeline when:

- the HDMI output disappears (TV off, cable unplugged, display sleep);
- another app changes the output's exclusive hold or format;
- the capture or output stops delivering audio, or the driver stops updating its shared mix;
- the virtual device disappears or changes sample rate;
- the encoder thread stops.

It finds the output again by UID, `--tv` name, or auto-detection, and retries every 2 s. Before system sleep it releases the output; 2 s after wake it takes it back. While the output is gone, the virtual device stays the system output, so audio is silent rather than suddenly playing from the Mac speakers.

MATBridge never leaves the HDMI output changed:

1. On Ctrl-C, SIGTERM or SIGHUP it restores the output's original PCM format, mixing and exclusive hold. It points the system output back at the HDMI output, or at the Mac's built-in speakers if that's gone or held by another app.
2. `run` is a small supervisor process. If the worker exits for any reason, including a crash or `kill -9`, the supervisor runs the same recovery, then restarts the worker. It gives up after 5 crashes in 2 minutes.
3. If the supervisor dies, the worker notices within a second, cleans up and exits.
4. The original format is saved in `~/Library/Application Support/MATBridge/state.json` before anything changes. After a hard kill, macOS can reset the output to 2-channel PCM; recovery puts back the exact original.

To restore everything by hand at any time:

```bash
.build/release/MATBridge recover
```

`MATBridge status` shows the output's format, who holds it, the virtual device, whether the driver's shared mix is there, and the saved state.

## Command reference

```
MATBridge <command> [options]
  run        run the bridge (supervisor + worker)
  recover    restore the HDMI output and the system output; safe to run any time
  status     show the HDMI output, virtual device, shared mix and saved state
  devices    list audio devices; marks outputs that accept Dolby MAT

  --tv NAME / --tv-uid UID         HDMI output (default: the one used last time, else the first that accepts Dolby MAT)
  --rate 48000|96000|192000        TrueHD sample rate (MAT runs at 768 kHz on the wire either way)
  --target-ms MS                   pipeline buffer (default 70)
  --no-music-handoff               keep the output while Apple Music plays
  --handoff-delay S                wait after Music pauses before taking the output back (default 0.5)
  --no-default-output              never change the system output
  --channel-map a,b,c,d,e,f        0-based source channels for FL FR FC LFE SL SR (default: from the speaker layout)
  --test-file PATH                 loop a raw s32le 6-channel file instead of capturing
  --stats-interval S               seconds between stats lines in the log (default 60)
  --mute, --no-realtime            diagnostics
```

## Troubleshooting

- **No output is marked "accepts Dolby MAT".** The sink must be on and support TrueHD/MAT passthrough. For a TV with eARC, enable passthrough or bitstream in the TV's sound settings. Some sinks only accept MAT over eARC, not plain ARC.
- **The receiver shows PCM, or no sound.** Run `MATBridge status`, then `MATBridge recover`, and check the log.
- **It doesn't start after `brew upgrade ffmpeg`** (the log shows a dyld error). FFmpeg changed major version: rebuild with `swift build -c release`, then re-run `scripts/install.sh` if installed.
- **Short gaps in the sound.** The log counts underruns. Try a larger `--target-ms`, then rebuild the driver with the new total.
- **Channels on the wrong speakers.** Run the channel test from the quick start. If that's wrong too, open Audio MIDI Setup → MATBridge → Configure Speakers and check that channels 1–6 are L R C LFE Ls Rs. Leave the TV's own speaker setup alone.
- **No sound after quitting MATBridge.** The system output may still be the MATBridge device. Run `MATBridge recover`, or pick another output in Control Center.

When reporting a problem, include the output of `MATBridge devices` and `MATBridge status`, and the relevant part of the log.

## Known limits

- **5.1 only.** FFmpeg's TrueHD encoder supports up to 5.1. There's no 7.1 and no Atmos for system audio; macOS downmixes 7.1 to 5.1.
- **48 kHz family only.** MAT runs at 768 kHz, so 44.1 kHz sources are resampled to 48 kHz by macOS.
- **The encoder is marked experimental** in FFmpeg. It has seen far less use than Dolby's own encoder.
- **No volume control in MATBridge.** Use your receiver's volume. If you move the MATBridge device's volume slider, samples are scaled before encoding.
- **The shared mix is readable by any local process.** The driver runs as `_coreaudiod` and can't hand the ring to just your user, so any program on the Mac can read what plays through MATBridge. See [docs/design.md](docs/design.md).
- **Fixed reported latency.** It's set when the driver is built, and doesn't include the receiver's decode time.
- **Clock-drift correction drops or repeats single samples**, so those few samples aren't bit-exact. For a minute or two after a start, while the correction settles, this can be heard as faint ticks on a pure test tone; music masks it.
- Hard crashes cause a ~2 s gap while the supervisor restarts the worker.

## Uninstall

```bash
scripts/uninstall.sh
```

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/MATBridge.driver && sudo killall coreaudiod
```

The first removes the login item and the installed app, and restores the HDMI output and the system output. The second removes the virtual device; its 1.5 MB shared-memory ring goes away at the next restart. The saved state and the log stay behind in `~/Library/Application Support/MATBridge` and `~/Library/Logs/MATBridge.log`; delete them if you like.

## Tested setup

Mac Studio (M5 Max), macOS 27.2, built-in HDMI → LG TV with eARC → 5.1.2 soundbar, FFmpeg 9.0.2.

## Repository layout

```
LICENSE                  GPL-3.0
Sources/CTrueHD/         C: lock-free ring buffer, TrueHD encoder + MAT burst assembly (libavcodec/libavformat),
                         IO-workgroup helper, reader for the driver's shared mix (matbridge_shm.h: the layout
                         shared with the driver)
Sources/MATBridge/       Swift: CoreAudio helpers, capture, HDMI sender, pipeline, supervisor, Music hand-off, recovery
docs/design.md           how the system mix reaches MATBridge, and the alternatives that were measured
driver/                  patches for the virtual device (BlackHole v0.7.2 is downloaded at build time)
scripts/                 build-driver, install-driver, install, uninstall, make-channel-test
prototype/bitsend.swift  the original proof of concept: plays a pre-encoded IEC 61937 file bit-exact
```

## Credits and trademarks

- Encoding by [FFmpeg](https://ffmpeg.org) (libavcodec `truehd`, libavformat `spdif`).
- The virtual device is built from [BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio (GPL-3.0).
- Dolby, Dolby TrueHD, Dolby Atmos and Dolby MAT are trademarks of Dolby Laboratories. This project is not affiliated with or endorsed by Dolby.

## License

MATBridge is licensed under the [GNU General Public License v3.0](LICENSE). The driver patch modifies BlackHole (GPL-3.0), and Homebrew's FFmpeg is a GPL build, so GPL-3.0 keeps everything compatible.
