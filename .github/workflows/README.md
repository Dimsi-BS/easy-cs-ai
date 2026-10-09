# Workflows directory

[← Back to project root](../../README.md)

This directory contains the CI workflows for the project:

- `ci.yml`: `shellcheck` and the `bats` unit tests, and the [packaging tests](../../tests/packaging/README.md) (tarball, `.deb`, `.rpm` built and installed in containers), on every push;
- `release.yml`: on a `v*` tag, runs the tests, builds the tarball, `.deb` and `.rpm` (see [packaging](../../docs/decision-packaging.md#implementation)), checks them with the packaging tests and publishes them with their checksums as a GitHub release. `v0.1.0` is a release (the latest); a tag with a hyphen, `v0.1.0-rc1`, is a **pre-release**. Not run yet.

See also: [tests](../../tests/README.md), the test suite these workflows run.
