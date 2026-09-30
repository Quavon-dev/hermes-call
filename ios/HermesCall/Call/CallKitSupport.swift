@preconcurrency import CallKit
import Foundation
import HermesCallCore
import UIKit

/// CallKit set-up and the pure helpers of the call flow (no call state here).
extension CallCoordinator {
    static func configuration(includeInRecents: Bool) -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = includeInRecents
        configuration.iconTemplateImageData = iconTemplate
        return configuration
    }

    /// The glyph iOS shows on the call screen's app button (a template: only its alpha counts).
    static let iconTemplate: Data? = {
        let side: CGFloat = 40
        let configuration = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        guard let symbol = UIImage(systemName: "waveform", withConfiguration: configuration)?
            .withTintColor(.black, renderingMode: .alwaysOriginal) else { return nil }
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            symbol.draw(at: CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2))
        }
        return image.pngData()
    }()

    /// Who rings before a bridge confirms it (the push does not say): the agent's name when there is one,
    /// both names for two, else a neutral name. The confirmed ring then shows the right agent.
    static func ringName(_ names: [String]) -> String {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        switch unique.count {
        case 1: return unique[0]
        case 2: return "\(unique[0]) or \(unique[1])"
        default: return "Your agent"
        }
    }

    /// The call id is 16 random bytes, so it doubles as the CallKit UUID: a push and an `invite`
    /// for the same ring become one call (CallKit rejects the second report as a duplicate).
    static func callUUID(_ callID: String) -> UUID? {
        guard let bytes = try? Base64URL.decode(callID, length: 16) else { return nil }
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    // CallKit's completions: made outside the main actor, so they never run as main-actor code on
    // CallKit's queue (Swift 6 traps there); they hop to the main actor themselves.

    nonisolated static func report(_ provider: CXProvider, incoming uuid: UUID, update: CXCallUpdate,
                                           done: @escaping @Sendable (Error?) -> Void) {
        provider.reportNewIncomingCall(with: uuid, update: update) { error in done(error) }
    }

    /// `failed` runs only when CallKit refused the transaction.
    nonisolated static func request(_ controller: CXCallController, _ action: CXAction, failed: @escaping @Sendable () -> Void) {
        controller.request(CXTransaction(action: action)) { error in if error != nil { failed() } }
    }

    static func update(caller: String) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.localizedCallerName = caller
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ProtocolError.timeout: "Your agent did not answer. Is the bridge running?"
        case ProtocolError.notConnected: "Cannot reach your relay."
        case ProtocolError.relay(let code): "The relay refused the call (\(code))."
        default: "The call could not be set up."
        }
    }
}
