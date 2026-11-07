#include "ctruehd.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <CoreAudio/CoreAudio.h>
#include <os/workgroup.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/log.h>

// ---------------------------------------------------------------- ring

struct thb_ring {
    uint8_t *buf;
    size_t cap;
    _Atomic size_t head;  // total bytes written (producer)
    _Atomic size_t tail;  // total bytes read (consumer)
};

thb_ring *thb_ring_create(size_t capacity) {
    thb_ring *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->buf = malloc(capacity);
    if (!r->buf) { free(r); return NULL; }
    r->cap = capacity;
    atomic_init(&r->head, 0);
    atomic_init(&r->tail, 0);
    return r;
}

void thb_ring_destroy(thb_ring *r) {
    if (!r) return;
    free(r->buf);
    free(r);
}

size_t thb_ring_readable(const thb_ring *r) {
    size_t h = atomic_load_explicit(&((thb_ring *)r)->head, memory_order_acquire);
    size_t t = atomic_load_explicit(&((thb_ring *)r)->tail, memory_order_acquire);
    return h - t;
}

int thb_ring_write_all(thb_ring *r, const void *src, size_t len) {
    size_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
    size_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
    if (r->cap - (h - t) < len) return 0;
    size_t pos = h % r->cap, first = r->cap - pos < len ? r->cap - pos : len;
    memcpy(r->buf + pos, src, first);
    memcpy(r->buf, (const uint8_t *)src + first, len - first);
    atomic_store_explicit(&r->head, h + len, memory_order_release);
    return 1;
}

static size_t ring_take(thb_ring *r, void *dst, size_t len) {
    size_t t = atomic_load_explicit(&r->tail, memory_order_relaxed);
    size_t h = atomic_load_explicit(&r->head, memory_order_acquire);
    size_t n = h - t < len ? h - t : len;
    if (dst && n) {
        size_t pos = t % r->cap, first = r->cap - pos < n ? r->cap - pos : n;
        memcpy(dst, r->buf + pos, first);
        memcpy((uint8_t *)dst + first, r->buf, n - first);
    }
    atomic_store_explicit(&r->tail, t + n, memory_order_release);
    return n;
}

size_t thb_ring_read(thb_ring *r, void *dst, size_t len) { return ring_take(r, dst, len); }
size_t thb_ring_skip(thb_ring *r, size_t len) { return ring_take(r, NULL, len); }

// ---------------------------------------------------------------- encoder

struct thb_enc {
    AVCodecContext *cc;
    AVFormatContext *fc;
    AVFrame *frame;
    AVPacket *pkt;
    int frame_size, filled;
    int64_t pts;
    thb_burst_fn cb;
    void *ctx;
    // burst assembly from the muxer's byte stream
    uint8_t asm_buf[THB_MAT_BURST_BYTES * 2];
    int asm_len;
};

static const uint8_t kSync[4] = {0x72, 0xF8, 0x1F, 0x4E};  // Pa=0xF872 Pb=0x4E1F, little-endian words

static void assemble(thb_enc *e) {
    for (;;) {
        if (e->asm_len < 4) return;
        if (memcmp(e->asm_buf, kSync, 4) != 0) {
            // Out of sync: drop bytes up to the next preamble (2-byte aligned).
            int i = 2;
            while (i + 4 <= e->asm_len && memcmp(e->asm_buf + i, kSync, 4) != 0) i += 2;
            memmove(e->asm_buf, e->asm_buf + i, e->asm_len - i);
            e->asm_len -= i;
            continue;
        }
        if (e->asm_len < THB_MAT_BURST_BYTES) return;
        e->cb(e->ctx, e->asm_buf, THB_MAT_BURST_BYTES);
        memmove(e->asm_buf, e->asm_buf + THB_MAT_BURST_BYTES, e->asm_len - THB_MAT_BURST_BYTES);
        e->asm_len -= THB_MAT_BURST_BYTES;
    }
}

static int io_write(void *opaque, const uint8_t *buf, int size) {
    thb_enc *e = opaque;
    while (size > 0) {
        int room = (int)sizeof(e->asm_buf) - e->asm_len;
        int n = size < room ? size : room;
        memcpy(e->asm_buf + e->asm_len, buf, n);
        e->asm_len += n; buf += n; size -= n;
        assemble(e);
        if (e->asm_len == (int)sizeof(e->asm_buf)) { e->asm_len = 0; }  // garbage; start over
    }
    return 0;
}

