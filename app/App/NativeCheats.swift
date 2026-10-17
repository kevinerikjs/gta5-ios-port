import Foundation

struct NativeCheatAction {
    let title: String
    let command: PGCheatCommand
    var value: Int32 = 0
}

struct NativeCheatGroup {
    let title: String
    let detail: String
    let actions: [NativeCheatAction]
    var toggleCommand: PGCheatCommand? = nil

    var statusDetail: String {
        guard let command = toggleCommand else { return AppLanguage.choose(detail) }
        return AppLanguage.choose(PGCheatEnabled(command) ? "On" : "Off") + " · " + AppLanguage.choose(detail)
    }

    static let all: [NativeCheatGroup] = [
        .init(title: "Persistent god mode", detail: "Stay invincible until turned off. Applies when gameplay resumes; resets when the app closes.", actions: [
            .init(title: "God mode on", command: PGCheatGodMode, value: 1),
            .init(title: "God mode off", command: PGCheatGodMode, value: 0),
        ], toggleCommand: PGCheatGodMode),
        .init(title: "Never wanted", detail: "Clear wanted stars and prevent new ones. Applies when gameplay resumes; resets when the app closes.", actions: [
            .init(title: "Never wanted on", command: PGCheatNeverWanted, value: 1),
            .init(title: "Never wanted off", command: PGCheatNeverWanted, value: 0),
        ], toggleCommand: PGCheatNeverWanted),
        .init(title: "Repair vehicle", detail: "Repairs and cleans the vehicle you are currently in.", actions: [
            .init(title: "Repair vehicle", command: PGCheatRepairVehicle),
        ]),
        .init(title: "Clean vehicle", detail: "Removes dirt from your current vehicle.", actions: [
            .init(title: "Clean vehicle", command: PGCheatCleanVehicle),
        ]),
        .init(title: "Time of day", detail: "Choose a time. The clock keeps running afterward.", actions: [
            .init(title: "Morning · 06:00", command: PGCheatSetTime, value: 6),
            .init(title: "Noon · 12:00", command: PGCheatSetTime, value: 12),
            .init(title: "Evening · 18:00", command: PGCheatSetTime, value: 18),
            .init(title: "Midnight · 00:00", command: PGCheatSetTime, value: 0),
        ]),
        .init(title: "Weather", detail: "Choose weather or restore the natural cycle. Missions may override it.", actions: [
            .init(title: "Clear", command: PGCheatSetWeather, value: 0),
            .init(title: "Extra sunny", command: PGCheatSetWeather, value: 1),
            .init(title: "Cloudy", command: PGCheatSetWeather, value: 2),
            .init(title: "Overcast", command: PGCheatSetWeather, value: 3),
            .init(title: "Rain", command: PGCheatSetWeather, value: 4),
            .init(title: "Thunderstorm", command: PGCheatSetWeather, value: 5),
            .init(title: "Fog", command: PGCheatSetWeather, value: 6),
            .init(title: "Natural weather", command: PGCheatNaturalWeather),
        ]),
    ]
}
