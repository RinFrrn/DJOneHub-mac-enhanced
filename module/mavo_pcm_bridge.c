/*
 * MaVo raw voice bridge for Quectel MDM9x07 modules.
 *
 * This recreates the user-space part of AT+QPCMV=1,0 found in standard
 * Quectel firmware.  It does not dial a call and it does not change the USB
 * gadget layout.  It may start shortly before a call and waits a bounded time
 * for the voice PCM path; the Mac side exchanges signed 16-bit, mono, 8 kHz
 * PCM through /dev/ttyGS0.
 */

#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <net/if.h>
#endif

#define DEFAULT_AUDIO_LIBRARY "libql_lib_audio.so.1"
#define DEFAULT_TTY_DEVICE "/dev/ttyGS0"
#define PCM_DEVICE "hw:0,0"

#define PCM_RATE 8000U
#define PCM_CHANNELS 1U
#define PCM_FORMAT_S16_LE 2U
#define PCM_HOSTLESS 0U
#define PCM_PLAYBACK_FLAGS 0x01000000U
#define PCM_CAPTURE_FLAGS 0x11000000U

#define VOICE_PCM_DEVICE "hw:0,4"
#define VOICE_PLAYBACK_FLAGS 0x01000001U
#define VOICE_CAPTURE_FLAGS 0x11000001U
#define VOICE_HOSTLESS 1U
#define VOICE_LEGACY_DOWNLINK_MIXER "SEC_AUX_PCM_RX_Voice Mixer VoLTE"
#define VOICE_LEGACY_UPLINK_MIXER "VoLTE_Tx Mixer SEC_AUX_PCM_TX_VoLTE"
#define VOICE_DOWNLINK_MIXER "AFE_PCM_RX_Voice Mixer VoLTE"
#define VOICE_UPLINK_MIXER "VoLTE_Tx Mixer AFE_PCM_TX_VoLTE"
#define VOICE_AUDIO_ENABLE_PATH "/sys/class/android_usb/f_audio/audio_enable"
#define NETWORK_UPLINK_PCM_DEVICE "hw:0,0"
#define NETWORK_DOWNLINK_PCM_DEVICE "hw:0,6"
#define INCALL_DOWNLINK_PCM_DEVICE "hw:0,0"
#define NETWORK_PCM_FRAME_BYTES 256U
#define NETWORK_PCM_FRAME_SAMPLES (NETWORK_PCM_FRAME_BYTES / 2U)
#define NETWORK_UPLINK_DEVICE_RATE 48000U
#define NETWORK_UPLINK_RATE_MULTIPLIER \
    (NETWORK_UPLINK_DEVICE_RATE / PCM_RATE)
#define NETWORK_UPLINK_DEVICE_FRAME_BYTES \
    (NETWORK_PCM_FRAME_BYTES * NETWORK_UPLINK_RATE_MULTIPLIER)
#define NETWORK_PCM_FRAME_USEC \
    ((NETWORK_PCM_FRAME_SAMPLES * 1000000U) / PCM_RATE)
#define NETWORK_PROBE_DURATION_USEC 3000000U
#define NETWORK_PACKET_HEADER_BYTES 20U
#define NETWORK_PACKET_TAG_BYTES 16U
#define NETWORK_PACKET_BYTES (NETWORK_PACKET_HEADER_BYTES + \
                              NETWORK_PCM_FRAME_BYTES + \
                              NETWORK_PACKET_TAG_BYTES)
#define NETWORK_PACKET_MAGIC 0x444A4F41U
#define NETWORK_PACKET_VERSION 1U
#define NETWORK_DIRECTION_UPLINK 1U
#define NETWORK_DIRECTION_DOWNLINK 2U
#define NETWORK_AUDIO_PORT 45751U
#define NETWORK_SESSION_TIMEOUT_USEC 3000000LL
#define NETWORK_POLL_USEC NETWORK_PCM_FRAME_USEC
#define UPLINK_JITTER_CAPACITY 16U

#define IDLE_RETRY_USEC 20000U
#define STARTUP_RETRY_USEC 200000U
#define STARTUP_RETRY_LIMIT 100U
#define PARTIAL_WRITE_RETRY_USEC 5000U
#define SHUTDOWN_GRACE_USEC 3000000U
#define CANCEL_GRACE_USEC 1000000U

#define MIXER_UPLINK_AFE "AFE_PCM_RX Audio Mixer MultiMedia1"
#define MIXER_UPLINK "Incall_Music Audio Mixer MultiMedia1"
#define MIXER_DOWNLINK "MultiMedia1 Mixer VOC_REC_DL"

typedef void *(*quec_pcm_open_fn)(const char *, unsigned int, unsigned int,
                                  unsigned int, unsigned int, unsigned int);
typedef int (*quec_pcm_close_fn)(void *);
typedef int (*quec_pcm_io_fn)(void *, void *, unsigned int);
typedef unsigned int (*quec_pcm_buffer_len_fn)(void *);
typedef int (*quec_set_mixer_fn)(const char *, int, const char *);

struct vendor_audio {
    void *library;
    quec_pcm_open_fn pcm_open;
    quec_pcm_close_fn pcm_close;
    quec_pcm_io_fn pcm_read;
    quec_pcm_io_fn pcm_write;
    quec_pcm_buffer_len_fn pcm_buffer_len;
    quec_set_mixer_fn set_mixer;
};

struct bridge_context {
    struct vendor_audio api;
    int tty_fd;
    const char *playback_device;
    const char *capture_device;
    struct termios saved_tty_attributes;
    int tty_attributes_saved;
    int use_mixers;
    int verbose;
    volatile int worker_failed;
};

static volatile sig_atomic_t stop_requested;

#if !defined(__GCC_ATOMIC_INT_LOCK_FREE) || __GCC_ATOMIC_INT_LOCK_FREE != 2
#error "This bridge requires lock-free int atomics on the target ABI"
#endif

static int should_stop(void)
{
    return __atomic_load_n(&stop_requested, __ATOMIC_RELAXED) != 0;
}

static void request_worker_stop(void)
{
    __atomic_store_n(&stop_requested, 1, __ATOMIC_RELAXED);
}

static void mark_worker_failed(struct bridge_context *context)
{
    __atomic_store_n(&context->worker_failed, 1, __ATOMIC_RELAXED);
    request_worker_stop();
}

static int worker_failed(const struct bridge_context *context)
{
    return __atomic_load_n(&context->worker_failed, __ATOMIC_RELAXED) != 0;
}

static void log_message(const char *level, const char *format, ...)
{
    char buffer[1024];
    va_list arguments;
    size_t used;
    size_t available;
    int count;
    ssize_t ignored;

    count = snprintf(buffer, sizeof(buffer), "mavo-pcm-bridge[%s]: ",
                     level);
    if (count < 0) {
        return;
    }
    used = (size_t)count;
    if (used >= sizeof(buffer) - 1U) {
        used = sizeof(buffer) - 2U;
    }
    available = sizeof(buffer) - used;
    va_start(arguments, format);
    count = vsnprintf(buffer + used, available, format, arguments);
    va_end(arguments);
    if (count < 0) {
        return;
    }
    if ((size_t)count >= available) {
        used = sizeof(buffer) - 2U;
    } else {
        used += (size_t)count;
    }
    buffer[used++] = '\n';

    do {
        ignored = write(STDERR_FILENO, buffer, used);
    } while (ignored < 0 && errno == EINTR);
}

struct sha256_state {
    uint32_t hash[8];
    uint64_t bit_count;
    unsigned char block[64];
    size_t used;
};

static uint32_t sha256_rotr(uint32_t value, unsigned int amount)
{
    return (value >> amount) | (value << (32U - amount));
}

static uint32_t sha256_load_be32(const unsigned char *data)
{
    return ((uint32_t)data[0] << 24U) | ((uint32_t)data[1] << 16U) |
           ((uint32_t)data[2] << 8U) | (uint32_t)data[3];
}

static void sha256_store_be32(unsigned char *data, uint32_t value)
{
    data[0] = (unsigned char)(value >> 24U);
    data[1] = (unsigned char)(value >> 16U);
    data[2] = (unsigned char)(value >> 8U);
    data[3] = (unsigned char)value;
}

static void sha256_transform(struct sha256_state *state,
                             const unsigned char *block)
{
    static const uint32_t round_constants[64] = {
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
    uint32_t schedule[64];
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
        schedule[index] = sha256_load_be32(block + index * 4U);
    }
    for (index = 16U; index < 64U; ++index) {
        uint32_t s0 = sha256_rotr(schedule[index - 15U], 7U) ^
                      sha256_rotr(schedule[index - 15U], 18U) ^
                      (schedule[index - 15U] >> 3U);
        uint32_t s1 = sha256_rotr(schedule[index - 2U], 17U) ^
                      sha256_rotr(schedule[index - 2U], 19U) ^
                      (schedule[index - 2U] >> 10U);
        schedule[index] = schedule[index - 16U] + s0 +
                          schedule[index - 7U] + s1;
    }
    a = state->hash[0]; b = state->hash[1]; c = state->hash[2];
    d = state->hash[3]; e = state->hash[4]; f = state->hash[5];
    g = state->hash[6]; h = state->hash[7];
    for (index = 0U; index < 64U; ++index) {
        uint32_t sum1 = sha256_rotr(e, 6U) ^ sha256_rotr(e, 11U) ^
                        sha256_rotr(e, 25U);
        uint32_t choose = (e & f) ^ ((~e) & g);
        uint32_t temporary1 = h + sum1 + choose + round_constants[index] +
                              schedule[index];
        uint32_t sum0 = sha256_rotr(a, 2U) ^ sha256_rotr(a, 13U) ^
                        sha256_rotr(a, 22U);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temporary2 = sum0 + majority;
        h = g; g = f; f = e; e = d + temporary1;
        d = c; c = b; b = a; a = temporary1 + temporary2;
    }
    state->hash[0] += a; state->hash[1] += b; state->hash[2] += c;
    state->hash[3] += d; state->hash[4] += e; state->hash[5] += f;
    state->hash[6] += g; state->hash[7] += h;
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

static void sha256_update(struct sha256_state *state, const void *data,
                          size_t length)
{
    const unsigned char *bytes = data;

    state->bit_count += (uint64_t)length * 8U;
    while (length != 0U) {
        size_t available = sizeof(state->block) - state->used;
        size_t copied = length < available ? length : available;

        memcpy(state->block + state->used, bytes, copied);
        state->used += copied;
        bytes += copied;
        length -= copied;
        if (state->used == sizeof(state->block)) {
            sha256_transform(state, state->block);
            state->used = 0U;
        }
    }
}

static void sha256_final(struct sha256_state *state, unsigned char digest[32])
{
    unsigned char length_bytes[8];
    unsigned int index;

    for (index = 0U; index < 8U; ++index) {
        length_bytes[index] = (unsigned char)(state->bit_count >>
                                               (56U - index * 8U));
    }
    state->block[state->used++] = 0x80U;
    while (state->used != 56U) {
        if (state->used == sizeof(state->block)) {
            sha256_transform(state, state->block);
            state->used = 0U;
        }
        state->block[state->used++] = 0U;
    }
    memcpy(state->block + 56U, length_bytes, sizeof(length_bytes));
    sha256_transform(state, state->block);
    for (index = 0U; index < 8U; ++index) {
        sha256_store_be32(digest + index * 4U, state->hash[index]);
    }
}

static void hmac_sha256(const unsigned char *key, size_t key_length,
                        const unsigned char *data, size_t data_length,
                        unsigned char digest[32])
{
    struct sha256_state state;
    unsigned char key_block[64];
    unsigned char inner_digest[32];
    unsigned int index;

    memset(key_block, 0, sizeof(key_block));
    if (key_length > sizeof(key_block)) {
        sha256_init(&state);
        sha256_update(&state, key, key_length);
        sha256_final(&state, key_block);
    } else {
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
}

static int secure_equal(const unsigned char *left, const unsigned char *right,
                        size_t length)
{
    volatile unsigned char difference = 0U;
    size_t index;

    for (index = 0U; index < length; ++index) {
        difference |= (unsigned char)(left[index] ^ right[index]);
    }
    return difference == 0U;
}

static void request_stop(int signal_number)
{
    (void)signal_number;
    request_worker_stop();
}

static int install_signal_handlers(void)
{
    struct sigaction action;

    memset(&action, 0, sizeof(action));
    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);

    if (sigaction(SIGINT, &action, NULL) != 0 ||
        sigaction(SIGTERM, &action, NULL) != 0) {
        log_message("error", "sigaction failed: %s", strerror(errno));
        return -1;
    }

    /* Do not install a SIGHUP handler.  An ignored disposition inherited from
     * nohup survives exec and must remain ignored when the ADB shell exits. */

    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_IGN;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPIPE, &action, NULL) != 0) {
        log_message("error", "could not ignore SIGPIPE: %s", strerror(errno));
        return -1;
    }
    return 0;
}

static int load_symbol(void *library, const char *name, void *destination,
                       size_t destination_size)
{
    void *symbol;
    const char *error;

    dlerror();
    symbol = dlsym(library, name);
    error = dlerror();
    if (error != NULL || symbol == NULL) {
        log_message("error", "missing %s: %s", name,
                    error != NULL ? error : "symbol is null");
        return -1;
    }

    if (destination_size != sizeof(symbol)) {
        log_message("error", "unexpected function pointer size for %s", name);
        return -1;
    }
    memcpy(destination, &symbol, sizeof(symbol));
    return 0;
}

#define LOAD_API(api, member, symbol_name)                                      \
    load_symbol((api)->library, (symbol_name), &(api)->member,                  \
                sizeof((api)->member))

