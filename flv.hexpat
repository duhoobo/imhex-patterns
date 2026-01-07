// vim: ft=rust:
#pragma author duhoobo@gmail.com
#pragma description FLV with Enhanced RTMP
#pragma pattern_limit 0x100000

#pragma endian big
#pragma MIME video/x-flv

import type.magic;


namespace amf {
    enum AMF0Type : u8 {
        number = 0x00,
        boolean = 0x01,
        string = 0x02,
        object = 0x03,
        movie_clip = 0x04,
        nil = 0x05,
        reserved1 = 0x06,
        reference = 0x07,
        ecma_array = 0x08,
        object_end = 0x09,
        strict_array = 0x0A,
        date = 0x0B,
        long_string = 0x0C,
        reserved2 = 0x0D,
        record_set = 0x0E,
        xml_document = 0x0F,
        typed_object = 0x10,
        amf3 = 0x11,
        origin_strict_array = 0x20,
        invalid = 0x3F
    };

    // Helper: read next 3 bytes and restore offset, return whether it's NOT the object-end marker.
    fn amf0_object_not_end() {
        u24 _peek = std::mem::read_unsigned($, 3, std::mem::Endian::Big);
        $ -= 3;
        return _peek != 0x000009;
    };

    // For ECMA array we can reuse same check but provide a name for clarity (keeps intent explicit).
    fn amf0_ecma_array_not_end() {
        u24 _peek = std::mem::read_unsigned($, 3, std::mem::Endian::Big);
        $ -= 3;
        return _peek != 0x000009;
    };

    fn format_amf0_type(u8 type) {
        if (type == AMF0Type::number) {
            return std::format("AMF0Number");
        } else if (type == AMF0Type::boolean) {
            return std::format("AMF0Boolean");
        } else if (type == AMF0Type::string) {
            return std::format("AMF0String");
        } else if (type == AMF0Type::object) {
            return std::format("AMF0Object");
        } else if (type == AMF0Type::nil) {
            return std::format("AMF0Null");
        } else if (type == AMF0Type::ecma_array) {
            return std::format("AMF0ECMAArray");
        } else if (type == AMF0Type::object_end) {
            return std::format("AMF0ObjectEnd");
        } else if (type == AMF0Type::strict_array) {
            return std::format("AMF0StrictArray");
        } else {
            return std::format("AMF0{}", type);
        }
    };

    using AMF0;
    using AMF0String;
    using AMF0LongString;
    using AMF0ObjectKeyVal;

    fn format_amf0_string(ref AMF0String amf0) {
        return std::format("{}", amf0.value);
    };

    // reuse same formatter for long string (both expose value)
    fn format_amf0_long_string(ref AMF0LongString amf0) {
        return std::format("{}", amf0.value);
    };

    fn format_amf0_value(ref AMF0 amf0) {
        return amf::format_amf0_type(amf0.type);
    };

    fn format_amf0_object_keyval(ref AMF0ObjectKeyVal keyval) {
        return std::format("{} {}", amf::format_amf0_value(keyval.value), keyval.key.value);
    };

    struct AMF0String {
        u16 length;
        char value[length];
    } [[format("amf::format_amf0_string")]];

    struct AMF0LongString {
        u32 length;
        char value[length];
    } [[format("amf::format_amf0_long_string")]];

    struct AMF0ObjectKeyVal {
        AMF0String key;
        AMF0 value;
    } [[format("amf::format_amf0_object_keyval")]];

    struct AMF0Object {
        // use helper function in while-expression (function handles read+restore)
        AMF0ObjectKeyVal keyvals[while(amf::amf0_object_not_end())] [[inline]];

        // consume the 00 00 09 object-end marker so subsequent parsing is aligned
        u24 object_end_marker [[hidden]];
    };

    struct AMF0ObjectEnd {
        // empty; marker consumed by AMF0Object
    };

    struct AMF0ECMAArray {
        u32 length;

        AMF0ObjectKeyVal keyvals[while(amf::amf0_ecma_array_not_end())] [[inline]];

        // consume the 00 00 09 object-end marker
        u24 object_end_marker [[hidden]];
    };

    struct AMF0StrictArray {
        u32 count;
        AMF0 items[count] [[inline]];
    };

    struct AMF0 {
        u8 type [[format("amf::format_amf0_type")]];

        match (type) {
            (AMF0Type::number) : double value;
            (AMF0Type::boolean) : bool value;
            (AMF0Type::string) : AMF0String value [[inline]];
            (AMF0Type::long_string) : AMF0LongString value [[inline]];
            (AMF0Type::object) : AMF0Object value [[inline]];
            (AMF0Type::object_end) : AMF0ObjectEnd value [[inline]];
            (AMF0Type::ecma_array) : AMF0ECMAArray value [[inline]];
            (AMF0Type::strict_array) : AMF0StrictArray value [[inline]];
            // other AMF0 types (date, reference, typed_object...) can be added later
        }
    };
} // namespace amf

