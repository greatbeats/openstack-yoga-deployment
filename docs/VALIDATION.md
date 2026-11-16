# Validation checklist (read-only unless explicitly labeled)

## Static checks (conducted for packaged scripts)
- `bash -n` for all shell scripts.
- Files contain no live credentials; configuration samples use `<ENTER_...>` placeholders.
- `.gitignore` excludes populated env, private key files, admin-openrc.

## Runtime checks (NOT executed on a fresh build)
1. On Controller: `openstack token issue`, `openstack service list`, `openstack endpoint list`.
2. On Controller: `openstack compute service list`, `openstack hypervisor list`, `openstack network agent list`, `openstack volume service list`.
3. Network: `openstack network show provider`, `openstack subnet show provider-subnet`; verify flat mapping, gateway reachability, DHCP range and no other pool conflicts.
4. On Compute: `systemctl is-active nova-compute neutron-linuxbridge-agent libvirtd`, `chronyc sources -v`, `sudo crudini --get /etc/nova/nova-compute.conf libvirt virt_type`.
5. On Storage: `systemctl is-active cinder-volume tgt`, `sudo vgs --readonly`, `sudo lvs --readonly -a`, `sudo ss -lnt | grep 3260`.
6. **Mutation test only on disposable resources:** create an image/flavor/test VM, boot and verify networking, attach a newly created Cinder volume, verify guest disk and I/O, detach and delete. Do not run this in the production capstone lab without approval.

Known omissions: original Controller gateway/NAT specifics, original Cloud Notification log collection, exact fresh-install success, password rotation/TLS/firewall hardening, any full E2E test.
