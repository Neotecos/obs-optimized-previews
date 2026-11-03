# OBS compatibility policy

All current and future changes must remain compatible across the complete
supported OBS Studio range, from the minimum supported version declared by the
project through the latest stable release. Implementations, build logic, and
tests must not assume only the compile-time OBS version or only the newest
runtime. When APIs, capabilities, or behavior differ by OBS version, use a
backward-compatible implementation and verify at least the oldest supported
version and the latest stable release.

Before increasing the minimum supported OBS Studio version, build the plugin
against the official tag of the current minimum and document the exact required
public API that is unavailable there.

# Commits

All commit messages are written in English and must not carry any agent
watermark: no `Co-Authored-By` trailer for an agent, no "Generated with"
line, and no other mention of the tool that produced the change.

# Tests

Tests and test-only files (for example everything under `tests/` and the
`op-*-test` and probe programs) must be listed in `.gitignore` and must not be
committed. When adding a new test, add its path to `.gitignore` in the same
change.
