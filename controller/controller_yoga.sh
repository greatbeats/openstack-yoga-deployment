#!/usr/bin/env bash
# Ubuntu 22.04 + OpenStack Yoga package installation; clean lab host ONLY.
# Evidence: Controller_OpenStack_Original_Commands.md (September 23 and 28, 2026)
# Not tested end-to-end on a clean host; unattended staged installer for disposable LAB VMs.
set -Eeuo pipefail
umask 077
PHASE=${1:-all}
CFG=${CFG:-"$HOME/controller_yoga.env"}
[[ -f "$CFG" ]] || { echo "Missing $CFG. Copy env example and edit." >&2; exit 2; }
# shellcheck disable=SC1090
CONFIRM_FROM_CLI=${CONFIRM_FRESH_HOST-}
source "$CFG"
# An explicit environment override takes precedence over the sample config.
if [[ -n $CONFIRM_FROM_CLI ]]; then CONFIRM_FRESH_HOST=$CONFIRM_FROM_CLI; fi
: "${CONTROLLER_IP:?}" "${MGMT_IF:?}" "${PROVIDER_IF:?}" "${ADMIN_PASS:?}" "${DB_PASS:?}" "${RABBIT_PASS:?}" "${SERVICE_PASS:?}" "${METADATA_SECRET:?}"
K="http://${CONTROLLER_IP}:5000"
log(){ printf '\n\n==== %s ====\n' "$*"; }
all_services_active(){ local s; for s in "$@"; do systemctl is-active --quiet "$s" || return 1; done; }
need_clean(){ [[ ${CONFIRM_FRESH_HOST:-} == 'YES_FRESH_HOST' ]] || { echo 'Set CONFIRM_FRESH_HOST=YES_FRESH_HOST only on a fresh disposable lab controller.' >&2; exit 3; }; }
check_creds(){
  for v in ADMIN_PASS DB_PASS RABBIT_PASS SERVICE_PASS METADATA_SECRET; do
    x=${!v}
    [[ $x != *'<'* && $x != *'>'* && $x != *ENTER_* ]] || { echo "Replace placeholder for $v in $CFG before installation." >&2; exit 3; }
    [[ $x =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Invalid $v: must be nonempty and use only [a-zA-Z0-9_-] (any length)." >&2; exit 3; }
  done
}
preflight(){
  log 'Read-only preflight'; cat /etc/os-release | grep -E '^(NAME|VERSION_ID)='; [[ $(. /etc/os-release; echo "$VERSION_ID") == 22.04 ]] || { echo 'Requires Ubuntu 22.04'; exit 3; }
  ip -br addr; ip route; hostnamectl --static; ip link show "$MGMT_IF" >/dev/null; ip link show "$PROVIDER_IF" >/dev/null
  [[ $MGMT_IF != "$PROVIDER_IF" ]] || { echo 'Dedicated provider NIC required'; exit 3; }
  ip -4 -o addr show "$MGMT_IF" | grep -q " ${CONTROLLER_IP}/" || { echo 'Controller IP not configured on MGMT_IF'; exit 3; }
  echo 'Provider interface must be dedicated; verify its cable/VLAN, no management IP.'
  apt-cache policy keystone nova-api neutron-server placement-api cinder-api | sed -n '1,65p'
  echo 'Expected Yoga major package versions: Keystone 21, Nova 25, Neutron 20, Placement 7, Cinder 20.'
  echo 'Network must allow access to archives, DNS, NTP. Confirm release is Yoga (no cloud-archive:zed).'
}
backup(){ local target=$1; if [[ -f $target ]] && ! sudo test -e "$target.pre-yoga-rebuild.initial"; then sudo cp -a "$target" "$target.pre-yoga-rebuild.initial"; fi; }
ini(){ sudo crudini --set "$1" "$2" "$3" "$4"; }
db_create(){
 local name=$1
 sudo mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${name};
CREATE USER IF NOT EXISTS '${name}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${name}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${name}.* TO '${name}'@'localhost';
GRANT ALL PRIVILEGES ON ${name}.* TO '${name}'@'%';
FLUSH PRIVILEGES;
SQL
}
admin_env(){
 export OS_AUTH_URL="$K/v3" OS_PROJECT_DOMAIN_NAME=Default OS_USER_DOMAIN_NAME=Default
 export OS_PROJECT_NAME=admin OS_USERNAME=admin OS_PASSWORD="$ADMIN_PASS" OS_IDENTITY_API_VERSION=3 OS_IMAGE_API_VERSION=2
}
# Idempotent registration helpers: only create missing resources; refuse conflicting URLs.
service_user(){
 local n=$1
 if ! openstack user show --domain default "$n" >/dev/null 2>&1; then
   openstack user create --domain default --password "$SERVICE_PASS" "$n" >/dev/null
 fi
 # OpenStack role add is idempotent for an existing assignment.
 openstack role add --project service --user "$n" admin
}
service_register(){
 local kind=$1 n=$2 description=$3
 if openstack service show "$n" >/dev/null 2>&1; then
   local actual
   actual=$(openstack service show "$n" -f value -c type)
   [[ "$actual" == "$kind" ]] || { echo "Existing service $n type=$actual, expected=$kind" >&2; return 1; }
 else
   openstack service create --name "$n" --description "$description" "$kind" >/dev/null
 fi
}
endpoint(){
 local kind=$1 base=$2 i rows url count
 for i in public internal admin; do
   # Column format yields only URLs for matching service/type, region and interface.
   rows=$(openstack endpoint list --service "$kind" -f json)
   url=$(printf '%s' "$rows" | python3 -c 'import sys,json; a=json.load(sys.stdin); k=sys.argv[1]; r=[x.get("URL", "") for x in a if x.get("Interface")==k and x.get("Region")=="RegionOne"]; print("\n".join(r))' "$i")
   if [[ -z "$url" ]]; then
     openstack endpoint create --region RegionOne "$kind" "$i" "$base" >/dev/null
   elif [[ "$url" != "$base" ]]; then
     echo "Existing $kind/$i endpoint differs from requested URL; refuse duplicate: $url" >&2
     return 1
   fi
 done
}
# Bounded API readiness checks; avoid transient failures immediately after service restart.
wait_http(){
 local url=$1 attempts=${2:-45} n rc
 for ((n=1;n<=attempts;n++)); do
   if curl -fsS --max-time 4 -o /dev/null "$url"; then return 0; fi
   sleep 2
 done
 echo "API readiness timeout: $url" >&2
 return 1
}
wait_openstack(){
 local n
 for ((n=1;n<=30;n++)); do
   if "$@" >/dev/null 2>&1; then return 0; fi
   sleep 2
 done
 printf 'OpenStack command failed after readiness retries: %s\n' "$*" >&2
 return 1
}
auth_opts(){ local f=$1 n=$2
  ini "$f" keystone_authtoken www_authenticate_uri "$K"
  ini "$f" keystone_authtoken auth_url "$K"
  ini "$f" keystone_authtoken memcached_servers "${CONTROLLER_IP}:11211"
  ini "$f" keystone_authtoken auth_type password
  ini "$f" keystone_authtoken project_domain_name Default
  ini "$f" keystone_authtoken user_domain_name Default
  ini "$f" keystone_authtoken project_name service
  ini "$f" keystone_authtoken username "$n"
  ini "$f" keystone_authtoken password "$SERVICE_PASS"
}
phase_base(){
 log 'BASE: lab controller prerequisites'; sudo apt-get -o DPkg::Lock::Timeout=600 update
 sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y chrony mariadb-server python3-pymysql rabbitmq-server memcached python3-memcache python3-openstackclient crudini
 # Requires existing static IP on management NIC. MariaDB open only to controller management IP.
 sudo install -m 0644 /dev/null /etc/mysql/mariadb.conf.d/99-openstack.cnf
 sudo tee /etc/mysql/mariadb.conf.d/99-openstack.cnf >/dev/null <<EOF
[mysqld]
bind-address = ${CONTROLLER_IP}
default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF
 sudo systemctl enable --now chrony mariadb rabbitmq-server memcached
 sudo systemctl restart mariadb
 backup /etc/memcached.conf
 sudo sed -i -E "s/^-l .*/-l 127.0.0.1,${CONTROLLER_IP}/" /etc/memcached.conf
 sudo systemctl restart memcached
 if ! sudo rabbitmqctl list_users -q | awk '{print $1}' | grep -Fxq openstack; then
  sudo rabbitmqctl add_user openstack "$RABBIT_PASS"
 else
  echo 'RabbitMQ user openstack already exists; applying configured password on this fresh lab host.'
  sudo rabbitmqctl change_password openstack "$RABBIT_PASS"
 fi
 sudo rabbitmqctl set_permissions openstack '.*' '.*' '.*'
 sudo rabbitmqctl list_users
 sudo ss -lnt | grep -E ':(3306|5672|11211)\b'
}
phase_keystone(){
 log 'KEYSTONE'; db_create keystone
 sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y keystone
 local C=/etc/keystone/keystone.conf; backup "$C"
 ini "$C" database connection "mysql+pymysql://keystone:${DB_PASS}@${CONTROLLER_IP}/keystone"
 ini "$C" token provider fernet
 sudo -u keystone keystone-manage db_sync
 sudo keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
 sudo keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
 sudo keystone-manage bootstrap --bootstrap-password "$ADMIN_PASS" --bootstrap-admin-url "$K/v3" --bootstrap-internal-url "$K/v3" --bootstrap-public-url "$K/v3" --bootstrap-region-id RegionOne
 echo "ServerName ${CONTROLLER_IP}" | sudo tee /etc/apache2/conf-available/controller-servername.conf >/dev/null
 sudo a2enconf controller-servername >/dev/null
 sudo systemctl restart apache2
 admin_env
 install -m 0600 /dev/null "$HOME/admin-openrc"
 cat > "$HOME/admin-openrc" <<EOF
export OS_AUTH_URL=${K}/v3
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD='${ADMIN_PASS}'
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF
 chmod 600 "$HOME/admin-openrc"
 openstack token issue -f value -c expires
 if ! openstack project show service >/dev/null 2>&1; then openstack project create --domain default --description 'Service Project' service >/dev/null; fi
}
phase_glance(){
 log GLANCE; admin_env; db_create glance; service_user glance
 service_register image glance 'OpenStack Image'
 endpoint image "http://${CONTROLLER_IP}:9292"
 sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y glance
 local C=/etc/glance/glance-api.conf; backup "$C"
 ini "$C" database connection "mysql+pymysql://glance:${DB_PASS}@${CONTROLLER_IP}/glance"
 sudo crudini --del "$C" database backend 2>/dev/null || true
 auth_opts "$C" glance; ini "$C" paste_deploy flavor keystone
 ini "$C" DEFAULT enabled_backends 'fs:file'; ini "$C" glance_store default_backend fs
 ini "$C" fs filesystem_store_datadir /var/lib/glance/images/
 sudo install -d -o glance -g glance -m 0750 /var/lib/glance/images
 sudo -u glance glance-manage db_sync; sudo systemctl restart glance-api
 wait_http "http://${CONTROLLER_IP}:9292/"; wait_openstack openstack image list
}
phase_placement(){
 log PLACEMENT; admin_env; db_create placement; service_user placement
 service_register placement placement 'Placement API'
 endpoint placement "http://${CONTROLLER_IP}:8778"
 # The resource provider postcheck uses the OSC Placement plugin, not only the Placement API.
  sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y placement-api python3-osc-placement
 local C=/etc/placement/placement.conf; backup "$C"
 ini "$C" placement_database connection "mysql+pymysql://placement:${DB_PASS}@${CONTROLLER_IP}/placement"
 ini "$C" api auth_strategy keystone; auth_opts "$C" placement
 sudo -u placement placement-manage db sync; sudo systemctl restart apache2
 wait_http "http://${CONTROLLER_IP}:8778/"; sudo -u placement placement-status upgrade check
}
phase_nova(){
 log NOVA; admin_env
 # Nova uses three schemas but ONE database account (nova).
 # Do not create nova_api or nova_cell0 as independent DB users.
 sudo mysql <<SQL
CREATE DATABASE IF NOT EXISTS nova_api;
CREATE DATABASE IF NOT EXISTS nova;
CREATE DATABASE IF NOT EXISTS nova_cell0;
CREATE USER IF NOT EXISTS 'nova'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS 'nova'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%';
FLUSH PRIVILEGES;
SQL
 service_user nova
 service_register compute nova 'OpenStack Compute'
 endpoint compute "http://${CONTROLLER_IP}:8774/v2.1"
 sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y nova-api nova-conductor nova-novncproxy nova-scheduler
 local C=/etc/nova/nova.conf; backup "$C"
 ini "$C" DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
  ini "$C" DEFAULT my_ip "$CONTROLLER_IP"; ini "$C" DEFAULT enabled_apis osapi_compute,metadata; ini "$C" DEFAULT use_neutron true
  # Notification emission observed during 2026-11-16 instance scenario tests.
  ini "$C" oslo_messaging_notifications driver messagingv2
  ini "$C" oslo_messaging_notifications topics notifications
 ini "$C" api_database connection "mysql+pymysql://nova:${DB_PASS}@${CONTROLLER_IP}/nova_api"
 ini "$C" database connection "mysql+pymysql://nova:${DB_PASS}@${CONTROLLER_IP}/nova"
 ini "$C" api auth_strategy keystone; auth_opts "$C" nova
 ini "$C" service_user send_service_user_token true
 for k in project_domain_name user_domain_name project_name username password auth_type auth_url; do
  case "$k" in project_domain_name|user_domain_name) v=Default;; project_name) v=service;; username) v=nova;; password) v=$SERVICE_PASS;; auth_type) v=password;; auth_url) v="$K/v3";; esac
  ini "$C" service_user "$k" "$v"
 done
 for k in region_name project_domain_name user_domain_name project_name username password auth_type auth_url; do
  case "$k" in region_name) v=RegionOne;; project_domain_name|user_domain_name) v=Default;; project_name) v=service;; username) v=placement;; password) v=$SERVICE_PASS;; auth_type) v=password;; auth_url) v="$K/v3";; esac
  ini "$C" placement "$k" "$v"
 done
 ini "$C" vnc enabled true; ini "$C" vnc server_listen "$CONTROLLER_IP"; ini "$C" vnc server_proxyclient_address "$CONTROLLER_IP"
 ini "$C" vnc novncproxy_base_url "http://${CONTROLLER_IP}:6080/vnc_auto.html"
 ini "$C" glance api_servers "http://${CONTROLLER_IP}:9292"
 ini "$C" oslo_concurrency lock_path /var/lib/nova/tmp
 sudo crudini --del "$C" DEFAULT log_dir 2>/dev/null || true
 sudo -u nova nova-manage api_db sync
 if ! sudo -u nova nova-manage cell_v2 list_cells --verbose 2>/dev/null | grep -Eq '(^|[[:space:]|])cell0([[:space:]|]|$)'; then
   sudo -u nova nova-manage cell_v2 map_cell0
 fi
 if ! sudo -u nova nova-manage cell_v2 list_cells --verbose 2>/dev/null | grep -Eq '(^|[[:space:]|])cell1([[:space:]|]|$)'; then
   sudo -u nova nova-manage cell_v2 create_cell --name=cell1 --verbose
 fi
 sudo -u nova nova-manage db sync
 sudo systemctl restart nova-api nova-scheduler nova-conductor nova-novncproxy
 sudo -u nova nova-manage cell_v2 list_cells
}
phase_neutron(){
 log NEUTRON; admin_env; db_create neutron; service_user neutron
 service_register network neutron 'OpenStack Networking'
 endpoint network "http://${CONTROLLER_IP}:9696"
 sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y neutron-server neutron-plugin-ml2 neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent
 local D=/etc/neutron C=/etc/neutron/neutron.conf M=/etc/neutron/plugins/ml2/ml2_conf.ini L=/etc/neutron/plugins/ml2/linuxbridge_agent.ini H=/etc/neutron/dhcp_agent.ini T=/etc/neutron/metadata_agent.ini N=/etc/nova/nova.conf
 for f in "$C" "$M" "$L" "$H" "$T" "$N"; do backup "$f"; done
 ini "$C" database connection "mysql+pymysql://neutron:${DB_PASS}@${CONTROLLER_IP}/neutron"
 ini "$C" DEFAULT core_plugin ml2; ini "$C" DEFAULT service_plugins ''
 ini "$C" DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
 ini "$C" DEFAULT auth_strategy keystone
 ini "$C" DEFAULT notify_nova_on_port_status_changes true
 ini "$C" DEFAULT notify_nova_on_port_data_changes true
 auth_opts "$C" neutron
 ini "$C" nova auth_url "$K/v3"; ini "$C" nova auth_type password
 ini "$C" nova project_domain_name Default; ini "$C" nova user_domain_name Default
 ini "$C" nova region_name RegionOne; ini "$C" nova project_name service
 ini "$C" nova username nova; ini "$C" nova password "$SERVICE_PASS"
 ini "$C" oslo_concurrency lock_path /var/lib/neutron/tmp
 ini "$M" ml2 type_drivers flat,vlan; ini "$M" ml2 tenant_network_types ''
 ini "$M" ml2 mechanism_drivers linuxbridge; ini "$M" ml2 extension_drivers port_security
 ini "$M" ml2_type_flat flat_networks provider; ini "$M" securitygroup enable_ipset true
 ini "$L" linux_bridge physical_interface_mappings "provider:${PROVIDER_IF}"
 ini "$L" vxlan enable_vxlan false; ini "$L" securitygroup enable_security_group true
 ini "$L" securitygroup firewall_driver neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
 ini "$H" DEFAULT interface_driver linuxbridge; ini "$H" DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
 ini "$H" DEFAULT enable_isolated_metadata true
 ini "$T" DEFAULT nova_metadata_host "$CONTROLLER_IP"; ini "$T" DEFAULT metadata_proxy_shared_secret "$METADATA_SECRET"
 ini "$N" neutron auth_url "$K/v3"; ini "$N" neutron auth_type password
 ini "$N" neutron project_domain_name Default; ini "$N" neutron user_domain_name Default
 ini "$N" neutron region_name RegionOne; ini "$N" neutron project_name service
 ini "$N" neutron username neutron; ini "$N" neutron password "$SERVICE_PASS"
 ini "$N" neutron service_metadata_proxy true; ini "$N" neutron metadata_proxy_shared_secret "$METADATA_SECRET"
 echo br_netfilter | sudo tee /etc/modules-load.d/br_netfilter.conf >/dev/null
 sudo modprobe br_netfilter
 printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\n' | sudo tee /etc/sysctl.d/99-neutron-bridge.conf >/dev/null
 sudo sysctl -p /etc/sysctl.d/99-neutron-bridge.conf
 sudo -u neutron neutron-db-manage --config-file "$C" --config-file "$M" upgrade head
 sudo systemctl restart nova-api nova-conductor nova-scheduler neutron-server neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent
 wait_openstack openstack network agent list
}
phase_horizon(){
 log HORIZON; sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y openstack-dashboard
 local C=/etc/openstack-dashboard/local_settings.py; backup "$C"
 # Targeted edits rather than replacing distro file; verify manually after.
 sudo env HORIZON_HOST="$CONTROLLER_IP" HORIZON_ALLOWED_HOST="$HORIZON_ALLOWED_HOST" python3 - "$C" <<'PY'
import os,re,sys
p=sys.argv[1]; s=open(p).read()
for key, val in {
 'OPENSTACK_HOST':repr(os.environ['HORIZON_HOST']),
 'OPENSTACK_KEYSTONE_URL':repr('http://'+os.environ['HORIZON_HOST']+':5000/v3'),
 'OPENSTACK_KEYSTONE_DEFAULT_DOMAIN':repr('Default'),
 'OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT':'False',
 'ALLOWED_HOSTS':repr([os.environ['HORIZON_ALLOWED_HOST'],'localhost','127.0.0.1']),
 'SESSION_ENGINE':repr('django.contrib.sessions.backends.cache'),
}.items():
 pat=r'(?m)^'+re.escape(key)+r'\s*=\s*[^\n]*$'
 if re.search(pat,s): s=re.sub(pat,lambda m:key+' = '+val,s,count=1)
 else: s+='\n'+key+' = '+val+'\n'
open(p,'w').write(s)
PY
 sudo systemctl restart apache2; wait_http "http://${CONTROLLER_IP}/horizon/"
}
phase_cinder(){
 log CINDER; admin_env; db_create cinder; service_user cinder
 service_register volumev3 cinderv3 'OpenStack Block Storage'
 endpoint volumev3 "http://${CONTROLLER_IP}:8776/v3/%(project_id)s"
 sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y cinder-api cinder-scheduler
 local C=/etc/cinder/cinder.conf N=/etc/nova/nova.conf; backup "$C"; backup "$N"
 ini "$C" DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_IP}:5672/"
 ini "$C" DEFAULT auth_strategy keystone; ini "$C" DEFAULT my_ip "$CONTROLLER_IP"
 ini "$C" database connection "mysql+pymysql://cinder:${DB_PASS}@${CONTROLLER_IP}/cinder"
 auth_opts "$C" cinder; ini "$C" oslo_concurrency lock_path /var/lib/cinder/tmp
 # Notification settings on Controller API/scheduler as well as the Storage node.
 ini "$C" oslo_messaging_notifications driver messagingv2
 ini "$C" oslo_messaging_notifications topics notifications
 ini "$N" cinder os_region_name RegionOne
 sudo -u cinder cinder-manage db sync
 sudo systemctl enable --now cinder-scheduler
 sudo systemctl restart nova-api cinder-scheduler apache2
 openstack volume service list
}
# Additive notification stage for installations that already finished nova/cinder.
# Existing completion markers are left intact. Read/write configuration only on fresh labs.
notify_config_matches(){
  local f=$1 driver topics
  driver=$(sudo crudini --get "$f" oslo_messaging_notifications driver 2>/dev/null) || return 1
  topics=$(sudo crudini --get "$f" oslo_messaging_notifications topics 2>/dev/null) || return 1
  [[ "$driver" == messagingv2 && ",${topics// /}," == *,notifications,* ]]
}
phase_notifications(){
 log 'NOTIFICATIONS: Controller Nova + Cinder'
 local n=/etc/nova/nova.conf c=/etc/cinder/cinder.conf
 for f in "$n" "$c"; do
   [[ -f "$f" ]] || { echo "Missing $f; complete its service phase first" >&2; return 1; }
   backup "$f"
   ini "$f" oslo_messaging_notifications driver messagingv2
   ini "$f" oslo_messaging_notifications topics notifications
 done
 sudo systemctl restart nova-api nova-conductor nova-scheduler cinder-scheduler apache2
 all_services_active nova-api nova-conductor nova-scheduler cinder-scheduler apache2
 echo 'Controller emission enabled. Compute/Storage must enable notifications separately.'
}
phase_notification_bind(){
 log 'NOTIFICATION QUEUE: opt-in Agent capture binding'
 [[ "${ENABLE_NOTIFICATION_QUEUE_BINDING:-NO}" == YES ]] || {
    echo 'Explicitly set ENABLE_NOTIFICATION_QUEUE_BINDING=YES only after confirming exchange, queue and Agent consumer.' >&2; return 3;
 }
 sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y python3-pika
 local script_dir
 script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 CONTROLLER_IP="$CONTROLLER_IP" RABBIT_USER=openstack RABBIT_PASS="$RABBIT_PASS" \
 NOTIFY_VHOST="${NOTIFY_VHOST:-/}" NOTIFY_EXCHANGE="${NOTIFY_EXCHANGE:-openstack}" \
 NOTIFY_QUEUE="${NOTIFY_QUEUE:-cto.openstack.notifications}" \
 NOTIFY_ROUTING_KEYS="${NOTIFY_ROUTING_KEYS:-notifications.info}" \
 python3 "$script_dir/notification_queue.py" apply
}
notification_bind_check(){
 local script_dir
 script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 NOTIFY_VHOST="${NOTIFY_VHOST:-/}" NOTIFY_EXCHANGE="${NOTIFY_EXCHANGE:-openstack}" \
 NOTIFY_QUEUE="${NOTIFY_QUEUE:-cto.openstack.notifications}" \
 NOTIFY_ROUTING_KEYS="${NOTIFY_ROUTING_KEYS:-notifications.info}" \
 python3 "$script_dir/notification_queue.py" check >/dev/null
}
phase_provider(){
 log PROVIDER; admin_env
 [[ ${CONFIRM_PROVIDER_PHYSICAL_NET:-} == 'YES' ]] || { echo 'Review provider NIC/cabling/VLAN and set CONFIRM_PROVIDER_PHYSICAL_NET=YES' >&2; exit 3; }
 if openstack network show provider >/dev/null 2>&1; then
   local type phys
   type=$(openstack network show provider -f value -c provider:network_type)
   phys=$(openstack network show provider -f value -c provider:physical_network)
   [[ "$type" == flat && "$phys" == provider ]] || { echo 'Existing provider network is not flat/provider; refusing overwrite' >&2; return 1; }
 else
   openstack network create --share --external --provider-physical-network provider --provider-network-type flat provider
 fi
 if openstack subnet show provider-subnet >/dev/null 2>&1; then
   local cidr gateway
   cidr=$(openstack subnet show provider-subnet -f value -c cidr)
   gateway=$(openstack subnet show provider-subnet -f value -c gateway_ip)
   [[ "$cidr" == "$PROVIDER_CIDR" && "$gateway" == "$PROVIDER_GATEWAY" ]] || { echo 'Existing subnet differs from configured CIDR/gateway; refusing overwrite' >&2; return 1; }
 else
   openstack subnet create --network provider --subnet-range "${PROVIDER_CIDR}" --gateway "${PROVIDER_GATEWAY}" --dns-nameserver "${PROVIDER_DNS}" --allocation-pool "start=${PROVIDER_POOL_START},end=${PROVIDER_POOL_END}" provider-subnet
 fi
 openstack network show provider; openstack subnet show provider-subnet
 echo 'ATTENTION: gateway address must exist on the physically attached external network or be supplied by a separately configured lab gateway/NAT.'
}
phase_verify(){
 log VERIFY; admin_env
 for s in mariadb rabbitmq-server memcached apache2 glance-api nova-api nova-conductor nova-scheduler nova-novncproxy neutron-server neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent cinder-scheduler; do printf '%-30s %s\n' "$s" "$(systemctl is-active "$s" || true)"; done
 openstack token issue -f value -c expires
 openstack service list; openstack endpoint list; openstack compute service list; openstack network agent list; openstack volume service list
 sudo -u nova nova-status upgrade check; wait_http "http://${CONTROLLER_IP}:8778/"; sudo -u placement placement-status upgrade check
 echo 'Controller only: no nova-compute hypervisor / cinder-volume is expected until com/sto are deployed.'
}
# Resumable phased installer. A marker is accepted only when a read-only health check passes.
# Non-successful phases are retried; registration/database helpers avoid duplicating objects.
STATE_DIR=${STATE_DIR:-"$HOME/.local/state/openstack-yoga-controller"}
INSTALL_STEPS=(base keystone glance placement nova neutron horizon cinder notifications provider)
CURRENT_STEP=''
on_error(){
  local rc=$?
  echo >&2
  echo "FAILED: step=${CURRENT_STEP:-initialization} exit=$rc" >&2
  echo 'Do NOT delete DBs or reset state blindly; inspect the failed service and retry after correction.' >&2
  exit "$rc"
}
trap on_error ERR

