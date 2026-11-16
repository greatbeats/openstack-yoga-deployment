# Observed lab topology and network (as of 2026-11-16)

| Role | Host | Management IP (observed) | Components |
|---|---|---|---|
| Controller | `con` | `[REDACTED_CONTROLLER_IP]` | Keystone, Glance, Nova API/Conductor/Scheduler, Neutron Server/DHCP/Metadata/Linux Bridge, Cinder API/Scheduler, Placement, Horizon |
| Compute | `com` | `[REDACTED_COMPUTE_IP]` | Nova Compute, KVM/libvirt, Neutron Linux Bridge, provider NIC `enp4s0` |
| Storage | `sto` | `[REDACTED_STORAGE_IP]` | Cinder Volume LVM (`sto@lvm`), `ubuntu-vg` thin pool, TGT iSCSI TCP 3260 |

For public sharing, actual management addresses are redacted. The repository's `.env.example` files use reserved documentation IPs `192.0.2.81`/`.82`/`.83`. Never route those sample addresses as real lab addresses.

Provider network: `provider`, flat, physical network `provider`, external/shared. Compute mapping `provider:enp4s0`, VXLAN off. Subnet `provider-subnet`: `192.168.100.0/24`, gateway `192.168.100.1`, DHCP enabled, pool `192.168.100.100–192.168.100.200`, DNS `8.8.8.8`. This gateway and physical flat L2 transport must exist independently.

Observed resources: image `cirros` active, `test-vm` SHUTOFF at `192.168.100.147`, flavor `m1.tiny`. `SHUTOFF` does not demonstrate current VM connectivity. Controller status queries showed Nova Compute, Neutron agents and Cinder Scheduler/Volume all registered `up` at the time of the query. Does NOT certify VM lifecycle or Cinder attach.

Storage: `/dev/nvme0n1p3` contains `ubuntu-vg`, shares an OS root LV (~450 GiB) with a Cinder thin pool (~22.7 GiB), remaining VG free ~1.14 GiB at observation. This layout cannot be blindly recreated on arbitrary hardware.