static void set_err(char *err, int errlen, const char *what, int ret) {
    if (!err || errlen <= 0) return;
    char msg[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (ret) av_strerror(ret, msg, sizeof msg);
    snprintf(err, errlen, "%s%s%s", what, ret ? ": " : "", msg);
}

thb_enc *thb_enc_create(int rate, thb_burst_fn cb, void *ctx, char *err, int errlen) {
    av_log_set_level(AV_LOG_ERROR);
    thb_enc *e = calloc(1, sizeof(*e));
    if (!e) { set_err(err, errlen, "out of memory", 0); return NULL; }
    e->cb = cb; e->ctx = ctx;
    int ret;

    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_TRUEHD);
    if (!codec) { set_err(err, errlen, "libavcodec has no truehd encoder", 0); goto fail; }
    e->cc = avcodec_alloc_context3(codec);
    if (!e->cc) { set_err(err, errlen, "out of memory", 0); goto fail; }
    e->cc->sample_rate = rate;
    e->cc->sample_fmt = AV_SAMPLE_FMT_S32P;
    e->cc->strict_std_compliance = FF_COMPLIANCE_EXPERIMENTAL;
    e->cc->time_base = (AVRational){1, rate};
    av_channel_layout_from_mask(&e->cc->ch_layout, AV_CH_LAYOUT_5POINT1);  // 5.1(side)
    if ((ret = avcodec_open2(e->cc, codec, NULL)) < 0) { set_err(err, errlen, "avcodec_open2(truehd)", ret); goto fail; }
    e->frame_size = e->cc->frame_size;

    e->frame = av_frame_alloc();
    if (!e->frame) { set_err(err, errlen, "out of memory", 0); goto fail; }
    e->frame->format = AV_SAMPLE_FMT_S32P;
    e->frame->sample_rate = rate;
    e->frame->nb_samples = e->frame_size;
    av_channel_layout_copy(&e->frame->ch_layout, &e->cc->ch_layout);
    if ((ret = av_frame_get_buffer(e->frame, 0)) < 0) { set_err(err, errlen, "av_frame_get_buffer", ret); goto fail; }
    e->pkt = av_packet_alloc();
    if (!e->pkt) { set_err(err, errlen, "out of memory", 0); goto fail; }

    const AVOutputFormat *ofmt = av_guess_format("spdif", NULL, NULL);
    if (!ofmt) { set_err(err, errlen, "libavformat has no spdif muxer", 0); goto fail; }
    if ((ret = avformat_alloc_output_context2(&e->fc, ofmt, NULL, NULL)) < 0) { set_err(err, errlen, "avformat_alloc_output_context2", ret); goto fail; }
    const int iosize = 65536;
    uint8_t *iobuf = av_malloc(iosize);
    if (!iobuf || !(e->fc->pb = avio_alloc_context(iobuf, iosize, 1, e, NULL, io_write, NULL))) {
        av_free(iobuf); set_err(err, errlen, "out of memory", 0); goto fail;
    }
    e->fc->flags |= AVFMT_FLAG_FLUSH_PACKETS;
    AVStream *st = avformat_new_stream(e->fc, NULL);
    if (!st) { set_err(err, errlen, "out of memory", 0); goto fail; }
    avcodec_parameters_from_context(st->codecpar, e->cc);
    st->time_base = e->cc->time_base;
    if ((ret = avformat_write_header(e->fc, NULL)) < 0) { set_err(err, errlen, "avformat_write_header(spdif)", ret); goto fail; }
    return e;
fail:
    thb_enc_destroy(e);
    return NULL;
}

static int drain(thb_enc *e) {
    int ret;
    while ((ret = avcodec_receive_packet(e->cc, e->pkt)) == 0) {
        e->pkt->stream_index = 0;
        av_packet_rescale_ts(e->pkt, e->cc->time_base, e->fc->streams[0]->time_base);
        ret = av_write_frame(e->fc, e->pkt);  // takes ownership of the data, resets pkt
        if (ret < 0) return ret;
        avio_flush(e->fc->pb);
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

int thb_enc_push(thb_enc *e, const int32_t *in, int frames) {
    int ret;
    while (frames > 0) {
        if (e->filled == 0 && (ret = av_frame_make_writable(e->frame)) < 0) return ret;
        int n = e->frame_size - e->filled;
        if (n > frames) n = frames;
        for (int c = 0; c < THB_CHANNELS; c++) {
            int32_t *dst = (int32_t *)e->frame->extended_data[c] + e->filled;
            const int32_t *src = in + c;
            for (int i = 0; i < n; i++) dst[i] = src[i * THB_CHANNELS];
        }
        in += n * THB_CHANNELS; frames -= n; e->filled += n;
        if (e->filled == e->frame_size) {
            e->frame->pts = e->pts;
            e->pts += e->frame_size;
            e->filled = 0;
            if ((ret = avcodec_send_frame(e->cc, e->frame)) < 0) return ret;
            if ((ret = drain(e)) < 0) return ret;
        }
    }
    return 0;
}

void thb_enc_destroy(thb_enc *e) {
    if (!e) return;
    if (e->fc) {
        if (e->fc->pb) { av_freep(&e->fc->pb->buffer); avio_context_free(&e->fc->pb); }
        avformat_free_context(e->fc);
    }
    av_packet_free(&e->pkt);
    av_frame_free(&e->frame);
    avcodec_free_context(&e->cc);
    free(e);
}

// ---------------------------------------------------------------- workgroup

struct thb_wg { os_workgroup_t wg; os_workgroup_join_token_s token; };

void *thb_wg_join_device(uint32_t dev) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyIOThreadOSWorkgroup, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    os_workgroup_t wg = NULL;
    UInt32 size = sizeof(wg);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &wg) != noErr || !wg) return NULL;
    struct thb_wg *h = calloc(1, sizeof(*h));
    h->wg = wg;
    if (os_workgroup_join(wg, &h->token) != 0) { os_release(wg); free(h); return NULL; }
    return h;
}

