#!/usr/bin/env python3
"""Safely verify or (explicitly) add Agent notification queue AMQP bindings.

No queue purge/deletion, message consumption, exchange creation, or RabbitMQ
management API. The existing queue is reused without changing its properties.
Only intended for a disposable lab Controller with RabbitMQ 3.9+ and Pika.
"""
import os
import re
import subprocess
import sys


def settings():
    vhost = os.environ.get('NOTIFY_VHOST', '/')
    exchange = os.environ.get('NOTIFY_EXCHANGE', 'openstack')
    queue = os.environ.get('NOTIFY_QUEUE', 'cto.openstack.notifications')
    keys = [s.strip() for s in os.environ.get('NOTIFY_ROUTING_KEYS', 'notifications.info').split(',')]
    for title, val in [('exchange', exchange), ('queue', queue), *[(f'key {i}', x) for i, x in enumerate(keys)]]:
        if not val or not re.fullmatch(r'[A-Za-z0-9_.:-]+', val):
            raise ValueError(f'Invalid {title}: expected nonempty letters/digits/._:-')
    if vhost != '/':
        raise ValueError('Only the observed RabbitMQ vhost "/" is supported; check deployment before changing.')
    return vhost, exchange, queue, list(dict.fromkeys(keys))


def rabbitctl(cmd, vhost, fields):
    result = subprocess.run(['sudo', 'rabbitmqctl', cmd, '-p', vhost, *fields],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, check=False, timeout=30)
    if result.returncode:
        raise RuntimeError(f'rabbitmqctl {cmd} failed (exit={result.returncode}); inspect RabbitMQ locally')
    return result.stdout


def rows(output, columns):
    result = []
    for line in output.splitlines():
        # rabbitmqctl emits tab-separated fields; ignore column headers and status lines.
        parts = line.split('\t')
        if len(parts) == columns:
            result.append(parts)
    return result


def verify(vhost, exchange, queue, keys):
    data = rabbitctl('list_bindings', vhost, ['source_name', 'destination_name', 'destination_kind', 'routing_key'])
    seen = set()
    for parts in rows(data, 4):
        src, dst, dst_kind, routing_key = [x.strip() for x in parts]
        if src == exchange and dst == queue and dst_kind == 'queue':
            seen.add(routing_key)
    missing = [k for k in keys if k not in seen]
    if missing:
        print(f'Missing binding(s) for {queue} <- {exchange}: {", ".join(missing)}', file=sys.stderr)
        return False
    print(f'OK bindings: {exchange} -> {queue} keys={",".join(keys)}')
    return True


def apply(vhost, exchange, queue, keys):
    # The producer must have declared the exchange; do NOT create or change it.
    info = rabbitctl('list_exchanges', vhost, ['name', 'type'])
    known = {r[0].strip(): r[1].strip() for r in rows(info, 2)}
    exchange_type = known.get(exchange)
    if exchange_type not in ('topic', 'direct'):
        raise RuntimeError(f'Exchange {exchange!r} not found as topic/direct; inspect RabbitMQ exchanges, then retry. Found type={exchange_type!r}')

    import pika  # installed by Controller phase_notification_bind when explicitly enabled
    user = os.environ.get('RABBIT_USER', '')
    password = os.environ.get('RABBIT_PASS', '')
    host = os.environ.get('CONTROLLER_IP', '127.0.0.1')
    if not user or not password:
        raise RuntimeError('Missing RabbitMQ credentials in private env file')
    params = pika.ConnectionParameters(
        host=host, port=5672, virtual_host=vhost,
        credentials=pika.PlainCredentials(user, password),
        socket_timeout=5, stack_timeout=10, blocked_connection_timeout=10)
    conn = pika.BlockingConnection(params)
    try:
        ch = conn.channel()
        # Probe first: do not redeclare an existing Agent-managed queue with
        # potentially different durability, quorum, arguments or TTL.
        try:
            ch.queue_declare(queue=queue, passive=True)
        except pika.exceptions.ChannelClosedByBroker as exc:
            if exc.reply_code != 404:
                raise
            ch = conn.channel()
            ch.queue_declare(queue=queue, durable=True)
            print(f'Created durable Agent queue {queue} (no pre-existing queue found)')
        for key in keys:
            # queue_bind is idempotent when exchange, queue and key are unchanged.
            ch.queue_bind(exchange=exchange, queue=queue, routing_key=key)
            print(f'Applied queue binding: {exchange} -> {queue} ({key})')
    finally:
        conn.close()


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ('check', 'apply'):
        print('Usage: notification_queue.py {check|apply}', file=sys.stderr)
        return 2
    try:
        vhost, exchange, queue, keys = settings()
        if sys.argv[1] == 'apply':
            apply(vhost, exchange, queue, keys)
        return 0 if verify(vhost, exchange, queue, keys) else 1
    except Exception as exc:
        safe_detail = str(exc) if isinstance(exc, (ValueError, RuntimeError)) else 'inspect RabbitMQ locally (internal details withheld)'
        print(f'Notification queue {sys.argv[1]} failed: {type(exc).__name__}: {safe_detail}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
