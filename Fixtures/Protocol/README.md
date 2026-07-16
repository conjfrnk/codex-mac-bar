# Shared protocol contracts

`rate-limit-contracts.json` is a language-neutral corpus consumed by both the
Swift and Rust test suites. Each case supplies either an app-server request-3
result or JSON-RPC error and its expected normalized presentation contract.

The contract covers lossy decoding, meaningful-data selection, legacy fallback,
derived spend-control percentages, reset-credit availability, and bounded
data-quality warnings. Warning comparisons use stable field paths because the
underlying decoder prose is platform-specific; transport-generated warnings
also specify their complete expected text.
