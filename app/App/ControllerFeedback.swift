import GameController
import QuartzCore

/// Drives the controller's rumble (ControllerHaptics) and adaptive triggers (TriggerEffects) from
/// a 100 Hz clock on its own queue, so a slow UI frame never delays or stretches a pulse. The
/// view controller hands it the controller in use and the live trigger positions every input
/// poll; the rest (rumble, game state, weapon, speed) is read straight from the engine here.
final class ControllerFeedback {
    private let queue = DispatchQueue(label: "gta5port.controller-feedback", qos: .userInteractive)
    private let haptics: ControllerHaptics
    private let triggers = TriggerEffects()
    private var timer: DispatchSourceTimer?
    private var controller: GCController?
    private var engineStarted = false
    private var active = false
    private var leftPull: Float = 0, rightPull: Float = 0
    private var rumbleOn = true, triggersOn = true, lightOn = true
    private var lightColor: (Float, Float, Float) = (-1, -1, -1)
    private var lightSentAt: TimeInterval = 0, lightWrites = 0
    private var reportedModel: UInt32 = 0
    /// Receives one-off lines (controller taken up, engine failures); called on the feedback queue.
    var log: ((String) -> Void)? {
        didSet { let log = log; queue.async { self.haptics.log = log; self.triggers.log = log } }
    }

    init() {
        haptics = ControllerHaptics(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    /// From the main thread, every input poll. `active` is false while the app is in the
    /// background: the motors stop and the triggers go slack, the controller stays attached.
    func update(controller: GCController?, engineStarted: Bool, active: Bool, leftPull: Float, rightPull: Float,
                rumble: Bool = GameSettings.shared.controllerRumble, triggers: Bool = GameSettings.shared.adaptiveTriggers,
                light: Bool = GameSettings.shared.controllerLight) {
        queue.async {
            self.controller = controller
            self.engineStarted = engineStarted
            self.active = active
            self.leftPull = leftPull
            self.rightPull = rightPull
            self.rumbleOn = rumble
            self.triggersOn = triggers
            self.lightOn = light
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        haptics.attach(controller)
        triggers.attach(controller)
        guard let controller, active else {
            haptics.update(low: 0, high: 0, now: now)
            triggers.relax()
            return
        }
        var low: Float = 0, high: Float = 0
        if engineStarted { PGReadRumble(&low, &high) }
        haptics.update(low: rumbleOn ? low : 0, high: rumbleOn ? high : 0, now: now)
        // Adaptive triggers follow the game: off in menus, cutscenes and while the phone is out.
        let inPlay = engineStarted && PGGameStatus() & 0x1F == 0 && !PGPauseMenuActive()
        updateLight(controller, inPlay: inPlay, now: now)
        guard triggersOn else { triggers.relax(); return }
        let context = inPlay ? PGCurrentTouchContext() : 0
        triggers.update(inPlay: inPlay, context: context, hints: inPlay ? PGReadTriggerHints(context) : PGTriggerHints(),
                        firing: high > 0.05, leftPull: leftPull, rightPull: rightPull, now: now)
    }

    // Light bar: the character's colour as the console versions show it (Michael blue, Franklin
    // green, Trevor orange), red and blue strobing while wanted, dim white in menus and loading.
    private static let michael = TriggerEffects.joaat("player_zero"), franklin = TriggerEffects.joaat("player_one"), trevor = TriggerEffects.joaat("player_two")
    private var reportedLight: ObjectIdentifier?
    private func updateLight(_ controller: GCController, inPlay: Bool, now: TimeInterval) {
        if reportedLight != ObjectIdentifier(controller) {
            reportedLight = ObjectIdentifier(controller)
            log?("Light bar: \(controller.vendorName ?? "the controller") \(controller.light == nil ? "has no light" : "has a light").")
        }
        guard let light = controller.light else { return }
        var color: (Float, Float, Float) = (0.25, 0.25, 0.25)
        if lightOn && inPlay {
            let hints = PGReadLightHints()
            if hints.modelHash != reportedModel {
                reportedModel = hints.modelHash
                let who = hints.modelHash == Self.michael ? " (Michael)" : hints.modelHash == Self.franklin ? " (Franklin)" : hints.modelHash == Self.trevor ? " (Trevor)" : ""
                log?("Light bar: playing model " + String(format: "%08x", hints.modelHash) + who + ".")
            }
            if hints.wantedLevel > 0 {
                // Faster strobe at higher wanted levels: 2 Hz at one star, 5 Hz at five.
                let period = 1 / (1.25 + 0.75 * Double(hints.wantedLevel))
                color = now.truncatingRemainder(dividingBy: period) < period / 2 ? (1, 0.05, 0.05) : (0.05, 0.2, 1)
            } else if hints.modelHash == Self.michael { color = (0.25, 0.55, 1) }
            else if hints.modelHash == Self.franklin { color = (0.2, 0.9, 0.35) }
            else if hints.modelHash == Self.trevor { color = (1, 0.45, 0.1) }
            else { color = (0.8, 0.8, 0.8) }
        } else if !lightOn {
            color = (0, 0, 0)
        }
        // Re-send once a second even when unchanged: the system rewrites the controller's output
        // report when the haptic engines start or the controller re-syncs, which can drop the colour.
        guard color != lightColor || now - lightSentAt > 1 else { return }
        lightColor = color
        lightSentAt = now
        lightWrites += 1
        if lightWrites <= 3 || lightWrites % 600 == 0 {
            log?("Light bar: write \(lightWrites) \(String(format: "(%.2f, %.2f, %.2f)", color.0, color.1, color.2)).")
        }
        let gcColor = GCColor(red: color.0, green: color.1, blue: color.2)
        DispatchQueue.main.async { light.color = gcColor }
    }
}