namespace exp_golomb {
    // Internal: read one bit from stream at absolute base_offset and bitpos.
    // Returns encoded u32: (new_bitpos << 1) | bit
    fn read_one_bit_encoded(u64 base_offset, u32 buf_len, u32 bitpos) {
        u32 byte_index = bitpos / 8u;
        u32 inner_bit = bitpos % 8u;
        if (byte_index >= buf_len) {
            // out of range: return bit=0 and unchanged pos
            return (bitpos << 1) | 0u;
        }
        u8 b = std::mem::read_unsigned(base_offset + byte_index, 1, std::mem::Endian::Big);
        u32 bit = (b >> (7u - inner_bit)) & 1u;
        u32 newpos = bitpos + 1u;
        return (newpos << 1) | bit;
    };

    // Read n bits (n <= 32) starting at bitpos, set start_bit and return value.
    fn read_bits(u64 base_offset, u32 buf_len, u32 start_bit, u32 n) {
        u32 newpos = start_bit;
        u32 v = 0u;
        u32 i = 0u;
        while (i < n) {
            u32 enc = exp_golomb::read_one_bit_encoded(base_offset, buf_len, newpos);
            u32 bit = enc & 1u;
            newpos = enc >> 1;
            v = (v << 1) | bit;
            i = i + 1u;
        }
        return (v << 32) | newpos;
    };

    // Read unsigned Exp-Golomb (UE) from stream buffer at base_offset with buf_len bytes,
    // starting at start_bit (bit index). Returns decoded value and updates start_bit.
    fn read_ue(u64 base_offset, u32 buf_len, u32 start_bit) {
        u32 newpos = start_bit;
        u32 leadingZeros = 0u;

        // count leading zeros until first '1'
        while (true) {
            u32 enc = exp_golomb::read_one_bit_encoded(base_offset, buf_len, newpos);
            u32 bit = enc & 1u;
            newpos = enc >> 1;
            if (bit == 1u) { break; }
            leadingZeros = leadingZeros + 1u;
            if (newpos >= buf_len * 8u) {
                return newpos;
            }
        }

        u32 info = 0u;
        if (leadingZeros > 0u) {
            // read `leadingZeros` bits
            u32 pos_tmp = newpos;
            u32 idx = 0u;
            u32 val = 0u;
            while (idx < leadingZeros) {
                u32 e = exp_golomb::read_one_bit_encoded(base_offset, buf_len, pos_tmp);
                u32 b = e & 1u;
                pos_tmp = e >> 1;
                val = (val << 1) | b;
                idx = idx + 1u;
            }
            info = val;
            newpos = pos_tmp;
        }

        // UE value = 2^leadingZeros - 1 + info
        u32 value = (1u << leadingZeros) - 1u + info;
        return (value << 32 | newpos);
    };

    // Read signed Exp-Golomb (SE), returns s32 and updates start_bit.
    fn read_se(u64 base_offset, u32 buf_len, u32 start_bit) {
        u64 rval = exp_golomb::read_ue(base_offset, buf_len, start_bit);

        u32 codeNum = rval >> 32;
        u32 newpos = 0xFFFFFFFF | rval;

        s32 se;
        if (codeNum == 0u) {
            se = 0;
        } else if ((codeNum & 1u) == 1u) {
            se = s32((codeNum + 1u) / 2u);
        } else {
            se = -s32(codeNum / 2u);
        }

        return (se << 32) | newpos;
    };

    // Align bitpos to next byte boundary
    fn bitpos_to_next_byte(u32 bitpos) {
        u32 rem = bitpos % 8u;
        if (rem == 0u) { return bitpos; } else { return bitpos + (8u - rem); }
    };
} // namespace exp_golomb

// FLV
//
// A bunch of formatters
//
using Header;
using TagType;
using Tag;
using VideoFrameType;
using VideoCodecId;
using VideoPacketType;
using VideoEnhancedPacketType;
using SpsNalu;
using AACPacketType;
using AvcNaluHeader;

namespace fmt {
    fn format_header(ref Header header) {
        return std::format("version={}, audio={}, video={}", header.version, header.flags.has_audio,
            header.flags.has_video);
    };

    fn format_tag_type(ref TagType type) {
        if (type == TagType::audio) {
            return std::format("Audio Tag");
        } else if (type == TagType::video) {
            return std::format("Video Tag");
        } else if (type == TagType::script) {
            return std::format("Script Tag");
        } else {
            return std::format("{}", type);
        }
    };

