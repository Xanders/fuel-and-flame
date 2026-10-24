# Contributing

Use a failing behavior test before implementation, then the smallest complete change and refactor. Run dart analyze, Dart core tests and affected Flutter/Flame tests using the README toolchain. Keep exact retries, cancellation, ownership, background/resume and subscription cleanup tests meaningful.

Review initial code as a complete tree; later review exact candidates and their connected contracts. Resolve material findings before publishing. Use CODEOWNERS and GitHub issues for shared API gaps; avoid game-local SDK forks.

Do not commit credentials, private transcripts, generated SDK caches or machine-specific paths. Platform secure storage and real-device behavior must be tested in the consuming application; unit tests do not prove those properties.
