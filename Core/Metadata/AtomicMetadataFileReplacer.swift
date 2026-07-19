import Darwin
import Foundation

/// Applies a metadata mutation to a same-directory copy and then swaps that
/// verified copy over the source path with one atomic rename. Existing audio
/// decoders keep reading the old inode while new readers see the completed file,
/// so no tag writer ever shares a mutable file with playback or artwork reads.
enum AtomicMetadataFileReplacer {
    enum ReplacementSupport: Equatable {
        case supported
        case multipleHardLinks
        case unsupportedVolume
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let userID: UInt32
        let groupID: UInt32
        let flags: UInt32
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let statusChangeSeconds: Int
        let statusChangeNanoseconds: Int
        let linkCount: UInt64

        func matchesDisplacedFile(_ other: Self) -> Bool {
            device == other.device &&
                inode == other.inode &&
                size == other.size &&
                mode == other.mode &&
                userID == other.userID &&
                groupID == other.groupID &&
                flags == other.flags &&
                modificationSeconds == other.modificationSeconds &&
                modificationNanoseconds == other.modificationNanoseconds &&
                linkCount == other.linkCount
        }

        func identifiesSameFile(as other: Self) -> Bool {
            device == other.device && inode == other.inode
        }
    }

    private struct SwapSnapshot {
        let temporaryIdentity: FileIdentity
        let sourceIdentity: FileIdentity
    }

    static func replacementSupport(
        for originalURL: URL
    ) -> ReplacementSupport {
        let sourceURL = originalURL.resolvingSymlinksInPath()
        guard let identity = try? fileIdentity(
            at: sourceURL
        ) else {
            return .unsupportedVolume
        }
        guard identity.linkCount == 1 else {
            return .multipleHardLinks
        }
        let values = try? sourceURL.resourceValues(
            forKeys: [.volumeSupportsSwapRenamingKey]
        )
        guard values?.volumeSupportsSwapRenaming == true else {
            return .unsupportedVolume
        }
        return .supported
    }

    static func replace(
        _ originalURL: URL,
        mutate: (URL) throws -> Void,
        verify: (URL) throws -> Void
    ) throws {
        let sourceURL = originalURL.resolvingSymlinksInPath()
        try replacePrepared(
            sourceURL,
            accessedThrough: originalURL,
            mutate: mutate,
            verify: verify
        )
    }

