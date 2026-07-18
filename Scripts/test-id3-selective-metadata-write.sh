#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_HEADER="$ROOT_DIR/Core/Metadata/ID3TagWriterBridge.h"
BRIDGE_IMPL="$ROOT_DIR/Core/Metadata/ID3TagWriterBridge.mm"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"

if [[ ! -f "$BRIDGE_HEADER" || ! -f "$BRIDGE_IMPL" ]]; then
    printf '%s\n' 'Production selective ID3 bridge is missing.' >&2
    exit 1
fi

if [[ ! -x "$FFMPEG" ]]; then
    printf '%s\n' "ffmpeg is required at $FFMPEG" >&2
    exit 1
fi

TAGLIB_SOURCE="${CXXTAGLIB_SOURCE_DIR:-}"
TAGLIB_OBJECT="${CXXTAGLIB_OBJECT:-}"

if [[ -z "$TAGLIB_SOURCE" ]]; then
    for candidate in \
        /tmp/PetrichorID3DerivedData/SourcePackages/checkouts/CXXTagLib \
        /tmp/PetrichorMetadataEditorDerivedDataFinal/SourcePackages/checkouts/CXXTagLib
    do
        if [[ -d "$candidate" ]]; then
            TAGLIB_SOURCE="$candidate"
            break
        fi
    done
fi

if [[ -z "$TAGLIB_OBJECT" ]]; then
    for candidate in \
        /tmp/PetrichorID3DerivedData/Build/Products/Debug/taglib.o \
        /tmp/PetrichorMetadataEditorDerivedDataFinal/Build/Products/Debug/taglib.o
    do
        if [[ -f "$candidate" ]]; then
            TAGLIB_OBJECT="$candidate"
            break
        fi
    done
fi

if [[ ! -d "$TAGLIB_SOURCE" || ! -f "$TAGLIB_OBJECT" ]]; then
    printf '%s\n' \
        'Build the Debug app target first, or set CXXTAGLIB_SOURCE_DIR and CXXTAGLIB_OBJECT.' >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-id3-selective.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

"$FFMPEG" -hide_banner -loglevel error -f lavfi \
    -i 'anullsrc=r=44100:cl=stereo' -t 0.2 -codec:a libmp3lame \
    "$TMP_DIR/sample.mp3"
"$FFMPEG" -hide_banner -loglevel error -f lavfi \
    -i 'anullsrc=r=44100:cl=stereo' -t 0.2 -codec:a pcm_s16le \
    "$TMP_DIR/sample.wav"
"$FFMPEG" -hide_banner -loglevel error -f lavfi \
    -i 'anullsrc=r=44100:cl=stereo' -t 0.2 -codec:a pcm_s16be \
    "$TMP_DIR/sample.aiff"
"$FFMPEG" -hide_banner -loglevel error -f lavfi \
    -i 'anullsrc=r=44100:cl=stereo' -t 0.2 -codec:a tta \
    "$TMP_DIR/sample.tta"
"$FFMPEG" -hide_banner -loglevel error -f lavfi \
    -i 'anullsrc=r=44100:cl=stereo' -t 0.2 -codec:a flac \
    "$TMP_DIR/not-an-mp3.flac"

cp "$TMP_DIR/sample.mp3" "$TMP_DIR/misnamed-mpeg.flac"
cp "$TMP_DIR/not-an-mp3.flac" "$TMP_DIR/renamed-flac.mp3"
printf 'ajkg\002shorten-signature-fixture' >"$TMP_DIR/shorten-signature.shn"

SHORTEN_PATHS=()
for extension in mp3 m4a flac wav aiff aif ogg oga opus spx ape mpc wv tta
do
    path="$TMP_DIR/renamed-shorten.$extension"
    cp "$TMP_DIR/shorten-signature.shn" "$path"
    SHORTEN_PATHS+=("$path")
done

HARNESS="$TMP_DIR/id3_selective_harness.mm"
cat >"$HARNESS" <<'HARNESS_EOF'
#include "ID3TagWriterBridge.h"

