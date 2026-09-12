#define _POSIX_C_SOURCE 200809L

#include "djonehub_crypto.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct sha256_state {
    uint32_t hash[8];
    uint64_t bit_count;
    uint8_t block[64];
    size_t used;
};

static uint32_t rotate_right(uint32_t value, unsigned int amount)
{
    return (value >> amount) | (value << (32U - amount));
}

static uint32_t load_be32(const uint8_t *data)
{
    return ((uint32_t)data[0] << 24U) | ((uint32_t)data[1] << 16U) |
           ((uint32_t)data[2] << 8U) | (uint32_t)data[3];
}

static void store_be32(uint8_t *data, uint32_t value)
{
    data[0] = (uint8_t)(value >> 24U);
    data[1] = (uint8_t)(value >> 16U);
    data[2] = (uint8_t)(value >> 8U);
    data[3] = (uint8_t)value;
}

static void sha256_transform(struct sha256_state *state,
                             const uint8_t block[64])
{
    static const uint32_t constants[64] = {
        0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
        0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
        0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
        0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
        0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
        0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
        0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
        0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
        0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
        0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
        0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
        0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
        0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
        0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
        0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
        0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
    };
    uint32_t words[64];
    uint32_t a;
    uint32_t b;
    uint32_t c;
    uint32_t d;
    uint32_t e;
    uint32_t f;
    uint32_t g;
    uint32_t h;
    unsigned int index;

    for (index = 0U; index < 16U; ++index) {
        words[index] = load_be32(block + index * 4U);
    }
    for (index = 16U; index < 64U; ++index) {
        uint32_t first = rotate_right(words[index - 15U], 7U) ^
                         rotate_right(words[index - 15U], 18U) ^
                         (words[index - 15U] >> 3U);
        uint32_t second = rotate_right(words[index - 2U], 17U) ^
                          rotate_right(words[index - 2U], 19U) ^
                          (words[index - 2U] >> 10U);

        words[index] = words[index - 16U] + first + words[index - 7U] +
                       second;
    }
    a = state->hash[0];
    b = state->hash[1];
    c = state->hash[2];
    d = state->hash[3];
    e = state->hash[4];
    f = state->hash[5];
    g = state->hash[6];
    h = state->hash[7];
    for (index = 0U; index < 64U; ++index) {
        uint32_t sum_one = rotate_right(e, 6U) ^ rotate_right(e, 11U) ^
                           rotate_right(e, 25U);
        uint32_t choose = (e & f) ^ ((~e) & g);
        uint32_t temporary_one = h + sum_one + choose + constants[index] +
                                 words[index];
        uint32_t sum_zero = rotate_right(a, 2U) ^ rotate_right(a, 13U) ^
                            rotate_right(a, 22U);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temporary_two = sum_zero + majority;

        h = g;
        g = f;
        f = e;
        e = d + temporary_one;
        d = c;
        c = b;
        b = a;
        a = temporary_one + temporary_two;
    }
    state->hash[0] += a;
    state->hash[1] += b;
    state->hash[2] += c;
    state->hash[3] += d;
    state->hash[4] += e;
    state->hash[5] += f;
    state->hash[6] += g;
    state->hash[7] += h;
}

static void sha256_init(struct sha256_state *state)
{
    static const uint32_t initial_hash[8] = {
        0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U
    };

    memcpy(state->hash, initial_hash, sizeof(initial_hash));
    state->bit_count = 0U;
    state->used = 0U;
}

static void sha256_update(struct sha256_state *state, const uint8_t *data,
                          size_t length)
{
    state->bit_count += (uint64_t)length * 8U;
    while (length != 0U) {
        size_t available = sizeof(state->block) - state->used;
        size_t copied = length < available ? length : available;

        memcpy(state->block + state->used, data, copied);
        state->used += copied;
        data += copied;
        length -= copied;
        if (state->used == sizeof(state->block)) {
            sha256_transform(state, state->block);
            state->used = 0U;
        }
    }
}