    private static func replacePrepared(
        _ sourceURL: URL,
        accessedThrough originalURL: URL,
        mutate: (URL) throws -> Void,
        verify: (URL) throws -> Void
    ) throws {
        let originalIdentity = try fileIdentity(at: sourceURL)
        guard originalIdentity.linkCount == 1 else {
            throw posixError(code: EMLINK, url: sourceURL)
        }
        guard replacementSupport(for: sourceURL) == .supported else {
            throw posixError(code: ENOTSUP, url: sourceURL)
        }

        let temporaryURL = makeTemporaryURL(for: sourceURL)
        let fileManager = FileManager.default
        var deferredCleanupIdentity: FileIdentity?

        defer {
            if let deferredCleanupIdentity,
               (try? fileIdentity(at: temporaryURL)) ==
                    deferredCleanupIdentity {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        deferredCleanupIdentity = try fileIdentity(at: temporaryURL)
        do {
            try mutate(temporaryURL)
        } catch {
            if let currentIdentity = try? fileIdentity(at: temporaryURL),
               let expectedCleanupIdentity = deferredCleanupIdentity,
               currentIdentity.identifiesSameFile(
                    as: expectedCleanupIdentity
               ) {
                deferredCleanupIdentity = currentIdentity
            } else {
                deferredCleanupIdentity = nil
            }
            throw error
        }
        deferredCleanupIdentity = try fileIdentity(at: temporaryURL)
        let candidateDescriptor = try openValidatedDescriptor(
            at: temporaryURL,
            flags: O_RDONLY
        )
        defer { Darwin.close(candidateDescriptor) }
        try synchronizeDescriptor(candidateDescriptor, url: temporaryURL)
        let candidateIdentity = try verifyPinnedCandidate(
            at: temporaryURL,
            descriptor: candidateDescriptor,
            verify: verify
        )
        deferredCleanupIdentity = candidateIdentity

        guard resolves(originalURL, to: sourceURL) else {
            throw posixError(code: EBUSY, url: originalURL)
        }
        let currentIdentity = try fileIdentity(at: sourceURL)
        guard currentIdentity == originalIdentity else {
            throw posixError(code: EBUSY, url: sourceURL)
        }
        guard try fileIdentity(at: temporaryURL) == candidateIdentity,
              try fileIdentity(
                descriptor: candidateDescriptor,
                url: temporaryURL
              ) == candidateIdentity else {
            throw posixError(code: EBUSY, url: temporaryURL)
        }

        try atomicallySwap(temporaryURL, with: sourceURL)
        deferredCleanupIdentity = nil

        var swapSnapshot: SwapSnapshot?
        var rollbackCandidateIdentity: FileIdentity?
        var displacedCleanupIdentity: FileIdentity?
        do {
            let observedSwap = SwapSnapshot(
                temporaryIdentity: try fileIdentity(at: temporaryURL),
                sourceIdentity: try fileIdentity(at: sourceURL)
            )
            swapSnapshot = observedSwap
            let displacedMatches = originalIdentity.matchesDisplacedFile(
                observedSwap.temporaryIdentity
            )
            let candidateMatches = candidateIdentity.matchesDisplacedFile(
                observedSwap.sourceIdentity
            )
            guard candidateMatches else {
                // The public source contains a modified or substituted
                // candidate. Preserve it and the displaced file; rolling back
                // would move and later delete another writer's update.
                swapSnapshot = nil
                throw posixError(code: EBUSY, url: sourceURL)
            }
            rollbackCandidateIdentity = observedSwap.sourceIdentity
            guard displacedMatches,
                  try fileIdentity(
                    descriptor: candidateDescriptor,
                    url: sourceURL
                  ) == observedSwap.sourceIdentity else {
                throw posixError(code: EBUSY, url: sourceURL)
            }
            guard resolves(originalURL, to: sourceURL) else {
                throw posixError(code: EBUSY, url: originalURL)
            }
            try copyMetadataAndSynchronize(
                from: temporaryURL,
                expectedSource: originalIdentity,
                to: sourceURL,
                expectedTarget: candidateIdentity
            )
            let postMetadataCandidateIdentity = try fileIdentity(
                descriptor: candidateDescriptor,
                url: sourceURL
            )
            guard try fileIdentity(at: sourceURL) ==
                    postMetadataCandidateIdentity else {
                swapSnapshot = nil
                throw posixError(code: EBUSY, url: sourceURL)
            }
            rollbackCandidateIdentity = postMetadataCandidateIdentity
            guard try fileIdentity(at: temporaryURL) ==
                    observedSwap.temporaryIdentity,
                  resolves(originalURL, to: sourceURL) else {
                throw posixError(code: EBUSY, url: sourceURL)
            }
            do {
                rollbackCandidateIdentity = try verifyPinnedCandidate(
                    at: sourceURL,
                    descriptor: candidateDescriptor,
                    verify: verify
                )
            } catch {
                // Initial verification already succeeded and metadata copying
                // does not touch the data fork. A post-swap verification
                // failure may therefore be an external public-path write.
                // Preserve both inodes instead of deleting that writer's data.
                swapSnapshot = nil
                throw error
            }
            guard try fileIdentity(at: temporaryURL) ==
                    observedSwap.temporaryIdentity else {
                throw posixError(code: EBUSY, url: temporaryURL)
            }
            displacedCleanupIdentity = observedSwap.temporaryIdentity
        } catch let replacementError {
            guard let swapSnapshot,
                  let rollbackCandidateIdentity,
                  candidateStillOwned(
                    at: sourceURL,
                    descriptor: candidateDescriptor,
                    expectedIdentity: rollbackCandidateIdentity
                  ) else {
                // If either path cannot be inspected, no path-based recovery
                // can prove that it would leave an external replacement alone.
                throw replacementError
            }
            do {
                deferredCleanupIdentity = try rollbackSwap(
                    temporaryURL: temporaryURL,
                    sourceURL: sourceURL,
                    snapshot: swapSnapshot,
                    expectedCandidateIdentity: rollbackCandidateIdentity
                )
            } catch let rollbackError {
                throw rollbackError
            }
            throw replacementError
        }

        synchronizeDirectoryBestEffort(
            at: sourceURL.deletingLastPathComponent()
        )
        // The replacement is already committed. A cleanup failure must not be
        // reported as a failed tag save, because callers would then keep stale
        // database/cache state even though the audio path contains new tags.
        if let displacedCleanupIdentity,
           (try? fileIdentity(at: temporaryURL)) ==
                displacedCleanupIdentity {
            try? fileManager.removeItem(at: temporaryURL)
        }
        synchronizeDirectoryBestEffort(
            at: sourceURL.deletingLastPathComponent()
        )
    }

    /// Restores the two exact path occupants observed immediately after the
    /// exchange. This also recovers safely when a different process replaced
    /// the source or candidate in the precheck-to-swap window.
    private static func rollbackSwap(
        temporaryURL: URL,
        sourceURL: URL,
        snapshot: SwapSnapshot,
        expectedCandidateIdentity: FileIdentity
    ) throws -> FileIdentity {
        guard swapPathsStillIdentify(
            temporaryURL: temporaryURL,
            sourceURL: sourceURL,
            expectedTemporary: snapshot.temporaryIdentity,
            expectedSource: snapshot.sourceIdentity
        ) else {
            // Preserve both paths if another process changed either occupant.
            throw posixError(code: EBUSY, url: sourceURL)
        }

        try atomicallySwap(temporaryURL, with: sourceURL)
        let restoredSource = try fileIdentity(at: sourceURL)
        let restoredTemporary = try fileIdentity(at: temporaryURL)
        guard restoredSource.identifiesSameFile(
            as: snapshot.temporaryIdentity
        ),
        expectedCandidateIdentity.matchesDisplacedFile(
            restoredTemporary
        ) else {
            throw posixError(code: EBUSY, url: sourceURL)
        }
        synchronizeDirectoryBestEffort(
            at: sourceURL.deletingLastPathComponent()
        )

        // The defer removes only this exact, app-owned candidate state.
        return restoredTemporary
    }

    private static func candidateStillOwned(
        at url: URL,
        descriptor: Int32,
        expectedIdentity: FileIdentity
    ) -> Bool {
        guard let descriptorIdentity = try? fileIdentity(
            descriptor: descriptor,
            url: url
        ),
        let pathIdentity = try? fileIdentity(at: url) else {
            return false
        }
        return descriptorIdentity == expectedIdentity &&
            pathIdentity == expectedIdentity
    }

    private static func swapPathsStillIdentify(
        temporaryURL: URL,
        sourceURL: URL,
        expectedTemporary: FileIdentity,
        expectedSource: FileIdentity
    ) -> Bool {
        guard let currentTemporary = try? fileIdentity(at: temporaryURL),
              let currentSource = try? fileIdentity(at: sourceURL) else {
            return false
        }
        return currentTemporary.identifiesSameFile(as: expectedTemporary) &&
            currentSource.identifiesSameFile(as: expectedSource)
    }

    private static func makeTemporaryURL(for sourceURL: URL) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let pathExtension = sourceURL.pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let temporaryName =
            ".petrichor-metadata-\(UUID().uuidString)\(suffix)"
        return directory.appendingPathComponent(
            temporaryName,
            isDirectory: false
        )
    }

    private static func resolves(_ originalURL: URL, to sourceURL: URL) -> Bool {
        originalURL.resolvingSymlinksInPath().standardizedFileURL ==
            sourceURL.standardizedFileURL
    }

    private static func atomicallySwap(
        _ temporaryURL: URL,
        with sourceURL: URL
    ) throws {
        let result = temporaryURL.withUnsafeFileSystemRepresentation {
            temporaryPath in
            sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
                guard let temporaryPath, let sourcePath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return Darwin.renamex_np(
                    temporaryPath,
                    sourcePath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw posixError(
                code: errno,
                url: sourceURL
            )
        }
    }

    private static func fileIdentity(at url: URL) throws -> FileIdentity {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.lstat(path, &information)
        }
        guard result == 0 else {
            throw posixError(code: errno, url: url)
        }
        return fileIdentity(from: information)
    }

    private static func fileIdentity(from information: stat) -> FileIdentity {
        return FileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: information.st_size,
            mode: information.st_mode,
            userID: information.st_uid,
            groupID: information.st_gid,
            flags: information.st_flags,
            modificationSeconds: information.st_mtimespec.tv_sec,
            modificationNanoseconds: information.st_mtimespec.tv_nsec,
            statusChangeSeconds: information.st_ctimespec.tv_sec,
            statusChangeNanoseconds: information.st_ctimespec.tv_nsec,
            linkCount: UInt64(information.st_nlink)
        )
    }

