// vim: ft=rust:
#pragma author duhoobo@gmail.com
#pragma description FLV with Enhanced RTMP
#pragma pattern_limit 0x100000
#pragma eval_depth 128

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
        if (amf0.type == AMF0Type::number || amf0.type == AMF0Type::boolean) {
            return std::format("{}", amf0.value);
        } else if (amf0.type == AMF0Type::string) {
            return std::format("{}", amf::format_amf0_string(amf0.value));
        } else {
            return amf::format_amf0_type(amf0.type);
        }
    };

    fn format_amf0_object_keyval(ref AMF0ObjectKeyVal keyval) {
        return std::format("{}: {}", keyval.key.value, amf::format_amf0_value(keyval.value));
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

namespace expgolomb {
    // expgolomb::read_one_bit_encoded - treat bitpos as raw-stream bit index; skip 0x03 locally.
    // Returns encoded u32: (new_bitpos << 1) | bit
    fn read_one_bit_encoded(u64 base_offset, u32 buf_len, u32 bitpos) {
        u32 raw_index = bitpos / 8u;
        u32 inner_bit = bitpos % 8u;

        // clamp / bounds
        if (raw_index >= buf_len) { return (bitpos << 1) | 0u; }

        // advance raw_index while the byte at raw_index is an emulation-prevention 0x03
        // (i.e. raw[raw_index]==0x03 and raw[raw_index-1]==0x00 and raw[raw_index-2]==0x00)
        if (inner_bit == 0 && raw_index >= 2u) {
            u8 b2 = std::mem::read_unsigned(base_offset + raw_index - 2u, 1, std::mem::Endian::Big);
            u8 b1 = std::mem::read_unsigned(base_offset + raw_index - 1u, 1, std::mem::Endian::Big);
            u8 b0 = std::mem::read_unsigned(base_offset + raw_index, 1, std::mem::Endian::Big);
            if (b2 == 0x00u && b1 == 0x00u && b0 == 0x03u) {
                raw_index += 1u;
                if (raw_index >= buf_len) { return (bitpos << 1) | 0u; }
            }
        }

        u8 cur = std::mem::read_unsigned(base_offset + raw_index, 1, std::mem::Endian::Big);
        u32 bit = (u32((cur >> (7u - inner_bit)) & 1u));

        // new raw bit position: the bit we read was at (raw_index*8 + inner_bit), next bit is +1
        u32 newpos = raw_index * 8u + inner_bit + 1u;
        return (newpos << 1) | bit;
    };

    // Read n bits (n <= 32) starting at bitpos, set start_bit and return value.
    fn read_bits(u64 base_offset, u32 buf_len, u32 start_bit, u32 n) {
        u32 newpos = start_bit;
        u32 v = 0u;
        u32 i = 0u;
        while (i < n) {
            u32 enc = expgolomb::read_one_bit_encoded(base_offset, buf_len, newpos);
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
            u32 enc = expgolomb::read_one_bit_encoded(base_offset, buf_len, newpos);
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
                u32 e = expgolomb::read_one_bit_encoded(base_offset, buf_len, pos_tmp);
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
        return (value << 32) | newpos;
    };

    // Read signed Exp-Golomb (SE), returns s32 and updates start_bit.
    fn read_se(u64 base_offset, u32 buf_len, u32 start_bit) {
        u64 combo = expgolomb::read_ue(base_offset, buf_len, start_bit);
        u32 codeNum = u32(combo >> 32);
        u32 newpos = u32(0xFFFFFFFFu & combo);

        s32 se;
        if (codeNum == 0u) {
            se = 0;
        } else if ((codeNum & 1u) == 1u) {
            se = s32((codeNum + 1u) / 2u);
        } else {
            se = -s32(codeNum / 2u);
        }

        // pack signed value (converted to u32) in high 32 bits and bitpos in low 32 bits
        return (u64(u32(se)) << 32) | u64(newpos);
    };

    // Align bitpos to next byte boundary
    fn bitpos_to_next_byte(u32 bitpos) {
        u32 rem = bitpos % 8u;
        if (rem == 0u) { return bitpos; } else { return bitpos + (8u - rem); }
    };
} // namespace expgolomb

namespace helpers {
    fn skip_avc_pps_slice_group_map(u64 combo, u32 remaining_bytes, u32 slice_group_map_type, u32 num_slice_groups_minus1) {
        if (slice_group_map_type == 0u) {
            // type 0: run_length_minus1[i] for i = 0..num_slice_groups_minus1
            for (u32 i = 0u, i <= num_slice_groups_minus1, i = i + 1u) {
                combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
            }
            return combo;
        } else if (slice_group_map_type == 1u) {
            // type 1: dispersed - no additional syntax
            return combo;
        } else if (slice_group_map_type == 2u) {
            // type 2: top_left/bottom_right pairs
            for (u32 i = 0u, i <= num_slice_groups_minus1, i = i + 1u) {
                combo = expgolomb::read_ue($, remaining_bytes, u32(combo)); // top_left
                combo = expgolomb::read_ue($, remaining_bytes, u32(combo)); // bottom_right
            }
            return combo;
        } else if (slice_group_map_type == 3u || slice_group_map_type == 4u || slice_group_map_type == 5u) {
            // type 3/4/5: one bit + UE per group
            for (u32 i = 0u, i < num_slice_groups_minus1, i = i + 1u) {
                combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);  // direction flag
                combo = expgolomb::read_ue($, remaining_bytes, u32(combo));      // change_rate_minus1
            }
            return combo;
        } else if (slice_group_map_type == 6u) {
            // type 6: pic_size_in_map_units_minus1 + fixed-width slice_group_id[]
            combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
            u32 pic_size_in_map_units_minus1 = u32(combo >> 32);

            // compute bits_per_id = ceil(log2(num_slice_groups_minus1 + 1))
            u32 num_groups = num_slice_groups_minus1 + 1u;
            u32 bits_per_id = 0u;
            for (u32 tmp = 1u, tmp < num_groups, tmp <<= 1u) {
                bits_per_id += 1u;
            }

            for (u32 k = 0u, k <= pic_size_in_map_units_minus1, k = k + 1u) {
                if (bits_per_id > 0u) {
                    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), bits_per_id);
                }
            }
            return combo;
        } else {
            return combo;
        }
    };

    // New helper: skip offset_for_ref_frame[] in AVC SPS (SE entries)
    fn skip_avc_offset_for_ref_frames(u64 combo, u32 remaining_bytes, u32 count) {
        for (u32 k = 0u, k < count, k = k + 1u) {
            combo = expgolomb::read_se($, remaining_bytes, u32(combo));
        }
        return combo;
    };

    // VPS helpers to replace loops inside structs (avoid for/while inside struct bodies)
    // Parse sub_layer_profile_present_flag / sub_layer_level_present_flag and per-sub-layer fields,
    // then return updated combo. This handles reading flags, reserved bits, and optional per-sub-layer parsing.
    fn parse_vps_profile_tier_sublayers(u64 combo, u32 remaining_bytes, u32 vps_max_sub_layers_minus1) {
        // read sub_layer_profile_present_flag and sub_layer_level_present_flag for i=0..vps_max_sub_layers_minus1-1
        u32 sub_layer_profile_present_mask = 0u;
        u32 sub_layer_level_present_mask = 0u;
        for (u32 i = 0u, i < vps_max_sub_layers_minus1, i = i + 1u) {
            combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
            u32 profile_present = combo >> 32;
            if (profile_present == 1u) sub_layer_profile_present_mask |= (1u << i);
            combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
            u32 level_present = combo >> 32;
            if (level_present == 1u) sub_layer_level_present_mask |= (1u << i);
            std::print("VPS: sub_layer[%u] profile_present=%u level_present=%u bitoff=%u",
                i, profile_present, level_present, u32(combo));
        }

        // reserved_zero_2bits if less than 8 sub-layers
        if (vps_max_sub_layers_minus1 < 8u) {
            for (u32 i = vps_max_sub_layers_minus1, i < 8u, i = i + 1u) {
                combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 2);
            }
        }

        // For each sub-layer present, parse or skip its profile/level info.
        for (u32 i = 0u, i < vps_max_sub_layers_minus1, i = i + 1u) {
            if (((sub_layer_profile_present_mask >> i) & 1u) == 1u) {
                // read sub-layer profile fields (2 + 1 + 5 = 8 bits)
                combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 2);
                combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
                combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 5);
                // skip 32-bit compat and 48-bit constraint if available (read as 32+16)
                if (u32(combo) + 32u <= remaining_bytes * 8u) {
                    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 32);
                }
                if (u32(combo) + 16u <= remaining_bytes * 8u) {
                    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 16);
                }
                if (u32(combo) + 16u <= remaining_bytes * 8u) {
                    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 16);
                }
                std::print("VPS: parsed/skip sub_layer[%u] profile fields, bitoff=%u", i, u32(combo));
            }
            if (((sub_layer_level_present_mask >> i) & 1u) == 1u) {
                combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 8);
                std::print("VPS: sub_layer[%u] level_idc parsed, bitoff=%u", i, u32(combo));
            }
        }

        return combo;
    };

    // Parse vps_sub_layer_ordering_info entries (calls UE three times per sub-layer as per spec)
    fn parse_vps_sub_layer_ordering_info(u64 combo, u32 remaining_bytes, u32 vps_sub_layer_ordering_info_present_flag, u32 vps_max_sub_layers_minus1) {
        u32 start_i = vps_sub_layer_ordering_info_present_flag == 1u ? 0u : vps_max_sub_layers_minus1;
        for (u32 i = start_i, i <= vps_max_sub_layers_minus1, i = i + 1u) {
            combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
            u32 vps_max_dec_pic_buffering_minus1 = combo >> 32;
            combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
            u32 vps_max_num_reorder_pics = combo >> 32;
            combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
            u32 vps_max_latency_increase_plus1 = combo >> 32;
            std::print("VPS: sub_layer_info[{}] max_dec_pic_buffering_minus1={}, max_num_reorder_pics={}, max_latency_increase_plus1={}, bitoff={}",
                i, vps_max_dec_pic_buffering_minus1, vps_max_num_reorder_pics, vps_max_latency_increase_plus1, u32(combo));
        }
        return combo;
    };

    // Parse vps layer sets table (i = 1..vps_num_layer_sets_minus1, j = 0..vps_max_layer_id)
    fn parse_vps_layer_sets(u64 combo, u32 remaining_bytes, u32 vps_num_layer_sets_minus1, u32 vps_max_layer_id) {
        for (u32 i = 1u, i <= vps_num_layer_sets_minus1, i = i + 1u) {
            for (u32 j = 0u, j <= vps_max_layer_id, j = j + 1u) {
                combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
                // do not store flags here; we just advance and maintain bit offset
            }
            std::print("VPS: layer_set[{}] parsed layer_id_included_flags, bitoff={}", i, u32(combo));
        }
        return combo;
    };

    // New helper: read general_profile_compatibility_flags[32] and general_constraint_indicator_flags[48]
    fn parse_vps_sps_profile_compat_and_constraints(u64 combo, u32 remaining_bytes) {
        // read 32-bit compatibility flags in one read
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 32);
        u32 general_profile_compatibility_flags = combo >> 32;
        std::print("VPS or SPS: general_profile_compatibility_flags=0x{:08x}, bitoff={}", general_profile_compatibility_flags, u32(combo));

        // read 48-bit constraint flags as 32 + 16
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 32);
        u64 gcif_high32 = combo >> 32;
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 16);
        u64 gcif_low16 = combo >> 32;
        u64 general_constraint_indicator_flags = (gcif_high32 << 16) | gcif_low16;
        std::print("VPS or SPS: general_constraint_indicator_flags=0x{:012x}, bitoff={}", general_constraint_indicator_flags, u32(combo));

        return combo;
    };
} // namespace helpers

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
using AvcNalu;
using HevcNalu;
using AACPacketType;
using AvcNaluHeader;
using HevcNaluHeader;

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
            return std::format("Audio: [{} {}|{}|{}|{}], dts={}, size={}",
                    fmt::format_sound_format(tag.audio_tag.audio_tag_header.sound_format),
                    fmt::format_audio_packet_type(tag.audio_tag.audio_tag_header.packet_type),
                    fmt::format_sound_rate(tag.audio_tag.audio_tag_header.sound_rate),
                    fmt::format_sound_size(tag.audio_tag.audio_tag_header.sound_size),
                    fmt::format_sound_type(tag.audio_tag.audio_tag_header.sound_type),
                    tag.audio_tag.timestamp, tag.audio_tag.data_size);
        } else if (tag.type == TagType::video) {
            if (tag.video_tag.video_tag_header.ext_header) {
                return std::format("Video: [{} {}|{}], enhanced, dts={}, cts={}, size={}",
                    fmt::format_video_codec_id(tag.video_tag.video_tag_header.codec_id),
                    fmt::format_video_frame_type(tag.video_tag.video_tag_header.frame_type),
                    fmt::format_video_enhanced_packet_type(tag.video_tag.video_tag_header.packet_type),
                    tag.video_tag.timestamp, tag.video_tag.video_tag_header.composition_time,
                    tag.video_tag.data_size);
            } else {
                return std::format("Video: [{} {}|{}], dts={}, cts={}, size={}",
                    fmt::format_video_codec_id(tag.video_tag.video_tag_header.codec_id),
                    fmt::format_video_frame_type(tag.video_tag.video_tag_header.frame_type),
                    fmt::format_video_packet_type(tag.video_tag.video_tag_header.packet_type),
                    tag.video_tag.timestamp, tag.video_tag.video_tag_header.composition_time,
                    tag.video_tag.data_size);
            }
        } else {
            return std::format("Script: dts={}, size={}", tag.script_tag.timestamp,
                tag.script_tag.data_size);
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
            return "Not Known";
        }
    };

    fn format_video_packet_type(u8 value) {
        if (value == VideoPacketType::sequence_header) {
            return "Sequence Header";
        } else if (value == VideoPacketType::nalu) {
            return "NALU or OBU (vvc)";
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

    fn format_hevc_nalu_type(u8 value) {
        if (value == 0) {
            return "TRAIL_N";
        } else if (value == 1) {
            return "TRAIL_R";
        } else if (value == 2) {
            return "TSA_N";
        } else if (value == 3) {
            return "TSA_R";
        } else if (value == 4) {
            return "STSA_N";
        } else if (value == 5) {
            return "STSA_R";
        } else if (value == 6) {
            return "RADL_N";
        } else if (value == 7) {
            return "RADL_R";
        } else if (value == 8) {
            return "RASL_N";
        } else if (value == 9) {
            return "RASL_R";
        } else if (value >= 10 && value <= 15) {
            return std::format("Reserved VCL{}", value);
        } else if (value == 16) {
            return "BLA_W_LP";
        } else if (value == 17) {
            return "BLA_W_RADL";
        } else if (value == 18) {
            return "BLA_N_LP";
        } else if (value == 19) {
            return "IDR_R_RADL";
        } else if (value == 20) {
            return "IDR_N_LP";
        } else if (value == 21) {
            return "CRA_NUT";
        } else if (value == 22) {
            return "RSV_IRAP_VLC22";
        } else if (value == 23) {
            return "RSV_IRAP_VLC23";
        } else if (value >= 24 && value <= 31) {
            return std::format("Reserved VCL");
        } else if (value == 32) {
            return "VPS";
        } else if (value == 33) {
            return "SPS";
        } else if (value == 34) {
            return "PPS";
        } else if (value == 35) {
            return "AUD";
        } else if (value == 36) {
            return "EOS_NUT";
        } else if (value == 37) {
            return "EOB_NUT";
        } else if (value == 38) {
            return "FD_NUT";
        } else if (value == 39) {
            return "SEI_PREFIX";
        } else if (value == 40) {
            return "SEI_SUFFIX";
        } else if (value >= 41 && value <= 47) {
            return std::format("RSV_NVCL{}", value);
        } else if (value >= 48 && value <= 63) {
            return std::format("UNSPEC{}", value);
        } else {
            return std::format("ILL{}", value);
        }
    };

    fn format_avc_nalu_header(ref AvcNaluHeader hdr) {
        return std::format("AVC NALU Header [nal_unit_type={}]",
            fmt::format_avc_nalu_type(hdr.nal_unit_type));
    };

    fn format_hevc_nalu_header(ref HevcNaluHeader hdr) {
        return std::format("HEVC NALU Header [nal_unit_type={}]",
            fmt::format_hevc_nalu_type(hdr.nal_unit_type));
    };

    fn format_avc_nalu(ref AvcNalu nalu) {
        return std::format("AVC NALU: {}, size={}",
            fmt::format_avc_nalu_header(nalu.avc_nalu_header), nalu.nalu_length);
    };

    fn format_hevc_nalu(ref HevcNalu nalu) {
        return std::format("HEVC NALU: {}, size={}",
            fmt::format_hevc_nalu_header(nalu.hevc_nalu_header), nalu.nalu_length);
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
    u32 previous_tag_size;
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

bitfield AudioTagHeaderBits {
    sound_format : 4 [[format("fmt::format_sound_format")]];
    sound_rate : 2 [[format("fmt::format_sound_rate")]];
    sound_size : 1 [[format("fmt::format_sound_size")]];
    sound_type : 1 [[format("fmt::format_sound_type")]];
};

struct AudioTagHeader {
    AudioTagHeaderBits bits [[inline]];
    u8 sound_format = bits.sound_format;
    u8 sound_rate = bits.sound_rate;
    u8 sound_size = bits.sound_size;
    u8 sound_type = bits.sound_type;

    if (bits.sound_format == 10) {
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
    end_of_sequence = 2,
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

bitfield AvcNaluHeader {
    forbidden_zero_bit : 1;
    nal_ref_idc : 2;
    nal_unit_type : 5 [[format("fmt::format_avc_nalu_type")]];;
} [[name("AVC NALU Header"),format("fmt::format_avc_nalu_header")]];

bitfield HevcNaluHeader {
    forbidden_zero_bit : 1;
    nal_unit_type : 6;
    nuh_layer_id : 6;
    nuh_temporal_id_plus1 : 3;
} [[name("HEVC NALU Header"),format("fmt::format_hevc_nalu_header")]];

bitfield AvcDecoderConfigurationLengths {
    reserved0 : 6;
    lengthSizeMinusOne : 2;
    reserved1 : 3;
    numOfSequenceParameterSets : 5;
};

//
// AvcSpsNalu - H.264 (AVC) SPS parsing
//
struct AvcSpsNalu {
    u16 nalu_length [[name("AVC SPS NALU Length")]];
    u32 end = $ + nalu_length;
    u32 remaining_bytes = nalu_length;

    AvcNaluHeader avc_nalu_header;

    u64 combo = 0u;
    remaining_bytes -= 1;

    // profile_idc (u8), constraint flags (u8), level_idc (u8)
    u8 profile_idc;
    u8 constraint_set_flags;
    u8 level_idc;

    std::print("SPS: profile_idc={}, constraint_flags=0x{:02x}, level_idc={}",
        profile_idc, constraint_set_flags, level_idc);

    remaining_bytes -= 3;

    // seq_parameter_set_id (ue(v))
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 seq_parameter_set_id = combo >> 32;
    std::print("SPS: seq_parameter_set_id={}, bitoff={}", seq_parameter_set_id, u32(combo));

    // chroma_format_idc and related fields for certain profiles
    u32 chroma_format_idc = 1u;
    u32 separate_colour_plane_flag = 0u;
    if (profile_idc == 100u || profile_idc == 110u || profile_idc == 122u || profile_idc == 144u) {
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        chroma_format_idc = combo >> 32;
        std::print("SPS: chroma_format_idc={}, bitoff={}", chroma_format_idc, u32(combo));

        if (chroma_format_idc == 3u) {
            combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
            separate_colour_plane_flag = combo >> 32;
            std::print("SPS: separate_colour_plane_flag={}, bitoff={}",
                separate_colour_plane_flag, u32(combo));
        }
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        std::print("SPS: bit_depth_luma_minus8={}, bitoff={}", combo >> 32, u32(combo));
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        std::print("SPS: bit_depth_chroma_minus8={}, bitoff={}", combo >> 32, u32(combo));
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
        std::print("SPS: qpprime_y_zero_transform_bypass_flag={}, bitoff={}",
            combo >> 32, u32(combo));
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
        std::print("SPS: seq_scaling_matrix_present_flag={}, bitoff={}",
            combo >> 32, u32(combo));
        u32 seq_scaling_matrix_present_flag = combo >> 32;
        if (seq_scaling_matrix_present_flag == 1u) {
            std::print("SPS: seq_scaling_matrix present - skipping detailed parse");
            // scaling lists omitted (opaque)
        }
    }

    // log2_max_frame_num_minus4 (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    std::print("SPS: log2_max_frame_num_minus4={}, bitoff={}", combo >> 32, u32(combo));

    // pic_order_cnt_type (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 pic_order_cnt_type = combo >> 32;
    std::print("SPS: pic_order_cnt_type={}, bitoff={}", pic_order_cnt_type, u32(combo));

    if (pic_order_cnt_type == 0u) {
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        std::print("SPS: log2_max_pic_order_cnt_lsb_minus4={}, bitoff={}",
            combo >> 32, u32(combo));
    } else if (pic_order_cnt_type == 1u) {
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
        std::print("SPS: delta_pic_order_always_zero_flag={}, bitoff={}",
            combo >> 32, u32(combo));
        combo = expgolomb::read_se($, remaining_bytes, u32(combo));
        std::print("SPS: offset_for_non_ref_pic={}, bitoff={}",
            s32(combo >> 32), u32(combo));
        combo = expgolomb::read_se($, remaining_bytes, u32(combo));
        std::print("SPS: offset_for_top_to_bottom_field={}, bitoff={}",
            s32(combo >> 32), u32(combo));
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        u32 num_ref_frames_in_pic_order_cnt_cycle = combo >> 32;
        std::print("SPS: num_ref_frames_in_pic_order_cnt_cycle={}, bitoff={}",
            num_ref_frames_in_pic_order_cnt_cycle, u32(combo));
        // Delegate skipping offset_for_ref_frame[] SE entries to helper (no for/while inside struct)
        combo = helpers::skip_avc_offset_for_ref_frames(combo, remaining_bytes, num_ref_frames_in_pic_order_cnt_cycle);
    }

    // max_num_ref_frames (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    std::print("SPS: max_num_ref_frames={}, bitoff={}", combo >> 32, u32(combo));

    // gaps_in_frame_num_value_allowed_flag (u1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    std::print("SPS: gaps_in_frame_num_value_allowed_flag={}, bitoff={}", combo >> 32, u32(combo));

    // pic_width_in_mbs_minus1 (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 pic_width_in_mbs_minus1 = combo >> 32;
    std::print("SPS: pic_width_in_mbs_minus1={}, bitoff={}", pic_width_in_mbs_minus1, u32(combo));

    // pic_height_in_map_units_minus1 (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 pic_height_in_map_units_minus1 = combo >> 32;
    std::print("SPS: pic_height_in_map_units_minus1={}, bitoff={}", pic_height_in_map_units_minus1, u32(combo));

    // frame_mbs_only_flag (u1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 frame_mbs_only_flag = combo >> 32;
    std::print("SPS: frame_mbs_only_flag={}, bitoff={}", frame_mbs_only_flag, u32(combo));
    if (frame_mbs_only_flag == 0u) {
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
        std::print("SPS: mb_adaptive_frame_field_flag={}, bitoff={}", combo >> 32, u32(combo));
    }

    // direct_8x8_inference_flag (u1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    std::print("SPS: direct_8x8_inference_flag={}, bitoff={}", combo >> 32, u32(combo));

    // frame_cropping_flag + offsets
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 frame_cropping_flag = combo >> 32;
    u32 frame_crop_left_offset = 0u;
    u32 frame_crop_right_offset = 0u;
    u32 frame_crop_top_offset = 0u;
    u32 frame_crop_bottom_offset = 0u;
    if (frame_cropping_flag == 1u) {
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo)); frame_crop_left_offset = combo >> 32;
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo)); frame_crop_right_offset = combo >> 32;
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo)); frame_crop_top_offset = combo >> 32;
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo)); frame_crop_bottom_offset = combo >> 32;
        std::print("SPS: frame_crop offsets l={},r={},t={},b={}, bitoff={}",
            frame_crop_left_offset, frame_crop_right_offset, frame_crop_top_offset, frame_crop_bottom_offset, u32(combo));
    }

    // derived/display values (AVC uses macroblocks)
    u32 pic_width_in_mbs = pic_width_in_mbs_minus1 + 1u;
    u32 pic_height_in_map_units = pic_height_in_map_units_minus1 + 1u;
    u32 frame_height_in_mbs = (2u - frame_mbs_only_flag) * pic_height_in_map_units;
    u32 width = pic_width_in_mbs * 16u;
    u32 height = frame_height_in_mbs * 16u;

    u32 crop_unit_x = 1u;
    u32 crop_unit_y = 2u - frame_mbs_only_flag;
    if (chroma_format_idc == 1u) { // 4:2:0
        crop_unit_x = 2u;
        crop_unit_y = 2u * (2u - frame_mbs_only_flag);
    } else if (chroma_format_idc == 2u) { // 4:2:2
        crop_unit_x = 2u;
        crop_unit_y = 2u - frame_mbs_only_flag;
    } else if (chroma_format_idc == 0u) {
        crop_unit_x = 1u;
        crop_unit_y = 2u - frame_mbs_only_flag;
    }

    u32 display_width = width - (frame_crop_left_offset + frame_crop_right_offset) * crop_unit_x;
    u32 display_height = height - (frame_crop_top_offset + frame_crop_bottom_offset) * crop_unit_y;

    std::print("SPS: width*height={}x{}, display_width*display_height={}x{}",
        width, height, display_width, display_height);

    std::print("SPS: --- length={}, end={}, $={}, end-$={}, remaining={}, bitoff={}",
        nalu_length, end, $, end - $, remaining_bytes, u32(combo));

    u8 opaque[end - $];
};

