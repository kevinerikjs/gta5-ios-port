import GameController
import CoreHaptics

/// Plays the engine's controller rumble (PGReadRumble) on the controller's own motors through
/// Core Haptics. DualSense and DualShock 4 expose the heavy and light motors as the left and
/// right handle localities; a controller with one locality gets the stronger of the two.
///
/// Each motor keeps one engine running. Rumble is a stream of short plain pattern players
/// (an advanced looping player with live intensity fails on controller engines with "Couldn't
/// communicate with a helper application"), re-issued every 100 ms while the engine asks for a
/// value (50 ms, short enough for the engine's per-shot pulses) and whenever the value moves.
/// Any failure rebuilds that motor's engine. Everything runs on the queue given at init
/// (ControllerFeedback's 100 Hz clock), never on the main thread.
final class ControllerHaptics {
    private final class Motor {
        let locality: GCHapticsLocality
        let sharpness: Float
        var engine: CHHapticEngine?
        var starting = false
        var ready = false            // engine running
        var intensity: Float = 0     // last burst's value
        var lastBurst: TimeInterval = 0
        var wanted: Float = 0        // latest value asked for
        var retryAt: TimeInterval = 0
        var failures = 0
        init(locality: GCHapticsLocality, sharpness: Float) { self.locality = locality; self.sharpness = sharpness }
    }
    private static let burstEvery: TimeInterval = 0.05
    private static let burstLength: TimeInterval = 0.08
    private var motors: [Motor] = []   // [heavy, light] or one shared motor
    private var single = false
    private weak var controller: GCController?
    private var haptics: GCDeviceHaptics?
    private var lastLogged: [String: TimeInterval] = [:]
    private let queue: DispatchQueue   // every call and callback runs here
    var log: ((String) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    /// Keeps engines for the controller in use; `nil` releases them.
    func attach(_ controller: GCController?) {
        if controller === self.controller { return }
        detach()
        self.controller = controller
        guard let controller else { return }
        let name = controller.vendorName ?? "the controller"
        guard let haptics = controller.haptics else {
            log?("Controller rumble: \(name) offers no haptics.")
            return
        }
        self.haptics = haptics
        let localities = haptics.supportedLocalities
        single = !(localities.contains(.leftHandle) && localities.contains(.rightHandle))
        motors = single ? [Motor(locality: .default, sharpness: 0.5)] : [Motor(locality: .leftHandle, sharpness: 0.2), Motor(locality: .rightHandle, sharpness: 0.8)]
        let names = localities.map { $0.rawValue }.sorted().joined(separator: ", ")
        log?("Controller rumble: \(name) with \(motors.count) motor engine\(motors.count == 1 ? "" : "s") (\(names)).")
        let now = CACurrentMediaTime()
        for motor in motors { prepare(motor, now: now, pulse: true) }
    }

    func detach() {
        motors.forEach(tearDown)
        motors.removeAll()
        haptics = nil
        controller = nil
    }

    /// Engine actuator values 0...1, every poll.
    func update(low: Float, high: Float, now: TimeInterval) {
        guard !motors.isEmpty else { return }
        let values: [Float] = single ? [max(low, high)] : [low, high]
        for (motor, value) in zip(motors, values) {
            motor.wanted = value.isFinite ? min(1, max(0, value)) : 0
            guard motor.ready else {
                if now >= motor.retryAt { prepare(motor, now: now, pulse: false) }
                continue
            }
            if motor.wanted > 0 {
                let moved = abs(motor.wanted - motor.intensity) >= 0.08
                if moved || now - motor.lastBurst >= Self.burstEvery { burst(motor, motor.wanted, length: Self.burstLength, now: now) }
            } else {
                motor.intensity = 0
            }
        }
    }

    /// Creates (or re-creates) the motor's engine and starts it.
    private func prepare(_ motor: Motor, now: TimeInterval, pulse: Bool) {
        guard !motor.starting, let haptics else { return }
        motor.starting = true
        motor.retryAt = now + min(10, 1 + Double(motor.failures) * 2)
        tearDown(motor)
        guard let engine = haptics.createEngine(withLocality: motor.locality) else {
            motor.starting = false
            failed(motor, "no engine for \(motor.locality.rawValue)", nil)
            return
        }
        engine.playsHapticsOnly = true
        engine.resetHandler = { [weak self, weak motor] in
            self?.queue.async {
                guard let self, let motor else { return }
                self.note("Controller rumble: haptic engine reset (\(motor.locality.rawValue)); rebuilding.")
                motor.ready = false; motor.retryAt = 0
            }
        }
        engine.stoppedHandler = { [weak self, weak motor] reason in
            self?.queue.async {
                guard let self, let motor else { return }
                if motor.ready { self.note("Controller rumble: haptic engine stopped (\(motor.locality.rawValue), reason \(reason.rawValue)); rebuilding.") }
                motor.ready = false; motor.retryAt = 0
            }
        }
        motor.engine = engine
        engine.start { [weak self, weak motor] error in
            self?.queue.async {
                guard let self, let motor else { return }
                motor.starting = false
                if let error { self.failed(motor, "start", error); return }
                motor.ready = true
                motor.failures = 0
                motor.intensity = 0
                // A short buzz when a controller is taken up: the motors answer before the game needs them.
                if pulse { self.burst(motor, 0.8, length: 0.3, now: CACurrentMediaTime()) }
            }
        }
    }

    private func burst(_ motor: Motor, _ value: Float, length: TimeInterval, now: TimeInterval) {
        guard let engine = motor.engine else { return }
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: value),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: motor.sharpness),
        ], relativeTime: 0, duration: length)
        do {
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            motor.intensity = value
            motor.lastBurst = now
        } catch { failed(motor, "burst", error) }
    }

    private func tearDown(_ motor: Motor) {
        if let engine = motor.engine {
            engine.resetHandler = {}
            engine.stoppedHandler = { _ in }
            engine.stop(completionHandler: nil)
        }
        motor.engine = nil
        motor.ready = false
        motor.intensity = 0
    }

    private func failed(_ motor: Motor, _ step: String, _ error: Error?) {
        motor.failures += 1
        tearDown(motor)
        motor.retryAt = CACurrentMediaTime() + min(10, 1 + Double(motor.failures) * 2)
        note("Controller rumble: \(step) failed for \(motor.locality.rawValue)\(error.map { ": \($0.localizedDescription)" } ?? ""); retrying.")
    }

    /// One line per distinct message every 10 s at most.
    private func note(_ line: String) {
        let now = CACurrentMediaTime()
        if let last = lastLogged[line], now - last < 10 { return }
        lastLogged[line] = now
        log?(line)
    }
}
