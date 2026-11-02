# GTA V on iPhone (5★ Port)

> [!IMPORTANT]
> **📢 Everything you'll need is in the [Five Star Port Telegram](https://t.me/fivestarport).**
> Every new release, step-by-step help, answers to the common questions and a community that has been through the setup already. Questions about files and installs are answered there, not by email or DM.

A fan project that runs the WebAssembly build of GTA V natively on iPhone: the engine compiled to ARM64, a native Metal renderer with every shader precompiled, Story mode or free-roam Sandbox, touch controls that act as a real controller (with the game's own aim assist), gyro aiming, tilt steering and graphics presets up to near-native resolution.

**This repository contains no game files and no game code.** You need your own copy of the game files, and the app plays from your own copy on your phone.

> Not affiliated with or endorsed by Rockstar Games or Take-Two Interactive. Rights holders: contact kevin@aether.ee and the repository will be taken down promptly.

**Website:** [fivestarport.site](https://fivestarport.site): the guides, the questions and answers and the translate page in one place.

**On a Mac?** The same app runs natively on Apple Silicon Macs with keyboard and mouse: **[gta5-macos-port](https://github.com/kevinerikjs/gta5-macos-port)** ([setup guide](docs/MAC.md)).

## What you need

| | |
|---|---|
| **Your own game files** | Web build `8b0b5899ed`: the folder that contains `data/` and `b/8b0b5899ed/`, about 21 GB. |
| **An iPhone with 6 GB of memory** | iPhone 12 Pro, 13 Pro, any iPhone 14 or newer, on iOS 16 or later, with about 30 GB free. Older 4 GB iPhones will most likely run out of memory. |
| **The app (IPA)** | From the [Releases topic](https://t.me/fivestarport/786) of the [Five Star Port Telegram](https://t.me/fivestarport): join the group, the newest post there is the newest version. Or build it yourself on a Mac (see below). |
| **SideStore or AltStore** (free) | Installs the app with your normal Apple ID. Setting it up needs a computer once (an Apple rule). [SideStore](https://sidestore.io) · [AltStore](https://altstore.io) |

No paid Apple account is needed.

## Install in 4 steps

### 1. Put your game files on your iPhone

Copy your game folder (the one with `data/` and `b/` inside) onto the iPhone, so it sits in the Files app under **On My iPhone**. Not iCloud Drive: iCloud can offload files to save space, and the game needs every file on the phone.

Any way that gets the folder there works, for example:
- **AirDrop** it from a Mac, or download and unzip it in the Files app.
- **With a cable**, once the app is installed (step 3): Finder on a Mac, or the Apple Devices app on Windows. Select your iPhone, open **Files**, and drag the folder onto **GTA V Port**. It then shows up in Files under On My iPhone › GTA V Port.

### 2. Get the app from the Telegram group

Join the **[Five Star Port Telegram](https://t.me/fivestarport)** and open its **[Releases topic](https://t.me/fivestarport/786)**: the newest post there is the newest version. Download the IPA from it. Get it there rather than from random sites, which can have old or modified copies. (Have a Mac? You can also build it yourself, see [Build it yourself on a Mac](#build-it-yourself-on-a-mac).)

### 3. Install it

Open **SideStore** or **AltStore**, go to **My Apps**, tap **+** and pick `GTA5Port.ipa`. A free Apple ID re-signs the app every 7 days; SideStore does that on the phone, and AltStore does it over Wi-Fi from your computer.

### 4. Give the app your game files and play

**Easiest:** open the app once, then in the Files app long-press your game folder, tap **Move**, and choose **On My iPhone › GTA V Port**. Moving within On My iPhone is instant. Open the app again: it finds the game by itself, at any depth (a `mirror/playgta5.com/…` folder works as is).

**Or pick it:** in the app tap the **Game files** card, then **Choose a folder…**, and open any folder that has your game somewhere inside (even On My iPhone itself). The app searches it.

**Only have the zip or rar?** The app can unpack it for you: on the **Game files** screen, paste a direct link to it (or a download page; it opens in a built-in browser and takes the download over), or choose the archive in Files. It unpacks as it downloads, so you need about 21 GB free, not double.

Whichever way, the app checks every game file before you play and tells you exactly what's missing or damaged.

Then choose **Story mode** (the campaign, with saves) or **Sandbox** (free roam) and press **Play**.

Everything plays from your phone: no server, no internet needed while playing.

## Tips

- **Graphics.** Settings has six presets, from Battery to Max, and a separate resolution choice that changes while you play. Presets above the recommended one show a warning. If a setting needs more memory than your iPhone gives the app, the game closes; on the next launch the app tells you and goes back to a setting that works. Settings that already ran fine on your phone are never lowered.
- **Something went wrong?** Settings › **Send log to the developer** sends this run's log and the previous one (the one from a crash) in one tap. **Share log** lets you save or send it yourself.
- **Controls.** Move, resize or hide every touch button with **Edit controls layout** (start screen or Settings). Assisted aim, gyro aiming and tilt steering are in Settings. Bluetooth controllers work too; the touch controls hide while one is connected. Settings › Controls › **Airplane right stick** optionally replaces the airplane throttle and rudder buttons with a visible second stick: drag vertically to set throttle (it stays set when released), and horizontally for rudder (it recentres). Helicopters keep their buttons.
- **Updating.** When a new version comes out, get the newest IPA from the [Releases topic](https://t.me/fivestarport/786) and install it over the old app. Your game folder and saves stay where they are.

## Get the most performance

The biggest upgrade is **more memory**: iOS normally gives the app about half of your iPhone's RAM, which caps the graphics. You can unlock more, for free:

### Unlock more memory with SideStore + GetMoreRam (free)

Players report this works great and makes the game far more playable.

1. Install `GTA5Port.ipa` with **SideStore** as usual. The IPA already asks for the extra memory.
2. Install **[GetMoreRam](https://github.com/hugeBlack/GetMoreRam)**, sign in with the **same Apple ID** you use in SideStore, pick **GTA V Port** and add **Increased Memory Limit**.
3. In SideStore, **refresh** GTA V Port so it picks up the change.
4. Open the app: **Settings** shows the memory limit at the bottom. It should now be clearly higher than before (for example above ~3,500 MB on a 6 GB iPhone).

A paid Apple developer account or TrollStore gets you the same result without GetMoreRam (see *Free vs paid* below).

### Then tune the game

- **Graphics preset:** with more memory, try one step higher (Balanced, Quality, Ultra). If a preset is too much, the app tells you on the next launch and steps back down, so trying is safe.
- **Resolution:** set it separately in Settings while you play. It's the main lever for sharpness vs. frame rate.
- **Frame rate:** Settings › Frame rate: **30** is steadiest and coolest, **60** is smoother, **Unlocked** goes up to 120 on ProMotion iPhones (13 Pro and newer Pro models), and **40** on those is smoother than Unlocked when the game runs between 40 and 60. Changes apply right away.
- **Keep it cool:** iPhones slow down when hot. Play without a case or near airflow, and avoid charging while playing if it gets warm.
- **Close other apps** before playing and keep **Low Power Mode off**.
- **Game files on the iPhone:** keep the game folder in *On My iPhone*, not iCloud Drive (iCloud can offload files and cause loading stutters).

## What's new

See [CHANGELOG.md](CHANGELOG.md) for every version.

## Self Radio (your own music)

Since v1.4.5 your own songs play on the car radio, as on PC. Add them in **Settings › Self Radio › Add songs…**, or copy them into **On My iPhone › GTA V Port › Self Radio** (subfolders work too). MP3, M4A/AAC, ALAC, WAV, AIFF and FLAC play; songs from Apple Music or Spotify are protected and can't be added. With 3 songs or more, Self Radio is the smiley next to Los Santos Rock Radio in the radio wheel (the game calls it User Music FM). **Play order** is Shuffle by default; Shuffle and In order start each song from the beginning, and the **Next song** button next to Radio skips one. Like a radio station joins songs midway, as the PC does. Songs added while you play reach the station at the next start.

## Mods

PC mods work as downloaded: car and character replacements, add-on cars, OpenIV packages (`.oiv`), data files and Script Hook V scripts (`.asi`), trainers included. Install them in **Settings › Mods** by picking the downloaded file, or put the files in **On My iPhone › GTA V Port › Mods** yourself. See [docs/MODS.md](docs/MODS.md).

## Cheats

**Settings › Cheats** has a vehicle spawner (search any vehicle the game has, it appears in front of you), God mode and Never wanted switches, repair and clean, time of day and weather, Set money and the game's own story cheats. See [docs/CHEATS.md](docs/CHEATS.md).

## Anonymous play stats

Since v1.4.4 the app sends a few anonymous numbers so we can see what to fix first: how many people play, on which iPhones and versions, FPS, crashes, and which missions fail. No names, saves, game files, mod names or IP addresses. Exactly what is sent: [docs/STATS.md](docs/STATS.md).

## Translate the app

Anyone can add a language to the app or finish one with the [Translate page](https://fivestarport.site/translate/) on the website. Vietnamese, Arabic and Uzbek are community translations. See [docs/TRANSLATING.md](docs/TRANSLATING.md).

## Community and help

**[Questions and answers](docs/FAQ.md)**: the answers to the most common questions (install, game files, memory, controls, missions, crashes), the same ones the helper bot gives.

**[Five Star Port on Telegram](https://t.me/fivestarport)** has everything: every new release as it comes out, help with installs, and a community that has solved most problems before. Please ask there instead of by email or DM.

Bugs can also go to this repository's [Issues](https://github.com/kevinerikjs/gta5-ios-port/issues). Please attach your log from Settings › Share log.

---

## Build it yourself on a Mac

Needs an Apple Silicon Mac with Xcode (free) and `brew install xcodegen`. Point the script at your game folder:

```sh
./build_ipa.sh --mirror /path/to/your/game-folder          # asks for extra memory (works with any account)
./build_ipa.sh --mirror /path/to/your/game-folder --free   # only if your installer refuses the app
```

This makes `GTA5Port.ipa` next to the script (about 30 to 60 minutes); install it with SideStore or AltStore. Don't want 21 GB on your phone? Serve the game folder from your computer over [Tailscale](https://tailscale.com) (`tailscale serve --bg "/path/to/your/game-files"`) and build with `./build_ipa.sh https://my-pc.tailnet-name.ts.net`: the app then streams the files while you play. To install straight from Xcode instead, open `app/PlayGTA5Native.xcodeproj` (created by the script), choose your iPhone as the destination, pick your Apple ID under **Signing & Capabilities** (free accounts appear as *Personal Team*; change the bundle identifier to something unique if Xcode asks), and press **Run**.

## Free vs paid Apple account

| | Free Apple ID | Paid Apple Developer account (99 USD/year) |
|---|---|---|
| Works | yes | yes |
| Memory iOS allows the app | normal limit (about 3,000 MB on a 6 GB iPhone) | *Increased Memory Limit* + *Extended Virtual Addressing* (about 4,000 MB) |
| Experience | smooth on the lighter presets: about 25 to 31 FPS on an iPhone 13 Pro Max | the same, plus room for higher presets |
| Re-sign | every 7 days | once a year |

Settings shows the memory limit iOS gave the app at the bottom.

**Using a paid account:** the IPA and the Mac script ask for the memory entitlements by default, so just sign with your paid team. On a Mac (most reliable): open `app/PlayGTA5Native.xcodeproj`, pick your paid team under **Signing & Capabilities**, change the bundle identifier to something unique (e.g. `com.yourname.gta5port`), check that **Increased Memory Limit** and **Extended Virtual Addressing** are listed, choose your iPhone and press **Run**. If an IPA signed by SideStore or AltStore with a paid Apple ID shows the free limit, the tool dropped the entitlements; use the Mac route.

## How it works

- The engine (`game.wasm` from your files) is translated to C with [wasm2c](https://github.com/WebAssembly/wabt) and compiled to ARM64 at build time; iOS does not allow compiling code on the phone.
- Graphics use this project's own Metal renderer (`app/Source/MetalRenderer`). It runs the game's Direct3D 11-style command stream directly on Metal. At build time, the game's shaders from your files are translated to Metal with `app/ShaderTool` (built on Google's [Tint](https://dawn.googlesource.com/dawn), BSD-3-Clause/Apache-2.0, prebuilt in this project's releases) and precompiled into the app, so nothing is compiled on the phone while you play.
- Touch input feeds the engine's own controller code, so GTA's controller features (assisted aim, analog driving) work.
- Game files are read straight from the folder on your phone, or streamed from your server into a block cache.
- Script Hook V mods (`.asi`, Windows x64 code) run in a built-in x86-64 interpreter ([Blink](https://github.com/jart/blink), ISC license) whose memory is the engine's own, so a mod's game commands go straight to the engine's handlers.

## License

The code written for this project is MIT licensed (see `LICENSE`). It does not cover the game, its data, or the third-party files fetched at build time. Those keep their own licenses: WABT and SIMDe (Apache-2.0, MIT), bcdec (MIT), libarchive (`app/Vendor/LICENSE-libarchive.txt`) and libopus (`app/Vendor/LICENSE-libopus.txt`), both BSD, and Blink (`app/Vendor/LICENSE-blink.txt`, ISC).

## Thanks

This port is better because of people outside the project:

- **[@k49kg9xmsd-prog](https://github.com/k49kg9xmsd-prog)**: the app in 13 languages and swipe-to-look ([#4](https://github.com/kevinerikjs/gta5-ios-port/pull/4)).
- **[@ITSUPERVISOR](https://github.com/ITSUPERVISOR)**: the story cheats in Settings ([#9](https://github.com/kevinerikjs/gta5-ios-port/pull/9)).
- **[@TomerGamerTV](https://github.com/TomerGamerTV)**: the ideas behind the v1.3.2 fixes for pedestrian spawning crashes, the Replay editor's free space check and flickering props.
- **[@gfejer](https://github.com/gfejer)**: the Cheats menu with the vehicle spawner, God mode and Never wanted ([#22](https://github.com/kevinerikjs/gta5-ios-port/pull/22)).
- **[@m1337v](https://github.com/m1337v)**: the airplane right stick ([#12](https://github.com/kevinerikjs/gta5-ios-port/pull/12)) and retrying interrupted game-file reads ([#13](https://github.com/kevinerikjs/gta5-ios-port/pull/13)).
- **Players who opened issues** that shaped v1.3.4: [@aliiscoding2122](https://github.com/aliiscoding2122) (Story money reset to $0, [#10](https://github.com/kevinerikjs/gta5-ios-port/issues/10)) and [@k49kg9xmsd-prog](https://github.com/k49kg9xmsd-prog) (pause when leaving the app, [#11](https://github.com/kevinerikjs/gta5-ios-port/issues/11)).
- **Players who opened issues** that shaped v1.4: [@k49kg9xmsd-prog](https://github.com/k49kg9xmsd-prog) (aim and duck while driving, [#15](https://github.com/kevinerikjs/gta5-ios-port/issues/15)), [@abtastic-hub](https://github.com/abtastic-hub) (five bugs from the barber to Set money, [#19](https://github.com/kevinerikjs/gta5-ios-port/issues/19)), [@mmts7hrnb5-jpg](https://github.com/mmts7hrnb5-jpg) (the photo crash, [#16](https://github.com/kevinerikjs/gta5-ios-port/issues/16)) and [@Blue7366](https://github.com/Blue7366) (mods, [#3](https://github.com/kevinerikjs/gta5-ios-port/issues/3)).
- **Players who opened issues** that shaped v1.4.2: [@abtastic-hub](https://github.com/abtastic-hub) (the Handler in Scouting the Port, calls while walking, switching back from Chop, aiming while driving and more, [#20](https://github.com/kevinerikjs/gta5-ios-port/issues/20)).
- **Players who opened issues** that shaped v1.4.3: [@abtastic-hub](https://github.com/abtastic-hub) (the trailer, the Handler, switching back from Chop and the engine sounds, [#20](https://github.com/kevinerikjs/gta5-ios-port/issues/20)).
- **Translators**: @lekhoi2811 (Vietnamese), @uk9_v (Arabic) and @muhammadiminov_007 (Uzbek), from the Translate page.
- **Everyone who sent logs** from Settings › Send log to the developer, especially those who described exactly what failed and added their own analysis. Those reports found the Story mode bugs fixed in v1.3.3: the crash at the end of Marriage Counseling, the lock-ups after long sessions, and the lag with stuck buttons.