static int load_vendor_audio(struct vendor_audio *api, const char *library_path)
{
    memset(api, 0, sizeof(*api));

    api->library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (api->library == NULL) {
        log_message("error", "dlopen(%s) failed: %s", library_path, dlerror());
        return -1;
    }

    if (LOAD_API(api, pcm_open, "quec_pcm_open") != 0 ||
        LOAD_API(api, pcm_close, "quec_pcm_close") != 0 ||
        LOAD_API(api, pcm_read, "quec_read_pcm") != 0 ||
        LOAD_API(api, pcm_write, "quec_write_pcm") != 0 ||
        LOAD_API(api, pcm_buffer_len, "quec_get_pem_buffer_len") != 0 ||
        LOAD_API(api, set_mixer, "quectel_clt_set_mixer_value") != 0) {
        dlclose(api->library);
        memset(api, 0, sizeof(*api));
        return -1;
    }

    return 0;
}

static void unload_vendor_audio(struct vendor_audio *api)
{
    if (api->library != NULL) {
        dlclose(api->library);
    }
    memset(api, 0, sizeof(*api));
}

static int set_tty_attributes(int fd, const struct termios *attributes)
{
    int result;

    do {
        result = tcsetattr(fd, TCSANOW, attributes);
    } while (result != 0 && errno == EINTR);
    return result;
}

static int flush_tty(int fd)
{
    int result;

    do {
        result = tcflush(fd, TCIOFLUSH);
    } while (result != 0 && errno == EINTR);
    return result;
}

static int configure_raw_tty(struct bridge_context *context)
{
    struct termios attributes;
    int result;

    do {
        result = tcgetattr(context->tty_fd, &context->saved_tty_attributes);
    } while (result != 0 && errno == EINTR);
    if (result != 0) {
        log_message("error", "tcgetattr failed: %s", strerror(errno));
        return -1;
    }
    context->tty_attributes_saved = 1;
    attributes = context->saved_tty_attributes;

    cfmakeraw(&attributes);
    attributes.c_cflag &= (tcflag_t)~(tcflag_t)(CSIZE | PARENB | CSTOPB);
#ifdef CRTSCTS
    attributes.c_cflag &= (tcflag_t)~(tcflag_t)CRTSCTS;
#endif
    attributes.c_cflag |= CS8 | CLOCAL | CREAD;
    attributes.c_cc[VMIN] = 0;
    attributes.c_cc[VTIME] = 0;

    if (set_tty_attributes(context->tty_fd, &attributes) != 0) {
        log_message("error", "tcsetattr failed: %s", strerror(errno));
        return -1;
    }
    if (flush_tty(context->tty_fd) != 0) {
        log_message("warn", "initial tcflush failed: %s", strerror(errno));
    }
    return 0;
}

static int restore_tty(struct bridge_context *context)
{
    int result = 0;

    if (context->tty_fd < 0 || !context->tty_attributes_saved) {
        return 0;
    }
    if (flush_tty(context->tty_fd) != 0 && errno != EIO) {
        log_message("warn", "final tcflush failed: %s", strerror(errno));
        result = -1;
    }
    if (set_tty_attributes(context->tty_fd,
                           &context->saved_tty_attributes) != 0) {
        log_message("error", "could not restore tty attributes: %s",
                    strerror(errno));
        result = -1;
    }
    context->tty_attributes_saved = 0;
    return result;
}

static int valid_buffer_length(unsigned int length)
{
    /* Protect against an ABI mismatch before allocating or issuing I/O. */
    return length >= 160U && length <= 65536U && (length & 1U) == 0U;
}

static int enable_mixer_with_retry(struct bridge_context *context,
                                   const char *mixer_name)
{
    unsigned int attempt;

    for (attempt = 1U; attempt <= STARTUP_RETRY_LIMIT && !should_stop();
         ++attempt) {
        if (context->api.set_mixer(mixer_name, 1, "1") != 0) {
            return 1;
        }
        if (context->verbose && attempt == 1U) {
            log_message("info", "waiting for mixer %s", mixer_name);
        }
        usleep(STARTUP_RETRY_USEC);
    }
    return 0;
}

static void *open_pcm_with_retry(struct bridge_context *context,
                                 const char *device, unsigned int flags,
                                 const char *direction)
{
    unsigned int attempt;

    for (attempt = 1U; attempt <= STARTUP_RETRY_LIMIT && !should_stop();
         ++attempt) {
        void *pcm = context->api.pcm_open(
            device, flags, PCM_RATE, PCM_CHANNELS, PCM_FORMAT_S16_LE,
            PCM_HOSTLESS);

        if (pcm != NULL) {
            return pcm;
        }
        if (context->verbose && attempt == 1U) {
            log_message("info", "waiting for %s PCM %s", direction,
                        device);
        }
        usleep(STARTUP_RETRY_USEC);
    }
    return NULL;
}

static int set_voice_mixer(struct vendor_audio *api, const char *name,
                           const char *value)
{
    if (api->set_mixer(name, 1, value) == 0) {
        log_message("error", "could not set mixer %s=%s", name, value);
        return -1;
    }
    return 0;
}

static void disable_legacy_voice_mixer(struct vendor_audio *api,
                                       const char *name, int *changed)
{
    *changed = 0;
    if (api->set_mixer(name, 1, "0") == 0) {
        /*
         * The vendor setter uses a false return both when an optional legacy
         * path is already disabled and when that path is unavailable.  Those
         * states need no rollback and must not prevent the AFE voice route
         * from being selected.  Enabling the AFE paths remains mandatory.
         */
        log_message("warn", "legacy mixer %s already disabled or unavailable; "
                    "continuing", name);
        return;
    }
    *changed = 1;
}

static int set_voice_audio_enabled(int enabled)
{
    const char *value = enabled != 0 ? "1\n" : "0\n";
    int fd;
    int saved_errno;
    ssize_t written;

    do {
        fd = open(VOICE_AUDIO_ENABLE_PATH, O_WRONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        log_message("error", "open(%s) failed: %s", VOICE_AUDIO_ENABLE_PATH,
                    strerror(errno));
        return -1;
    }

    do {
        written = write(fd, value, 2U);
    } while (written < 0 && errno == EINTR);
    saved_errno = errno;
    if (close(fd) != 0 && written == (ssize_t)2) {
        saved_errno = errno;
        written = -1;
    }
    if (written != (ssize_t)2) {
        if (written >= 0) {
            log_message("error", "short write to %s", VOICE_AUDIO_ENABLE_PATH);
        } else {
            log_message("error", "write(%s) failed: %s",
                        VOICE_AUDIO_ENABLE_PATH, strerror(saved_errno));
        }
        return -1;
    }
    return 0;
}

static int get_voice_audio_enabled(int *enabled)
{
    unsigned char value;
    int fd;
    int saved_errno;
    ssize_t received;

    do {
        fd = open(VOICE_AUDIO_ENABLE_PATH, O_RDONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        log_message("error", "open(%s) failed: %s", VOICE_AUDIO_ENABLE_PATH,
                    strerror(errno));
        return -1;
    }

    do {
        received = read(fd, &value, 1U);
    } while (received < 0 && errno == EINTR);
    saved_errno = errno;
    if (close(fd) != 0 && received == (ssize_t)1) {
        saved_errno = errno;
        received = -1;
    }
    if (received != (ssize_t)1) {
        log_message("error", "read(%s) failed: %s", VOICE_AUDIO_ENABLE_PATH,
                    received == 0 ? "empty value" : strerror(saved_errno));
        return -1;
    }
    if (value != (unsigned char)'0' && value != (unsigned char)'1') {
        log_message("error", "unexpected value in %s: 0x%02x",
                    VOICE_AUDIO_ENABLE_PATH, (unsigned int)value);
        return -1;
    }
    *enabled = value == (unsigned char)'1' ? 1 : 0;
    return 0;
}

struct voice_route_state {
    void *playback;
    void *capture;
    int legacy_downlink_disabled;
    int legacy_uplink_disabled;
    int downlink_enabled;
    int uplink_enabled;
    int usb_audio_enabled;
};

struct voice_session_anchor {
    void *playback;
    void *capture;
};

static int voice_session_anchor_stop(struct vendor_audio *api,
                                     struct voice_session_anchor *anchor)
{
    int result = EXIT_SUCCESS;

    if (anchor->playback != NULL) {
        if (api->pcm_close(anchor->playback) != 0) {
            log_message("warn", "could not close VoLTE playback anchor");
            result = EXIT_FAILURE;
        }
        anchor->playback = NULL;
    }
    if (anchor->capture != NULL) {
        if (api->pcm_close(anchor->capture) != 0) {
            log_message("warn", "could not close VoLTE capture anchor");
            result = EXIT_FAILURE;
        }
        anchor->capture = NULL;
    }
    return result;
}

static int voice_session_anchor_start(struct vendor_audio *api,
                                      struct voice_session_anchor *anchor)
{
    memset(anchor, 0, sizeof(*anchor));
    if (set_voice_mixer(api, VOICE_LEGACY_DOWNLINK_MIXER, "1") != 0) {
        log_message("error", "could not enable VoLTE SEC_AUX downlink route");
        return EXIT_FAILURE;
    }
    if (set_voice_mixer(api, VOICE_LEGACY_UPLINK_MIXER, "1") != 0) {
        log_message("error", "could not enable VoLTE SEC_AUX uplink route");
        return EXIT_FAILURE;
    }
    anchor->capture = api->pcm_open(
        VOICE_PCM_DEVICE, VOICE_CAPTURE_FLAGS, PCM_RATE, PCM_CHANNELS,
        PCM_FORMAT_S16_LE, VOICE_HOSTLESS);
    if (anchor->capture == NULL) {
        log_message("error", "could not open VoLTE capture session anchor");
        goto failed;
    }
    anchor->playback = api->pcm_open(
        VOICE_PCM_DEVICE, VOICE_PLAYBACK_FLAGS, PCM_RATE, PCM_CHANNELS,
        PCM_FORMAT_S16_LE, VOICE_HOSTLESS);
    if (anchor->playback == NULL) {
        log_message("error", "could not open VoLTE playback session anchor");
        goto failed;
    }
    log_message("info", "VoLTE hostless session anchor active on %s; "
                "existing SEC_AUX mixers preserved", VOICE_PCM_DEVICE);
    return EXIT_SUCCESS;

failed:
    (void)voice_session_anchor_stop(api, anchor);
    return EXIT_FAILURE;
}

static int voice_route_stop(struct vendor_audio *api,
                            struct voice_route_state *state);

static int voice_route_start(struct vendor_audio *api, int enable_usb_audio,
                             struct voice_route_state *state)
{
    memset(state, 0, sizeof(*state));

    disable_legacy_voice_mixer(api, VOICE_LEGACY_DOWNLINK_MIXER,
                               &state->legacy_downlink_disabled);
    if (should_stop()) {
        goto failed;
    }
    disable_legacy_voice_mixer(api, VOICE_LEGACY_UPLINK_MIXER,
                               &state->legacy_uplink_disabled);
    if (should_stop()) {
        goto failed;
    }
    if (set_voice_mixer(api, VOICE_DOWNLINK_MIXER, "1") != 0) {
        goto failed;
    }
    state->downlink_enabled = 1;
    if (should_stop()) {
        goto failed;
    }
    if (set_voice_mixer(api, VOICE_UPLINK_MIXER, "1") != 0) {
        goto failed;
    }
    state->uplink_enabled = 1;
    if (should_stop()) {
        goto failed;
    }
    if (enable_usb_audio != 0) {
        if (set_voice_audio_enabled(1) != 0) {
            goto failed;
        }
        state->usb_audio_enabled = 1;
        if (should_stop()) {
            goto failed;
        }
    }

    state->capture = api->pcm_open(
        VOICE_PCM_DEVICE, VOICE_CAPTURE_FLAGS, PCM_RATE, PCM_CHANNELS,
        PCM_FORMAT_S16_LE, VOICE_HOSTLESS);
    if (state->capture == NULL) {
        log_message("error", "could not open VoLTE capture PCM %s",
                    VOICE_PCM_DEVICE);
        goto failed;
    }
    if (should_stop()) {
        goto failed;
    }
    state->playback = api->pcm_open(
        VOICE_PCM_DEVICE, VOICE_PLAYBACK_FLAGS, PCM_RATE, PCM_CHANNELS,
        PCM_FORMAT_S16_LE, VOICE_HOSTLESS);
    if (state->playback == NULL) {
        log_message("error", "could not open VoLTE playback PCM %s",
                    VOICE_PCM_DEVICE);
        goto failed;
    }

    return EXIT_SUCCESS;

failed:
    (void)voice_route_stop(api, state);
    return EXIT_FAILURE;
}

static int voice_route_stop(struct vendor_audio *api,
                            struct voice_route_state *state)
{
    int result = EXIT_SUCCESS;

    if (state->playback != NULL) {
        if (api->pcm_close(state->playback) != 0) {
            log_message("warn", "could not close VoLTE playback PCM cleanly");
            result = EXIT_FAILURE;
        }
        state->playback = NULL;
    }
    if (state->capture != NULL) {
        if (api->pcm_close(state->capture) != 0) {
            log_message("warn", "could not close VoLTE capture PCM cleanly");
            result = EXIT_FAILURE;
        }
        state->capture = NULL;
    }
    if (state->usb_audio_enabled) {
        if (set_voice_audio_enabled(0) != 0) {
            result = EXIT_FAILURE;
        }
        state->usb_audio_enabled = 0;
    }
    if (state->uplink_enabled) {
        if (set_voice_mixer(api, VOICE_UPLINK_MIXER, "0") != 0) {
            result = EXIT_FAILURE;
        }
        state->uplink_enabled = 0;
    }
    if (state->downlink_enabled) {
        if (set_voice_mixer(api, VOICE_DOWNLINK_MIXER, "0") != 0) {
            result = EXIT_FAILURE;
        }
        state->downlink_enabled = 0;
    }
    if (state->legacy_uplink_disabled) {
        if (set_voice_mixer(api, VOICE_LEGACY_UPLINK_MIXER, "1") != 0) {
            result = EXIT_FAILURE;
        }
        state->legacy_uplink_disabled = 0;
    }
    if (state->legacy_downlink_disabled) {
        if (set_voice_mixer(api, VOICE_LEGACY_DOWNLINK_MIXER, "1") != 0) {
            result = EXIT_FAILURE;
        }
        state->legacy_downlink_disabled = 0;
    }
    return result;
}

static int run_voice_route_session(struct vendor_audio *api, int verbose)
{
    struct voice_route_state state;
    int result;

    if (install_signal_handlers() != 0) {
        return EXIT_FAILURE;
    }
    result = voice_route_start(api, 1, &state);
    if (result != EXIT_SUCCESS) {
        if (verbose) {
            log_message("info", "VoLTE route session cleanup complete");
        }
        return result;
    }

    log_message("info", "VoLTE route session active on %s; send SIGTERM to stop",
                VOICE_PCM_DEVICE);
    while (!should_stop()) {
        usleep(100000U);
    }
    result = voice_route_stop(api, &state);
    if (verbose) {
        log_message("info", "VoLTE route session cleanup complete");
    }
    return result;
}

static int run_network_pcm_probe(struct vendor_audio *api, int verbose)
{
    struct timespec started;
    struct timespec now;
    void *uplink_pcm = NULL;
    void *downlink_pcm = NULL;
    unsigned char buffer[NETWORK_PCM_FRAME_BYTES];
    unsigned long frames = 0UL;
    unsigned long nonzero_samples = 0UL;
    unsigned int uplink_buffer_length;
    unsigned int downlink_buffer_length;
    unsigned int peak = 0U;
    int result = EXIT_FAILURE;

    if (install_signal_handlers() != 0) {
        return EXIT_FAILURE;
    }
    uplink_pcm = api->pcm_open(NETWORK_UPLINK_PCM_DEVICE, PCM_PLAYBACK_FLAGS, PCM_RATE,
                               PCM_CHANNELS, PCM_FORMAT_S16_LE, PCM_HOSTLESS);
    if (uplink_pcm == NULL) {
        log_message("error", "could not open network uplink PCM %s",
                    NETWORK_UPLINK_PCM_DEVICE);
        goto cleanup;
    }
    downlink_pcm = api->pcm_open(NETWORK_DOWNLINK_PCM_DEVICE,
                                 PCM_CAPTURE_FLAGS, PCM_RATE, PCM_CHANNELS,
                                 PCM_FORMAT_S16_LE, PCM_HOSTLESS);
    if (downlink_pcm == NULL) {
        log_message("error", "could not open network downlink PCM %s",
                    NETWORK_DOWNLINK_PCM_DEVICE);
        goto cleanup;
    }
    uplink_buffer_length = api->pcm_buffer_len(uplink_pcm);
    downlink_buffer_length = api->pcm_buffer_len(downlink_pcm);
    log_message("info", "network PCM buffers: uplink=%u downlink=%u bytes",
                uplink_buffer_length, downlink_buffer_length);
    if (uplink_buffer_length != NETWORK_PCM_FRAME_BYTES ||
        downlink_buffer_length != NETWORK_PCM_FRAME_BYTES) {
        log_message("error", "network PCM devices must expose %u-byte buffers",
                    NETWORK_PCM_FRAME_BYTES);
        goto cleanup;
    }
    if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) {
        log_message("error", "clock_gettime failed: %s", strerror(errno));
        goto cleanup;
    }

    while (!should_stop()) {
        int64_t elapsed_usec;
        unsigned int index;

        if (api->pcm_read(downlink_pcm, buffer, NETWORK_PCM_FRAME_BYTES) != 0) {
            log_message("error", "network downlink PCM read failed");
            goto cleanup;
        }
        ++frames;
        for (index = 0U; index < NETWORK_PCM_FRAME_BYTES; index += 2U) {
            int16_t sample;
            unsigned int magnitude;

            memcpy(&sample, buffer + index, sizeof(sample));
            magnitude = sample < 0 ? (unsigned int)(-(int32_t)sample)
                                   : (unsigned int)sample;
            if (magnitude != 0U) {
                ++nonzero_samples;
            }
            if (magnitude > peak) {
                peak = magnitude;
            }
        }
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
            log_message("error", "clock_gettime failed: %s", strerror(errno));
            goto cleanup;
        }
        if (now.tv_sec < started.tv_sec ||
            (now.tv_sec == started.tv_sec && now.tv_nsec < started.tv_nsec)) {
            log_message("error", "monotonic clock moved backwards");
            goto cleanup;
        }
        elapsed_usec = ((int64_t)now.tv_sec - (int64_t)started.tv_sec) *
                       1000000LL;
        elapsed_usec += ((int64_t)now.tv_nsec - (int64_t)started.tv_nsec) /
                        1000LL;
        if (elapsed_usec >= NETWORK_PROBE_DURATION_USEC) {
            result = EXIT_SUCCESS;
            break;
        }
    }

    if (should_stop() && result == EXIT_FAILURE) {
        log_message("info", "network PCM probe interrupted");
    }
    if (result == EXIT_SUCCESS || verbose) {
        log_message("info", "network PCM probe: frames=%lu peak=%u "
                    "nonzero_samples=%lu", frames, peak,
                    nonzero_samples);
    }

cleanup:
    if (downlink_pcm != NULL && api->pcm_close(downlink_pcm) != 0) {
        log_message("warn", "could not close network downlink PCM cleanly");
        result = EXIT_FAILURE;
    }
    if (uplink_pcm != NULL && api->pcm_close(uplink_pcm) != 0) {
        log_message("warn", "could not close network uplink PCM cleanly");
        result = EXIT_FAILURE;
    }
    return result;
}