    fn format_tag(ref Tag tag) {
        if (tag.type == TagType::audio) {
            return std::format("Audio: [{} {}|{}|{}|{}], dts={}",
                    fmt::format_sound_format(tag.audio_tag.audio_tag_header.sound_format),
                    fmt::format_audio_packet_type(tag.audio_tag.audio_tag_header.packet_type),
                    fmt::format_sound_rate(tag.audio_tag.audio_tag_header.sound_rate),
                    fmt::format_sound_size(tag.audio_tag.audio_tag_header.sound_size),
                    fmt::format_sound_type(tag.audio_tag.audio_tag_header.sound_type),
                    tag.audio_tag.timestamp);
        } else if (tag.type == TagType::video) {
            if (tag.video_tag.video_tag_header.ext_header) {
                return std::format("Video: [{} {}|{}], Enhanced, dts={}, cts={}",
                    tag.video_tag.video_tag_header.four_cc,
                    fmt::format_video_frame_type(tag.video_tag.video_tag_header.frame_type),
                    fmt::format_video_packet_type(tag.video_tag.video_tag_header.packet_type),
                    tag.video_tag.timestamp, tag.video_tag.video_tag_header.composition_time);
            } else {
                return std::format("Video: [{} {}|{}], dts={}, cts={}",
                    fmt::format_video_codec_id(tag.video_tag.video_tag_header.codec_id),
                    fmt::format_video_frame_type(tag.video_tag.video_tag_header.frame_type),
                    fmt::format_video_packet_type(tag.video_tag.video_tag_header.packet_type),
                    tag.video_tag.timestamp, tag.video_tag.video_tag_header.composition_time);
            }
        } else {
            return std::format("Script: dts={}", tag.script_tag.timestamp);
        }
    };

    fn format_sound_format(u8 value) {
        if (value == 0) {
            return "Linear PCM, platform endian";
        } else if (value == 1) {
            return "ADPCM";
        } else if (value == 2) {
            return "MP3";
        } else if (value == 3) {
            return "Linear PCM, little endian";
        } else if (value == 4) {
            return "Nellymoser 16 kHz mono";
        } else if (value == 5) {
            return "Nellymoser 8 kHz mono";
        } else if (value == 6) {
            return "Nellymoser";
        } else if (value == 7) {
            return "G.711 A-law logarithmic PCM";
        } else if (value == 8) {
            return "G.711 mu-law logarithmic PCM";
        } else if (value == 10) {
            return "AAC";
        } else if (value == 11) {
            return "Speex";
        } else if (value == 14) {
            return "MP3 8 kHz";
        } else if (value == 15) {
            return "Device-specific sound";
        } else {
            return str(value);
        }
    };

    fn format_sound_rate(u8 value) {
        if (value == 0) {
            return "5.5 kHz";
        } else if (value == 1) {
            return "11 kHz";
        } else if (value == 2) {
            return "22 kHz";
        } else if (value == 3) {
            return "44 kHz";
        } else {
            return str(value);
        }
    };

    fn format_sound_size(u8 value) {
        if (value == 0) {
            return "8-bit samples";
        } else if (value == 1) {
            return "16-bit samples";
        } else {
            return str(value);
        }
    };

    fn format_sound_type(u8 value) {
        if (value == 0) {
            return "Mono sound";
        } else if (value == 1) {
            return "Stereo sound";
        } else {
            return str(value);
        }
    };

    fn format_audio_object_type(u8 value) {
        if (value == 1) {
            return "AAC Main";
        } else if (value == 2) {
            return "AAC LC";
        } else if (value == 3) {
            return "AAC SSR";
        } else if (value == 4) {
            return "AAC LTP";
        } else if (value == 5) {
            return "SBR";
        } else if (value == 6) {
            return "AAC scalable";
        } else if (value == 7) {
            return "TwinVQ";
        } else if (value == 8) {
            return "CELP";
        } else if (value == 9) {
            return "HVXC";
        } else if (value == 12) {
            return "TTSI";
        } else if (value == 13) {
            return "Main synthetic";
        } else if (value == 14) {
            return "Wavetable synthesis";
        } else if (value == 15) {
            return "General MIDI";
        } else if (value == 16) {
            return "Algorithm Synthesis and Audio FX";
        } else {
            return str(value);
        }
    };

    fn format_sampling_frequency_index(u8 value) {
        if (value == 0) {
            return "96000";
        } else if (value == 1) {
            return "88200";
        } else if (value == 2) {
            return "64000";
        } else if (value == 3) {
            return "48000";
        } else if (value == 4) {
            return "44100";
        } else if (value == 5) {
            return "32000";
        } else if (value == 6) {
            return "24000";
        } else if (value == 7) {
            return "22050";
        } else if (value == 8) {
            return "16000";
        } else if (value == 9) {
            return "12000";
        } else if (value == 10) {
            return "11025";
        } else if (value == 11) {
            return "8000";
        } else if (value == 12) {
            return "7350";
        } else if (value == 15) {
            return "Escape";
        } else {
            return str(value);
        }
    };

    fn format_audio_packet_type(u8 value) {
        if (value == AACPacketType::sequence_header) {
            return "Sequence Header";
        } else if (value == AACPacketType::raw) {
            return "Raw";
        } else {
            return str(value);
        }
    };

