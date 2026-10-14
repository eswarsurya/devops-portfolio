# HTTP 502 from a reverse proxy

**Reported symptom:** "The site returns 502 Bad Gateway."

## What `break.sh` does

Runs nginx on `127.0.0.1:18080` with its own config, proxying to the upstream `orders-api` on `127.0.0.1:19001`. It checks that a request returns 200, then kills the upstream with SIGKILL, like a crash.

## Investigate

1. **Read the response.** `curl -si http://127.0.0.1:18080/orders` returns `HTTP/1.1 502 Bad Gateway` with `Server: nginx/1.24.0 (Ubuntu)`. The proxy answered, so nginx is up. 502 means it could not get a valid response from the upstream. 504 would mean the upstream was too slow. 503 usually means no upstream is available or a limit was hit.
2. **nginx's error log says why.** From CI:
   ```
   [error] ... connect() failed (111: Connection refused) while connecting to upstream, client: 127.0.0.1, server: ,
   request: "GET /orders HTTP/1.1", upstream: "http://127.0.0.1:19001/orders", host: "127.0.0.1:18080"
   ```
   errno 111 is `ECONNREFUSED`: nothing listens on that address and port. `upstream timed out (110)` would point at a slow upstream (a 504), and `Connection reset by peer` (104) at an upstream that crashed mid-request.
3. **Check the real config, not the one you remember.** `nginx -T` prints the full config nginx loaded, including the `upstream` block (`server 127.0.0.1:19001`).
4. **Is the upstream listening?** `ss -ltnp '( sport = :18080 or sport = :19001 )'` shows nginx on 18080 and nothing on 19001. `pgrep -a -x orders-api` finds no process, and `curl http://127.0.0.1:19001/` is refused directly.

## Root cause

The upstream application is down. nginx is the messenger.

## Fix

`fix.sh` starts the upstream again. nginx needs no reload: it tries the upstream on every request. Then find out why it died: its own logs, `journalctl -u <service>`, `dmesg` for an OOM kill, and the exit code (`systemctl status` shows it).

## Prevention

- Run the upstream under a supervisor that restarts it (`Restart=on-failure` in systemd, a Deployment in Kubernetes).
- More than one upstream instance, so one crash is not an outage. nginx then retries the next server.
- Alert on 5xx rate at the proxy *and* on upstream health, so you see the cause, not just the symptom.

## What CI checks

After `break.sh` the proxy returns 502. `diagnose.sh` reports the status (502), the upstream address from nginx's error log (`127.0.0.1:19001`), the error type (`connection refused`) and that nothing listens on the upstream port. After the fix, the proxy returns 200 with `orders-api ok`.

## Interview questions this covers

- **502 vs 503 vs 504?** 502: bad or no response from the upstream (refused, reset, invalid). 503: service unavailable (no healthy upstream, maintenance, rate limit). 504: the upstream did not answer in time.
- **Where do you look first for a 502?** The proxy's error log. It names the upstream and the system error.
- **How do you prove whether the proxy or the app is at fault?** Call the upstream directly from the proxy host, bypassing the proxy.
- **The upstream is up but you still get 502s. What else?** Wrong port or address in the config, the upstream closing keep-alive connections early, response headers too big for the proxy buffers, or SELinux blocking nginx from connecting (`httpd_can_network_connect`).
