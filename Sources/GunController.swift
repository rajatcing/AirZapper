import AppKit
import ApplicationServices
import CoreMotion
import simd

enum AimMode: String, CaseIterable, Identifiable {
    case head = "Motion aim"
    case trackpad = "Trackpad aim"
    var id: String { rawValue }
}

/// Which AirPod's motion to accept. macOS picks the streaming bud; this only filters.
enum SensorChoice: String, CaseIterable, Identifiable {
    case right = "Right"
    case left = "Left"
    case either = "Either"
    var id: String { rawValue }

    func accepts(_ location: CMDeviceMotion.SensorLocation) -> Bool {
        switch self {
        case .right: location != .headphoneLeft
        case .left: location != .headphoneRight
        case .either: true
        }
    }
}

/// The emulator picture being shot at, in global screen coordinates (top-left origin, same as CGEvent).
struct Target: Equatable {
    var title: String
    var picture: CGRect
}

/// Turns AirPods motion into a light gun, whether the AirPod is worn or held in the hand.
///
/// Aiming works like an air mouse: rotation about gravity moves the cursor left/right (no setup,
/// independent of grip), and rotation about a learned "tilt" axis moves it up/down. A sharp tilt
/// or twist fires a left click, which OpenEmu feeds to the NES Zapper at that point.
@MainActor
final class GunController: NSObject, ObservableObject {
    static let openEmuBundleID = "org.openemu.OpenEmu"

    /// Tilt axis of an AirPod worn in the ear (nodding), used until one is learned.
    private static let inEarTiltAxis = SIMD3<Double>(1, 0, 0)

    // NES picture is 256x224 (overscan cropped) with 8:7 pixels.
    private let pictureAspect = 256.0 * 8.0 / 7.0 / 224.0
    private let titleBarHeight: CGFloat = 28
    private let refractory: TimeInterval = 0.35
    private let triggerHold: TimeInterval = 0.08
    private let aimFreezeAfterShot: TimeInterval = 0.3
    private let manualOverride: TimeInterval = 1.5
    private let learnTimeout: TimeInterval = 8
    private let learnEnough = 2.0  // radians of tilting to collect, about two up-and-down swings

    // MARK: Settings (persisted)

    @Published var armed = true
    @Published var aimMode: AimMode = AimMode(rawValue: UserDefaults.standard.string(forKey: "aimMode") ?? "") ?? .head {
        didSet { UserDefaults.standard.set(aimMode.rawValue, forKey: "aimMode") }
    }
    /// Tilt/twist speed (rad/s) that counts as pulling the trigger.
    @Published var threshold: Double = UserDefaults.standard.object(forKey: "flickThreshold") as? Double ?? 6 {
        didSet { UserDefaults.standard.set(threshold, forKey: "flickThreshold") }
    }
    /// Degrees of rotation from center to the left/right edge of the picture.
    @Published var aimRange: Double = UserDefaults.standard.object(forKey: "aimRange") as? Double ?? 15 {
        didSet { UserDefaults.standard.set(aimRange, forKey: "aimRange") }
    }
    @Published var invertX = UserDefaults.standard.bool(forKey: "invertX") {
        didSet { UserDefaults.standard.set(invertX, forKey: "invertX") }
    }
    @Published var invertY = UserDefaults.standard.bool(forKey: "invertY") {
        didSet { UserDefaults.standard.set(invertY, forKey: "invertY") }
    }
    @Published var sensorChoice = SensorChoice(rawValue: UserDefaults.standard.string(forKey: "sensorChoice") ?? "") ?? .either {
        didSet {
            UserDefaults.standard.set(sensorChoice.rawValue, forKey: "sensorChoice")
            recenterPending = true
        }
    }

    private var tiltAxis = loadAxis("tiltAxis") ?? GunController.inEarTiltAxis
    @Published var tiltLearned = UserDefaults.standard.bool(forKey: "tiltLearned")

    // MARK: Status shown in the HUD

