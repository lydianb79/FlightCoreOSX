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

## Interface

- **Main menu** (Esc): shows the current aircraft and flying site with previews, and starts the flight.
- **Aircraft browser** (Tab, or click the aircraft name): category list, search, a rendered preview of every model, and a detail panel with description, difficulty and key figures.
- **Site browser** (click the site name): preview, description and conditions for each 3D and photo site, plus a button to add your own panorama.
- **Weather panel** (wind button in the top bar): wind speed and direction, turbulence, thermals and time of day, applied live.
- **In flight:** a top bar with the current aircraft and site, and a telemetry strip with altitude, airspeed, climb, distance, throttle and wind. Press V to hide it.

The last aircraft and site are remembered between launches.

## Aircraft

Ninety aircraft, grouped by category in the aircraft browser and the Aircraft menu. Step through them with `[` and `]`.

| Category | Count | Examples |
|---|---|---|
| Trainers & Sport | 9 | Skylark Trainer, Cadet 1200, Stick 40, Tundra Trainer, Stiletto Racer |
| Scale Civil | 22 | Piper J-3 Cub, Cessna 172, Pilatus PC-6 Porter, DHC-2 Beaver, Cirrus SR22, DHC-6 Twin Otter, Douglas DC-3, Antonov An-2, Tiger Moth |
| Warbirds | 17 | P-51D Mustang, Spitfire, Bf 109, Fw 190, Hurricane, P-47, Zero, Sea Fury, Mosquito, T-6 Texan, Sopwith Camel |
| Aerobatic | 11 | Extra 300, Edge 540, Sukhoi Su-26, Yak-54, CAP 232, Pitts Special, Pilatus PC-7 |
| Foam 3D | 9 | Flatty 3D, F3P Indoor Aerobat, Slick 3D Profile, Foam Extra XL, Micro Flatty |
| Jets | 9 | F-16, F-86 Sabre, MiG-15, F-104 Starfighter, BAe Hawk, L-39 Albatros |
| Gliders | 8 | ASK 21, ASW 28, DG-1000, Discus, Ka 8, Thermal 2M |
| Helicopters | 3 | Kestrel 550, Sparrow 450, Condor 700 |
| Multirotors | 2 | Quad X450, Wasp Racing Quad |

Every aircraft has its own flight model: the physics and the 3D shape are both generated from the same set of numbers (span, chords, mass, thrust, tail sizes, control throws, gear). The scale models are approximations: proportions, engine layout, gear and colours follow the real aircraft, but shapes such as elliptical or gull wings are simplified and there are no national markings. Most were derived by scaling a handful of tested base designs, so aircraft of the same family handle more alike than the real ones would. The Foam 3D planes are flat-plate "profile" airframes with oversized control surfaces and more thrust than weight.

## Flying sites

The site browser filters by type (3D or photo) and by landscape (Fields, Airfields, Mountains, Water, Desert, Winter), with search, previews, a difficulty rating and a description for each site.

### 3D sites

| Site | Landscape | Notes |
|---|---|---|
| Meadow Field | Fields | Asphalt runway among green hills; the easiest place to learn |
| Tuscan Hills | Fields | Grass strip among golden hills with cypress and olive trees |
| Forest Clearing | Fields | Short strip hemmed in by tall forest |
| Regional Airport | Airfields | 520 m runway, hangars, apron and control tower |
| Alpine Ridge | Mountains | Ridge-top strip with strong slope lift |
| Highland Moor | Mountains | Treeless, windy and overcast, with dark lochs |
| Coastal Strip | Water | Runway behind the dunes, sea in front |
| Lakeside | Water | Grass strip beside a wooded lake |
| Tropical Island | Water | Sand strip among palms, lagoon all round |
| Dry Lake | Desert | Wide dirt strip on a playa |
| Red Canyon | Desert | Mesa-top strip beside a deep canyon |
| Savanna | Desert | Golden grassland with acacias and strong thermals |
| Winter Field | Winter | Packed-snow strip under high peaks |

Wind, turbulence, thermals and time of day are set from the Weather panel. An aircraft that comes down in water is lost.

### Photo sites

Any 360° equirectangular panorama (2:1 aspect ratio; JPG, PNG, HEIC or TIFF) can be used as a flying site.

