// C helpers for MATBridge: a lock-free single-producer/single-consumer byte ring, and a
// Dolby TrueHD encoder (libavcodec "truehd") wrapped in Dolby MAT / IEC 61937 bursts (libavformat "spdif").
#ifndef CTRUEHD_H
#define CTRUEHD_H

#include <stdint.h>
#include <stddef.h>

// ---- SPSC byte ring. One thread writes, one thread reads; no locks, safe on a real-time thread. ----
typedef struct thb_ring thb_ring;
thb_ring *thb_ring_create(size_t capacity);
void thb_ring_destroy(thb_ring *r);
size_t thb_ring_readable(const thb_ring *r);
size_t thb_ring_writable(const thb_ring *r);
// Writes all `len` bytes or nothing. Returns 1 if written, 0 if there was not enough room.
int thb_ring_write_all(thb_ring *r, const void *src, size_t len);
// Reads up to `len` bytes, returns how many were read.
size_t thb_ring_read(thb_ring *r, void *dst, size_t len);
// Drops up to `len` readable bytes (consumer side), returns how many were dropped.
size_t thb_ring_skip(thb_ring *r, size_t len);

// ---- TrueHD -> MAT encoder ----
// Every IEC 61937 MAT burst is exactly this many bytes (15360 16-bit stereo frames at 768 kHz = 20 ms).
#define THB_MAT_BURST_BYTES 61440
#define THB_CHANNELS 6  // FL FR FC LFE SL SR ("5.1(side)")

typedef void (*thb_burst_fn)(void *ctx, const uint8_t *burst, int len);
typedef struct thb_enc thb_enc;

// rate: 48000, 96000 or 192000. `cb` is called once per complete MAT burst, synchronously from
// thb_enc_push. Returns NULL on failure with a message in `err`.
thb_enc *thb_enc_create(int rate, thb_burst_fn cb, void *ctx, char *err, int errlen);
// `frames` frames of interleaved int32 samples in FL FR FC LFE SL SR order (TrueHD keeps the top 24 bits).
// Returns 0 on success, a negative AVERROR on failure.
int thb_enc_push(thb_enc *e, const int32_t *interleaved, int frames);
int thb_enc_frame_size(const thb_enc *e);
// Bursts whose preamble was not where expected (should stay 0).
int64_t thb_enc_resyncs(const thb_enc *e);
void thb_enc_destroy(thb_enc *e);

// ---- Real-time help: join a CoreAudio device's IO thread workgroup (Apple silicon P-core scheduling). ----
// Returns an opaque handle (NULL if the device has no workgroup or joining failed); pass it to thb_wg_leave
// from the same thread.
void *thb_wg_join_device(uint32_t audio_device_id);
void thb_wg_leave(void *handle);

// ---- Shared-memory mix written by the MATBridge driver (matbridge_shm.h). Read-only mapping; one reader thread. ----
typedef struct thb_shm thb_shm;
// Returns NULL with a message in `err`; errno is ENOENT when the ring does not exist (yet).
thb_shm *thb_shm_open(char *err, int errlen);
void thb_shm_close(thb_shm *s);
int thb_shm_channels(const thb_shm *s);
uint64_t thb_shm_rate(const thb_shm *s);
uint64_t thb_shm_writes(const thb_shm *s);
// Real-time safe. Copies up to `max_frames` new interleaved Float32 frames into `dst` and returns how many. Returns 0
// (and resynchronizes to the newest frame) on the first call and whenever the device clock restarted; frames that
// had to be skipped are added to *lost.
int thb_shm_read(thb_shm *s, float *dst, int max_frames, int64_t *lost);

#endif
