# OpenStack Yoga 3-node deployment (Ubuntu 22.04)

**Status: reconstructed lab installation guide; NOT tested end-to-end on a fresh OS.**

This repository packages a staged Controller + Compute + Storage installation based on the team's historical package/root shell records and verified current settings. This is a **reproducibility candidate**, not a guaranteed installer. Use only isolated **new lab servers** with console access. Do **not** run mutation phases on the working `con`, `com`, or `sto` servers. Bash parsing has been checked, not actual OpenStack deployment.

## Files and order

| Location | Function | Steps |
|---|---|---|
| `controller/` | Keystone, Glance, Placement, Nova API, Neutron, Horizon, Cinder API/Scheduler, provider network | `preflight → base → keystone → glance → placement → nova → neutron → horizon → cinder` |
| `compute/` | KVM/libvirt, nova-compute, Neutron Linux Bridge provider mapping | `preflight → base → nova → neutron → verify` |
| `storage/` | cinder-volume, LVM VG discovery, TGT iSCSI | `preflight → base → lvm-check → cinder → verify` |
| `docs/` | Verified topology, runbook, evidence limitations and security checklist | Read before changing any host |

After all nodes are installed and externally connected, run Controller `provider` phase **only once** and verify `openstack compute service list`, `openstack network agent list`, `openstack hypervisor list`, and `openstack volume service list`.

## Setup

On each corresponding clean Ubuntu 22.04 test host, copy that node's script and `.env.example`. Rename the example to `~/controller_yoga.env`, `~/compute_yoga.env`, or `~/storage_yoga.env`, then `chmod 600` and edit. Set `CONFIRM_FRESH_HOST=YES_FRESH_HOST` **only after reviewing every step and backup**. Replace `<ENTER_...>` with passwords provisioned on the Controller. Secrets must be consistent between service endpoints and their accounts. The Controller sample uses one shared `SERVICE_PASS` and `DB_PASS` for convenience; Compute uses `NOVA_PASS`, `NEUTRON_PASS`, `PLACEMENT_PASS` and Storage uses `CINDER_PASS`, `CINDER_DB_PASS`; in the supplied Controller script these must match `SERVICE_PASS` and `DB_PASS`, respectively, unless Controller is adapted to per-service credentials.

**Public sample IPs `192.0.2.81/.82/.83` are documentation placeholders**, not usable real addresses. The observed lab used `con/com/sto`, Linux Bridge `provider:enp4s0` on Compute, a flat shared/external network `192.168.100.0/24` with gateway `192.168.100.1` and allocation pool `.100–.200`. The real flat network requires a functioning physical L2 network and configured external gateway/NAT. The historical gateway setup and OpenStack Notification→RabbitMQ→Agent log pipeline are not reproduced here.

Storage historical OS root LV and Cinder thin pool **share the same `ubuntu-vg`** (`/dev/nvme0n1p3`); this is not a recommended default for a fresh generic machine. Our Storage script does **not** run `pvcreate`, `vgcreate`, `lvcreate`, `mkfs`, `wipefs`, or `lvremove`, and does not change LVM filters. Prepare an appropriately sized, dedicated test VG independently after checking physical disks and backup/restore. Thin pool creation by Cinder is not treated as a successful complete API test.

### Review before execution

```bash
bash -n controller/controller_yoga.sh
bash -n compute/compute_yoga.sh
bash -n storage/storage_yoga.sh
```

See each node README for the precise commands. The Controller now supports one-shot `bash controller_yoga.sh` on a disposable clean lab host only (preflight and explicit confirmations required). Compute/Storage remain staged. Phases are **not idempotent** and are potentially destructive to a live deployment (DB/resource creation, configuration, service restarts). Shell history commands that had typos or incomplete arguments were not copied as instructions.

## Evidence vs. reconstruction

- **Observed**: Compute `nova-compute`, Linux Bridge, `provider:enp4s0`, `enable_vxlan=false`, KVM (`nova-compute.conf`), Chrony sync to Controller. Storage `cinder-volume`, `tgt`, `ubuntu-vg`, automatic thin provisioning; Controller shows all three service groups enabled/up on the observed date.
- **Reconstructed additions**: exact first-boot account/DB setup, inter-node credentials, some Neutron/Nova options, order of dependent services, and verification scaffolding. They are not historical execution evidence or clean-host validation.
- **Not validated**: fresh Ubuntu provisioning across three nodes, VM boot and provider connectivity, Cinder volume create/attach/read/write/detach, full network gateway/NAT and live security analytics pipeline.

No live passwords, tokens, private keys, credential-bearing config files, or raw root history should be pushed to public GitHub.


### Controller one-shot mode (updated)

On a fresh disposable Controller VM, create `~/controller_yoga.env` from `controller/controller_yoga.env.example`, configure actual IPs/NICs, passwords (any nonzero length using only ASCII letters, digits, `_`, `-`) and explicitly confirm both `CONFIRM_FRESH_HOST=YES_FRESH_HOST` and `CONFIRM_PROVIDER_PHYSICAL_NET=YES` after verifying provider L2 and gateway. Then:

```bash
cd ~/openstack-yoga-deployment/controller
bash controller_yoga.sh preflight
bash controller_yoga.sh
```

The no-argument script runs all Controller phases in order and writes completed-phase markers under `~/.local/state/openstack-yoga-controller/`. It stops on errors; an interrupted phase may have partially modified the host and must be reviewed before rerunning. Apt uses a lock wait to avoid clashes with unattended upgrades. It does not run Compute or Storage phases. This new mode has passed shell syntax and static inspection only, **not a full clean-install test**.