void thb_wg_leave(void *handle) {
    struct thb_wg *h = handle;
    if (!h) return;
    os_workgroup_leave(h->wg, &h->token);
    os_release(h->wg);
    free(h);
}

// ---------------------------------------------------------------- shared-memory mix (driver -> app)

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "matbridge_shm.h"

struct thb_shm {
    const matb_shm_header *h;
    size_t bytes;
    uint64_t pos;      // next device sample time to read
    uint64_t epoch;
    int started;
};

thb_shm *thb_shm_open(char *err, int errlen) {
    int fd = shm_open(MATB_SHM_NAME, O_RDONLY);
    if (fd < 0) {
        int e = errno;
        snprintf(err, errlen, "no shared mix '%s' (%s): is the MATBridge driver installed?", MATB_SHM_NAME, strerror(e));
        errno = e;  // callers check for ENOENT
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(matb_shm_header)) { close(fd); snprintf(err, errlen, "shared mix too small"); return NULL; }
    void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) { snprintf(err, errlen, "mmap: %s", strerror(errno)); return NULL; }
    const matb_shm_header *h = p;
    atomic_thread_fence(memory_order_acquire);
    if (h->magic != MATB_SHM_MAGIC || h->version != MATB_SHM_VERSION || h->capacityFrames != MATB_SHM_FRAMES
        || h->channels == 0 || (size_t)st.st_size < MATB_SHM_BYTES(h->channels)) {
        snprintf(err, errlen, "shared mix has an unknown layout (magic %08x version %u)", h->magic, h->version);
        munmap(p, (size_t)st.st_size);
        return NULL;
    }
    thb_shm *s = calloc(1, sizeof(*s));
    if (!s) { munmap(p, (size_t)st.st_size); snprintf(err, errlen, "out of memory"); return NULL; }
    s->h = h; s->bytes = (size_t)st.st_size;
    return s;
}

void thb_shm_close(thb_shm *s) {
    if (!s) return;
    munmap((void *)s->h, s->bytes);
    free(s);
}

int thb_shm_channels(const thb_shm *s) { return (int)s->h->channels; }
uint64_t thb_shm_rate(const thb_shm *s) { return atomic_load_explicit(&((matb_shm_header *)s->h)->sampleRateHz, memory_order_relaxed); }
uint64_t thb_shm_writes(const thb_shm *s) { return atomic_load_explicit(&((matb_shm_header *)s->h)->writes, memory_order_relaxed); }

int thb_shm_read(thb_shm *s, float *dst, int max_frames, int64_t *lost) {
    matb_shm_header *h = (matb_shm_header *)s->h;
    const uint64_t cap = MATB_SHM_FRAMES, ch = h->channels;
    uint64_t e = atomic_load_explicit(&h->epoch, memory_order_acquire);
    uint64_t w = atomic_load_explicit(&h->writeEnd, memory_order_acquire);
    if (!s->started || e != s->epoch || w < s->pos) {   // first read, or the device clock restarted: start from now
        s->started = 1; s->epoch = e; s->pos = w;
        return 0;
    }
    uint64_t avail = w - s->pos;
    if (avail > cap / 2) {   // fell far behind (reader stalled): skip to now rather than read frames being overwritten
        if (lost) *lost += (int64_t)avail;
        s->pos = w;
        return 0;
    }
    uint64_t n = avail < (uint64_t)max_frames ? avail : (uint64_t)max_frames;
    if (n == 0) return 0;
    uint64_t at = s->pos % cap, first = cap - at < n ? cap - at : n;
    memcpy(dst, h->data + at * ch, first * ch * sizeof(float));
    memcpy(dst + first * ch, h->data, (n - first) * ch * sizeof(float));
    // The copy is only valid if the writer did not restart or reach our frames meanwhile. It may be writing up to one
    // IO buffer past writeEnd already, so keep a margin of cap/8 (far more than any IO buffer).
    atomic_thread_fence(memory_order_acquire);
    uint64_t w2 = atomic_load_explicit(&h->writeEnd, memory_order_acquire);
    if (atomic_load_explicit(&h->epoch, memory_order_acquire) != e || w2 < s->pos || w2 - s->pos > cap - cap / 8) {
        if (lost) *lost += (int64_t)n;
        s->started = 0;
        return 0;
    }
    s->pos += n;
    return (int)n;
}