#include <taglib/aifffile.h>
#include <taglib/attachedpictureframe.h>
#include <taglib/id3v2tag.h>
#include <taglib/mpegfile.h>
#include <taglib/popularimeterframe.h>
#include <taglib/privateframe.h>
#include <taglib/textidentificationframe.h>
#include <taglib/trueaudiofile.h>
#include <taglib/uniquefileidentifierframe.h>
#include <taglib/unsynchronizedlyricsframe.h>
#include <taglib/wavfile.h>

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

using TagLib::ByteVector;
using TagLib::String;
using TagLib::StringList;
using TagLib::ID3v2::AttachedPictureFrame;
using TagLib::ID3v2::Frame;
using TagLib::ID3v2::PopularimeterFrame;
using TagLib::ID3v2::PrivateFrame;
using TagLib::ID3v2::Tag;
using TagLib::ID3v2::TextIdentificationFrame;
using TagLib::ID3v2::UniqueFileIdentifierFrame;
using TagLib::ID3v2::UnsynchronizedLyricsFrame;
using TagLib::ID3v2::UserTextIdentificationFrame;

[[noreturn]] static void fail(const std::string &message)
{
    std::cerr << message << '\n';
    std::exit(1);
}

static void require(bool condition, const std::string &message)
{
    if(!condition) {
        fail(message);
    }
}

static ByteVector bytes(const char *value)
{
    return ByteVector(value, static_cast<unsigned int>(std::strlen(value)));
}

static TextIdentificationFrame *textFrame(
    const char *id,
    const StringList &values
)
{
    auto *frame = new TextIdentificationFrame(ByteVector(id), String::UTF8);
    frame->setText(values);
    return frame;
}

static TextIdentificationFrame *textFrame(const char *id, const char *value)
{
    StringList values;
    values.append(String(value, String::UTF8));
    return textFrame(id, values);
}

static void seedFrames(Tag *tag)
{
    require(tag != nullptr, "ID3v2 tag is unavailable while seeding");

    for(const char *id : {"TIT2", "TPE1", "TDRC", "TCMP", "POPM", "USLT",
                          "APIC", "TXXX", "PRIV", "UFID"}) {
        tag->removeFrames(ByteVector(id));
    }

    tag->addFrame(textFrame("TIT2", "Before"));
    StringList artists;
    artists.append(String("Artist One", String::UTF8));
    artists.append(String("Artist Two", String::UTF8));
    tag->addFrame(textFrame("TPE1", artists));
    tag->addFrame(textFrame("TDRC", "1999"));
    tag->addFrame(textFrame("TCMP", "1"));

    auto *popmOne = new PopularimeterFrame();
    popmOne->setEmail(String("first@example.test", String::UTF8));
    popmOne->setRating(211);
    popmOne->setCounter(12345);
    tag->addFrame(popmOne);

    auto *popmTwo = new PopularimeterFrame();
    popmTwo->setEmail(String("second@example.test", String::UTF8));
    popmTwo->setRating(77);
    popmTwo->setCounter(9876);
    tag->addFrame(popmTwo);

    auto *lyricsOne = new UnsynchronizedLyricsFrame(String::UTF8);
    lyricsOne->setLanguage(bytes("eng"));
    lyricsOne->setDescription(String("original", String::UTF8));
    lyricsOne->setText(String("First preserved lyric", String::UTF8));
    tag->addFrame(lyricsOne);

    auto *lyricsTwo = new UnsynchronizedLyricsFrame(String::UTF8);
    lyricsTwo->setLanguage(bytes("jpn"));
    lyricsTwo->setDescription(String("translation", String::UTF8));
    lyricsTwo->setText(String("Second preserved lyric", String::UTF8));
    tag->addFrame(lyricsTwo);

    auto *front = new AttachedPictureFrame();
    front->setTextEncoding(String::UTF8);
    front->setMimeType(String("image/png", String::UTF8));
    front->setType(AttachedPictureFrame::FrontCover);
    front->setDescription(String("front", String::UTF8));
    front->setPicture(bytes("front-picture-bytes"));
    tag->addFrame(front);

    auto *back = new AttachedPictureFrame();
    back->setTextEncoding(String::UTF8);
    back->setMimeType(String("image/jpeg", String::UTF8));
    back->setType(AttachedPictureFrame::BackCover);
    back->setDescription(String("back", String::UTF8));
    back->setPicture(bytes("back-picture-bytes"));
    tag->addFrame(back);

    auto *custom = new UserTextIdentificationFrame(String::UTF8);
    custom->setDescription(String("X-PETRICHOR-UNKNOWN", String::UTF8));
    StringList customValues;
    customValues.append(String("custom-one", String::UTF8));
    customValues.append(String("custom-two", String::UTF8));
    custom->setText(customValues);
    tag->addFrame(custom);

    auto *privateFrame = new PrivateFrame();
    privateFrame->setOwner(String("petrichor.example/private", String::UTF8));
    privateFrame->setData(bytes("private-binary-payload"));
    tag->addFrame(privateFrame);

    tag->addFrame(new UniqueFileIdentifierFrame(
        String("petrichor.example/owner", String::UTF8),
        bytes("stable-identifier")
    ));
}

