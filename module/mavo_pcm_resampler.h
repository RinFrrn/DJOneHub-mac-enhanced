#ifndef MAVO_PCM_RESAMPLER_H
#define MAVO_PCM_RESAMPLER_H

#include <stddef.h>
#include <stdint.h>

#define MAVO_PCM_RESAMPLE_FACTOR 6U
#define MAVO_PCM_DECIMATOR_TAPS 127U
#define MAVO_PCM_COEFFICIENT_SCALE 32768LL

struct mavo_pcm_upsampler {
    int16_t previous;
    int initialized;
};

struct mavo_pcm_downsampler {
    int16_t history[MAVO_PCM_DECIMATOR_TAPS];
    unsigned int next;
    unsigned int phase;
};

/*
 * 127-tap Blackman-windowed low-pass, cutoff 3600 Hz at 48 kHz. Coefficients
 * are signed Q15 and sum to exactly 32768, preserving DC gain. The response
 * is about -1.2 dB at 3.2 kHz, -17.8 dB at 4 kHz and -43 dB at 4.4 kHz.
 */
static const int16_t mavo_pcm_decimator_coefficients[] = {
    0, 0, 0, 0, 0, 1, 2, 2, 2, 1, -1, -4, -7, -9, -10, -8,
    -2, 6, 15, 23, 28, 26, 17, 0, -22, -44, -60, -65, -54, -27, 15,
    63, 106, 132, 130, 95, 28, -60, -152, -225, -257, -231, -142, 0,
    171, 335, 449, 476, 390, 188, -105, -441, -746, -941, -950, -718,
    -222, 518, 1438, 2440, 3403, 4202, 4731, 4908, 4731, 4202, 3403,
    2440, 1438, 518, -222, -718, -950, -941, -746, -441, -105, 188,
    390, 476, 449, 335, 171, 0, -142, -231, -257, -225, -152, -60,
    28, 95, 130, 132, 106, 63, 15, -27, -54, -65, -60, -44, -22, 0,
    17, 26, 28, 23, 15, 6, -2, -8, -10, -9, -7, -4, -1, 1, 2, 2,
    2, 1, 0, 0, 0, 0, 0
};

_Static_assert(sizeof(mavo_pcm_decimator_coefficients) /
                       sizeof(mavo_pcm_decimator_coefficients[0]) ==
                   MAVO_PCM_DECIMATOR_TAPS,
               "unexpected decimator coefficient count");

static int16_t mavo_pcm_clip_s16(int64_t value)
{
    if (value > INT16_MAX) {
        return INT16_MAX;
    }
    if (value < INT16_MIN) {
        return INT16_MIN;
    }
    return (int16_t)value;
}

static void mavo_pcm_upsampler_reset(struct mavo_pcm_upsampler *state)
{
    state->previous = 0;
    state->initialized = 0;
}

static void mavo_pcm_downsampler_reset(struct mavo_pcm_downsampler *state)
{
    unsigned int index;

    for (index = 0U; index < MAVO_PCM_DECIMATOR_TAPS; ++index) {
        state->history[index] = 0;
    }
    state->next = 0U;
    state->phase = 0U;
}

/*
 * First-order hold interpolation. Each new 8 kHz sample completes the ramp
 * from the preceding sample, so the state remains continuous across packets.
 */
static void mavo_pcm_upsample_8k_to_48k(
    struct mavo_pcm_upsampler *state, const int16_t *input,
    size_t input_samples, int16_t *output)
{
    size_t input_index;

    for (input_index = 0U; input_index < input_samples; ++input_index) {
        int16_t current = input[input_index];
        int32_t previous;
        int32_t delta;
        unsigned int phase;

        if (!state->initialized) {
            state->previous = current;
            state->initialized = 1;
        }
        previous = (int32_t)state->previous;
        delta = (int32_t)current - previous;
        for (phase = 0U; phase < MAVO_PCM_RESAMPLE_FACTOR; ++phase) {
            int32_t numerator =
                delta * (int32_t)(phase + 1U);
            int32_t interpolated =
                previous + numerator / (int32_t)MAVO_PCM_RESAMPLE_FACTOR;

            output[input_index * MAVO_PCM_RESAMPLE_FACTOR + phase] =
                mavo_pcm_clip_s16((int64_t)interpolated);
        }
        state->previous = current;
    }
}

/* Returns SIZE_MAX without changing state if output_capacity is insufficient. */
static size_t mavo_pcm_downsample_48k_to_8k(
    struct mavo_pcm_downsampler *state, const int16_t *input,
    size_t input_samples, int16_t *output, size_t output_capacity)
{
    size_t required =
        ((size_t)state->phase + input_samples) / MAVO_PCM_RESAMPLE_FACTOR;
    size_t input_index;
    size_t produced = 0U;

    if (required > output_capacity) {
        return SIZE_MAX;
    }
    for (input_index = 0U; input_index < input_samples; ++input_index) {
        unsigned int coefficient;
        unsigned int history_index;
        int64_t accumulator = 0LL;
        int64_t rounded;

        state->history[state->next] = input[input_index];
        state->next = (state->next + 1U) % MAVO_PCM_DECIMATOR_TAPS;
        state->phase += 1U;
        if (state->phase != MAVO_PCM_RESAMPLE_FACTOR) {
            continue;
        }
        state->phase = 0U;
        history_index = state->next == 0U
            ? MAVO_PCM_DECIMATOR_TAPS - 1U
            : state->next - 1U;
        for (coefficient = 0U; coefficient < MAVO_PCM_DECIMATOR_TAPS;
             ++coefficient) {
            accumulator +=
                (int64_t)mavo_pcm_decimator_coefficients[coefficient] *
                (int64_t)state->history[history_index];
            history_index = history_index == 0U
                ? MAVO_PCM_DECIMATOR_TAPS - 1U
                : history_index - 1U;
        }
        rounded = accumulator >= 0LL
            ? (accumulator + MAVO_PCM_COEFFICIENT_SCALE / 2LL) /
                  MAVO_PCM_COEFFICIENT_SCALE
            : -((-accumulator + MAVO_PCM_COEFFICIENT_SCALE / 2LL) /
                MAVO_PCM_COEFFICIENT_SCALE);
        output[produced++] = mavo_pcm_clip_s16(rounded);
    }
    return produced;
}

#endif
