import Foundation

public enum AudioDestination: String, CaseIterable, Identifiable {
    case teams, listen
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .teams: return "Teams virtual microphone"
        case .listen: return "Listen locally"
        }
    }
}

public struct AudioEndpoint {
    public enum Kind { case physical, blackHole, other }
    public let uid: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let kind: Kind
    public init(uid: String, inputChannels: Int, outputChannels: Int, kind: Kind) {
        self.uid = uid
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.kind = kind
    }
}

public enum AudioRouting {
    public static func validate(input: AudioEndpoint, output: AudioEndpoint, destination: AudioDestination) throws {
        guard input.inputChannels > 0, output.outputChannels > 0 else {
            throw BridgeError.unavailable("Choose an available audio source and output device.")
        }
        // A physical headset can be both microphone and speaker. A loopback device cannot safely be both ends.
        guard input.uid != output.uid || input.kind == .physical else {
            throw BridgeError.unavailable("Feedback prevented: choose different loopback input and output devices.")
        }
        switch destination {
        case .teams:
            guard output.kind == .blackHole, output.outputChannels >= 2 else {
                throw BridgeError.unavailable("Teams mode requires BlackHole as the output.")
            }
        case .listen:
            guard output.kind == .physical else {
                throw BridgeError.unavailable("Listen locally requires headphones or speakers as the output.")
            }
        }
    }
}