static int run_direct_pcm_probe(struct vendor_audio *api, int verbose)
{
    static const int16_t tone_cycle[8] = {
        0, 14142, 20000, 14142, 0, -14142, -20000, -14142
    };
    struct voice_route_state route;
    struct timespec started;
    struct timespec now;
    void *uplink_pcm = NULL;
    void *downlink_pcm = NULL;
    unsigned char buffer[NETWORK_PCM_FRAME_BYTES];
    uint64_t sum_magnitude = 0U;
    uint32_t tone_sample = 0U;
    unsigned long frames = 0UL;
    unsigned long nonzero_samples = 0UL;
    unsigned int uplink_buffer_length;
    unsigned int downlink_buffer_length;
    unsigned int peak = 0U;
    int original_usb_audio = 0;
    int observed_usb_audio = 0;
    int usb_audio_changed = 0;
    int route_started = 0;
    int result = EXIT_FAILURE;

    memset(&route, 0, sizeof(route));
    if (install_signal_handlers() != 0) {
        return EXIT_FAILURE;
    }
    if (get_voice_audio_enabled(&original_usb_audio) != 0) {
        goto cleanup;
    }
    if (original_usb_audio != 0) {
        if (set_voice_audio_enabled(0) != 0) {
            goto cleanup;
        }
        usb_audio_changed = 1;
    }
    if (get_voice_audio_enabled(&observed_usb_audio) != 0 ||
        observed_usb_audio != 0) {
        log_message("error", "USB UAC bypass verification failed");
        goto cleanup;
    }
    log_message("info", "USB UAC disabled; starting direct D5/D6 PCM probe");

    if (voice_route_start(api, 0, &route) != EXIT_SUCCESS) {
        goto cleanup;
    }
    route_started = 1;
    uplink_pcm = api->pcm_open(NETWORK_UPLINK_PCM_DEVICE, PCM_PLAYBACK_FLAGS,
                               PCM_RATE, PCM_CHANNELS, PCM_FORMAT_S16_LE,
                               PCM_HOSTLESS);
    if (uplink_pcm == NULL) {
        log_message("error", "could not open direct uplink PCM %s",
                    NETWORK_UPLINK_PCM_DEVICE);
        goto cleanup;
    }
    downlink_pcm = api->pcm_open(NETWORK_DOWNLINK_PCM_DEVICE,
                                 PCM_CAPTURE_FLAGS, PCM_RATE, PCM_CHANNELS,
                                 PCM_FORMAT_S16_LE, PCM_HOSTLESS);
    if (downlink_pcm == NULL) {
        log_message("error", "could not open direct downlink PCM %s",
                    NETWORK_DOWNLINK_PCM_DEVICE);
        goto cleanup;
    }
    uplink_buffer_length = api->pcm_buffer_len(uplink_pcm);
    downlink_buffer_length = api->pcm_buffer_len(downlink_pcm);
    log_message("info", "direct PCM format: 8000 Hz, mono, signed S16_LE; "
                "uplink=%s/%u bytes downlink=%s/%u bytes",
                NETWORK_UPLINK_PCM_DEVICE, uplink_buffer_length,
                NETWORK_DOWNLINK_PCM_DEVICE, downlink_buffer_length);
    if (uplink_buffer_length != NETWORK_PCM_FRAME_BYTES ||
        downlink_buffer_length != NETWORK_PCM_FRAME_BYTES) {
        log_message("error", "direct PCM devices must expose %u-byte buffers",
                    NETWORK_PCM_FRAME_BYTES);
        goto cleanup;
    }
    if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) {
        log_message("error", "clock_gettime failed: %s", strerror(errno));
        goto cleanup;
    }

    while (!should_stop()) {
        int64_t elapsed_usec;
        unsigned int index;

        if (api->pcm_read(downlink_pcm, buffer, NETWORK_PCM_FRAME_BYTES) != 0) {
            log_message("error", "direct downlink PCM read failed");
            goto cleanup;
        }
        ++frames;
        for (index = 0U; index < NETWORK_PCM_FRAME_BYTES; index += 2U) {
            int16_t sample;
            unsigned int magnitude;

            memcpy(&sample, buffer + index, sizeof(sample));
            magnitude = sample < 0 ? (unsigned int)(-(int32_t)sample)
                                   : (unsigned int)sample;
            sum_magnitude += (uint64_t)magnitude;
            if (magnitude != 0U) {
                ++nonzero_samples;
            }
            if (magnitude > peak) {
                peak = magnitude;
            }
        }
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
            log_message("error", "clock_gettime failed: %s", strerror(errno));
            goto cleanup;
        }
        if (now.tv_sec < started.tv_sec ||
            (now.tv_sec == started.tv_sec && now.tv_nsec < started.tv_nsec)) {
            log_message("error", "monotonic clock moved backwards");
            goto cleanup;
        }
        elapsed_usec = ((int64_t)now.tv_sec - (int64_t)started.tv_sec) *
                       1000000LL;
        elapsed_usec += ((int64_t)now.tv_nsec - (int64_t)started.tv_nsec) /
                        1000LL;
        if (elapsed_usec >= NETWORK_PROBE_DURATION_USEC) {
            break;
        }
        usleep(NETWORK_PCM_FRAME_USEC);
    }
    if (should_stop()) {
        log_message("info", "direct PCM probe interrupted during capture");
        goto cleanup;
    }
    log_message("info", "direct downlink capture: frames=%lu peak=%u "
                "nonzero_samples=%lu mean_abs=%llu",
                frames, peak, nonzero_samples,
                frames == 0UL ? 0ULL :
                (unsigned long long)(sum_magnitude /
                    ((uint64_t)frames * (uint64_t)NETWORK_PCM_FRAME_SAMPLES)));

    log_message("info", "writing three 1 kHz uplink beeps: 500 ms on, "
                "500 ms off, peak=20000");
    while (tone_sample < PCM_RATE * 3U && !should_stop()) {
        unsigned int index;

        for (index = 0U; index < NETWORK_PCM_FRAME_SAMPLES; ++index) {
            int16_t sample = 0;

            if (tone_sample < PCM_RATE * 3U &&
                tone_sample % PCM_RATE < PCM_RATE / 2U) {
                sample = tone_cycle[tone_sample % 8U];
            }
            memcpy(buffer + index * 2U, &sample, sizeof(sample));
            ++tone_sample;
        }
        if (api->pcm_write(uplink_pcm, buffer, NETWORK_PCM_FRAME_BYTES) != 0) {
            log_message("error", "direct uplink PCM write failed");
            goto cleanup;
        }
        usleep(NETWORK_PCM_FRAME_USEC);
    }
    if (should_stop()) {
        log_message("info", "direct PCM probe interrupted during tone");
        goto cleanup;
    }
    log_message("info", "direct uplink tone complete: samples=%u frames=%u",
                tone_sample,
                (tone_sample + NETWORK_PCM_FRAME_SAMPLES - 1U) /
                    NETWORK_PCM_FRAME_SAMPLES);
    result = EXIT_SUCCESS;

cleanup:
    if (downlink_pcm != NULL && api->pcm_close(downlink_pcm) != 0) {
        log_message("warn", "could not close direct downlink PCM cleanly");
        result = EXIT_FAILURE;
    }
    if (uplink_pcm != NULL && api->pcm_close(uplink_pcm) != 0) {
        log_message("warn", "could not close direct uplink PCM cleanly");
        result = EXIT_FAILURE;
    }
    if (route_started && voice_route_stop(api, &route) != EXIT_SUCCESS) {
        log_message("warn", "could not stop direct voice route cleanly");
        result = EXIT_FAILURE;
    }
    if (usb_audio_changed) {
        if (set_voice_audio_enabled(original_usb_audio) != 0) {
            log_message("warn", "could not restore USB UAC state");
            result = EXIT_FAILURE;
        } else if (verbose) {
            log_message("info", "restored USB UAC state to %d",
                        original_usb_audio);
        }
    }
    return result;
}

struct network_options {
    int enabled;
    int uplink_listener;
    const char *listen_address;
    const char *peer_address;
    const char *token_file;
    const char *interface_name;
    unsigned int port;
    unsigned int peer_port;
    uint32_t session_id;
};

struct network_session {
    struct vendor_audio *api;
    int socket_fd;
    struct sockaddr_in peer;
    unsigned char key[32];
    uint32_t session_id;
    void *uplink_pcm;
    void *downlink_pcm;
    uint32_t tx_sequence;
    uint32_t rx_sequence;
    int64_t last_rx_usec;
    unsigned int downlink_pcm_buffer_length;
    unsigned char *downlink_resample_buffer;
    size_t downlink_resample_capacity;
    size_t downlink_resample_available;
    volatile int media_stop;
    volatile int downlink_failed;
    volatile int failed;
    int verbose;
};

struct uplink_jitter_buffer {
    unsigned char frames[UPLINK_JITTER_CAPACITY][NETWORK_PCM_FRAME_BYTES];
    uint32_t sequences[UPLINK_JITTER_CAPACITY];
    unsigned int head;
    unsigned int count;
    uint64_t dropped;
};

