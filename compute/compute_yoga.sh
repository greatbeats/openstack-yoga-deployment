#!/usr/bin/env bash
# Reconstructed from com root shell/Apt evidence + current settings; NOT fresh-host validated.
# Strictly phased execution on a new disposable Ubuntu 22.04 host ONLY.
set -Eeuo pipefail
umask 077
PHASE=${1:-help}
CFG=${CFG:-"$HOME/compute_yoga.env"}
[[ -r "$CFG" ]] || { echo "Missing env: $CFG" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CFG"
: "${CONTROLLER_IP:?}" "${COMPUTE_IP:?}" "${MGMT_IF:?}" "${PROVIDER_IF:?}" "${PHYSICAL_NETWORK:?}" "${RABBIT_USER:?}" "${REGION:?}"
log(){ printf '\n==== %s ====\n' "$*"; }
require_fresh(){ [[ ${CONFIRM_FRESH_HOST:-NO} == YES_FRESH_HOST ]] || { echo 'Only on FRESH test host; set CONFIRM_FRESH_HOST=YES_FRESH_HOST' >&2; exit 3; }; }
require_credentials(){ local k v; for k in RABBIT_PASS NOVA_PASS NEUTRON_PASS PLACEMENT_PASS; do v=${!k:-}; [[ -n $v && $v != *'<'* && $v != *'>'* ]] || { echo "Replace $k placeholder" >&2; exit 3; }; done; }
ini(){ sudo crudini --set "$1" "$2" "$3" "$4"; }
preflight(){
  log 'PRE-FLIGHT (read-only)';
  [[ $(. /etc/os-release; echo "$VERSION_ID") == 22.04 ]] || { echo 'Ubuntu 22.04 required' >&2; exit 3; }
  hostnamectl --static; ip -br addr; ip route
  ip link show "$MGMT_IF" >/dev/null; ip link show "$PROVIDER_IF" >/dev/null
  [[ "$MGMT_IF" != "$PROVIDER_IF" ]] || { echo 'Management and provider NIC must differ' >&2; exit 3; }
  ip -4 -o addr show "$MGMT_IF" | grep -Fq " ${COMPUTE_IP}/" || { echo 'Compute management IP not found' >&2; exit 3; }
  lscpu | grep -Ei 'virtualization|vendor id' || true
  grep -Ecm1 '(vmx|svm)' /proc/cpuinfo || true
  echo "Provider NIC: $PROVIDER_IF (must be dedicated; mapping ${PHYSICAL_NETWORK}:${PROVIDER_IF})"
  apt-cache policy nova-compute neutron-linuxbridge-agent | head -25
}
phase_base(){
  log 'BASE packages and clock'; sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y chrony nova-compute neutron-linuxbridge-agent crudini
  echo 'Set NTP server to Controller (replace existing default pool entries after inspection).'
  sudo cp -a /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.pre-yoga.$(date +%s)"
  # Only replace the selected pool/server directives. Check existing file before running this phase.
  sudo sed -i -E '/^[[:space:]]*(pool|server)[[:space:]]/s/^/# Replaced for lab: /' /etc/chrony/chrony.conf
  printf 'server %s iburst\n' "$CONTROLLER_IP" | sudo tee -a /etc/chrony/chrony.conf >/dev/null
  sudo systemctl enable --now chrony
  sudo systemctl restart chrony
  chronyc sources -v || true
}
phase_nova(){
  log 'NOVA compute configuration'; local C=/etc/nova/nova.conf D=/etc/nova/nova-compute.conf
  sudo cp -a "$C" "$C.pre-yoga.$(date +%s)"
  [[ ! -f $D ]] || sudo cp -a "$D" "$D.pre-yoga.$(date +%s)"
  ini "$C" DEFAULT my_ip "$COMPUTE_IP"
  ini "$C" DEFAULT transport_url "rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
  ini "$C" api auth_strategy keystone
  for section in keystone_authtoken placement neutron; do
    ini "$C" "$section" auth_url "http://${CONTROLLER_IP}:5000/v3"
    ini "$C" "$section" auth_type password
    ini "$C" "$section" project_domain_name Default
    ini "$C" "$section" user_domain_name Default
    ini "$C" "$section" project_name service
    ini "$C" "$section" region_name "$REGION"
  done
  ini "$C" keystone_authtoken www_authenticate_uri "http://${CONTROLLER_IP}:5000/"
  ini "$C" keystone_authtoken memcached_servers "${CONTROLLER_IP}:11211"
  ini "$C" keystone_authtoken username nova; ini "$C" keystone_authtoken password "$NOVA_PASS"
  ini "$C" placement username placement; ini "$C" placement password "$PLACEMENT_PASS"
  ini "$C" neutron username neutron; ini "$C" neutron password "$NEUTRON_PASS"
  ini "$C" vnc enabled true; ini "$C" vnc server_listen 0.0.0.0
  ini "$C" vnc server_proxyclient_address "$COMPUTE_IP"
  ini "$C" vnc novncproxy_base_url "http://${CONTROLLER_IP}:6080/vnc_auto.html"
  ini "$C" glance api_servers "http://${CONTROLLER_IP}:9292"
  ini "$C" oslo_concurrency lock_path /var/lib/nova/tmp
  ini "$D" libvirt virt_type kvm
  sudo systemctl enable --now libvirtd nova-compute
  sudo systemctl restart nova-compute
}
phase_neutron(){
  log 'NEUTRON provider/flat Linux Bridge'; local N=/etc/neutron/neutron.conf L=/etc/neutron/plugins/ml2/linuxbridge_agent.ini
  for f in "$N" "$L"; do sudo cp -a "$f" "$f.pre-yoga.$(date +%s)"; done
  ini "$N" DEFAULT transport_url "rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
  ini "$N" DEFAULT auth_strategy keystone
  ini "$N" keystone_authtoken www_authenticate_uri "http://${CONTROLLER_IP}:5000/"
  ini "$N" keystone_authtoken auth_url "http://${CONTROLLER_IP}:5000/"
  ini "$N" keystone_authtoken memcached_servers "${CONTROLLER_IP}:11211"
  ini "$N" keystone_authtoken auth_type password
  ini "$N" keystone_authtoken project_domain_name Default
  ini "$N" keystone_authtoken user_domain_name Default
  ini "$N" keystone_authtoken project_name service
  ini "$N" keystone_authtoken username neutron
  ini "$N" keystone_authtoken password "$NEUTRON_PASS"
  ini "$N" oslo_concurrency lock_path /var/lib/neutron/tmp
  ini "$L" linux_bridge physical_interface_mappings "${PHYSICAL_NETWORK}:${PROVIDER_IF}"
  ini "$L" vxlan enable_vxlan false
  ini "$L" securitygroup enable_security_group true
  ini "$L" securitygroup firewall_driver neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
  echo br_netfilter | sudo tee /etc/modules-load.d/br_netfilter.conf >/dev/null
  sudo modprobe br_netfilter
  printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\n' | sudo tee /etc/sysctl.d/99-neutron-bridge.conf >/dev/null
  sudo sysctl -p /etc/sysctl.d/99-neutron-bridge.conf
  sudo systemctl enable --now neutron-linuxbridge-agent
  sudo systemctl restart neutron-linuxbridge-agent nova-compute
}
phase_verify(){
  log 'READ-ONLY service checks';
  for s in chrony libvirtd nova-compute neutron-linuxbridge-agent; do printf '%-28s %s\n' "$s" "$(systemctl is-active "$s" || true)"; done
  sudo crudini --get /etc/nova/nova-compute.conf libvirt virt_type
  sudo crudini --get /etc/neutron/plugins/ml2/linuxbridge_agent.ini linux_bridge physical_interface_mappings
  sudo crudini --get /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan enable_vxlan
  chronyc sources -v; ip -br addr
  echo 'Run Controller validation: openstack compute service list; openstack network agent list; openstack hypervisor list.'
  echo 'Controller must also discover compute host with nova-manage cell_v2 discover_hosts when required.'
}
case "$PHASE" in
 preflight) preflight;;
 base|nova|neutron) require_fresh; require_credentials; preflight; "phase_$PHASE";;
 verify) phase_verify;;
 *) echo 'Usage: bash compute_yoga.sh {preflight|base|nova|neutron|verify}';;
esac
