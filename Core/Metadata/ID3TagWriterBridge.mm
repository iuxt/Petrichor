#include "ID3TagWriterBridge.h"

#include <taglib/apefile.h>
#include <taglib/aifffile.h>
#include <taglib/commentsframe.h>
#include <taglib/dsdifffile.h>
#include <taglib/dsffile.h>
#include <taglib/flacfile.h>
#include <taglib/id3v2header.h>
#include <taglib/id3v2tag.h>
#include <taglib/mpegfile.h>
#include <taglib/mpegproperties.h>
#include <taglib/mp4file.h>
#include <taglib/mpcfile.h>
#include <taglib/oggflacfile.h>
#include <taglib/opusfile.h>
#include <taglib/speexfile.h>
#include <taglib/textidentificationframe.h>
#include <taglib/tfilestream.h>
#include <taglib/trueaudiofile.h>
#include <taglib/vorbisfile.h>
#include <taglib/wavfile.h>
#include <taglib/wavpackfile.h>

#include <array>
#include <cstdio>
#include <exception>
#include <optional>
#include <stdexcept>
#include <string>

namespace {

using TagLib::ByteVector;
using TagLib::String;
using TagLib::ID3v2::CommentsFrame;
using TagLib::ID3v2::Tag;
using TagLib::ID3v2::TextIdentificationFrame;

constexpr size_t kFieldCount =
    static_cast<size_t>(PTID3MetadataFieldComment) + 1;

void setError(
    char *buffer,
    size_t capacity,
    const std::string &message
)
{
    if(buffer == nullptr || capacity == 0) {
        return;
    }
    std::snprintf(buffer, capacity, "%s", message.c_str());
}

bool hasAudioProperties(const TagLib::File &file)
{
    return file.isValid() && file.audioProperties() != nullptr;
}

template <typename FileType>
bool containerIsSupported(const char *path)
{
    TagLib::FileStream stream(path, true);
    return stream.isOpen() && FileType::isSupported(&stream);
}

PTID3ContainerKind probeContainer(const char *path)
{
    if(path == nullptr || path[0] == '\0') {
        return PTID3ContainerKindNone;
    }

    try {
        if(!containerIsSupported<TagLib::MPEG::File>(path)) {
            throw std::runtime_error("Not MPEG");
        }
        TagLib::MPEG::File file(
            path,
            true,
            TagLib::AudioProperties::Fast
        );
        const auto *properties = file.audioProperties();
        if(file.isValid() && properties != nullptr &&
           properties->layer() == 3 && !properties->isADTS()) {
            return PTID3ContainerKindMPEG;
        }
    } catch(const std::exception &) {
    }

    try {
        if(!containerIsSupported<TagLib::RIFF::WAV::File>(path)) {
            throw std::runtime_error("Not WAVE");
        }
        TagLib::RIFF::WAV::File file(
            path,
            true,
            TagLib::AudioProperties::Fast
        );
        if(hasAudioProperties(file)) {
            return PTID3ContainerKindWAVE;
        }
    } catch(const std::exception &) {
    }

    try {
        if(!containerIsSupported<TagLib::RIFF::AIFF::File>(path)) {
            throw std::runtime_error("Not AIFF");
        }
        TagLib::RIFF::AIFF::File file(
            path,
            true,
            TagLib::AudioProperties::Fast
        );
        if(hasAudioProperties(file)) {
            return PTID3ContainerKindAIFF;
        }
    } catch(const std::exception &) {
    }

    try {
        if(!containerIsSupported<TagLib::TrueAudio::File>(path)) {
            throw std::runtime_error("Not TrueAudio");
        }
        TagLib::TrueAudio::File file(
            path,
            true,
            TagLib::AudioProperties::Fast
        );
        if(hasAudioProperties(file)) {
            return PTID3ContainerKindTrueAudio;
        }
    } catch(const std::exception &) {
    }

    try {
        if(!containerIsSupported<TagLib::DSF::File>(path)) {
            throw std::runtime_error("Not DSF");
        }
        TagLib::DSF::File file(
            path,
            true,
            TagLib::AudioProperties::Fast
        );
        if(hasAudioProperties(file)) {
            return PTID3ContainerKindUnsafeID3Carrier;
        }
    } catch(const std::exception &) {
    }

    try {
        if(!containerIsSupported<TagLib::DSDIFF::File>(path)) {
            throw std::runtime_error("Not DSDIFF");
        }
        TagLib::DSDIFF::File file(
            path,
            true,
            TagLib::AudioProperties::Fast
        );
        if(hasAudioProperties(file)) {
            return PTID3ContainerKindUnsafeID3Carrier;
        }
    } catch(const std::exception &) {
    }

    try {
        if(!containerIsSupported<TagLib::FLAC::File>(path)) {
            throw std::runtime_error("Not FLAC");
        }
        TagLib::FLAC::File file(
            path,
            true,
            TagLib::AudioProperties::Fast
        );
        if(hasAudioProperties(file)) {
            return file.hasID3v2Tag()
                ? PTID3ContainerKindUnsafeID3Carrier
                : PTID3ContainerKindNativeMetadata;
        }
    } catch(const std::exception &) {
    }

    try {
        if(containerIsSupported<TagLib::MP4::File>(path)) {
            return PTID3ContainerKindNativeMetadata;
        }
    } catch(const std::exception &) {
    }
    try {
        if(containerIsSupported<TagLib::Ogg::Vorbis::File>(path)) {
            return PTID3ContainerKindNativeMetadata;
        }
    } catch(const std::exception &) {
    }
    try {
        if(containerIsSupported<TagLib::Ogg::FLAC::File>(path)) {
            return PTID3ContainerKindNativeMetadata;
        }
    } catch(const std::exception &) {
    }
    try {
        if(containerIsSupported<TagLib::Ogg::Opus::File>(path)) {
            return PTID3ContainerKindNativeMetadata;
        }
    } catch(const std::exception &) {
    }
    try {
        if(containerIsSupported<TagLib::Ogg::Speex::File>(path)) {
            return PTID3ContainerKindNativeMetadata;
        }
    } catch(const std::exception &) {
    }
    try {
        if(containerIsSupported<TagLib::APE::File>(path)) {
            return PTID3ContainerKindNativeMetadata;
        }
    } catch(const std::exception &) {
    }
    try {
        if(containerIsSupported<TagLib::MPC::File>(path)) {
            return PTID3ContainerKindNativeMetadata;
        }
    } catch(const std::exception &) {
    }
    try {
        if(containerIsSupported<TagLib::WavPack::File>(path)) {
            return PTID3ContainerKindNativeMetadata;
        }
    } catch(const std::exception &) {
    }

    return PTID3ContainerKindNone;
}

bool validField(PTID3MetadataField field)
{
    return field >= PTID3MetadataFieldTitle &&
           field <= PTID3MetadataFieldComment;
}

bool validateOperations(
    const PTID3MetadataOperation *operations,
    size_t operationCount,
    std::string &error
)
{
    if(operationCount > 0 && operations == nullptr) {
        error = "Metadata operations are missing.";
        return false;
    }

    std::array<bool, kFieldCount> seen {};
    for(size_t index = 0; index < operationCount; ++index) {
        const auto &operation = operations[index];
        if(!validField(operation.field)) {
            error = "A metadata operation has an invalid field.";
            return false;
        }
        if(operation.action != PTID3PatchActionSet &&
           operation.action != PTID3PatchActionRemove) {
            error = "A metadata operation has an invalid action.";
            return false;
        }
        if(operation.action == PTID3PatchActionSet &&
           operation.value == nullptr) {
            error = "A set metadata operation has no value.";
            return false;
        }

        const auto fieldIndex = static_cast<size_t>(operation.field);
        if(seen[fieldIndex]) {
            error = "A metadata field was supplied more than once.";
            return false;
        }
        seen[fieldIndex] = true;
    }
    return true;
}

const PTID3MetadataOperation *findOperation(
    PTID3MetadataField field,
    const PTID3MetadataOperation *operations,
    size_t operationCount
)
{
    for(size_t index = 0; index < operationCount; ++index) {
        if(operations[index].field == field) {
            return operations + index;
        }
    }
    return nullptr;
}

ByteVector frameIDForField(PTID3MetadataField field)
{
    switch(field) {
    case PTID3MetadataFieldTitle: return ByteVector("TIT2");
    case PTID3MetadataFieldArtist: return ByteVector("TPE1");
    case PTID3MetadataFieldAlbum: return ByteVector("TALB");
    case PTID3MetadataFieldAlbumArtist: return ByteVector("TPE2");
    case PTID3MetadataFieldComposer: return ByteVector("TCOM");
    case PTID3MetadataFieldGenre: return ByteVector("TCON");
    case PTID3MetadataFieldReleaseDate: return ByteVector("TDRC");
    case PTID3MetadataFieldBPM: return ByteVector("TBPM");
    default: return ByteVector();
    }
}

void replaceTextFrame(
    Tag *tag,
    const ByteVector &frameID,
    const PTID3MetadataOperation &operation
)
{
    tag->removeFrames(frameID);
    if(operation.action == PTID3PatchActionRemove) {
        return;
    }

    auto *frame = new TextIdentificationFrame(frameID, String::UTF8);
    frame->setText(String(operation.value, String::UTF8));
    tag->addFrame(frame);
}

struct NumberPair {
    std::optional<std::string> number;
    std::optional<std::string> total;
};

std::optional<std::string> nonempty(std::string value)
{
    if(value.empty()) {
        return std::nullopt;
    }
    return value;
}

NumberPair readNumberPair(Tag *tag, const ByteVector &frameID)
{
    const auto frames = tag->frameList(frameID);
    if(frames.isEmpty()) {
        return {};
    }

    const auto *frame =
        dynamic_cast<const TextIdentificationFrame *>(frames.front());
    if(frame == nullptr) {
        return {};
    }

    const std::string text = frame->toString().to8Bit(true);
    const auto slash = text.find('/');
    if(slash == std::string::npos) {
        return {nonempty(text), std::nullopt};
    }
    return {
        nonempty(text.substr(0, slash)),
        nonempty(text.substr(slash + 1))
    };
}

void applyNumberComponent(
    std::optional<std::string> &component,
    const PTID3MetadataOperation *operation
)
{
    if(operation == nullptr) {
        return;
    }
    if(operation->action == PTID3PatchActionRemove) {
        component = std::nullopt;
    } else {
        component = std::string(operation->value);
    }
}

void replaceNumberPair(
    Tag *tag,
    const ByteVector &frameID,
    const PTID3MetadataOperation *numberOperation,
    const PTID3MetadataOperation *totalOperation
)
{
    if(numberOperation == nullptr && totalOperation == nullptr) {
        return;
    }

    auto pair = readNumberPair(tag, frameID);
    applyNumberComponent(pair.number, numberOperation);
    applyNumberComponent(pair.total, totalOperation);
    tag->removeFrames(frameID);

    if(!pair.number.has_value() && !pair.total.has_value()) {
        return;
    }

    std::string value = pair.number.value_or("");
    if(pair.total.has_value()) {
        value += "/";
        value += *pair.total;
    }

    auto *frame = new TextIdentificationFrame(frameID, String::UTF8);
    frame->setText(String(value, String::UTF8));
    tag->addFrame(frame);
}

void replaceCompilation(
    Tag *tag,
    const PTID3MetadataOperation *operation
)
{
    if(operation == nullptr) {
        return;
    }

    const ByteVector frameID("TCMP");
    tag->removeFrames(frameID);
    if(operation->action == PTID3PatchActionRemove) {
        return;
    }

    auto *frame = new TextIdentificationFrame(frameID, String::UTF8);
    frame->setText(String("1", String::Latin1));
    tag->addFrame(frame);
}

void replaceComment(
    Tag *tag,
    const PTID3MetadataOperation *operation
)
{
    if(operation == nullptr) {
        return;
    }

    tag->removeFrames(ByteVector("COMM"));
    if(operation->action == PTID3PatchActionRemove) {
        return;
    }

    auto *frame = new CommentsFrame(String::UTF8);
    frame->setLanguage(ByteVector("eng"));
    frame->setDescription(String());
    frame->setText(String(operation->value, String::UTF8));
    tag->addFrame(frame);
}

void applyOperations(
    Tag *tag,
    const PTID3MetadataOperation *operations,
    size_t operationCount
)
{
    constexpr std::array<PTID3MetadataField, 8> textFields = {
        PTID3MetadataFieldTitle,
        PTID3MetadataFieldArtist,
        PTID3MetadataFieldAlbum,
        PTID3MetadataFieldAlbumArtist,
        PTID3MetadataFieldComposer,
        PTID3MetadataFieldGenre,
        PTID3MetadataFieldReleaseDate,
        PTID3MetadataFieldBPM
    };

    for(const auto field : textFields) {
        const auto *operation =
            findOperation(field, operations, operationCount);
        if(operation != nullptr) {
            replaceTextFrame(tag, frameIDForField(field), *operation);
        }
    }

    replaceNumberPair(
        tag,
        ByteVector("TRCK"),
        findOperation(
            PTID3MetadataFieldTrackNumber,
            operations,
            operationCount
        ),
        findOperation(
            PTID3MetadataFieldTrackTotal,
            operations,
            operationCount
        )
    );
    replaceNumberPair(
        tag,
        ByteVector("TPOS"),
        findOperation(
            PTID3MetadataFieldDiscNumber,
            operations,
            operationCount
        ),
        findOperation(
            PTID3MetadataFieldDiscTotal,
            operations,
            operationCount
        )
    );
    replaceCompilation(
        tag,
        findOperation(
            PTID3MetadataFieldCompilation,
            operations,
            operationCount
        )
    );
    replaceComment(
        tag,
        findOperation(
            PTID3MetadataFieldComment,
            operations,
            operationCount
        )
    );
}

TagLib::ID3v2::Version versionForTag(const Tag *tag)
{
    if(tag != nullptr && tag->header() != nullptr &&
       tag->header()->majorVersion() == 3) {
        return TagLib::ID3v2::v3;
    }
    return TagLib::ID3v2::v4;
}

bool writeMPEG(
    const char *path,
    const PTID3MetadataOperation *operations,
    size_t operationCount
)
{
    TagLib::MPEG::File file(path, true, TagLib::AudioProperties::Fast);
    auto *tag = file.ID3v2Tag(true);
    const auto version = versionForTag(tag);
    applyOperations(tag, operations, operationCount);
    return file.save(
        TagLib::MPEG::File::ID3v2,
        TagLib::File::StripNone,
        version,
        TagLib::File::DoNotDuplicate
    );
}

bool writeWAVE(
    const char *path,
    const PTID3MetadataOperation *operations,
    size_t operationCount
)
{
    TagLib::RIFF::WAV::File file(
        path,
        true,
        TagLib::AudioProperties::Fast
    );
    auto *tag = file.ID3v2Tag();
    const auto version = versionForTag(tag);
    applyOperations(tag, operations, operationCount);
    return file.save(
        TagLib::RIFF::WAV::File::ID3v2,
        TagLib::File::StripNone,
        version
    );
}

bool writeAIFF(
    const char *path,
    const PTID3MetadataOperation *operations,
    size_t operationCount
)
{
    TagLib::RIFF::AIFF::File file(
        path,
        true,
        TagLib::AudioProperties::Fast
    );
    auto *tag = file.tag();
    const auto version = versionForTag(tag);
    applyOperations(tag, operations, operationCount);
    return file.save(version);
}

bool writeTrueAudio(
    const char *path,
    const PTID3MetadataOperation *operations,
    size_t operationCount
)
{
    TagLib::TrueAudio::File file(
        path,
        true,
        TagLib::AudioProperties::Fast
    );
    auto *tag = file.ID3v2Tag(true);
    applyOperations(tag, operations, operationCount);
    return file.save();
}

} // namespace