using FrameSnapshot = std::vector<std::pair<std::string, std::string>>;

static FrameSnapshot preservedSnapshot(Tag *tag)
{
    require(tag != nullptr, "ID3v2 tag is unavailable while snapshotting");
    FrameSnapshot result;
    for(Frame *frame : tag->frameList()) {
        const ByteVector idBytes = frame->frameID();
        const std::string id(idBytes.data(), idBytes.size());
        if(id == "POPM" || id == "USLT" || id == "APIC" || id == "TXXX" ||
           id == "PRIV" || id == "UFID" || id == "TPE1") {
            const ByteVector rendered = frame->render();
            result.emplace_back(
                id,
                std::string(rendered.data(), rendered.size())
            );
        }
    }
    return result;
}

static std::string firstText(Tag *tag, const char *id)
{
    const auto frames = tag->frameList(ByteVector(id));
    require(!frames.isEmpty(), std::string("Missing frame ") + id);
    auto *frame = dynamic_cast<TextIdentificationFrame *>(frames.front());
    require(frame != nullptr, std::string("Unexpected frame type for ") + id);
    return frame->toString().to8Bit(true);
}

static void verifyFirstWrite(Tag *tag, const FrameSnapshot &before)
{
    require(
        preservedSnapshot(tag) == before,
        "Untouched advanced or multi-value frames changed"
    );
    require(firstText(tag, "TIT2") == "After", "TIT2 did not round-trip");
    require(
        firstText(tag, "TDRC") == "2024-02-29",
        "Full TDRC date did not round-trip exactly"
    );
    require(tag->frameList("TCMP").isEmpty(), "Compilation false left TCMP");
}

static void verifySecondWrite(Tag *tag)
{
    require(firstText(tag, "TDRC") == "2025", "Year-only TDRC changed");
    const auto compilation = tag->frameList("TCMP");
    require(compilation.size() == 1, "Compilation true did not write one TCMP");
    require(firstText(tag, "TCMP") == "1", "Compilation true was not TCMP=1");
}

