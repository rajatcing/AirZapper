import SwiftUI

/// Floating control panel: live status, flick meter, up/down learning, and tuning.
struct HUDView: View {
    @ObservedObject var gun: GunController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            status
            Divider()
            meter
            Divider()
            tilt
            Divider()
            controls
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 5) {
            StatusRow(label: "AirPods", value: gun.motionStatus, ok: gun.headphonesConnected)
            StatusRow(label: "Sensor", value: gun.sensorName, ok: gun.sensorOK)
            StatusRow(label: "Accessibility", value: gun.accessibilityOK ? "Granted" : "Required to click", ok: gun.accessibilityOK)
            StatusRow(label: "Target", value: gun.targetDescription, ok: gun.hasTarget)
            HStack {
                Text("Use AirPod").font(.caption).foregroundStyle(.secondary)
                Picker("Use AirPod", selection: $gun.sensorChoice) {
                    ForEach(SensorChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                if !gun.accessibilityOK {
                    Button("Accessibility Settings…") { gun.openAccessibilitySettings() }
                }
                Button("Bluetooth Settings…") { gun.openBluetoothSettings() }
                    .help("Turn off Automatic Ear Detection for your AirPods to use one out of your ear")
            }
        }
        .controlSize(.small)
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Flick speed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Shots \(gun.shots)").font(.caption.monospacedDigit())
            }
            FlickMeter(value: gun.flickSpeed, peak: gun.peakFlick, threshold: gun.threshold)
                .frame(height: 12)
            Text(String(format: "Aim  x %+.0f°   y %+.0f°", gun.aimXDeg, gun.aimYDeg))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var tilt: some View {
        VStack(alignment: .leading, spacing: 6) {
            if gun.learning {
                Text(gun.learnMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { gun.cancelLearning() }
                }
            } else {
                Text(gun.learnMessage.isEmpty
                     ? (gun.tiltLearned
                        ? "Up/down is learned for your grip."
                        : "Holding the AirPod in your hand? Click Learn up/down once so tilting moves the cursor up and down.")
                     : gun.learnMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Learn up/down…") { gun.startLearning() }
                    if gun.tiltLearned {
                        Button("Reset") { gun.resetTilt() }
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Aim", selection: $gun.aimMode) {
                ForEach(AimMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            SliderRow(label: "Trigger", value: $gun.threshold, range: 2...15, format: "%.1f rad/s")
            SliderRow(label: "Aim range", value: $gun.aimRange, range: 5...45, format: "±%.0f°")
            HStack {
                Toggle("Invert X", isOn: $gun.invertX)
                Toggle("Invert Y", isOn: $gun.invertY)
            }
            HStack {
                Toggle("Armed", isOn: $gun.armed)
                Spacer()
                Button("Recenter ( ` )") { gun.recenter() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            Text("Move the AirPod to aim. Swing past an edge to re-sync, or press ` to center the cursor. Flick to fire.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
    }
}

private struct StatusRow: View {
    let label: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            Text(value).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Bar showing current flick speed, recent peak, and the trigger threshold (red tick).
private struct FlickMeter: View {
    let value: Double
    let peak: Double
    let threshold: Double

    var body: some View {
        GeometryReader { geo in
            let scale = threshold * 1.6
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(value >= threshold ? Color.red : Color.accentColor)
                    .frame(width: w * min(value / scale, 1))
                Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 2)
                    .offset(x: w * min(peak / scale, 1) - 1)
                Rectangle().fill(Color.red).frame(width: 2)
                    .offset(x: w * threshold / scale - 1)
            }
        }
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .font(.caption.monospacedDigit())
                .frame(width: 66, alignment: .trailing)
        }
    }
}