static void store_u16_be(unsigned char *data, uint16_t value)
{
    uint16_t encoded = htons(value);

    memcpy(data, &encoded, sizeof(encoded));
}

static void store_u32_be(unsigned char *data, uint32_t value)
{
    uint32_t encoded = htonl(value);

    memcpy(data, &encoded, sizeof(encoded));
}

static uint16_t load_u16_be(const unsigned char *data)
{
    uint16_t encoded;

    memcpy(&encoded, data, sizeof(encoded));
    return ntohs(encoded);
}

static uint32_t load_u32_be(const unsigned char *data)
{
    uint32_t encoded;

    memcpy(&encoded, data, sizeof(encoded));
    return ntohl(encoded);
}

static int64_t monotonic_usec(void)
{
    struct timespec current;

    if (clock_gettime(CLOCK_MONOTONIC, &current) != 0) {
        return -1LL;
    }
    return (int64_t)current.tv_sec * 1000000LL +
           (int64_t)current.tv_nsec / 1000LL;
}

static int load_pairing_key(const char *path, unsigned char key[32])
{
    struct stat attributes;
    unsigned char extra;
    size_t offset = 0U;
    ssize_t received;
    int fd;

    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        log_message("error", "open(%s) failed: %s", path, strerror(errno));
        return -1;
    }
    if (fstat(fd, &attributes) != 0 || !S_ISREG(attributes.st_mode) ||
        (attributes.st_mode & 0077) != 0) {
        log_message("error", "pairing key must be a mode-0600 regular file");
        (void)close(fd);
        return -1;
    }
    while (offset < 32U) {
        received = read(fd, key + offset, 32U - offset);
        if (received > 0) {
            offset += (size_t)received;
        } else if (received < 0 && errno == EINTR) {
            continue;
        } else {
            log_message("error", "pairing key must contain exactly 32 bytes");
            (void)close(fd);
            return -1;
        }
    }
    do {
        received = read(fd, &extra, sizeof(extra));
    } while (received < 0 && errno == EINTR);
    if (received != 0) {
        log_message("error", "pairing key must contain exactly 32 bytes");
        (void)close(fd);
        return -1;
    }
    if (close(fd) != 0) {
        log_message("error", "close(%s) failed: %s", path, strerror(errno));
        return -1;
    }
    return 0;
}

static void make_audio_packet(const struct network_session *session,
                              unsigned char direction, uint32_t sequence,
                              const unsigned char *payload,
                              unsigned char packet[NETWORK_PACKET_BYTES])
{
    unsigned char digest[32];

    memset(packet, 0, NETWORK_PACKET_BYTES);
    store_u32_be(packet, NETWORK_PACKET_MAGIC);
    packet[4] = NETWORK_PACKET_VERSION;
    packet[5] = direction;
    store_u16_be(packet + 6U, NETWORK_PCM_FRAME_BYTES);
    store_u32_be(packet + 8U, session->session_id);
    store_u32_be(packet + 12U, sequence);
    store_u32_be(packet + 16U, sequence * NETWORK_PCM_FRAME_SAMPLES);
    memcpy(packet + NETWORK_PACKET_HEADER_BYTES, payload,
           NETWORK_PCM_FRAME_BYTES);
    hmac_sha256(session->key, sizeof(session->key), packet,
                NETWORK_PACKET_HEADER_BYTES + NETWORK_PCM_FRAME_BYTES, digest);
    memcpy(packet + NETWORK_PACKET_HEADER_BYTES + NETWORK_PCM_FRAME_BYTES,
           digest, NETWORK_PACKET_TAG_BYTES);
}

static int valid_audio_packet(const struct network_session *session,
                              const unsigned char *packet, size_t length,
                              const struct sockaddr_in *source,
                              uint32_t *sequence,
                              unsigned char payload[NETWORK_PCM_FRAME_BYTES])
{
    unsigned char digest[32];
    uint32_t packet_sequence;

    if (length != NETWORK_PACKET_BYTES ||
        source->sin_family != AF_INET ||
        source->sin_addr.s_addr != session->peer.sin_addr.s_addr ||
        source->sin_port != session->peer.sin_port ||
        load_u32_be(packet) != NETWORK_PACKET_MAGIC ||
        packet[4] != NETWORK_PACKET_VERSION ||
        packet[5] != NETWORK_DIRECTION_UPLINK ||
        load_u16_be(packet + 6U) != NETWORK_PCM_FRAME_BYTES ||
        load_u32_be(packet + 8U) != session->session_id) {
        return 0;
    }
    packet_sequence = load_u32_be(packet + 12U);
    if (packet_sequence == 0U ||
        load_u32_be(packet + 16U) !=
            packet_sequence * NETWORK_PCM_FRAME_SAMPLES) {
        return 0;
    }
    hmac_sha256(session->key, sizeof(session->key), packet,
                NETWORK_PACKET_HEADER_BYTES + NETWORK_PCM_FRAME_BYTES, digest);
    if (!secure_equal(packet + NETWORK_PACKET_HEADER_BYTES +
                          NETWORK_PCM_FRAME_BYTES,
                      digest, NETWORK_PACKET_TAG_BYTES)) {
        return 0;
    }
    *sequence = packet_sequence;
    memcpy(payload, packet + NETWORK_PACKET_HEADER_BYTES,
           NETWORK_PCM_FRAME_BYTES);
    return 1;
}

static int valid_initial_uplink_packet(
    const unsigned char key[32], const unsigned char *packet, size_t length,
    const struct sockaddr_in *source, const struct in_addr *local_address,
    uint32_t *session_id, uint32_t *sequence,
    unsigned char payload[NETWORK_PCM_FRAME_BYTES])
{
    unsigned char digest[32];
    uint32_t packet_sequence;
    uint32_t packet_session;
    uint32_t source_host;
    uint32_t local_host;

    if (length != NETWORK_PACKET_BYTES || source->sin_family != AF_INET ||
        source->sin_port == 0U || load_u32_be(packet) != NETWORK_PACKET_MAGIC ||
        packet[4] != NETWORK_PACKET_VERSION ||
        packet[5] != NETWORK_DIRECTION_UPLINK ||
        load_u16_be(packet + 6U) != NETWORK_PCM_FRAME_BYTES) {
        return 0;
    }
    source_host = ntohl(source->sin_addr.s_addr);
    local_host = ntohl(local_address->s_addr);
    if ((source_host & 0xffffff00U) != (local_host & 0xffffff00U) ||
        source_host == local_host) {
        return 0;
    }
    packet_session = load_u32_be(packet + 8U);
    packet_sequence = load_u32_be(packet + 12U);
    if (packet_session == 0U || packet_sequence == 0U ||
        load_u32_be(packet + 16U) !=
            packet_sequence * NETWORK_PCM_FRAME_SAMPLES) {
        return 0;
    }
    hmac_sha256(key, 32U, packet,
                NETWORK_PACKET_HEADER_BYTES + NETWORK_PCM_FRAME_BYTES, digest);
    if (!secure_equal(packet + NETWORK_PACKET_HEADER_BYTES +
                          NETWORK_PCM_FRAME_BYTES,
                      digest, NETWORK_PACKET_TAG_BYTES)) {
        return 0;
    }
    *session_id = packet_session;
    *sequence = packet_sequence;
    memcpy(payload, packet + NETWORK_PACKET_HEADER_BYTES,
           NETWORK_PCM_FRAME_BYTES);
    return 1;
}

static void mark_network_failed(struct network_session *session,
                                const char *message)
{
    if (message != NULL) {
        log_message("error", "%s", message);
    }
    __atomic_store_n(&session->failed, 1, __ATOMIC_RELAXED);
    request_worker_stop();
}

static void *network_uplink_thread(void *opaque)
{
    struct network_session *session = opaque;
    unsigned char packet[NETWORK_PACKET_BYTES];
    unsigned char payload[NETWORK_PCM_FRAME_BYTES];
    unsigned char silence[NETWORK_PCM_FRAME_BYTES];
    struct pollfd descriptor;
    struct sockaddr_in source;
    socklen_t source_length;
    uint32_t sequence;
    int64_t current_usec;
    ssize_t received;

    memset(silence, 0, sizeof(silence));
    descriptor.fd = session->socket_fd;
    descriptor.events = POLLIN;
    while (!should_stop()) {
        int poll_result = poll(&descriptor, 1U, (int)(NETWORK_POLL_USEC / 1000U));

        if (poll_result < 0 && errno == EINTR) {
            continue;
        }
        if (poll_result < 0) {
            mark_network_failed(session, "network uplink poll failed");
            break;
        }
        if (poll_result > 0 &&
            (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
            mark_network_failed(session, "network uplink socket closed");
            break;
        }
        if (poll_result > 0 && (descriptor.revents & POLLIN) != 0) {
            source_length = sizeof(source);
            received = recvfrom(session->socket_fd, packet, sizeof(packet), 0,
                                (struct sockaddr *)&source, &source_length);
            if (received < 0) {
                if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                    mark_network_failed(session, "network uplink receive failed");
                    break;
                }
            } else if (valid_audio_packet(session, packet, (size_t)received,
                                          &source, &sequence, payload) &&
                       sequence != 0U &&
                       (session->rx_sequence == 0U ||
                        (int32_t)(sequence - session->rx_sequence) > 0)) {
                if (session->api->pcm_write(session->uplink_pcm, payload,
                                            NETWORK_PCM_FRAME_BYTES) != 0) {
                    mark_network_failed(session, "network uplink PCM write failed");
                    break;
                }
                session->rx_sequence = sequence;
                current_usec = monotonic_usec();
                if (current_usec < 0LL) {
                    mark_network_failed(session, "monotonic clock failed");
                    break;
                }
                session->last_rx_usec = current_usec;
            }
        } else if (session->api->pcm_write(session->uplink_pcm, silence,
                                           NETWORK_PCM_FRAME_BYTES) != 0) {
            mark_network_failed(session, "network uplink silence write failed");
            break;
        }
        current_usec = monotonic_usec();
        if (current_usec < 0LL ||
            current_usec - session->last_rx_usec > NETWORK_SESSION_TIMEOUT_USEC) {
            mark_network_failed(session, "network media heartbeat timed out");
            break;
        }
        (void)pthread_testcancel();
    }
    return NULL;
}

static void *network_downlink_thread(void *opaque)
{
    struct network_session *session = opaque;
    unsigned char payload[NETWORK_PCM_FRAME_BYTES];
    unsigned char packet[NETWORK_PACKET_BYTES];
    int64_t next_send_usec;
    ssize_t sent;

    next_send_usec = monotonic_usec();
    if (next_send_usec < 0LL) {
        mark_network_failed(session, "network downlink clock failed");
        return NULL;
    }
    while (!should_stop()) {
        int64_t current_usec;

        if (session->api->pcm_read(session->downlink_pcm, payload,
                                   NETWORK_PCM_FRAME_BYTES) != 0) {
            mark_network_failed(session, "network downlink PCM read failed");
            break;
        }
        current_usec = monotonic_usec();
        if (current_usec < 0LL) {
            mark_network_failed(session, "network downlink clock failed");
            break;
        }
        if (current_usec < next_send_usec) {
            int64_t delay_usec = next_send_usec - current_usec;

            usleep((unsigned int)delay_usec);
            if (should_stop()) {
                break;
            }
        } else if (current_usec - next_send_usec >
                   (int64_t)NETWORK_PCM_FRAME_USEC) {
            /* Do not emit a catch-up burst if the PCM source stalls. */
            next_send_usec = current_usec;
        }
        ++session->tx_sequence;
        make_audio_packet(session, NETWORK_DIRECTION_DOWNLINK,
                          session->tx_sequence, payload, packet);
        do {
            sent = sendto(session->socket_fd, packet, sizeof(packet), 0,
                          (const struct sockaddr *)&session->peer,
                          sizeof(session->peer));
        } while (sent < 0 && errno == EINTR && !should_stop());
        if (sent < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            mark_network_failed(session, "network downlink send failed");
            break;
        }
        if (sent >= 0 && (size_t)sent != sizeof(packet)) {
            mark_network_failed(session, "short network downlink packet");
            break;
        }
        next_send_usec += (int64_t)NETWORK_PCM_FRAME_USEC;
        (void)pthread_testcancel();
    }
    return NULL;
}

static int parse_ipv4(const char *text, struct in_addr *address)
{
    if (inet_pton(AF_INET, text, address) != 1) {
        log_message("error", "invalid IPv4 address: %s", text);
        return -1;
    }
    return 0;
}

static int setup_bound_network_socket(struct network_session *session,
                                      const struct network_options *options,
                                      struct in_addr *local_address)
{
    struct sockaddr_in local;
    int enabled = 1;

    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = htons((uint16_t)options->port);
    if (parse_ipv4(options->listen_address, &local.sin_addr) != 0) {
        return -1;
    }
    session->socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (session->socket_fd < 0) {
        log_message("error", "UDP socket failed: %s", strerror(errno));
        return -1;
    }
    if (setsockopt(session->socket_fd, SOL_SOCKET, SO_REUSEADDR, &enabled,
                   sizeof(enabled)) != 0 ||
        bind(session->socket_fd, (const struct sockaddr *)&local,
             sizeof(local)) != 0) {
        log_message("error", "UDP bind failed: %s", strerror(errno));
        return -1;
    }
#if defined(SO_BINDTODEVICE) && defined(IFNAMSIZ)
    if (options->interface_name == NULL || options->interface_name[0] == '\0' ||
        strlen(options->interface_name) >= IFNAMSIZ ||
        setsockopt(session->socket_fd, SOL_SOCKET, SO_BINDTODEVICE,
                   options->interface_name,
                   (socklen_t)(strlen(options->interface_name) + 1U)) != 0) {
        log_message("error", "UDP socket interface binding failed: %s",
                    strerror(errno));
        return -1;
    }
#else
    if (options->interface_name != NULL && options->interface_name[0] != '\0') {
        log_message("error", "interface binding is unsupported on this build");
        return -1;
    }
#endif
    if (ioctl(session->socket_fd, FIONBIO, &enabled) != 0) {
        log_message("error", "could not make UDP socket nonblocking: %s",
                    strerror(errno));
        return -1;
    }
    *local_address = local.sin_addr;
    return 0;
}

