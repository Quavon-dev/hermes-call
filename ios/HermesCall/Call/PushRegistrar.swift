import Foundation
import HermesCallCore
@preconcurrency import PushKit

/// Receives the VoIP push token and incoming-call pushes. Created at launch so a push
/// can wake the app even when it was not running.
@MainActor
final class PushRegistrar: NSObject {
    private let registry = PKPushRegistry(queue: .main)
    private let app: AppModel
    private let calls: CallCoordinator

    init(app: AppModel, calls: CallCoordinator) {
        self.app = app
        self.calls = calls
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }
}

/// The registry delivers on the main queue (see `PKPushRegistry(queue: .main)`).
extension PushRegistrar: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated { app.updatePushToken(token) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated { app.updatePushToken(nil) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType, completion: @escaping () -> Void) {
        let callID = IncomingPush.callID(from: payload.dictionaryPayload)
        nonisolated(unsafe) let completion = completion
        MainActor.assumeIsolated { calls.reportIncomingPush(callID: callID) { completion() } }
    }
}

enum IncomingPush {
    /// The relay's payload is exactly `{"c": call_id}`; anything else is not a valid ring.
    static func callID(from payload: [AnyHashable: Any]) -> String? {
        guard payload.count == 1, let value = payload["c"] as? String,
              (try? Base64URL.decode(value, length: 16)) != nil else { return nil }
        return value
    }
}

enum PushEnvironment {
    /// Xcode builds carry a development `aps-environment` in their profile; TestFlight/App Store builds
    /// have no embedded profile and use production APNs.
    static var current: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return "production" }
        return from(provisioningProfile: data)
    }

    static func from(provisioningProfile data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>") else { return "production" }
        let value = text[key.upperBound...].drop { $0.isWhitespace }
        return value.hasPrefix("<string>development</string>") ? "sandbox" : "production"
    }
}
