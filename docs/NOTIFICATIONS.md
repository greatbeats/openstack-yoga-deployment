# OpenStack Yoga Notification → RabbitMQ → Agent 연결 (2026-11-17)

**Status: changes reconstructed from 2026-11-16 attack scenario findings; not redeployed or tested on fresh Ubuntu.**

This repository handles **OpenStack-side emission** and optional **RabbitMQ queue binding**, NOT the Agent consumer, Neo4j, ontology mapping, or `record_writer.py`. Do not claim end-to-end AI threat detection based only on AMQP delivery.

## 1. Why this was added

In the capstone scenario tests Keystone messages were collected but Nova instance and Cinder volume/snapshot messages were initially missing. The reported follow-up test observed **12 Nova instance messages**, and **12 Cinder messages spanning 8 event types**, after messaging/binding repairs. These are historical test observations, not results produced by the scripts in this repository.

## 2. Emission settings (automatically applied during installation)

All relevant configuration uses the same topic name on RabbitMQ (vhost `/` in the observed environment). The notification transport defaults to the normal RabbitMQ `transport_url` if `oslo_messaging_notifications.transport_url` is not set. This repository does not introduce a second message broker.

| Node | Config | Notification section | Restarted services |
|---|---|---|---|
| Controller | `/etc/nova/nova.conf` | `driver=messagingv2`, `topics=notifications` | `nova-api`, `nova-conductor`, `nova-scheduler` |
| Controller | `/etc/cinder/cinder.conf` | same | `cinder-scheduler`; `apache2` for applicable API configuration |
| Compute | `/etc/nova/nova.conf` | same | `nova-compute` |
| Storage | `/etc/cinder/cinder.conf` | same | `cinder-volume` |

In the 2026-11-17 revision, the Controller's Nova/Cinder phases also write the notification section. New final additive `notifications` stages are important for installations that completed the original stages with older scripts. The scripts back up the configuration before initial edits; they do not reset DBs or re-create completed Keystone endpoints.

Reference: [Nova Yoga sample configuration](https://docs.openstack.org/nova/yoga/configuration/sample-config.html) and [Nova notification format](https://docs.openstack.org/nova/yoga/reference/notifications.html).

## 3. Optional Agent queue binding (Controller only)

Binding is **off by default** to avoid touching an Agent-managed queue without confirming its exchange, vhost and consumer. This is not needed to install OpenStack itself.

On the disposable **Controller** VM first inspect the existing broker; these commands do not consume or clear messages:

```bash
sudo rabbitmqctl list_exchanges -p / name type
sudo rabbitmqctl list_queues -p / name messages consumers
sudo rabbitmqctl list_bindings -p / source_name destination_name destination_kind routing_key
```

After checking the exchange, vhost and queue used by the actual Agent, set the **private** `~/controller_yoga.env`:

```ini
ENABLE_NOTIFICATION_QUEUE_BINDING=YES
NOTIFY_VHOST=/
NOTIFY_EXCHANGE=openstack
NOTIFY_QUEUE=cto.openstack.notifications
NOTIFY_ROUTING_KEYS=notifications.info
```

The above routing key is based on the earlier tested configuration; **verify exchange type and actual routing key before enabling**. Additional priorities can be comma-separated only when actually present in the broker, e.g. `notifications.info,notifications.error`. Avoid using a wildcard that would collect unrelated RPC traffic. Existing queue arguments, type and durability will **not** be changed. If the queue does not exist, the optional script creates a **durable** queue. It never purges, deletes or consumes queue messages, and will refuse to create a missing `openstack` exchange.

Then, on a **new lab Controller** only:

```bash
cd ~/openstack-yoga-deployment/controller
bash controller_yoga.sh notification_bind
```

Or simply `bash controller_yoga.sh` on a fresh/resumable lab; with opt-in enabled it will run this new optional step after all required steps. The binding helper requires `python3-pika` (the opt-in phase installs this package), and uses the Controller's private RabbitMQ credentials without passing them as visible command-line arguments.

If the `openstack` exchange is not present, the script fails safely with a diagnostic. Do not invent a new exchange; first start and verify the actual Nova/Cinder notification publishers and inspect broker topology.

## 4. Additive upgrade / resume

On a partially deployed **disposable lab** with old `.done` markers, back up the existing scripts and private env, then apply the new code. The extra stage runs even if older phase markers are already complete:

```bash
# Controller (no need to repeat database or identity creation)
cd ~/openstack-yoga-deployment/controller
bash controller_yoga.sh notifications

# Compute, separately on the Compute host
cd ~/openstack-yoga-deployment/compute
bash compute_yoga.sh notifications

# Storage, separately on the Storage host
cd ~/openstack-yoga-deployment/storage
bash storage_yoga.sh notifications
```

These commands **modify configurations and restart services**. Use only on fresh disposable lab hosts, **never** on the live capstone Controller/Compute/Storage without a separately approved operational change window. After manual Notification stage(s), `bash *_yoga.sh` will skip completed stages whose health checks pass. The new `.done` marker is placed in the respective pre-existing state directory.

## 5. Read-only verification

On each corresponding lab node, verify only permitted fields (do not display `transport_url`, passwords, token values, or DB URL):

```bash
# Controller/Compute Nova
sudo crudini --get /etc/nova/nova.conf oslo_messaging_notifications driver
sudo crudini --get /etc/nova/nova.conf oslo_messaging_notifications topics

# Controller/Storage Cinder
sudo crudini --get /etc/cinder/cinder.conf oslo_messaging_notifications driver
sudo crudini --get /etc/cinder/cinder.conf oslo_messaging_notifications topics
```

Expect `messagingv2` and `notifications`. On Controller check bindings with `rabbitmqctl list_bindings`, then observe **fresh test actions** from the appropriate node. Check Agent consumer behavior, source JSONL, ingestion/storage and ontology mapping separately. An empty queue is **not** proof of no events because an active consumer may acknowledge them immediately.

## 6. Not included

The actual `Agent` installation, `live_notification_consumer.py`, `record_writer.py`, `ObservedEvent` mapping and alert/incident logic are **not in this repository**. The original scenario reported Cinder `bc=None` mapping and a later Agent-side write fix, but no Agent code has been incorporated here. A clean end-to-end deployment must bring that code from its own reviewed source and validate it separately.

Avoid uploading real host credentials, RPC URLs with passwords, SSH keys, AMQP dumps, event payloads with personal data or full Cinder/Nova logs to a public repository.