static void sha256_final(struct sha256_state *state,
                         uint8_t digest[DJONEHUB_SHA256_BYTES])
{
    uint8_t encoded_length[8];
    unsigned int index;

    for (index = 0U; index < 8U; ++index) {
        encoded_length[index] =
            (uint8_t)(state->bit_count >> (56U - index * 8U));
    }
    state->block[state->used++] = 0x80U;
    while (state->used != 56U) {
        if (state->used == sizeof(state->block)) {
            sha256_transform(state, state->block);
            state->used = 0U;
        }
        state->block[state->used++] = 0U;
    }
    memcpy(state->block + 56U, encoded_length, sizeof(encoded_length));
    sha256_transform(state, state->block);
    for (index = 0U; index < 8U; ++index) {
        store_be32(digest + index * 4U, state->hash[index]);
    }
    memset(state, 0, sizeof(*state));
}

void djonehub_hmac_sha256(const uint8_t *key, size_t key_length,
                          const uint8_t *data, size_t data_length,
                          uint8_t digest[DJONEHUB_SHA256_BYTES])
{
    struct sha256_state state;
    uint8_t key_block[64];
    uint8_t inner_digest[DJONEHUB_SHA256_BYTES];
    unsigned int index;

    memset(key_block, 0, sizeof(key_block));
    if (key_length > sizeof(key_block)) {
        sha256_init(&state);
        sha256_update(&state, key, key_length);
        sha256_final(&state, key_block);
    } else if (key_length != 0U) {
        memcpy(key_block, key, key_length);
    }
    for (index = 0U; index < sizeof(key_block); ++index) {
        key_block[index] ^= 0x36U;
    }
    sha256_init(&state);
    sha256_update(&state, key_block, sizeof(key_block));
    sha256_update(&state, data, data_length);
    sha256_final(&state, inner_digest);
    for (index = 0U; index < sizeof(key_block); ++index) {
        key_block[index] ^= 0x36U ^ 0x5cU;
    }
    sha256_init(&state);
    sha256_update(&state, key_block, sizeof(key_block));
    sha256_update(&state, inner_digest, sizeof(inner_digest));
    sha256_final(&state, digest);
    memset(key_block, 0, sizeof(key_block));
    memset(inner_digest, 0, sizeof(inner_digest));
}

int djonehub_secure_equal(const uint8_t *left, const uint8_t *right,
                          size_t length)
{
    volatile uint8_t difference = 0U;
    size_t index;

    if (left == NULL || right == NULL) {
        return 0;
    }
    for (index = 0U; index < length; ++index) {
        difference |= (uint8_t)(left[index] ^ right[index]);
    }
    return difference == 0U;
}

int djonehub_load_pairing_key(const char *path,
                              uint8_t key[DJONEHUB_PAIRING_KEY_BYTES])
{
    struct stat attributes;
    uint8_t extra;
    size_t offset = 0U;
    ssize_t count;
    int close_result;
    int descriptor;

    if (path == NULL || key == NULL) {
        errno = EINVAL;
        return -1;
    }
#ifdef O_NOFOLLOW
    descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
#else
    descriptor = open(path, O_RDONLY | O_CLOEXEC);
#endif
    if (descriptor < 0) {
        return -1;
    }
    if (fstat(descriptor, &attributes) != 0 ||
        !S_ISREG(attributes.st_mode) || (attributes.st_mode & 0077) != 0) {
        (void)close(descriptor);
        errno = EACCES;
        return -1;
    }
    while (offset < DJONEHUB_PAIRING_KEY_BYTES) {
        count = read(descriptor, key + offset,
                     DJONEHUB_PAIRING_KEY_BYTES - offset);
        if (count > 0) {
            offset += (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            memset(key, 0, DJONEHUB_PAIRING_KEY_BYTES);
            (void)close(descriptor);
            errno = EINVAL;
            return -1;
        }
    }
    do {
        count = read(descriptor, &extra, sizeof(extra));
    } while (count < 0 && errno == EINTR);
    close_result = close(descriptor);
    if (count != 0 || close_result != 0) {
        memset(key, 0, DJONEHUB_PAIRING_KEY_BYTES);
        if (count != 0) {
            errno = EINVAL;
        }
        return -1;
    }
    return 0;
}