- Choose **Flying Site ▸ Add 360° Panorama Photo…** (⌘O), or drop images into `~/Library/Application Support/FlightCore/Panoramas`.
- The sun direction and ambient light are estimated from the photo, so the model is lit to match and casts a shadow on the photographed ground.
- The **Photo:** items in the Flying Site menu rotate the panorama, shift its horizon and set the camera height. The settings are saved in a `.json` file next to the image.

No photos are included in this repository. [Poly Haven](https://polyhaven.com/hdris) offers CC0 panoramas; download the tone-mapped JPG version.

Fifteen Poly Haven panoramas have built-in presets (name, description, rotation, start point, take-off direction and, for some, obstacles) that apply automatically when the file keeps its original name: `alps_field`, `autumn_field`, `belfast_open_field`, `derelict_airfield_01`, `derelict_airfield_02`, `dry_cracked_lake`, `dry_hay_field`, `farm_field`, `hochsal_field`, `limpopo_golf_course`, `snow_field`, `straw_rolls_field_01`, `suburban_football_field`, `wildflower_field` and `yellow_field`.

For your own photos, the `.json` file next to the image can also set where aircraft start and add obstacles — upright cylinders standing in for photographed trees and buildings, which the aircraft crashes into:

```json
{
  "startX": -20, "startZ": -15, "startHeading": 90,
  "obstacles": [ { "bearing": -52, "distance": 30, "radius": 5, "height": 13 } ]
}
```

`bearing` is measured in the photo (0° at the image centre, positive to the right). **Photo: Show / Hide Obstacles** draws the cylinders over the photo so you can line them up.

Photo sites have a flat, invisible ground plane and use the pilot camera only. The aircraft is always drawn in front of the photo, so it never disappears behind a photographed object.

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
| E | Flaps: up, half, full (Bushmaster, Falcon, Twin Courier) |
| G | Landing gear up / down (Falcon, Arrow EDF, Twin Courier) |
| Y | Smoke on / off |
| U | Helicopter throttle hold (autorotation) |
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
- **Models are generated in code:** airfoil-section wings with rounded tips, shaped fuselages, canopies, sprung gear legs, wheel spats, lift struts, twisted propellers that blur into a translucent disc at speed, and six trim schemes (sport, aerobatic, warbird, glider, jet, vintage). Surfaces are shaded as glossy film covering with sky reflections.
- **Scenery** on the 3D sites includes a clubhouse, car park with vehicles, pit tables, people, fences, power lines, a farm, long grass that sways in the wind, wild flowers, bushes, hedges, and rocks or cacti depending on the site.
- **Rendering** uses Metal. Each frame:
  - the scene is drawn in linear HDR (16-bit float) with 4× MSAA, resolving both colour and depth;
  - two shadow maps are used: a tight one around the aircraft whose penumbra widens with the aircraft's height above the ground, and a 4096² one for the airfield that is redrawn only when the scene changes;
  - ambient occlusion is computed from the resolved depth buffer;
  - bloom, filmic tone mapping, a light colour grade, vignette and dithering are applied in a final pass.
  The sky and clouds are procedural and rendered at half resolution; grass and trees are frustum-culled in chunks. Render resolution adjusts automatically to hold the frame rate, up to a ceiling set by the Graphics quality level (Low, Medium, High). Shaders are compiled from source at launch.
- **The app starts in full screen.** Press ⌃⌘F to switch to a window.
- **Sound** is synthesized, with distance attenuation and Doppler shift.
- **Crashes** break the model apart: wings, control surfaces, propellers and rotor blades come off and tumble, with a dust cloud and an impact sound.
- **Helicopter rotor speed** is simulated. The governed engine holds head speed under load, and with throttle hold the rotor is driven by the airflow alone, so autorotations work.

### Source layout

| File | Contents |
|---|---|
| `Aircraft.swift` | Rigid-body physics for airplanes, helicopters and multirotors; ground contact |
| `AircraftLibrary.swift` | Aircraft definitions |
| `Models.swift` | Procedural 3D models and trim schemes |
| `Scenery.swift` | Buildings, vehicles, people, trees, bushes, grass |
| `World.swift` | Sites, terrain, scenery, wind, and the demo autopilot |
| `Panorama.swift` | Photo sites |
| `Renderer.swift`, `Shaders.swift` | Metal renderer and shader source |
| `Game.swift` | Game loop, cameras, interface state |
| `UI.swift` | Main menu, aircraft and site browsers, weather panel, in-flight display |
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
- Float planes and water
- Sloping ground and occlusion by photographed objects on photo sites
