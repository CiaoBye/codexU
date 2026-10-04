# Third-Party Notices

## Zstandard

codexU vendors the official Zstandard v1.5.7 decode-only single-file
amalgamation (`Sources/CodexUsageWidget/Vendor/zstd/zstddeclib.c`) under the
BSD-3-Clause license. The corresponding license text is stored beside the
source.

Upstream: https://github.com/facebook/zstd

## Claude Desktop local cache reader design

The Claude Desktop local HTTP-cache reader in this fork is independently
adapted from the local-cache approach used by Codenotch
(https://github.com/vinzdg/codenotch), an MIT-licensed project by Vinz.
The implementation is intentionally read-only and does not use OAuth tokens,
cookies, Keychain credentials, or direct Anthropic network requests.

Codenotch license: MIT.
