#if CARPLAY_APP
import AVFoundation
import CarPlay
import HermesCallCore

/// A CarPlay app for Hermes Call: "Call <agent>" and the agent's latest messages, read aloud.
///
/// Not built by default: CarPlay apps need an entitlement Apple grants on request
/// (developer.apple.com/carplay). Calls already appear in CarPlay without it — CallKit shows incoming
/// and active calls in the car, and Siri ("Call Hermes") works there. Once the entitlement is granted:
/// 1. add `com.apple.developer.carplay-communication` (or the category Apple grants) to the entitlements,
/// 2. add `CARPLAY_APP` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in project.yml,
/// 3. add a `CPTemplateApplicationSceneSessionRoleApplication` scene with this delegate class to the
///    Info.plist `UIApplicationSceneManifest` (docs/ios.md, "CarPlay").
/// Driver safety: no text to read on screen beyond short titles; messages are spoken.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private let speech = AVSpeechSynthesizer()

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(rootTemplate(), animated: false, completion: nil)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        speech.stopSpeaking(at: .immediate)
        self.interfaceController = nil
    }

    private func rootTemplate() -> CPListTemplate {
        guard let app = AppServices.shared.app, let chat = AppServices.shared.chat, let calls = AppServices.shared.calls else {
            return CPListTemplate(title: "Hermes", sections: [])
        }
        let name = app.activeProfile?.bridgeName ?? RelayProfile.defaultAgentName
        let call = CPListItem(text: "Call \(name)", detailText: nil, image: UIImage(systemName: "phone.fill"))
        call.handler = { _, completion in
            Task { @MainActor in
                await calls.startCall()
                completion()
            }
        }
        let recent = chat.messages.filter { $0.role == .agent }.suffix(5).reversed().map { message in
            let item = CPListItem(text: String(message.preview.prefix(60)), detailText: message.date.formatted(.relative(presentation: .named)))
            item.handler = { [weak self] _, completion in
                self?.read(message.preview)
                completion()
            }
            return item
        }
        return CPListTemplate(title: name, sections: [
            CPListSection(items: [call]),
            CPListSection(items: Array(recent), header: "Latest messages — tap to hear", sectionIndexTitle: nil),
        ])
    }

    private func read(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }
}
#endif