//
// AvcPpsNalu - H.264 (AVC) PPS parsing
// - No boundary checks, follows H.264 pic_parameter_set_rbsp syntax
//
struct AvcPpsNalu {
    u16 nalu_length [[name("PPS NALU Length")]];
    u32 end = $ + nalu_length;

    u64 combo = 0u;
    u32 remaining_bytes = nalu_length;

    // AVC NAL header
    AvcNaluHeader avc_nalu_header;
    remaining_bytes -= 1;

    // pic_parameter_set_id (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 pic_parameter_set_id = combo >> 32;
    std::print("PPS: pic_parameter_set_id={}, bitoff={}", pic_parameter_set_id, u32(combo));

    // seq_parameter_set_id (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 seq_parameter_set_id = combo >> 32;
    std::print("PPS: seq_parameter_set_id={}, bitoff={}", seq_parameter_set_id, u32(combo));

    // entropy_coding_mode_flag (u1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    std::print("PPS: entropy_coding_mode_flag={}, bitoff={}", combo >> 32, u32(combo));

    // bottom_field_pic_order_in_frame_present_flag (u1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    std::print("PPS: bottom_field_pic_order_in_frame_present_flag={}, bitoff={}", combo >> 32, u32(combo));

    // num_slice_groups_minus1 (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 num_slice_groups_minus1 = combo >> 32;
    std::print("PPS: num_slice_groups_minus1={}, bitoff={}", num_slice_groups_minus1, u32(combo));

