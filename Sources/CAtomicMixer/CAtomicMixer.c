#include "CAtomicMixer.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sched.h>
#pragma STDC FP_CONTRACT OFF

_Static_assert(__atomic_always_lock_free(1, 0) && __atomic_always_lock_free(4, 0) && __atomic_always_lock_free(8, 0), "The audio callback requires lock-free 64-bit atomics");
#define ORIGINAL_CAPACITY 2880u
#define TRANSLATED_CAPACITY 48000u
#define ENABLED (UINT64_C(1) << 32)
#define PLAYING (UINT64_C(1) << 33)
#define ORIGINAL_ONLY (UINT64_C(1) << 34)
#define DUCKING (UINT64_C(1) << 35)
#define MIXES (UINT64_C(1) << 36)
#define ORIGINAL_GATE (UINT64_C(1) << 37)
#define TRANSLATED_GATE (UINT64_C(1) << 38)
#define SPEECH_MUTED (UINT64_C(1) << 39)
#define EPOCH (UINT64_C(1) << 40)
#define EPOCH_MASK (UINT64_C(0xffffff) << 40)

typedef struct {
    _Atomic uint64_t *slots;
    size_t capacity;
    _Atomic uint64_t write, read, floor;
} Ring;
struct BFMixer {
    _Atomic uint64_t original_slots[ORIGINAL_CAPACITY];
    _Atomic uint64_t translated_slots[TRANSLATED_CAPACITY];
    Ring original, translated;
    _Atomic uint64_t control, active, original_consumed, output_frames, lead_epoch, speech_epoch;
    // Only the serialized producer/control lane touches these accounting baselines.
    uint64_t discarded_base, produced_base, consumed_base;
    size_t lead;
    // Only render touches DSP state, including during explicit control cancellation.
    uint64_t render_epoch, render_lead_epoch, render_sequence, rendered_original, rendered_output;
    size_t lead_remaining;
    float gain, original_scale;
    unsigned hold;
    // The original keeps full level after each switch to translation until translated speech plays.
    uint64_t render_speech_epoch;
    bool speech_started;
};
static uint64_t maximum(uint64_t a, uint64_t b) { return a > b ? a : b; }
static uint32_t bits(float value) { uint32_t result; memcpy(&result, &value, sizeof result); return result; }
static float sample(uint64_t value) { uint32_t low = (uint32_t)value; float result; memcpy(&result, &low, sizeof result); return result; }
static uint64_t queued(Ring *ring) {
    uint64_t w = atomic_load_explicit(&ring->write, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint64_t floor = atomic_load_explicit(&ring->floor, memory_order_acquire);
    r = maximum(r, maximum(floor, w > ring->capacity ? w - ring->capacity : 0));
    // A tagged overwrite may be adopted just before its writer publishes write.
    return w > r ? w - r : 0;
}
static uint64_t discarded(BFMixer *m) {
    uint64_t written = atomic_load_explicit(&m->original.write, memory_order_acquire) - m->produced_base;
    uint64_t consumed = atomic_load_explicit(&m->original_consumed, memory_order_acquire) - m->consumed_base;
    uint64_t remaining = queued(&m->original);
    // A live snapshot is observational, not a multi-atomic transaction. Clamp a
    // temporarily unpublished adopted slot rather than underflowing the metric.
    return m->discarded_base + (written > consumed + remaining ? written - consumed - remaining : 0);
}
static uint64_t next_epoch(uint64_t control) {
    return (control & ~EPOCH_MASK) | ((control + EPOCH) & EPOCH_MASK);
}
static void publish_slot(Ring *ring, uint64_t position, float value) {
    uint64_t tagged = ((uint64_t)(uint32_t)position << 32) | bits(value);
    atomic_store_explicit(&ring->slots[position % ring->capacity], tagged, memory_order_release);
}
// One atomic slot load, with no CAS/retry or contention-to-silence branch. A
// simultaneous live overwrite can replace this exact slot. Adopt its newer
// tagged sample and advance past *all* skipped oldest positions, never replay.
// The 32-bit modular tag is unambiguous: the reader first clamps within capacity
// of the 64-bit published tail; producer lapping 2^31 frames during this one
// atomic load would require >24 hours of 24 kHz audio in that instruction gap.
static bool pop(Ring *ring, float *value) {
    uint64_t w = atomic_load_explicit(&ring->write, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&ring->read, memory_order_relaxed);
    r = maximum(r, atomic_load_explicit(&ring->floor, memory_order_acquire));
    r = maximum(r, w > ring->capacity ? w - ring->capacity : 0);
    if (r >= w) return false;
    uint64_t tagged = atomic_load_explicit(&ring->slots[r % ring->capacity], memory_order_acquire);
    uint32_t distance = (uint32_t)(tagged >> 32) - (uint32_t)r;
    r += distance;
    *value = sample(tagged);
    atomic_store_explicit(&ring->read, r + 1, memory_order_release);
    return true;
}
// Control cancels the affected branch before waiting for an in-flight callback.
// A callback beginning during this interval sees the gate and never accesses
// that branch. The callback itself never waits. Seq-cst gate/active publication
// closes the enter-vs-quiesce race; serialized controls may yield off RT.
static void quiesce(BFMixer *m, uint64_t gate) {
    atomic_fetch_or_explicit(&m->control, gate, memory_order_seq_cst);
    while (atomic_load_explicit(&m->active, memory_order_seq_cst) & 1) sched_yield();
}
static void clear_original_quiescent(BFMixer *m) {
    m->discarded_base = discarded(m);
    m->produced_base = atomic_load_explicit(&m->original.write, memory_order_acquire);
    m->consumed_base = atomic_load_explicit(&m->original_consumed, memory_order_acquire);
    atomic_store_explicit(&m->original.floor, m->produced_base, memory_order_release);
    atomic_fetch_add_explicit(&m->lead_epoch, 1, memory_order_release);
}
BFMixer *bf_mixer_create(float level, bool ducking, bool mixes_translation, size_t lead) {
    BFMixer *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->original.slots = m->original_slots; m->original.capacity = ORIGINAL_CAPACITY;
    m->translated.slots = m->translated_slots; m->translated.capacity = TRANSLATED_CAPACITY;
    // Explicit initialization also covers platforms where atomic zero has an
    // implementation-defined representation. All allocation occurs before RT.
    for (size_t i = 0; i < ORIGINAL_CAPACITY; ++i) atomic_init(&m->original_slots[i], 0);
    for (size_t i = 0; i < TRANSLATED_CAPACITY; ++i) atomic_init(&m->translated_slots[i], 0);
    atomic_init(&m->original.write, 0); atomic_init(&m->original.read, 0); atomic_init(&m->original.floor, 0);
    atomic_init(&m->translated.write, 0); atomic_init(&m->translated.read, 0); atomic_init(&m->translated.floor, 0);
    atomic_init(&m->control, bits(level) | ENABLED | (ducking ? DUCKING : 0) | (mixes_translation ? MIXES : 0));
    atomic_init(&m->active, 0); atomic_init(&m->original_consumed, 0); atomic_init(&m->output_frames, 0);
    atomic_init(&m->lead_epoch, 0); atomic_init(&m->speech_epoch, 0);
    m->lead = lead; m->lead_remaining = lead; m->gain = 1; m->original_scale = 1;
    return m;
}
void bf_mixer_destroy(BFMixer *m) { free(m); }
bool bf_mixer_enabled(BFMixer *m) { return (atomic_load_explicit(&m->control, memory_order_acquire) & ENABLED) != 0; }
void bf_mixer_append_original(BFMixer *m, const float *values, size_t count) {
    if (!(atomic_load_explicit(&m->control, memory_order_acquire) & ENABLED)) return;
    uint64_t w = atomic_load_explicit(&m->original.write, memory_order_relaxed);
    size_t skip = count > ORIGINAL_CAPACITY ? count - ORIGINAL_CAPACITY : 0;
    // Oversized appends retain only their suffix, as before. Publishing the
    // suffix tail per slot avoids a writer lock or unpublished wraparound gap.
    w += skip;
    if (skip) atomic_store_explicit(&m->original.floor, w, memory_order_release);
    for (size_t i = skip; i < count; ++i) {
        publish_slot(&m->original, w, values[i]);
        atomic_store_explicit(&m->original.write, ++w, memory_order_release);
    }
}
bool bf_mixer_schedule(BFMixer *m, const float *values, size_t count, uint64_t *end) {
    if (!(atomic_load_explicit(&m->control, memory_order_acquire) & ENABLED)) return false;
    if (!count || count > TRANSLATED_CAPACITY - queued(&m->translated)) return false;
    uint64_t w = atomic_load_explicit(&m->translated.write, memory_order_relaxed);
    for (size_t i = 0; i < count; ++i) publish_slot(&m->translated, w + i, values[i]);
    *end = w + count;
    atomic_store_explicit(&m->translated.write, *end, memory_order_release);
    return true;
}
void bf_mixer_translation(BFMixer *m, float level, bool ducking) {
    uint64_t c = atomic_load_explicit(&m->control, memory_order_relaxed);
    c = (c & ~(UINT64_C(0xffffffff) | ORIGINAL_ONLY | DUCKING)) | bits(level) | MIXES | (ducking ? DUCKING : 0);
    atomic_fetch_add_explicit(&m->speech_epoch, 1, memory_order_release);
    atomic_store_explicit(&m->control, next_epoch(c), memory_order_seq_cst);
}
void bf_mixer_original(BFMixer *m) {
    quiesce(m, ORIGINAL_ONLY | TRANSLATED_GATE);
    atomic_store_explicit(&m->translated.floor, atomic_load_explicit(&m->translated.write, memory_order_acquire), memory_order_release);
    uint64_t c = atomic_load_explicit(&m->control, memory_order_relaxed) & ~TRANSLATED_GATE;
    atomic_store_explicit(&m->control, next_epoch(c), memory_order_seq_cst);
}
// Translated audio keeps playing out silently, so pacing and completions stay intact.
void bf_mixer_speech_muted(BFMixer *m, bool muted) {
    if (muted) atomic_fetch_or_explicit(&m->control, SPEECH_MUTED, memory_order_seq_cst);
    else atomic_fetch_and_explicit(&m->control, ~SPEECH_MUTED, memory_order_seq_cst);
}
void bf_mixer_playing(BFMixer *m, bool playing) {
    if (playing) atomic_fetch_or_explicit(&m->control, PLAYING, memory_order_seq_cst);
    else atomic_fetch_and_explicit(&m->control, ~PLAYING, memory_order_seq_cst);
}
void bf_mixer_clear_original(BFMixer *m) {
    quiesce(m, ORIGINAL_GATE);
    clear_original_quiescent(m);
    atomic_fetch_and_explicit(&m->control, ~ORIGINAL_GATE, memory_order_seq_cst);
}
void bf_mixer_reset(BFMixer *m) {
    quiesce(m, ORIGINAL_GATE | TRANSLATED_GATE);
    clear_original_quiescent(m);
    atomic_store_explicit(&m->translated.floor, atomic_load_explicit(&m->translated.write, memory_order_acquire), memory_order_release);
    uint64_t c = atomic_load_explicit(&m->control, memory_order_relaxed) & ~(ORIGINAL_GATE | TRANSLATED_GATE | PLAYING);
    atomic_store_explicit(&m->control, next_epoch(c), memory_order_seq_cst);
}
void bf_mixer_stop(BFMixer *m) {
    atomic_fetch_and_explicit(&m->control, ~ENABLED, memory_order_seq_cst);
    quiesce(m, ORIGINAL_GATE | TRANSLATED_GATE);
    clear_original_quiescent(m);
    atomic_store_explicit(&m->translated.floor, atomic_load_explicit(&m->translated.write, memory_order_acquire), memory_order_release);
}
BFMixerSnapshot bf_mixer_snapshot(BFMixer *m) {
    // Observational snapshots may wait on the control lane. The monotonically
    // changing render sequence yields coherent cursor/consumption accounting,
    // including when a callback starts and ends between the two observations.
    for (;;) {
        uint64_t before = atomic_load_explicit(&m->active, memory_order_seq_cst);
        if (before & 1) { sched_yield(); continue; }
        BFMixerSnapshot result = { queued(&m->original), queued(&m->translated), discarded(m),
            atomic_load_explicit(&m->output_frames, memory_order_acquire),
            atomic_load_explicit(&m->translated.read, memory_order_acquire),
            atomic_load_explicit(&m->translated.write, memory_order_acquire),
            (atomic_load_explicit(&m->control, memory_order_acquire) & ENABLED) != 0 };
        if (before == atomic_load_explicit(&m->active, memory_order_seq_cst)) return result;
    }
}
BFMixerRender bf_mixer_render(BFMixer *m, float *output, size_t count) {
    BFMixerRender result = {0};
    atomic_store_explicit(&m->active, ++m->render_sequence, memory_order_seq_cst);
    uint64_t c = atomic_load_explicit(&m->control, memory_order_seq_cst);
    if (!(c & ENABLED)) {
        for (size_t i = 0; i < count; ++i) output[i] = 0;
        atomic_store_explicit(&m->active, ++m->render_sequence, memory_order_seq_cst);
        return result;
    }
    result.enabled = true;
    uint64_t lead_epoch = atomic_load_explicit(&m->lead_epoch, memory_order_acquire);
    if (lead_epoch != m->render_lead_epoch) { m->render_lead_epoch = lead_epoch; m->lead_remaining = m->lead; }
    for (size_t i = 0; i < count; ++i) {
        c = atomic_load_explicit(&m->control, memory_order_seq_cst);
        if ((c & EPOCH_MASK) != m->render_epoch) { m->render_epoch = c & EPOCH_MASK; m->gain = 1; m->hold = 0; }
        float original = 0, speech = 0;
        bool original_held = false;
        if ((c & ENABLED) && !(c & ORIGINAL_GATE)) {
            lead_epoch = atomic_load_explicit(&m->lead_epoch, memory_order_acquire);
            if (lead_epoch != m->render_lead_epoch) { m->render_lead_epoch = lead_epoch; m->lead_remaining = m->lead; }
            if (m->lead_remaining && queued(&m->original)) {
                --m->lead_remaining; ++result.original_startup_hold; original_held = true;
            }
            if (!original_held && pop(&m->original, &original)) {
                ++result.original_consumed;
                atomic_store_explicit(&m->original_consumed, ++m->rendered_original, memory_order_release);
            }
        }
        if ((c & (ENABLED | PLAYING)) == (ENABLED | PLAYING) && !(c & (ORIGINAL_ONLY | TRANSLATED_GATE)) && pop(&m->translated, &speech)) ++result.translated_consumed;
        uint64_t speech_epoch = atomic_load_explicit(&m->speech_epoch, memory_order_acquire);
        if (speech_epoch != m->render_speech_epoch) { m->render_speech_epoch = speech_epoch; m->speech_started = false; }
        // Recheck explicit cancellation after reading atomics. Original is still
        // available for a mode change; Stop always silences the complete buffer.
        uint64_t latest = atomic_load_explicit(&m->control, memory_order_seq_cst);
        if ((latest & EPOCH_MASK) != (c & EPOCH_MASK)) { m->gain = 1; m->hold = 0; m->render_epoch = latest & EPOCH_MASK; }
        c = latest;
        if (c & (ORIGINAL_ONLY | TRANSLATED_GATE | SPEECH_MUTED)) speech = 0;
        if (c & ORIGINAL_ONLY) { m->gain = 1; m->hold = 0; }
        if (fabsf(speech) > 0.001f) m->speech_started = true;
        if (!(c & ORIGINAL_ONLY) && (c & DUCKING) && fabsf(speech) > 0.001f) m->hold = 3600;
        else if (m->hold) --m->hold;
        // With speech muted the duck releases within 80 ms, together with the original's fade-up.
        if (c & SPEECH_MUTED) m->hold = 0;
        float target = !(c & ORIGINAL_ONLY) && (c & DUCKING) && m->hold ? 0.15f : 1;
        float step = target < m->gain ? 0.85f / 240 : (c & SPEECH_MUTED ? 0.85f / 1920 : 0.85f / 4800);
        m->gain += fminf(step, fmaxf(-step, target - m->gain));
        float level = c & ORIGINAL_ONLY ? 1 : sample(c);
        float headroom = c & ORIGINAL_ONLY || !(c & MIXES) ? 1 : 1 / (1 + level);
        // Without audible translated speech the original plays at full level. It fades up over
        // 80 ms. It drops at once when translated speech plays, so the sum keeps its headroom.
        bool full = !(c & MIXES) || (c & (ORIGINAL_ONLY | SPEECH_MUTED)) || !m->speech_started;
        float scale_target = full ? 1 : level * headroom;
        if (scale_target < m->original_scale && fabsf(speech) > 0.001f) m->original_scale = scale_target;
        else m->original_scale += fminf(1.0f / 1920, fmaxf(-1.0f / 1920, scale_target - m->original_scale));
        float mixed = speech * headroom + original * m->original_scale * m->gain;
        output[i] = c & ENABLED ? fminf(1, fmaxf(-1, mixed)) : 0;
    }
    result.original_empty = count - result.original_startup_hold - result.original_consumed;
    m->rendered_output += count;
    atomic_store_explicit(&m->output_frames, m->rendered_output, memory_order_release);
    if (!(atomic_load_explicit(&m->control, memory_order_seq_cst) & ENABLED))
        for (size_t i = 0; i < count; ++i) output[i] = 0;
    atomic_store_explicit(&m->active, ++m->render_sequence, memory_order_seq_cst);
    return result;
}
void bf_mixer_seed_empty_cursors(BFMixer *m, uint64_t original, uint64_t translated) {
    atomic_store(&m->original.write, original); atomic_store(&m->original.read, original); atomic_store(&m->original.floor, original);
    atomic_store(&m->translated.write, translated); atomic_store(&m->translated.read, translated); atomic_store(&m->translated.floor, translated);
    m->produced_base = original; m->consumed_base = atomic_load(&m->original_consumed);
}

#include <mach/mach_time.h>
#include <mach/semaphore.h>
#include <mach/task.h>

// Payload bytes/slot metadata have exclusive ownership: producer before release
// publication of write, consumer until release publication of read. No plain
// payload/metadata access overlaps. The in-flight consumer retains its slot.
struct BFCapture {
    size_t capacity, buffer_count, bytes_per_frame, bytes_per_buffer, slot_bytes;
    uint32_t max_frames, channels;
    bool interleaved;
    unsigned char *storage;
    uint32_t *frames;
    _Atomic uint64_t *hosts;
    _Atomic uint64_t write, reserved_write, read, callbacks, empty_callbacks, captured_frames, peak;
    _Atomic uint64_t active;
    _Atomic unsigned gate; // 0 paused/pre-start, 1 open, 2 permanently closed
    _Atomic bool cancelled;
    _Atomic unsigned error;
    semaphore_t wake;
};
BFCapture *bf_capture_create(size_t capacity, uint32_t max_frames, uint32_t channels,
                             uint32_t bytes_per_frame, bool interleaved, bool initially_accepting) {
    if (!capacity || capacity > 64 || !max_frames || !channels || channels > 64 || !bytes_per_frame) return NULL;
    size_t buffers = interleaved ? 1 : channels;
    if (max_frames > SIZE_MAX / bytes_per_frame) return NULL;
    size_t bytes = (size_t)max_frames * bytes_per_frame;
    if (bytes > UINT32_MAX || bytes > SIZE_MAX / buffers || bytes * buffers > SIZE_MAX / capacity) return NULL;
    BFCapture *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->capacity = capacity; c->max_frames = max_frames; c->channels = channels;
    c->interleaved = interleaved; c->buffer_count = buffers; c->bytes_per_frame = bytes_per_frame;
    c->bytes_per_buffer = bytes; c->slot_bytes = bytes * buffers;
    c->storage = calloc(capacity, c->slot_bytes);
    c->frames = calloc(capacity, sizeof *c->frames);
    c->hosts = calloc(capacity, sizeof *c->hosts);
    if (!c->storage || !c->frames || !c->hosts) { bf_capture_destroy(c); return NULL; }
    for (size_t i = 0; i < capacity; ++i) atomic_init(&c->hosts[i], 0);
    // Fault in payload pages during setup rather than the first receiver call.
    volatile unsigned char *pages = c->storage;
    for (size_t offset = 0; offset < capacity * c->slot_bytes; offset += 4096) pages[offset] = 0;
    atomic_init(&c->write, 0); atomic_init(&c->reserved_write, 0); atomic_init(&c->read, 0); atomic_init(&c->callbacks, 0);
    atomic_init(&c->empty_callbacks, 0); atomic_init(&c->captured_frames, 0); atomic_init(&c->peak, 0);
    atomic_init(&c->active, 0); atomic_init(&c->gate, initially_accepting ? 1 : 0); atomic_init(&c->cancelled, false); atomic_init(&c->error, 0);
    return c;
}
void bf_capture_destroy(BFCapture *c) {
    if (!c) return;
    // Owner quiesces the engine/receiver before releasing this ring. The wake
    // semaphore belongs to the owner and outlives the ring.
    free(c->storage); free(c->frames); free(c->hosts); free(c);
}
void bf_capture_set_wake_semaphore(BFCapture *c, semaphore_t semaphore) { c->wake = semaphore; }
static void capture_wake(BFCapture *c) { if (c->wake != SEMAPHORE_NULL) semaphore_signal(c->wake); }
void bf_capture_fail(BFCapture *c, unsigned error) {
    unsigned expected = 0;
    if (atomic_compare_exchange_strong_explicit(&c->error, &expected, error, memory_order_release, memory_order_relaxed)) capture_wake(c);
}
bool bf_capture_push(BFCapture *c, uint32_t frames, const AudioBufferList *buffers) {
    uint64_t already_active = atomic_fetch_add_explicit(&c->active, 1, memory_order_seq_cst);
    atomic_fetch_add_explicit(&c->callbacks, 1, memory_order_relaxed);
    if (!frames) atomic_fetch_add_explicit(&c->empty_callbacks, 1, memory_order_relaxed);
    bool accepted = false;
    // The engine contract is non-reentrant. Reject misuse before touching any
    // plain slot payload rather than silently turning SPSC into a data race.
    if (already_active) { bf_capture_fail(c, 1); goto done; }
    if (atomic_load_explicit(&c->gate, memory_order_seq_cst) != 1 || atomic_load_explicit(&c->error, memory_order_acquire)) goto done;
    if (!frames) { accepted = true; goto done; }
    if (frames > c->max_frames || !buffers || buffers->mNumberBuffers != c->buffer_count) { bf_capture_fail(c, 1); goto done; }
    size_t bytes = (size_t)frames * c->bytes_per_frame;
    for (size_t i = 0; i < c->buffer_count; ++i) {
        const AudioBuffer *b = &buffers->mBuffers[i];
        if (!b->mData || b->mNumberChannels != (c->interleaved ? c->channels : 1) || b->mDataByteSize < bytes) { bf_capture_fail(c, 1); goto done; }
    }
    uint64_t w = atomic_load_explicit(&c->write, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&c->read, memory_order_acquire);
    if (w - r >= c->capacity) { bf_capture_fail(c, 2); goto done; }
    size_t slot = w % c->capacity;
    c->frames[slot] = frames;
    atomic_store_explicit(&c->hosts[slot], mach_absolute_time(), memory_order_relaxed);
    atomic_fetch_add_explicit(&c->captured_frames, frames, memory_order_relaxed);
    uint64_t peak = atomic_load_explicit(&c->peak, memory_order_relaxed);
    if (w - r + 1 > peak) atomic_store_explicit(&c->peak, w - r + 1, memory_order_relaxed);
    // Reservation is observational only; the consumer sees write only AFTER
    // copying. Queue telemetry includes the producer's current owned slot.
    atomic_store_explicit(&c->reserved_write, w + 1, memory_order_release);
    for (size_t i = 0; i < c->buffer_count; ++i) memcpy(c->storage + slot * c->slot_bytes + i * c->bytes_per_buffer, buffers->mBuffers[i].mData, bytes);
    atomic_store_explicit(&c->write, w + 1, memory_order_release);
    capture_wake(c);
    accepted = true;
done:
    atomic_fetch_sub_explicit(&c->active, 1, memory_order_seq_cst);
    return accepted;
}
void bf_capture_close(BFCapture *c, bool cancel) {
    atomic_store_explicit(&c->gate, 2, memory_order_seq_cst);
    if (cancel) atomic_store_explicit(&c->cancelled, true, memory_order_release);
    while (atomic_load_explicit(&c->active, memory_order_seq_cst)) sched_yield();
}
void bf_capture_begin(BFCapture *c) {
    unsigned expected = 0;
    atomic_compare_exchange_strong_explicit(&c->gate, &expected, 1, memory_order_seq_cst, memory_order_seq_cst);
}
void bf_capture_pause(BFCapture *c) {
    unsigned expected = 1;
    atomic_compare_exchange_strong_explicit(&c->gate, &expected, 0, memory_order_seq_cst, memory_order_seq_cst);
    while (atomic_load_explicit(&c->active, memory_order_seq_cst)) sched_yield();
}
uint32_t bf_capture_front_frames(BFCapture *c) {
    uint64_t r = atomic_load_explicit(&c->read, memory_order_relaxed);
    if (r == atomic_load_explicit(&c->write, memory_order_acquire)) return 0;
    return c->frames[r % c->capacity];
}
uint64_t bf_capture_front_host_time(BFCapture *c) {
    uint64_t r = atomic_load_explicit(&c->read, memory_order_relaxed);
    if (r == atomic_load_explicit(&c->write, memory_order_acquire)) return 0;
    return atomic_load_explicit(&c->hosts[r % c->capacity], memory_order_relaxed);
}
bool bf_capture_copy_front(BFCapture *c, AudioBufferList *destination) {
    uint64_t r = atomic_load_explicit(&c->read, memory_order_relaxed);
    if (r == atomic_load_explicit(&c->write, memory_order_acquire) || !destination || destination->mNumberBuffers != c->buffer_count) return false;
    size_t slot = r % c->capacity, bytes = (size_t)c->frames[slot] * c->bytes_per_frame;
    for (size_t i = 0; i < c->buffer_count; ++i) {
        AudioBuffer *b = &destination->mBuffers[i];
        if (!b->mData || b->mDataByteSize < bytes) return false;
        memcpy(b->mData, c->storage + slot * c->slot_bytes + i * c->bytes_per_buffer, bytes);
    }
    return true;
}
void bf_capture_release_front(BFCapture *c) { atomic_fetch_add_explicit(&c->read, 1, memory_order_release); }
BFCaptureSnapshot bf_capture_snapshot(BFCapture *c) {
    // Observers never read plain payload metadata. Retry if the oldest slot was
    // released while collecting its atomic timestamp/cursors.
    uint64_t r, w, host;
    do {
        r = atomic_load_explicit(&c->read, memory_order_acquire);
        w = atomic_load_explicit(&c->reserved_write, memory_order_acquire);
        host = w > r ? atomic_load_explicit(&c->hosts[r % c->capacity], memory_order_relaxed) : 0;
    } while (r != atomic_load_explicit(&c->read, memory_order_acquire));
    BFCaptureSnapshot s = { atomic_load(&c->callbacks), atomic_load(&c->empty_callbacks), atomic_load(&c->captured_frames), w - r,
        atomic_load(&c->peak), host, atomic_load(&c->error), atomic_load(&c->cancelled) };
    return s;
}