static int setup_network_session(struct network_session *session,
                                 const struct network_options *options)
{
    struct in_addr local_address;

    if (setup_bound_network_socket(session, options, &local_address) != 0 ||
        parse_ipv4(options->peer_address, &session->peer.sin_addr) != 0) {
        return -1;
    }
    (void)local_address;
    session->peer.sin_family = AF_INET;
    session->peer.sin_port = htons((uint16_t)options->peer_port);
    session->uplink_pcm = session->api->pcm_open("hw:0,5", PCM_PLAYBACK_FLAGS,
                                                 PCM_RATE, PCM_CHANNELS,
                                                 PCM_FORMAT_S16_LE, PCM_HOSTLESS);
    session->downlink_pcm = session->api->pcm_open("hw:0,6", PCM_CAPTURE_FLAGS,
                                                   PCM_RATE, PCM_CHANNELS,
                                                   PCM_FORMAT_S16_LE, PCM_HOSTLESS);
    if (session->uplink_pcm == NULL || session->downlink_pcm == NULL ||
        session->api->pcm_buffer_len(session->uplink_pcm) !=
            NETWORK_PCM_FRAME_BYTES ||
        session->api->pcm_buffer_len(session->downlink_pcm) !=
            NETWORK_PCM_FRAME_BYTES) {
        log_message("error", "network PCM devices must expose %u-byte buffers",
                    NETWORK_PCM_FRAME_BYTES);
        return -1;
    }
    return 0;
}

static int run_network_session(struct vendor_audio *api,
                               const struct network_options *options,
                               int verbose)
{
    struct voice_route_state route;
    struct network_session session;
    int64_t current_usec;
    pthread_t uplink_thread_id;
    pthread_t downlink_thread_id;
    int uplink_started = 0;
    int downlink_started = 0;
    int result = EXIT_FAILURE;
    int thread_error;

    memset(&session, 0, sizeof(session));
    session.api = api;
    session.socket_fd = -1;
    session.session_id = options->session_id;
    session.verbose = verbose;
    if (load_pairing_key(options->token_file, session.key) != 0 ||
        install_signal_handlers() != 0) {
        return EXIT_FAILURE;
    }
    if (voice_route_start(api, 0, &route) != EXIT_SUCCESS) {
        return EXIT_FAILURE;
    }
    if (setup_network_session(&session, options) != 0) {
        goto cleanup;
    }
    current_usec = monotonic_usec();
    if (current_usec < 0LL) {
        log_message("error", "monotonic clock failed");
        goto cleanup;
    }
    session.last_rx_usec = current_usec;
    thread_error = pthread_create(&uplink_thread_id, NULL, network_uplink_thread,
                                  &session);
    if (thread_error != 0) {
        log_message("error", "could not start network uplink: %s",
                    strerror(thread_error));
        goto cleanup;
    }
    uplink_started = 1;
    thread_error = pthread_create(&downlink_thread_id, NULL, network_downlink_thread,
                                  &session);
    if (thread_error != 0) {
        log_message("error", "could not start network downlink: %s",
                    strerror(thread_error));
        request_worker_stop();
        (void)pthread_cancel(uplink_thread_id);
        (void)pthread_join(uplink_thread_id, NULL);
        uplink_started = 0;
        goto cleanup;
    }
    downlink_started = 1;
    log_message("info", "authenticated UDP media active on port %u; send SIGTERM to stop",
                options->port);
    while (!should_stop()) {
        usleep(100000U);
    }
    result = __atomic_load_n(&session.failed, __ATOMIC_RELAXED) != 0 ?
             EXIT_FAILURE : EXIT_SUCCESS;

cleanup:
    request_worker_stop();
    if (downlink_started) {
        (void)pthread_cancel(downlink_thread_id);
        (void)pthread_join(downlink_thread_id, NULL);
    }
    if (uplink_started) {
        (void)pthread_cancel(uplink_thread_id);
        (void)pthread_join(uplink_thread_id, NULL);
    }
    if (session.downlink_pcm != NULL) {
        (void)api->pcm_close(session.downlink_pcm);
    }
    if (session.uplink_pcm != NULL) {
        (void)api->pcm_close(session.uplink_pcm);
    }
    if (session.socket_fd >= 0) {
        (void)close(session.socket_fd);
    }
    if (voice_route_stop(api, &route) != EXIT_SUCCESS) {
        result = EXIT_FAILURE;
    }
    return result;
}

static int wait_for_initial_uplink_packet(
    struct network_session *session, const struct in_addr *local_address,
    uint32_t rejected_session_id, struct sockaddr_in *source,
    uint32_t *session_id, uint32_t *sequence,
    unsigned char payload[NETWORK_PCM_FRAME_BYTES])
{
    unsigned char packet[NETWORK_PACKET_BYTES];
    struct pollfd descriptor;

    descriptor.fd = session->socket_fd;
    descriptor.events = POLLIN;
    while (!should_stop()) {
        socklen_t source_length = sizeof(*source);
        ssize_t received;
        int poll_result;

        descriptor.revents = 0;
        poll_result = poll(&descriptor, 1U, 500);
        if (poll_result < 0 && errno == EINTR) {
            continue;
        }
        if (poll_result < 0) {
            log_message("error", "uplink listener poll failed: %s",
                        strerror(errno));
            return -1;
        }
        if (poll_result == 0) {
            continue;
        }
        if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
            log_message("error", "uplink listener socket closed");
            return -1;
        }
        if ((descriptor.revents & POLLIN) == 0) {
            continue;
        }
        memset(source, 0, sizeof(*source));
        received = recvfrom(session->socket_fd, packet, sizeof(packet), 0,
                            (struct sockaddr *)source, &source_length);
        if (received < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            log_message("error", "uplink listener receive failed: %s",
                        strerror(errno));
            return -1;
        }
        if (source_length == sizeof(*source) &&
            valid_initial_uplink_packet(session->key, packet,
                                        (size_t)received, source,
                                        local_address, session_id, sequence,
                                        payload) &&
            *session_id != rejected_session_id) {
            return 1;
        }
    }
    return 0;
}

static void enqueue_uplink_frame(
    struct uplink_jitter_buffer *buffer,
    const unsigned char payload[NETWORK_PCM_FRAME_BYTES], uint32_t sequence)
{
    unsigned int tail;

    if (buffer->count == UPLINK_JITTER_CAPACITY) {
        buffer->head = (buffer->head + 1U) % UPLINK_JITTER_CAPACITY;
        buffer->count -= 1U;
        buffer->dropped += 1U;
    }
    tail = (buffer->head + buffer->count) % UPLINK_JITTER_CAPACITY;
    memcpy(buffer->frames[tail], payload, NETWORK_PCM_FRAME_BYTES);
    buffer->sequences[tail] = sequence;
    buffer->count += 1U;
}

static int dequeue_uplink_frame(
    struct uplink_jitter_buffer *buffer,
    unsigned char payload[NETWORK_PCM_FRAME_BYTES], uint32_t *sequence)
{
    if (buffer->count == 0U) {
        return 0;
    }
    memcpy(payload, buffer->frames[buffer->head], NETWORK_PCM_FRAME_BYTES);
    *sequence = buffer->sequences[buffer->head];
    buffer->head = (buffer->head + 1U) % UPLINK_JITTER_CAPACITY;
    buffer->count -= 1U;
    return 1;
}

static int drain_uplink_packets(
    struct network_session *session, struct uplink_jitter_buffer *buffer)
{
    unsigned char packet[NETWORK_PACKET_BYTES];

    for (;;) {
        unsigned char candidate[NETWORK_PCM_FRAME_BYTES];
        struct sockaddr_in source;
        socklen_t source_length = sizeof(source);
        uint32_t sequence;
        ssize_t received;

        memset(&source, 0, sizeof(source));
        received = recvfrom(session->socket_fd, packet, sizeof(packet), 0,
                            (struct sockaddr *)&source, &source_length);
        if (received < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return 0;
            }
            log_message("error", "uplink media receive failed: %s",
                        strerror(errno));
            return -1;
        }
        if (source_length != sizeof(source) ||
            !valid_audio_packet(session, packet, (size_t)received, &source,
                                &sequence, candidate) ||
            (int32_t)(sequence - session->rx_sequence) <= 0) {
            continue;
        }
        session->rx_sequence = sequence;
        enqueue_uplink_frame(buffer, candidate, sequence);
        session->last_rx_usec = monotonic_usec();
        if (session->last_rx_usec < 0LL) {
            log_message("error", "uplink media clock failed");
            return -1;
        }
    }
}

static unsigned int pcm_s16le_peak(
    const unsigned char payload[NETWORK_PCM_FRAME_BYTES])
{
    unsigned int peak = 0U;
    size_t index;

    for (index = 0U; index < NETWORK_PCM_FRAME_BYTES; index += 2U) {
        int sample = (int)(int16_t)((uint16_t)payload[index] |
                                    ((uint16_t)payload[index + 1U] << 8U));
        unsigned int magnitude =
            (unsigned int)(sample < 0 ? -sample : sample);

        if (magnitude > peak) {
            peak = magnitude;
        }
    }
    return peak;
}

static int valid_uplink_pcm_buffer_length(unsigned int length)
{
    return length >= 2U && length <= NETWORK_UPLINK_DEVICE_FRAME_BYTES &&
           (length & 1U) == 0U &&
           NETWORK_UPLINK_DEVICE_FRAME_BYTES % length == 0U;
}

static int valid_downlink_pcm_buffer_length(unsigned int length)
{
    return length >= 2U && length <= 65536U && (length & 1U) == 0U;
}

static int write_uplink_network_frame(
    struct vendor_audio *api, void *pcm, unsigned int pcm_buffer_length,
    unsigned char payload[NETWORK_PCM_FRAME_BYTES])
{
    unsigned char device_payload[NETWORK_UPLINK_DEVICE_FRAME_BYTES];
    unsigned int input_sample;
    unsigned int offset;

    for (input_sample = 0U; input_sample < NETWORK_PCM_FRAME_SAMPLES;
         ++input_sample) {
        unsigned int copy;

        for (copy = 0U; copy < NETWORK_UPLINK_RATE_MULTIPLIER; ++copy) {
            unsigned int output_sample =
                input_sample * NETWORK_UPLINK_RATE_MULTIPLIER + copy;

            device_payload[output_sample * 2U] = payload[input_sample * 2U];
            device_payload[output_sample * 2U + 1U] =
                payload[input_sample * 2U + 1U];
        }
    }
    for (offset = 0U; offset < NETWORK_UPLINK_DEVICE_FRAME_BYTES;
         offset += pcm_buffer_length) {
        int write_result =
            api->pcm_write(pcm, device_payload + offset, pcm_buffer_length);

        if (write_result != 0) {
            int write_errno = errno;

            log_message("error", "Media1 PCM chunk write failed: "
                        "offset=%u length=%u result=%d errno=%d (%s)",
                        offset, pcm_buffer_length, write_result, write_errno,
                        strerror(write_errno));
            return write_result;
        }
    }
    return 0;
}

static int read_downlink_network_frame(
    struct network_session *session,
    unsigned char payload[NETWORK_PCM_FRAME_BYTES])
{
    unsigned int output_sample;
    size_t remaining;

    while (session->downlink_resample_available <
           NETWORK_UPLINK_DEVICE_FRAME_BYTES) {
        size_t offset = session->downlink_resample_available;
        int read_result;

        if (session->downlink_resample_capacity - offset <
            session->downlink_pcm_buffer_length) {
            log_message("error", "Media1 downlink resample buffer overflow");
            return -1;
        }
        read_result = session->api->pcm_read(
            session->downlink_pcm,
            session->downlink_resample_buffer + offset,
            session->downlink_pcm_buffer_length);

        if (read_result != 0) {
            int read_errno = errno;

            log_message("error", "Media1 downlink PCM chunk read failed: "
                        "offset=%u length=%u result=%d errno=%d (%s)",
                        (unsigned int)offset,
                        session->downlink_pcm_buffer_length,
                        read_result, read_errno,
                        strerror(read_errno));
            return read_result;
        }
        session->downlink_resample_available +=
            session->downlink_pcm_buffer_length;
    }
    for (output_sample = 0U; output_sample < NETWORK_PCM_FRAME_SAMPLES;
         ++output_sample) {
        unsigned int input_sample =
            output_sample * NETWORK_UPLINK_RATE_MULTIPLIER;

        payload[output_sample * 2U] =
            session->downlink_resample_buffer[input_sample * 2U];
        payload[output_sample * 2U + 1U] =
            session->downlink_resample_buffer[input_sample * 2U + 1U];
    }
    remaining = session->downlink_resample_available -
        NETWORK_UPLINK_DEVICE_FRAME_BYTES;
    if (remaining != 0U) {
        memmove(session->downlink_resample_buffer,
                session->downlink_resample_buffer +
                    NETWORK_UPLINK_DEVICE_FRAME_BYTES,
                remaining);
    }
    session->downlink_resample_available = remaining;
    return 0;
}

