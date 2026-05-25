# wsmnt-taxevasion

## Distributed CRUD over MOM (RabbitMQ) — WSMT Project

A horizontally-scalable CRUD application that exposes a REST web service, but executes every operation as a **message** routed through **RabbitMQ**. Two REST gateways sit behind an Nginx load balancer; two worker nodes consume messages from durable queues and persist to PostgreSQL.

## Architecture

```
            ┌──────────────┐
 Browser ──►│  Nginx (LB)  │──►  gateway-1 ──┐
            │   :8080      │──►  gateway-2 ──┤    (RPC over RabbitMQ)
            └──────────────┘                 │
                                             ▼
                                     ┌──────────────┐
                                     │   RabbitMQ   │  durable, persistent, quorum-ready
                                     │  :5672 :15672│
                                     └──────┬───────┘
                                            │
                                ┌───────────┴───────────┐
                                ▼                       ▼
                           worker-1                 worker-2
                                │                       │
                                └──────────► PostgreSQL ◄──────────┘
```

### Requirement → Mechanism

| Requirement | How it's satisfied |
|---|---|
| Web service tech | REST (Spring Web) on the gateways |
| User-friendly client | Static HTML/JS app served by Nginx (`client/`) |
| CRUD | `POST/GET/PUT/DELETE /api/products` |
| Load balancing | Nginx upstream with `least_conn` over two gateway nodes |
| Failover | Nginx `max_fails`/`fail_timeout`; RabbitMQ redelivers unacked messages from a crashed worker to a healthy one |
| Message persistence | `durable=true` queues + `MessageDeliveryMode.PERSISTENT` |
| Reliable delivery | Publisher confirms, mandatory publish, manual consumer ACK, DLQ |
| Message queuing (async) | All operations published to `products.commands` queue; RPC reply queue for responses |
| Administered via messages | Gateway never touches the DB; only the broker speaks to workers |
| Horizontal scale | `docker compose up --scale worker=N` / `--scale gateway=N` |
| Security | RabbitMQ user+password, vhost isolation, Postgres credentials, TLS-ready (see notes) |
| Works with existing MOM | RabbitMQ (AMQP 0-9-1) |

## Run

```powershell
docker compose up --build
```

Open the client at <http://localhost:8080/> and the RabbitMQ console at <http://localhost:15672/> (user: `wsmt`, pass: `wsmt`).

### Scale horizontally

```powershell
docker compose up --build --scale worker=3 --scale gateway=3
```

### Failover demo

```powershell
docker compose kill worker-1   # second worker keeps serving; unacked messages are redelivered
docker compose kill gateway-1  # Nginx routes to gateway-2
```

## Project layout

- `gateway/` — Spring Boot REST API, publishes commands, awaits replies (RabbitMQ RPC)
- `worker/` — Spring Boot consumer, JPA persistence, replies with results
- `client/` — Static SPA (HTML + vanilla JS)
- `nginx/` — Load balancer + static client host
- `rabbitmq/` — Pre-declared queues, exchanges, users (definitions.json)
- `docker-compose.yml` — Orchestration

## Notes on security
- Broker credentials are injected via env vars; rotate before production.
- Enable TLS by mounting certs into RabbitMQ and switching `spring.rabbitmq.ssl.enabled=true`.
- Nginx terminates HTTP; put a real TLS cert in `nginx/` for HTTPS.