    fn format_video_frame_type(u8 value) {
        if (value == VideoFrameType::key_frame) {
            return "Key Frame";
        } else if (value == VideoFrameType::inter_frame) {
            return "Inter Frame";
        } else if (value == VideoFrameType::disposable_inter_frame) {
            return "Disposable Inter Frame";
        } else if (value == VideoFrameType::generated_key_frame) {
            return "Generated Key Frame";
        } else if (value == VideoFrameType::video_info) {
            return "Video Info/Command Frame";
        } else {
            return "Not Known";
        }
    };

    fn format_video_codec_id(u8 value) {
        if (value == VideoCodecId::h263) {
            return "Sorenson H.263";
        } else if (value == VideoCodecId::screen) {
            return "Screen video";
        } else if (value == VideoCodecId::vp6) {
            return "On2 VP6";
        } else if (value == VideoCodecId::vp6_with_alpha) {
            return "On2 VP6 with alpha channel";
        } else if (value == VideoCodecId::screenv2) {
            return "Screen video version 2";
        } else if (value == VideoCodecId::avc) {
            return "AVC";
        } else if (value == VideoCodecId::hevc) {
            return "HEVC";
        } else if (value == VideoCodecId::av1) {
            return "AV1";
        } else if (value == VideoCodecId::vvc) {
            return "VVC";
        } else {
            return "NotKnown";
        }
    };

    fn format_video_packet_type(u8 value) {
        if (value == VideoPacketType::sequence_header) {
            return "Sequence Header";
        } else if (value == VideoPacketType::nalu) {
            return "NALU";
        } else if (value == VideoPacketType::end_of_sequence) {
            return "End Of Sequence";
        } else {
            return str(value);
        }
    };

    fn format_video_enhanced_packet_type(u8 value) {
        if (value == VideoEnhancedPacketType::sequence_start) {
            return "Sequence Start";
        } else if (value == VideoEnhancedPacketType::coded_frames) {
            return "Coded Frames";
        } else if (value == VideoEnhancedPacketType::sequence_end) {
            return "Sequence End";
        } else if (value == VideoEnhancedPacketType::coded_frames_x) {
            return "Coded Frames X";
        } else if (value == VideoEnhancedPacketType::metadata) {
            return "Metadata";
        } else if (value == VideoEnhancedPacketType::mpeg2ts_sequence_start) {
            return "MPEG2 TS Sequence Start";
        } else if (value == VideoEnhancedPacketType::multitrack) {
            return "Multitrack";
        } else if (value == VideoEnhancedPacketType::mod_ex) {
            return "ModEx";
        } else {
            return "Reserved";
        }
    };

    fn format_avc_nalu_type(u8 value) {
        if (value == 0) {
            return "Unspecified";
        } else if (value == 1) {
            return "SliceOfNonIDR";
        } else if (value == 2) {
            return "SliceOfPartitionA";
        } else if (value == 3) {
            return "SliceOfPartitionB";
        } else if (value == 4) {
            return "SliceOfPartitionC";
        } else if (value == 5) {
            return "SliceOfIDR";
        } else if (value == 6) {
            return "SEI";
        } else if (value == 7) {
            return "SPS";
        } else if (value == 8) {
            return "PPS";
        } else if (value == 9) {
            return "AUD";
        } else if (value == 10) {
            return "EndOfSequence";
        } else if (value == 11) {
            return "EndOfStream";
        } else if (value == 12) {
            return "FillerData";
        } else if (value == 13) {
            return "SPSExt";
        } else if (value == 14) {
            return "PrefixNalu";
        } else if (value == 15) {
            return "SPSSubset";
        } else if (value == 16) {
            return "DepthParameterSet";
        } else if (value == 17 || value == 18) {
            return "Reserved";
        } else if (value == 19) {
            return "SliceOfAuxCodedPictureWithoutPartitioning";
        } else if (value == 20) {
            return "SliceExt";
        } else if (value == 21) {
            return "SliceExtForDepthViewComponents";
        } else {
            return str(value);
        }
    };

    fn format_sps_nalu(ref SpsNalu sps) {
        return std::format("SPS: width={}, height={}, display_w={}, display_h={}",
            sps.width, sps.height, sps.display_width, sps.display_height
        );
    };

    fn format_avc_nalu_header(ref AvcNaluHeader hdr) {
        return std::format("AVC NALU: nal_ref_idc={}, nal_unit_type={}", hdr.nal_ref_idc,
            fmt::format_avc_nalu_type(hdr.nal_unit_type));
    };
}


u8 global_nalu_length_size = 0;

struct FLV {
    Header header;
    Tag tags[while(!std::mem::eof())] [[name("Body")]];
} [[static, name("FLV")]];

bitfield Flags {
    reserved1 : 5;
    has_audio : 1;
    reserved2 : 1;
    has_video : 1;
};

struct Header {
    type::Magic<"FLV"> magic;
    u8 version;
    Flags flags [[inline]];
    u32 header_size;
    u32 first_tag_size;
} [[static,name("Header"),format("fmt::format_header")]];

enum TagType : u8 {
    audio = 0x08,
    video = 0x09,
    script = 0x12
} [[format("fmt::format_tag_type")]];

using ScriptTag;
using AudioTag;
using VideoTag;

