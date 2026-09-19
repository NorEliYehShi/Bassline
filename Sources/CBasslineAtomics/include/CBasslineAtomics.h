#ifndef CBASSLINE_ATOMICS_H
#define CBASSLINE_ATOMICS_H

#include <stdint.h>

static inline void bsl_store_release_u64(uint64_t *slot, uint64_t value) {
    __atomic_store_n(slot, value, __ATOMIC_RELEASE);
}

static inline void bsl_store_relaxed_u64(uint64_t *slot, uint64_t value) {
    __atomic_store_n(slot, value, __ATOMIC_RELAXED);
}

static inline uint64_t bsl_load_acquire_u64(const uint64_t *slot) {
    return __atomic_load_n(slot, __ATOMIC_ACQUIRE);
}

static inline uint64_t bsl_load_relaxed_u64(const uint64_t *slot) {
    return __atomic_load_n(slot, __ATOMIC_RELAXED);
}

#endif /* CBASSLINE_ATOMICS_H */
