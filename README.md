# AirZapper

Use your AirPods as an NES Zapper light gun on a Mac.

Hold an AirPod in your hand like a pistol (or wear it), move it to aim, and flick your wrist to fire.
AirZapper reads the AirPods' motion sensors with Core Motion and turns them into mouse aim and clicks on
the [OpenEmu](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon) game window. OpenEmu's NES core
(Nestopia) treats those clicks as Zapper shots.

Built and tested with **Wild Gunman**. Other Zapper games, such as Duck Hunt and Hogan's Alley, use
the same input path but haven't been tested.

## Requirements

- A Mac running macOS 14 (Sonoma) or later. Developed on Apple Silicon with macOS 26.
- AirPods with motion sensors: AirPods Pro, AirPods Max, or AirPods 3rd generation and later
- Xcode Command Line Tools (`xcode-select --install`), to build
- [OpenEmu-Silicon](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon), a maintained, notarized
  Apple Silicon build of OpenEmu. The original OpenEmu 2.4.1 is Intel-only.
- Your own NES game ROMs. None are included, and this project won't help you find them.

## Install

```sh
git clone https://github.com/rajatcing/AirZapper.git
cd AirZapper
./build.sh --open
```

This builds `build/AirZapper.app` and launches it. A small floating **AirZapper** panel appears
in the top-right corner of the screen.

## Setup

Do these once, in order. Each step lists what the panel should show when it's done.

1. **Allow Accessibility.** AirZapper needs it to move the cursor and click. When macOS asks,
   click *Open System Settings* and turn on **AirZapper** under Privacy & Security → Accessibility.
   → *Accessibility: Granted*
2. **Turn off Automatic Ear Detection.** In the panel, click **Bluetooth Settings…**, then the ⓘ
   next to your AirPods, and switch off **Automatic Ear Detection**. Otherwise macOS stops sending
   motion as soon as the AirPod leaves your ear.
   → *AirPods: Streaming ~50 Hz*
3. **Use one bud.** macOS streams motion from one AirPod at a time and decides which. Keep the bud
   you'll hold out, and put the other in its case with the lid closed. The **Sensor** row names
   the bud that's streaming.
   → *Sensor: Right AirPod — move this one* (or Left)
4. **Learn up/down.** Click **Learn up/down…**, hold the AirPod the way you'll play, and tilt
   your hand up, then back down, twice. It finishes on its own. Left/right aim needs no setup.

## Play Wild Gunman

1. Open your Wild Gunman ROM in OpenEmu-Silicon. The emulator core downloads automatically, and
   the Zapper is connected automatically.
2. Click the game window so it's in front.
   → *Target: Wild Gunman (Nestopia)*
3. Press **Right Shift** (Select) to choose Game A, B or C, then **Return** (Start).
4. When the outlaw's eyes flash and you hear "FIRE!", **flick your wrist**.

### Controls

| Action | How |
| --- | --- |
| Aim | Move the AirPod like a Wii remote. The cursor follows. |
| Fire | Flick or twist your wrist sharply. |
| Re-center | Press `` ` `` (backtick), or swing past an edge of the picture to re-sync there. |
| Use the trackpad | Move it. Motion aim pauses for 1.5 s so you can reach menus. |
| Trackpad aim mode | Aim with the trackpad and flick the AirPod to fire. |

AirZapper only aims and fires while an OpenEmu game window is in front.

### Tuning

- **Trigger**: how sharp a flick must be (rad/s). If it fires by accident, raise it. If flicks
  don't register, lower it. The meter shows each flick, and the red tick is the threshold.
- **Aim range**: how far you rotate from the center to the edge of the picture.
- **Invert X / Invert Y**: flip an axis if the cursor moves the wrong way.

Settings are saved between launches.

## How it works

- `CMHeadphoneMotionManager` delivers ~50 Hz gyro and gravity samples from one AirPod.
- Gyro rotation is split into two parts. Rotation **about gravity** drives horizontal aim, and it
  works however you hold the bud. Rotation about a **learned tilt axis** drives vertical aim.
  Both are integrated like an air mouse and clamped to the picture, so swinging past an edge
  re-syncs.
- A sharp rotation about any horizontal axis is a trigger pull. The shot lands where you were
  aiming just before the flick started, and aim snaps back there afterwards.
- AirZapper reads OpenEmu's game window frame through the Accessibility API, works out where the
  letterboxed NES picture sits, and posts mouse events there. OpenEmu's Nestopia core turns a
  click into a Zapper trigger at that point.

## Troubleshooting

- **Nothing moves**: check the **Sensor** row. If it says the bud is ignored, set *Use AirPod*
  to *Either*, or put the other bud in its case.
- **"No motion"**: Automatic Ear Detection is still on, or the AirPods aren't the active audio
  device.
- **Target says "OpenEmu not in front"**: click the game window.
- **Accessibility keeps resetting after a rebuild**: `build.sh` signs with the first code-signing
  identity in your keychain, so the permission survives rebuilds. Without one it signs ad-hoc,
  and macOS asks again after every build. Set `SIGN_IDENTITY` to choose a specific identity.
- A detailed log is written to `~/Library/Logs/AirZapper.log`.

## License

[MIT](LICENSE). Nintendo, NES, Zapper and Wild Gunman are trademarks of Nintendo. This project
isn't affiliated with Nintendo, Apple, or OpenEmu.
