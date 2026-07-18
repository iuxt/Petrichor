#ifndef ID3TagWriterBridge_h
#define ID3TagWriterBridge_h

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum PTID3ContainerKind {
    PTID3ContainerKindNone = 0,
    PTID3ContainerKindMPEG = 1,
    PTID3ContainerKindWAVE = 2,
    PTID3ContainerKindAIFF = 3,
    PTID3ContainerKindTrueAudio = 4,
    PTID3ContainerKindUnsafeID3Carrier = 5,
    PTID3ContainerKindNativeMetadata = 6
} PTID3ContainerKind;

typedef enum PTID3MetadataField {
    PTID3MetadataFieldTitle = 0,
    PTID3MetadataFieldArtist = 1,
    PTID3MetadataFieldAlbum = 2,
    PTID3MetadataFieldAlbumArtist = 3,
    PTID3MetadataFieldComposer = 4,
    PTID3MetadataFieldGenre = 5,
    PTID3MetadataFieldReleaseDate = 6,
    PTID3MetadataFieldTrackNumber = 7,
    PTID3MetadataFieldTrackTotal = 8,
    PTID3MetadataFieldDiscNumber = 9,
    PTID3MetadataFieldDiscTotal = 10,
    PTID3MetadataFieldBPM = 11,
    PTID3MetadataFieldCompilation = 12,
    PTID3MetadataFieldComment = 13
} PTID3MetadataField;

typedef enum PTID3PatchAction {
    PTID3PatchActionSet = 1,
    PTID3PatchActionRemove = 2
} PTID3PatchAction;

typedef struct PTID3MetadataOperation {
    PTID3MetadataField field;
    PTID3PatchAction action;
    const char *value;
} PTID3MetadataOperation;

PTID3ContainerKind PTID3ProbeContainerAtPath(const char *path);

bool PTID3WriteMetadataAtPath(
    const char *path,
    const PTID3MetadataOperation *operations,
    size_t operationCount,
    char *errorBuffer,
    size_t errorBufferCapacity
);

#ifdef __cplusplus
}
#endif

#endif
