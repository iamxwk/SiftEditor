#include "SiftDigitScanner.h"
#include <unicode/uchar.h>

static unsigned decimal_digit_width(const uint8_t *bytes, size_t length, size_t i,
                                    uint32_t *value) {
    uint8_t first = bytes[i];
    if (first >= '0' && first <= '9') {
        *value = first;
        return 1;
    }
    if (first < 0x80) return 0;

    unsigned width;
    uint32_t scalar;
    uint32_t minimum;
    if ((first & 0xE0) == 0xC0) {
        width = 2; scalar = first & 0x1F; minimum = 0x80;
    } else if ((first & 0xF0) == 0xE0) {
        width = 3; scalar = first & 0x0F; minimum = 0x800;
    } else if ((first & 0xF8) == 0xF0) {
        width = 4; scalar = first & 0x07; minimum = 0x10000;
    } else return 0;
    if (length - i < width) return 0;
    for (unsigned used = 1; used < width; ++used) {
        uint8_t continuation = bytes[i + used];
        if ((continuation & 0xC0) != 0x80) return 0;
        scalar = (scalar << 6) | (continuation & 0x3F);
    }
    if (scalar < minimum || scalar > 0x10FFFF ||
        (scalar >= 0xD800 && scalar <= 0xDFFF)) return 0;
    if (u_charType((UChar32)scalar) != U_DECIMAL_DIGIT_NUMBER) return 0;
    *value = scalar;
    return width;
}

uint64_t sift_count_decimal_digits(const uint8_t *bytes, size_t length, uint64_t *counts) {
    uint64_t matches = 0;
    for (size_t i = 0; i < length; ++i) {
        uint8_t first = bytes[i];
        if (first >= '0' && first <= '9') {
            ++counts[first];
            ++matches;
            continue;
        }
        if (first < 0x80) continue;
        uint32_t value;
        unsigned width = decimal_digit_width(bytes, length, i, &value);
        if (!width) continue;
        ++counts[value];
        ++matches;
        i += width - 1;
    }
    return matches;
}

int sift_contains_decimal_digit(const uint8_t *bytes, size_t length) {
    for (size_t i = 0; i < length; ++i) {
        uint8_t first = bytes[i];
        if (first >= '0' && first <= '9') return 1;
        if (first < 0x80) continue;
        uint32_t value;
        if (decimal_digit_width(bytes, length, i, &value)) return 1;
    }
    return 0;
}