template <typename Adapter>
static void exercise(const char *path, PTID3ContainerKind expected)
{
    const auto actual = PTID3ProbeContainerAtPath(path);
    require(
        actual == expected,
        std::string("Wrong content probe for ") + path +
            ": expected " + std::to_string(expected) +
            ", got " + std::to_string(actual)
    );

    {
        typename Adapter::File file(path, true, TagLib::AudioProperties::Fast);
        require(file.isValid(), std::string("Fixture is invalid: ") + path);
        seedFrames(Adapter::tag(file, true));
        require(Adapter::save(file), std::string("Could not seed ") + path);
    }

    FrameSnapshot before;
    {
        typename Adapter::File file(path, true, TagLib::AudioProperties::Fast);
        before = preservedSnapshot(Adapter::tag(file, false));
    }

    const PTID3MetadataOperation first[] = {
        {PTID3MetadataFieldTitle, PTID3PatchActionSet, "After"},
        {PTID3MetadataFieldReleaseDate, PTID3PatchActionSet, "2024-02-29"},
        {PTID3MetadataFieldCompilation, PTID3PatchActionRemove, nullptr}
    };
    char error[512] = {};
    require(
        PTID3WriteMetadataAtPath(path, first, 3, error, sizeof(error)),
        std::string("First selective write failed: ") + error
    );

    {
        typename Adapter::File file(path, true, TagLib::AudioProperties::Fast);
        verifyFirstWrite(Adapter::tag(file, false), before);
    }

    const PTID3MetadataOperation second[] = {
        {PTID3MetadataFieldReleaseDate, PTID3PatchActionSet, "2025"},
        {PTID3MetadataFieldCompilation, PTID3PatchActionSet, "1"}
    };
    require(
        PTID3WriteMetadataAtPath(path, second, 2, error, sizeof(error)),
        std::string("Second selective write failed: ") + error
    );

    {
        typename Adapter::File file(path, true, TagLib::AudioProperties::Fast);
        verifySecondWrite(Adapter::tag(file, false));
    }
}

struct MPEGAdapter {
    using File = TagLib::MPEG::File;
    static Tag *tag(File &file, bool create) { return file.ID3v2Tag(create); }
    static bool save(File &file)
    {
        return file.save(
            File::ID3v2,
            TagLib::File::StripNone,
            TagLib::ID3v2::v4,
            TagLib::File::DoNotDuplicate
        );
    }
};

struct WAVEAdapter {
    using File = TagLib::RIFF::WAV::File;
    static Tag *tag(File &file, bool) { return file.ID3v2Tag(); }
    static bool save(File &file) { return file.save(); }
};

struct AIFFAdapter {
    using File = TagLib::RIFF::AIFF::File;
    static Tag *tag(File &file, bool) { return file.tag(); }
    static bool save(File &file) { return file.save(TagLib::ID3v2::v4); }
};

struct TrueAudioAdapter {
    using File = TagLib::TrueAudio::File;
    static Tag *tag(File &file, bool create) { return file.ID3v2Tag(create); }
    static bool save(File &file) { return file.save(); }
};

int main(int argc, char **argv)
{
    require(argc >= 8, "Expected ID3 fixtures followed by renamed Shorten fixtures");
    exercise<MPEGAdapter>(argv[1], PTID3ContainerKindMPEG);
    exercise<WAVEAdapter>(argv[2], PTID3ContainerKindWAVE);
    exercise<AIFFAdapter>(argv[3], PTID3ContainerKindAIFF);
    exercise<TrueAudioAdapter>(argv[4], PTID3ContainerKindTrueAudio);
    exercise<MPEGAdapter>(argv[5], PTID3ContainerKindMPEG);
    require(
        PTID3ProbeContainerAtPath(argv[6]) == PTID3ContainerKindNativeMetadata,
        "A FLAC renamed to .mp3 was not identified as native non-ID3 content"
    );
    for(int index = 7; index < argc; ++index) {
        require(
            PTID3ProbeContainerAtPath(argv[index]) == PTID3ContainerKindNone,
            std::string("Shorten-signature content was accepted for allowlisted path ") +
                argv[index]
        );
    }
    std::cout << "Selective ID3 real-file checks passed\n";
}
HARNESS_EOF

xcrun clang++ -std=c++17 -fobjc-arc \
    -I"$ROOT_DIR/Core/Metadata" \
    -I"$TAGLIB_SOURCE/Sources/taglib/include" \
    "$HARNESS" "$BRIDGE_IMPL" "$TAGLIB_OBJECT" \
    -lz -o "$TMP_DIR/id3_selective_harness"

"$TMP_DIR/id3_selective_harness" \
    "$TMP_DIR/sample.mp3" \
    "$TMP_DIR/sample.wav" \
    "$TMP_DIR/sample.aiff" \
    "$TMP_DIR/sample.tta" \
    "$TMP_DIR/misnamed-mpeg.flac" \
    "$TMP_DIR/renamed-flac.mp3" \
    "${SHORTEN_PATHS[@]}"
