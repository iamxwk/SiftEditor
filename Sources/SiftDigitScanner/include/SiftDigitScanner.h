#ifndef SIFT_DIGIT_SCANNER_H
#define SIFT_DIGIT_SCANNER_H

#include <stddef.h>
#include <stdint.h>

// Counts one-character ICU \d matches by Unicode scalar value. `counts` has
// 0x110000 entries. Callers split UTF-8 only at scalar boundaries.
uint64_t sift_count_decimal_digits(const uint8_t *bytes, size_t length, uint64_t *counts);
int sift_contains_decimal_digit(const uint8_t *bytes, size_t length);

#endif
