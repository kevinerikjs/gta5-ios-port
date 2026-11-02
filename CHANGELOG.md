# Changelog

## v1.5.2

Lighter and steadier, the same version for iPhone and Mac.

### Performance
- **The game needs about 40% less CPU for the same frames.** Measured on an iPhone 13 Pro Max with the built-in benchmark: about 1 CPU core instead of 1.8 at 30 FPS. With the frame rate unlocked, each frame costs about 18% less energy.
- **About 200 MB less memory** on 6 GB iPhones, and about 300 MB less on Macs with 8 GB. The game now gives the memory of 3D models back once the GPU has them, and freed memory really goes back to iOS.

### Adding the game (iPhone and iPad)
- **A step-by-step guide**: Game files › Show me how shows each step with a moving picture. Open the GTA V Port folder, move your game folder or its .zip/.rar into it (touch and hold › Move › On My iPhone › GTA V Port), come back, tap Unpack for an archive, and the app checks every file. It opens by itself the first time there are no game files.
- **Two ways in**: the GTA V Port folder in Files, or a download link. The Choose a folder… and Choose an archive… buttons are gone on iPhone: they failed on many sideloaded installs. A folder you picked in an earlier version keeps working, and the Mac keeps both buttons.
- **An archive in the folder is recognized**: Game files says "Found a game archive" with an Unpack button instead of "Nothing in this app's folder".

### 4 GB iPhones
- **Far fewer missing roads and ground while you drive.** On iPhones that give the game about 2 GB (iPhone 11, 12 and 13 with 4 GB, and others), the game used to throw textures out and load them again thousands of times a minute. Cars drove over nothing and trees floated. It now keeps a smaller safety margin that fits these phones and uses less memory overall. It also stays further from the limit where iOS closes the app.
- **Every graphics preset keeps Ultra Performance's memory settings on these phones**: the textures and draw distance that fit. If you picked a higher preset, this update moves you back to Ultra Performance once; you can still change it in Settings.

### Fixes
- **Alamo Sea water**: after an update, part of the lake by the trailer park could be missing and show bare lakebed as a big hard-edged shape. Fixed.
- **Starting without mods after a crash** could itself crash right away. Fixed.
- **Better default graphics** for 6 GB iPhones on a free Apple ID: Performance instead of Battery, a sharper picture at no measured cost.
- Other bug fixes and improvements.

### Translations
- **Bulgarian is nearly complete** (848 of 852 lines), with fixes to earlier lines and capitalization. Thanks @g_m1sh3vvw!
- **More Turkish** (66 → 207 lines). Thanks Efe Tokdemir!

## v1.5.1

A fix for v1.5, the same version for iPhone and Mac.

- **Driving controls no longer turn into menu arrows with some script mods.** With certain script mods (.asi files) installed, v1.5 could swap the play buttons (gas, brake and the rest) for the menu arrows, Select and Back, with no menu on screen. ATM screens still get their Back button, and an open mod menu such as Menyoo still gets the arrows.

## v1.5

A big update, the same version for iPhone and Mac.

### Missions and story
- **Eye in the Sky**: the scan now finishes. The RT button stays on screen while you hold it on a target, and in the helicopter the Interact button switches on thermal vision, so the mission goes on.
- **Monkey Business** (the dive) and **Barry's "The Drag"** (the stash car): a Y button shows when the mission waits for you to dive or get out.
- **The Jewel Store Job**: the game no longer stops when it autosaves after the mission.
- **The Atomic Blimp and Interaction Menu messages** show once instead of coming back after every start.
- **Coin-operated telescopes** on the beach and the piers open their view after you pay. The game's own animation placed Franklin beside the telescope, so the view never opened.
- **ATMs**: with touch controls, the ATM screen now shows Back (and the menu arrows), so you can leave it.
- **Garages**: you can walk out of a car garage on foot again, and a garage car with mod parts this game doesn't have no longer stops the game when the save loads.
- **The barber** works every time, not just once.
- **"Restart now?"** in the pause menu's graphics settings no longer freezes the game: your choices apply at the next start.
- **Sandbox** shows the Switch character button too.

