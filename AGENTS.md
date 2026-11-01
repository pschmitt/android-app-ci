# Agent notes

This repository contains shared Android CI interfaces for existing callers.
The README says new integrations and shared interface updates have moved to
[ci-workflows](https://github.com/pschmitt/ci-workflows).

- Keep existing caller workflows compatible while they migrate.
- Check the corresponding `ci-workflows` interface before changing a shared
  workflow; preserve callers' triggers, inputs, permissions, and check
  coverage.
- Validate workflow changes in a consuming Android project and avoid
  publishing app releases as part of CI maintenance.