struct Tag {
    TagType type [[name("tag_type")]];

    match (type) {
        (TagType::script): ScriptTag script_tag [[inline]];
        (TagType::audio): AudioTag audio_tag [[inline]];
        (TagType::video): VideoTag video_tag [[inline]];
    }

    u32 previous_tag_size;
} [[format("fmt::format_tag")]];

struct BaseTag {
    u24 data_size;

    // FLV timestamp is 3 bytes + 1 byte extended (TimestampExtended << 24 | Timestamp)
    u24 timestamp_low;
    u8 timestamp_extended;
    u32 timestamp = (u32(timestamp_extended) << 24) | u32(timestamp_low);

    u24 stream_id;
    u64 end = $ + data_size;
};

// Script Tag
//
struct ScriptTag : BaseTag {
    if ($ < end)
        amf::AMF0 amf1;
    if ($ < end)
        amf::AMF0 amf2;
    u8 opaque[end - $];
} [[name("Script Tag")]];

// Audio Tag
//
enum AACPacketType : u8 {
    sequence_header = 0,
    raw = 1,
};

bitfield AudioTagSubHeader {
    sound_format : 4 [[format("fmt::format_sound_format")]];
    sound_rate : 2 [[format("fmt::format_sound_rate")]];
    sound_size : 1 [[format("fmt::format_sound_size")]];
    sound_type : 1 [[format("fmt::format_sound_type")]];
};

struct AudioTagHeader {
    AudioTagSubHeader sub_header [[inline]];
    u8 sound_format = sub_header.sound_format;
    u8 sound_rate = sub_header.sound_rate;
    u8 sound_size = sub_header.sound_size;
    u8 sound_type = sub_header.sound_type;

    if (sub_header.sound_format == 10) {
        u8 packet_type;
    } else {
        u8 packet_type = 255;
    }
} [[name("Audio Tag Header")]];

bitfield AudioSpecificConfig {
    audioObjectType : 5 [[format("fmt::format_audio_object_type")]];
    samplingFrequencyIndex : 4 [[format("fmt::format_sampling_frequency_index")]];
    channelConfiguration : 4;
    SpecificConfig : 3;
} [[name("AudioSpecificConfig")]];

fn adts_next_is_syncword() {
    u16 _peek = std::mem::read_unsigned($, 2, std::mem::Endian::Big);
    $ -= 2;
    return (_peek >> 4) == 0xFFF;
};

bitfield ADTSHeader {
    syncword : 12;                         // 0xFFF
    id : 1;
    layer : 2;
    protection_absent : 1;
    profile : 2;
    sampling_frequency_index : 4;
    private_bit : 1;
    channel_configuration : 3;
    original_copy : 1;
    home : 1;
    copyright_id_bit : 1;
    copyright_id_start : 1;
    aac_frame_length : 13;                 // includes header length (7 or 9)
    adts_buffer_fullness : 11;
    number_of_raw_data_blocks : 2;         // usually 0
} [[name("ADTS Header")]];

struct ADTSFrame {
    ADTSHeader adts_header [[inline]];
    if (adts_header.protection_absent == 0) {
        u16 crc_check;
    }
    // payload length = aac_frame_length - header_length, and
    // header_length is 7 when protection_absent == 1, else 9
    u8 aac_raw_data[adts_header.aac_frame_length - (adts_header.protection_absent == 1 ? 7 : 9)];
} [[name("ADTS Frame")]];

struct AudioTag : BaseTag {
    AudioTagHeader audio_tag_header;

    if (audio_tag_header.sound_format == 10) {
        if (audio_tag_header.packet_type == AACPacketType::sequence_header) {
            AudioSpecificConfig audio_specific_config;
        } else if (audio_tag_header.packet_type == AACPacketType::raw) {
            if (adts_next_is_syncword()) {
                // if we detect ADTS syncword, parse as ADTS frames repeatedly, non-standard
                ADTSFrame adts_frames[while(adts_next_is_syncword() && ($ < end))] [[inline]];
            } else {
                u8 aac_raw_data[end - $] [[name("AAC ES")]];
            }
        }
    }

    u8 opaque[end - $];
} [[name("Audio Tag")]];

// Video Tag
//
enum VideoFrameType : u8 {
    key_frame = 1,
    inter_frame = 2,
    disposable_inter_frame = 3,
    generated_key_frame = 4,
    video_info = 5,
};

enum VideoCodecId : u8 {
    h263 = 2,
    screen = 3,
    vp6 = 4,
    vp6_with_alpha = 5,
    screenv2 = 6,
    avc = 7,
    hevc = 12,
    av1 = 13,
    vvc = 14,
};

enum VideoPacketType : u8 {
    sequence_header = 0,
    nalu = 1,
    end_of_sequence = 2
};

enum VideoEnhancedPacketType : u8 {
    sequence_start = 0,
    coded_frames = 1,
    sequence_end = 2,
    coded_frames_x = 3,   // no CompositionTime
    metadata = 4,
    mpeg2ts_sequence_start = 5,
    multitrack = 6,
    mod_ex = 7,
    reserved = 8 ... 15
};