    @Published var headphonesConnected = false
    @Published var motionStatus = "Waiting for AirPods…"
    @Published var sensorName = "—"
    @Published var sensorOK = false
    @Published var accessibilityOK = AXIsProcessTrusted()
    @Published var targetDescription = "—"
    @Published var hasTarget = false
    @Published var flickSpeed: Double = 0
    @Published var peakFlick: Double = 0
    @Published var shots = 0
    @Published var aimXDeg: Double = 0
    @Published var aimYDeg: Double = 0
    @Published var learning = false
    @Published var learnMessage = ""

    // MARK: Internal state

    private let motion = CMHeadphoneMotionManager()
    private var sensorLocation: CMDeviceMotion.SensorLocation?
    private var recenterPending = true
    private var lastTimestamp: TimeInterval?
    /// Aim angles in radians: +x is right, +y is up. Clamped to the picture, so swinging past an edge re-syncs.
    private var aimX = 0.0
    private var aimY = 0.0
    /// Aim from the last sample before a flick began, and where to put aim back after the shot.
    private var calmAim: (t: TimeInterval, x: Double, y: Double)?
    private var restoreAim: (x: Double, y: Double)?
    private var rearmed = true
    private var target: Target?
    private var targetCheckedAt: TimeInterval = 0
    private var lastShotAt: TimeInterval = 0
    private var holdUntil: TimeInterval = 0
    private var manualUntil: TimeInterval = 0
    private var lastPlaced: CGPoint?
    private var lastSeenCursor: CGPoint?
    private var lastSampleAt: TimeInterval = 0
    private var samplesThisSecond = 0
    private var lastDebugLog: TimeInterval = 0
    private var statusTimer: Timer?
    private var learnSamples: [(dt: Double, w: SIMD3<Double>)] = []
    private var learnStartedAt: TimeInterval = 0
    private var learnCollected = 0.0

    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AirZapper.log")

    // MARK: Lifecycle

