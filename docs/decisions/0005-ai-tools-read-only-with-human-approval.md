# 0005: AI tools get read-only access; changes need a person

**Status:** accepted, Oct 2026 · Projects: [aiops-triage-agent](../../projects/aiops-triage-agent), [devops-mcp-server](../../projects/devops-mcp-server), [ci-log-doctor](../../projects/ci-log-doctor)

## Context
An AI assistant that can investigate incidents is useful. One that can change production on its own is a risk: a wrong guess, or text in a log written to manipulate it (prompt injection), could turn into a destructive command.

## Decision
- Investigation tools are read-only, enforced in code and by Kubernetes RBAC (get and list only, no secrets, no exec).
- The agent can propose a fix. The fix only runs after a person approves it, and approval fails closed: with no approver token configured, every approval is refused.
- Secrets are redacted before any log or output reaches the model, and each redaction pattern has a test.
- The MCP server blocks requests to internal and metadata addresses (SSRF), so a prompt can't make it probe `169.254.169.254`.

## Consequences
- The AI speeds up diagnosis without being trusted with changes.
- A person stays in the loop for every change, which is slower at 3 a.m. but safe.
- The guardrails are tested (19 tests in the triage agent alone), so they can't quietly regress.