bitfield AvcDecoderConfigurationLengths {
    reserved0 : 6;
    lengthSizeMinusOne : 2;
    reserved1 : 3;
    numOfSequenceParameterSets : 5;
};

bitfield AvcNaluHeader {
    forbidden_zero_bit : 1;
    nal_ref_idc : 2;
    nal_unit_type : 5;
} [[name("AVC NALU Header"),format("fmt::format_avc_nalu_header")]];

struct SpsNalu {
    u16 sps_nalu_length [[name("SPS NALU Length")]];
    u32 end = $ + sps_nalu_length;

    AvcNaluHeader avc_nalu_header;
    u8 profile_idc;
    u8 constraint_set_flags;
    u8 level_idc;
    $ -= 4;

    // bit parsing position (bits)
    u32 buflen = sps_nalu_length - 3;
    // as start offset bit and compound returning value
    u64 compo = 4u * 8u;

    compo = exp_golomb::read_ue($, buflen, u32(compo));
    std::print("SpsNalu: seq_parameter_set_id={}, bitoff={}", compo >> 32, u32(compo));

    u32 chroma_format_idc = 1u;
    u32 separate_colour_plane_flag = 0u;
    // profiles that include chroma_format_idc etc
    if (profile_idc == 100u || profile_idc == 110u || profile_idc == 122u
            || profile_idc == 244u || profile_idc == 44u || profile_idc == 83u
            || profile_idc == 86u || profile_idc == 118u || profile_idc == 128u
            || profile_idc == 138u || profile_idc == 139u || profile_idc == 134u) {
        compo = exp_golomb::read_ue($, buflen, u32(compo));
        std::print("SpsNalu: chroma_format_idc={}, bitoff={}", compo >> 32, u32(compo));
        if ((compo >> 32) == 3u) {
            compo = exp_golomb::read_bits($, buflen, compo, 1);
            std::print("SpsNalu: separate_colour_plane_flag={}, bitoff={}", compo >> 32, u32(compo));
        }
        compo = exp_golomb::read_ue($, buflen, u32(compo));
        std::print("SpsNalu: bit_depth_luma_minus8={}, bitoff={}", compo >> 32, u32(compo));
        compo = exp_golomb::read_ue($, buflen, u32(compo));
        std::print("SpsNalu: bit_depth_chroma_minus8={}, bitoff={}", compo >> 32, u32(compo));
        compo = exp_golomb::read_bits($, buflen, compo, 1);
        std::print("SpsNalu: qpprime_y_zero_transform_bypass_flag={}, bitoff={}", compo >> 32, u32(compo));
        compo = exp_golomb::read_bits($, buflen, compo, 1);
        std::print("SpsNalu: seq_scaling_matrix_present_flag={}, bitoff={}", compo >> 32, u32(compo));

        u32 seq_scaling_matrix_present_flag = compo >> 32;
        if (seq_scaling_matrix_present_flag == 1u) {
            // TODO
            // scaling lists are complex; skip/opaque (not parsed here)
            // For robustness we won't attempt to parse them in this compact implementation.
        }
    }

    compo = exp_golomb::read_ue($, buflen, u32(compo));
    std::print("SpsNalu: log2_max_frame_num_minus4={}, bitoff={}", compo >> 32, u32(compo));
    compo = exp_golomb::read_ue($, buflen, u32(compo));
    std::print("SpsNalu: pic_order_cnt_type={}, bitoff={}", compo >> 32, u32(compo));

    u32 pic_order_cnt_type = compo >> 32;

    if (pic_order_cnt_type == 0u) {
        compo = exp_golomb::read_ue($, buflen, u32(compo));
        std::print("SpsNalu: log2_max_pic_order_cnt_lsb_minus4={}, bitoff={}", compo >> 32, u32(compo));
    } else if (pic_order_cnt_type == 1u) {
        // partial parse for type==1: read a few fields, skip array entries
        compo = exp_golomb::read_bits($, buflen, compo, 1);
        std::print("SpsNalu: delta_pic_order_always_zero_flag={}, bitoff={}", compo >> 32, u32(compo));
        compo = exp_golomb::read_se($, buflen, u32(compo));
        std::print("SpsNalu: offset_for_non_ref_pic={}, bitoff={}", s32(compo >> 32), u32(compo));
        compo = exp_golomb::read_se($, buflen, u32(compo));
        std::print("SpsNalu: offset_for_top_to_bottom_field={}, bitoff={}", s32(compo >> 32), u32(compo));
        compo = exp_golomb::read_ue($, buflen, u32(compo));
        std::print("SpsNalu: num_ref_frames_in_pic_order_cnt_cycle={}, bitoff={}", compo >> 32, u32(compo));
        u32 num_ref_frames_in_pic_order_cnt_cycle = compo >> 32;
        // skip offset_for_ref_frame[]
        compo += 8u * num_ref_frames_in_pic_order_cnt_cycle;
    }

