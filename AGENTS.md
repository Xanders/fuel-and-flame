# Fuel SDK contributor guide

Read README.md and docs/USAGE.md plus Fuel's public wire API before changing behavior. Single-maintainer pre-production packages; GitHub issues handle feature requests and CODEOWNERS identifies the maintainer.

Apply [Ponytail](.agents/skills/ponytail/SKILL.md). Use TDD for behavior, analyze and run affected package tests. Obtain independent review of the exact candidate before publication; review the whole tree for the initial import. Keep the Dart core independent of Flutter/Flame.

Preserve exact semantic command identity, explicit session loss, secure credential storage boundaries, single-flight polling and generation fences. Never replay transient inputs as persistent commands. Flame presentation must not own server rules or pause server deadlines.

Public files must remain portable and omit machine-specific paths, private consumer details and host-specific operations. Read AGENTS_LOCAL.md **if it exists**; it is optional and ignored. Never publish its details. Keep architecture contracts and useful lessons current after substantial changes.
