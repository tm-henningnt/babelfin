#ifndef BF_ATOMIC_MIXER_H
#define BF_ATOMIC_MIXER_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Single serialized control/producer lane and one non-reentrant render lane.
// Allocation and control-side quiescence are forbidden from the render lane.
typedef struct BFMixer BFMixer;
typedef struct {
    uint64_t original_frames, translated_frames, discarded_original_frames, output_frames;
    uint64_t translated_read, translated_write;
    bool enabled;
} BFMixerSnapshot;
typedef struct {
    size_t original_consumed, original_empty, original_startup_hold;
    uint64_t translated_consumed;
    bool enabled;
} BFMixerRender;
BFMixer *bf_mixer_create(float level, bool ducking, bool mixes_translation, size_t lead);
void bf_mixer_destroy(BFMixer *mixer);
bool bf_mixer_enabled(BFMixer *mixer);
void bf_mixer_append_original(BFMixer *mixer, const float *samples, size_t count);
bool bf_mixer_schedule(BFMixer *mixer, const float *samples, size_t count, uint64_t *end);
void bf_mixer_translation(BFMixer *mixer, float level, bool ducking);
void bf_mixer_original(BFMixer *mixer);
void bf_mixer_playing(BFMixer *mixer, bool playing);
void bf_mixer_speech_muted(BFMixer *mixer, bool muted);
void bf_mixer_clear_original(BFMixer *mixer);
void bf_mixer_reset(BFMixer *mixer);
void bf_mixer_stop(BFMixer *mixer);
BFMixerSnapshot bf_mixer_snapshot(BFMixer *mixer);
BFMixerRender bf_mixer_render(BFMixer *mixer, float *output, size_t count);
// Offline tests only: caller must quiesce both lanes and empty both queues.
void bf_mixer_seed_empty_cursors(BFMixer *mixer, uint64_t original, uint64_t translated);

// One non-reentrant real-time capture producer, one serialized conversion consumer.
// The ring owns exactly capacity slots until release, including synchronous delivery.
#include <CoreAudio/CoreAudioTypes.h>
#include <mach/mach_types.h>
typedef struct BFCapture BFCapture;
typedef struct {
    uint64_t callbacks, empty_callbacks, captured_frames, queued, peak, oldest_host_time;
    unsigned error; // 0 none, 1 invalid layout/size, 2 capacity exceeded, 3 consumer failure
    bool cancelled;
} BFCaptureSnapshot;
BFCapture *bf_capture_create(size_t capacity, uint32_t max_frames, uint32_t channels,
                             uint32_t bytes_per_frame, bool interleaved, bool initially_accepting);
void bf_capture_destroy(BFCapture *capture);
// Bind once before opening admission. The caller owns the semaphore and keeps it alive
// until after bf_capture_destroy. Push and failure signal it; signaling is real-time safe.
void bf_capture_set_wake_semaphore(BFCapture *capture, semaphore_t semaphore);
bool bf_capture_push(BFCapture *capture, uint32_t frames, const AudioBufferList *buffers);
void bf_capture_fail(BFCapture *capture, unsigned error);
// Control-only barriers: gate first, then wait for a copy already admitted to publish.
void bf_capture_close(BFCapture *capture, bool cancel);
void bf_capture_begin(BFCapture *capture);
void bf_capture_pause(BFCapture *capture);
uint32_t bf_capture_front_frames(BFCapture *capture);
// Consumer only: push host time of the front slot, or 0 when empty.
uint64_t bf_capture_front_host_time(BFCapture *capture);
bool bf_capture_copy_front(BFCapture *capture, AudioBufferList *destination);
void bf_capture_release_front(BFCapture *capture);
BFCaptureSnapshot bf_capture_snapshot(BFCapture *capture);

#endif