static void *incall_downlink_thread(void *opaque)
{
    struct network_session *session = opaque;
    unsigned char payload[NETWORK_PCM_FRAME_BYTES];
    unsigned char packet[NETWORK_PACKET_BYTES];
    int64_t next_send_usec = monotonic_usec();
    uint64_t frames = 0U;
    uint64_t network_drops = 0U;
    unsigned int maximum_peak = 0U;

    if (next_send_usec < 0LL) {
        session->downlink_failed = 1;
        return NULL;
    }
    while (!should_stop() && !session->media_stop) {
        int64_t current_usec;
        unsigned int peak;
        ssize_t sent;

        if (read_downlink_network_frame(session, payload) != 0) {
            session->downlink_failed = 1;
            break;
        }
        current_usec = monotonic_usec();
        if (current_usec < 0LL) {
            session->downlink_failed = 1;
            break;
        }
        if (current_usec < next_send_usec) {
            usleep((unsigned int)(next_send_usec - current_usec));
        } else if (current_usec - next_send_usec >
                   (int64_t)NETWORK_PCM_FRAME_USEC) {
            next_send_usec = current_usec;
        }
        session->tx_sequence += 1U;
        if (session->tx_sequence == 0U) {
            session->tx_sequence = 1U;
        }
        make_audio_packet(session, NETWORK_DIRECTION_DOWNLINK,
                          session->tx_sequence, payload, packet);
        do {
            sent = sendto(session->socket_fd, packet, sizeof(packet), 0,
                          (const struct sockaddr *)&session->peer,
                          sizeof(session->peer));
        } while (sent < 0 && errno == EINTR && !should_stop());
        if (sent < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                network_drops += 1U;
            } else {
                log_message("error", "in-call downlink UDP send failed: %s",
                            strerror(errno));
                session->downlink_failed = 1;
                break;
            }
        } else if ((size_t)sent != sizeof(packet)) {
            log_message("error", "short in-call downlink UDP packet");
            session->downlink_failed = 1;
            break;
        }
        frames += 1U;
        peak = pcm_s16le_peak(payload);
        if (peak > maximum_peak) {
            maximum_peak = peak;
        }
        if (frames == 1U || frames % 500U == 0U) {
            log_message("info", "downlink Media1 progress: frames=%llu "
                        "sequence=%u peak=%u/32768 max_peak=%u/32768 "
                        "network_drops=%llu",
                        (unsigned long long)frames, session->tx_sequence,
                        peak, maximum_peak,
                        (unsigned long long)network_drops);
        }
        next_send_usec += (int64_t)NETWORK_PCM_FRAME_USEC;
        (void)pthread_testcancel();
    }
    log_message("info", "downlink Media1 final: frames=%llu max_peak=%u/32768 "
                "network_drops=%llu",
                (unsigned long long)frames, maximum_peak,
                (unsigned long long)network_drops);
    return NULL;
}

static int run_incall_music_tone_probe(struct vendor_audio *api)
{
    static const int16_t tone_cycle[8] = {
        0, 5793, 8192, 5793, 0, -5793, -8192, -5793
    };
    unsigned char payload[NETWORK_PCM_FRAME_BYTES];
    struct voice_session_anchor anchor;
    void *uplink_pcm = NULL;
    unsigned int pcm_buffer_length = 0U;
    unsigned int frame;
    unsigned int sample_index = 0U;
    int original_usb_audio = 0;
    int usb_audio_changed = 0;
    int mixer_enabled = 0;
    int anchor_started = 0;
    int result = EXIT_FAILURE;

    if (install_signal_handlers() != 0 ||
        get_voice_audio_enabled(&original_usb_audio) != 0) {
        goto cleanup;
    }
    if (original_usb_audio != 0) {
        if (set_voice_audio_enabled(0) != 0) {
            goto cleanup;
        }
        usb_audio_changed = 1;
    }
    if (voice_session_anchor_start(api, &anchor) != EXIT_SUCCESS) {
        goto cleanup;
    }
    anchor_started = 1;
    log_message("info", "local in-call tone: preserving active VoLTE "
                "SEC_AUX route; Media1=48000/mono/S16_LE via Incall_Music");
    if (set_voice_mixer(api, MIXER_UPLINK, "1") != 0) {
        goto cleanup;
    }
    mixer_enabled = 1;
    uplink_pcm = api->pcm_open(
        NETWORK_UPLINK_PCM_DEVICE, PCM_PLAYBACK_FLAGS,
        NETWORK_UPLINK_DEVICE_RATE, PCM_CHANNELS, PCM_FORMAT_S16_LE,
        PCM_HOSTLESS);
    if (uplink_pcm == NULL) {
        log_message("error", "local in-call tone could not open %s",
                    NETWORK_UPLINK_PCM_DEVICE);
        goto cleanup;
    }
    pcm_buffer_length = api->pcm_buffer_len(uplink_pcm);
    if (!valid_uplink_pcm_buffer_length(pcm_buffer_length)) {
        log_message("error", "local in-call tone got invalid PCM buffer %u",
                    pcm_buffer_length);
        goto cleanup;
    }
    log_message("info", "local in-call tone started: 1 kHz, peak=8192, "
                "duration=10s, pcm_buffer=%u", pcm_buffer_length);
    for (frame = 0U; frame < 625U && !should_stop(); ++frame) {
        unsigned int sample;

        for (sample = 0U; sample < NETWORK_PCM_FRAME_SAMPLES; ++sample) {
            int16_t value = 0;

            if (sample_index % PCM_RATE < PCM_RATE / 2U) {
                value = tone_cycle[sample_index % 8U];
            }
            memcpy(payload + sample * 2U, &value, sizeof(value));
            ++sample_index;
        }
        if (write_uplink_network_frame(api, uplink_pcm, pcm_buffer_length,
                                       payload) != 0) {
            goto cleanup;
        }
        if ((frame + 1U) % 125U == 0U) {
            log_message("info", "local in-call tone progress: frames=%u/625",
                        frame + 1U);
        }
        usleep(NETWORK_PCM_FRAME_USEC);
    }
    if (should_stop()) {
        log_message("warn", "local in-call tone interrupted at frame %u",
                    frame);
        goto cleanup;
    }
    log_message("info", "local in-call tone complete: frames=625");
    result = EXIT_SUCCESS;

cleanup:
    if (uplink_pcm != NULL && api->pcm_close(uplink_pcm) != 0) {
        log_message("warn", "local in-call tone PCM close failed");
        result = EXIT_FAILURE;
    }
    if (mixer_enabled && set_voice_mixer(api, MIXER_UPLINK, "0") != 0) {
        result = EXIT_FAILURE;
    }
    if (anchor_started &&
        voice_session_anchor_stop(api, &anchor) != EXIT_SUCCESS) {
        result = EXIT_FAILURE;
    }
    if (usb_audio_changed && set_voice_audio_enabled(original_usb_audio) != 0) {
        result = EXIT_FAILURE;
    }
    return result;
}

static int run_uplink_media_session(
    struct network_session *session, const struct sockaddr_in *source,
    uint32_t session_id, uint32_t sequence,
    unsigned char payload[NETWORK_PCM_FRAME_BYTES])
{
    unsigned char silence[NETWORK_PCM_FRAME_BYTES];
    struct voice_session_anchor anchor;
    struct uplink_jitter_buffer jitter;
    int64_t next_frame_usec;
    void *uplink_pcm = NULL;
    int original_usb_audio = 0;
    int observed_usb_audio = 0;
    int usb_audio_changed = 0;
    int incall_mixer_enabled = 0;
    int downlink_mixer_enabled = 0;
    int anchor_started = 0;
    int downlink_started = 0;
    int payload_ready = 0;
    unsigned int uplink_pcm_buffer_length = 0U;
    uint32_t played_sequence = sequence;
    pthread_t downlink_thread_id;
    uint64_t written_frames = 0U;
    uint64_t audio_frames = 0U;
    unsigned int maximum_peak = 0U;
    int result = EXIT_FAILURE;

    memset(silence, 0, sizeof(silence));
    memset(&jitter, 0, sizeof(jitter));
    session->peer = *source;
    session->session_id = session_id;
    session->rx_sequence = sequence;
    session->tx_sequence = 0U;
    session->media_stop = 0;
    session->downlink_failed = 0;
    enqueue_uplink_frame(&jitter, payload, sequence);

    if (get_voice_audio_enabled(&original_usb_audio) != 0) {
        goto cleanup;
    }
    if (original_usb_audio != 0) {
        if (set_voice_audio_enabled(0) != 0) {
            goto cleanup;
        }
        usb_audio_changed = 1;
    }
    if (get_voice_audio_enabled(&observed_usb_audio) != 0 ||
        observed_usb_audio != 0) {
        log_message("error", "uplink listener USB UAC bypass verification failed");
        goto cleanup;
    }
    if (voice_session_anchor_start(session->api, &anchor) != EXIT_SUCCESS) {
        goto cleanup;
    }
    anchor_started = 1;
    log_message("info", "preserving active VoLTE SEC_AUX route and routing "
                "Media1 directly to VOICE_PLAYBACK_TX via Incall_Music");
    if (set_voice_mixer(session->api, MIXER_UPLINK, "1") != 0) {
        goto cleanup;
    }
    incall_mixer_enabled = 1;
    uplink_pcm = session->api->pcm_open(
        NETWORK_UPLINK_PCM_DEVICE, PCM_PLAYBACK_FLAGS,
        NETWORK_UPLINK_DEVICE_RATE, PCM_CHANNELS, PCM_FORMAT_S16_LE,
        PCM_HOSTLESS);
    if (uplink_pcm == NULL) {
        log_message("error", "uplink listener could not open %s",
                    NETWORK_UPLINK_PCM_DEVICE);
        goto cleanup;
    }
    uplink_pcm_buffer_length = session->api->pcm_buffer_len(uplink_pcm);
    if (!valid_uplink_pcm_buffer_length(uplink_pcm_buffer_length)) {
        log_message("error", "uplink listener got invalid %s buffer length %u",
                    NETWORK_UPLINK_PCM_DEVICE, uplink_pcm_buffer_length);
        goto cleanup;
    }
    session->uplink_pcm = uplink_pcm;
    if (set_voice_mixer(session->api, MIXER_DOWNLINK, "1") != 0) {
        goto cleanup;
    }
    downlink_mixer_enabled = 1;
    session->downlink_pcm = session->api->pcm_open(
        INCALL_DOWNLINK_PCM_DEVICE, PCM_CAPTURE_FLAGS,
        NETWORK_UPLINK_DEVICE_RATE, PCM_CHANNELS, PCM_FORMAT_S16_LE,
        PCM_HOSTLESS);
    if (session->downlink_pcm == NULL) {
        log_message("error", "downlink listener could not open %s",
                    INCALL_DOWNLINK_PCM_DEVICE);
        goto cleanup;
    }
    session->downlink_pcm_buffer_length =
        session->api->pcm_buffer_len(session->downlink_pcm);
    if (!valid_downlink_pcm_buffer_length(
            session->downlink_pcm_buffer_length)) {
        log_message("error", "downlink listener got invalid %s buffer length %u",
                    INCALL_DOWNLINK_PCM_DEVICE,
                    session->downlink_pcm_buffer_length);
        goto cleanup;
    }
    session->downlink_resample_capacity =
        NETWORK_UPLINK_DEVICE_FRAME_BYTES +
        session->downlink_pcm_buffer_length;
    session->downlink_resample_buffer =
        malloc(session->downlink_resample_capacity);
    if (session->downlink_resample_buffer == NULL) {
        log_message("error", "could not allocate downlink resample buffer");
        goto cleanup;
    }
    session->downlink_resample_available = 0U;
    if (pthread_create(&downlink_thread_id, NULL, incall_downlink_thread,
                       session) != 0) {
        log_message("error", "could not start in-call downlink worker");
        goto cleanup;
    }
    downlink_started = 1;
    session->last_rx_usec = monotonic_usec();
    next_frame_usec = session->last_rx_usec;
    if (session->last_rx_usec < 0LL) {
        log_message("error", "uplink media clock failed");
        goto cleanup;
    }
    if (drain_uplink_packets(session, &jitter) != 0) {
        goto cleanup;
    }
    log_message("info", "authenticated uplink session active: peer=%s:%u "
                "session=%u network=8000/mono/S16_LE frame=256 "
                "Media1=48000/mono/S16_LE Incall_Music pcm_buffer=%u "
                "chunks=%u jitter=%u/%u downlink=%s/%u",
                inet_ntoa(source->sin_addr),
                (unsigned int)ntohs(source->sin_port), session_id,
                uplink_pcm_buffer_length,
                NETWORK_UPLINK_DEVICE_FRAME_BYTES /
                    uplink_pcm_buffer_length,
                jitter.count, UPLINK_JITTER_CAPACITY,
                INCALL_DOWNLINK_PCM_DEVICE,
                session->downlink_pcm_buffer_length);

    while (!should_stop()) {
        int64_t current_usec = monotonic_usec();

        if (current_usec < 0LL) {
            log_message("error", "uplink media clock failed");
            goto cleanup;
        }
        if (session->downlink_failed) {
            log_message("error", "in-call downlink worker failed");
            goto cleanup;
        }
        if (current_usec < next_frame_usec) {
            usleep((unsigned int)(next_frame_usec - current_usec));
        } else if (current_usec - next_frame_usec >
                   (int64_t)NETWORK_PCM_FRAME_USEC) {
            next_frame_usec = current_usec;
        }
        if (drain_uplink_packets(session, &jitter) != 0) {
            goto cleanup;
        }
        payload_ready = dequeue_uplink_frame(
            &jitter, payload, &played_sequence);
        current_usec = monotonic_usec();
        if (current_usec < 0LL) {
            log_message("error", "uplink media clock failed");
            goto cleanup;
        }
        if (current_usec - session->last_rx_usec >
            NETWORK_SESSION_TIMEOUT_USEC) {
            log_message("info", "uplink session idle timeout; returning to listener");
            result = EXIT_SUCCESS;
            goto cleanup;
        }
        if (write_uplink_network_frame(
                session->api, uplink_pcm, uplink_pcm_buffer_length,
                payload_ready ? payload : silence) != 0) {
            log_message("error", "uplink listener Media1 PCM write failed");
            goto cleanup;
        }
        written_frames += 1U;
        if (payload_ready) {
            unsigned int peak = pcm_s16le_peak(payload);

            audio_frames += 1U;
            if (peak > maximum_peak) {
                maximum_peak = peak;
            }
            if (audio_frames == 1U) {
                log_message("info", "uplink first Media1 frame: sequence=%u "
                            "peak=%u/32768", played_sequence, peak);
            }
        }
        if (written_frames % 500U == 0U) {
            log_message("info", "uplink Media1 progress: written=%llu "
                        "audio=%llu silence=%llu last_sequence=%u "
                        "max_peak=%u/32768 jitter=%u/%u overflow=%llu",
                        (unsigned long long)written_frames,
                        (unsigned long long)audio_frames,
                        (unsigned long long)(written_frames - audio_frames),
                        played_sequence, maximum_peak, jitter.count,
                        UPLINK_JITTER_CAPACITY,
                        (unsigned long long)jitter.dropped);
        }
        next_frame_usec += (int64_t)NETWORK_PCM_FRAME_USEC;
    }
    result = EXIT_SUCCESS;

cleanup:
    if (written_frames != 0U) {
        log_message("info", "uplink Media1 final: written=%llu audio=%llu "
                    "silence=%llu last_sequence=%u max_peak=%u/32768 "
                    "jitter=%u/%u overflow=%llu",
                    (unsigned long long)written_frames,
                    (unsigned long long)audio_frames,
                    (unsigned long long)(written_frames - audio_frames),
                    played_sequence, maximum_peak, jitter.count,
                    UPLINK_JITTER_CAPACITY,
                    (unsigned long long)jitter.dropped);
    }
    session->media_stop = 1;
    if (downlink_started) {
        (void)pthread_cancel(downlink_thread_id);
        (void)pthread_join(downlink_thread_id, NULL);
        downlink_started = 0;
    }
    if (session->downlink_pcm != NULL) {
        if (session->api->pcm_close(session->downlink_pcm) != 0) {
            log_message("warn", "could not close downlink listener PCM cleanly");
            result = EXIT_FAILURE;
        }
        session->downlink_pcm = NULL;
    }
    free(session->downlink_resample_buffer);
    session->downlink_resample_buffer = NULL;
    session->downlink_resample_capacity = 0U;
    session->downlink_resample_available = 0U;
    session->uplink_pcm = NULL;
    if (uplink_pcm != NULL && session->api->pcm_close(uplink_pcm) != 0) {
        log_message("warn", "could not close uplink listener PCM cleanly");
        result = EXIT_FAILURE;
    }
    if (incall_mixer_enabled &&
        set_voice_mixer(session->api, MIXER_UPLINK, "0") != 0) {
        result = EXIT_FAILURE;
    }
    if (downlink_mixer_enabled &&
        set_voice_mixer(session->api, MIXER_DOWNLINK, "0") != 0) {
        result = EXIT_FAILURE;
    }
    if (anchor_started &&
        voice_session_anchor_stop(session->api, &anchor) != EXIT_SUCCESS) {
        result = EXIT_FAILURE;
    }
    if (usb_audio_changed && set_voice_audio_enabled(original_usb_audio) != 0) {
        log_message("warn", "could not restore USB UAC state after uplink session");
        result = EXIT_FAILURE;
    }
    memset(&session->peer, 0, sizeof(session->peer));
    session->session_id = 0U;
    session->rx_sequence = 0U;
    return result;
}