### Fewer crashes
- **Five crashes that came back again and again in player logs now carry on, as on PC.** They came from add-on car sound packs that didn't load, broken collision data, weather mods asking for clouds that don't exist, a ped model mod in a truck, and a game file read that went wrong.
- **The game no longer stops after its graphics are rebuilt**, for example after a window size change on Mac or when a TV connects.
- **When the game must stop, it says why**: damaged or unreadable game files (with the file's name), a car layout mod, too many add-on cars, or a mod made for another game version. Where a mod caused it, it offers to start without that mod.

### Controls
- **Controller buttons**: an optional touch scheme with every Xbox button on screen (two sticks, A B X Y, bumpers, triggers, D-pad, L3, R3, View and Menu). Settings › Touch controls › Touch scheme. Each button can be moved, resized or hidden in Edit controls layout.
- **HUD layout**: move the character switch wheel, the FPS counter, the phone, notifications, subtitles, names, the stats, the minimap and help messages. Settings › Touch controls › HUD layout. Out of the box they no longer sit on top of touch buttons.
- **"Fire, left hand"**, the button that shows while you aim, can now be moved in Edit controls layout.
- **With a controller**, Settings and Mods stay on screen while the rest of the touch controls hide.
- **120 Hz screens** now get a fixed refresh rate for each frame rate setting, also when you play with a controller and don't touch the screen.

### Mods
- **The newest desktop Menyoo works.** It needs Microsoft's C and C++ runtime, which the app now provides to script mods, so other mods built the same way work too. While a mod starts up (Menyoo reads its lists for about 10 seconds), the game says "Loading Menyoo…".
- **Mod keys**: Settings › Mods lists the keys each script mod uses. You can give a mod's key another key, and add your own **on-screen buttons** for mod keys (show them always, in any vehicle, or in one car). Pick an icon from every system icon, about 7,000, with search. The buttons work with the Controller buttons scheme too.

### Memory and performance
- **4 GB iPhones** (iPhone 11, 12, 13, 13 mini): about 75 MB more for the city, and Ultra Performance drops one more detail level from the biggest textures. On our recorded drive at a 4 GB iPhone's limit, the time the game spent struggling to keep textures loaded fell from about 70% to about 14%, with the same FPS.
- **Cheaper thread wake-ups** in the engine, and the recommended presets now limit heat on the iPhone 12 Pro and 12 Pro Max. In the built-in benchmark on an iPhone 13 Pro Max, v1.5 held its 30 FPS limit where v1.4.7 averaged 25.

### Devices
- **iPhone Duo**: the game fills the inner screen, and folding or unfolding while you play keeps the game going. The controls stay within thumb reach on the inner screen.
- **Built with Xcode 27** (the iOS 27 SDK). iOS 16 is still supported.
- **Stretched clothing**: a spike that stuck out of one gang jacket is gone.

### Bug reports and ideas
- **[fivestarport.site/report](https://fivestarport.site/report/)**: report a bug or suggest an idea in any language. It finds the same report if it's already known, so yours counts on it, and you can vote on what gets fixed next and follow your report until it's fixed. After Settings › This device › Send log to the developer, the app offers to open it with your log attached.

### Languages
- **New community translations** from the Translate page: Bulgarian by g_m1sh3vvw_ and Turkish by Efe Tokdemir (both new), more Arabic by @uk9_v and hoSAM, more Uzbek, and a Latin American Spanish fix by Hot.

Other bug fixes and improvements.

## v1.4.7

The same version for iPhone and Mac.

### Missions
- **Eye in the Sky**: the helicopter camera now aims and zooms. The mission reads the camera from the "scaled look" controls, which stayed at zero in this port, so the camera didn't move on touch or controller. They now follow the normal look controls. On touch, drag on the right side to aim and use the left side to zoom; on a controller, the right stick aims and the left stick zooms.

### Languages
- **Simplified Chinese** no longer crashes at every load. This game build's Simplified Chinese text files make the game stop while loading, so with Simplified Chinese picked, the game's own text shows in Traditional Chinese for now. The app's menus stay in Simplified Chinese.
- **New community translations** from the Translate page: Ukrainian by @waven and Filipino by Ricjayson (both new), and more Arabic by @uk9_v.

### Graphics
- **Changing the resolution during play no longer crashes on iPhone and iPad.** The change now applies the next time you start the game, and Settings says so. On Mac it still applies right away.

### Mods
- **Script mods that need more than a frame keep running.** The ASI interpreter stopped any script mod that ran longer than one frame without waiting, which is what Menyoo does while it starts. Such a mod now continues over the next frames; one that never waits is still stopped after a long while. Tested with an iOS build of Menyoo.
- **Mods still packed in the Mods folder** (.zip, .rar, .oiv) are listed in Settings › Mods under "Still packed in the Mods folder". The game can't use a packed mod; tap one to install it. A .7z is listed too, but the app can't open 7z yet: unpack it first, then install the files.

### Heat and performance
- **Less work per frame.** The game's frame limiter used to spin on the CPU for the last 1-2 ms of every frame, waiting for its time. It now sleeps that stretch instead, with the same frame pacing: in the simulator the render thread used about 40% less CPU.
- **Logs show where the CPU goes.** The log now lists the CPU each part of the game uses (every 10 s), and every 5 minutes the functions the busiest threads spend their time in. Sending a log after a long session helps cut more heat in future updates.

### Updates
- **Update popups work again.** The app asked GitHub for new versions, and GitHub is gone. It now asks fivestarport.site, so from this version on, a popup tells you when the next update is out.

Other bug fixes and improvements.

## v1.4.6

A quick update for iPhone and Mac.

### Memory
- **More room for the game on iPhones and iPads with 8 GB or more (with extra memory) and on Macs.** The game engine keeps its data in one block of memory reserved when the game starts, and on most devices that block was 4 GB. In player logs, every time the block filled up the app still had 2 to 4 GB of its memory free, and the game then stopped loading the city: grey ground and late textures, most of all while driving fast. The block is now the app's memory limit less 1 GB, up to 7 GB: about 5.5 GB on 8 GB iPhones with extra memory, 7 GB on 8 GB iPads with extra memory and on Macs. The memory guard still stops loading before iOS's limit. On a recorded drive in the simulator (Max preset, an 8 GB iPhone's limit), the guard had to hold loading back half as often, with the same FPS. If iOS doesn't allow a block that big (installs without the extended address space), the app takes the biggest one iOS allows, as before.

### Mods
- **Debug text on screen**: some players saw the game's developer debug text: small blue labels like "runVendingMachine", or "#Scripts", "Active Trackers" and "OVER BUDGET". This game build kept a developer shortcut: pressing B turned it on while a script mod had the keyboard. B no longer does that. (Restarting the game always cleared it.)

### Logs
- **The run where the game stopped is kept until you send a log.** The app keeps only the last two runs, so restarting a couple of times after a stop pushed the stop out of the log you sent. Now a run that stopped (the game stopped with a message, or the app ended while the game was running) is kept on its own and goes first in Settings › This device › Send log to the developer (and Share log), however often you start the game again.
- **iOS's own report of why the app ended** (iPhone): when iOS closes the app for memory, or the app crashes without a message, the next start adds iOS's report to the log (MetricKit: the reason, and for crashes where it happened).

Other bug fixes and improvements.

## v1.4.5

The same version for iPhone and Mac (the Mac app is in [gta5-macos-port](https://github.com/kevinerikjs/gta5-macos-port)).

### Self Radio
- **Your own music on the car radio**, as on PC: add songs in Settings › Self Radio › Add songs…, or copy them into On My iPhone › GTA V Port › Self Radio (subfolders work too; on Mac, Show the Self Radio folder in Finder). MP3, M4A/AAC, ALAC, WAV, AIFF and FLAC play; songs from Apple Music or Spotify are protected and can't be added.
- With 3 songs or more, the station is in the radio wheel: the smiley next to Los Santos Rock Radio (the game calls it User Music FM). This game's audio data had no Self Radio station at all, so the app now adds one; with fewer than 3 songs nothing changes.
- **Play order**: Shuffle (the default) and In order start each song from the beginning; Like a radio station joins songs midway, as the PC's default does. Shuffle no longer repeats the song that just played.
- **Next song**: a button next to Radio while Self Radio plays.

### 4 GB iPhones
- **Fewer grey and missing textures while driving**: on iPhones that give the game about 2 GB, Ultra Performance draws detail a little closer and keeps what it just loaded, instead of throwing it out and loading it again. On a recorded drive the ground matched the no-limit drive much more closely, and the game re-read about 140 MB per 10 s instead of up to 970 MB. Settings › This device › Experimental › Steady city on low memory turns it off.
- **Lighter 3D models in memory** (on by default on 4 GB iPhones): the game kept a second copy of every 3D model after the GPU had it; about 80 MB of it goes back to iOS.
- A one-time note when you start on an iPhone with little memory, and a red ⚠️ next to the FPS counter there, so a screenshot shows it at once.

### Mods
- **After a failed start**: if the game stops while starting with mods on (or iOS closes it while loading), the next start offers "Start without mods". Your mods stay installed; the game reads them again at the start after that.
- **Across updates**: each start notes which switched-on mods the game used. From the next update on, the first start of a new version switches off the mods the old version had on but didn't load, and says which.
- **Add-on cars made for newer PC updates spawn**: cars whose textures name a texture set this game version doesn't have (for example the Honda Fireblade CBR1000RR-R) waited 30 s and failed; they now use the game's shared vehicle textures.

### Controls
- **Help messages can move**: Settings › Touch controls › Help messages: Top left (the game's place), Top right (the default when the map is at the top), Bottom middle, or Custom, where you drag the box anywhere.
- **BMX**: a Jump button (hold longer to hop higher).
- **D-pad prompts in missions**: when a mission asks for the D-pad (like calling elk while hunting with Cletus), on-screen buttons appear for as long as the hint shows.

### Display
- **40 FPS** on iPhones with a 120 Hz screen (ProMotion): Settings › Graphics › Frame rate. Smoother than Unlocked when the game runs between 40 and 60.
- A new frame rate applies right away while playing.

### Game files
- **Play without game files** opens Game files and says what's missing, instead of starting into a stop when the game server doesn't answer.
- **"Updated and my files are gone"**: the Game files screen explains that installing with another sideloader or Apple ID makes a separate copy of the app with an empty folder.
- **LiveContainer**: its folder picker hands your game folder over once GTA V Port's **Fix File Picker** and **Use LiveContainer's Bundle ID** are on (in LiveContainer's settings for the app, under Fixes; found by a player). The Game files screen now names both, and shows the tip first when the app runs inside LiveContainer.

### Mac
- Settings › Self Radio and Settings › Mods open their folders in Finder.
- Settings › This device shows how much of the Mac's memory the game may use, instead of the iPhone's "Extra memory: off".

### Translations
- More Arabic (93 → 133 lines) and Vietnamese (124 → 155), and Uzbek is new. Thanks @uk9_v, @lekhoi2811 and @muhammadiminov_007!

Other bug fixes and improvements.

## v1.4.4

### Missions
- **Friend Request**: the mission waits for a channel change on the couch ("Find Weazel News"), then lets you call Jay Norris from 1:17 to 2:50 of the presentation, when he holds the phone up on TV. With a black TV neither moment could be seen, so players waited forever or missed the call. The couch now has arrow buttons for the TV (channel and volume), and a note says what to do and when ("Call now: … Phone › Contacts › Jay Norris, before 2:50").
- **Phone camera**: while the phone is out, its touch buttons show A, B and X, the letters the game's own hints name ("Take Photo A", "Send X"); Scouting the Port's photos and sending them to Ron are easy to find.

### Mods
- **Several add-on cars**: a loose `dlc.rpf` (or "dlc 2.rpf", as the Files app renames a second one) becomes an add-on pack of its own; two mods that use the same pack name both load (the second as `name_2`); the same car installed twice loads once.
- **Changing mods while playing**: switching a mod off or removing it in Settings › Mods during play pulled its files away from the game ("Game file missing from your folder", then a stop). Such changes now wait until the game starts again, and the row says so.
- **Unencrypted archives**: an archive saved without encryption stopped the game ("Unencrypted archives no longer supported"); the app leaves it out and says to re-save it with OpenIV or use the original.
- **Removing hand-copied mods**: folders with read-only files can be removed in Settings › Mods.
- The log no longer fills with "ENTITY SET FOUND" lines while a script mod like Simple Trainer runs.

### Game files and saves
- **Import a Story save**: Settings › Game mode › Import a Story save… puts a save from a PC or a friend (SGTA50000…) into a free slot.
- **Folder picker**: on many sideloaded installs iOS doesn't hand the picked folder to the app (logs show it copying the whole folder instead). The Game files screen has "Open GTA V Port in Files": move the game folder there and come back, the app finds it by itself. Closing the picker without a folder explains this.

### Display
- **Subtitles above the home bar**: the subtitle line sat under the iPhone's home bar; it now sits 5% higher (Settings › Touch controls › Subtitles above the home bar, on by default on iPhones with a home bar). The game's own Safezone Size doesn't move subtitles.

### Performance
- **Less CPU**: one part of the game engine (its lowest-level code, including drawing and controller input) was built without optimization; it now is. In the simulator the app uses about 17% less CPU at the same FPS: less heat, more headroom.
- **Sharper textures for longer on iPhones before the 15 Pro**: the texture budget follows what textures really take on your iPhone (measured while you play) instead of a fixed half.

### Experimental
- **Compressed see-through textures** (on): on iPhones before the 15 Pro, leaves, fences, smoke and decals (BC3 textures, about 4 in 10) stay compressed instead of taking 4x the memory: in the simulator's iPhone mode the textures at the same spots went from 600 to 427 MB. Soft see-through edges can show steps; Settings › This device › Experimental turns it off.
- **More engine memory** (off by default): about 270 MB more room inside the game's 4 GB on 6-8 GB iPhones, for fewer stops after long play: turn it on in Settings › This device › Experimental (and off again if the game stops more often).

### Stability
- **Changing the resolution during play**: a resolution change in Settings (or a TV) could still stop the game right after the screen came back ("Invalid call_indirect"; v1.4.3's fix covered the render thread, this one the main thread). A render phase the change destroyed stayed in the game's list; it's now dropped.
- **Long sessions on 6-8 GB iPhones**: near the end of the engine's 4 GB, v1.4.3's memory guard counted small free pieces as room, kept loading, and the game could stop on a big load ("Read request … some of which are NULL"). The guard now counts those pieces only while there's real room left.
- **Random stops with "Error allocating … bytes in heap 0"**: a background worker sometimes picked up a job whose memory had already been freed and asked for a 3.7 GB buffer (or called a garbage function). It now drops such a job and keeps going.

### Stats
- **Anonymous play stats**: a random install ID, the app and iPhone model, play time, FPS, missions started and failed, engine stops and Cheats rows used; no names, saves, game files, mod names or IP addresses. Exactly what is sent: [docs/STATS.md](docs/STATS.md).
- Other bug fixes and improvements.

## v1.4.3

### Missions
- **Trackify works**: the game files ship the phone's Trackify app as an empty stub, so it never ran, and asking for it jammed the game's script loading for the rest of the session (respawn freezes, phone apps and missions that never loaded). The port now does the app's job on the phone's own Trackify screen: the sonar with the mission's target, direction from where you face, distance and depth, and the ping that speeds up as you get closer.
- **The Merryweather Heist (Offshore)**: the heist opens Trackify itself and waited for it to load for good; it now goes on. The submersible holds out to 200 m (the game kept a script's crush depth for one frame only, so the heist's own limit didn't hold and the sub imploded beside the device at 180 m).
- **Street race result screens**: "1st Place … Retry / Continue" ignored every button and Pause. Making the pause input exclusive disabled about 70 inputs that share an unbound keyboard key, Continue and Retry among them; unbound keys no longer count.
- **By the Book's tooth**: the tool cart keeps its arrows, and at "Rotate to pull it out" the RT button stays held while the right side becomes a stick. The game counts only a fast rotation (about 3 to 4 turns a second).
- **Scouting the Port**: the Handler's arm lowers again, also after a mission retry (two of its flags could keep garbage from reused memory, so it only went up).
- **Mission failed after dying** shows Retry / Exit instead of the play buttons.
- **"Loading Story Mode" hang**: leaving a replayed mission or loading a save waited forever on a debug log flush; it no longer does.
- **Chop**: the switch button shows whenever the game waits for a character switch, to get back to Franklin.

### Controls
- **Detach trailer** button while a vehicle pulls a trailer.
- **Cargobob hook** button in any Cargobob.
- **"Press → to pick up a container"** (the docks crane) gets the Interact button, and **"Detonate the explosives"** (bombs a mission planted) gets Detonate.
- **Minimap**: Settings › Touch controls › Minimap: bottom left, top left or a custom spot (drag and pinch). Tap the minimap for the full-screen map; pinch to zoom it.
- **Sprint button setting**: with it on, pushing the stick to its edge no longer sprints.

### Sound
- Sound restarts after interruptions that failed to restart or never ended, and the game plays alongside your own music app.
- **Fuller engine sounds with your own PC files**: the Mods guide explains how to use your own PC copy's audio archives from the Mods folder ([docs/MODS.md](docs/MODS.md#your-own-pc-audio-files)).

### Languages
- **Translate the app** on the website's Translate page ([docs/TRANSLATING.md](docs/TRANSLATING.md)); the app's language picker lists the new languages. First community translations: Vietnamese by @lekhoi2811 and Arabic by @uk9_v (the rest falls back to English until more lines are translated).

### Stability and performance
- **Crash after a resolution change or connecting a TV**: the main thread rebuilt graphics objects while the render thread could still be drawing with them ("Invalid call_indirect"); it now waits for the render thread first.
- **Add-on cars and bigger mod packs**: more room for vehicle handling entries (3000), scripts, scenarios and physics objects, which stopped the game when full.
- **Experimental, on by default** (Settings › This device can switch each off):
  - Smarter texture loading: the memory guard counts the free space in the texture pool. It used to hold back loading while most of the pool was empty, and the ground went grey after about 10 minutes.
  - Lighter big textures: on iPhones before the 15 Pro, the sharpest level of only the biggest textures is skipped.
  - Faster engine threads: engine threads run at a higher priority, and GPU queries go out at once (for the FPS drop after a few minutes).

### Logs
- Send log can include your latest save, so a problem can be reproduced exactly.
- Logs say which mission is running, what a stuck prompt waits for, and streaming health.
- The version number is right again (v1.4.2 said 1.4.1).
- Other bug fixes and improvements.

Thanks to @abtastic-hub for the reports behind the trailer, Handler, Chop and engine sound changes ([#20](https://github.com/kevinerikjs/gta5-ios-port/issues/20)), to @lekhoi2811 and @uk9_v for the first translations, and to everyone in the Telegram group who sent logs and saves.

## v1.4.2
- **Cheats menu** (Settings › Cheats, [docs/CHEATS.md](docs/CHEATS.md)), contributed by [@gfejer](https://github.com/gfejer) ([#22](https://github.com/kevinerikjs/gta5-ios-port/pull/22)): a searchable vehicle spawner with the game's own vehicle names (it keeps your last two spawned vehicles, so they don't pile up), God mode and Never wanted switches that last until you turn them off, repair and clean, time of day and weather, next to Set money and the game's own story cheats. Everything runs on the game's main script thread.
- **Game files download continues**: a dropped connection is retried for 30 minutes (iOS pauses the app while the phone is locked); after the app was closed, Game files offers "Continue the download", which resumes from the saved byte. Normal (non-solid, single-volume) RAR5 archives continue in the middle too, not only zip.
- **TVs no longer crash the game**: every TV switched on or channel change queued a video command for a thread this build doesn't run, and after about 30 the game stopped with "bwMovie command queue flood". Those commands are now dropped.
- **Add-on cars**: room for 1500 vehicle handling entries instead of 560, so installing several add-on cars no longer stops the game with "CHandlingObject Pool Full". Add-on cars that ship their own engine sounds (`.rel` audio files) load instead of stopping at "Failed to find ..._game.dat151".
- **Mods made for GTA V Enhanced** stopped the game ("Code is expecting version 162"). The loader checks every mod file before the game starts and leaves those out; the installer says to use the mod's Legacy version, and names ScriptHookVDotNet scripts and RAGE Plugin Hook plugins (LSPDFR) as not supported.
- **Swipe camera**: the touch controls no longer switch to the menu layout after a swipe, and aiming from a vehicle works (mouse movement put the game in keyboard-and-mouse mode, where the touch controls' controller presses were ignored; aim and shoot now also press the mouse buttons).
- **Missions get the buttons they ask for**: the buttons a help message names (for example "Hold RT") now appear however the mission reads them; while the help asks for the right stick, the right side of the screen is a stick, even with the swipe camera, and a trigger asked for together with the right stick latches (tap to hold, tap to let go). Prompts that ask for the context input get the hand button (standing up from a couch, drinking at Trevor's), and playing as Chop keeps the Switch character button to get back to Franklin.
- **Scouting the Port**: the Handler gets Raise and Lower arm buttons; on the steering stick the arm could be raised but hardly lowered.
- **Calls while walking** no longer take away the walking controls; the Phone button opens the phone to answer.
- **Friend Request**: the Lifeinvader presentation plays about 3 minutes on a black TV (the game files have no TV videos); a note shows its progress.
- **Settings › Graphics**: Textures, Shadows, Reflections, Draw distance, Grass, and Traffic and people can be set apart from the preset.
- **Pause menu**: no more "You made changes but did not apply them" on every tab change (the menu's lowest shadow setting is above the lighter presets'; "Yes" raised the shadows). Help boxes for text the game files don't have no longer show raw labels like "HELP_DCK missing".
- **Shop menus on touch** (barber, Los Santos Customs) keep their arrows.
- Other bug fixes and improvements.

## v1.4.1
- **Mods work as downloaded** (see [docs/MODS.md](docs/MODS.md)): replacement cars and characters (files inside the game's archives, like `x64e.rpf/levels/gta5/vehicles.rpf/oracle.yft`), add-on cars (`dlc.rpf` packs, added to the game's pack list automatically), OpenIV packages (`.oiv` files and unpacked packages, with their text and XML edits) and data files. PC/OpenIV paths work; names match regardless of case.
- **Script Hook V scripts and trainers** (`.asi`): the app runs them in a built-in x86-64 interpreter (Blink, ISC license), with the Windows functions they use and the Script Hook V API, so the same file from gta5-mods.com works. Simple Trainer runs at about 2 to 3 ms per frame. Features that patch the PC game's memory stay off; a script that crashes or freezes is stopped on its own. ScriptHookVDotNet (C#) scripts aren't supported.
- **Settings › Mods:** install a mod by picking the downloaded file (zip, rar, oiv, asi or loose files). The app works out where each file goes, using the game's own index of its files, shows the plan first, and leaves out what it can't place safely (and says why). Each mod gets its own folder and can be switched off or removed.
- **Mod controls:** while a script mod runs, a Mods button in the top row opens its keys (the key that opens its menu first, learned from the mod or read from its settings), a D-pad shows while its menu is open, and Type sends the iPhone keyboard to the mod (car names); mods that ask with the game's text box get the same keyboard.
- **Logs show when mods are active**, and the app explains once that mods can break things and where to ask about them.
- **Fewer crashes on 6 to 8 GB iPhones** (GTA-70): the memory guard also watches the engine's own 4 GB address space, which v1.4 could fill.
- **iPhone 8, 8 Plus and X** (GTA-68): if iOS refuses the 4 GB engine reservation the app tries smaller ones, and says so instead of freezing when none fits.
- **Yoga** (GTA-37): the poses read both sticks on the touch controls.
- **In-game phone browser** (GTA-71): websites scroll with the swipe camera on.

## v1.4
- **Sandbox runs smoothly again on 4 GB iPhones.** Converting the game's most common texture format for the iPhone's GPU is 12.7 times faster (same output, bit for bit), so the world streams in without the lag v1.3.4 brought (Sandbox went from about 15 back to 30 FPS on a 2 GB memory limit).
- **New Ultra Performance preset** (Settings › Graphics) for iPhones with little memory, recommended automatically under about 2.6 GB. It keeps less of the world in memory so it doesn't run out.
- **No more "sea of clay"** when memory is low: when the memory guard holds the game back, it now asks the game to free its own unused models, so new areas load their detailed models and textures.
- **Guns show and fire in Sandbox again:** the memory guard makes room for the weapon you select.
- **The GTA VI test map and Sandbox no longer crash** soon after loading.
- **Play on a TV** with AirPlay or an HDMI adapter: the game shows on the TV, the controls stay on the phone.
- **Sharper upscaling** (Settings › Graphics): MetalFX upscaling when the game renders below the screen's resolution.
- **Mods folder:** Files › On My iPhone › GTA V Port › Mods. Put a replacement game file there at the same path it has in the game files (for example `common/data/handling.meta`); it's read when the game starts (#3).
- **Mission button row:** when a mission or minigame asks for a button that has no touch button (LB/RB/LT/RT/X/Y, LT and RT together, stick clicks), a button for it appears while it's asked for. This covers the yoga breathing, Skip Mission ("Press X"), torture and the container crane.
- **Barber and shop menus work** (#19). The scripts ask for two Scaleform movies (the hair colour switcher) that no game version players have contains; the barber waited for them and gave up without its menu. A missing movie is now replaced by a blank one and logged, so the menu opens. Menus that lock player control get Accept/Back, with the left side free when the menu reads the stick.
- **Aim and Duck buttons while driving** (#15).
- **Phone calls no longer take over the driving controls** (#19), and the phone button always opens the phone (missions that wait for it no longer get stuck).
- **The sprint button sprints** instead of jogging, and **character switching works in helicopters, planes and back from Chop**.
- **Set money saves properly** (#19): it sets the game's own balance, so spending lowers it and the amount survives saving and loading.
- **Fewer crashes:** taking a photo with the in-game phone (#16), opening the pause map or watching a TV (the Friend Request mission, #19), changing the resolution while playing, and Simeon's first mission.
- **The pause menu responds at once** instead of after a few seconds, and the mission passed screen shows real button icons instead of "???".
- **No more "missing" text labels** (for example after a stunt jump): the release text files are used.
- **Your outfit stays** after restarting the game.
- **Sound comes back** after a call or after leaving the app.
- **Taking a screenshot for a log no longer turns the screen black.**
- **Fills the screen on iPhone 17 Pro Max.**
- **Home screen fits long languages** (Russian and others); the top buttons are icons in every language, and the story cheats list follows the app's language.
- **The folder picker explains** how to choose the game folder.
- **New button icons** for every touch button.
- **A "Loading…" note** shows during long loads after a death or between story scenes, so they don't look like a freeze.

Thanks to @k49kg9xmsd-prog, @abtastic-hub, @mmts7hrnb5-jpg, @Blue7366 and @sonubhutani1979-afk for the issues behind these fixes (#3, #15, #16, #18, #19), and to everyone in the Telegram group who sent logs and screenshots.

## v1.3.4
- **Story money no longer resets to $0.** Right after a save loaded, a game script set every character's cash to $0, so each save after that kept $0. The app now ignores that one write while a save loads (#10). Saves made after the bug already hold $0, so money lost before this update doesn't come back.
- **Downloading the game in the app works with more file hosts.** The app asks for the file exactly the way Safari does, in one request. If a host shows a bot check (such as Cloudflare's), the link opens in the app's browser, which passes it and hands the download back. If a site refuses the download because of the ad blocking, the browser turns it off for that site; a shield button does the same by hand.
- **Fewer crashes after long jumps** (character switches, mission skips, respawns): the game could try to draw part of the map it had just unloaded, and crash.
- **Update notice.** When a newer version is out, the app says so once and links to the Releases topic in the Telegram group.
- **Settings are grouped:** Graphics, Controls, Story cheats, Game mode and language, Game files and This device each have their own page.
- **The game pauses when you leave it.** Control Center, a notification, a call, another app or the app's own Settings now open the game's pause menu, and it stays paused until you resume (#11). A story cheat picked from Settings leaves the pause menu by itself.
- **Set money** (Settings › Story cheats): type an amount and the character you're playing gets it. Save the game to keep it.
- **Sprint button** (Settings › Controls, off by default): tap it while moving to sprint until you let go of the stick; hold it to open a parachute.
- **Airplane right stick** (Settings › Controls, off by default): a second stick for planes; drag up or down to set the throttle (it stays where you leave it), left or right for rudder. Helicopters keep their buttons. Thanks to GitHub user @m1337v (#12).
- **Game files that fail to read are named in the log**, and a read the system interrupted is retried instead of failing. Thanks to GitHub user @m1337v (#13).
- **Less texture memory on iPhones.** The most common texture type is now stored in a format the iPhone's GPU reads directly, at half the memory of before.
- **Audio uses a little less CPU:** the game's music and speech are decoded natively.
- **Extra memory is asked for by default** by the Mac script; use `--free` for a free Apple ID.

Thanks to @m1337v for the airplane right stick and the file read fix (#12, #13), and to @aliiscoding2122, @k49kg9xmsd-prog and @phakamaec for the issues behind the money fix, the pause and the version fix (#10, #11, #14).

## v1.3.3
- **Runs on iOS 16.** The app now installs on iOS 16 as well as iOS 17 and later.
- **No more crash at the end of Marriage Counseling** (the Vinewood Hills fences). The engine wrote the list of where a model's pieces are in memory one entry past the space the model reserved for it, which broke the fence model. That same overflow hit other models too, so it may fix other rare glitches as well.
- **The game's intro plays when you press Play.** The original Rockstar intro runs while the game loads behind it, instead of the blue loading log. Tap to skip.
- **Runs cooler and stutters less.**
  - The game's audio processing uses about a third less CPU (the whole app about 12% less, measured on an iPhone 13 Pro Max).
  - The game no longer plans its textures as if every phone had 4 GB of video memory; the texture budget now fits your phone's memory.
  - New switch, Settings › Graphics › Steady frame rate when hot: lowers the frame rate while the iPhone is hot for fewer stutters, and raises it again once it cools down. Off by default.
- **No more app-wide lag and "stuck" buttons late in a session.** The game could print millions of log lines, and each one went through the app's main thread, so menus lagged and buttons acted as if held. Thanks to the player who traced it.
- **No more lock-ups after long sessions on phones with lots of memory.** The game's memory was capped at 4 GB even where the phone allowed more; phones with a limit of about 7.5 GB or more now give it up to 6 GB, and the app backs off loading instead of retrying when the game's memory is full.
- **Memory cap**, Settings › Graphics: limit how much memory the game may use (Automatic by default). Lower it if the game closes on its own.
- **Story cheats in Settings.** While playing, Settings lists the game's own cheats (invincibility, health and armor, weapons, wanted level, Buzzard, Comet and more); tap one and the app enters it for you. Thanks to GitHub user @ITSUPERVISOR (#9).
- **Steering buttons**, Settings › Touch controls: Left and Right buttons instead of the steering stick in cars, bikes and boats.
- **Phone keypad with touch controls.** A new button on the phone controls (the controller's X) opens the keypad for a custom number and the phone's other options.
- **Taxi rides work with touch controls** (Story mode; Sandbox has no taxi service). As a passenger, Left/Right change the destination, Select picks it, and there are Hurry up, Stop and Exit buttons (#6).
- **The aircraft weapon button switches weapons** (cannon and missiles) instead of changing the radio station.
- **Game files without the GTA VI test map work.** Some copies of the game leave out the test level; the file check no longer calls them incomplete, and the GTA VI test map button greys out instead.
- **Settings during play only shows what works during play.** Game mode, Sandbox map, game files, graphics presets and frame rate apply at the next start, so they're hidden while you play.
- **Telegram links** on the start screen and in Settings. The Telegram group is the official place for updates and help.
- **One IPA for everyone.** It works with SideStore, AltStore and Sideloadly, and gets the extra memory where your account allows it.
- **Clearer logs.** Hundreds of engine messages that printed as empty "Error:" lines now show their text, repeats are collapsed, sent logs keep the start of the run as well as the end, and logs report heat, CPU use and stutters every 10 seconds.

Thanks to everyone who sent logs with exact failures and their own analysis: those reports found the Story mode bugs fixed here (the Marriage Counseling crash, the lock-ups after long sessions, the lag with stuck buttons).

## v1.3.2
- **Fewer missing and blurry textures.** The app used much more memory for textures than the game planned for, so the game threw detailed textures away to stay under the limit.
  - iPads and Macs with Apple chips keep textures compressed: 2 to 8 times less texture memory.
  - iPhones store the most common texture type at half the size.
  - A spare copy of every texture is no longer kept in memory.
  - The game stops loading new detail a little before the memory limit instead of loading and dropping the same textures over and over.
- **13 languages** for the app's menus (English, French, Italian, German, Spanish, Latin American Spanish, Japanese, Korean, Polish, Brazilian Portuguese, Russian, Simplified and Traditional Chinese). The game itself switches language the next time it starts. Thanks to GitHub user @k49kg9xmsd-prog (#4).
- **Swipe to look** (Settings › Controls › Camera): swipe anywhere to move the camera. It moves the game's mouse, so it is smooth in every direction. Sensitivity goes up to 15x, 5x by default. Thanks to GitHub user @k49kg9xmsd-prog (#4).
- **Pause map:** drag on the left side of the screen to move the cursor and set a waypoint anywhere, not only on places in the legend.
- **Shop menus** (Ammu-Nation, clothes and others) show the D-pad so you can move through them.
- **New vehicle buttons:**
  - Tow trucks: tow hook, and Raise and Lower for the tow arm.
  - Convertibles: roof up and down.
- **Switching aircraft weapons** no longer opens the radio wheel.
- **GTA VI test map** gets the phone, cheats and free roam, and puts you back on land if you fall off the map.
- **Fixed a crash on two fences in the Vinewood Hills** ("Invalid fixup").
- Fixed a crash when pedestrians spawn at a crowded spot.
- The Replay editor no longer says there's no space left.
- Props no longer flicker in the first time you see them.
- Thanks to tomergamertv on Telegram for the last three.
- **New start screen and Settings background.**
- **FPS counter switch** in Settings › Graphics.
- **Settings shows whether extra memory is on** for your install, next to the memory limit.
- Logs say more: the app version, where your game files are, free storage and memory, and which engine function a crash happened in.

## v1.3.1
- **Los Santos Customs works.** Driving in no longer leaves you stuck inside with no menu: the shop waited for a texture the game files don't include. A few labels in the shop may be blank.
- **Interact shows in vehicles too** when the game asks for it ("Press D-pad right to ...").
- **The app version shows** under the title on the start screen, in Settings and in the log. Please mention it when you report a problem.

## v1.3
- **No more freezes when a TV comes on.** The game waited forever for TV and cutscene videos the game files don't include (Franklin's aunt's house, Michael's house, the Complications intro). Those videos are now skipped.
- **The minimap shows the map** (it was blank in every earlier version, and in the browser version).
- **New start screen** with new artwork, a new app icon, and a matching Settings look.
- **Game files screen:**
  - The app finds your game anywhere in its folder, however deep, or in any folder you choose (even On My iPhone itself).
  - **Every game file is checked.** If something is missing or damaged, it names the file and the likely cause (usually unpacking stopped early for lack of storage). **Play anyway** if only a few files are off.
  - **Unpack in the app:** paste a direct link to your zip or rar, or pick the archive in Files. It unpacks as it downloads, so you need about 21 GB free, not double. Dropped connections resume.
  - **Download pages** ("tap Download to start") open in a built-in browser with ad and pop-up blocking; the app takes the download over by itself.
  - Downloads keep going while you look around the start screen, Settings or the controls layout.
- **Sandbox map choice:** GTA V, or the GTA VI test map that comes with the game files.
- **Controls:**
  - New buttons that show only when they apply: special ability (with its charge), detonate (sticky bombs placed), interact (when the game asks), zoom while aiming, and weapons inside a weapon wheel slot.
  - Radio: tap for the next station, hold and point at a station on the wheel. Controllers pick with the right stick.
  - Cars: tilt in the air with up/down on the stick.
  - Aircraft: throttle and rudder buttons instead of the hidden throttle lever.
  - Quick taps are no longer missed.
  - All new buttons can be moved in the controls layout editor, which has an Aircraft tab now.
- **Keyboard and mouse** (PC controls) when connected; touch controls hide when both are connected.
- **Apple Game Mode** turns on while you play.
- Changing graphics in the game's own pause menu can no longer stop the game from starting.
- Crash logs survive reopening the app several times before sending.

## v1.2.2
- New app icon.
- **Edit controls layout** (start screen or Settings): move, resize or hide every touch button, on foot and in vehicles.
- **Accept / Back buttons** on screens like Mission Failed, so you can retry without a controller.
- **Switch character** button in Story mode (hold, drag toward a character, release).
- The **phone stays up** when you get into a vehicle; Back closes it.
- Touch controls **hide while a game controller is connected** (setting, on by default).
- **Frame rate 30, 60 or Unlocked** (up to 120 Hz on ProMotion iPhones).
- Default camera look speed doubled.
- **Send log to the developer** in one tap; the log records memory and file-loading health every 10 seconds.
- README: "Get the most performance" guide (SideStore + GetMoreRam).

## v1.2.1
- Move your game folder into **Files › On My iPhone › GTA V Port** and the app finds it by itself.
- Picking the wrong folder now explains what to pick instead.
- Any folder above the game folder can be picked; folder picks are logged.

## v1.2
- **Play from a folder on your iPhone**: no server, nothing streams while playing.
- New **Max** preset, every preset selectable, separate resolution setting that changes while playing.
- After a launch that runs out of memory, the next start explains it and lowers the settings.
- **Share log** in Settings.

## v1.1
- **Native Metal renderer**: about 2.2 to 2.6× the frame rate of v1.0 and about 700 MB less memory.
- **Story mode or Sandbox**.
- **Download all game files** to the phone (streaming route).

## v1.0
- First release: build the iPhone app from your own game files on a Mac, streaming the files from your computer over Tailscale.
