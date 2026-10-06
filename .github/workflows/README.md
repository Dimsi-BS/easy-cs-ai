# Workflows directory

[← Back to project root](../../README.md)

This directory contains the CI workflows for the project:

- `ci.yml`: `shellcheck` and the `bats` unit tests on every push;
- `release.yml`: on a `v*` tag, builds the tarball, `.deb` and `.rpm` (see [packaging](../../docs/decision-packaging.md#implementation)) and publishes them with their checksums as a GitHub release. Not run yet.

See also: [tests](../../tests/README.md), the test suite these workflows run.
