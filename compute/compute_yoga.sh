#!/usr/bin/env bash
# Reconstructed from com root shell/Apt evidence + current settings; NOT fresh-host validated.
# Strictly phased execution on a new disposable Ubuntu 22.04 host ONLY.
set -Eeuo pipefail
umask 077
PHASE=${1:-all}
CFG=${CFG:-"$HOME/compute_yoga.env"}
[[ -r "$CFG" ]] || { echo "Missing env: $CFG" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CFG"
: "${CONTROLLER_IP:?}" "${COMPUTE_IP:?}" "${MGMT_IF:?}" "${PROVIDER_IF:?}" "${PHYSICAL_NETWORK:?}" "${RABBIT_USER:?}" "${REGION:?}"
log(){ printf '\n==== %s ====\n' "$*"; }
all_services_active(){ local s; for s in "$@"; do systemctl is-active --quiet "$s" || return 1; done; }
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
  log 'BASE packages and clock'; sudo apt-get -o DPkg::Lock::Timeout=600 update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y chrony nova-compute neutron-linuxbridge-agent crudini
  echo 'Set NTP server to Controller (replace existing default pool entries after inspection).'
  sudo cp -a /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.pre-yoga.$(date +%s)"
  # Only replace the selected pool/server directives. Check existing file before running this phase.
  sudo sed -i -E '/^[[:space:]]*(pool|server)[[:space:]]/s/^/# Replaced for lab: /' /etc/chrony/chrony.conf
  if ! sudo grep -Eq "^[[:space:]]*server[[:space:]]+${CONTROLLER_IP//./\.}[[:space:]]+iburst([[:space:]]|$)" /etc/chrony/chrony.conf; then printf 'server %s iburst\n' "$CONTROLLER_IP" | sudo tee -a /etc/chrony/chrony.conf >/dev/null; fi
  sudo systemctl enable --now chrony
  sudo systemctl restart chrony
  chronyc sources -v || true
}
phase_nova(){
  log 'NOVA compute configuration'; local C=/etc/nova/nova.conf D=/etc/nova/nova-compute.conf
  if ! sudo test -e "$C.pre-yoga.initial"; then sudo cp -a "$C" "$C.pre-yoga.initial"; fi
  if sudo test -f "$D" && ! sudo test -e "$D.pre-yoga.initial"; then sudo cp -a "$D" "$D.pre-yoga.initial"; fi
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
  ini "$C" oslo_messaging_notifications driver messagingv2
  ini "$C" oslo_messaging_notifications topics notifications
  ini "$C" oslo_concurrency lock_path /var/lib/nova/tmp
  ini "$D" libvirt virt_type kvm
  sudo systemctl enable --now libvirtd nova-compute
  sudo systemctl restart nova-compute
}
phase_neutron(){
  log 'NEUTRON provider/flat Linux Bridge'; local N=/etc/neutron/neutron.conf L=/etc/neutron/plugins/ml2/linuxbridge_agent.ini
  for f in "$N" "$L"; do if ! sudo test -e "$f.pre-yoga.initial"; then sudo cp -a "$f" "$f.pre-yoga.initial"; fi; done
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
phase_notifications(){
 log 'NOTIFICATIONS: Nova Compute -> RabbitMQ'
 local C=/etc/nova/nova.conf
 [[ -f "$C" ]] || { echo "Missing $C; configure Nova first" >&2; return 1; }
 if ! sudo test -e "$C.pre-yoga.initial"; then sudo cp -a "$C" "$C.pre-yoga.initial"; fi
 ini "$C" oslo_messaging_notifications driver messagingv2
 ini "$C" oslo_messaging_notifications topics notifications
 sudo systemctl restart nova-compute
 systemctl is-active --quiet nova-compute
}
notify_config_matches(){
 local f=$1 driver topics
 driver=$(sudo crudini --get "$f" oslo_messaging_notifications driver 2>/dev/null) || return 1
 topics=$(sudo crudini --get "$f" oslo_messaging_notifications topics 2>/dev/null) || return 1
 [[ "$driver" == messagingv2 && ",${topics// /}," == *,notifications,* ]]
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
# Resume support: completed stages checked before skipping. Do not use on operational nodes.
STATE_DIR=${STATE_DIR:-"$HOME/.local/state/openstack-yoga-compute"}
STEPS=(base nova neutron notifications)
CURRENT_STEP=''
trap 'rc=$?; echo "FAILED: ${CURRENT_STEP:-initialization} exit=$rc. Inspect logs before retry." >&2' ERR
check_step(){
 local step=$1
 case "$step" in
 base) systemctl is-active --quiet chrony &&
       [[ "$(dpkg-query -W -f='${Status}' nova-compute 2>/dev/null)" == 'install ok installed' ]] &&
       [[ "$(dpkg-query -W -f='${Status}' neutron-linuxbridge-agent 2>/dev/null)" == 'install ok installed' ]];;
 nova) all_services_active nova-compute libvirtd && [[ $(sudo crudini --get /etc/nova/nova-compute.conf libvirt virt_type) == kvm ]];;
 neutron) systemctl is-active --quiet neutron-linuxbridge-agent && [[ $(sudo crudini --get /etc/neutron/plugins/ml2/linuxbridge_agent.ini linux_bridge physical_interface_mappings) == "${PHYSICAL_NETWORK}:${PROVIDER_IF}" ]];;
 notifications) systemctl is-active --quiet nova-compute && notify_config_matches /etc/nova/nova.conf;;
 *) return 2;;
 esac
}
step_run(){
 local step=$1 marker="$STATE_DIR/$1.done"
 CURRENT_STEP=$step
 if [[ -f $marker ]]; then
   if check_step "$step"; then echo "SKIP: $step (state + health verified)"; CURRENT_STEP=''; return 0; fi
   echo "STOP: $step marked complete, but service health is not valid; repair manually." >&2
   return 1
 fi
 echo "START: $step"
 "phase_$step"
 if ! check_step "$step"; then echo "POSTCHECK FAILED: $step" >&2; return 1; fi
 printf 'completed_at_utc=%s\n' "$(date -u +%FT%TZ)" > "$marker"
 CURRENT_STEP=''
 echo "DONE: $step"
}
case "$PHASE" in
 all)
   require_fresh; require_credentials; preflight
   mkdir -p "$STATE_DIR"
   for step in "${STEPS[@]}"; do step_run "$step"; done
   phase_verify
   echo 'COMPLETED; controller integration / VM and volume functionality still require validation.';;
 preflight) preflight;;
 lvm-check) phase_lvm_check;;
 base|nova|neutron|notifications)
   require_fresh; require_credentials; preflight; mkdir -p "$STATE_DIR"
   if [[ -f "$STATE_DIR/$PHASE.done" ]]; then
     if check_step "$PHASE"; then echo "ALREADY HEALTHY: $PHASE"; else echo "Marker exists, failed health check" >&2; exit 1; fi
   else step_run "$PHASE"; fi;;
 verify) phase_verify;;
 help|-h|--help) echo "Usage: bash compute_yoga.sh [all|preflight|base|nova|neutron|notifications|verify]";;
 *) echo "Unknown phase: $PHASE" >&2; exit 2;;
esac
