#!/usr/bin/env bash
# Reconstructed from sto apt/root history and current Cinder/LVM/TGT configuration.
# No disk initialization, PV/VG/LV creation/deletion, or filesystem formatting.
# NOT freshly deployed / end-to-end tested.
set -Eeuo pipefail
umask 077
PHASE=${1:-all}
CFG=${CFG:-"$HOME/storage_yoga.env"}
[[ -r "$CFG" ]] || { echo "Missing env: $CFG" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CFG"
: "${CONTROLLER_IP:?}" "${STORAGE_IP:?}" "${MGMT_IF:?}" "${VOLUME_GROUP:?}" "${BACKEND_SECTION:?}" "${RABBIT_USER:?}"
log(){ printf '\n==== %s ====\n' "$*"; }
all_services_active(){ local s; for s in "$@"; do systemctl is-active --quiet "$s" || return 1; done; }
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
  log 'BASE packages and clock'; sudo apt-get -o DPkg::Lock::Timeout=600 update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y chrony lvm2 thin-provisioning-tools cinder-volume tgt crudini
  sudo cp -a /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.pre-yoga.$(date +%s)"
  sudo sed -i -E '/^[[:space:]]*(pool|server)[[:space:]]/s/^/# Replaced for lab: /' /etc/chrony/chrony.conf
  if ! sudo grep -Eq "^[[:space:]]*server[[:space:]]+${CONTROLLER_IP//./\.}[[:space:]]+iburst([[:space:]]|$)" /etc/chrony/chrony.conf; then printf 'server %s iburst\n' "$CONTROLLER_IP" | sudo tee -a /etc/chrony/chrony.conf >/dev/null; fi
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
  if ! sudo test -e "$C.pre-yoga.initial"; then sudo cp -a "$C" "$C.pre-yoga.initial"; fi
  ini "$C" DEFAULT my_ip "$STORAGE_IP"
  ini "$C" DEFAULT auth_strategy keystone
  ini "$C" DEFAULT enabled_backends "$BACKEND_SECTION"
  ini "$C" oslo_messaging_notifications driver messagingv2
  ini "$C" oslo_messaging_notifications topics notifications
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
phase_notifications(){
 log 'NOTIFICATIONS: Cinder Volume -> RabbitMQ'
 local C=/etc/cinder/cinder.conf
 [[ -f "$C" ]] || { echo "Missing $C; configure Cinder first" >&2; return 1; }
 if ! sudo test -e "$C.pre-yoga.initial"; then sudo cp -a "$C" "$C.pre-yoga.initial"; fi
 ini "$C" oslo_messaging_notifications driver messagingv2
 ini "$C" oslo_messaging_notifications topics notifications
 sudo systemctl restart cinder-volume
 systemctl is-active --quiet cinder-volume
}
notify_config_matches(){
 local f=$1 driver topics
 driver=$(sudo crudini --get "$f" oslo_messaging_notifications driver 2>/dev/null) || return 1
 topics=$(sudo crudini --get "$f" oslo_messaging_notifications topics 2>/dev/null) || return 1
 [[ "$driver" == messagingv2 && ",${topics// /}," == *,notifications,* ]]
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
# Resume support: completed stages checked before skipping. Do not use on operational nodes.
STATE_DIR=${STATE_DIR:-"$HOME/.local/state/openstack-yoga-storage"}
STEPS=(base lvm_check cinder notifications)
CURRENT_STEP=''
trap 'rc=$?; echo "FAILED: ${CURRENT_STEP:-initialization} exit=$rc. Inspect logs before retry." >&2' ERR
check_step(){
 local step=$1
 case "$step" in
 base) systemctl is-active --quiet chrony &&
       [[ "$(dpkg-query -W -f='${Status}' cinder-volume 2>/dev/null)" == 'install ok installed' ]] &&
       [[ "$(dpkg-query -W -f='${Status}' tgt 2>/dev/null)" == 'install ok installed' ]];;
 lvm_check) sudo vgs --readonly --noheadings -o vg_name | awk '{print $1}' | grep -Fxq "$VOLUME_GROUP";;
 cinder) all_services_active tgt cinder-volume && [[ $(sudo crudini --get /etc/cinder/cinder.conf "$BACKEND_SECTION" volume_group) == "$VOLUME_GROUP" ]];;
 notifications) systemctl is-active --quiet cinder-volume && notify_config_matches /etc/cinder/cinder.conf;;
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
 base|cinder|notifications)
   require_fresh; require_credentials; preflight; mkdir -p "$STATE_DIR"
   if [[ -f "$STATE_DIR/$PHASE.done" ]]; then
     if check_step "$PHASE"; then echo "ALREADY HEALTHY: $PHASE"; else echo "Marker exists, failed health check" >&2; exit 1; fi
   else step_run "$PHASE"; fi;;
 verify) phase_verify;;
 help|-h|--help) echo "Usage: bash storage_yoga.sh [all|preflight|base|lvm-check|cinder|notifications|verify]";;
 *) echo "Unknown phase: $PHASE" >&2; exit 2;;
esac
