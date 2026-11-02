# Player stats

From v1.4.4 the app sends a few anonymous stats, so the port's developer can see how many people play, on which iPhones, and where the game struggles. Nothing in them says who you are.

## What is sent

- **A random install ID**, made by the app the first time it starts. It isn't your Apple ID, your name, your phone's name or any hardware ID, and deleting the app makes a new one.
- **The app and the iPhone:** the app's version, the iPhone model (for example iPhone14,3), the iOS version, the memory the app may use and whether extra memory is on, and the app's language.
- **When you play:** that the app was opened; when a game starts, the mode (Story, Sandbox or the test map), the graphics preset, the Experimental settings, and how many mod files, script mods and add-on packs are active (counts only, no names); when you stop, how many minutes you played, the average and lowest FPS, and how hot the phone got.
- **Story progress:** the name of each mission you start (for example fbi5A), and whether it was failed or ended.
- **Problems:** when the engine stops, the first words of the reason (no file paths), and the minutes played until then.
- **Cheats:** which Cheats row you used (for example "Repair vehicle" or the vehicle spawner).

## What is not sent

Your saves, your game files, your mods' names or files, your logs, your location, your IP address, contacts, or anything you type. The country is taken from the connection (two letters, like EE) and the address itself is not kept.

## Where it goes

The app sends the stats to the project's website (fivestarport.site/api/stats). The site checks every item against the list above, drops anything else, and passes them on to the developer's stats service, PostHog (EU). The code is in this repository: [app/App/Analytics.swift](../app/App/Analytics.swift). Logs you send with **Send log to the developer** are separate and only sent when you tap Send.
