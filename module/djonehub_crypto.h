#ifndef DJONEHUB_CRYPTO_H
#define DJONEHUB_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#define DJONEHUB_SHA256_BYTES 32U
#define DJONEHUB_PAIRING_KEY_BYTES 32U

void djonehub_hmac_sha256(const uint8_t *key, size_t key_length,
                          const uint8_t *data, size_t data_length,
                          uint8_t digest[DJONEHUB_SHA256_BYTES]);

int djonehub_secure_equal(const uint8_t *left, const uint8_t *right,
                          size_t length);

/*
 * Loads an exact 32-byte key from a regular file.  Group and other permission
 * bits must be clear.  The caller remains responsible for checking ownership
 * against the daemon account before accepting network traffic.
 */
int djonehub_load_pairing_key(const char *path,
                              uint8_t key[DJONEHUB_PAIRING_KEY_BYTES]);

#endif
