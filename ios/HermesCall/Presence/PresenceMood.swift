import Foundation

/// What the presence shows during a call, inferred from the audio levels: the phone only knows
/// "the owner stopped talking" from the mic level falling while no agent audio has come back yet.
struct PresenceMood: Equatable {
    enum State: Equatable { case idle, listening, thinking, speaking }

    private(set) var state = State.idle
    private var lastOwnerSpeech: Date?

    static let speakingLevel = 0.04
    static let listeningLevel = 0.05
    /// Quiet this long before the owner counts as done talking.
    static let pauseTolerance: TimeInterval = 0.8
    /// Longest wait for an answer shown as "thinking".
    static let thinkingWindow: TimeInterval = 12

    mutating func update(agent: Double, mic: Double, muted: Bool, now: Date = Date()) {
        if agent > Self.speakingLevel {
            state = .speaking
            lastOwnerSpeech = nil
        } else if !muted, mic > Self.listeningLevel {
            state = .listening
            lastOwnerSpeech = now
        } else if let spoke = lastOwnerSpeech, now.timeIntervalSince(spoke) < Self.pauseTolerance {
            state = .listening  // a pause between words
        } else if let spoke = lastOwnerSpeech, now.timeIntervalSince(spoke) < Self.thinkingWindow {
            state = .thinking
        } else {
            state = .idle
            lastOwnerSpeech = nil
        }
    }
}