    compo = exp_golomb::read_ue($, buflen, u32(compo));
    std::print("SpsNalu: max_num_ref_frames={}, bitoff={}", compo >> 32, u32(compo));
    compo = exp_golomb::read_bits($, buflen, compo, 1);
    std::print("SpsNalu: gaps_in_frame_num_value_allowed_flag={}, bitoff={}", compo >> 32, u32(compo));

    compo = exp_golomb::read_ue($, buflen, u32(compo));
    u32 pic_width_in_mbs_minus1 = compo >> 32;
    std::print("SpsNalu: pic_width_in_mbs_minus1={}, bitoff={}", compo >> 32, u32(compo));

    compo = exp_golomb::read_ue($, buflen, u32(compo));
    u32 pic_height_in_map_units_minus1 = compo >> 32;
    std::print("SpsNalu: pic_height_in_map_units_minus1={}, bitoff={}", compo >> 32, u32(compo));

    compo = exp_golomb::read_bits($, buflen, u32(compo), 1);
    u32 frame_mbs_only_flag = compo >> 32;
    if (frame_mbs_only_flag == 0u) {
        compo = exp_golomb::read_bits($, buflen, u32(compo), 1);
        std::print("SpsNalu: mb_adaptive_frame_field_flag={}, bitoff={}", compo >> 32, u32(compo));
    }
    compo = exp_golomb::read_bits($, buflen, u32(compo), 1);
    std::print("SpsNalu: direct_8x8_inference_flag={}, bitoff={}", compo >> 32, u32(compo));

    compo = exp_golomb::read_bits($, buflen, u32(compo), 1);
    u32 frame_cropping_flag = compo >> 32;

    u32 frame_crop_left_offset = 0u;
    u32 frame_crop_right_offset = 0u;
    u32 frame_crop_top_offset = 0u;
    u32 frame_crop_bottom_offset = 0u;
    if (frame_cropping_flag == 1u) {
        compo = exp_golomb::read_ue($, buflen, u32(compo));
        frame_crop_left_offset = compo >> 32;
        compo = exp_golomb::read_ue($, buflen, u32(compo));
        frame_crop_right_offset = compo >> 32;
        compo = exp_golomb::read_ue($, buflen, u32(compo));
        frame_crop_top_offset = compo >> 32;
        compo = exp_golomb::read_ue($, buflen, u32(compo));
        frame_crop_bottom_offset = compo >> 32;
    }

    std::print("SpsNalu: frame_crop_offset, flag={}, left={}, right={}, top={}, bottom={}, bitoff={}",
        frame_cropping_flag, frame_crop_left_offset, frame_crop_right_offset, frame_crop_top_offset,
        frame_crop_bottom_offset, u32(compo));

    // derived/display values
    u32 pic_width_in_mbs = pic_width_in_mbs_minus1 + 1u;
    u32 pic_height_in_map_units = pic_height_in_map_units_minus1 + 1u;
    u32 frame_height_in_mbs = (2u - frame_mbs_only_flag) * pic_height_in_map_units;
    u32 width = pic_width_in_mbs * 16u;
    u32 height = frame_height_in_mbs * 16u;

    // apply simple cropping units (assume 4:2:0 typical)
    u32 crop_unit_x = 1u;
    u32 crop_unit_y = 2u - frame_mbs_only_flag;
    if (chroma_format_idc == 1u) { // 4:2:0
        crop_unit_x = 2u;
        crop_unit_y = 2u * (2u - frame_mbs_only_flag);
    } else if (chroma_format_idc == 2u) { // 4:2:2
        crop_unit_x = 2u;
        crop_unit_y = 2u - frame_mbs_only_flag;
    } else if (chroma_format_idc == 0u) { // monochrome
        crop_unit_x = 1u;
        crop_unit_y = 2u - frame_mbs_only_flag;
    }

    u32 display_width = width - (frame_crop_left_offset + frame_crop_right_offset) * crop_unit_x;
    u32 display_height = height - (frame_crop_top_offset + frame_crop_bottom_offset) * crop_unit_y;

    std::print("SpsNalu: width*height={}*{}, display_width*display_height={}*{}",
        width, height, display_width, display_height);
    std::print("SpsNalu: length={}, end={}, $={}, bitoff={}", sps_nalu_length, end, $, u32(compo));

    u8 opaque[end - $] [[hidden]];
} [[format("fmt::format_sps_nalu")]];

bitfield SPSNaluExtFlags {
    reserved0 : 6;
    chroma_format : 2;
    reserved1 : 5;
    bit_depth_luma_minus8 : 3;
    reserved2 : 5;
    bit_depth_chroma_minus8 : 3;
};

struct PpsNalu {
    u16 pps_nalu_length [[name("PPS NALU Length")]];
    u32 end = $ + pps_nalu_length;

    AvcNaluHeader avc_nalu_header;

    // TODO
    u8 opaque[end - $] [[hidden]];
};

