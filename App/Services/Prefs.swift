import Foundation

/// UserDefaults keys shared by services and `@AppStorage` in settings.
enum Prefs {
    static let realertEnabled = "realertEnabled"
    static let realertMinutes = "realertMinutes"
    static let realertMax = "realertMax"
    static let tomorrowHour = "tomorrowHour"
    static let remindersListID = "remindersListID"
    static let retentionDays = "retentionDays"
    static let doNotDisturb = "doNotDisturb"
    static let onboarded = "onboarded"

    static func register() {
        UserDefaults.standard.register(defaults: [
            realertEnabled: true, realertMinutes: 5, realertMax: 12, tomorrowHour: 9,
            remindersListID: "", retentionDays: 30, doNotDisturb: false,
        ])
    }

    static var defaults: UserDefaults { .standard }
}
