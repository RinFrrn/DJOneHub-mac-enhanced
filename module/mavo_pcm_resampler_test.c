#include "mavo_pcm_resampler.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition)                                                     \
    do {                                                                     \
        if (!(condition)) {                                                  \
            fprintf(stderr, "check failed at line %d: %s\n", __LINE__,      \
                    #condition);                                             \
            return EXIT_FAILURE;                                             \
        }                                                                    \
    } while (0)

static int test_upsampler_continuity(void)
{
    const int16_t first[] = {0, 600};
    const int16_t second[] = {1200};
    const int16_t expected[] = {
        0, 0, 0, 0, 0, 0, 100, 200, 300, 400, 500, 600,
        700, 800, 900, 1000, 1100, 1200
    };
    struct mavo_pcm_upsampler state;
    int16_t output[18];

    mavo_pcm_upsampler_reset(&state);
    mavo_pcm_upsample_8k_to_48k(&state, first, 2U, output);
    mavo_pcm_upsample_8k_to_48k(&state, second, 1U, output + 12U);
    CHECK(memcmp(output, expected, sizeof(expected)) == 0);
    return EXIT_SUCCESS;
}

static int test_downsampler_split_matches_contiguous(void)
{
    struct mavo_pcm_downsampler contiguous_state;
    struct mavo_pcm_downsampler split_state;
    int16_t input[960];
    int16_t contiguous[160];
    int16_t split[160];
    size_t first_count;
    size_t second_count;
    size_t contiguous_count;
    size_t index;

    for (index = 0U; index < 960U; ++index) {
        input[index] = (int16_t)((int)(index % 401U) * 97 - 19400);
    }
    mavo_pcm_downsampler_reset(&contiguous_state);
    mavo_pcm_downsampler_reset(&split_state);
    contiguous_count = mavo_pcm_downsample_48k_to_8k(
        &contiguous_state, input, 960U, contiguous, 160U);
    first_count = mavo_pcm_downsample_48k_to_8k(
        &split_state, input, 317U, split, 160U);
    second_count = mavo_pcm_downsample_48k_to_8k(
        &split_state, input + 317U, 643U, split + first_count,
        160U - first_count);
    CHECK(contiguous_count == 160U);
    CHECK(first_count + second_count == contiguous_count);
    CHECK(memcmp(contiguous, split, sizeof(contiguous)) == 0);
    return EXIT_SUCCESS;
}

static double filtered_tone_rms(double frequency)
{
    struct mavo_pcm_downsampler state;
    int16_t input[4800];
    int16_t output[800];
    size_t produced;
    size_t index;
    double energy = 0.0;

    for (index = 0U; index < 4800U; ++index) {
        double phase = 6.28318530717958647693 * frequency *
                       (double)index / 48000.0;
        input[index] = (int16_t)lrint(12000.0 * sin(phase));
    }
    mavo_pcm_downsampler_reset(&state);
    produced = mavo_pcm_downsample_48k_to_8k(
        &state, input, 4800U, output, 800U);
    if (produced != 800U) {
        return -1.0;
    }
    for (index = 128U; index < produced; ++index) {
        double sample = (double)output[index];
        energy += sample * sample;
    }
    return sqrt(energy / (double)(produced - 128U));
}

static int test_downsampler_low_pass(void)
{
    double passband = filtered_tone_rms(1000.0);
    double rejected = filtered_tone_rms(12000.0);

    CHECK(passband > 8000.0);
    CHECK(rejected >= 0.0);
    CHECK(rejected < passband / 100.0);
    return EXIT_SUCCESS;
}

static int test_downsampler_preserves_dc(void)
{
    struct mavo_pcm_downsampler state;
    int16_t input[960];
    int16_t output[160];
    size_t produced;
    size_t index;

    for (index = 0U; index < 960U; ++index) {
        input[index] = 10000;
    }
    mavo_pcm_downsampler_reset(&state);
    produced = mavo_pcm_downsample_48k_to_8k(
        &state, input, 960U, output, 160U);
    CHECK(produced == 160U);
    CHECK(output[159] == 10000);
    return EXIT_SUCCESS;
}

static int test_downsampler_capacity_failure_preserves_state(void)
{
    struct mavo_pcm_downsampler state;
    struct mavo_pcm_downsampler before;
    const int16_t input[] = {100, 200, 300, 400, 500, 600};
    int16_t output = 1234;
    size_t produced;

    mavo_pcm_downsampler_reset(&state);
    before = state;
    produced = mavo_pcm_downsample_48k_to_8k(
        &state, input, 6U, &output, 0U);
    CHECK(produced == SIZE_MAX);
    CHECK(memcmp(&state, &before, sizeof(state)) == 0);
    CHECK(output == 1234);
    return EXIT_SUCCESS;
}

int main(void)
{
    CHECK(test_upsampler_continuity() == EXIT_SUCCESS);
    CHECK(test_downsampler_split_matches_contiguous() == EXIT_SUCCESS);
    CHECK(test_downsampler_low_pass() == EXIT_SUCCESS);
    CHECK(test_downsampler_preserves_dc() == EXIT_SUCCESS);
    CHECK(test_downsampler_capacity_failure_preserves_state() == EXIT_SUCCESS);
    puts("mavo_pcm_resampler_test: PASS");
    return EXIT_SUCCESS;
}
