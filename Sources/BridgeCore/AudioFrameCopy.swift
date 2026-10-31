import Foundation
import AVFoundation

public enum AudioFrameCopy {
    public static func byteCount(frames: Int, bytesPerFrame: Int, sourceBytes: Int, destinationBytes: Int) throws -> Int {
        guard frames >= 0, bytesPerFrame > 0, sourceBytes >= 0, destinationBytes >= 0 else { throw BridgeError.invalidPCM }
        let (bytes, overflow) = frames.multipliedReportingOverflow(by: bytesPerFrame)
        guard !overflow, bytes <= sourceBytes, bytes <= destinationBytes else { throw BridgeError.invalidPCM }
        return bytes
    }

    public static func copy(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { throw BridgeError.invalidPCM }
        copy.frameLength = source.frameLength
        let original = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard original.count == destination.count else { throw BridgeError.invalidPCM }
        for index in 0..<original.count {
            let bytes = try byteCount(frames: Int(source.frameLength),
                                      bytesPerFrame: Int(source.format.streamDescription.pointee.mBytesPerFrame),
                                      sourceBytes: Int(original[index].mDataByteSize),
                                      destinationBytes: Int(destination[index].mDataByteSize))
            guard let from = original[index].mData, let to = destination[index].mData else { throw BridgeError.invalidPCM }
            memcpy(to, from, bytes)
        }
        return copy
    }
}
