#if targetEnvironment(simulator)
import Network
import UIKit

/// Simulator only: the test harness's live channel (Harness/gta.py). One text command per line on
/// 127.0.0.1:7979 (PG_DEBUG_PORT), one JSON line back for each, in order.
///
/// Fingers, pad buttons and the touch layout are handled here on the main thread; everything else (game
/// commands, memory, script globals, the game state) goes to the engine (PGDebugCommand).
///
///     ui                                   the touch layout, what each finger does, the last pad sample
///     touch <finger> down|move <x> <y>     a finger at a point (fractions of the screen) or on a button (@name)
///     touch <finger> up
///     tap <x> <y> | @name [seconds]        down, then up after that long (0.15 s)
///     drag <finger> <x0> <y0> <x1> <y1> <seconds> [hold]   moves over that time, lifts after `hold` more seconds
///     pad <a+up|-> <seconds> [lx ly rx ry lt rt]          controller input, merged like a real controller's
///     mark <text>                          a line in the game log
///     sendlog <save 0|1> <note>            Send log to the developer, as its screen does (PG_LOG_ENDPOINT: a local catcher)
final class DebugChannel {
    static let shared = DebugChannel()
    private weak var controller: NativePortViewController?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "debug-channel")
    private var nextFinger = 1000

    func start(_ controller: NativePortViewController) {
        guard listener == nil else { return }
        self.controller = controller
        let port = NWEndpoint.Port(ProcessInfo.processInfo.environment["PG_DEBUG_PORT"] ?? "") ?? 7979
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { GameFolder.log("Debug channel: can't listen on \(port)."); return }
        listener.stateUpdateHandler = { state in
            if case .ready = state { GameFolder.log("Debug channel: listening on 127.0.0.1:\(port).") }
            if case .failed(let error) = state { GameFolder.log("Debug channel: \(error)") }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func serve(_ connection: NWConnection) {
        let commands = DispatchQueue(label: "debug-channel-connection")   // one at a time, replies in order
        var buffer = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data { buffer.append(data) }
                while let end = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer.removeSubrange(buffer.startIndex...end)
                    commands.async {
                        let reply = self.run(line)
                        connection.send(content: Data((reply + "\n").utf8), completion: .contentProcessed { _ in })
                    }
                }
                if done || error != nil { commands.async { connection.cancel() } } else { receive() }
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func run(_ line: String) -> String {
        let words = line.split(separator: " ").map(String.init)
        guard let command = words.first else { return Self.json(["ok": false, "error": "empty"]) }
        if command == "sendlog" {
            let done = DispatchSemaphore(value: 0); var reply: (String, String) = ("", "")
            LogUploader.send(note: words.dropFirst(2).joined(separator: " "), includeSave: words.count > 1 && words[1] == "1") { reply = $0; done.signal() }
            _ = done.wait(timeout: .now() + 90)
            return Self.json(["ok": true, "title": reply.0, "detail": reply.1])
        }
        if ["ui", "touch", "tap", "drag", "pad", "mark", "resize", "alert", "play", "screen", "mouse", "open"].contains(command) {
            var reply: [String: Any] = [:]
            DispatchQueue.main.sync { reply = self.runOnMain(command, Array(words.dropFirst())) }
            return Self.json(reply)
        }
        var out = [CChar](repeating: 0, count: 1 << 20)
        PGDebugCommand(line, &out, out.count)
        return String(cString: out)
    }

    private func runOnMain(_ command: String, _ arguments: [String]) -> [String: Any] {
        guard let controller else { return ["ok": false, "error": "no game screen"] }
        let controls = controller.debugTouchControls
        let size = controls.bounds.size
        // A point: "x y" as fractions of the screen, or "@name" for a visible button's centre.
        func point(_ from: ArraySlice<String>) -> (CGPoint, Int)? {
            if let first = from.first, first.hasPrefix("@") {
                return controls.debugButton(named: String(first.dropFirst())).map { ($0, 1) }
            }
            guard from.count >= 2, let x = Double(from[from.startIndex]), let y = Double(from[from.startIndex + 1]) else { return nil }
            return (CGPoint(x: x * size.width, y: y * size.height), 2)
        }
        switch command {
        case "ui":
            var state = controls.debugState()
            let pad = controller.debugLastPad
            state["pad"] = ["buttons": pad.buttons, "left": [pad.leftX, pad.leftY], "right": [pad.rightX, pad.rightY], "triggers": [pad.leftTrigger, pad.rightTrigger]]
            state["ok"] = true
            return state
        case "touch":
            guard arguments.count >= 2, let finger = Int(arguments[0]) else { return ["ok": false, "error": "touch <finger> down|move|up [x y | @name]"] }
            switch arguments[1] {
            case "down", "move":
                guard let (at, _) = point(arguments.dropFirst(2)) else { return ["ok": false, "error": "no such point or button"] }
                controls.debugTouch(finger: finger, phase: arguments[1] == "down" ? .began : .moved, at: at)
            default:
                controls.debugTouch(finger: finger, phase: .ended, at: nil)
            }
            return ["ok": true]
        case "tap":
            guard let (at, used) = point(arguments[...]) else { return ["ok": false, "error": "no such point or button"] }
            let seconds = arguments.count > used ? Double(arguments[used]) ?? 0.15 : 0.15
            nextFinger += 1
            let finger = nextFinger
            controls.debugTouch(finger: finger, phase: .began, at: at)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { controls.debugTouch(finger: finger, phase: .ended, at: nil) }
            return ["ok": true, "at": [at.x / size.width, at.y / size.height]]
        case "drag":
            let numbers = arguments.dropFirst().compactMap(Double.init)
            guard let finger = arguments.first.flatMap(Int.init), numbers.count >= 5 else {
                return ["ok": false, "error": "drag <finger> <x0> <y0> <x1> <y1> <seconds> [hold]"]
            }
            let from = CGPoint(x: numbers[0] * size.width, y: numbers[1] * size.height)
            let to = CGPoint(x: numbers[2] * size.width, y: numbers[3] * size.height)
            let seconds = max(0.02, numbers[4]), steps = max(1, Int(seconds * 60))
            controls.debugTouch(finger: finger, phase: .began, at: from)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds * Double(t)) {
                    controls.debugTouch(finger: finger, phase: .moved, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                }
            }
            if numbers.count > 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds + numbers[5]) { controls.debugTouch(finger: finger, phase: .ended, at: nil) }
            }
            return ["ok": true]
        case "pad":
            guard let names = arguments.first else { return ["ok": false, "error": "pad <a+up|-> <seconds> [lx ly rx ry lt rt]"] }
            let all: [String: PadButtons] = ["l2": .l2, "r2": .r2, "l1": .l1, "r1": .r1, "y": .y, "b": .b, "a": .a, "x": .x, "select": .select,
                                             "l3": .l3, "r3": .r3, "start": .start, "up": .up, "right": .right, "down": .down, "left": .left]
            var pad = PGPadState()
            for name in names.split(separator: "+") where name != "-" {
                guard let bit = all[String(name)] else { return ["ok": false, "error": "no button \(name)"] }
                pad.padButtons.insert(bit)
            }
            let numbers = arguments.dropFirst().compactMap(Float.init)
            let seconds = Double(numbers.first ?? 0.15)
            if numbers.count >= 5 { pad.leftX = numbers[1]; pad.leftY = numbers[2]; pad.rightX = numbers[3]; pad.rightY = numbers[4] }
            if numbers.count >= 7 { pad.leftTrigger = numbers[5]; pad.rightTrigger = numbers[6] }
            controller.debugHold(pad, for: seconds)
            return ["ok": true]
        case "mouse":
            // mouse <dx> <dy> <seconds> [wheel notches]: relative mouse movement every frame, with pointer focus and lock.
            let numbers = arguments.compactMap(Double.init)
            guard numbers.count >= 3 else { return ["ok": false, "error": "mouse <dx> <dy> <seconds> [wheel]"] }
            let frames = max(1, Int(numbers[2] * 60))
            PGSetMouseFocus(true, true)
            if numbers.count >= 4 { PGMouseWheel(Int32(numbers[3])) }
            for frame in 0..<frames {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(frame) / 60) {
                    PGSetMouseFocus(true, true); PGMouseInput(Int32(numbers[0]), Int32(numbers[1]), 0)
                    if frame == frames - 1 { PGSetMouseFocus(true, false) }
                }
            }
            return ["ok": true]
        case "mark":
            GameFolder.log("MARK: \(arguments.joined(separator: " "))")
            return ["ok": true]
        case "alert":
            // alert: the alert on screen (title, message, buttons); alert <n>: press its button n (GTA-153 tests).
            var top: UIViewController? = controller
            while let next = top?.presentedViewController { top = next }
            guard let alert = top as? UIAlertController else { return ["ok": false, "error": "no alert on screen"] }
            let reply: [String: Any] = ["ok": true, "title": alert.title ?? "", "message": alert.message ?? "", "actions": alert.actions.map { $0.title ?? "" }]
            if let index = arguments.first.flatMap(Int.init), alert.actions.indices.contains(index) {
                typealias Handler = @convention(block) (UIAlertAction) -> Void
                let action = alert.actions[index], handler = action.value(forKey: "handler") as AnyObject?
                alert.dismiss(animated: false) { if let handler { unsafeBitCast(handler, to: Handler.self)(action) } }
            }
            return reply
        case "play":
            // Presses Play on the home screen, as a player would.
            controller.debugPressPlay()
            return ["ok": true]
        case "screen":
            // The screen on top: its type and title (Game files, Settings…).
            var top: UIViewController? = controller
            while let next = top?.presentedViewController { top = next }
            let shown = (top as? UINavigationController)?.topViewController ?? top
            return ["ok": true, "screen": shown.map { String(describing: type(of: $0)) } ?? "", "title": shown?.title ?? ""]
        case "open":
            // open mods: Settings › Mods on top, for screenshots of its lists (GTA-167); close: dismiss what's on top.
            var top: UIViewController? = controller
            while let next = top?.presentedViewController { top = next }
            if arguments.first == "mods" { top?.present(UINavigationController(rootViewController: ModsViewController()), animated: false); return ["ok": true] }
            if arguments.first == "close" { top?.dismiss(animated: false); return ["ok": true] }
            return ["ok": false, "error": "open mods|close"]
        case "resize":
            // resize <width> <height>: the live back-buffer resize a resolution change in Settings or a TV makes (GTA-89).
            guard arguments.count == 2, let width = Int32(arguments[0]), let height = Int32(arguments[1]) else {
                return ["ok": false, "error": "resize <width> <height>"]
            }
            PGSetBackBufferSize(width, height)
            GameFolder.log("Graphics: live resize to \(width)×\(height) (harness)")
            return ["ok": true]
        default:
            return ["ok": false, "error": "unknown command"]
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return #"{"ok":false,"error":"reply"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
