# Changelog

## 2026-11-17 — Placement CLI dependency fix

- Controller `phase_placement` installs `python3-osc-placement` alongside `placement-api`.
- Resolves postcheck `openstack resource provider list` returning `Unknown command` on a host with a functioning Placement HTTP API but without the CLI plugin.
- No changes to Compute/Storage scripts or any live host. The update is statically checked; fresh-host installation remains unverified.