struct AvcDecoderConfigurationRecord {
    u8 configurationVersion;
    u8 AvcProfileIndication;
    u8 profile_compatibility;
    u8 AvcLevelIndication;

    AvcDecoderConfigurationLengths lengths [[inline]];
    global_nalu_length_size = lengths.lengthSizeMinusOne + 1;

    std::print("set NaluLengthSize={}", global_nalu_length_size);

    SpsNalu sps[lengths.numOfSequenceParameterSets] [[inline]];
    u8 numOfPictureParameterSets;
    PpsNalu pps[numOfPictureParameterSets] [[inline]];

    //if (AvcProfileIndication == 100             // Baseline Profile
    //        || AvcProfileIndication == 110      // Main Profile
    //        || AvcProfileIndication == 122      // Extended Profile
    //        || AvcProfileIndication == 144) {   // High 4:4:4 Predictive Profile
    //    SPSNaluExtFlags ext [[inline]];
    //    u8 numOfSequenceParameterSetExt;
    //    // sequenceParameterSetExtNalUnits
    //}
} [[name("AvcDecoderConfigurationRecord")]];

struct AvcNalu {
    if (global_nalu_length_size == 1u) {
        u8 nalu_length [[name("NALU Length")]];
    } else if (global_nalu_length_size == 2u) {
        u16 nalu_length [[name("NALU Length")]];
    } else if (global_nalu_length_size == 3u) {
        u24 nalu_length [[name("NALU Length")]];
    } else {
        u32 nalu_length [[name("NALU Length")]];
    }

    u32 end = $ + nalu_length;
    AvcNaluHeader avc_nalu_header;

    u8 payload[end - $] [[name("AVC NALU Payload")]];
};

bitfield VvcDCRNaluLengthSizeAndPtlFlag {
    reserved : 5;
    LengthSizeMinusOne : 2;
    ptl_present_flag : 1;
};

bitfield VvcDCRPrePtlRecord {
    ols_idx : 9;
    num_sublayers : 3;
    constant_frame_rate : 2;
    chroma_format_idc : 2;
    bit_depth_minus8 : 3;
    reserved : 5;
};

bitfield VvcPTLRecord {
    reserved : 2;
    num_bytes_constraint_info : 6;
    general_profile_idc : 7;
    general_tier_flag : 1;
    general_level_idc : 8;
};

struct VvcDCRPtl {
    VvcDCRPrePtlRecord pre_ptl_record;
};

struct VvcDecoderConfigurationRecord {
    VvcDCRNaluLengthSizeAndPtlFlag nalu_length_size_and_ptl_flag [[inline]];

    if (nalu_length_size_and_ptl_flag.ptl_present_flag) {
        VvcDCRPtl ptl [[inline]];
        VvcPTLRecord ptl_record_p1 [[inline]];
        u8 general_constraint_info_with_previous_2_bits_flags[ptl_record_p1.num_bytes_constraint_info];

        u16 max_picture_width;
        u16 max_picture_height;
        u16 avg_frame_rate;
    }
};

bitfield VideoTagSubHeader {
    ext_header : 1;
    frame_type : 3;
    codec_id_or_enhanced_packet_type : 4;
};

struct VideoTagHeader {
    VideoTagSubHeader sub_header[[inline]];

    u8 ext_header = sub_header.ext_header;
    u8 frame_type = sub_header.frame_type;

    if (!ext_header) {
        u8 codec_id = sub_header.codec_id_or_enhanced_packet_type;

        if (codec_id == VideoCodecId::avc || codec_id == VideoCodecId::hevc
                || codec_id == VideoCodecId::av1 || codec_id == VideoCodecId::vvc) {
            u8 packet_type [[format("fmt::format_video_packet_type")]];
            s24 composition_time;
        } else {
            u8 packet_type = 255;
            s24 composition_time = 0;
        }
    } else {   // Enhanced RTMP
        u8 packet_type = sub_header.codec_id_or_enhanced_packet_type;
        char four_cc[4];    // hvc1, av01, av09
    }
} [[name("Video Tag Header")]];

struct VideoTag : BaseTag {
    VideoTagHeader video_tag_header;

    u8 nalu_length_size = 0u;

    if (video_tag_header.ext_header == 0) {
        if (video_tag_header.packet_type == VideoPacketType::sequence_header) {
            if (video_tag_header.codec_id == VideoCodecId::avc) {
                AvcDecoderConfigurationRecord avc_header [[name("AvcDecoderConfigurationRecord")]];
            } else if (video_tag_header.codec_id == VideoCodecId::vvc) {
                VvcDecoderConfigurationRecord vvc_header [[name("VvcDecoderConfigurationRecord")]];
            }
        } else if (video_tag_header.packet_type == VideoPacketType::nalu) {
            if (video_tag_header.codec_id == VideoCodecId::avc) {
                AvcNalu avc_nalus[while($ < end)] [[inline]];
            }
        }
    }

    u8 opaque[end - $];
} [[name("Video Tag")]];

// main
FLV flv @ 0x00;