    if (num_slice_groups_minus1 > 0u) {
        // slice_group_map_type (ue) and use helper to consume group map syntax
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        u32 slice_group_map_type = combo >> 32;
        std::print("PPS: slice_group_map_type={}, bitoff={}", slice_group_map_type, u32(combo));
        combo = helpers::skip_avc_pps_slice_group_map(combo, remaining_bytes, slice_group_map_type, num_slice_groups_minus1);
        std::print("PPS: slice_group_map consumed, bitoff={}", u32(combo));
    }

    // num_ref_idx_l0_default_active_minus1 (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    std::print("PPS: num_ref_idx_l0_default_active_minus1={}, bitoff={}", u32(combo >> 32), u32(combo));

    // num_ref_idx_l1_default_active_minus1 (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    std::print("PPS: num_ref_idx_l1_default_active_minus1={}, bitoff={}", u32(combo >> 32), u32(combo));

    // weighted_pred_flag (u1), weighted_bipred_idc (u2)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    std::print("PPS: weighted_pred_flag={}, bitoff={}", combo >> 32, u32(combo));
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 2);
    std::print("PPS: weighted_bipred_idc={}, bitoff={}", combo >> 32, u32(combo));

    // pic_init_qp_minus26 (se)
    combo = expgolomb::read_se($, remaining_bytes, u32(combo));
    s32 pic_init_qp_minus26 = s32(combo >> 32);
    std::print("PPS: pic_init_qp_minus26={}, bitoff={}", pic_init_qp_minus26, u32(combo));

    // pic_init_qs_minus26 (se) and chroma_qp_index_offset (se)
    combo = expgolomb::read_se($, remaining_bytes, u32(combo));
    std::print("PPS: pic_init_qs_minus26={}, bitoff={}", s32(combo >> 32), u32(combo));
    combo = expgolomb::read_se($, remaining_bytes, u32(combo));
    std::print("PPS: chroma_qp_index_offset={}, bitoff={}", s32(combo >> 32), u32(combo));

    // deblocking_filter_control_present_flag (u1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 deblocking_filter_control_present_flag = u32(combo >> 32);
    std::print("PPS: deblocking_filter_control_present_flag={}, bitoff={}", deblocking_filter_control_present_flag, u32(combo));

    // constrained_intra_pred_flag (u1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    std::print("PPS: constrained_intra_pred_flag={}, bitoff={}", combo >> 32, u32(combo));

    // redundant_pic_cnt_present_flag (u1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    std::print("PPS: redundant_pic_cnt_present_flag={}, bitoff={}", combo >> 32, u32(combo));

    // optional transform_8x8_mode_flag and pic_scaling_matrix_present_flag (if present)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    std::print("PPS: transform_8x8_mode_flag (optional)={}, bitoff={}", combo >> 32, u32(combo));
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 pic_scaling_matrix_present_flag = combo >> 32;
    std::print("PPS: pic_scaling_matrix_present_flag (optional)={}, bitoff={}", pic_scaling_matrix_present_flag, u32(combo));
    if (pic_scaling_matrix_present_flag == 1u) {
        std::print("PPS: pic_scaling_matrix present - skipping detailed parse");
    }

    std::print("PPS: --- length={}, end={}, $={}, end-$={}, remaining={}, bitoff={}",
        nalu_length, end, $, end - $, remaining_bytes, u32(combo));

    u8 opaque[end - $];
};