    func start() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        log("AirZapper starting (motion auth=\(CMHeadphoneMotionManager.authorizationStatus().rawValue), available=\(motion.isDeviceMotionAvailable), accessibility=\(accessibilityOK), sensor=\(sensorChoice.rawValue), tilt=\(tiltLearned ? "learned" : "in-ear"), threshold=\(threshold), range=\(aimRange))")

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        guard motion.isDeviceMotionAvailable else {
            motionStatus = "Headphone motion not supported on this Mac"
            log(motionStatus)
            return
        }
        motion.delegate = self
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.motionStatus = "Motion error: \(error.localizedDescription)"
                    self.log(self.motionStatus)
                    return
                }
                if let m { self.process(m) }
            }
        }
    }

    func recenter() {
        recenterPending = true
        log("recenter requested")
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openBluetoothSettings() {
        open("x-apple.systempreferences:com.apple.Bluetooth-Settings.extension")
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    /// Once a second: refresh permissions, target window, and stream health.
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        accessibilityOK = AXIsProcessTrusted()
        refreshTarget(now)
        if samplesThisSecond > 0 {
            motionStatus = "Streaming \(samplesThisSecond) Hz"
        } else if headphonesConnected, now - lastSampleAt > 2 {
            motionStatus = "No motion — turn off Ear Detection"
            flickSpeed = 0
            peakFlick *= 0.5
        }
        samplesThisSecond = 0
    }

    // MARK: Learning the up/down axis

    func startLearning() {
        learnSamples.removeAll()
        learnCollected = 0
        learnStartedAt = ProcessInfo.processInfo.systemUptime
        learnMessage = "Hold the AirPod the way you'll play. Tilt your hand UP, then back down. Do it twice."
        learning = true
        log("learning tilt axis")
    }

    func cancelLearning() {
        learning = false
        learnMessage = ""
    }

    func resetTilt() {
        cancelLearning()
        tiltAxis = Self.inEarTiltAxis
        tiltLearned = false
        saveTilt()
        recenter()
        log("tilt axis reset to in-ear default")
    }

    private func learnStep(tilt: SIMD3<Double>, dt: Double, now: TimeInterval) {
        if dt > 0 {
            learnSamples.append((dt, tilt))
            learnCollected += simd_length(tilt) * dt
        }
        if learnCollected >= learnEnough {
            finishLearning()
        } else if now - learnStartedAt > learnTimeout {
            learning = false
            learnMessage = "Didn't see enough tilting. Click Learn up/down and tilt a bit further."
            log("tilt learning timed out (collected \(String(format: "%.2f", learnCollected)) rad)")
        }
    }

    private func finishLearning() {
        learning = false

        // The tilt axis is the dominant rotation axis: principal eigenvector of the covariance.
        var covariance = simd_double3x3(0)
        for s in learnSamples {
            covariance += simd_double3x3(columns: (s.w * s.w.x, s.w * s.w.y, s.w * s.w.z)) * s.dt
        }
        guard var axis = learnSamples.max(by: { simd_length($0.w) < simd_length($1.w) }).map({ simd_normalize($0.w) }) else { return }
        for _ in 0..<30 {
            axis = simd_normalize(covariance * axis)
        }

        // The first big swing was UP, so make the angle positive there.
        var angle = 0.0
        for s in learnSamples {
            angle += simd_dot(s.w, axis) * s.dt
            if abs(angle) > 0.1 {
                if angle < 0 { axis = -axis }
                break
            }
        }

        tiltAxis = axis
        tiltLearned = true
        invertY = false
        saveTilt()
        recenter()
        learnMessage = "Learned. Tilting up and down now moves the cursor up and down."
        log(String(format: "tilt axis learned: (%.2f, %.2f, %.2f) from %d samples", axis.x, axis.y, axis.z, learnSamples.count))
    }

    private func saveTilt() {
        UserDefaults.standard.set([tiltAxis.x, tiltAxis.y, tiltAxis.z], forKey: "tiltAxis")
        UserDefaults.standard.set(tiltLearned, forKey: "tiltLearned")
    }

    // MARK: Motion

    private func process(_ m: CMDeviceMotion) {
        let now = ProcessInfo.processInfo.systemUptime
        lastSampleAt = now
        samplesThisSecond += 1
        if !headphonesConnected {
            headphonesConnected = true
            log("motion samples arriving")
        }

        // Motion comes from one bud at a time, and macOS picks which.
        let location = m.sensorLocation
        if location != sensorLocation {
            sensorLocation = location
            recenterPending = true
            log("motion now from \(Self.name(of: location))")
        }
        guard sensorChoice.accepts(location) else {
            sensorName = "\(Self.name(of: location)) — ignored"
            sensorOK = false
            flickSpeed = 0
            lastTimestamp = nil
            return
        }
        sensorName = "\(Self.name(of: location)) — move this one"
        sensorOK = true

        let dt = lastTimestamp.map { min(max(m.timestamp - $0, 0), 0.1) } ?? 0
        lastTimestamp = m.timestamp

        // Split the gyro into rotation about gravity (turning left/right) and about horizontal axes
        // (tilting/twisting). Both are independent of how the AirPod is held.
        let w = SIMD3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z)
        let g = SIMD3(m.gravity.x, m.gravity.y, m.gravity.z)
        let up = simd_length(g) > 0.5 ? -simd_normalize(g) : SIMD3<Double>(0, 0, 1)
        let turnRate = simd_dot(w, up)  // positive = turning left
        let tilt = w - turnRate * up
        let tiltSpeed = simd_length(tilt)

        if learning {
            flickSpeed = tiltSpeed
            learnStep(tilt: tilt, dt: dt, now: now)
            return
        }

        if recenterPending {
            aimX = 0
            aimY = 0
            calmAim = nil
            restoreAim = nil
            recenterPending = false
            log("recentered")
        }
        if let restore = restoreAim, now >= holdUntil {
            aimX = restore.x
            aimY = restore.y
            restoreAim = nil
        }

        var axis = tiltAxis - simd_dot(tiltAxis, up) * up
        let axisLength = simd_length(axis)
        axis = axisLength > 0.3 ? axis / axisLength : .zero
        let pitchRate = simd_dot(w, axis)  // positive = up

        let rangeX = aimRange * .pi / 180
        let rangeY = rangeX / pictureAspect
        aimX = clamp(aimX + (invertX ? 1 : -1) * turnRate * dt, -rangeX, rangeX)
        aimY = clamp(aimY + (invertY ? -1 : 1) * pitchRate * dt, -rangeY, rangeY)
        aimXDeg = aimX * 180 / .pi
        aimYDeg = aimY * 180 / .pi

        if now - targetCheckedAt > 0.4 { refreshTarget(now) }
        updateCursor(now: now)
        detectTrigger(tiltSpeed: tiltSpeed, turnRate: turnRate, gravity: g, gyro: w, now: now)
    }

    private func aimPoint(x: Double, y: Double, in r: CGRect) -> CGPoint {
        let rangeX = aimRange * .pi / 180
        let rangeY = rangeX / pictureAspect
        let nx = clamp(x / rangeX, -1, 1)
        let ny = clamp(y / rangeY, -1, 1)
        return CGPoint(x: r.midX + nx * r.width / 2, y: r.midY - ny * r.height / 2)
    }

    private func updateCursor(now: TimeInterval) {
        guard let target, armed, aimMode == .head, now >= holdUntil else { return }

        // If the trackpad moved the cursor since we last placed it, let the user have it for a moment.
        let cursor = currentCursor()
        if let ref = lastPlaced ?? lastSeenCursor, hypot(cursor.x - ref.x, cursor.y - ref.y) > 4 {
            manualUntil = now + manualOverride
        }
        lastSeenCursor = cursor
        lastPlaced = nil
        guard now >= manualUntil else { return }

        let p = aimPoint(x: aimX, y: aimY, in: target.picture)
        moveCursor(to: p)
        lastPlaced = p
    }

    private func detectTrigger(tiltSpeed: Double, turnRate: Double, gravity: SIMD3<Double>, gyro: SIMD3<Double>, now: TimeInterval) {
        flickSpeed = tiltSpeed
        peakFlick = max(tiltSpeed, peakFlick * 0.92)

        let onset = threshold * 0.35
        if tiltSpeed < onset {
            calmAim = (now, aimX, aimY)
            rearmed = true
        } else if now - lastDebugLog > 0.1 {
            lastDebugLog = now
            log(String(format: "flick tilt=%.2f turn=%+.2f gyro=(%+.2f, %+.2f, %+.2f) gravity=(%+.2f, %+.2f, %+.2f) threshold=%.1f",
                       tiltSpeed, turnRate, gyro.x, gyro.y, gyro.z, gravity.x, gravity.y, gravity.z, threshold))
        }

        guard tiltSpeed >= threshold, tiltSpeed > 1.2 * abs(turnRate), rearmed, now - lastShotAt > refractory else { return }
        rearmed = false
        lastShotAt = now
        fire(now: now, tiltSpeed: tiltSpeed)
    }

    // MARK: Firing

    private func fire(now: TimeInterval, tiltSpeed: Double) {
        guard armed else {
            log("trigger ignored: disarmed")
            return
        }
        refreshTarget(now)
        guard let target else {
            log("trigger ignored: \(targetDescription)")
            return
        }
        guard AXIsProcessTrusted() else {
            accessibilityOK = false
            log("trigger ignored: Accessibility permission missing")
            return
        }

        let p: CGPoint
        switch aimMode {
        case .head:
            // Shoot where you were aiming before the flick, and put aim back there afterwards.
            let aim = calmAim.flatMap { now - $0.t < 0.5 ? ($0.x, $0.y) : nil } ?? (aimX, aimY)
            restoreAim = aim
            p = aimPoint(x: aim.0, y: aim.1, in: target.picture)
        case .trackpad:
            p = clamp(currentCursor(), to: target.picture.insetBy(dx: 1, dy: 1))
        }

        holdUntil = now + aimFreezeAfterShot
        moveCursor(to: p)
        lastPlaced = p
        postMouse(.leftMouseDown, at: p)
        DispatchQueue.main.asyncAfter(deadline: .now() + triggerHold) { [weak self] in
            self?.postMouse(.leftMouseUp, at: p)
        }
        shots += 1
        log(String(format: "BANG #%d at (%.0f, %.0f) tilt=%.1f in %@ [%@]", shots, p.x, p.y, tiltSpeed, target.title, aimMode.rawValue))
    }

    private func moveCursor(to p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, at p: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func currentCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Target window

    private func refreshTarget(_ now: TimeInterval) {
        targetCheckedAt = now
        let (found, description) = findTarget()
        if found != target || description != targetDescription {
            if let found {
                log(String(format: "target \"%@\" picture=(%.0f, %.0f, %.0f x %.0f)",
                           found.title, found.picture.minX, found.picture.minY, found.picture.width, found.picture.height))
            } else {
                log("no target: \(description)")
            }
        }
        target = found
        targetDescription = description
        hasTarget = found != nil
    }

    private func findTarget() -> (Target?, String) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == Self.openEmuBundleID else {
            return (nil, "OpenEmu not in front — click the game")
        }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        guard let window = axElement(app, kAXFocusedWindowAttribute) else {
            return (nil, accessibilityOK ? "No OpenEmu window focused" : "Needs Accessibility")
        }
        let title = axString(window, kAXTitleAttribute) ?? ""
        guard isGameWindow(title) else {
            return (nil, "Start a game in OpenEmu")
        }
        guard var content = axFrame(window) else {
            return (nil, "Can't read OpenEmu window frame")
        }
        if !(axBool(window, "AXFullScreen") ?? false) {
            content.origin.y += titleBarHeight
            content.size.height -= titleBarHeight
        }
        return (Target(title: title, picture: fit(aspect: pictureAspect, in: content)), title)
    }

    private func isGameWindow(_ title: String) -> Bool {
        // The library window, plus the Preferences window, whose title is its selected tab.
        let nonGame: Set<String> = [
            "", "OpenEmu", "Library", "Gameplay", "Controls", "Cores", "System Files",
            "Cloud Sync", "Cover Art", "Achievements", "Debug",
        ]
        return !nonGame.contains(title)
            && !title.localizedCaseInsensitiveContains("preferences")
            && !title.localizedCaseInsensitiveContains("settings")
    }

    private static func name(of location: CMDeviceMotion.SensorLocation) -> String {
        switch location {
        case .headphoneLeft: "Left AirPod"
        case .headphoneRight: "Right AirPod"
        default: "Headphones"
        }
    }

    // MARK: Logging

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String) {
        let line = "\(Self.stamp.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }
}

