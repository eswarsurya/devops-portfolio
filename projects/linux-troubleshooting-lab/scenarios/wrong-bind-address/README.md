# Service listening on the wrong address

**Reported symptom:** "inventory-api is up. The health check on the server passes. Every client gets 'connection refused'."

## Topology

```
lab-bind-cli  10.202.0.10  <-- veth -->  lab-bind-srv  10.202.0.1  inventory-api :8080
```

## What `break.sh` does

Starts `inventory-api` with `BIND_ADDRESS=127.0.0.1` in its config. It only accepts connections from the server itself.

## Investigate

1. **From the client.** `curl http://10.202.0.1:8080/` fails at once: `curl: (7) Failed to connect to 10.202.0.1 port 8080 after 0 ms`. An immediate refusal means the host answered with a TCP reset. The network path works; nothing is listening on *that address and port*.
2. **Is the host up?** `ping 10.202.0.1` replies. So it is not the network.
3. **On the server: who listens where?** `ss -ltnp`. From CI:
   ```
   State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess
   LISTEN 0      5          127.0.0.1:8080      0.0.0.0:*    users:(("inventory-api",pid=...,fd=3))
   ```
   `127.0.0.1:8080` means loopback only. `0.0.0.0:8080` (or the server's own IP) would accept connections from outside.
4. **Confirm.** On the server, `curl http://127.0.0.1:8080/` works and `curl http://10.202.0.1:8080/` is refused. That is why the local health check passed.

## Root cause

The service binds to the loopback address. Common causes: a framework default (`localhost`), a config copied from a laptop, or `localhost` in a container.

## Fix

`fix.sh` sets `BIND_ADDRESS=0.0.0.0`, restarts the service, and `ss` shows `0.0.0.0:8080`. Binding to the specific service IP is even better when you know it, and a firewall should still decide who may connect.

## Prevention

- Health checks should come from where the clients are (the load balancer, another host), not only from `localhost`.
- Make the bind address an explicit setting and review it.
- In containers, apps must listen on `0.0.0.0` inside the container, or port publishing cannot reach them.

## What CI checks

After `break.sh` the client cannot connect. `diagnose.sh` reports the listening address (`127.0.0.1:8080`), the listening process (`inventory-api`), that the client error is "connection refused", and that the host answers ping. After the fix, the client gets `inventory-api ok`.

## Interview questions this covers

- **"Connection refused" vs "connection timed out"?** Refused: the host answered with a RST (nothing listening, or a REJECT rule). Timed out: no answer at all (a DROP rule, routing, host down).
- **What does `ss -ltnp` show?** Listening (`-l`) TCP (`-t`) sockets, numeric (`-n`), with the owning process (`-p`, needs root for other users' processes).
- **What is the difference between `0.0.0.0`, `127.0.0.1` and `::`?** All IPv4 addresses, loopback only, and all IPv6 addresses (often IPv4 too, depending on `net.ipv6.bindv6only`).
- **How do you check this inside a Kubernetes pod?** `kubectl exec ... -- ss -ltn` (or `netstat`), and compare with the Service's `targetPort`.
