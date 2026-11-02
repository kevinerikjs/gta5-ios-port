# Questions and answers

The same answers the helper bot gives in [Five Star Port on Telegram](https://t.me/fivestarport), generated from its knowledge base at every release. Something missing or wrong? Ask in the group or open an issue.

- [Install and signing](#install-and-signing)
- [Updating](#updating)
- [Game files](#game-files)
- [Extra memory](#extra-memory)
- [Performance and graphics](#performance-and-graphics)
- [Controls](#controls)
- [Missions and Story mode](#missions-and-story-mode)
- [Mods](#mods)
- [Features](#features)
- [Mac](#mac)
- [Crashes and logs](#crashes-and-logs)
- [About the port](#about-the-port)
- [Other](#other)
- [Known issues](#known-issues)

## Install and signing

### SideStore or AltStore won't sign in with my Apple ID (error -80045, stuck on anisette). How do I fix it?

Errors like -80045, "bad credentials" or a sign-in stuck at anisette come from Apple's servers or the sideloader, not from the app. Check these first: LocalDevVPN (App Store) is installed, opened and connected (VPN icon at the top); no other VPN app is on, since only one VPN runs at a time; and no anti-revoke DNS profile is installed, as it can block Apple's servers. If SideStore says the pairing file is missing or invalid, make a new one on a computer as SideStore's guide shows and import it. Then update SideStore (players had luck with the nightly), switch the anisette server and sign in again with a fresh two-factor code. When Apple refuses everyone, waiting a few hours helps. Ask in the Install topic with the exact error if it keeps failing.

### Where do I download the IPA, including the latest version?

The newest IPA is posted in the Releases topic of the Telegram group (https://t.me/fivestarport/786): join the group, the newest post there is the newest version, the iPhone IPA and the Mac zip together. It's not on the App Store, and IPAs from other places can be old or modified.

### How do I install the game, and where do I start?

Start with the setup guide in the Start here topic of the Telegram group, or the install guide at fivestarport.site/iphone/. In short: 1) install a sideloader (SideStore or AltStore, set up once with a computer); 2) get the IPA from the Releases topic (https://t.me/fivestarport/786); 3) install it; 4) for extra memory, install with AltStore 2.3 or newer (it adds it by itself), GetMoreRam with SideStore works for some players, but its Apple sign-in fails for many since mid-October; 5) add your own game files in the app; 6) pick Story mode or Sandbox and tap Play.

### Is there a video tutorial or setup guide?

Yes: the Start here topic in the Telegram group has the step-by-step setup guide, and the install guide is on the website: fivestarport.site/iphone/ (on a Mac: fivestarport.site/mac/).

### Which sideloading app should I use (SideStore, AltStore, Sideloadly)?

Any of SideStore, AltStore or Sideloadly works: one IPA works with all of them since v1.3.3. For extra memory on a free Apple ID use AltStore 2.3 or newer: it adds the extra memory by itself. SideStore refreshes on the phone, but it currently drops extra memory on free Apple IDs. A paid developer account or TrollStore also work.

### Can it run inside LiveContainer, and where do I get LiveContainer?

It isn't officially tested in LiveContainer, but players run it there. Inside LiveContainer the app gets LiveContainer's memory limit, and the app's folder is inside LiveContainer's own folder in Files, not directly in On My iPhone: tap Game files › Open the GTA V Port folder and it opens the right one, then move your game folder or its .zip/.rar there. Installing with SideStore, AltStore or Sideloadly is the supported way.

### How do I set up SideStore, and do I need a PC for it?

SideStore and AltStore need a computer once to pair with your iPhone (an Apple rule); any Mac or Windows PC works, even a friend's. After that SideStore works on the phone by itself. Follow SideStore's own setup guide. On Windows, install iTunes and iCloud from Apple's website, not the Microsoft Store versions: otherwise the computer tools can't see your iPhone.

### Which iOS versions are supported (iOS 15, 16, 17, 27), and does it work offline?

iOS 16 or newer (iOS 16 since v1.3.3), including the newest iOS. iOS 15 isn't supported. Once installed, the game plays fully offline from your phone.

### Can I sign and install the IPA with eSign, KSign or Feather?

The supported installers are SideStore, AltStore and Sideloadly. Other signers (eSign, KSign, Feather) work for some players, but if they sign without the memory entitlements the game gets only the normal memory. When signing with a paid certificate, make sure the memory entitlements are kept.

### Installing the IPA fails with an error (unable to install, expired, Apple server error in ESign). What now?

"Unable to install", "integrity could not be verified" or Apple server errors come from signing, not from the app. Try again later, refresh/re-sign, check that you have fewer than 3 sideloaded apps on a free Apple ID, or try another supported installer (SideStore, AltStore, Sideloadly). If your installer refuses the app because of the memory entitlements, try another installer: AltStore 2.3 or newer and Sideloadly accept them. A free Apple ID can also register only 10 App IDs in 7 days (every app you sideload, and each retry with a new ID, uses one): if the installer says you've reached the limit, wait a few days or remove apps you don't need.

### Which certificate should I use, what does it cost, and why does it get revoked?

A free Apple ID works and re-signs every 7 days. A paid Apple developer account (99 USD/year) signs for a year and gives more memory. Shared or bought certificates from third parties often get revoked, which shows as "integrity could not be verified"; the project can't help with those.

### Can I get the IPA on a PC or Mac, and do I still need the game files on the phone?

You don't build anything: the app is the IPA from the Releases topic of the Telegram group, and a computer is only needed once to set up SideStore or AltStore. The game files must be on the iPhone (or streamed from your own computer over Tailscale). On a Mac there's a Mac app too: fivestarport.site/mac/.

### Do I need a PC (or a Mac) to install or play the port?

Playing needs no computer, and the app is the IPA from the Releases topic. Only setting up SideStore or AltStore needs a computer once (an Apple rule).

### Mac: how do I quit the game, and where are my saves?

Quit with ⌘Q like any Mac app (the menu bar's GTA V Port › Quit; ⌃⌘F leaves fullscreen if you want the menu bar). The Mac app keeps its own files (saves, mods, logs) in its container: in Finder hold Option and choose Go › Library, then open Containers › GTA V Port › Data › Documents. Your game folder stays where you put it.

### Can I install the app with Sideloadly?

Yes. Since v1.3.3 the one IPA works with Sideloadly too.

### Can I install with TrollStore, and does it give extra memory?

TrollStore works where your iPhone supports it, and gives the extra memory without GetMoreRam.

### Can I still build the app on the website?

The website doesn't build apps any more: the IPA from the Releases topic of the Telegram group (https://t.me/fivestarport/786) is the way to get it. fivestarport.site has the install guide, the Mac guide, the FAQ and the changelog.

### Do I have to sideload again every 7 days, and can I refresh wirelessly?

With a free Apple ID, yes: apps must be refreshed every 7 days. SideStore refreshes on the phone; AltStore over Wi-Fi from your computer. A paid developer account signs for a year.

### Does the app need JIT?

No. The engine is compiled into the app ahead of time and draws with Metal, so JIT isn't used: turning it on with StikDebug or another JIT tool doesn't add FPS or stability. What helps is extra memory and the right preset (Settings › Graphics).

### Does the port work on an iPhone 7 (or another phone that can't update past iOS 15)?

No. The app needs iOS 16 or newer, and the iPhone 7 (and older) stops at iOS 15. The oldest iPhones that can run it are the iPhone 8 and iPhone X, and with their small memory the game is very limited there.

### The app won't open after install (untrusted developer). Do I need to trust the profile, and is it safe?

If iOS says the developer isn't trusted: Settings › General › VPN & Device Management, tap your Apple ID's profile and tap Trust. iOS 16 and newer also need Developer Mode on (Settings › Privacy & Security › Developer Mode).

### Developer Mode doesn't show in Settings. How do I fix it without a PC?

Developer Mode shows in Settings › Privacy & Security after a sideloaded app is installed. The project can't help further with iOS setup; ask in the Install topic.

### Does it work with on-device install services that don't need a computer?

The supported installers are SideStore, AltStore and Sideloadly.

### The app didn't tell me there's a new update. How do I find out about new versions?

New versions are posted in the Releases topic (t.me/fivestarport/786). Up to v1.4.6 the app asked GitHub for new versions, and GitHub is gone, so those versions show no popup. From v1.4.7 the app asks fivestarport.site, so it tells you again when the next update is out.

## Updating

### How do I update to a new version without losing my files or progress?

Install the new IPA over the old app: your game files, Story saves, Mods and settings stay (iOS keeps the app's own folder when the same app is installed again). Use the same sideloader and the same Apple ID as before (SideStore/AltStore: My Apps › + › pick the new IPA). Don't delete the app first: deleting it deletes its folder, with the game files inside it and your saves. If you install with a different sideloader or Apple ID, iOS can treat it as a different app: a second GTA V Port appears with no game files, and the old app still has them. Keep using the old one, or copy the game folder across in the Files app. Inside LiveContainer the data lives in LiveContainer's own folder: back up its data folder before reinstalling LiveContainer. Updates never need new game files.

### What's new, and when is the next update?

Every version's changes are in the Releases topic (https://t.me/fivestarport/786) and on fivestarport.site/changelog/, and the app tells you when a new version is out. The newest is v1.5, a big update: Eye in the Sky, Monkey Business, The Drag, telescopes, ATMs, garages, the barber and the Jewel Store fixed; five common crashes fixed and the stop screen says why; desktop Menyoo works; mod keys as your own on-screen buttons; the Controller buttons touch scheme and the HUD layout editor; much better 4 GB iPhones; iPhone Duo support; and the report board at fivestarport.site/report/. There are no release dates for the next one.

### Do I need to delete and download the game files again when I update or after I get GetMoreRam?

No. Updates don't need new game files, and getting extra memory doesn't either. Only if the app's Game files screen reports damaged or missing files do you need to unpack again. Your saves stay as long as you don't delete the app.

### Will updates come as a new IPA or as new game files?

Updates come as a new IPA in the Releases topic of the Telegram group. Your game files stay.

### I installed v1.4.2 but the app says v1.4.1. Which version do I have?

v1.4.2 said 1.4.1 by mistake; it was v1.4.2. v1.4.3 shows the right number: install it from the Releases topic over the old app.

## Game files

### Where can I download the GTA V game files (assets) for the port?

The project can't help with getting the game files and doesn't share them: you need your own copy (the web build, a folder with data and b inside, about 21 GB). Once you have it, add it in the app on the Game files screen. Please don't ask for links in the group.

### I installed the app and downloaded the files. How do I add them so the game starts?

Open the app once so its folder appears in Files. Then in the Files app touch and hold your unpacked game folder (the one with data and b inside), or the .zip or .rar it came in, tap Move and choose On My iPhone › GTA V Port. Open the app again: it finds the game by itself and checks every file; an archive gets an Unpack button. Since v1.5.2 Game files › Show me how walks you through it with pictures. Or paste a download link under From a link. Then pick Story mode or Sandbox and tap Play.

### Pressing Open in the folder picker does nothing, so the app won't take my game files. How do I fix it?

Since v1.5.2 the iPhone app has no folder or archive picker any more: on many sideloaded installs iOS never handed the picked folder over (Open stayed grey or did nothing). Put the game in the app's own folder instead: Game files › Open the GTA V Port folder opens it in Files; move your game folder, or its .zip or .rar, there (touch and hold › Move) and come back, the app finds it by itself. Game files › Show me how shows each step. Or download the game in the app with From a link. A folder you picked in an earlier version keeps working.

### Which game files do I need to download and add, and does the archive contain everything?

The app needs the whole unpacked web build (version 8b0b5899ed): the folder that has data and b inside, about 21 GB. Put it in Files › On My iPhone › GTA V Port (or pick it in the app's Game files screen). The app checks every file and tells you exactly what's missing or damaged.

### Which version of the game files is the best or most stable (mirror, gta5webport.zip, 19 GB, 21 GB)?

The app needs the web build 8b0b5899ed (the folder with data and b inside). A zip or a rar of the same build gives the same files. Whatever you use, the app checks every file and tells you if something is missing, damaged or from a different version.

### Where are save files stored, and how do I add someone else's save?

Saves are in Files › On My iPhone › GTA V Port › EngineFiles › userdata › Documents › Rockstar Games › GTA V › Default. You can copy save files there (PC saves work too). Back up this folder before reinstalling.

### The download links won't open, or the download won't start. How do I fix it?

The project can't help with third-party download sites. If you have a link to your own copy: in the app's Game files screen paste it under From a link; a download page opens in the app's own browser, which takes the download over (it has a shield button to turn off ad blocking for a site that refuses). Or download it another way and move the .zip or .rar into Files › On My iPhone › GTA V Port: the app offers to unpack it.

### The download stops, restarts from zero, or ends up incomplete. How do I get it to finish?

When downloading in the app (From a link), keep the app open in front: it keeps the screen from locking while it works, so don't press the side button or switch apps. In the background the download pauses and continues when you come back. Since v1.4.2 a dropped connection is retried for 30 minutes, and if the app was closed, Game files shows "The download stopped at N%" with Continue the download, which picks up where it stopped instead of starting again. Zip and normal (not solid, not split) RAR5 archives continue in the middle; with other archives, files already unpacked aren't unpacked again. Keep about 21 GB free. If you downloaded it elsewhere, a much too small file means it didn't finish.

### Can I rename the RAR file to ZIP, and which app should I use to unpack it?

Don't rename .rar to .zip, that breaks it. No unzip app is needed: move the .rar into Files › On My iPhone › GTA V Port, open the app and tap Unpack (Game files › Show me how shows the steps).

### How much storage do the game files need, and how should I get them onto the phone?

The game is about 21 GB, plus the app. Keep about 30 GB free. Unpacking in the app from a link or an archive needs about 21 GB, not double, because the archive is used up while it unpacks. Keep the game in On My iPhone, not iCloud Drive.

### The game files archive won't unpack (corrupted, wrong password, unsupported format). What do I do?

Let the app do it: move the zip or rar (all parts of a multi-part one) into Files › On My iPhone › GTA V Port and tap Unpack in Game files; it unpacks and checks every file. "Corrupted" or "wrong password" usually means the archive didn't download completely; get it again.

### Can I download a 100% save file, and do downloaded saves work?

The project doesn't share save files. If you have a save, copy it into GTA V Port › EngineFiles › userdata › Documents › Rockstar Games › GTA V › Default (PC saves work).

### My game file download stopped (lost Wi-Fi, locked the phone, app closed). Do I have to start the 21 GB again?

No, since v1.4.2. A dropped connection is retried for 30 minutes (also while the phone is locked), and if the app was closed, Game files shows "The download stopped at N%" with Continue the download: it picks up where it stopped instead of starting again. Zip archives and normal (not solid, not split) RAR5 archives like mirror.rar continue in the middle of the download; other archives are read again but files already unpacked aren't written again.

### The download link only sends me to ad or betting sites. How do I download?

The project can't help with third-party download sites. If you use From a link in the app, a download page opens in the app's built-in browser, which blocks ads and takes the download over. The first tap on a page's download button often opens an ad or a redirect: close it and tap the button again (sometimes 3 or 4 times) until the app shows the download starting. If the site refuses, the app turns ad blocking off for that site and asks you to tap again.

### I don't have enough space to keep the archive and also extract it. What can I do?

Let the app do it: paste the link under Game files › From a link, or move the archive into Files › On My iPhone › GTA V Port and tap Unpack. It unpacks as it goes and uses the archive up, so you need about 21 GB free, not double.

### The file host says it is too busy, or the download is very slow. What can I do?

The project can't help with third-party file hosts or their limits.

### How do I fix the broken or missing files error in the app?

Tap the message on the Game files screen to see every problem. Missing or wrong-size files mean unpacking or copying stopped early (usually storage ran out). Free up space, delete the folder and unpack again. Files "only in iCloud": move the game folder to On My iPhone › GTA V Port.

### I can't find the b folder or game.wasm in my game files. What's wrong?

Pick the folder that has both data and b inside (not data or b itself). If you opened a folder too deep, the app says so and tells you to go up one or two levels. If there's no b folder at all, it's not the right build of the game files.

### I own the original PC game. Can I use those files, and do I need the PC game at all?

The port needs the web build of the game files (folder with data and b, about 21 GB), not the PC install. Normal PC save files do work.

### What is the source of the game files, and why are they only 20 GB?

The project doesn't provide game files. The web build is about 21 GB because its textures are smaller and it leaves out what the web version doesn't use.

### Why is there a GTA 6 test map, and how do I remove it to free space?

It comes with the game files and is optional. To free space: Files › On My iPhone › GTA V Port › your game folder › data › x64 › levels, delete the env_test folder, then empty Recently Deleted. The GTA VI test map button then greys out; Story and the normal Sandbox still work.

### After unzipping the 14 split parts they don't become one folder. Is that right?

All parts of a multi-part archive go together: move every part (.part1.rar, .part2.rar…) into Files › On My iPhone › GTA V Port and tap Unpack in Game files; the app unpacks them into one folder.

### Do I have to upload the game folder anywhere, and can I delete it afterwards?

Nothing gets uploaded anywhere. Keep the game folder on the iPhone (On My iPhone › GTA V Port): the app plays from it, so don't delete it.

### If I copy all the PC files (about 65 GB) to iOS, will all the cutscenes work?

No. The port uses the web build's files only. PC files won't add cutscenes.

### Is there a manifest file, and how do I get it?

data/manifest.json is in your game folder's data folder. The app uses it to check every game file; you don't need to do anything with it.

### My game size shows 15 GB rather than 20 GB in v1.3.3. Is that a problem?

That's fine if the Game files check says every file is there. Some copies leave out the GTA VI test map, which is optional.

### Why is my residents.rpf only about 100 MB?

The app checks every file's size against the game's list. If a file is the wrong size, the Game files screen says so.

### I updated the app and my game files are gone, or Play does nothing

Installing an update with another sideloader or another Apple ID makes a separate copy of the app with an empty folder, so the game files and saves stay in the old copy. Install over the old app the same way you installed it first, or open Game files and choose your game folder again. Since v1.4.5, Play without game files opens Game files and says what's missing.

## Extra memory

### What is GetMoreRam, and how do I get more RAM for the game?

iOS gives an app about half of the iPhone's memory. To unlock more for free, install GTA V Port with AltStore 2.3 or newer (with AltServer on a Mac or PC): it adds Increased Memory Limit by itself on a free Apple ID, no GetMoreRam needed, and players in the group confirm it. SideStore currently drops extra memory when it signs with a free Apple ID (a SideStore bug; a fix is waiting to be merged), and GetMoreRam's Apple sign-in fails for most players since mid-October. Every IPA since v1.3.3 already asks for it. Check Settings › This device: it should say "Extra memory: on" and show a higher app limit. A paid developer account or TrollStore gives it too.

### I can't sign in to GetMoreRam or iRAM+ (bad credentials, data error). How do I fix it?

GetMoreRam's and SideStore's Apple sign-in has been failing for many players (-80045, "request timed out", bad credentials, or the 2FA code never arrives). What worked for several players in the group: install SideStore nightly, set its anisette server to SideStore's "new" server (new · ani · sidestore · io; on-device anisette off), use "clean up keychain", reopen SideStore, keep LocalDevVPN on, then sign in again. You may not need GetMoreRam at all: AltStore 2.3 or newer adds the extra memory by itself on a free Apple ID, and a paid developer account always works. Ask in the Install topic (t.me/fivestarport/5) if it still fails.

### I tried to increase memory, but the game still shows only 2-3 GB. Why?

Check Settings › This device. "Extra memory: off" means your install doesn't have it: SideStore on a free Apple ID drops it today, and GetMoreRam fails for most players. Install the current IPA with AltStore 2.3 or newer instead (don't delete the old app first: your game files and saves are inside it). iOS never lets the app use all of the phone's memory: about 3,500 MB or more on a 6 GB iPhone is normal with extra memory.

### Should I enable the 'increased memory entitlement' option, and do I need to reinstall?

The IPA from the Releases topic always asks for the extra memory, so there's nothing to tick. The entitlement alone doesn't add memory: the installer has to keep it. AltStore 2.3 or newer does on a free Apple ID; with SideStore, GetMoreRam (or iRAM+) adds it once if its Apple sign-in works for you (it fails for many since mid-October); a paid developer account or TrollStore keep it. Settings › This device shows whether you have it ("Extra memory: on").

### Does a paid developer certificate give extra memory, and what do I need to enable when signing?

Yes. A paid Apple developer account (99 USD/year) gives Increased Memory Limit and Extended Virtual Addressing (about 4,000 MB on a 6 GB iPhone) and re-signs once a year. The IPA already asks for both. If an IPA signed by a tool with a paid account still shows the free limit in Settings › This device, the tool dropped the entitlements; signing on a Mac with Xcode is the most reliable.

### Does v1.4.6's bigger memory (up to 7 GB) help my phone? It still shows about 3 GB.

v1.4.6 lets the game use more of the memory iOS already gives the app: it helps devices with 8 GB or more that have the extra memory (the app limit is then 5 to 12 GB). It can't raise what iOS allows, so if Settings › This device shows about 3 GB, the extra memory isn't on for your install (see the extra memory answers), and 4 GB iPhones don't change. Grey textures on 4 GB iPhones are a known issue being worked on.

### Which IPA should I install, normal or unlimited, and what does 'unlimited' mean?

That's from older versions. Since v1.3.3 there's only one IPA: it asks for extra memory and works with SideStore, AltStore and Sideloadly. Always take the newest one from the Releases topic.

### Can I increase the RAM entitlement inside LiveContainer?

Not tested. Inside LiveContainer the game gets LiveContainer's own memory limit, so the extra memory would have to be applied to LiveContainer itself. The supported way is installing GTA V Port directly, with AltStore 2.3 or newer for extra memory.

### How do I get GetMoreRam without a PC, or after installing with SideInstaller?

Not right now. The free way to get extra memory today is AltStore 2.3 or newer, which needs AltServer on a Mac or PC (also for the refresh every 7 days). SideStore currently drops extra memory on free Apple IDs, and GetMoreRam's sign-in fails for most players. Without extra memory the game still runs: use the preset marked (recommended) or Ultra Performance.

### Do I have to use GetMoreRam again every time I update the app?

No. GetMoreRam turns on Increased Memory Limit for GTA V Port's App ID in your Apple account, not in the installed app, so it stays when you install each update over the old app with the same sideloader and the same Apple ID. In 47 player logs sent right after an update, all 30 that had extra memory before still had it after. Check Settings › This device after updating: it should say "Extra memory: on". If it ever says off (for example after installing with another sideloader or Apple ID, which makes a new App ID), add it again in GetMoreRam and refresh GTA V Port in SideStore.

## Performance and graphics

### Textures, ground or buildings disappear or don't load. How do I fix it?

Missing or grey ground, blurry buildings or a map that stops loading usually means the game is short on memory. Update to the newest version and keep the Experimental settings (Settings › This device) on. Unlock extra memory if you can (install with AltStore 2.3 or newer, or a paid account), use the preset marked (recommended) or lower and close other apps. On 3 to 4 GB iPhones far areas can still stay untextured: a known issue. If it happens on the newest version, send a log right after it happens (Settings › This device › Send log to the developer, with a short note in "What happened?").

### What FPS can I expect on my device?

It depends mostly on memory and the chip. Players report roughly 25-31 FPS on an iPhone 13 Pro Max with a free Apple ID, 30-40 on 13/14 Pro Max, 40-50 on 15 Pro Max on Balanced, and around 60 on 17 Pro models. 4 GB iPhones get about 20-30 FPS on the lowest settings. Turn on Settings › Graphics › Show FPS counter to see yours. Looking at the sky or ground shows higher numbers than normal play.

### Does it run on my device (iPhone 12 Pro, 13 Pro, 16, 16 Plus, 17 Pro, iPad)?

It runs on iPhones and iPads with iOS 16 or newer. What matters most is memory: 6 GB or more (iPhone 12 Pro, 13 Pro, any iPhone 14 or newer, M1 iPads or newer) plays well, best with extra memory unlocked. Newer chips give more FPS. You need about 30 GB free.

### Does it work on iPhone 11, XR, SE 3rd gen or other 4 GB devices?

It installs and starts, but 4 GB iPhones (iPhone XS, 11, 12, 12 mini, 13, 13 mini, SE 3rd generation) get only about 2 GB for the app, so expect low detail and around 20-30 FPS. Use the Ultra Performance preset (Settings › Graphics), made for these phones. v1.4.5 helps most: on these iPhones the city stays loaded while driving (fewer grey and missing textures) and the game gets about 80 MB more memory (Settings › This device › Experimental, on by default). The red ⚠️ next to the FPS counter marks a phone with this little memory. Unlocking extra memory helps a little.

### 4 GB iPhone (iPhone 11, 12, 13): textures or houses look worse since v1.4.5 than on v1.4.4

v1.5 improves 4 GB iPhones (iPhone 11, 12, 13, 13 mini) a lot: about 75 MB more memory for the city, and Ultra Performance drops one more detail level from the biggest textures, so the ground and buildings load instead of staying grey; on our test drive the struggling-to-load time fell from about 70% to 14%. Update, and keep the recommended preset (Ultra Performance) and Graphics › Textures on Low. If you prefer the older look, Settings › This device › Experimental › Lighter big textures and Steady city on low memory turn the changes off.

### How do I raise FPS or unlock 60 FPS?

Unlock extra memory first. Then in Settings › Graphics: pick the recommended preset (or lower), lower the Resolution, and set Frame rate to 60 or Unlocked (up to 120 on ProMotion iPhones; 40 there too since v1.4.5). The frame rate changes right away; since v1.4.7 a Resolution change on iPhone and iPad applies the next time the game starts (on Mac right away). Close other apps, turn off Low Power Mode and keep the phone cool. Turn on Show FPS counter to compare.

### Why does the game stutter or drop FPS over time (iPhone 17, iPad, v1.3.4)?

Update to v1.4.3: its Faster engine threads setting (Settings › This device, Experimental, on by default) runs the engine at a higher priority, for the FPS drop after a few minutes. Heat slows iPhones down too: try Settings › Graphics › Steady frame rate when hot, Frame rate 30, a lower resolution, no case or charging while playing. If it still drops, send a log right after it happens (Settings › This device › Send log to the developer, with a short note in "What happened?").

### Can I change shadows, textures or draw distance myself instead of a preset?

Yes, since v1.4.2: Settings › Graphics, at the bottom: Textures, Shadows, Reflections, Draw distance, Grass, and Traffic and people. Each says "Preset (…)" until you pick your own value; your choices stay when you switch presets and apply when you press Play. Higher values use more memory: if the game starts closing, set them back to the preset.

### Which graphics settings give good quality and FPS?

Start with the preset marked (recommended) in Settings › Graphics: the app picks it from your memory. Then try a higher or lower Resolution to find your balance between sharpness and FPS (on iPhone and iPad it applies the next time the game starts, since v1.4.7). Presets above the recommended one show a warning but are safe to try: if one is too much, the app steps back next launch. Since v1.4.2 you can also set Textures, Shadows, Reflections, Draw distance, Grass and Traffic and people yourself under the preset (Settings › Graphics, at the bottom); they stay when you change the preset and apply when you press Play.

### How much RAM does it need, and does more RAM increase FPS?

The game needs about 2.5 to 3 GB for the app, so 6 GB iPhones are the practical minimum (they get about 3 GB, or more with extra memory). More memory allows higher presets and fewer missing textures; FPS depends more on the chip and settings.

### Can the game be optimized for low-end devices?

Yes: since v1.4 the Ultra Performance preset (Settings › Graphics) keeps less of the world in memory so it keeps loading on low-memory iPhones, and Sandbox lag on 4 GB iPhones is fixed. v1.4.3 adds Experimental settings in Settings › This device (on by default): Smarter texture loading, Lighter big textures and Faster engine threads.

### How do I make the game fill the whole screen instead of 16:9?

Settings › Graphics › Fill the screen renders at your screen's shape instead of stretching 16:9. Since v1.4 it also fills the screen on iPhone 17 Pro Max. Cutscenes keep their black bars, like the original.

### How do I unlock 120 FPS on ProMotion devices?

Settings › Graphics › Frame rate › Unlocked goes up to 120 on ProMotion iPhones (13 Pro and newer Pro models); since v1.4.5 there's also 40, smoother than Unlocked when the game runs between 40 and 60. A new frame rate applies right away since v1.4.5 (at the next start on older versions). Reaching 120 depends on your phone and settings.

### I changed the graphics preset or frame rate but nothing changes in the game

The graphics preset applies when the game starts. If you change it while playing, Settings shows "Restart needed": close the app completely (swipe it away in the app switcher), open it again and press Play. Since v1.4.7 the same goes for the Resolution on iPhone and iPad (changing it during play could crash the game); on Mac it changes right away. The frame rate changes right away since v1.4.5.

### I have an 8 GB iPhone or iPad (or extra memory) and still get grey ground or missing textures while driving. Why?

Up to v1.4.5 the game engine kept its data in a 4 GB block, and on 8 GB devices that block filled up while the device still had 2 to 4 GB free; the game then stopped loading the city, most of all while driving fast. v1.4.6 makes the block the app's memory limit less 1 GB, up to 7 GB, so update. Heat also slows loading (Thermal Serious in the Metal HUD): keep the device cool. If it still happens on v1.4.6, send a log right after it happens.

### The phone gets very hot. Is that normal?

Yes, almost every iPhone gets warm with a game this big: in play stats 8-9 of 10 sessions on most iPhones get hot enough that iOS slows the chip (about half on the iPhone 17 family, rarely on M-chip iPads and Macs). What helps most: Frame rate 30 (Settings › Graphics), Steady frame rate when hot, a step down in preset, no case and not charging while playing. The iPhone 12 Pro and 12 Pro Max run hottest: on Battery or Performance the 12 Pro Max gets very hot in half of all sessions, on Ultra Performance in 1 of 5, and it runs smoother there too, so use Ultra Performance on the 12 Pro Max and at most Battery on the 12 Pro. fivestarport.site/performance/ has a table for every iPhone.

### What are the Experimental settings in Settings › This device?

Three settings added in v1.4.3, all on by default: Smarter texture loading keeps the ground and roads from turning grey after long play; Lighter big textures uses a quarter of the memory for the largest textures on iPhones before the 15 Pro, so more of the world stays sharp; Faster engine threads keeps the engine on the fast processor cores for steadier FPS. Turn one off if it causes trouble: Faster engine threads if your iPhone gets too hot, Smarter texture loading if the game runs out of memory, Lighter big textures for the sharpest close-ups.

### How well does the game run on my iPhone? What FPS and settings should I expect?

Every iPhone runs a steady 30 FPS at the default frame rate. Set higher, players average: XS/11/12/13 and SE 40-49 FPS on Ultra Performance (about 2 GB for the game, so some grey ground while driving fast); 12 Pro and 12 Pro Max 42-44 (they run hottest: Ultra Performance on the 12 Pro Max, Battery on the 12 Pro); 13 Pro to 15 Plus 45-51 (Battery, or Performance/Balanced with extra memory); 15 Pro to 16 Pro Max 41-49 (Battery, or Quality with extra memory); 17 family and Air 48-53; M-chip iPads and Macs 52-63. The preset marked (recommended) in Settings › Graphics follows your memory; extra memory (AltStore 2.3, GetMoreRam or a paid account) lets you go higher. Full table: fivestarport.site/performance/

### The pause menu keeps saying "You made changes but did not apply them" though I changed nothing. What do I press?

That was a bug, fixed in v1.4.2: the pause menu's lowest shadow setting is Normal, while the app's lighter presets use Low or Off, so the game thought something had changed. On older versions choose Cancel (No) there, not Yes: Yes raises the shadows and re-applies the graphics, which costs FPS and memory. The app's own Settings › Graphics is the place to change graphics.

### What's the 40 FPS option?

On iPhones with a 120 Hz screen (ProMotion), Settings › Graphics › Frame rate has 40 since v1.4.5. Each picture stays up exactly 1/40 s, so when the game runs between 40 and 60 it looks smoother than Unlocked, which jumps between speeds. It applies right away.

### What's the red ⚠️ next to the FPS counter?

It means iOS gives the game little memory on your iPhone (the 4 GB models get about 2 GB), so a less detailed city and textures that load late or stay missing are expected there. It's there so a screenshot shows it at once; nothing is broken. Unlocking extra memory (AltStore 2.3 or newer, or a paid account) helps the most.

### Why do car textures look low quality or blurry up close?

It's the texture setting, not a bug. The presets up to Balanced use Textures: Low, which keeps memory free for the city. For sharper cars, open Settings › Graphics and set Textures to Normal or High at the bottom, if your device has the memory (6 GB or more, or extra memory). It applies at the next Play. If the ground starts turning grey while driving, go back one step. The game files the port uses have no PC HD car textures, so cars never reach the PC's HD look up close. Some old cars in the game, like the rusty Emperor, really have a broken dashboard.

## Controls

### Does the game work with a controller?

Yes. Bluetooth controllers work, and the touch controls hide while one is connected (Settings › Controls › Hide touch controls with a controller); since v1.5 Settings and Mods stay on screen. Hold the controller's View / Share button for a second to open Settings (a tap still changes the camera view). Keyboard and mouse work too. No controller? Since v1.5, Settings › Touch controls › Touch scheme › Controller buttons puts every Xbox button on screen (L3 and R3 are their own buttons).

### How do I switch characters?

Use the Switch character button on the touch controls, then drag to the character on the wheel; since v1.5 it shows in Sandbox too, not only in Story mode. It works in helicopters and planes, and while playing as Chop it shows whenever the game waits for the switch back to Franklin. With a controller it's the game's usual D-pad down. You can move the wheel itself in Settings › Touch controls › HUD layout (v1.5).

### Can I move, edit or hide the on-screen buttons?

Yes: Edit controls layout (start screen or Settings › Controls). Drag a button to move it, pinch to resize, or hide it; since v1.5 that includes the "Fire, left hand" button that shows while you aim. Button size and opacity are in Settings › Controls. Since v1.5, Settings › Touch controls › HUD layout also moves the HUD: the minimap, the FPS counter, the character wheel, the phone, notifications, subtitles, names, the stats and help messages. Prefer a fixed layout with every Xbox button? Touch scheme › Controller buttons (v1.5).

### Can I change the camera sensitivity, or move the camera by dragging on the screen?

Settings › Touch controls: pick Camera: right stick or Camera: swipe at the top, then set the speed or sensitivity (swipe up to 15x). Gyro aiming is there too.

### Can I move the FPS counter, the minimap, the phone or the character switch wheel?

Yes, since v1.5: Settings › Touch controls › HUD layout. Drag a piece to move it, pinch the minimap or the character wheel to resize, and Reset puts one back. It moves the character wheel, the FPS counter, the phone, notifications, subtitles, vehicle and area names, the wanted level and cash (sideways only), the minimap and help messages. Some apply at once, the rest at the next start, as the screen says.

### Can I steer with left and right buttons instead of the joystick?

Yes: Settings › Controls › Steering buttons (Left and Right buttons instead of the steering stick in cars, bikes and boats).

### How do I aim or shoot while driving?

Use the Aim and shoot from vehicle button. Since v1.4 there are also Aim from the vehicle (aim without shooting) and Duck buttons while driving, and since v1.4.2 aiming from a vehicle works with the swipe camera too.

### How do I take a photo or send it with the phone camera (Scouting the Port, "take the shot")?

With the phone out, the touch buttons show the letters the game names: A takes the photo, X sends it (Scouting the Port: "Send the photos to Ron" opens your contacts with it), B exits.

### I sat on the couch to watch TV and now I can't stand up. Which button?

Since v1.4.2 the hand button appears whenever the help asks for the interact input: on the couch it stands you up, at Trevor's it drinks more whiskey (and Y stops drinking). On older versions the interact input is D-pad right, but on the couch the arrows make room for the TV stick, so update to v1.4.2.

### The subtitles are hidden behind the home bar at the bottom of the screen. How do I see them?

Since v1.4.4 the subtitle line sits above the home bar: Settings › Touch controls › Subtitles above the home bar (on by default on iPhones with a home bar; applies the next time the game starts).

### With the swipe camera, arrow buttons (and check, back, skip) pop up while I'm just walking around

That was a bug with the swipe camera: a game script reads the menu Down input after you turn the camera, and the touch controls took it for a shop menu. Fixed since v1.4.2; update to the newest version.

### A mouse cursor stays on the screen during the game

That's the iPhone's own pointer, not the game's: it shows while a mouse or trackpad is connected (or AssistiveTouch's pointer device is on). Disconnect the mouse in Bluetooth, or check Settings › Accessibility › Touch › AssistiveTouch › Pointer Devices. To play with a mouse, turn on Settings › Touch controls › Keyboard and mouse: the game then captures the pointer and it disappears.

### Can the touch controls hide when a controller is connected?

Yes: Settings › Controls › Hide when a controller is connected. The touch controls come back as soon as the controller disconnects.

### How do I answer a call while driving?

Tap the Phone button to open the phone and answer. Since v1.4 calls no longer take over the driving controls, and since v1.4.2 calls while walking keep the walking controls too.

### How do I detach a trailer, unhook a towed car or use the Cargobob hook?

Since v1.4.3 a Detach trailer button shows while a truck or car pulls a trailer. In a tow truck, use the Release tow hook button (Raise tow arm and Lower tow arm are there too); in a Cargobob the same Release tow hook button lowers and raises the hook.

### How do I equip a parachute?

Hold the Sprint button to open a parachute (Settings › Controls › Sprint button). While playing, Settings › Cheats › Parachute gives you one.

### How do I open the map?

Since v1.4.3, tap the minimap to open the full-screen map; pinch to zoom it. The map is also the first tab of the pause menu (the Pause button). Drag on the left of the screen to move the cursor and set a waypoint.

### Since v1.5 my driving buttons turned into arrows, a check mark, back and skip, with no menu on screen. How do I fix it?

Fixed in v1.5.1: update. On v1.5 some script mods (.asi files) read the menu arrows every frame, even with their own menu closed. The touch controls took that for an open menu and swapped the play buttons for the menu ones. v1.5.1 no longer counts mods for that check; ATM screens and an open mod menu such as Menyoo still get the arrows. Still on v1.5? Remove script mods one at a time in Settings › Mods until the play buttons come back.

### The touch buttons disappeared. How do I get them back?

The touch controls hide while a game controller is connected, or a keyboard and mouse with Keyboard and mouse on, and come back when it disconnects. Turn off Bluetooth or the controller, or switch off Settings › Touch controls › Hide when a controller is connected. If you moved or resized buttons, Settings › Touch controls › Edit controls layout › Reset puts them back.

### Why don't the controls work on my iPad Pro 2018?

Update to the newest version. If touch controls still don't respond, check that no controller or keyboard is connected (touch controls hide then), and send a log.

### Why is there no run or sprint button?

Push the stick all the way to its edge to sprint. Or turn on the Sprint button (Settings › Touch controls, off by default): tap it while moving to sprint until you let go of the stick, and hold it to open a parachute. Since v1.4.3, while the Sprint button is on, the stick alone no longer sprints.

### Will a Bluetooth keyboard and mouse work?

Yes: Settings › Controls › Keyboard and mouse (WASD, mouse look). With both connected, the touch controls hide.

### How do I jump (bunny hop) on the BMX?

Since v1.4.5 bicycles have a Jump button where cars have drive-by. Hold it longer to hop higher.

### I opened an ATM and can't close it with the touch controls. How do I leave?

Fixed in v1.5: update. With touch controls the ATM screen now shows Back and the menu arrows after a few seconds; Back closes it. On older versions only a controller's B closes it, or leave the app and come back.

### The help box ("Press … to …") covers the map. Can I move it?

Yes, since v1.4.5: Settings › Touch controls › Help messages: Top left (the game's place), Top right, Bottom middle, or Custom, where you drag the box anywhere. With the map at the top, Top right is the default. It applies the next time the game starts.

## Missions and Story mode

### How do I import a save file (from PC or a 100% save from a friend)?

Since v1.4.4: Settings › Game mode › Import a Story save… and pick the save file (named like SGTA50000, about 0.5 MB). It goes into a free save slot; start Story mode and load it with Pause › Game › Load Game. PC saves work.

### Is the full story mode playable from start to finish, and is there multiplayer?

Yes, Story mode is the full campaign with saves, and players are playing through it. Some missions have known bugs (see the known issues list), and some TV and cutscene videos aren't in the game files, so they're skipped. There is no online or multiplayer.

### Does story progress save, and how do I save?

Yes. Story mode saves the way GTA V does: it autosaves after missions, and you can save in a safehouse bed or with Quick Save on the in-game phone. Saves stay on this iPhone between launches (Sandbox keeps its own separate files). Save after using Set money to keep it.

### Eye in the Sky: I can't move the helicopter camera to scan the target, so the mission fails

Update to v1.5. The camera moves since v1.4.7 (touch: drag on the right side to aim, use the left side to zoom; controller: right stick aims, left stick zooms). v1.5 fixes the rest: the RT scan button stays on screen while you hold it on a target, so the scan finishes, and in the helicopter the Interact button (the hand) turns on thermal vision, so the mission goes on. If it still gets stuck on v1.5, send a log right after it happens.

### The map or minimap doesn't show (roads, or the whole map). Why?

The minimap works since v1.3; update if yours is blank. Since v1.4.3 you can move it (Settings › Touch controls › Minimap: bottom left, top left or a custom spot you drag and pinch) and tap it to open the full-screen map. The pause map reveals more as you explore, like the original game. If the map stops drawing, that's usually low memory (see the textures answer).

### How do I restart or skip a mission or cutscene?

After a mission fails, the game offers Retry; since v1.4.3 the Mission failed screen shows Retry / Exit buttons after dying too. After failing three times it offers to skip the mission ("Press X"): the X button appears when it's asked for.

### Scouting the Port: the Handler's arm only goes up, or I can't pick up the second container. How do I lower it?

Since v1.4.2 the Handler has two arm buttons (arrows up and down near the top of the screen): hold the down arrow to lower the arm onto the container, press the hand button when the game asks, then hold the up arrow to lift it. On older versions the arm moves with the steering stick up and down: put your thumb in the middle of the left side, not near the bottom edge, and push firmly up or down (the stick ignores small movements). With Settings › Controls › Steering buttons on there is no stick, so switch it off for this mission. Since v1.4.3 the arm also lowers after a mission retry (before, it could only go up).

### I'm stuck or crashing in the prologue (driving, the guard, the police). How do I get past it?

Unlock extra memory and update to the newest version; most Prologue crashes were memory. If it still crashes or a step doesn't continue, send a log and say which step.

### Nervous Ron (Trevor's sniper mission at the airfield): I shoot the lights but nothing happens and I can't progress

Zoom the scope all the way in first (the + zoom button next to Fire while aiming). From Trevor's perch the lights are about 140 m away, and the game only loads small things like those lamps when the scope is zoomed in: zoomed out, the bullets pass straight through them. The same goes for Ron at the start: he only counts as watched when you're zoomed in. Shoot the lights (the two small green markers) once Ron tells you to, after the truck has parked; shots that land near the bikers earlier alert them and fail the mission.

### The Merryweather Heist (Offshore): the game freezes when Trackify opens, or I can't find the device with the submarine. How do I get past it?

Fixed in v1.4.3: update the app. The game files have no working Trackify app, so it froze the game; since v1.4.3 the port draws Trackify itself. In the submersible the phone opens Trackify by itself: the sonar shows the device's direction, distance and depth, and the ping speeds up as you get closer. Head for it and dive; the sub now holds out to 200 m, so it no longer implodes beside the device (about 180 m down). If you still get stuck on v1.4.3, send a log right after it happens (Settings › This device › Send log to the developer, with a short note in "What happened?").

### A help box says something like "HELP_DCK missing" or "AM_H_DRIVEBY missing". What does it mean?

It's harmless: the game files have no text for some help messages that later PC updates added, and the game showed the label name instead. Since v1.4.2 those boxes simply don't show. Nothing is broken in your game.

### The Marriage Counseling mission crashes or won't progress. How do I fix it?

Fixed in v1.3.3 (the crash at the end, at the Vinewood Hills fences). Update to the newest version.

### After a street race the result screen (1st Place, Retry / Continue) ignores every button. How do I continue?

Fixed in v1.4.3: Continue, Retry and Pause work on the race result screens again. Update the app (install over the old one).

### By the Book (the torture scene): how do I pull the tooth with the touch controls?

Pick the pliers with the arrows. At "Rotate to pull it out" (v1.4.3), RT stays held for you and the right side of the screen becomes a stick: spin it fast, about 3 to 4 full circles a second, until the tooth comes out. A slow rotation doesn't count. Update to v1.4.3 if you have no stick there.

### Can the Los Santos Customs mission bug be fixed?

Fixed in v1.3.1. A few labels in the shop may be blank.

### How do I start a mission? Missions don't appear.

Story missions start at the letter markers on the map (M, F, T and others). Drive to one to start it. Open the pause map to find them.

### I paid $1 at a beach or pier telescope (binoculars) but can't look through it. Why?

Fixed in v1.5: update. The game's own animation placed your character beside the telescope, so the view never opened and the game gave control back after taking the $1. On v1.5 you stand at the eyepiece and the view opens; drag on the right side to look around and use the left side to zoom.

### In the Chop mission I switched to Chop and can't switch back to Franklin. How?

Since v1.4.2 the Switch character button stays on screen while you're Chop: tap it to switch back to Franklin. On older versions tap the down arrow (D-pad down), which is the game's switch input.

### Is there rain in the game?

Yes, the game has its own changing weather, rain included. While playing you can also pick it yourself: Settings › Cheats › Weather (clear, extra sunny, cloudy, overcast, rain, thunderstorm or fog); Natural weather goes back to the game's own. Missions can change the weather too.

### Monkey Business: how do I dive, cut the pipe, or detach the crate from the Cargobob on touch?

Monkey Business works on touch. Dive: since v1.5 a Y button shows when the mission waits for you to dive; tap it. Underwater, push the left stick forward and look down with the camera. Cutting tool: hold the RT button that appears and move it with the stick. At the end Trevor flies the Cargobob to the airfield: "Press … to detach the crate" is the Release tow hook button (the hook icon). Update to v1.5 if you don't see the Y button.

### No button for "Press → to pick up a container" (docks crane) or "Detonate the explosives". How do I do it?

Since v1.4.3 the docks crane's "Press → to pick up a container" gets the Interact button, and "Detonate the explosives" (bombs a mission planted) gets the Detonate button. Update the app if you don't see them.

### The TV doesn't work in the Lifeinvader (Friend Request) mission and the game freezes. How do I get past it?

Friend Request works without the TV picture. On the couch, change the channel with the arrows (Weazel News); since v1.4.4 a note at the top then says how far the presentation is and, from 1:17, "Call now": Phone › Contacts › Jay Norris, before 2:50. Calling later fails the mission; retry and call in that window.

### The game is stuck on "Loading Story Mode" after leaving a replayed mission or loading a save. What do I do?

Fixed in v1.4.3: update the app. Close the game completely and start it again to get out of a stuck load.

### Was the intro added, and can it show the characters like on PC?

The original intro plays when you press Play since v1.3.3. Tap to skip.

### Why are shops and buildings closed in Sandbox?

Sandbox starts with no story progress, and in GTA V shops, barbers and some buildings open as the story goes on, so many stay closed there. Play Story mode (or load a save further in the story) to use them.

### Why does my character's outfit change every time I log in?

Fixed since v1.4: the outfit you saved stays after restarting the game. Update to the newest version.

### A mission asks me to press the D-pad (like calling elk while hunting with Cletus), but there's no button

Since v1.4.5, when a mission's help asks for the D-pad, the matching on-screen buttons appear for as long as the hint shows (for example the elk call in Hunting with Cletus). Update the app.

## Mods

### After installing add-on cars the game stops with "CHandlingObject Pool Full". How do I fix it?

Fixed in v1.4.2: the app gives the game room for 1500 vehicle handling entries instead of 560, so several add-on cars fit without editing gameconfig.xml. Update the app (install over the old one). If it still says Pool Full with a different pool name, send a log right after (Settings › This device › Send log to the developer) and say which mods you installed.

### The mod installer leaves my car or skin files out ("no file with this name in the game"). What do I do?

Replacement mods work by file name: each file must have the exact name of the game file it replaces (like adder.yft or player_one.ydd). Files the mod's author renamed (a name or prefix added) or that a second download renamed ("adder (1).yft") aren't found, so the installer leaves them out with "no file with this name in the game". Check the mod page for which game files to replace, rename the files to match, and install again. "Unknown until the game has run once" means: start the game once, then install. Add-on cars are different: each keeps its own dlc.rpf (see the add-on cars answer).

### Debug text appeared on my screen (#Scripts, Active Trackers, Box Modifier, OVER BUDGET, or small blue labels like runVendingMachine). How do I get rid of it?

That's the game's own developer debug text, not a mod's menu. This game build had a developer shortcut: the B key turned it on while a script mod had switched the keyboard out of game mode. Since v1.4.6 B no longer does that, so update. On older versions, close the game completely and start it again: it's always off at start.

### After updating the app some of my mods are switched off. Why?

From v1.4.5 on, each start notes which switched-on mods the game actually loaded. The first start of a new version switches off the mods the old version had on but didn't load (they did nothing, and are the likeliest to break a start), and says which. Turn them back on in Settings › Mods if you want them.

### An add-on car stays at "waiting for the game…" and never spawns

Update to v1.4.5: cars made for newer PC updates (for example the Honda Fireblade CBR1000RR-R) name a texture set this game version doesn't have, and the game refused to load them. Now they use the game's shared vehicle textures and spawn. If a car still waits, send a log right after (Settings › This device › Send log to the developer) and say which car.

### The game stops while starting after I installed a mod. What do I do?

Since v1.4.5, after a start with mods that didn't finish, the app offers "Start without mods": the game starts once without them and your mods stay installed. Then switch off the mod you added last in Settings › Mods and start again. If it stops with that mod alone, send a log (Settings › This device › Send log to the developer) and say which mod.

## Features

### Does the port support mods, mod menus or trainers?

Yes, since v1.4.1 PC mods work as downloaded: car and character replacements, add-on cars (dlc.rpf), OpenIV packages (.oiv), data files and Script Hook V scripts (.asi) like Simple Trainer. Install them in Settings › Mods by picking the downloaded file, or put files in Files › On My iPhone › GTA V Port › Mods; the Mods guide button explains the paths. v1.4.3 has more room for add-on cars and big mod packs. ScriptHookVDotNet scripts and RAGE Plugin Hook plugins (LSPDFR) can't run on iPhone. Ask about mods in the Mods topic (t.me/fivestarport/10779).

### Is online multiplayer or FiveM possible?

Right now the port is Story mode and Sandbox only, with no online play. Online play is planned for v2, the next major update; there's no date yet.

### I can't change clothes or get a haircut, or doing so crashes the game. Why?

Changing clothes works in Story mode, and shop menus like the barber and Los Santos Customs have arrows on the touch controls. The barber working only once (then the chair did nothing) is fixed in v1.5: update. If a shop menu still doesn't open on v1.5, send a log right after it happens (Settings › This device › Send log to the developer).

### Can the blank app icon be changed?

Current versions have the GTA V Port icon. Changing it isn't an app option.

### Does the game have cheats, and how do I use them?

Yes. Since v1.4.2, Settings › Cheats has a vehicle spawner (search any vehicle by name, it appears in front of you), God mode and Never wanted switches that stay on until you turn them off, Repair and Clean vehicle, time of day and weather, Set money, and the game's own story cheats (invincibility, weapons, wanted level, Buzzard, Comet and more), which the app enters for you. The vehicle spawner and switches were contributed by gfejer. Turn God mode and Never wanted off for missions that need you to take damage or be chased.

### Does the port support the GTA 6 map, and how do I load into it?

Choose Sandbox on the start screen, then the Sandbox map: GTA VI test map (the test level that comes with the game files). If your files don't include it, the button is greyed out. The crash soon after loading it was fixed in v1.4; update if it still happens.

### Menyoo (or another big trainer) doesn't open, F8 does nothing

Since v1.5 the newest desktop Menyoo (about 4.4 MB) runs too, like other script mods built with Microsoft's C++ runtime: install it with Settings › Mods › Install a mod…, start the game, tap 🧩 Mods and press F8. Its first start takes a little while as it reads its lists. The community Menyoo-iOS build and Simple Trainer (F3) still work. If Menyoo doesn't open on v1.5, send a log right after trying.

### Can cars be tuned or modified?

In Story mode, Los Santos Customs works (since v1.3.1). Sandbox has no tuning menu.

### Does it have car engine sounds, and can a car pack be added?

Many engines sound faint or all the same because the common web game files have only a tiny car-engine audio archive (STREAMED_VEHICLES_GRANULAR.rpf, about 6 MB; on PC it's hundreds of MB). If you have your own PC copy of the game, put its audio archives in the Mods folder at the PC path, e.g. Mods/x64/audio/sfx/STREAMED_VEHICLES_GRANULAR.rpf. Don't copy them over the game folder's files: the game files check refuses the different size, and Play anyway only allows up to 20 problem files. Mods aren't size-checked, and whole PC audio archives already work (a 412 MB radio archive in place of the 22 MB one, no errors). Use the archives as they come with your PC copy: one re-saved without encryption stops the game ("Unencrypted archives no longer supported"); re-save it with OpenIV or use the original. A newer PC version's audio_rel.rpf is untested: your own risk. Ask in the Mods topic.

### Does it run on macOS, and how does it perform there?

Yes, on Apple Silicon Macs (M1 or newer, macOS 13 or later). It's the same app built for the Mac and runs natively, no emulator: an M4 with 16 GB plays Quality at about 80 FPS. Download the GTA5Port-mac zip from the Releases topic (t.me/fivestarport/786). Setup: fivestarport.site/mac/

### Can AirPlay or external display support be added?

Yes, since v1.4: connect AirPlay or an HDMI adapter and the game shows on the TV while the controls stay on the phone. v1.4.3 fixes a crash when connecting a TV.

### Can I drag and drop the game files into the app's folder instead of selecting them?

Yes. Move or drag the unpacked folder into On My iPhone › GTA V Port (also with a cable from Finder or the Apple Devices app). The app finds it at any depth.

### Can custom radio MP3s work?

Yes, since v1.4.5: Self Radio plays your own songs on the car radio, as on PC. Add songs in Settings › Self Radio › Add songs…, or copy them into Files › On My iPhone › GTA V Port › Self Radio (on Mac: Show the Self Radio folder in Finder). MP3, M4A/AAC, ALAC, WAV, AIFF and FLAC work; Apple Music and Spotify songs are protected and can't be added. With 3 songs or more, Self Radio is the smiley next to Los Santos Rock Radio in the radio wheel (the game calls it User Music FM). Songs added while you play reach the station at the next start.

### Can the app be in my language, and can I translate it?

The app's own text comes in English, the 12 other languages GTA V itself has, and community translations: Vietnamese, Arabic, Uzbek, Ukrainian and Filipino so far (pick one in Settings › Language). Anyone can add another language or finish one on the Translate page (fivestarport.site/translate/): translate line by line and tap Send. New languages show up in the language picker from the next release. Lines not translated yet stay in English, and in a language Rockstar didn't make, the game's own text stays English.

### Can the in-game phone be replaced with an LB Phone-style phone like in FiveM?

The app uses the game's own in-game phone; an LB Phone-style phone like in FiveM isn't in the app.

### Could GTA V be made fully playable on 4 GB devices?

It's getting closer: since v1.4 the Ultra Performance preset (Settings › Graphics) is made for 4 GB iPhones, and v1.4.5 keeps the city loaded while driving there and gives the game about 80 MB more memory (Settings › This device › Experimental, on by default). They still get much less memory than 6 GB iPhones, so expect lower detail.

### How can I remove the black bars?

The black bars show only in cutscenes, like in the original game, and the app has no setting to remove them. Outside cutscenes, Settings › Graphics › Fill the screen uses your screen's full shape.

### How do I enable subtitles?

Subtitles are a game setting: open the pause menu, then Settings › Display › Subtitles.

### How do I install more than one add-on car without one replacing the other?

Install each add-on car with Settings › Mods › Install a mod… (each gets its own folder) or put each dlc.rpf in its own folder: Mods › update › x64 › dlcpacks › <a name per car> › dlc.rpf. Since v1.4.4 the app also copes with a loose dlc.rpf (or "dlc 2.rpf") and with two cars that use the same pack name: each loads as its own pack, and the same car installed twice loads once.

### I switched a mod off (or removed it) while playing and the game stopped. Why?

Before v1.4.4, removing or switching off a mod in Settings › Mods while the game ran pulled its files away from the game. Since v1.4.4 such changes wait until the game starts again (the row says so). On older versions, close the game before changing mods.

### Is MetalFX or FSR upscaling possible?

Yes: since v1.4, Settings › Graphics › Sharper upscaling uses MetalFX to bring the picture to the screen's resolution with sharpening instead of stretching it. It uses a little more battery.

### Do ScriptHookVDotNet scripts, LSPDFR or RAGE Plugin Hook mods work?

No. ScriptHookVDotNet scripts (a "scripts" folder with .dll, .cs or .vb files; the mod page asks for ScriptHookVDotNet, NativeUI or LemonUI) and RAGE Plugin Hook plugins like LSPDFR (a "plugins" folder, RAGEPluginHook.exe) need Microsoft's .NET running inside the game, which can't run on iPhone. Script Hook V scripts (.asi files), like Simple Trainer, do work: if a mod only needs Script Hook V, it's that kind.

### How do I install a mod on iPhone?

Download the mod on your iPhone (Safari saves it to Files › Downloads), then in the app go to Settings › Mods › Install a mod… and pick the file as downloaded (zip, rar, oiv or asi; 7z isn't supported yet, unpack it first). The app works out where each file goes and shows you before installing, including anything it leaves out and why. Since v1.4.7, archives left packed in the Mods folder show in Settings › Mods under "Still packed in the Mods folder": tap one to install it. Start the game once before installing loose car or skin files: the game records where its files live while it runs. Settings › Mods lists installed mods: switch them off/on or swipe to remove. Cars, skins and add-ons need the game files on the iPhone.

### How do I open a trainer or press a mod's keyboard keys on iPhone?

While a script mod (.asi) runs, a 'Mod keys' button shows at the top of the screen. It lists exactly the keys your mods use (Simple Trainer: F3 opens the menu, Num 8/2 move, Num 5 selects). Hold a key to press it; long-press to pin it next to the button. Since v1.5, Settings › Mods › the mod lists its keys: give a key another key, or add your own on-screen button for it (always, in any vehicle, or in one car; pick an icon from All icons…), which also works with the Controller buttons scheme. Controller shortcuts work too (Simple Trainer: RB + X), and an iPad keyboard works. When a trainer asks you to type, the iPhone keyboard opens by itself.

### I added songs to Self Radio but I can't find the station in the radio wheel

Self Radio needs v1.4.5 and at least 3 songs (Settings › Self Radio lists what the app found). In a car, open the radio wheel: Self Radio is the smiley next to Los Santos Rock Radio, and the game names it User Music FM. Songs added or removed while you play reach the station the next time the game starts. Songs from Apple Music or Spotify are protected and can't play.

### My game crashes or looks wrong with mods. Can you fix it?

Mods can cause crashes and glitches, and the port can't fix other people's mods. First try with the Mods folder empty: if the problem is gone, it's the mod (ask in the Mods topic (t.me/fivestarport/10779), with the mod's name and link). Report it on fivestarport.site/report/ (with a log from the app) only if it also happens without mods. Logs show which mods were active. Add mods one at a time and start the game after each, so you know which one breaks it, and back up your saves first (GTA V Port › EngineFiles › userdata › Documents › Rockstar Games › GTA V › Default).

### Self Radio: how do I shuffle or skip a song?

Settings › Self Radio › Play order: Shuffle (the default) and In order start each song from the beginning; Like a radio station joins songs midway, as the PC does. While a song plays in a car, the Next song button next to Radio skips it (not in Like a radio station).

## Mac

### Does the Mac app run on an Intel Mac?

No, only Apple Silicon Macs (M1 or newer). The engine is built for Apple's chips.

### Mac: how do I update the app?

Download the new zip from the Releases topic (t.me/fivestarport/786), unzip it and drag GTA V Port into Applications, replacing the old one. Your game folder, saves, settings and mods stay. macOS asks once more (Open Anyway) for the new version.

### Mac: how do the controls work, and how do I open Settings?

Keyboard and mouse use the game's own PC controls, with PC key prompts. The cursor stays hidden while you play. ⌘, opens Settings at any time, and the pause menu (Esc) shows Settings and Mods buttons at the top right. ⌃⌘F leaves or enters fullscreen.

### Mac: it says Apple can't check the app for malicious software (or that it's damaged) and won't open

The Mac app isn't notarized by Apple, so macOS asks once. Click Done, then open System Settings › Privacy & Security, scroll down and click Open Anyway next to GTA V Port, and confirm with your password. If it says the app is damaged, the Mac guide has a one-line Terminal fix: fivestarport.site/mac/. It asks again after each new download.

### Mac: where do I put the game files?

Anywhere on your Mac. In the app click the Game files card, then Choose a folder…, and pick the folder your game is in (any folder above it works). The app remembers it. If the folder is in iCloud Drive, Control-click it in Finder and choose Download Now first.

## Crashes and logs

### The game crashes or closes randomly. How do I fix it?

Most random closes are iOS stopping the game because it ran out of memory. Unlock extra memory, use the recommended preset or lower, lower Settings › Graphics › Memory cap if it closes on its own, close other apps, turn off Low Power Mode, keep the phone cool, and update to the newest version. If a preset was too much, the app tells you on the next launch and steps back. Send a log after it happens: Settings › This device › Send log to the developer, with a short note in "What happened?".

### The game crashes at start or is stuck on loading. What's the fix?

Update to the newest version first. Then check the Game files screen: it lists missing or damaged files. If it started closing after you changed a preset, the app steps back to a working setting on the next launch; Settings › Graphics › Memory cap set lower also helps. Turn off Low Power Mode. Send a log after it happens: Settings › This device › Send log to the developer, with a short note in "What happened?".

### The game freezes or crashes during missions. How do I fix it?

Update to the newest version: v1.4.3 fixes the Trackify freeze in The Merryweather Heist, the endless "Loading Story Mode" after leaving a replayed mission or loading a save, and the race result screens that ignored every button. Unlock extra memory and use the recommended preset. If a mission still freezes, check the known issues list, then send a log naming the mission (Settings › This device › Send log to the developer); tick Include my latest save so the developer can load the game where it happened.

### My money or the vehicle in my garage isn't saved after I restart. How do I fix it?

Money resetting to $0 after loading a save was fixed in v1.3.4 (money lost before that doesn't come back: use Settings › Cheats › Set money, then save). Set money sets the game's own balance, so spending lowers it and it survives saving and loading. Cars in garages: police cars and cars spawned with a trainer are never kept, as in the original game, and nothing is kept without saving before you quit. Since v1.5 you can walk out of a car garage on foot again, and a garage car with mod parts this game doesn't have no longer stops the save from loading.

### After changing a setting the game shows a black screen or an error (has_lse). How do I fix it?

If a setting made the game unable to start, the app goes back to a working setting on the next launch. If not, set the preset back to the recommended one and Memory cap to Automatic in Settings › Graphics. v1.4.3 fixes a crash after changing the resolution or connecting a TV ("Invalid call_indirect"), and v1.4.7 a crash when changing the resolution during play on iPhone and iPad: the change now applies the next time the game starts. If it still happens, send a log right after it happens (Settings › This device › Send log to the developer, with a short note in "What happened?").

### The game crashes, or the character freezes, after I pause. Why?

Since v1.3.4 the game opens its pause menu when you leave the app or open Settings, and stays paused until you resume. Since v1.4 the pause menu responds at once, and opening the pause map no longer freezes or crashes the game. If the character can't move after you resume, send a log right after it happens (Settings › This device › Send log to the developer, with a short note in "What happened?").

### The screen goes black when I take a picture for a log, so I can't send a log. What can I do?

Fixed since v1.4: taking a screenshot for a log no longer turns the screen black. Update to the newest version. If it still happens, send the log without a screenshot and describe it in "What happened?".

### After buying a shotgun at Ammu-Nation the game won't let me leave. What now?

Ammu-Nation purchases not counting for the mission (it keeps asking you to buy something) was fixed in v1.4: update to the newest version. If it still happens, send a log right after it happens (Settings › This device › Send log to the developer, with a short note in "What happened?") and name the mission.

### I can't use any gun in the game. What now?

Guns not showing or not firing in Sandbox was fixed in v1.4: update to the newest version. If a gun still doesn't work, send a log right after it happens (Settings › This device › Send log to the developer, with a short note in "What happened?").

### The GTA 6 map crashes after 5-10 seconds. Why?

The GTA VI test map crashing soon after loading was fixed in v1.4: update to the newest version. If it still crashes, send a log right after it happens (Settings › This device › Send log to the developer, with a short note in "What happened?").

### The game freezes with an FPS drop and I can't get past the house. Why?

The freeze at the house when a TV comes on was fixed in v1.3. Update to the newest version.

### The game stopped earlier and I restarted it a few times. Does a log I send now still show the stop?

Since v1.4.6, yes: the app keeps the run where the game stopped (it stopped with a message, or iOS closed it while you played) and sends it first with the next log, however often you started the game since. On older versions the app keeps only the last two runs, so send the log right after the stop: open the app and go to Settings › This device › Send log to the developer before you press Play. On iPhone, v1.4.6 also adds iOS's own report of why the app ended.

### Why does the game crash in Sandbox mode?

Update to the newest version: since v1.4 Sandbox runs smoothly again on 4 GB iPhones and Sandbox and the GTA VI test map no longer crash soon after loading. If it still crashes, send a log right after it happens (Settings › This device › Send log to the developer, with a short note in "What happened?").

## About the port

### Why doesn't the dev share a ready-made IPA?

It is shared: the newest IPA is in the Releases topic of the Telegram group (https://t.me/fivestarport/786). You still need your own game files.

### Is downloading the game files legal, and is it safe for my phone?

The project doesn't share game files and can't advise on getting them. Get the app only from the Releases topic of the Telegram group: it plays offline from your own game files on your phone, and copies from other places can be old or modified.

### Could Rockstar shut this port down?

It's a fan project, not affiliated with Rockstar or Take-Two. The repository contains no game files and no game code.

### Does the app collect any data about me?

From v1.4.4 the app sends a few anonymous stats: a random install ID (not your Apple ID), the app version, iPhone model, iOS version and memory, how long you play, average FPS, which mission you start and whether it was failed, engine stops, and which Cheats rows are used. No names, saves, game files, mods' names, location or IP address. The exact list is at fivestarport.site/stats/. Logs are only sent when you tap Send log.

### Is the IPA open source?

Yes: the app's own code is open source (MIT) on GitHub: [gta5-ios-port](https://github.com/kevinerikjs/gta5-ios-port) for iPhone and [gta5-macos-port](https://github.com/kevinerikjs/gta5-macos-port) for Mac. The app doesn't include the game: you use your own game files.

## Other

### What about other iOS GTA V ports (Muguet, Evolved Port)? Are they better, and how do I use them?

This group only supports Five Star Port. Questions about other ports or launchers belong in their own communities.

### Is there an Android version?

No. This is an iOS/iPadOS port only.

### How do I check how much RAM my iPhone has?

Settings › This device shows your model, memory and the app's memory limit.

### Is there gameplay footage, including at max graphics?

Players post clips in the Show off topic of the Telegram group.

### Can I open the in-game pause menu?

Yes: the Pause button opens the game's pause menu (map, settings, stats).

### How do I show the performance graph overlay?

Settings › Graphics › Show FPS counter.

### Is this basically just the web version?

It runs the web build's game natively on iPhone: the engine is compiled to ARM64 with its own Metal renderer, so it runs much better than in a browser, with touch controls, saves and offline play.

### Is this the original GTA V or a fan remaster?

It's the original GTA V from the web build's game files, running natively on iPhone. Textures are smaller than the PC version.

### The game crashes or stops at every load when the language is Simplified Chinese

Fixed in v1.4.7, so update. This game build's Simplified Chinese text makes the game stop while loading, so with Simplified Chinese picked, the game's own text now shows in Traditional Chinese; the app's menus stay in Simplified Chinese. On older versions, pick another language in Settings › Language.

### What is this debug message on screen?

Texts showing as "... missing" were fixed in v1.4, and since v1.4.2 help boxes the game files have no text for (like "HELP_DCK missing") simply don't show. They were harmless. If you see another message, send a log (Settings › This device › Send log to the developer, with a short note in "What happened?").

### Does the port work on the iPhone Duo (the foldable)?

Yes. Since v1.5 the game fills the Duo's inner screen, keeps running when you fold or unfold it during play, and keeps the touch controls within thumb reach on the inner screen. Older versions run in a 16:9 box with black bars there. If something looks wrong on a Duo, send a log (Settings › This device › Send log to the developer); we haven't had one in hand yet.

### The game stopped and the screen says why (damaged files, a car layout mod, too many add-ons). What do I do?

Since v1.5 the stop screen names the cause and what to do. A game file that can't be read: check the game files in Settings › Game files and keep a few GB of storage free. A car layout mod or too many add-on cars: start without that mod (the screen offers it), or remove some add-on cars. A mod made for another game version (GTA V Enhanced): use the Legacy version of the mod. Otherwise send a log right after it happens.

## Known issues

Bugs we know about and are working on.

### With a controller, R2/RT doesn't accelerate the car. How do I fix it?

Right trigger not accelerating on some controllers is a known issue. v1.4 logs the trigger values: drive a while with the controller and send a log to help fix it.

### How do I fix bad audio or missing sound effects?

Missing sound effects for some players is a known issue. Since v1.4.3 the sound also comes back after interruptions (calls, alarms) that used to leave the game silent, and the game plays alongside your own music app. Faint or identical engine sounds come from the small web game files (see the engine sounds answer). If sound is still missing, send a log right after it happens (Settings › This device › Send log to the developer, with a short note in "What happened?").

### The game freezes when I change graphics in the game's pause menu and it asks to restart

Change graphics in the app's own Settings › Graphics instead (the ⚙️ button, or the pause menu's Settings button). The game's own restart prompt in its pause menu freezes in the port: a known issue.
