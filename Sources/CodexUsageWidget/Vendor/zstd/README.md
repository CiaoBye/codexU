# Vendored Zstandard decoder

codexU uses this decode-only Zstandard implementation solely to read the
**local HTTP cache written by Claude Desktop**. Claude Desktop currently stores
its Usage response body with `content-encoding: zstd`; macOS does not expose a
system Zstandard decoder suitable for a self-contained signed app.

- Upstream: https://github.com/facebook/zstd
- Version: v1.5.7
- File: official `zstddeclib.c` single-file decoder amalgamation
- License: BSD-3-Clause (see `LICENSE`)
- Local edits to `zstddeclib.c`: none

Only decompression is linked. codexU does not use this code for networking,
compression, credentials, cookies, prompts, or conversation content.

The vendored file and the narrow header are derived from the same source and
are intentionally kept separate from the Swift quota parser.
