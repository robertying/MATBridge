// Shared-memory layout between the MATBridge HAL driver (writer) and the MATBridge app (reader).
//
// The driver copies every output mix it receives (kAudioServerPlugInIOOperationWriteMix) into a POSIX shared-memory
// ring, so the app can read system audio without opening the virtual device's input side. Reading device input is
// what macOS counts as microphone use (orange indicator + Microphone permission); reading this ring is not.
//
// Included by the driver build (driver/shared-memory-mix.patch) and by the app (Sources/CTrueHD). Bump
// MATB_SHM_VERSION whenever the layout changes; the reader refuses a version it does not know.
#ifndef MATBRIDGE_SHM_H
#define MATBRIDGE_SHM_H

#include <stdatomic.h>
#include <stdint.h>

#ifndef MATB_SHM_NAME
#define MATB_SHM_NAME     "/io.ruiying.matbridge"   // POSIX shm names are limited to 31 characters on macOS
#endif
#define MATB_SHM_MAGIC    0x4D415442u               // 'MATB'
#define MATB_SHM_VERSION  1u
#define MATB_SHM_FRAMES   65536u                    // ring capacity in frames (1.36 s at 48 kHz, 341 ms at 192 kHz)

typedef struct {
    uint32_t magic;            // MATB_SHM_MAGIC, written last at creation
    uint32_t version;          // MATB_SHM_VERSION
    uint32_t channels;         // interleaved Float32 channels per frame
    uint32_t capacityFrames;   // MATB_SHM_FRAMES
    _Atomic uint64_t sampleRateHz;  // nominal rate of the frames being written (set when IO starts)
    _Atomic uint64_t epoch;         // incremented each time the device's IO (and its sample clock) restarts
    _Atomic uint64_t writeEnd;      // device sample time just past the last frame written; release-stored after data
    _Atomic uint64_t writes;        // number of WriteMix operations (diagnostics)
    uint8_t _pad[128 - 48];
    float data[];              // capacityFrames * channels, frame f lives at index (f % capacityFrames)
} matb_shm_header;

#define MATB_SHM_BYTES(ch) (sizeof(matb_shm_header) + (size_t)MATB_SHM_FRAMES * (ch) * sizeof(float))

#endif
