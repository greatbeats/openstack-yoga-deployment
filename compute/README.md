# Compute node — `com` (Ubuntu 22.04 / Yoga)

**Reconstructed, untested on a new machine.** Historical evidence: `apt install -y nova-compute neutron-linuxbridge-agent crudini`, Chrony installation, root-shell `crudini` commands, and current settings. Provider flat bridge mapping `provider:enp4s0`; VXLAN disabled; `virt_type=kvm` resides in `/etc/nova/nova-compute.conf` (not in `nova.conf`). Chrony uses Controller `iburst`. The node's service, hypervisor, and Neutron agent were `up` during investigation.

1. On an isolated **fresh** Ubuntu Server 22.04, configure management NIC and a separate provider NIC **manually** (ensure local console access; network changes can disconnect SSH). Do not put a management IP on provider NIC. Verify physical flat network mapping and NTP.
2. Copy `compute_yoga.env.example` to `~/compute_yoga.env`; `chmod 600 ~/compute_yoga.env`; edit all hosts/NICs/secrets. **Use credentials created on Controller**; with the supplied Controller example: NOVA_PASS, NEUTRON_PASS and PLACEMENT_PASS all equal the Controller's SERVICE_PASS; RABBIT_PASS equals its RABBIT_PASS. Never commit populated env.
3. Review `compute_yoga.sh`; verify `bash -n compute_yoga.sh` and run stages **separately**:

```bash
bash compute_yoga.sh preflight
# Set CONFIRM_FRESH_HOST=YES_FRESH_HOST in your PRIVATE env only on clean test hardware
bash compute_yoga.sh base
bash compute_yoga.sh nova
bash compute_yoga.sh neutron
bash compute_yoga.sh verify
```

4. On Controller, with authenticated OpenStack CLI, run `openstack compute service list`, `openstack network agent list`, `openstack hypervisor list`; if the host is missing, review cell mapping and `sudo -u nova nova-manage cell_v2 discover_hosts --verbose` on Controller (this changes cell DB state; not part of read-only verification).
5. Do not assume services active means a VM can boot or obtain an IP. Validate on disposable resources after all nodes are set up.

**Not included:** fresh OS/netplan provisioning, NIC wiring, network gateway/NAT, VM lifecycle testing. `[libvirt] virt_type` is written to `nova-compute.conf` on this host because that is where the original environment set it.
