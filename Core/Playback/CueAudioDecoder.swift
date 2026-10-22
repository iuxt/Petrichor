import AVFoundation
import SFBAudioEngine

/// Builds a decoder with its own seek origin and EOF for a virtual CUE track.
enum CueAudioDecoder {
    static func make(segment: CueTrackSegment) throws -> AudioRegionDecoder {
        let decoder = try AudioDecoder(url: segment.sourceURL)
        try decoder.open()
        let rate = decoder.processingFormat.sampleRate
        guard rate.isFinite, rate > 0,
              segment.start.isFinite, segment.end.isFinite,
              segment.start >= 0, segment.end > segment.start,
              segment.end * rate < Double(Int64.max) else { throw AudioPlayerError.invalidFormat }
        let startFrame = AVAudioFramePosition((segment.start * rate).rounded())
        let endFrame = min(decoder.length, AVAudioFramePosition((segment.end * rate).rounded()))
        guard endFrame > startFrame else { throw AudioPlayerError.invalidFormat }
        return try AudioRegionDecoder(decoder: decoder, startFrame: startFrame,
                                      frameLength: endFrame - startFrame)
    }
}