static int run_uplink_listener(struct vendor_audio *api,
                               const struct network_options *options,
                               int verbose)
{
    struct network_session session;
    struct in_addr local_address;
    uint32_t last_session_id = 0U;
    int result = EXIT_FAILURE;

    memset(&session, 0, sizeof(session));
    session.api = api;
    session.socket_fd = -1;
    session.verbose = verbose;
    if (load_pairing_key(options->token_file, session.key) != 0 ||
        install_signal_handlers() != 0 ||
        setup_bound_network_socket(&session, options, &local_address) != 0) {
        goto cleanup;
    }
    log_message("info", "authenticated uplink listener ready on %s:%u via %s; "
                "PCM remains closed until a valid packet arrives",
                options->listen_address, options->port,
                options->interface_name);
    while (!should_stop()) {
        struct sockaddr_in source;
        unsigned char payload[NETWORK_PCM_FRAME_BYTES];
        uint32_t session_id;
        uint32_t sequence;
        int wait_result = wait_for_initial_uplink_packet(
            &session, &local_address, last_session_id, &source, &session_id,
            &sequence, payload);

        if (wait_result < 0) {
            goto cleanup;
        }
        if (wait_result == 0) {
            break;
        }
        if (run_uplink_media_session(&session, &source, session_id, sequence,
                                     payload) != EXIT_SUCCESS) {
            goto cleanup;
        }
        last_session_id = session_id;
    }
    result = EXIT_SUCCESS;

cleanup:
    if (session.socket_fd >= 0) {
        (void)close(session.socket_fd);
    }
    memset(session.key, 0, sizeof(session.key));
    return result;
}

struct worker_resources {
    struct bridge_context *context;
    void *pcm;
    unsigned char *buffer;
    const char *mixer_name;
    int mixer_enabled;
    size_t carried_bytes;
    unsigned long dropped_frames;
};

static void release_worker_resources(void *opaque)
{
    struct worker_resources *resources = opaque;

    free(resources->buffer);
    resources->buffer = NULL;
    if (resources->pcm != NULL) {
        if (resources->context->api.pcm_close(resources->pcm) != 0) {
            log_message("error", "could not close PCM for %s",
                        resources->mixer_name);
            mark_worker_failed(resources->context);
        }
        resources->pcm = NULL;
    }
    if (resources->mixer_enabled) {
        if (resources->context->api.set_mixer(resources->mixer_name, 1, "0") ==
            0) {
            log_message("error", "could not disable mixer %s",
                        resources->mixer_name);
            mark_worker_failed(resources->context);
        }
        resources->mixer_enabled = 0;
    }
}

static void *uplink_thread(void *opaque)
{
    struct bridge_context *context = opaque;
    struct worker_resources resources;
    unsigned int buffer_length = 0;
    int cancel_error;

    memset(&resources, 0, sizeof(resources));
    resources.context = context;
    resources.mixer_name = MIXER_UPLINK;

    cancel_error = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    if (cancel_error != 0) {
        log_message("error", "could not protect uplink setup: %s",
                    strerror(cancel_error));
        mark_worker_failed(context);
        return NULL;
    }

    pthread_cleanup_push(release_worker_resources, &resources);

    if (should_stop()) {
        goto done;
    }

    if (context->use_mixers &&
        !enable_mixer_with_retry(context, MIXER_UPLINK)) {
        if (!should_stop()) {
            log_message("error", "uplink mixer unavailable after %u retries",
                        STARTUP_RETRY_LIMIT);
            mark_worker_failed(context);
        }
        goto done;
    }
    resources.mixer_enabled = context->use_mixers;

    resources.pcm =
        open_pcm_with_retry(context, context->playback_device,
                            PCM_PLAYBACK_FLAGS, "uplink");
    if (resources.pcm == NULL) {
        if (!should_stop()) {
            log_message("error", "uplink PCM unavailable after %u retries",
                        STARTUP_RETRY_LIMIT);
            mark_worker_failed(context);
        }
        goto done;
    }

    buffer_length = context->api.pcm_buffer_len(resources.pcm);
    if (!valid_buffer_length(buffer_length)) {
        log_message("error", "invalid uplink buffer length %u", buffer_length);
        mark_worker_failed(context);
        goto done;
    }
    resources.buffer = calloc(1U, buffer_length);
    if (resources.buffer == NULL) {
        log_message("error", "could not allocate %u-byte uplink buffer",
                    buffer_length);
        mark_worker_failed(context);
        goto done;
    }

    if (context->verbose) {
        log_message("info", "uplink active, PCM buffer %u bytes", buffer_length);
    }
    cancel_error = pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, NULL);
    if (cancel_error != 0) {
        log_message("error", "could not enable uplink cancellation: %s",
                    strerror(cancel_error));
        mark_worker_failed(context);
        goto done;
    }
    usleep(IDLE_RETRY_USEC);

    while (!should_stop()) {
        ssize_t received =
            read(context->tty_fd, resources.buffer + resources.carried_bytes,
                 (size_t)buffer_length - resources.carried_bytes);

        if (received > 0) {
            size_t total_bytes = resources.carried_bytes + (size_t)received;
            size_t pcm_bytes = total_bytes & ~(size_t)1U;
            unsigned char trailing_byte = 0U;

            if (pcm_bytes != total_bytes) {
                trailing_byte = resources.buffer[pcm_bytes];
            }
            if (pcm_bytes > 0U &&
                context->api.pcm_write(resources.pcm, resources.buffer,
                                       (unsigned int)pcm_bytes) != 0) {
                log_message("error", "uplink PCM write failed (%lu bytes)",
                            (unsigned long)pcm_bytes);
                mark_worker_failed(context);
                break;
            }
            resources.carried_bytes = total_bytes - pcm_bytes;
            if (resources.carried_bytes != 0U) {
                resources.buffer[0] = trailing_byte;
            }
            continue;
        }
        if (received == 0 ||
            (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            usleep(IDLE_RETRY_USEC);
            continue;
        }
        if (received < 0 && errno == EINTR) {
            continue;
        }

        log_message("error", "tty uplink read failed: %s", strerror(errno));
        mark_worker_failed(context);
        break;
    }

done:
    (void)pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    request_worker_stop();
    pthread_cleanup_pop(1);
    return NULL;
}

/*
 * Return 0 after a complete frame, 1 when an untouched frame was dropped due
 * to backpressure, and -1 on an I/O error.  Once any prefix has reached the
 * byte stream, finish that frame or fail the bridge so PCM16 sample alignment
 * cannot silently shift after an odd-length short write.
 */
static int write_downlink_frame(struct bridge_context *context,
                                const unsigned char *buffer,
                                unsigned int buffer_length)
{
    size_t offset = 0U;

    while (offset < (size_t)buffer_length && !should_stop()) {
        ssize_t written = write(context->tty_fd, buffer + offset,
                                (size_t)buffer_length - offset);

        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written == 0 ||
            (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            if (offset == 0U) {
                usleep(IDLE_RETRY_USEC);
                return 1;
            }
            /*
             * A frame prefix has already entered ttyGS0, so dropping the
             * suffix would shift every later PCM16 sample.  During startup
             * the module can fill g_serial before macOS opens interface 1;
             * wait for the host to drain it instead of killing the bridge
             * after an arbitrary 40 ms.  SIGTERM still breaks the loop via
             * should_stop(), so cleanup remains bounded by the supervisor.
             */
            usleep(PARTIAL_WRITE_RETRY_USEC);
            continue;
        }

        log_message("error", "tty downlink write failed: %s", strerror(errno));
        return -1;
    }

    return 0;
}

static void *downlink_thread(void *opaque)
{
    struct bridge_context *context = opaque;
    struct worker_resources resources;
    unsigned int buffer_length = 0;
    int cancel_error;

    memset(&resources, 0, sizeof(resources));
    resources.context = context;
    resources.mixer_name = MIXER_DOWNLINK;

    cancel_error = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    if (cancel_error != 0) {
        log_message("error", "could not protect downlink setup: %s",
                    strerror(cancel_error));
        mark_worker_failed(context);
        return NULL;
    }

    pthread_cleanup_push(release_worker_resources, &resources);

    if (should_stop()) {
        goto done;
    }

    if (context->use_mixers &&
        !enable_mixer_with_retry(context, MIXER_DOWNLINK)) {
        if (!should_stop()) {
            log_message("error", "downlink mixer unavailable after %u retries",
                        STARTUP_RETRY_LIMIT);
            mark_worker_failed(context);
        }
        goto done;
    }
    resources.mixer_enabled = context->use_mixers;

    resources.pcm =
        open_pcm_with_retry(context, context->capture_device,
                            PCM_CAPTURE_FLAGS, "downlink");
    if (resources.pcm == NULL) {
        if (!should_stop()) {
            log_message("error", "downlink PCM unavailable after %u retries",
                        STARTUP_RETRY_LIMIT);
            mark_worker_failed(context);
        }
        goto done;
    }

    buffer_length = context->api.pcm_buffer_len(resources.pcm);
    if (!valid_buffer_length(buffer_length)) {
        log_message("error", "invalid downlink buffer length %u", buffer_length);
        mark_worker_failed(context);
        goto done;
    }
    resources.buffer = calloc(1U, buffer_length);
    if (resources.buffer == NULL) {
        log_message("error", "could not allocate %u-byte downlink buffer",
                    buffer_length);
        mark_worker_failed(context);
        goto done;
    }

    if (context->verbose) {
        log_message("info", "downlink active, PCM buffer %u bytes", buffer_length);
    }
    cancel_error = pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, NULL);
    if (cancel_error != 0) {
        log_message("error", "could not enable downlink cancellation: %s",
                    strerror(cancel_error));
        mark_worker_failed(context);
        goto done;
    }
    usleep(IDLE_RETRY_USEC);

    while (!should_stop()) {
        int write_result;

        if (context->api.pcm_read(resources.pcm, resources.buffer,
                                  buffer_length) != 0) {
            if (!should_stop()) {
                log_message("error", "downlink PCM read failed");
                mark_worker_failed(context);
            }
            break;
        }

        write_result =
            write_downlink_frame(context, resources.buffer, buffer_length);
        if (write_result > 0) {
            ++resources.dropped_frames;
            if (context->verbose &&
                (resources.dropped_frames == 1UL ||
                 resources.dropped_frames % 50UL == 0UL)) {
                log_message("warn", "dropped %lu downlink PCM frames",
                            resources.dropped_frames);
            }
            continue;
        }
        if (write_result < 0) {
            mark_worker_failed(context);
            break;
        }
    }

done:
    (void)pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    request_worker_stop();
    pthread_cleanup_pop(1);
    return NULL;
}

static void reap_worker(pthread_t thread, int *started, const char *name,
                        struct bridge_context *context)
{
    int error;

    if (!*started) {
        return;
    }
    error = pthread_tryjoin_np(thread, NULL);
    if (error == 0) {
        *started = 0;
        return;
    }
    if (error == EBUSY) {
        return;
    }

    log_message("error", "could not join %s thread: %s", name,
                strerror(error));
    *started = 0;
    mark_worker_failed(context);
}

static void wait_for_workers(pthread_t uplink, int *uplink_started,
                             pthread_t downlink, int *downlink_started,
                             unsigned int timeout_usec,
                             struct bridge_context *context)
{
    unsigned int elapsed = 0U;

