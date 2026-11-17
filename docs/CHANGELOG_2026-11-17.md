# 2026-11-17 change log (Notification collection)

Based on the team's 2026-11-16 OpenStack attack-scenario test discussion:

- **Controller:** set `[oslo_messaging_notifications]` to `driver=messagingv2` and `topics=notifications` for both Nova and Cinder; restart relevant API/scheduler processes. Add opt-in RabbitMQ binding helper that checks the existing exchange and queue before modifying bindings.
- **Compute:** set the same Nova notification options and restart `nova-compute` only in an approved lab environment.
- **Storage:** set the same Cinder options and restart `cinder-volume` only in an approved lab environment. Retain LVM/TGT settings and avoid any disk initialization.
- **Resume:** add a separate `notifications` step to each node, so an older completed `nova` or `cinder` step can stay marked complete and the missing notification settings can be added independently. Controller's optional `notification_bind` step is independently tracked and disabled unless explicitly enabled.
- **Safety:** ensure Compute/Storage `base` health checks require **all** expected packages rather than any one installed package; require active status of every listed systemd service, not merely one.
- **Documentation:** specify that RabbitMQ delivery alone does not prove Agent ingestion or Neo4j mapping; link separate tests and observed limitations.

**Verification performed:** Bash syntax checks, Python syntax checks, ZIP file integrity and offline simulated binding behavior. **Not performed:** actual OpenStack package installation, live RabbitMQ binding, VM/volume functional tests, or testing the modified Agent ingestion code.