PTID3ContainerKind PTID3ProbeContainerAtPath(const char *path)
{
    return probeContainer(path);
}

bool PTID3WriteMetadataAtPath(
    const char *path,
    const PTID3MetadataOperation *operations,
    size_t operationCount,
    char *errorBuffer,
    size_t errorBufferCapacity
)
{
    if(errorBuffer != nullptr && errorBufferCapacity > 0) {
        errorBuffer[0] = '\0';
    }

    std::string validationError;
    if(path == nullptr || path[0] == '\0') {
        setError(errorBuffer, errorBufferCapacity, "The file path is missing.");
        return false;
    }
    if(!validateOperations(operations, operationCount, validationError)) {
        setError(errorBuffer, errorBufferCapacity, validationError);
        return false;
    }

    try {
        bool saved = false;
        switch(probeContainer(path)) {
        case PTID3ContainerKindMPEG:
            saved = writeMPEG(path, operations, operationCount);
            break;
        case PTID3ContainerKindWAVE:
            saved = writeWAVE(path, operations, operationCount);
            break;
        case PTID3ContainerKindAIFF:
            saved = writeAIFF(path, operations, operationCount);
            break;
        case PTID3ContainerKindTrueAudio:
            saved = writeTrueAudio(path, operations, operationCount);
            break;
        case PTID3ContainerKindUnsafeID3Carrier:
            setError(
                errorBuffer,
                errorBufferCapacity,
                "This ID3 container does not have a verified selective writer."
            );
            return false;
        case PTID3ContainerKindNativeMetadata:
        case PTID3ContainerKindNone:
            setError(
                errorBuffer,
                errorBufferCapacity,
                "The file is not a supported ID3 container."
            );
            return false;
        }

        if(!saved) {
            setError(
                errorBuffer,
                errorBufferCapacity,
                "TagLib could not save the ID3v2 tag."
            );
        }
        return saved;
    } catch(const std::exception &exception) {
        setError(errorBuffer, errorBufferCapacity, exception.what());
        return false;
    } catch(...) {
        setError(
            errorBuffer,
            errorBufferCapacity,
            "An unknown ID3 write error occurred."
        );
        return false;
    }
}