bitfield AvcSPSNaluExtBits {
    reserved0 : 6;
    chroma_format : 2;
    reserved1 : 5;
    bit_depth_luma_minus8 : 3;
    reserved2 : 5;
    bit_depth_chroma_minus8 : 3;
};

struct AvcSpsNaluExt {
    u16 nalu_length [[name("SPS NALU Extension Length")]];
    u32 end = $ + nalu_length;
    u32 remaining_bytes = nalu_length;

    AvcNaluHeader avc_nalu_header;
    remaining_bytes -= 1;

    u64 combo = 0u;

    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    std::print("SPS Ext: seq_parameter_set_id={}, bitoff={}", u32(combo >> 32), u32(combo));

    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 aux_format_idc = u32(combo >> 32);
    std::print("SPS Ext: aux_format_idc={}, bitoff={}", aux_format_idc, u32(combo));

    if (aux_format_idc != 0u) {
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        std::print("SPS Ext: bit_depth_aux_minus8={}, bitoff={}", u32(combo >> 32), u32(combo));

        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
        std::print("SPS Ext: alpha_incr_flag={}, bitoff={}", u32(combo >> 32), u32(combo));

        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        std::print("SPS Ext: alpha_opaque_value={}, bitoff={}", u32(combo >> 32), u32(combo));

        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        std::print("SPS Ext: alpha_transparent_value={}, bitoff={}", u32(combo >> 32), u32(combo));
    }

    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    std::print("SPS Ext: additional_extension_flag={}, bitoff={}", u32(combo >> 32), u32(combo));

