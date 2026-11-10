<p align="center">
  <img src="Resources/IconSources/RecBar Logo.svg" width="112" alt="RecBar icon">
</p>

<h1 align="center">RecBar</h1>

<p align="center">A fast, native macOS menu-bar screen recorder with real multi-track audio and crash-safe output.</p>

RecBar records your screen with hardware-encoded HEVC and writes **every audio source to its own track**: the Mac's system audio, plus each selected microphone (built-in, Blue Yeti, or several at once). The webcam is captured as a separate file with microphones only. Everything is written progressively in 30-second crash-safe segments and merged losslessly when you stop, so a crash never costs more than the segment in progress.

No OBS. No cloud. No giant QuickTime capture file.

## Download

**[Download RecBar.dmg](https://github.com/pukrvi/RecBar/releases/latest/download/RecBar.dmg)** — macOS 15 or later, Apple Silicon.

1. Open the downloaded `RecBar.dmg`.
2. Drag **RecBar** onto the **Applications** folder.
3. Open **Applications → RecBar**. RecBar appears in the menu bar, not the Dock.
4. The first launch is blocked because this build is ad-hoc signed, not notarized. Right-click **RecBar** in Applications and choose **Open**, then **Open** again. If macOS does not offer that, use **System Settings → Privacy & Security → Open Anyway**.
5. Grant **Screen Recording**, then click **Relaunch RecBar** in the alert.

If macOS asks whether to replace an existing `RecBar`, choose **Replace** — that is the normal upgrade path. Recordings and settings are not touched.

Each release also publishes `RecBar.dmg.sha256`:

```bash
shasum -a 256 ~/Downloads/RecBar.dmg
```

---

## Screenshots

![RecBar panel](docs/menu.png)

![Audio tile menu: system audio plus any number of microphones](docs/audio-menu.png)

![Recording timer in the menu bar](docs/menubar-recording.png)

![Session output](docs/output-folder.png)

## What it produces

A session folder under `~/Movies/RecBar/`:

```
2026-11-09_12-29-42/
├── recording.mp4                       # screen + system audio + every microphone
├── camera.mp4                          # webcam + every microphone (no system audio)
├── audio/
│   ├── system.m4a                      # standalone backup, stereo
│   └── mic-macbook-pro-microphone.m4a  # standalone backup, mono
├── manifest.json                       # settings, tracks, segments, status, notes
└── segments/                           # only when "Keep Segment Files" is on
    ├── screen-00001.mp4                # video-only crash-safe chunks
    ├── camera-00001.mp4
    └── audio/segments/
        ├── system-00001.m4a
        └── mic-macbook-pro-microphone-00001.m4a
```

### Track layout

| File | Video | Audio tracks |
|---|---|---|
| `recording.mp4` | HEVC, 1080p30 (Compact) or native | **System audio** (stereo) + **one track per microphone** (mono) |
| `camera.mp4` | HEVC 720p30 | **One track per microphone** (mono), never system audio |
| `audio/system.m4a` | — | System audio, stereo |
| `audio/mic-<name>.m4a` | — | One microphone, mono |

Track order is stable: system audio first, then microphones in selection order. Track IDs are `system` and `mic-<slug>`, so an editor or agent can address them without guessing.

### Size

One hour in the default Compact preset:

| Source | Codec | Bitrate | Size / hour |
|---|---|---|---|
| Screen | HEVC hardware | 3.2 Mbps | ~1.4 GB |
| System audio | AAC-LC 48 kHz stereo | 256 kbps | ~115 MB |
| Each microphone | AAC-LC 48 kHz mono | 256 kbps | ~115 MB |
| Webcam (optional) | HEVC 720p30 | 2 Mbps | ~0.9 GB |

A one-hour screen + voiceover with system audio is about **1.6 GB**. The Balanced and Crisp presets record at native resolution and frame rate for sharper text.

## Audio routing

- **Audio → Record System Audio** captures what the Mac is playing as a stereo track.
- **Audio → Microphones** is a multi-select list. Select the built-in mic, a USB mic, or both; each gets its own writer, its own segment chain, and its own track in both final files.
- **System Default Microphone** records whichever input macOS currently considers default.
- **Record All Microphones** selects every connected input at once, for backup tracks.
- **Refresh Devices** re-scans after plugging in a USB interface.

The screen recording always gets system audio plus every selected mic. The camera file gets the same microphones but **never** system audio, so a talking-head file does not contain music or notifications from the desktop.

If system audio cannot start, RecBar keeps recording the screen and mics and shows a notice instead of failing the session. The same is true for a camera or microphone that disappears mid-recording.

## Crash safety

Every source writes its own chain of short files:

1. `AVAssetWriter` writes to `<name>.partial.mp4` (video) or `<name>.partial.m4a` (audio).
2. On rotation, `finishWriting` completes, the file is **fsync'd**, renamed atomically to its final name, and the directory is fsync'd.
3. `manifest.json` is rewritten atomically and fsync'd after every segment.
4. All writers rotate at the same logical instant, so video and audio boundaries stay aligned across pause/resume.

A hard crash loses **at most the current 30-second segment per source**. Everything finalized before that is a valid, playable file.

On the next launch RecBar scans for unfinished sessions, offers to recover them, and:

- unions the manifest's segment list with the files actually on disk (a crash can land between the atomic rename and the manifest write),
- merges the video segments and every audio chain with AVFoundation passthrough (no re-encode),
- writes `recording.mp4`, `camera.mp4`, and the standalone `audio/*.m4a` files,
- marks the manifest `recovered` and records which in-progress segment was lost.

This path is exercised live: SIGKILL during a recording, relaunch, recover. The recovered screen file had one video track plus two audio tracks (system + mic), the camera file had one video track plus one mic track, and the standalone audio files were present.

## Screen Recording permission

The repeated "Screen Recording permission is required" prompt was a signing problem, not a TCC bug. macOS keys the grant to the app's **designated requirement**; a default ad-hoc signature uses the cdhash, which changes on every rebuild.

RecBar now signs with a stable requirement:

```
designated => identifier "app.recbar.recorder"
```

That keeps the grant across rebuilds and relaunches. In addition:

- `CGRequestScreenCaptureAccess()` is called **at most once per install** (`RecBarDidRequestScreenCapture` in `UserDefaults`).
- After that, a denied start shows an alert with **Open Settings**, **Relaunch RecBar**, and **Cancel**.
- **Relaunch RecBar** is there because macOS only applies a newly granted Screen Recording permission to a process started after the grant.

Verified on this Mac: grant once, rebuild, reinstall, relaunch several times, record again — no repeat prompt.

## Build and install

Requirements: macOS 15+ (built and tested on macOS 27.0.1), Apple Silicon, Command Line Tools. Full Xcode is not required.

```bash
cd RecBar
./scripts/build_app.sh      # release build, bundle, stable ad-hoc signature -> dist/RecBar.app
./scripts/install.sh        # copy to /Applications and launch
```

Or drag `dist/RecBar.app` into `/Applications` yourself.

The build script prints the designated requirement so you can confirm it:

```
designated => identifier "app.recbar.recorder"
```

The app is ad-hoc signed with a stable designated requirement, so macOS keeps the Screen Recording grant across rebuilds. The published DMG is also ad-hoc signed; it is not notarized, which is why the first launch needs the one-time **Open** step above. A Developer ID certificate and notarization would remove that step.

### Build the DMG

```bash
./scripts/make_dmg.sh       # -> dist/RecBar.dmg + dist/RecBar.dmg.sha256
```

Normal builds use the committed `Resources/DMG.DS_Store` and never open Finder. If you change the background or icon layout, regenerate that file once on a Mac with a GUI:

```bash
defaults write com.apple.finder AppleShowAllFiles -bool true
killall Finder
./scripts/make_dmg.sh --restyle
defaults write com.apple.finder AppleShowAllFiles -bool false
killall Finder
```

`--restyle` needs hidden files visible so Finder can position `.background` and `.VolumeIcon.icns` off-screen; otherwise they appear in the top-left corner for anyone who enables hidden files. The volume name is always `RecBar`, because the baked `.DS_Store` resolves its background picture relative to that name.

## First run

1. Launch RecBar. It appears as a **record icon in the menu bar** (no Dock icon).
2. Grant **Screen Recording** when macOS asks, then click **Relaunch RecBar** in the alert (or quit and reopen it).
3. Click the menu-bar icon to open the panel, then click the **Audio** tile to enable system audio and select microphones.
4. Click **Start Recording**. macOS asks for **Microphone** and **Camera** access the first time; grant them to include voice and the webcam file.
5. Click the icon again and press **Stop**, or use `⌃⌥⌘R`. The session appears in `~/Movies/RecBar/`.

## The panel

Click the menu-bar icon to open RecBar's control panel. It is a compact surface, not a long menu:

- **Status header** — READY when idle, a live REC timer while recording, and the free space on the recording volume.
- **Primary control** — **Start Recording** starts capture and closes the panel. While recording the row becomes **Stop** and **Pause**; when paused it becomes **Resume**.
- **Capture** — four tiles that open native menus:
  - **Audio** — system audio plus a multi-select list of microphones.
  - **Camera** — webcam off, or a separate file at the selected size.
  - **Display** — choose a monitor.
  - **Quality** — Compact 1080p30, Balanced Native 30, or Crisp Native 60.
- **Options** — System Audio, Cursor, and At Login toggles, plus Keep Segment Files.
- **Quick Actions** — open the recordings folder, play the last recording, or reveal it in Finder.
- **Footer** — Copy Path, About, Relaunch, and Quit (`⌘Q`).
- **Recovery banner** — appears only when an interrupted session can be recovered.

Tiles show a subtle zoom, a brighter shade, and an accent border under the pointer. The panel closes when you click **Start Recording** or click anywhere outside it.

While recording, the menu-bar item expands to show the live timer; when idle it shrinks back to the same compact width as the other menu-bar icons. Opening the panel does not move the icon.

The global shortcuts work with the panel closed:

- **Start / Stop** — `⌃⌥⌘R`
- **Pause / Resume** — `⌃⌥⌘P` (pausing stops capture entirely, so it costs no CPU)

While recording, the menu-bar icon and live timer switch to white on a dark or vibrant-dark menu bar and black on a light one. Both the artwork and the timer text use the same explicit colour, so they stay readable on translucent or coloured menu bars instead of being tinted into the background. While merging, the icon shows progress.

RecBar ships white and black SVG variants for every state (`Resources/MenuBar/menubar-*-white.svg` and `-black.svg`) and picks the variant from the status item's effective appearance, refreshing automatically when macOS changes appearance.

## Headless self-tests

No screen, microphone, or camera permission needed:

```bash
.build/release/RecBar --selftest
.build/release/RecBar --selftest-recovery
```

`--selftest` generates four seconds of synthetic video plus three independent audio sources (system audio and two microphones), writes one-second segments for screen, camera, and every audio track, merges them, and asserts the exact track layout:

```
SELFTEST segments: screen=4 camera=4 systemAudio=4 mic=4 mic2=4
SELFTEST merged screen: duration=4.00s tracks=v1/a3 bytes=427919
SELFTEST merged camera: duration=4.00s tracks=v1/a2 bytes=300913
SELFTEST standalone audio system: duration=4.00s tracks=1 bytes=106456 path=system.m4a
SELFTEST standalone audio mic-test: duration=4.00s tracks=1 bytes=121822 path=mic-test.m4a
SELFTEST standalone audio mic-test-2: duration=4.00s tracks=1 bytes=128188 path=mic-test-2.m4a
SELFTEST PASS
```

This proves the multi-mic path without needing two physical microphones: the screen file carries all three audio tracks, the camera file carries the two microphone tracks only, and each source gets its own standalone backup.

`--selftest-recovery` writes three segments per track, records only the first two in the manifest (simulating a crash between the atomic rename and the manifest write), adds stale partial files, then scans and recovers the session:

```
SELFTEST-RECOVERY scan: screen=3 camera=3 audioTracks=2
SELFTEST-RECOVERY merged screen: duration=3.00s tracks=v1/a2 bytes=102352
SELFTEST-RECOVERY merged camera: duration=3.00s tracks=v1/a1 bytes=44284
SELFTEST-RECOVERY PASS
```

## Architecture

```
ScreenCaptureKit (video) ──> SegmentWriter(screen) ──────┐
ScreenCaptureKit (audio) ──> AudioTrackWriter(system) ───┤
AVCapture microphone 1 ────> AudioTrackWriter(mic-1) ────┼─> ManifestStore (atomic JSON)
AVCapture microphone N ────> AudioTrackWriter(mic-N) ────┤
AVCapture camera ──────────> SegmentWriter(camera) ──────┘
                                                          └─> MergeService (multi-track passthrough)
```

- `ScreenCaptureEngine` — ScreenCaptureKit display capture plus a separate system-audio stream.
- `AudioCaptureEngine` — one AVCaptureSession per selected microphone.
- `CameraCaptureEngine` — AVCaptureSession webcam capture, mirrored, 720p.
- `SegmentWriter` — video-only HEVC segments with controller-driven rotation, fsync, atomic rename.
- `AudioTrackWriter` — one crash-safe AAC segment chain per audio source.
- `ManifestStore` — thread-safe, atomic, fsync'd session manifest.
- `MergeService` — AVMutableComposition + passthrough export; composes multi-track video and standalone audio, with an ffmpeg stream-copy fallback.
- `RecoveryService` — scans interrupted sessions, unions manifest with disk, rebuilds all tracks.
- `RecorderController` — start/pause/resume/stop, synchronized rotation, disk guard, auto-stop below 5 GB.
- Menu bar UI — AppKit `NSStatusItem` and `NSPopover` hosting a SwiftUI panel, Carbon global hotkeys.

## Limits

- Records a **display**, not a single window.
- A hard crash loses at most the current 30-second segment per source; that window is configurable in `RecorderSettings.segmentSeconds`.
- System audio is captured through ScreenCaptureKit; DRM-protected playback may be silent, which is a macOS limitation.
- The published DMG is ad-hoc signed, not notarized, so the first launch requires the one-time **Open** step described in [Download](#download). A Developer ID certificate would remove it.
- Each additional microphone adds about 115 MB per hour.

## Troubleshooting

**Menu bar icon missing** — RecBar is an accessory app (`LSUIElement`); check the menu bar, not the Dock. Quit and relaunch if needed.

**Permission alert even though the toggle is on** — click **Relaunch RecBar** in the alert. macOS does not apply a new Screen Recording grant to the running process.

**Microphone not listed** — connect it, then use **Audio → Refresh Devices**. USB audio devices sometimes take a second to appear.

**System audio is silent** — check the Mac's output device and whether the app you are recording uses DRM-protected playback. The system-audio track is separate from the mic track; open `audio/system.m4a` to inspect it directly.

**Merge failed** — the segments are kept and the manifest is marked `failed`. Use **Recover Interrupted Recordings…** on the next launch; `segments/` contains valid chunks.

**Disk fills up** — RecBar warns below 15 GB and stops/saves automatically below 5 GB.

## Privacy

Recordings stay on your Mac under `~/Movies/RecBar/`. RecBar has no network code and no telemetry.

## License

RecBar is released under the [MIT License](LICENSE). Copyright © 2026 Puneet Vishnawat.
