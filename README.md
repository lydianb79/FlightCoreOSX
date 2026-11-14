<img src="Resources/AppIcon.png" width="128" alt="FlightCore icon">

# FlightCore

A radio-control line-of-sight flight simulator for macOS, written in Swift and rendered with Metal.

You stand at the edge of the field and fly the model from the pilot's point of view, the way you would at a real flying site. FlightCore is an early, playable version: the flight physics, cameras, sites and controller support are in place, but it is far from a complete commercial simulator (see [Not yet implemented](#not-yet-implemented)).

## Requirements

- macOS 13 or later
- Xcode 15 or later (or the Swift 5.9+ command-line toolchain)
- A Mac with Metal support

## Build and run

Build the app bundle:

```bash
./build_app.sh
```

Then launch it:

```bash
open FlightCore.app
```

To work on the code, open `Package.swift` in Xcode, or run it directly from the command line with `swift run -c release`.

## Aircraft

Sixteen aircraft, selected with `[` and `]`, keys 1–9, or the Aircraft menu.

| Aircraft | Type |
|---|---|
| Skylark Trainer | High-wing trainer, tricycle gear |
| Vortex 3D | Unlimited aerobat: hovers, knife-edges, tumbles |
| Thermal 2M | Hand-launched electric glider |
| Arrow EDF | Swept-wing ducted-fan jet |
| Kestrel 550 | Flybarless collective-pitch 3D helicopter |
| Quad X450 | 450-class quadcopter, self-level or acro |
| Feather Park Flyer | 320 g slow flyer |
| Bushmaster STOL | High-wing taildragger for short take-offs |
| Falcon Warbird | Heavy, fast low-wing fighter |
| Twin Courier | Twin-engine transport |
| Jester Biplane | Compact aerobatic biplane |
| Stiletto Racer | Pylon racer |
| Zephyr 3.6 Sailplane | Large self-launching sailplane |
| Sparrow 450 | Small, docile helicopter |
| Condor 700 | Large 700-class helicopter |
| Wasp Racing Quad | 5-inch racing quad |

## Flying sites

Three built-in 3D sites:

- **Meadow Field** — asphalt runway among rolling hills
- **Dry Lake** — wide dirt strip on a desert playa
- **Alpine Ridge** — grass strip on a ridge with slope lift

Wind speed and direction, turbulence, thermals and time of day are set from the Environment menu.

### Photo sites

Any 360° equirectangular panorama (2:1 aspect ratio; JPG, PNG, HEIC or TIFF) can be used as a flying site.

- Choose **Flying Site ▸ Add 360° Panorama Photo…** (⌘O), or drop images into `~/Library/Application Support/FlightCore/Panoramas`.
- The sun direction and ambient light are estimated from the photo, so the model is lit to match and casts a shadow on the photographed ground.
- The **Photo:** items in the Flying Site menu rotate the panorama, shift its horizon and set the camera height. The settings are saved in a `.json` file next to the image.

No photos are included in this repository. [Poly Haven](https://polyhaven.com/hdris) offers CC0 panoramas; download the tone-mapped JPG version.

Photo sites have a flat, invisible ground plane and no collision with objects in the picture, and they use the pilot camera only.

## Controls

Press **H** in the app for this list.

| Key | Action |
|---|---|
| ← → | Aileron (roll) |
| ↑ ↓ | Elevator (↓ pulls up) |
| A / D | Rudder (yaw) |
| W / S | Throttle or collective up / down |
| X | Throttle cut |
| Shift | Full stick deflection |
| Space or R | Reset aircraft |
| `[` `]`, 1–9 | Previous / next aircraft, or pick one |
| N | Next flying site |
| C | Camera: pilot, chase, onboard |
| Z | Zoom: auto, keep ground in view, fixed |
| F | Flight mode (quadcopters) |
| L | High / low rates |
| P | Pause |
| T | Slow motion |
| , / . | Less / more wind |
| B | Balloon Burst challenge |
| K | Demo pilot on / off |
| M | Mute sound |
| V | Hide / show HUD |

### Controllers

- **Gamepads** (Xbox, PlayStation and similar) work without setup and default to Mode 2 sticks.
- **USB RC transmitters and simulator dongles** are detected automatically.

**Controller ▸ Controller Setup…** (⌘,) covers:

- channel assignment and reversing for transmitters
- stick calibration (end points and centre)
- stick mode 1–4 for gamepads and the on-screen stick display
- low-rate throw, expo per axis, and stick deadband

## How it works

- **Physics** runs at 1 kHz. Airplanes are built from individual lifting panels, each with its own local airflow, so stalls, spins, knife-edge flight and prop-wash hovering come from the geometry. Helicopters use a rotor inflow model with a rate-command flight controller; multirotors use per-motor thrust with a mixer.
- **Aircraft are parametric.** One set of numbers per airplane drives both its aerodynamics and its 3D model, so adding an aircraft is mostly a matter of new parameters.
- **Rendering** uses Metal with procedural terrain, sky and clouds, two shadow maps (one tight around the aircraft, one for the airfield) and 4× MSAA. Shaders are compiled from source at launch.
- **Sound** is synthesized, with distance attenuation and Doppler shift.

### Source layout

| File | Contents |
|---|---|
| `Aircraft.swift` | Rigid-body physics for airplanes, helicopters and multirotors; ground contact |
| `AircraftLibrary.swift` | Aircraft definitions and procedural models |
| `World.swift` | Sites, terrain, scenery, wind, and the demo autopilot |
| `Panorama.swift` | Photo sites |
| `Renderer.swift`, `Shaders.swift` | Metal renderer and shader source |
| `Game.swift` | Game loop, cameras, HUD |
| `Input.swift` | Keyboard, gamepad, USB joystick input; sound synthesis |
| `main.swift` | App window, menus, controller setup |

### Testing

A headless test flies every aircraft for 60 simulated seconds under the autopilot and reports whether it crashed:

```bash
swift run -c release FlightCore --selftest
```

## Not yet implemented

- Multiplayer and VR
- Aircraft and airport editors
- Flight recording and playback
- Flight-instructor lessons
- Breakable parts, retracts, flaps and smoke
- Float planes and water
- Terrain and object collision on photo sites
