# Mods

The app loads PC mods for GTA V as they are downloaded (from gta5-mods.com, for example). You don't convert anything: install them from **Settings › Mods**, or put the files in the app's **Mods** folder yourself, using the same folder names as on PC.

**Mods can break the game.** Crashes, missing textures or odd behaviour caused by a mod are not bugs in the port, and we can't fix other people's mods. Ask about mods in the **Mods** topic on Telegram. Please send logs (Settings › This device › Send log to the developer) only for problems that also happen with the Mods folder empty. Logs show which mods were active.

## What works

| Kind of mod | Works | Notes |
|---|---|---|
| Replace a car, bike or plane | Yes | `.yft` / `.ytd` files inside `vehicles.rpf` |
| Replace a character or skin | Yes | `.ydd` / `.yft` / `.ytd` / `.ymt` inside the ped archives |
| Add-on cars (`dlc.rpf` packs) | Yes | Added to the game's pack list automatically |
| OpenIV packages (`.oiv`) | Yes | Drop the `.oiv` file (or its unpacked folder) into Mods |
| Data files (handling, AI, weather...) | Yes | Whole-file replacements, e.g. `vehicleaihandlinginfo.meta` |
| Script Hook V scripts (`.asi`), trainers | Yes | Simple Trainer and similar; see [Scripts](#scripts-asi) |
| ScriptHookVDotNet scripts (C# `.dll` in a `scripts` folder) | No | Not supported |
| RAGE Plugin Hook plugins, like LSPDFR (LSPD First Response) | No | They need RAGE Plugin Hook's PC launcher and .NET |
| ASI files that patch the PC game (packfile or heap limit adjusters, OpenIV.asi, gameconfig fixes) | Not needed | The port handles most of those limits itself; they load but do nothing. One limit it doesn't raise yet is the number of game archives: very large map packs such as MapFixes (379 archives) stop the game while it loads ("An add-on pack doesn't fit this game") |
| Replacing files inside an archive that is inside another archive (for example a car in a DLC pack's `vehicles.rpf`) | Not yet | The log says which file was skipped |
| Adding a brand-new file to one of the game's archives | Not yet | Replacing existing files works. Add-on packs bring their own archive and work |

This is the PC game at the version the port is built from. Mods made for newer GTA updates can refer to cars, clothes or game commands this version doesn't have. Those parts won't show up, and the log names them.

## Installing a mod (the easy way)

1. Download the mod on your iPhone (Safari saves it to Files › Downloads).
2. In the app: **Settings › Mods › Install a mod…** and pick the file as you downloaded it: `.zip`, `.rar`, `.oiv`, `.asi` or loose files. (`.7z` isn't supported yet: unpack it first.)
3. The app works out where each file goes and shows you before installing: which game file each one replaces, which add-on pack it adds, and what it leaves out and why.
4. Start the game.

Each mod gets its own folder in Mods. **Settings › Mods** lists them: switch a mod off or on, or swipe to remove it.

The app knows where files go because the game itself does: while the game runs, it records where every file lives in its archives. So **start the game once before installing loose car or skin files**. Mods that come in their game folders, add-ons, `.oiv` and `.asi` files don't need that.

Some things the app won't guess, so it leaves them out and says so:
- a settings file (`vehicles.meta`, `carcols.meta`...) that the game has in several places, when the readme doesn't name one;
- a car's settings when its model can't be installed;
- PC limit files (`gameconfig.xml` and similar), which aren't needed here and would break the game.

Put those in by hand if you know where they go (below).

## Before you start

- Cars, skins and add-on packs need the **game files on your iPhone**: tap **Game files** and choose **A folder on this iPhone**. When the game streams from a server, only whole-file mods (data files, scripts) load.
- The Mods folder is in the Files app: **On My iPhone › GTA V Port › Mods**. It appears after the first launch. A `README.txt` inside it has a short version of this page.
- Mods are read when the game starts. After adding or removing mods, close the game completely and start it again.

## Putting files in by hand

Use the path the mod's readme gives for OpenIV, starting from the game folder. Upper or lower case doesn't matter. The `mods/` folder that OpenIV uses is not needed here; if your copy has it, that works too.

**Replace a car** (Nissan Altima replacing the Ubermacht Oracle):

```
Mods/x64e.rpf/levels/gta5/vehicles.rpf/oracle.yft
Mods/x64e.rpf/levels/gta5/vehicles.rpf/oracle_hi.yft
Mods/x64e.rpf/levels/gta5/vehicles.rpf/oracle.ytd
```

On PC the vehicle archive is in `x64e.rpf`. Some readmes say `x64e.rpf\levels\gta5\vehicles.rpf\`, others only `vehicles.rpf`; use the full path above.

**Replace a character** (an ambient biker):

```
Mods/x64v.rpf/models/cdimages/componentpeds_g_m_y.rpf/g_m_y_lost_01.ydd
Mods/x64v.rpf/models/cdimages/componentpeds_g_m_y.rpf/g_m_y_lost_01.ytd
...
```

Main characters are in `x64v.rpf/models/cdimages/streamedpeds_players.rpf/player_zero/` (Michael), `player_one/` (Franklin) and `player_two/` (Trevor).

**Add-on car** (a mod with its own `dlc.rpf`):

```
Mods/update/x64/dlcpacks/a80/dlc.rpf
```

Skip the step where the readme asks you to edit `dlclist.xml`: the app adds every pack it finds to the list. The car's spawn name is in the mod's readme. Spawn it with a trainer.

**Several add-on cars:** give each car its own pack folder, for example `Mods/update/x64/dlcpacks/a80/dlc.rpf` and `Mods/update/x64/dlcpacks/veneno/dlc.rpf` (or install each one with **Settings › Mods**, which does that for you). Don't put two `dlc.rpf` files in one folder: the Files app renames the second one `dlc 2.rpf`. The app copes with that and with two cars that use the same pack name: each still loads as a pack of its own (the log says "loaded as …"), and the same car installed twice loads once.

**OpenIV package** (`.oiv`): put the file in Mods as it is, for example `Mods/Lamborghini Veneno.oiv`. An unpacked package (a folder with `assembly.xml` and `content/`) works too. The app installs it the way OpenIV would, including the edits it makes to game files.

**Data file** (Faster AI Drivers):

```
Mods/common.rpf/data/ai/vehicleaihandlinginfo.meta
```

Paths under `update/update.rpf/common/...` work as well.

## Your own PC audio files

The common web game files have very little car-engine audio (`STREAMED_VEHICLES_GRANULAR.rpf` is about 6 MB, against hundreds of MB on PC). That's why many engines sound faint or all the same. If you have your own copy of the PC game, you can use its audio archives:

- **Put them in Mods, not in the game folder.** Copying a PC audio file over the game folder's file makes the game files check fail on its size (and **Play anyway** only allows up to 20 problem files). Files in Mods aren't size-checked.
- Use the same path as on PC, under `x64/audio/sfx/`:

```
Mods/x64/audio/sfx/STREAMED_VEHICLES_GRANULAR.rpf
Mods/x64/audio/sfx/RADIO_14_DANCE_02.rpf
```

Use the archives as they come with your PC copy. An archive re-saved by a tool **without encryption** stops the game ("Unencrypted archives no longer supported"); in Mods the app leaves such a file out and says why. Re-save it with OpenIV or use the original.

Whole PC audio archives already work this way: players have used a 412 MB `RADIO_14_DANCE_02.rpf` in place of the 22 MB one for 15 to 20 minute sessions with no audio errors in their logs.

- `x64/audio/audio_rel.rpf` (the sound definitions) from a newer PC version is untested. It may not match this game version: use it at your own risk, and take it out again if sounds break.

## Scripts (`.asi`)

Script Hook V scripts are Windows files. The app runs them in a built-in interpreter, so the same `.asi` file from gta5-mods.com works.

- Put the `.asi` file and its settings (`.ini`) at the top of the Mods folder, for example `Mods/TrainerV.asi` and `Mods/trainerv.ini`.
- You don't need `ScriptHookV.dll`, `dinput8.dll` or an ASI loader. If they're in the folder, they're ignored.
- **Keys:** PC scripts use the keyboard. While a script mod runs, a **🧩 Mods** button shows in the touch controls (top row, next to Settings). It lists the keys your mods use, with the key that opens the menu first, learned from the mod or read from its settings (Simple Trainer: F3 opens the menu; if nothing shows, press F4, which shows or hides it). While a mod's menu is open, a D-pad appears to move through it, and Enter selects.
- **Mod keys and your own buttons** (from v1.5): Settings › Mods › a script mod lists the keys it uses. Give a key another key if two mods clash, or add an **on-screen button** for a key: pick when it shows (always, in any vehicle, or in one car) and an icon (**All icons…** has every system icon, with search). Move and resize the buttons in Edit controls layout. They also show with the Controller buttons touch scheme.
- **Desktop Menyoo** (from v1.5): the newest desktop build runs, as does Menyoo for iOS. Its first start takes about 10 seconds, while the game shows "Loading Menyoo…". Then F8 opens the menu.
- **Typing:** tap **Type** in the 🧩 Mods keys to send the iPhone keyboard to the mod (spawn a car by name, a search box); **Done** sends it. When a script asks with the game's own text box, the same keyboard opens by itself.
- Controller shortcuts work through the touch controls and Bluetooth controllers too (Simple Trainer: RB + X opens the menu, D-pad and A/B to move around). A keyboard connected to an iPad works as well.
- Features that change the PC game's memory directly (some trainer options) stay off. The rest of the script keeps working.
- A script that crashes or freezes is stopped on its own. The game keeps running, and the log says what happened.
- Scripts cost a little speed: Simple Trainer takes about 2 to 3 ms per frame.

## Mods made for GTA V Enhanced

GTA V Enhanced (the 2025 PC edition) stores cars and textures in newer file versions that this game can't read. Many mods ship both versions, in "Legacy" and "Enhanced" folders or with "LegEnh" in the name: use the **Legacy** (original PC) files. In v1.4.1 an Enhanced car stops the game at start (the log says "Code is expecting version 162 but file <car>.yft has version 171"); switch the mod off in Settings › Mods. From the next update the installer leaves Enhanced files out and says why.

In v1.4.1 an add-on car that brings its own engine sound also stops the game at start (the log ends after "Failed to find …_game.dat151"). Switch it off for now; the next update loads those sounds.

## Mods that can't work on iPhone

Two kinds of GTA V script mods need things from Windows that don't exist on an iPhone, so the app can't run them:

- **ScriptHookVDotNet scripts** (C# or VB): you can spot them by a `scripts` folder with `.dll`, `.cs` or `.vb` files, and the mod page asks for "ScriptHookVDotNet" (often with "NativeUI" or "LemonUI"). They need Microsoft's .NET runtime inside the game, which iOS can't host. Many popular script mods are this kind.
- **RAGE Plugin Hook plugins**, including **LSPDFR** (LSPD First Response) and its callout packs: a `plugins` folder and `RAGEPluginHook.exe`. RAGE Plugin Hook is its own PC launcher that starts GTA5.exe and loads .NET plugins into it. Neither the launcher nor .NET can run here.

What does work: Script Hook V scripts (`.asi` files, written in C++), like Simple Trainer. When a mod page lists only "Script Hook V" (and maybe an ASI Loader) as requirements, it's this kind.

## Removing mods

In **Settings › Mods**, swipe a mod to remove it or switch it off. Files you put in by hand: delete them from the Mods folder. Start the game again afterwards. The game's own files are never changed.

## After an update, or when the game stops while starting

Each update loads some mods that the previous version skipped. A Mods folder that worked can then make the game stop. Two things protect you:

- **After an update**, a mod that was switched on but that the previous version didn't use stays off. The app lists those mods once. Turn them back on in **Settings › Mods** when you want to try them.
- **When the game stops while starting** with mods on, the next launch asks whether to start without mods this time. Play then says **Play without mods**. Your mods stay installed, and the next start uses them again.

## Something isn't working

1. Check the log (Settings › This device › Send log to the developer). Every mod file is listed with what happened to it. "Mods: ... ignored" lines say why a file wasn't used.
2. Try the mod alone, with nothing else in the Mods folder.
3. Ask in the **Mods** topic on Telegram, with the mod's name and link.