    std::print("SPS Ext: --- length={}, end={}, $={}, end-$={}, remaining={}, bitoff={}",
        nalu_length, end, $, end - $, remaining_bytes, u32(combo));

    u8 opaque[end - $] [[hidden]];
} [[name("SPS NALU Extension")]];

struct HevcSpsNalu {
    u16 nalu_length [[name("SPS NALU Length")]];
    u32 end = $ + nalu_length;
    u32 remaining_bytes = nalu_length;

    HevcNaluHeader hevc_nalu_header;
    remaining_bytes -= 2;

    u64 combo = 0u;

    // --- SPS fixed fields before profile_tier_level ---
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 4);
    u32 sps_video_parameter_set_id = combo >> 32;
    std::print("SPS: sps_video_parameter_set_id={}, bitoff={}", sps_video_parameter_set_id, u32(combo));

    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 3);
    u32 max_sub_layers_minus1 = combo >> 32;
    std::print("SPS: max_sub_layers_minus1={}, bitoff={}", max_sub_layers_minus1, u32(combo));

    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 sps_temporal_id_nesting_flag = combo >> 32;
    std::print("SPS: sps_temporal_id_nesting_flag={}, bitoff={}", sps_temporal_id_nesting_flag, u32(combo));

    // --- profile_tier_level( general, max_sub_layers_minus1 ) ---
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 2);
    u32 general_profile_space = combo >> 32;
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 general_tier_flag = combo >> 32;
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 5);
    u32 general_profile_idc = combo >> 32;
    std::print("PTL: general_profile_space={}, general_tier_flag={}, general_profile_idc={}, bitoff={}",
        general_profile_space, general_tier_flag, general_profile_idc, u32(combo));

    // general_profile_compatibility_flags[32] and general_constraint_indicator_flags[48]
    combo = helpers::parse_vps_sps_profile_compat_and_constraints(combo, remaining_bytes);

    // general_level_idc (8 bits)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 8);
    u32 general_level_idc = combo >> 32;
    std::print("PTL: general_level_idc={}, bitoff={}", general_level_idc, u32(combo));

    // Parse sub-layers flags and fields via helper (avoids for/while inside struct)
    combo = helpers::parse_vps_profile_tier_sublayers(combo, remaining_bytes, max_sub_layers_minus1);

    // --- Begin main SPS fields (HEVC) ---
    // sps_seq_parameter_set_id (UE)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 sps_seq_parameter_set_id = combo >> 32;
    std::print("SPS: sps_seq_parameter_set_id={}, bitoff={}", sps_seq_parameter_set_id, u32(combo));

    // chroma_format_idc (UE)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 chroma_format_idc = combo >> 32;
    std::print("SPS: chroma_format_idc={}, bitoff={}", chroma_format_idc, u32(combo));

    // if chroma_format_idc == 3 -> separate_colour_plane_flag (1)
    if (chroma_format_idc == 3u) {
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
        u32 separate_colour_plane_flag = combo >> 32;
        std::print("SPS: separate_colour_plane_flag={}, bitoff={}", separate_colour_plane_flag, u32(combo));
    }

    // pic_width_in_luma_samples (UE)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 pic_width_in_luma_samples = combo >> 32;
    std::print("SPS: pic_width_in_luma_samples={}, bitoff={}", pic_width_in_luma_samples, u32(combo));

    // pic_height_in_luma_samples (UE)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 pic_height_in_luma_samples = combo >> 32;
    std::print("SPS: pic_height_in_luma_samples={}, bitoff={}", pic_height_in_luma_samples, u32(combo));

    // conformance_window_flag (1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 conformance_window_flag = combo >> 32;
    std::print("SPS: conformance_window_flag={}, bitoff={}", conformance_window_flag, u32(combo));

    u32 conf_win_left_offset = 0u;
    u32 conf_win_right_offset = 0u;
    u32 conf_win_top_offset = 0u;
    u32 conf_win_bottom_offset = 0u;
    if (conformance_window_flag == 1u) {
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        conf_win_left_offset = combo >> 32;
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        conf_win_right_offset = combo >> 32;
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        conf_win_top_offset = combo >> 32;
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        conf_win_bottom_offset = combo >> 32;
        std::print("SPS: conf_win offsets L/R/T/B = {}/{}/{}/{} bitoff={}",
            conf_win_left_offset, conf_win_right_offset, conf_win_top_offset, conf_win_bottom_offset, u32(combo));
    }

    // bit_depth_luma_minus8 (UE)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 bit_depth_luma_minus8 = combo >> 32;
    std::print("SPS: bit_depth_luma_minus8={}, bitoff={}", bit_depth_luma_minus8, u32(combo));

    // bit_depth_chroma_minus8 (UE)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 bit_depth_chroma_minus8 = combo >> 32;
    std::print("SPS: bit_depth_chroma_minus8={}, bitoff={}", bit_depth_chroma_minus8, u32(combo));

    // --- compute derived/display values ---
    // For HEVC, pic_*_in_luma_samples are already in luma samples (pixels)
    u32 width = pic_width_in_luma_samples;
    u32 height = pic_height_in_luma_samples;

    // determine chroma subsampling (subWidthC, subHeightC)
    u32 subWidthC = 1u;
    u32 subHeightC = 1u;
    if (chroma_format_idc == 1u) { // 4:2:0
        subWidthC = 2u;
        subHeightC = 2u;
    } else if (chroma_format_idc == 2u) { // 4:2:2
        subWidthC = 2u;
        subHeightC = 1u;
    } else if (chroma_format_idc == 3u) { // 4:4:4
        subWidthC = 1u;
        subHeightC = 1u;
    } else { // monochrome or unspecified -> default to 1,1
        subWidthC = 1u;
        subHeightC = 1u;
    }

    // crop units per HEVC: offsets are in units of subWidthC/subHeightC
    u32 crop_unit_x = subWidthC;
    u32 crop_unit_y = subHeightC;

    u32 display_width = width;
    u32 display_height = height;
    if (conformance_window_flag == 1u) {
        display_width = width - (conf_win_left_offset + conf_win_right_offset) * crop_unit_x;
        display_height = height - (conf_win_top_offset + conf_win_bottom_offset) * crop_unit_y;
    }

    std::print("SPS: width*height={}x{}, display_width*display_height={}x{}",
        width, height, display_width, display_height);
    std::print("SPS: bit_depths(luma/chroma)={}+8/{}+8 => {}bpp (approx), bitoff={}",
        bit_depth_luma_minus8, bit_depth_chroma_minus8, (bit_depth_luma_minus8 + 8u), u32(combo));

    std::print("SPS: --- length={}, end={}, $={}, end-$={}, remaining={}, bitoff={}",
        nalu_length, end, $, end - $, remaining_bytes, u32(combo));

    // leave remaining bytes as opaque payload
    u8 opaque[end - $];
} [[name("HEVC SPS NALU")]];