    while ((*uplink_started || *downlink_started) && elapsed < timeout_usec) {
        reap_worker(uplink, uplink_started, "uplink", context);
        reap_worker(downlink, downlink_started, "downlink", context);
        if (!*uplink_started && !*downlink_started) {
            break;
        }
        usleep(IDLE_RETRY_USEC);
        if (timeout_usec - elapsed < IDLE_RETRY_USEC) {
            elapsed = timeout_usec;
        } else {
            elapsed += IDLE_RETRY_USEC;
        }
    }
}

static int stop_and_join_workers(pthread_t uplink, int *uplink_started,
                                 pthread_t downlink, int *downlink_started,
                                 struct bridge_context *context)
{
    int error;

    request_worker_stop();
    wait_for_workers(uplink, uplink_started, downlink, downlink_started,
                     SHUTDOWN_GRACE_USEC, context);
    if (!*uplink_started && !*downlink_started) {
        return 0;
    }

    log_message("warn", "worker shutdown timed out; requesting cancellation");
    mark_worker_failed(context);
    if (*uplink_started) {
        error = pthread_cancel(uplink);
        if (error != 0 && error != ESRCH) {
            log_message("error", "could not cancel uplink thread: %s",
                        strerror(error));
        }
    }
    if (*downlink_started) {
        error = pthread_cancel(downlink);
        if (error != 0 && error != ESRCH) {
            log_message("error", "could not cancel downlink thread: %s",
                        strerror(error));
        }
    }

    wait_for_workers(uplink, uplink_started, downlink, downlink_started,
                     CANCEL_GRACE_USEC, context);
    if (*uplink_started || *downlink_started) {
        log_message("error", "one or more PCM workers did not terminate");
        return -1;
    }
    return 0;
}

static int run_workers_until_stop(pthread_t uplink, int *uplink_started,
                                  pthread_t downlink, int *downlink_started,
                                  struct bridge_context *context)
{
    while (!should_stop() && (*uplink_started || *downlink_started)) {
        reap_worker(uplink, uplink_started, "uplink", context);
        reap_worker(downlink, downlink_started, "downlink", context);
        if (*uplink_started || *downlink_started) {
            usleep(IDLE_RETRY_USEC);
        }
    }
    return stop_and_join_workers(uplink, uplink_started, downlink,
                                 downlink_started, context);
}

static void force_failure_exit(int signal_number)
{
    (void)signal_number;
    _Exit(EXIT_FAILURE);
}

static void emergency_rollback(struct bridge_context *context)
{
    struct sigaction action;

    /* Restore the tty before touching a vendor function that may share the
     * same lock as the stuck worker. */
    (void)restore_tty(context);

    memset(&action, 0, sizeof(action));
    action.sa_handler = force_failure_exit;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGALRM, &action, NULL) != 0) {
        log_message("error", "could not arm emergency rollback watchdog");
        fflush(stderr);
        return;
    }
    (void)alarm(1U);

    /* These mixer writes are idempotent and are the only safe cross-thread
     * rollback available if a vendor PCM call never returns. */
    if (context->use_mixers && context->api.set_mixer != NULL) {
        if (context->api.set_mixer(MIXER_UPLINK, 1, "0") == 0) {
            log_message("error", "emergency uplink mixer rollback failed");
        }
        if (context->api.set_mixer(MIXER_DOWNLINK, 1, "0") == 0) {
            log_message("error", "emergency downlink mixer rollback failed");
        }
    }
    (void)alarm(0U);
    fflush(stderr);
}

static void print_usage(const char *program)
{
    fprintf(stderr,
            "Usage: %s [--check] [--verbose] [--tty PATH] [--library PATH] "
            "[--playback-device NAME] [--capture-device NAME] [--no-mixers] "
            "[--voice-route-session] [--probe-network-pcm] "
            "[--probe-direct-pcm] [--probe-incall-music-tone] "
            "[--uplink-listener --listen-address IPv4 --audio-port PORT "
            "--token-file PATH --interface NAME] "
            "[--network-session --listen-address IPv4 --peer-address IPv4 "
            "--audio-port PORT --peer-port PORT --token-file PATH --interface NAME "
            "--session-id ID]\n",
            program);
}

int main(int argc, char **argv)
{
    const char *tty_path = DEFAULT_TTY_DEVICE;
    const char *library_path = DEFAULT_AUDIO_LIBRARY;
    struct bridge_context context;
    pthread_t uplink;
    pthread_t downlink;
    int uplink_started = 0;
    int downlink_started = 0;
    int check_only = 0;
    int voice_route_session = 0;
    int probe_network_pcm = 0;
    int probe_direct_pcm = 0;
    int probe_incall_music_tone = 0;
    struct network_options network_options;
    int index;
    int thread_error;
    int result = EXIT_FAILURE;

    memset(&context, 0, sizeof(context));
    memset(&uplink, 0, sizeof(uplink));
    memset(&downlink, 0, sizeof(downlink));
    context.tty_fd = -1;
    context.playback_device = PCM_DEVICE;
    context.capture_device = PCM_DEVICE;
    context.use_mixers = 1;
    memset(&network_options, 0, sizeof(network_options));
    network_options.listen_address = "192.168.225.1";
    network_options.port = NETWORK_AUDIO_PORT;
    network_options.peer_port = NETWORK_AUDIO_PORT;

    for (index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "--check") == 0) {
            check_only = 1;
        } else if (strcmp(argv[index], "--voice-route-session") == 0) {
            voice_route_session = 1;
        } else if (strcmp(argv[index], "--probe-network-pcm") == 0) {
            probe_network_pcm = 1;
        } else if (strcmp(argv[index], "--probe-direct-pcm") == 0) {
            probe_direct_pcm = 1;
        } else if (strcmp(argv[index], "--probe-incall-music-tone") == 0) {
            probe_incall_music_tone = 1;
        } else if (strcmp(argv[index], "--network-session") == 0) {
            network_options.enabled = 1;
        } else if (strcmp(argv[index], "--uplink-listener") == 0) {
            network_options.uplink_listener = 1;
        } else if (strcmp(argv[index], "--verbose") == 0) {
            context.verbose = 1;
        } else if (strcmp(argv[index], "--tty") == 0 && index + 1 < argc) {
            tty_path = argv[++index];
        } else if (strcmp(argv[index], "--library") == 0 && index + 1 < argc) {
            library_path = argv[++index];
        } else if (strcmp(argv[index], "--playback-device") == 0 &&
                   index + 1 < argc) {
            context.playback_device = argv[++index];
        } else if (strcmp(argv[index], "--capture-device") == 0 &&
                   index + 1 < argc) {
            context.capture_device = argv[++index];
        } else if (strcmp(argv[index], "--no-mixers") == 0) {
            context.use_mixers = 0;
        } else if (strcmp(argv[index], "--listen-address") == 0 &&
                   index + 1 < argc) {
            network_options.listen_address = argv[++index];
        } else if (strcmp(argv[index], "--peer-address") == 0 &&
                   index + 1 < argc) {
            network_options.peer_address = argv[++index];
        } else if (strcmp(argv[index], "--token-file") == 0 &&
                   index + 1 < argc) {
            network_options.token_file = argv[++index];
        } else if (strcmp(argv[index], "--interface") == 0 &&
                   index + 1 < argc) {
            network_options.interface_name = argv[++index];
        } else if (strcmp(argv[index], "--audio-port") == 0 &&
                   index + 1 < argc) {
            unsigned long parsed_port;
            char *end = NULL;

            parsed_port = strtoul(argv[++index], &end, 10);
            if (end == argv[index] || *end != '\0' || parsed_port == 0UL ||
                parsed_port > 65535UL) {
                log_message("error", "invalid UDP audio port");
                return EXIT_FAILURE;
            }
            network_options.port = (unsigned int)parsed_port;
        } else if (strcmp(argv[index], "--peer-port") == 0 &&
                   index + 1 < argc) {
            unsigned long parsed_port;
            char *end = NULL;

            parsed_port = strtoul(argv[++index], &end, 10);
            if (end == argv[index] || *end != '\0' || parsed_port == 0UL ||
                parsed_port > 65535UL) {
                log_message("error", "invalid UDP peer port");
                return EXIT_FAILURE;
            }
            network_options.peer_port = (unsigned int)parsed_port;
        } else if (strcmp(argv[index], "--session-id") == 0 &&
                   index + 1 < argc) {
            unsigned long parsed_session;
            char *end = NULL;

            parsed_session = strtoul(argv[++index], &end, 0);
            if (end == argv[index] || *end != '\0' || parsed_session == 0UL ||
                parsed_session > 0xffffffffUL) {
                log_message("error", "invalid network session id");
                return EXIT_FAILURE;
            }
            network_options.session_id = (uint32_t)parsed_session;
        } else {
            print_usage(argv[0]);
            return EXIT_FAILURE;
        }
    }

    if (context.playback_device[0] == '\0' ||
        context.capture_device[0] == '\0') {
        log_message("error", "PCM device names must not be empty");
        return EXIT_FAILURE;
    }
    if ((check_only && voice_route_session) ||
        (check_only && probe_network_pcm) ||
        (check_only && probe_direct_pcm) ||
        (check_only && probe_incall_music_tone) ||
        (check_only && network_options.enabled) ||
        (check_only && network_options.uplink_listener) ||
        (voice_route_session && probe_network_pcm) ||
        (voice_route_session && probe_direct_pcm) ||
        (voice_route_session && probe_incall_music_tone) ||
        (voice_route_session && network_options.enabled) ||
        (voice_route_session && network_options.uplink_listener) ||
        (probe_network_pcm && probe_direct_pcm) ||
        (probe_network_pcm && probe_incall_music_tone) ||
        (probe_network_pcm && network_options.enabled) ||
        (probe_network_pcm && network_options.uplink_listener) ||
        (probe_direct_pcm && network_options.enabled) ||
        (probe_direct_pcm && network_options.uplink_listener) ||
        (probe_direct_pcm && probe_incall_music_tone) ||
        (probe_incall_music_tone && network_options.enabled) ||
        (probe_incall_music_tone && network_options.uplink_listener) ||
        (network_options.enabled && network_options.uplink_listener)) {
        log_message("error",
                    "--check, --voice-route-session and "
                    "PCM probe/session modes are mutually exclusive");
        return EXIT_FAILURE;
    }
    if (network_options.enabled &&
        (network_options.peer_address == NULL ||
         network_options.token_file == NULL ||
         network_options.interface_name == NULL ||
         network_options.session_id == 0U || !context.use_mixers)) {
        log_message("error", "network session requires --peer-address, "
                    "--token-file, --interface, nonzero --session-id, "
                    "and mixers");
        return EXIT_FAILURE;
    }
    if (network_options.uplink_listener &&
        (network_options.token_file == NULL ||
         network_options.interface_name == NULL || !context.use_mixers)) {
        log_message("error", "uplink listener requires --token-file, "
                    "--interface, and mixers");
        return EXIT_FAILURE;
    }

    if (load_vendor_audio(&context.api, library_path) != 0) {
        return EXIT_FAILURE;
    }
    if (check_only) {
        log_message("info", "all required symbols are available in %s",
                    library_path);
        unload_vendor_audio(&context.api);
        return EXIT_SUCCESS;
    }
    if (voice_route_session) {
        result = run_voice_route_session(&context.api, context.verbose);
        unload_vendor_audio(&context.api);
        return result;
    }
    if (probe_network_pcm) {
        result = run_network_pcm_probe(&context.api, context.verbose);
        unload_vendor_audio(&context.api);
        return result;
    }
    if (probe_direct_pcm) {
        result = run_direct_pcm_probe(&context.api, context.verbose);
        unload_vendor_audio(&context.api);
        return result;
    }
    if (probe_incall_music_tone) {
        result = run_incall_music_tone_probe(&context.api);
        unload_vendor_audio(&context.api);
        return result;
    }
    if (network_options.enabled) {
        result = run_network_session(&context.api, &network_options,
                                     context.verbose);
        unload_vendor_audio(&context.api);
        return result;
    }
    if (network_options.uplink_listener) {
        result = run_uplink_listener(&context.api, &network_options,
                                     context.verbose);
        unload_vendor_audio(&context.api);
        return result;
    }

    context.tty_fd =
        open(tty_path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (context.tty_fd < 0) {
        log_message("error", "open(%s) failed: %s", tty_path, strerror(errno));
        goto cleanup;
    }
    if (configure_raw_tty(&context) != 0 || install_signal_handlers() != 0) {
        goto cleanup;
    }

    thread_error = pthread_create(&uplink, NULL, uplink_thread, &context);
    if (thread_error != 0) {
        log_message("error", "could not start uplink thread: %s",
                    strerror(thread_error));
        mark_worker_failed(&context);
        goto cleanup;
    }
    uplink_started = 1;
    thread_error = pthread_create(&downlink, NULL, downlink_thread, &context);
    if (thread_error != 0) {
        log_message("error", "could not start downlink thread: %s",
                    strerror(thread_error));
        mark_worker_failed(&context);
        goto cleanup;
    }
    downlink_started = 1;

    log_message("info",
                "bridge active on %s (playback=%s capture=%s mixers=%s); "
                "send SIGTERM to stop",
                tty_path, context.playback_device, context.capture_device,
                context.use_mixers ? "on" : "off");
    if (run_workers_until_stop(uplink, &uplink_started, downlink,
                               &downlink_started, &context) != 0) {
        emergency_rollback(&context);
        _Exit(EXIT_FAILURE);
    }
    result = worker_failed(&context) ? EXIT_FAILURE : EXIT_SUCCESS;

cleanup:
    if (uplink_started || downlink_started) {
        if (stop_and_join_workers(uplink, &uplink_started, downlink,
                                  &downlink_started, &context) != 0) {
            emergency_rollback(&context);
            _Exit(EXIT_FAILURE);
        }
    }
    if (context.tty_fd >= 0) {
        if (restore_tty(&context) != 0) {
            result = EXIT_FAILURE;
        }
        if (close(context.tty_fd) != 0) {
            log_message("warn", "close(%s) failed: %s", tty_path,
                        strerror(errno));
            result = EXIT_FAILURE;
        }
        context.tty_fd = -1;
    }
    unload_vendor_audio(&context.api);
    return result;
}
