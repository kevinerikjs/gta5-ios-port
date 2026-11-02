import GameController

/// DualSense adaptive triggers built from game state. The engine in this port has no trigger
/// effects of its own (they belong to the PS5 edition), so the feel comes from what it reports:
/// the selected weapon's group on foot, speed and the pedals in a vehicle, the rumble while firing.
final class TriggerEffects {
    enum Mode: Equatable {
        case off
        case weapon(start: Float, end: Float, strength: Float)
        case feedback(start: Float, strength: Float)
        case vibration(start: Float, amplitude: Float, frequency: Float)
    }
    private weak var controller: GCController?
    private weak var gamepad: GCDualSenseGamepad?
    private var left: Mode = .off
    private var right: Mode = .off
    private var firingUntil: TimeInterval = 0
    private var lastApplied: TimeInterval = 0
    private var pending = false
    var log: ((String) -> Void)?

    // Weapon groups (joaat of the engine's GROUP_* names).
    private static let pistol = joaat("GROUP_PISTOL"), smg = joaat("GROUP_SMG"), rifle = joaat("GROUP_RIFLE")
    private static let mg = joaat("GROUP_MG"), shotgun = joaat("GROUP_SHOTGUN"), sniper = joaat("GROUP_SNIPER")
    private static let heavy = joaat("GROUP_HEAVY"), thrown = joaat("GROUP_THROWN"), stungun = joaat("GROUP_STUNGUN")
    private static let petrolCan = joaat("GROUP_PETROLCAN"), fireExtinguisher = joaat("GROUP_FIREEXTINGUISHER")

    func attach(_ controller: GCController?) {
        if controller === self.controller { return }
        relax()
        self.controller = controller
        gamepad = controller?.physicalInputProfile as? GCDualSenseGamepad
        if let controller {
            log?(gamepad != nil ? "Adaptive triggers: driving \(controller.vendorName ?? "the controller")'s triggers from the game."
                                : "Adaptive triggers: \(controller.vendorName ?? "the controller") has none.")
        }
    }

    /// Both triggers free; used when the app is inactive or the controller changes.
    func relax() {
        guard let gamepad else { left = .off; right = .off; return }
        if left != .off { gamepad.leftTrigger.setModeOff(); left = .off }
        if right != .off { gamepad.rightTrigger.setModeOff(); right = .off }
    }

    func update(inPlay: Bool, context: UInt32, hints: PGTriggerHints, firing: Bool, leftPull: Float, rightPull: Float, now: TimeInterval) {
        guard gamepad != nil else { return }
        var wantLeft = Mode.off, wantRight = Mode.off
        if !inPlay {
            // nothing
        } else if context != 0 {
            // Driving: the pedals stiffen with speed, the brake more than the throttle.
            let speed = min(1, max(0, hints.speed / 40))     // 40 m/s is about 145 km/h
            wantRight = .feedback(start: 0.05, strength: 0.2 + 0.35 * speed)
            wantLeft = .feedback(start: 0.1, strength: 0.4 + 0.45 * speed)
        } else {
            let group = hints.weaponGroup
            if firing { firingUntil = now + 0.15 }
            // Automatic: the SMG, rifle and MG groups, and anything else that fires faster than
            // about seven rounds a second (the AP pistol).
            let interval = hints.timeBetweenShots
            let automatic = group == Self.smg || group == Self.rifle || group == Self.mg || (interval > 0 && interval < 0.15)
            if automatic && now < firingUntil && rightPull > 0.3 {
                // Each shot kicks the trigger: the vibration runs at the weapon's own fire rate
                // (GET_WEAPON_TIME_BETWEEN_SHOTS; the frequency is normalised over about 0...255 Hz),
                // so a Micro SMG chatters, a Combat MG hammers and the minigun blurs into a buzz.
                let rate: Float = interval > 0.005 ? 1 / interval : 12
                wantRight = .vibration(start: 0.1, amplitude: 0.95, frequency: min(0.8, max(0.02, rate / 255)))
            } else if group == Self.pistol || group == Self.stungun {
                wantRight = .weapon(start: 0.3, end: 0.55, strength: 0.6)
            } else if automatic {
                wantRight = .weapon(start: 0.2, end: 0.4, strength: 0.45)
            } else if group == Self.shotgun {
                wantRight = .weapon(start: 0.35, end: 0.7, strength: 0.9)
            } else if group == Self.sniper {
                wantRight = .weapon(start: 0.4, end: 0.6, strength: 0.8)
            } else if group == Self.heavy {
                wantRight = .feedback(start: 0.2, strength: 0.7)
            } else if group == Self.thrown || group == Self.petrolCan || group == Self.fireExtinguisher {
                wantRight = .feedback(start: 0.4, strength: 0.3)
            }
            // Aiming has a little weight whenever a gun is held.
            if wantRight != .off && group != Self.thrown { wantLeft = .feedback(start: 0.1, strength: 0.25) }
        }
        if wantLeft != left || wantRight != right { pending = true }
        // The controller applies modes asynchronously; changes go out at most every 50 ms.
        guard pending, now - lastApplied >= 0.05, let gamepad else { return }
        pending = false
        lastApplied = now
        if wantLeft != left { apply(wantLeft, to: gamepad.leftTrigger); left = wantLeft }
        if wantRight != right { apply(wantRight, to: gamepad.rightTrigger); right = wantRight }
    }

    private func apply(_ mode: Mode, to trigger: GCDualSenseAdaptiveTrigger) {
        switch mode {
        case .off: trigger.setModeOff()
        case let .weapon(start, end, strength): trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength)
        case let .feedback(start, strength): trigger.setModeFeedbackWithStartPosition(start, resistiveStrength: strength)
        case let .vibration(start, amplitude, frequency): trigger.setModeVibrationWithStartPosition(start, amplitude: amplitude, frequency: frequency)
        }
    }

    /// The engine's string hash (Jenkins one-at-a-time over the lowercased name).
    static func joaat(_ name: String) -> UInt32 {
        var h: UInt32 = 0
        for byte in name.lowercased().utf8 {
            h = h &+ UInt32(byte)
            h = h &+ (h << 10)
            h ^= h >> 6
        }
        h = h &+ (h << 3)
        h ^= h >> 11
        h = h &+ (h << 15)
        return h
    }
}