    private static func copyMetadataAndSynchronize(
        from sourceURL: URL,
        expectedSource: FileIdentity,
        to targetURL: URL,
        expectedTarget: FileIdentity
    ) throws {
        let sourceDescriptor = try openValidatedDescriptor(
            at: sourceURL,
            flags: O_RDONLY,
            expectedIdentity: expectedSource
        )
        defer { Darwin.close(sourceDescriptor) }
        let targetDescriptor = try openValidatedDescriptor(
            at: targetURL,
            flags: O_WRONLY,
            expectedIdentity: expectedTarget
        )
        defer { Darwin.close(targetDescriptor) }

        guard Darwin.fcopyfile(
            sourceDescriptor,
            targetDescriptor,
            nil,
            copyfile_flags_t(COPYFILE_METADATA)
        ) == 0 else {
            throw posixError(code: errno, url: targetURL)
        }
        try synchronizeDescriptor(targetDescriptor, url: targetURL)
    }

    private static func openValidatedDescriptor(
        at url: URL,
        flags: Int32,
        expectedIdentity: FileIdentity? = nil
    ) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.open(path, flags | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw posixError(code: errno, url: url)
        }

        do {
            let openedIdentity = try fileIdentity(
                descriptor: descriptor,
                url: url
            )
            if let expectedIdentity {
                guard openedIdentity.identifiesSameFile(
                    as: expectedIdentity
                ) else {
                    throw posixError(code: EBUSY, url: url)
                }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Runs domain verification while the candidate inode is pinned open and
    /// rejects both pathname substitution and in-place mutation across the
    /// verification boundary.
    private static func verifyPinnedCandidate(
        at url: URL,
        descriptor: Int32,
        verify: (URL) throws -> Void
    ) throws -> FileIdentity {
        let identityBeforeVerification = try fileIdentity(
            descriptor: descriptor,
            url: url
        )
        guard try fileIdentity(at: url) == identityBeforeVerification else {
            throw posixError(code: EBUSY, url: url)
        }

        try verify(url)

        let identityAfterVerification = try fileIdentity(
            descriptor: descriptor,
            url: url
        )
        guard identityAfterVerification == identityBeforeVerification,
              try fileIdentity(at: url) == identityAfterVerification else {
            throw posixError(code: EBUSY, url: url)
        }
        return identityAfterVerification
    }

    private static func synchronizeFile(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw posixError(code: errno, url: url)
        }
        defer { Darwin.close(descriptor) }

        try synchronizeDescriptor(descriptor, url: url)
    }

    private static func synchronizeDescriptor(
        _ descriptor: Int32,
        url: URL
    ) throws {
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(code: errno, url: url)
        }
    }

    private static func fileIdentity(
        descriptor: Int32,
        url: URL
    ) throws -> FileIdentity {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw posixError(code: errno, url: url)
        }
        return fileIdentity(from: information)
    }

    private static func synchronizeDirectoryBestEffort(at url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fsync(descriptor)
    }

    private static func posixError(code: Int32, url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey:
                    String(cString: strerror(code))
            ]
        )
    }
}
