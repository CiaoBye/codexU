// Minimal Zstandard decode API used by codexU.
//
// The implementation is the official Zstandard v1.5.7 single-file decode-only
// amalgamation. See README.md in this directory for provenance.
#ifndef CODEXU_ZSTD_H
#define CODEXU_ZSTD_H

#include <stddef.h>

size_t ZSTD_decompress(void *dst, size_t dstCapacity,
                       const void *src, size_t compressedSize);
size_t ZSTD_findFrameCompressedSize(const void *src, size_t srcSize);
unsigned ZSTD_isError(size_t result);
unsigned long long ZSTD_getFrameContentSize(const void *src, size_t srcSize);

#define ZSTD_CONTENTSIZE_UNKNOWN (0ULL - 1)
#define ZSTD_CONTENTSIZE_ERROR   (0ULL - 2)

#endif /* CODEXU_ZSTD_H */
