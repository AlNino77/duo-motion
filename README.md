# DuoMo

**DuoMo** is a 3D clamshell fold animation for MacBooks driven by the physical lid angle sensor.

> *"When the lid closes, the picture on its screen stays where it is in space while the hardware sweeps through it: the image frosts over and slips into black without ever changing its size."*

Rather than rendering inside a separate window, **the entire macOS display follows the animation in 3D space as you close your MacBook lid**.

## NOTE
- **Opening MacBook**: it's not possible to do it on lock screen due to macOS restrictions (without disabling SIP, which i don’t recommend). Because in that case any malicious app would be able to draw a login flow on your lock screen and steal your passwords. But i have implemented the animation for opening when screen is unlocked
- **Normal MacBook Use**: When the lid is open, the overlay stays hidden and the renderer and live screen capture remain dormant. The lightweight lid sensor stays active so DuoMo can detect a fold.
- **Closing MacBook**: As you tilt the screen closed, the display freezes the screen and seamlessly folds **from up to down** toward the bottom keyboard hinge into the dark void.
---

## Features

- 📐 **Physical Lid Angle Sensing**: Real-time 60 Hz polling of Apple's internal lid angle sensor (`IOHIDDevice` Vendor `0x05AC`, Product `0x8104`, UsagePage `0x0020`, Usage `0x008A`).
- 🌊 **Exact 1:1 Shaders**: Native Metal Shading Language implementation:
  - 3D perspective projection with up-to-down clamshell hinge bend
  - 5-tap separable Gaussian blur mip chain
  - Glass tint and specular rim reflections
  - Dark void horizon falloff
- 🖥️ **Full-Screen Seamless Overlay**: Spans the entire screen at `.screenSaver` level. Completely click-through and invisible when open, freezing and folding into 3D space on tilt.
- 🎛️ **Native Settings Panel**: A compact SwiftUI panel using a 2×2 status layout and grouped settings:
  - **Liquid Glass Status Tiles**: Status, Screen Recording permission, Energy, and live lid angle use native Liquid Glass on macOS 26. Secondary details appear only as hover help.
  - **Angle**: Configure Start Fold and Full Fold. If a new Start Fold value would activate at the current lid position, DuoMo asks for confirmation before saving it.
  - **Motion**: Tune follow response, blur, and glass reflection.
  - **Advanced**: Control wake-transition priority.
  - **Live Capture Only**: The fold always uses the current display without a separate source selector.
- 🍸 **Menu Bar Extra**: Sensor status, settings, screen recapture, and quit actions without a numerical angle readout.
- 🚀 **Controlled Releases (`build.sh`)**: Builds the current version without silently changing it, and supports explicit semantic version and build-number updates.

---

## Requirements

- macOS 14.0 or later (Apple Silicon or Intel MacBook with lid angle sensor)
- macOS 26 for native Liquid Glass status tiles; earlier versions use a system-material fallback
- Xcode Command Line Tools (`swiftc`, `xcrun metal`)

---

## Building & Installing

Build and install the current version from `Info.plist`:

```bash
./build.sh
```

Create a release with an explicit version and build number:

```bash
./build.sh --version 1.0.1 --build 2
```

Build without installing:

```bash
./build.sh --no-install
```

The script compiles the Metal shaders and universal Swift application, signs the app, creates `DuoMo-vX.Y.Z.dmg`, and installs to `/Applications/DuoMo.app` unless `--no-install` is supplied. The Bundle ID is `com.lqsky7.duomo`.

---

## Launching

Open the installed application from `/Applications` or run:

```bash
open /Applications/DuoMo.app
```

The menu bar icon displays the sensor state. The settings panel groups controls under Angle, Motion, and Advanced. Changes save automatically, so the window closes with the standard macOS close control rather than a separate Done button.

---

## Credits & Acknowledgements

- **Lid Angle Sensor**: Inspired by hardware reverse-engineering documented in [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) by [@samhenrigold](https://github.com/samhenrigold).