struct HevcPpsNalu {
    u16 nalu_length [[name("PPS NALU Length")]];
    u32 end = $ + nalu_length;

    u64 combo = 0u;
    u32 remaining_bytes = nalu_length;

    HevcNaluHeader hevc_nalu_header;
    remaining_bytes -= 2;

    // Parse core PPS fields (basic subset) according to HEVC spec (7.3.3)
    // Keep complexity manageable: parse essential fields, skip complex optional tables.
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo)); // pps_pic_parameter_set_id
    u32 pps_pic_parameter_set_id = u32(combo >> 32);
    std::print("PPS: pps_pic_parameter_set_id={}, bitoff={}", pps_pic_parameter_set_id, u32(combo));

    combo = expgolomb::read_ue($, remaining_bytes, u32(combo)); // pps_seq_parameter_set_id
    u32 pps_seq_parameter_set_id = u32(combo >> 32);
    std::print("PPS: pps_seq_parameter_set_id={}, bitoff={}", pps_seq_parameter_set_id, u32(combo));

    // dependent_slice_segments_enabled_flag (1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 dependent_slice_segments_enabled_flag = combo >> 32;
    std::print("PPS: dependent_slice_segments_enabled_flag={}, bitoff={}", dependent_slice_segments_enabled_flag, u32(combo));

    // output_flag_present_flag (1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 output_flag_present_flag = combo >> 32;
    std::print("PPS: output_flag_present_flag={}, bitoff={}", output_flag_present_flag, u32(combo));

    // num_extra_slice_header_bits (3)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 3);
    u32 num_extra_slice_header_bits = combo >> 32;
    std::print("PPS: num_extra_slice_header_bits={}, bitoff={}", num_extra_slice_header_bits, u32(combo));

    // sign_data_hiding_enabled_flag (1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 sign_data_hiding_enabled_flag = combo >> 32;
    std::print("PPS: sign_data_hiding_enabled_flag={}, bitoff={}", sign_data_hiding_enabled_flag, u32(combo));

    // cabac_init_present_flag (1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 cabac_init_present_flag = combo >> 32;
    std::print("PPS: cabac_init_present_flag={}, bitoff={}", cabac_init_present_flag, u32(combo));

    // num_ref_idx_l0_default_active_minus1 (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 num_ref_idx_l0_default_active_minus1 = combo >> 32;
    std::print("PPS: num_ref_idx_l0_default_active_minus1={}, bitoff={}", num_ref_idx_l0_default_active_minus1, u32(combo));

    // num_ref_idx_l1_default_active_minus1 (ue)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 num_ref_idx_l1_default_active_minus1 = combo >> 32;
    std::print("PPS: num_ref_idx_l1_default_active_minus1={}, bitoff={}", num_ref_idx_l1_default_active_minus1, u32(combo));

    // init_qp_minus26 (se)
    combo = expgolomb::read_se($, remaining_bytes, u32(combo));
    s32 init_qp_minus26 = s32(combo >> 32);
    std::print("PPS: init_qp_minus26={}, bitoff={}", init_qp_minus26, u32(combo));

    // constrained_intra_pred_flag (1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 constrained_intra_pred_flag = combo >> 32;
    std::print("PPS: constrained_intra_pred_flag={}, bitoff={}", constrained_intra_pred_flag, u32(combo));

    // transform_skip_enabled_flag (1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 transform_skip_enabled_flag = combo >> 32;
    std::print("PPS: transform_skip_enabled_flag={}, bitoff={}", transform_skip_enabled_flag, u32(combo));

    // cu_qp_delta_enabled_flag (1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 cu_qp_delta_enabled_flag = combo >> 32;
    std::print("PPS: cu_qp_delta_enabled_flag={}, bitoff={}", cu_qp_delta_enabled_flag, u32(combo));

    // if cu_qp_delta_enabled_flag then diff_cu_qp_delta_depth (ue)
    if (cu_qp_delta_enabled_flag == 1u) {
        combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
        u32 diff_cu_qp_delta_depth = combo >> 32;
        std::print("PPS: diff_cu_qp_delta_depth={}, bitoff={}", diff_cu_qp_delta_depth, u32(combo));
    }

    // pps_cb_qp_offset (se) and pps_cr_qp_offset (se)
    combo = expgolomb::read_se($, remaining_bytes, u32(combo));
    std::print("PPS: pps_cb_qp_offset={}, bitoff={}", s32(combo >> 32), u32(combo));
    combo = expgolomb::read_se($, remaining_bytes, u32(combo));
    std::print("PPS: pps_cr_qp_offset={}, bitoff={}", s32(combo >> 32), u32(combo));

    // pps_slice_chroma_qp_offsets_present_flag (1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 pps_slice_chroma_qp_offsets_present_flag = combo >> 32;
    std::print("PPS: pps_slice_chroma_qp_offsets_present_flag={}, bitoff={}", pps_slice_chroma_qp_offsets_present_flag, u32(combo));

    // weighted_pred_flag / weighted_bipred_flag (if present in spec variants) - skip/opaque for now
    // many other optional fields (tiles, loop filters, scaling lists, etc) are complex; skip them
    std::print("PPS: --- skipping optional tables");
    std::print("PPS: --- length={}, end={}, $={}, end-$={}, remaining={}, bitoff={}",
        nalu_length, end, $, end - $, remaining_bytes, u32(combo));

    // leave remaining bytes as opaque payload
    u8 opaque[end - $];
};

