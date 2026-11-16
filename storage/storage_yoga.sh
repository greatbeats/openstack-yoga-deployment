#!/usr/bin/env bash
# Reconstructed from sto apt/root history and current Cinder/LVM/TGT configuration.
# No disk initialization, PV/VG/LV creation/deletion, or filesystem formatting.
# NOT freshly deployed / end-to-end tested.
set -Eeuo pipefail
umask 077
PHASE=${1:-help}
CFG=${CFG:-"$HOME/storage_yoga.env"}
[[ -r "$CFG" ]] || { echo "Missing env: $CFG" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CFG"
: "${CONTROLLER_IP:?}" "${STORAGE_IP:?}" "${MGMT_IF:?}" "${VOLUME_GROUP:?}" "${BACKEND_SECTION:?}" "${RABBIT_USER:?}"
log(){ printf '\n==== %s ====\n' "$*"; }
require_fresh(){ [[ ${CONFIRM_FRESH_HOST:-NO} == YES_FRESH_HOST ]] || { echo 'Fresh disposable lab host only' >&2; exit 3; }; }
require_credentials(){ local k v; for k in RABBIT_PASS CINDER_PASS CINDER_DB_PASS; do v=${!k:-}; [[ -n $v && $v != *'<'* && $v != *'>'* ]] || { echo "Replace $k placeholder" >&2; exit 3; }; done; }
ini(){ sudo crudini --set "$1" "$2" "$3" "$4"; }
preflight(){
  log 'PRE-FLIGHT (read-only)';
  [[ $(. /etc/os-release; echo "$VERSION_ID") == 22.04 ]] || { echo 'Ubuntu 22.04 required' >&2; exit 3; }
  hostnamectl --static; ip -br addr; ip route; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
  ip -4 -o addr show "$MGMT_IF" | grep -Fq " ${STORAGE_IP}/" || { echo 'Storage management IP not found' >&2; exit 3; }
  echo "VG required: $VOLUME_GROUP. Do not erase or re-create an OS PV/VG."
  if command -v vgs >/dev/null; then sudo vgs --readonly -o vg_name,vg_size,vg_free; fi
  apt-cache policy cinder-volume tgt lvm2 | head -35
}
phase_base(){
  log 'BASE packages and clock'; sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y chrony lvm2 thin-provisioning-tools cinder-volume tgt crudini
  sudo cp -a /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.pre-yoga.$(date +%s)"
  sudo sed -i -E '/^[[:space:]]*(pool|server)[[:space:]]/s/^/# Replaced for lab: /' /etc/chrony/chrony.conf
  printf 'server %s iburst\n' "$CONTROLLER_IP" | sudo tee -a /etc/chrony/chrony.conf >/dev/null
  sudo systemctl enable --now chrony; sudo systemctl restart chrony
  chronyc sources -v || true
}
phase_lvm_check(){
  log 'READ-ONLY LVM check';
  sudo pvs --readonly -o pv_name,vg_name,pv_size,pv_free
  sudo vgs --readonly -o vg_name,vg_size,vg_free
  sudo lvs --readonly -a -o vg_name,lv_name,lv_size,segtype,data_percent,metadata_percent
  sudo vgs --readonly --noheadings -o vg_name | awk '{print $1}' | grep -Fxq "$VOLUME_GROUP" || { echo "VG $VOLUME_GROUP not present, prepare OS/LVM separately" >&2; exit 3; }
  echo 'OS and Cinder shared ubuntu-vg in original deployment; this script will NOT alter LVM devices.'
}
phase_cinder(){
  log 'CINDER storage configuration';
  phase_lvm_check
  local C=/etc/cinder/cinder.conf
  sudo cp -a "$C" "$C.pre-yoga.$(date +%s)"
  ini "$C" DEFAULT my_ip "$STORAGE_IP"
  ini "$C" DEFAULT auth_strategy keystone
  ini "$C" DEFAULT enabled_backends "$BACKEND_SECTION"
  ini "$C" DEFAULT glance_api_servers "http://${CONTROLLER_IP}:9292"
  ini "$C" DEFAULT transport_url "rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
  ini "$C" database connection "mysql+pymysql://cinder:${CINDER_DB_PASS}@${CONTROLLER_IP}/cinder"
  ini "$C" keystone_authtoken www_authenticate_uri "http://${CONTROLLER_IP}:5000"
  ini "$C" keystone_authtoken auth_url "http://${CONTROLLER_IP}:5000"
  ini "$C" keystone_authtoken memcached_servers "${CONTROLLER_IP}:11211"
  ini "$C" keystone_authtoken auth_type password
  ini "$C" keystone_authtoken project_domain_name Default
  ini "$C" keystone_authtoken user_domain_name Default
  ini "$C" keystone_authtoken project_name service
  ini "$C" keystone_authtoken username cinder
  ini "$C" keystone_authtoken password "$CINDER_PASS"
  ini "$C" "$BACKEND_SECTION" volume_driver cinder.volume.drivers.lvm.LVMVolumeDriver
  ini "$C" "$BACKEND_SECTION" volume_group "$VOLUME_GROUP"
  # Do not set lvm_type; original file omitted it and runtime AUTO selected thin.
  ini "$C" "$BACKEND_SECTION" target_protocol iscsi
  ini "$C" "$BACKEND_SECTION" target_helper tgtadm
  ini "$C" oslo_concurrency lock_path /var/lib/cinder/tmp
  # Source environment uses /etc/lvm/lvm.conf allowlist for its OS PV, but
  # deliberately DO NOT overwrite the LVM filter; it could hide root filesystem.
  printf '%s\n' 'include /var/lib/cinder/volumes/*' | sudo tee /etc/tgt/conf.d/cinder.conf >/dev/null
  sudo systemctl enable --now tgt cinder-volume
  sudo systemctl restart tgt cinder-volume
}
phase_verify(){
  log 'READ-ONLY checks';
  for s in chrony tgt cinder-volume; do printf '%-25s %s\n' "$s" "$(systemctl is-active "$s" || true)"; done
  sudo vgs --readonly -o vg_name,vg_size,vg_free
  sudo lvs --readonly -a -o vg_name,lv_name,lv_size,segtype,data_percent,metadata_percent
  sudo ss -lnt | grep -E ':3260\b' || true
  sudo crudini --get /etc/cinder/cinder.conf DEFAULT enabled_backends
  sudo crudini --get /etc/cinder/cinder.conf "$BACKEND_SECTION" volume_group
  echo 'On Controller: openstack volume service list (expect sto@lvm enabled/up).'
  echo 'Volume create/attach/detach is NOT tested by this script.'
}
case "$PHASE" in
 preflight) preflight;;
 lvm-check) phase_lvm_check;;
 base|cinder) require_fresh; require_credentials; preflight; "phase_$PHASE";;
 verify) phase_verify;;
 *) echo 'Usage: bash storage_yoga.sh {preflight|base|lvm-check|cinder|verify}';;
esac
