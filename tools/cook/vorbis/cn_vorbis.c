// The cooker's interface to libvorbis: one call, so that Odin does not mirror libvorbis's structs.
#include <stdint.h>

#include <vorbis/vorbisenc.h>

typedef void (*cn_vorbis_write)(void* user, const unsigned char* data, long size);

static void write_page(const ogg_page* page, cn_vorbis_write write, void* user) {
    write(user, page->header, page->header_len);
    write(user, page->body, page->body_len);
}

// Encodes interleaved samples at 48 kHz to an Ogg Vorbis stream, which it hands to write in pieces. quality is libvorbis's,
// from -0.1 to 1. Returns 0, or a negative number when it cannot. The serial number is fixed, so a sound's bytes do not
// change from one cook to the next.
int cn_vorbis_encode(const int16_t* samples, uint64_t frames, int channels, float quality, cn_vorbis_write write, void* user) {
    enum { RATE = 48000, CHUNK_FRAMES = 4096, SERIAL = 0x636e };
    vorbis_info info;
    vorbis_comment comment;
    vorbis_dsp_state dsp;
    vorbis_block block;
    ogg_stream_state stream;
    ogg_page page;
    ogg_packet packet;
    ogg_packet header, header_comment, header_code;

    vorbis_info_init(&info);
    if (vorbis_encode_init_vbr(&info, channels, RATE, quality) != 0) {
        vorbis_info_clear(&info);
        return -1;
    }
    vorbis_comment_init(&comment);
    vorbis_analysis_init(&dsp, &info);
    vorbis_block_init(&dsp, &block);
    ogg_stream_init(&stream, SERIAL);

    vorbis_analysis_headerout(&dsp, &comment, &header, &header_comment, &header_code);
    ogg_stream_packetin(&stream, &header);
    ogg_stream_packetin(&stream, &header_comment);
    ogg_stream_packetin(&stream, &header_code);
    while (ogg_stream_flush(&stream, &page) != 0) {
        write_page(&page, write, user);
    }

    uint64_t next = 0;
    int ended = 0;
    while (!ended) {
        if (next < frames) {
            uint64_t left = frames - next;
            int count = left < CHUNK_FRAMES ? (int)left : CHUNK_FRAMES;
            float** buffer = vorbis_analysis_buffer(&dsp, count);
            for (int c = 0; c < channels; c++) {
                for (int i = 0; i < count; i++) {
                    buffer[c][i] = (float)samples[(next + i) * channels + c] / 32768.0f;
                }
            }
            vorbis_analysis_wrote(&dsp, count);
            next += count;
        } else {
            vorbis_analysis_wrote(&dsp, 0);
        }
        while (vorbis_analysis_blockout(&dsp, &block) == 1) {
            vorbis_analysis(&block, NULL);
            vorbis_bitrate_addblock(&block);
            while (vorbis_bitrate_flushpacket(&dsp, &packet) != 0) {
                ogg_stream_packetin(&stream, &packet);
                while (ogg_stream_pageout(&stream, &page) != 0) {
                    write_page(&page, write, user);
                    ended = ogg_page_eos(&page);
                }
            }
        }
    }

    ogg_stream_clear(&stream);
    vorbis_block_clear(&block);
    vorbis_dsp_clear(&dsp);
    vorbis_comment_clear(&comment);
    vorbis_info_clear(&info);
    return 0;
}