# Called with configured credentials in this process; never print passwords or tokens.
check_step(){
 local step=$1
 case "$step" in
 base) all_services_active mariadb rabbitmq-server memcached chrony && sudo mysql -Nse 'SELECT 1' >/dev/null;;
 keystone) systemctl is-active --quiet apache2 && admin_env && openstack token issue -f value -c expires >/dev/null 2>&1 && openstack project show service >/dev/null 2>&1;;
 glance) systemctl is-active --quiet glance-api && wait_http "http://${CONTROLLER_IP}:9292/" 4 && admin_env && openstack image list >/dev/null 2>&1;;
 placement) systemctl is-active --quiet apache2 && wait_http "http://${CONTROLLER_IP}:8778/" 4 && admin_env && openstack resource provider list >/dev/null 2>&1;;
 nova) all_services_active nova-api nova-conductor nova-scheduler nova-novncproxy && admin_env && openstack compute service list >/dev/null 2>&1 && sudo -u nova nova-manage cell_v2 list_cells --verbose | grep -q cell1;;
 neutron) all_services_active neutron-server neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent && admin_env && openstack network agent list >/dev/null 2>&1;;
 horizon) systemctl is-active --quiet apache2 && wait_http "http://${CONTROLLER_IP}/horizon/" 4;;
 cinder) systemctl is-active --quiet cinder-scheduler && admin_env && openstack volume service list >/dev/null 2>&1;;
 notifications) all_services_active nova-api nova-conductor nova-scheduler cinder-scheduler apache2 && notify_config_matches /etc/nova/nova.conf && notify_config_matches /etc/cinder/cinder.conf;;
 notification_bind) [[ "${ENABLE_NOTIFICATION_QUEUE_BINDING:-NO}" == YES ]] && notification_bind_check;;
 provider) admin_env && openstack network show provider >/dev/null 2>&1 && openstack subnet show provider-subnet >/dev/null 2>&1;;
 *) echo "Unknown check step: $step" >&2; return 2;;
 esac
}
step_run(){
 local step=$1 marker="$STATE_DIR/$1.done"
 CURRENT_STEP=$step
 if [[ -f "$marker" ]]; then
   if check_step "$step"; then echo "SKIP: $step (marker + service health verified)"; CURRENT_STEP=''; return 0; fi
   echo "STOP: $step has a completion marker but health checks failed." >&2
   echo "Inspect service health; manual rerun only with explicit phase command after correcting the issue." >&2
   return 1
 fi
 echo "START: $step"
 "phase_${step}"
 # Check the actual functionality rather than only an exit code from the configuration script.
 if ! check_step "$step"; then
   echo "POSTCHECK FAILED: $step. Step was NOT marked complete." >&2
   return 1
 fi
 printf 'completed_at_utc=%s\n' "$(date -u +%FT%TZ)" > "$marker"
 CURRENT_STEP=''
 echo "DONE: $step"
}
install_all(){
 need_clean; check_creds; preflight
 [[ ${CONFIRM_PROVIDER_PHYSICAL_NET:-} == YES ]] || {
   echo 'Set CONFIRM_PROVIDER_PHYSICAL_NET=YES only after lab NIC and gateway are verified.' >&2; exit 3;
 }
 mkdir -p "$STATE_DIR"
 for step in "${INSTALL_STEPS[@]}"; do step_run "$step"; done
 if [[ "${ENABLE_NOTIFICATION_QUEUE_BINDING:-NO}" == YES ]]; then
   step_run notification_bind
 else
   echo 'SKIP: optional Agent notification queue binding (ENABLE_NOTIFICATION_QUEUE_BINDING=NO)'
 fi
 CURRENT_STEP=verify
 phase_verify
 CURRENT_STEP=''
 echo 'ALL CONTROLLER STEPS FINISHED; verify VM networking after deploying Compute and Storage.'
}
case "$PHASE" in
 all) install_all;;
 preflight) preflight;;
 base|keystone|glance|placement|nova|neutron|horizon|cinder|notifications|notification_bind|provider)
   need_clean; check_creds; preflight
   if [[ "$PHASE" == notification_bind && "${ENABLE_NOTIFICATION_QUEUE_BINDING:-NO}" != YES ]]; then
     echo 'Set ENABLE_NOTIFICATION_QUEUE_BINDING=YES only after verifying the existing Agent queue and exchange.' >&2; exit 3
   fi
   mkdir -p "$STATE_DIR"
   # Explicit phase supports repair; remove a stale marker for this phase only after user asks for a reconfiguration.
   if [[ -f "$STATE_DIR/$PHASE.done" ]]; then
      if check_step "$PHASE"; then echo "ALREADY HEALTHY: $PHASE"; exit 0; fi
      echo "Marker exists but $PHASE failed verification. Do not overwrite automatically." >&2; exit 1
   fi
   step_run "$PHASE";;
 verify) phase_verify;;
 help|-h|--help)
   echo 'Usage: bash controller_yoga.sh [all|preflight|base|keystone|glance|placement|nova|neutron|horizon|cinder|notifications|notification_bind|provider|verify]'
   echo 'No argument resumes unfinished phases. CFG defaults to ~/controller_yoga.env.';;
 *) echo "Unknown phase: $PHASE" >&2; exit 2;;
esac
