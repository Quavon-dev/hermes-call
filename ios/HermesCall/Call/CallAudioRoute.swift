@preconcurrency import AVFoundation
import AVKit
import os
import SwiftUI
@preconcurrency import WebRTC

/// The call's audio session: category, speaker, and what iOS does to it meanwhile (another call or
/// Siri interrupts, headphones are plugged in, a car or AirPods take over). `isSpeaker` always
/// follows the real output route, also when the owner switches it in Control Center.
@MainActor @Observable
final class CallAudioRoute {
    private(set) var isSpeaker = false
    /// Another app or call has the audio right now.
    private(set) var isInterrupted = false
    /// Name of the current output (e.g. "AirPods Pro", "Speaker"), for the call screen.
    private(set) var outputName = ""

    private let log = Logger(subsystem: "de.quavon.hermescall", category: "audio")
    private var observers: [Task<Void, Never>] = []

    init() {
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                self?.routeChanged()
            }
        })
        observers.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                let (began, resume) = Self.interruption(note.userInfo ?? [:])
                self?.interrupted(began: began, shouldResume: resume)
            }
        })
        routeChanged()
    }

    isolated deinit {
        observers.forEach { $0.cancel() }
    }

    /// Voice chat with Bluetooth hands-free; set before CallKit activates the session.
    func configure() {
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        do {
            try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        } catch {
            log.error("audio session configuration failed")
        }
    }

    func toggleSpeaker() {
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        do {
            try audio.overrideOutputAudioPort(isSpeaker ? .none : .speaker)
        } catch {
            log.error("speaker switch failed")
        }
        routeChanged()
    }

    /// After CallKit activated the call's audio: the presence speaks out loud when only the earpiece would play.
    func preferSpeaker(appearance: Appearance, enabled: Bool) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        guard Self.prefersSpeaker(appearance: appearance, enabled: enabled, outputs: outputs) else { return }
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        do {
            try audio.overrideOutputAudioPort(.speaker)
        } catch {
            log.error("speaker switch failed")
        }
        routeChanged()
    }

    /// Loudspeaker for HUD calls, but never over AirPods, headphones, a car or a speaker already chosen.
    nonisolated static func prefersSpeaker(appearance: Appearance, enabled: Bool, outputs: [AVAudioSession.Port]) -> Bool {
        appearance == .hud && enabled && !outputs.isEmpty && outputs.allSatisfy { $0 == .builtInReceiver }
    }

    /// A call ended: the next one starts on the earpiece again.
    func reset() {
        isInterrupted = false
        routeChanged()
    }

    private func routeChanged() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        isSpeaker = Self.isSpeaker(outputs.map(\.portType))
        outputName = outputs.first?.portName ?? ""
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        isInterrupted = began
        log.info("audio interruption \(began ? "began" : "ended", privacy: .public)")
        guard !began, shouldResume else { return }
        // The call keeps its audio: bring the engine back (CallKit re-activates the session itself).
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        EngineAudioDevice.shared.sessionActivated()
    }

    nonisolated static func isSpeaker(_ ports: [AVAudioSession.Port]) -> Bool {
        ports.contains(.builtInSpeaker)
    }

    /// (began, should resume) from an interruption notification.
    nonisolated static func interruption(_ info: [AnyHashable: Any]) -> (Bool, Bool) {
        let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
        return (type == .began, options.contains(.shouldResume))
    }
}

/// iOS's own output picker (AirPods, car, speaker…), for the call controls.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .label
        picker.activeTintColor = .tintColor
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