struct HevcVpsNalu {
    u16 nalu_length [[name("VPS NALU Length")]];
    u32 end = $ + nalu_length;

    u64 combo = 0u;
    u32 remaining_bytes = nalu_length;

    // VPS primarily applies to HEVC (codec 265). Read and skip NAL header(s) as needed.
    HevcNaluHeader hevc_nalu_header;
    remaining_bytes -= 2;

    // Begin parsing VPS RBSP fields according to HEVC spec (7.3.2.1)
    // vps_video_parameter_set_id: u(4)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 4);
    u32 vps_video_parameter_set_id = combo >> 32;
    std::print("VPS: vps_video_parameter_set_id={}, bitoff={}", vps_video_parameter_set_id, u32(combo));

    // vps_reserved_three_2bits: u(2) (should be '11')
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 2);
    u32 vps_reserved_three_2bits = combo >> 32;
    std::print("VPS: vps_reserved_three_2bits=0x{:x}, bitoff={}", vps_reserved_three_2bits, u32(combo));

    // vps_max_layers_minus1: u(6)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 6);
    u32 vps_max_layers_minus1 = combo >> 32;
    std::print("VPS: vps_max_layers_minus1={}, bitoff={}", vps_max_layers_minus1, u32(combo));

    // vps_max_sub_layers_minus1: u(3)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 3);
    u32 vps_max_sub_layers_minus1 = combo >> 32;
    std::print("VPS: vps_max_sub_layers_minus1={}, bitoff={}", vps_max_sub_layers_minus1, u32(combo));

    // vps_temporal_id_nesting_flag: u(1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 vps_temporal_id_nesting_flag = combo >> 32;
    std::print("VPS: vps_temporal_id_nesting_flag={}, bitoff={}", vps_temporal_id_nesting_flag, u32(combo));

    // vps_reserved_0xffff_16bits: u(16)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 16);
    u32 vps_reserved_0xffff_16bits = combo >> 32;
    std::print("VPS: vps_reserved_0xffff_16bits=0x{:x}, bitoff={}", vps_reserved_0xffff_16bits, u32(combo));

    // profile_tier_level(1, vps_max_sub_layers_minus1)
    // Parse general profile/tier/level fields (basic subset sufficient for identification)
    // general_profile_space: u(2)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 2);
    u32 general_profile_space = combo >> 32;
    std::print("VPS: general_profile_space={}, bitoff={}", general_profile_space, u32(combo));

    // general_tier_flag: u(1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 general_tier_flag = combo >> 32;
    std::print("VPS: general_tier_flag={}, bitoff={}", general_tier_flag, u32(combo));

    // general_profile_idc: u(5)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 5);
    u32 general_profile_idc = combo >> 32;
    std::print("VPS: general_profile_idc={}, bitoff={}", general_profile_idc, u32(combo));

    // general_profile_compatibility_flags[32] and general_constraint_indicator_flags[48]
    combo = helpers::parse_vps_sps_profile_compat_and_constraints(combo, remaining_bytes);

    // general_level_idc: u(8)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 8);
    u32 general_level_idc = combo >> 32;
    std::print("VPS: general_level_idc={}, bitoff={}", general_level_idc, u32(combo));

    // Use helper to parse sub-layer flags and per-sub-layer profile/level fields
    combo = helpers::parse_vps_profile_tier_sublayers(combo, remaining_bytes, vps_max_sub_layers_minus1);

    // vps_sub_layer_ordering_info_present_flag: u(1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 vps_sub_layer_ordering_info_present_flag = combo >> 32;
    std::print("VPS: vps_sub_layer_ordering_info_present_flag={}, bitoff={}", vps_sub_layer_ordering_info_present_flag, u32(combo));

    // parse vps_max_dec_pic_buffering_minus1[i], vps_max_num_reorder_pics[i], vps_max_latency_increase_plus1[i]
    combo = helpers::parse_vps_sub_layer_ordering_info(combo, remaining_bytes, vps_sub_layer_ordering_info_present_flag, vps_max_sub_layers_minus1);

    // vps_max_layer_id: u(6)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 6);
    u32 vps_max_layer_id = combo >> 32;
    std::print("VPS: vps_max_layer_id={}, bitoff={}", vps_max_layer_id, u32(combo));

    // vps_num_layer_sets_minus1: ue(v)
    combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
    u32 vps_num_layer_sets_minus1 = combo >> 32;
    std::print("VPS: vps_num_layer_sets_minus1={}, bitoff={}", vps_num_layer_sets_minus1, u32(combo));

    // use helper to parse layer sets table (loops moved out of struct)
    combo = helpers::parse_vps_layer_sets(combo, remaining_bytes, vps_num_layer_sets_minus1, vps_max_layer_id);

    // vps_timing_info_present_flag: u(1)
    combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
    u32 vps_timing_info_present_flag = combo >> 32;
    std::print("VPS: vps_timing_info_present_flag={}, bitoff={}", vps_timing_info_present_flag, u32(combo));

    if (vps_timing_info_present_flag == 1u) {
        // vps_num_units_in_tick: u(32)
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 32);
        u32 vps_num_units_in_tick = combo >> 32;
        // vps_time_scale: u(32)
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 32);
        u32 vps_time_scale = combo >> 32;
        // vps_poc_proportional_to_timing_flag: u(1)
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
        u32 vps_poc_proportional_to_timing_flag = combo >> 32;
        std::print("VPS: timing num_units_in_tick={}, time_scale={}, poc_proportional_flag={}, bitoff={}",
            vps_num_units_in_tick, vps_time_scale, vps_poc_proportional_to_timing_flag, u32(combo));
        if (vps_poc_proportional_to_timing_flag == 1u) {
            combo = expgolomb::read_ue($, remaining_bytes, u32(combo));
            std::print("VPS: vps_num_ticks_poc_diff_one_minus1={}, bitoff={}", combo >> 32, u32(combo));
        }
    }

    // For robustness read vps_extension_flag at end (u(1)) if present before RBSP trailing bits
    // Try to read if bits remain
    if (u32(combo) + 1u <= remaining_bytes * 8u) {
        combo = expgolomb::read_bits($, remaining_bytes, u32(combo), 1);
        u32 vps_extension_flag = combo >> 32;
        std::print("VPS: vps_extension_flag={}, bitoff={}", vps_extension_flag, u32(combo));
    }

    std::print("VPS: --- length={}, end={}, $={}, end-$={}, remaining={}, bitoff={}",
        nalu_length, end, $, end - $, remaining_bytes, u32(combo));

    // keep remaining payload opaque to avoid parsing errors for lesser-used extensions
    u8 opaque[end - $];
} [[name("Hevc PPS NALU")]];

