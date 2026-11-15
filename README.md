<img src="Resources/AppIcon.png" width="128" alt="FlightCore OSX icon">

# FlightCore OSX

A RC Flight Simulator for macOS, written in Swift and rendered with Metal. Created by Rock FPV.

![FlightCore OSX splash screen](Resources/Splash.jpg)

You stand at the edge of the field and fly the model from the pilot's point of view, the way you would at a real flying site. It has 100 aircraft, 13 3D flying sites, support for 360° photo sites, and works with USB RC transmitters, gamepads and the keyboard. Some features of commercial simulators are missing; see [Not yet implemented](#not-yet-implemented).

## Download

Get `FlightCore-OSX.zip` from the [latest release](https://github.com/lydianb79/FlightCoreOSX/releases/latest), unzip it and move `FlightCore.app` to your Applications folder.

The app is not signed with an Apple developer certificate or notarised, so macOS will refuse to open it the first time. Either right-click the app, choose **Open**, and confirm (on recent macOS versions: try to open it once, then allow it under **System Settings ▸ Privacy & Security**), or clear the download flag in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/FlightCore.app
```

The release is built for Apple silicon Macs running macOS 13 or later.

## Build from source

Requirements: macOS 13 or later, a Mac with Metal support, and Xcode 15 or later (or the Swift 5.9+ command-line toolchain).

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

- **Splash screen** at launch; any key or click continues, or it moves on by itself after a few seconds.
- **Main menu** (Esc): shows the current aircraft and flying site with previews, starts the flight, and sets the graphics quality.
- **Aircraft browser** (Tab, or click the aircraft name): category list, search, a rendered preview of every model, and a detail panel with description, difficulty and key figures.
- **Site browser** (click the site name): filters by type and landscape, search, and a preview, description, difficulty and conditions for each 3D and photo site, plus a button to add your own panorama.
- **Weather panel** (wind button in the top bar): wind speed and direction, turbulence, thermals and time of day, applied live.
- **In flight:** a top bar with the current aircraft and site, and a telemetry strip with altitude, airspeed, climb, distance, throttle and wind. Press V to hide it.

The last aircraft and site are remembered between launches. The interface uses the red, cream and black of the splash artwork.

## Aircraft

One hundred aircraft, grouped by category in the aircraft browser and the Aircraft menu. Step through them with `[` and `]`.

| Category | Count | Examples |
|---|---|---|
| Trainers & Sport | 9 | Skylark Trainer, Cadet 1200, Stick 40, Tundra Trainer, Stiletto Racer |
| Scale Civil | 26 | Piper J-3 Cub, Cessna 172, Pilatus PC-6 Porter, Pilatus PC-12, DHC-2 Beaver, Cirrus SR22, DHC-6 Twin Otter, Douglas DC-3, Antonov An-2, Tiger Moth, and three floatplanes |
| Warbirds | 17 | P-51D Mustang, Spitfire, Bf 109, Fw 190, Hurricane, P-47, Zero, Sea Fury, Mosquito, T-6 Texan, Sopwith Camel |
| Aerobatic | 11 | Extra 300, Edge 540, Sukhoi Su-26, Yak-54, CAP 232, Pitts Special, Pilatus PC-7 |
| Foam 3D | 9 | Flatty 3D, F3P Indoor Aerobat, Slick 3D Profile, Foam Extra XL, Micro Flatty |
| Wings | 6 | Sweep 48 Combat Wing, Plank 1.5 Soarer, Delta Dart, Voyager 2.1 FPV Wing, Horten Ho 229, Race Wing 600 |
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
| Q | Wheel brakes |
| Shift | Full stick deflection |
| Space or R | Reset aircraft |
| `[` `]`, 1–9 | Previous / next aircraft, or pick one |
| N | Next flying site |
| C | Camera: pilot, chase, onboard |
| Z | Zoom: auto, keep ground in view, fixed |
| F | Flight mode (quadcopters) |
| L | High / low rates |
| E | Flaps: up, half, full (aircraft that have them) |
| G | Landing gear up / down (aircraft with retractable gear) |
| Y | Smoke on / off |
| U | Helicopter throttle hold (autorotation) |
| P | Pause |
| T | Slow motion |
| , / . | Less / more wind |
| B | Balloon Burst challenge |
| K | Demo pilot on / off |
| M | Mute sound |
| V | Hide / show the in-flight display |
| H | Controls list |
| Tab | Aircraft browser |
| Esc | Main menu |
| ⌃⌘F | Full screen / window |

### Controllers

- **Gamepads** (Xbox, PlayStation and similar) work without setup and default to Mode 2 sticks.
- **USB RC transmitters and simulator dongles** are detected automatically, whether they identify as a joystick or as a gamepad (DJI controllers, for example). `FlightCore --hidtest` prints what was detected and the current stick values.

**Controller ▸ Controller Setup…** (⌘,) covers:

- channel assignment and reversing for transmitters
- stick calibration (end points and centre)
- stick mode 1–4 for gamepads and the on-screen stick display
- low-rate throw, expo per axis, and stick deadband

## How it works

- **Physics** runs at 1 kHz. Helicopters use a rotor inflow model with a rate-command flight controller; multirotors use per-motor thrust with a mixer. Airplanes are built from individual lifting panels, each with its own local airflow:
  - **Wings** have six panels per side, each with its own chord, twist (washout) and share of the load. The stall is tuned for model-size aircraft: the wing keeps most of its lift as it lets go and sheds it gradually, the centre of pressure moves back, and the sharpness depends on the wing section. A stall met in normal flight is a gentle nose-drop; a spin still needs to be provoked with rudder and elevator.
  - **Tail:** the wing's downwash reduces the tail's angle of attack and collapses when the wing stalls, which gives the nose-drop at the stall.
  - **Propulsion:** an electric motor whose torque falls with speed, a propeller that unloads in flight, and a battery that sags under load and drains with use (Simulation ▸ Unlimited Battery turns that off). Propeller effects are modelled: torque reaction, P-factor, spiral slipstream on the fin, and gyroscopic precession. Built-up and scale models have the motor angled slightly right and down to counter them, as real ones do; flat foam planes have a straight thrust line.
  - **Near the ground:** ground effect adds lift and cuts induced drag within about half a wingspan of the surface, so aircraft float in the flare. Flaps add drag and pitch the nose down.
  - **Balance and inertia:** the centre of gravity is placed a set static margin ahead of the computed neutral point. The moments of inertia are computed from where the weight sits, which depends on the construction: foam airframes are featherweight with the mass concentrated at the motor and battery, balsa models spread it more evenly, and composite gliders and jets carry heavy wings.
  - **Control rates** are calibrated when the app starts: each airplane is test-flown and its control throws scaled until it rolls, pitches and yaws at the rate its category is set up for (for example 150°/s of roll for a trainer, 380°/s for an aerobat, 95°/s for a glider).
- **Flying wings** have no tailplane. Pitch and roll both come from elevons, the wing is balanced by a reflexed section (or, for the delta, by its shape), and stability comes from sweep and a small static margin. Fins are on the wingtips, on the body, or absent (the Horten, which is loose in yaw).
- **Helicopters** also model vortex ring state (descending into their own downwash; fly forward to escape), blade flapping (the nose rises with speed), retreating-blade stall at high speed, and loss of tail-rotor authority in a fast sideways slide. The display shows VORTEX RING when it happens.
- **On the ground:** tyres build side force with slip angle and let go when they slide; rolling resistance, grip and bumpiness depend on the surface (asphalt, mown or long grass, dirt, sand, packed or soft snow); main wheels have brakes (Q, or the left trigger).
- **Floatplanes** (Beaver, Super Cub and Twin Otter) float on four buoyancy points per aircraft, with hull drag that peaks before the floats plane, and water rudders. At sites with water they start afloat, pointing into the wind.
- **Air:** the wind follows a boundary-layer profile (the set speed is at 10 m; it is about half that at 1 m). Turbulence is random gusts whose scale grows with height. Trees and buildings leave slower, rougher air downwind, and the lee of a slope is turbulent. Thermals lean with the wind, drift, build and fade, and are ringed by sink.
- **Scale data:** the 57 models of real aircraft are shaped from approximate published figures for the full-size type: aspect ratio, taper, length, wing loading, power loading and top speed, plus a wing-section family and washout. A Cub model comes out light and slow, a Starfighter model heavy and fast. `FlightCore --physicstest` prints every airplane's figures and runs stall, spin, take-off and battery tests on a sample; `FlightCore --handlingtest` lists every airplane's control rates and checks hovering and continuous rolls; `FlightCore --envtest` tests water take-offs, landing rolls, ground effect, vortex ring state and the weather.
- **Aircraft are parametric.** One set of numbers per airplane drives both its aerodynamics and its 3D model, so adding an aircraft is mostly a matter of new parameters.
- **Models are generated in code:** airfoil-section wings with rounded tips, shaped fuselages, canopies, sprung gear legs, wheel spats, lift struts, twisted propellers that blur into a translucent disc at speed, flat-foam profile airframes, and ten trim schemes including camouflage. Surfaces are shaded as glossy film covering with sky reflections.
- **Scenery** on the 3D sites includes a clubhouse, car park with vehicles, pit tables, people, fences, power lines, long grass that sways in the wind, wild flowers and bushes. Each site has its own terrain shape, ground colours and trees (deciduous, conifers, palms, acacias, cypresses, cacti), and some have water, a farm, or an airport with hangars and a tower.
- **Rendering** uses Metal. Each frame:
  - the scene is drawn in linear HDR (16-bit float) with 4× MSAA, resolving both colour and depth;
  - two shadow maps are used: a tight one around the aircraft whose penumbra widens with the aircraft's height above the ground, and a 4096² one for the airfield that is redrawn only when the scene changes;
  - ambient occlusion is computed from the resolved depth buffer;
  - bloom, filmic tone mapping, a light colour grade, vignette and dithering are applied in a final pass.
  The sky and clouds are procedural and rendered at half resolution; grass and trees are frustum-culled in chunks. Render resolution adjusts automatically to hold the frame rate, up to a ceiling set by the Graphics quality level (Low, Medium, High). Shaders are compiled from source at launch.
- **Frame pacing:** the simulation advances by exact display refresh periods, and the aircraft is drawn at its physics state carried forward by the fraction of a step not yet simulated, so motion is even from frame to frame. `FlightCore --perf` prints frame-pacing and motion statistics once a second.
- **The app starts in full screen.** Press ⌃⌘F to switch to a window.
- **Sound** is synthesized in stereo, with nothing sampled:
  - engine types: electric motor and propeller, piston engines (inline, flat and radial, which idle), ducted fans, turboprops, helicopter rotor with blade slap and tail rotor, and four separate multirotor motors;
  - the aircraft is placed left to right by where it is, gets quieter and duller with distance, and is Doppler-shifted;
  - airframe wind noise and tyre rumble on the ground;
  - ambience at the pilot's position: wind that follows the wind speed, birdsong on green sites, surf on water sites;
  - crashes (impact, debris) and splashes.
  `FlightCore --soundtest out.wav` renders a fly-past of each engine type to a file.
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
| `Input.swift` | Keyboard, gamepad, USB joystick input |
| `Sound.swift` | Sound synthesis |
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
- Sloping ground and occlusion by photographed objects on photo sites

## Credits

- Created by Rock FPV.
- The photo-site presets are written for CC0 panoramas from [Poly Haven](https://polyhaven.com), which are not included.
- Aircraft named after real types are approximate scale models and are not affiliated with or endorsed by their manufacturers.

## Licence

FlightCore OSX is free software, released under the [GNU General Public License, version 3](LICENSE). You may use, study, share and modify it; if you distribute it or a modified version, you must do so under the same licence and make the source available. It comes with no warranty.