extension GunController: CMHeadphoneMotionManagerDelegate {
    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            self.headphonesConnected = true
            self.motionStatus = "Connected"
            self.recenterPending = true
            self.log("AirPods connected")
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            self.headphonesConnected = false
            self.motionStatus = "Disconnected — turn off Ear Detection"
            self.sensorOK = false
            self.log("AirPods disconnected")
        }
    }
}

// MARK: - Helpers

private func loadAxis(_ key: String) -> SIMD3<Double>? {
    guard let a = UserDefaults.standard.array(forKey: key) as? [Double], a.count == 3 else { return nil }
    return SIMD3(a[0], a[1], a[2])
}

private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let v = axValue(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axValue(element, attribute) as? String
}

private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    axValue(element, attribute) as? Bool
}

private func axFrame(_ window: AXUIElement) -> CGRect? {
    guard let pv = axValue(window, kAXPositionAttribute), CFGetTypeID(pv) == AXValueGetTypeID(),
          let sv = axValue(window, kAXSizeAttribute), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

/// Largest rect of the given aspect ratio centered in `r` (how OpenEmu letterboxes the picture).
private func fit(aspect: Double, in r: CGRect) -> CGRect {
    if r.width / r.height > aspect {
        let w = r.height * aspect
        return CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height)
    }
    let h = r.width / aspect
    return CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h)
}

private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(v, lo), hi)
}

private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
    CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
}
