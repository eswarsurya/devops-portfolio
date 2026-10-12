# devops-mcp-server

**Give your AI assistant safe eyes on production.** This is an MCP (Model Context Protocol) server that lets Claude Desktop, Claude Code or any MCP client check websites, TLS certificates, Prometheus, Kubernetes and GitHub Actions. Every tool is **read-only**, validates its input, and blocks **SSRF**, so an assistant can't be talked into probing `169.254.169.254` or your internal admin panels.

![devops-mcp-server](https://github.com/eswarsurya/devops-portfolio/actions/workflows/devops-mcp-server-ci.yml/badge.svg)

```
You:    Is rail-pulse healthy? Check the site, its certificate, and the last CI run.
Claude: → check_url("https://rail-pulse.example.com")        200 in 84 ms
        → tls_certificate("rail-pulse.example.com")          Let's Encrypt, 61 days left, OK
        → github_actions_runs("eswarsurya/devops-portfolio")     last 5 runs green
        All healthy. The certificate renews automatically in about 30 days.
```

## Tools

| Tool | What it does |
|---|---|
| `check_url` | HTTP status, latency, redirect target. Redirects are **reported, not followed**. |
| `tls_certificate` | Expiry, days left, issuer, SANs, TLS version. Flags `EXPIRING_SOON` within 14 days. |
| `prometheus_query` | Instant PromQL query |
| `prometheus_alerts` | What's firing or pending right now |
| `k8s_pods` / `k8s_events` / `k8s_logs` | Namespace health, events, logs (`previous=true` for the crashed container) |
| `github_actions_runs` | Latest CI runs for `owner/repo`, with failure count |
| Prompt: `triage_service` | A step-by-step investigation plan the assistant can follow |

## Install

```bash
pip install "git+https://github.com/eswarsurya/devops-portfolio#subdirectory=projects/devops-mcp-server"
```

**Claude Code:**
```bash
claude mcp add devops -e PROMETHEUS_URL=http://localhost:9090 -- devops-mcp
```

**Claude Desktop** (`claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "devops": {
      "command": "devops-mcp",
      "env": { "PROMETHEUS_URL": "http://localhost:9090", "GITHUB_TOKEN": "optional" }
    }
  }
}
```

Kubernetes tools use your current `kubectl` context, so point it at a **read-only** kubeconfig (for example the `triage-reader` ClusterRole from my aiops-triage-agent repo).

## Security model

| Threat | Control |
|---|---|
| AI changes something | No write tools exist. Every tool carries `readOnlyHint: true, destructiveHint: false`, so clients can auto-approve them safely. |
| **SSRF**: "check http://169.254.169.254/…" | URLs and hosts are resolved first, and private, loopback, link-local and metadata IPs are refused (IPv4 and IPv6). Public names that resolve to private IPs are refused too. Opt in with `ALLOW_PRIVATE_TARGETS=1`. |
| Redirect to an internal URL | Redirects are not followed, only reported |
| Command injection | Kubernetes names checked with a regex, `kubectl` run **without a shell**, fixed verbs only |
| Credentials in URLs | `https://user:pass@…` is refused |
| Huge outputs flooding context | Output is truncated, log tails are capped at 500 lines, lists at 50 |
| Leaking internals in errors | Deliberate refusals return a clear `ToolError`. Unexpected crashes return a generic message, and the stack trace stays on the server. |

## Tests

22 tests run through a **real MCP client connected in-process**: tool discovery and read-only annotations, the prompt, 8 SSRF payloads (metadata, loopback, RFC 1918, IPv6, DNS-to-private, `file://`, credentials), injection, log caps, truncation, Prometheus and GitHub parsing. CI also starts the server over **stdio** the way Claude Desktop does.

## What I'd add next

- An HTTP transport with OAuth for a shared team server.
- `argocd_app_status` and `terraform_state_drift` tools.
- Per-tool audit logging (who asked what, when).