struct AvcDecoderConfigurationRecord {
    u8 configurationVersion;
    u8 AvcProfileIndication;
    u8 profile_compatibility;
    u8 AvcLevelIndication;

    AvcDecoderConfigurationLengths lengths [[inline]];
    global_nalu_length_size = lengths.lengthSizeMinusOne + 1;

    // For AVC use AvcSpsNalu/AvcPpsNalu
    AvcSpsNalu sps[lengths.numOfSequenceParameterSets] [[inline]];
    u8 numOfPictureParameterSets;
    AvcPpsNalu pps[numOfPictureParameterSets] [[inline]];

    std::print("--- NALU_LENGTH_SIZE={}, AvcProfileIndication={}, $={}, end={}",
        global_nalu_length_size, AvcProfileIndication, $, parent.end);

    if (AvcProfileIndication != 66 && AvcProfileIndication != 77 && AvcProfileIndication != 88) {
        if ($ < parent.end) {
            AvcSPSNaluExtBits bits[[inline]];
            u8 numOfSequenceParameterSetExt;

            std::print("--- chroma_format={}, bit_depth_luma_minus8={}, numOfSequenceParameterSetExt={}",
                bits.chroma_format, bits.bit_depth_luma_minus8, numOfSequenceParameterSetExt);

            AvcSpsNaluExt sps_ext[numOfSequenceParameterSetExt];
        }
    }
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
} [[format("fmt::format_avc_nalu")]];

bitfield HevcDecoderConfigurationRecordBits {
    reserved0 : 4;
    min_spatial_segmentation_idc : 12;
    reserved1 : 6;
    parallelismType : 2;
    reserved2 : 6;
    chroma_format_idc : 2;
    reserved3 : 5;
    bit_depth_luma_minus8 : 3;
    reserved4 : 5;
    bit_depth_chroma_minus8 : 3;
    avgFrameRate : 16;
    constantFrameRate : 2;
    numTemporalLayers : 3;
    temporalIdNested : 1;
    lengthSizeMinusOne : 2;
    numOfArrays : 8;
};

bitfield HevcParameterSetNaluBits {
    array_completeness : 1;
    reserved : 1;
    nal_unit_type : 6;
};

struct HevcParameterSetNalu {
    HevcParameterSetNaluBits bits [[inline]];
    u16 numNalus;

    std::print("HevcParameterSetNalu: array_completeness={}, nal_unit_type={}, numNalus={}",
        bits.array_completeness, bits.nal_unit_type, numNalus);

    if (bits.nal_unit_type == 32) {
        HevcVpsNalu vps[numNalus];
    } else if (bits.nal_unit_type == 33) {
        HevcSpsNalu sps[numNalus];
    } else if (bits.nal_unit_type == 34) {
        HevcPpsNalu pps[numNalus];
    } else {
        u16 nalu_length;
        u8 opaque[nalu_length];
        std::print("HevcParameterSetNalu: nal_unit_type={}, length={}",
            fmt::format_hevc_nalu_type(bits.nal_unit_type), nalu_length);
    }
} [[name("HEVC Parameter Set NALU")]];

struct HevcDecoderConfigurationRecord {
    u8 configurationVersion;
    u8 general_profile_space_and_tier_and_idc;
    u32 general_profile_compatibility_flags;
    u48 general_constraint_indicator_flags;
    u8 general_level_idc;

    HevcDecoderConfigurationRecordBits bits[[inline]];

    global_nalu_length_size = bits.lengthSizeMinusOne + 1;

    std::print("HevcDecoderConfigurationRecordBits: nalu_length_size={}, numOfArrays={}",
        global_nalu_length_size, bits.numOfArrays);

    HevcParameterSetNalu ps[bits.numOfArrays] [[inline]];
} [[name("HevcDecoderConfigurationRecord")]];

struct HevcNalu {
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

    HevcNaluHeader hevc_nalu_header;

    u8 payload[end - $] [[name("HEVC NALU Payload")]];
} [[format("fmt::format_hevc_nalu")]];

bitfield VideoTagHeaderBits {
    ext_header : 1;
    frame_type : 3;
    codec_id_or_enhanced_packet_type : 4;
};

struct VideoTagHeader {
    VideoTagHeaderBits bits [[inline]];

    u8 ext_header = bits.ext_header;
    u8 frame_type = bits.frame_type;

    if (!ext_header) {
        u8 codec_id = bits.codec_id_or_enhanced_packet_type;

        if (codec_id == VideoCodecId::avc || codec_id == VideoCodecId::hevc
                || codec_id == VideoCodecId::av1 || codec_id == VideoCodecId::vvc) {
            u8 packet_type [[format("fmt::format_video_packet_type")]];
            s24 composition_time;
        } else {
            u8 packet_type = 255;
            s24 composition_time = 0;
        }
    } else {   // Enhanced RTMP
        u8 codec_id = VideoCodecId::hevc;
        u8 packet_type = bits.codec_id_or_enhanced_packet_type;
        char four_cc[4];    // hvc1, av01, av09

        if (four_cc[0] == 'h' && four_cc[1] == 'v' && four_cc[2] == 'c' && four_cc[3] == '1') {
            codec_id = VideoCodecId::hevc;
        } else if (four_cc[0] == 'a' && four_cc[1] == 'v' && four_cc[2] == '0' && four_cc[3] == '1') {
            codec_id = VideoCodecId::av1;
        }

        if (packet_type == 1) {
            s24 composition_time;
        } else {
            s24 composition_time = 0;
        }
    }
} [[name("Video Tag Header")]];

struct VideoTag : BaseTag {
    VideoTagHeader video_tag_header;

    if (video_tag_header.packet_type == VideoPacketType::sequence_header) {
        if (video_tag_header.codec_id == VideoCodecId::avc) {
            AvcDecoderConfigurationRecord avc_header;
        } else if (video_tag_header.codec_id == VideoCodecId::hevc) {
            HevcDecoderConfigurationRecord hevc_header;
        }
    } else if (video_tag_header.packet_type == VideoPacketType::nalu) {
        if (video_tag_header.codec_id == VideoCodecId::avc) {
            AvcNalu avc_nalu[while($ < end)] [[inline]];
        } else if (video_tag_header.codec_id == VideoCodecId::hevc) {
            HevcNalu hevc_nalu[while($ < end)] [[inline]];
        }
    }

    u8 opaque[end - $];
} [[name("Video Tag")]];

//
// Starts here
//
FLV flv @ 0x00;
