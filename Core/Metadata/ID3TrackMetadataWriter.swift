import Darwin
import Foundation

enum ID3TrackMetadataContainer: Equatable, Sendable {
    case none
    case mpeg
    case wave
    case aiff
    case trueAudio
    case nativeMetadata
    case unsafeID3Carrier

    var supportsSelectiveWriting: Bool {
        switch self {
        case .mpeg, .wave, .aiff, .trueAudio:
            return true
        case .none, .nativeMetadata, .unsafeID3Carrier:
            return false
        }
    }
}

enum ID3TrackMetadataWriter {
    private struct Operation {
        let field: PTID3MetadataField
        let action: PTID3PatchAction
        let value: String?
    }

    private struct WriteError: LocalizedError {
        let detail: String

        var errorDescription: String? {
            detail
        }
    }

    static func probe(_ url: URL) -> ID3TrackMetadataContainer {
        let kind = url.path.withCString(PTID3ProbeContainerAtPath)
        switch kind.rawValue {
        case PTID3ContainerKindMPEG.rawValue:
            return .mpeg
        case PTID3ContainerKindWAVE.rawValue:
            return .wave
        case PTID3ContainerKindAIFF.rawValue:
            return .aiff
        case PTID3ContainerKindTrueAudio.rawValue:
            return .trueAudio
        case PTID3ContainerKindUnsafeID3Carrier.rawValue:
            return .unsafeID3Carrier
        case PTID3ContainerKindNativeMetadata.rawValue:
            return .nativeMetadata
        default:
            return .none
        }
    }

    static func write(_ patch: TrackMetadataPatch, to url: URL) throws {
        let pending = operations(for: patch)
        guard !pending.isEmpty else { return }

        let allocatedValues = pending.map { operation in
            operation.value.map(strdup)
        }
        defer {
            for value in allocatedValues {
                free(value)
            }
        }

        var operations = zip(pending, allocatedValues).map {
            PTID3MetadataOperation(
                field: $0.0.field,
                action: $0.0.action,
                value: $0.1.map(UnsafePointer.init)
            )
        }
        var errorBuffer = [CChar](repeating: 0, count: 1_024)

        let didWrite = url.path.withCString { path in
            operations.withUnsafeMutableBufferPointer { operationBuffer in
                errorBuffer.withUnsafeMutableBufferPointer { error in
                    PTID3WriteMetadataAtPath(
                        path,
                        operationBuffer.baseAddress,
                        operationBuffer.count,
                        error.baseAddress,
                        error.count
                    )
                }
            }
        }
        guard didWrite else {
            let detail = errorBuffer.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress,
                      baseAddress.pointee != 0 else {
                    return "TagLib could not save the ID3v2 tag."
                }
                return String(cString: baseAddress)
            }
            throw WriteError(detail: detail)
        }
    }

    private static func operations(
        for patch: TrackMetadataPatch
    ) -> [Operation] {
        var result: [Operation] = []
        append(patch.title, field: .title, to: &result)
        append(patch.artist, field: .artist, to: &result)
        append(patch.album, field: .album, to: &result)
        append(patch.albumArtist, field: .albumArtist, to: &result)
        append(patch.composer, field: .composer, to: &result)
        append(patch.genre, field: .genre, to: &result)
        append(patch.releaseDate, field: .releaseDate, to: &result)
        append(patch.trackNumber, field: .trackNumber, to: &result)
        append(patch.trackTotal, field: .trackTotal, to: &result)
        append(patch.discNumber, field: .discNumber, to: &result)
        append(patch.discTotal, field: .discTotal, to: &result)
        append(patch.bpm, field: .bpm, to: &result)
        appendCompilation(patch.compilation, to: &result)
        append(patch.comment, field: .comment, to: &result)
        return result
    }

    private static func append(
        _ patch: MetadataPatchValue<String>,
        field: PTID3MetadataField,
        to operations: inout [Operation]
    ) {
        switch patch {
        case .unchanged:
            break
        case .set(let value):
            operations.append(
                Operation(field: field, action: .set, value: value)
            )
        case .remove:
            operations.append(
                Operation(field: field, action: .remove, value: nil)
            )
        }
    }

    private static func append(
        _ patch: MetadataPatchValue<Int>,
        field: PTID3MetadataField,
        to operations: inout [Operation]
    ) {
        switch patch {
        case .unchanged:
            break
        case .set(let value):
            operations.append(
                Operation(
                    field: field,
                    action: .set,
                    value: String(value)
                )
            )
        case .remove:
            operations.append(
                Operation(field: field, action: .remove, value: nil)
            )
        }
    }

    private static func appendCompilation(
        _ patch: MetadataPatchValue<Bool>,
        to operations: inout [Operation]
    ) {
        switch patch {
        case .unchanged:
            break
        case .set(true):
            operations.append(
                Operation(field: .compilation, action: .set, value: "1")
            )
        case .set(false), .remove:
            operations.append(
                Operation(field: .compilation, action: .remove, value: nil)
            )
        }
    }
}
