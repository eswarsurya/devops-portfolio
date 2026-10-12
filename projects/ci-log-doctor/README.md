# ci-log-doctor

When a CI build fails, this GitHub Actions workflow reads the failed job logs, strips the noise, **redacts secrets**, asks Claude for the root cause and a fix, and posts **one** comment on the pull request. It updates that comment on re-runs instead of spamming.

![ci-log-doctor](https://github.com/eswarsurya/devops-portfolio/actions/workflows/ci-log-doctor-ci.yml/badge.svg)

## Why

Developers lose time scrolling 5,000-line CI logs to find the one line that matters. This tool turns a red build into a short "here's what broke and how to fix it" on the PR. It's built with the guardrails you'd want before letting an LLM near CI:

- **Secrets never leave the runner.** GitHub tokens, Anthropic keys, AWS key IDs, bearer tokens, `password=` values, passwords inside connection URLs and PEM private keys are all redacted before the prompt is built. Each pattern has a test.
- **Cheap and focused.** Only the lines around error markers plus the log tail are sent (capped at about 12k chars), using a small, fast model by default. A typical diagnosis costs a fraction of a cent.
- **Safe trigger.** It runs on `workflow_run` from the default branch, so code in a PR can't change what the doctor does or read its secrets.
- **Honest output.** The prompt tells the model to say when the log doesn't show the cause, and every comment carries a "verify before merging" note.
- **Credential-safe fallback.** If `ANTHROPIC_API_KEY` is missing, the workflow writes a clear skip notice to the job summary and exits without downloading logs. Log downloads follow GitHub's signed redirect without forwarding the GitHub token to the storage host.
- **No dependencies.** Python standard library only. Nothing to install, nothing to keep patched.

## How it works

```
 PR push ──► workflow "ci" ──► ❌ fails
                                   │ workflow_run: completed (failure)
                                   ▼
                     workflow "ci-log-doctor"  (runs trusted code from main)
                       1. GET  /actions/runs/{id}/jobs      → failed jobs (max 3)
                       2. GET  /actions/jobs/{id}/logs      → raw logs
                       3. extract_relevant()  error lines ± 6, tail 40, strip timestamps
                       4. redact()            tokens, keys, passwords, PEM blocks
                       5. POST Claude Messages API          → root cause / fix / confidence
                       6. create or PATCH the PR comment with a hidden marker
                       7. also write it to the job summary
```

## Example output

> ### ❌ `test`
> **Root cause:** `GET /incidents` returns items in insertion order, but the test expects them sorted by severity: `assert [3, 1] == [1, 3]`.
> **Fix:** in `list_incidents`, sort before returning: `sorted(_db.values(), key=lambda i: (i.severity, i.id))`.
> **Confidence:** high. The assertion diff shows the exact ordering problem.

(Run the local demo below to see the exact prompt it builds from `examples/failed-build.log`.)

## Try it locally

```bash
python src/log_doctor.py --log-file examples/failed-build.log          # dry run: shows the redacted prompt
ANTHROPIC_API_KEY=sk-ant-... python src/log_doctor.py --log-file examples/failed-build.log   # real diagnosis
pytest -q tests demo                                                    # 19 tests
```

## Use it in a repo

1. Add the secret **`ANTHROPIC_API_KEY`** (Settings → Secrets and variables → Actions). Set a monthly spend limit in the Anthropic console. If the secret is absent, the diagnostic workflow skips safely and records the reason in the job summary.
2. Push to `main` (the `workflow_run` trigger only works from the default branch).
3. Open a PR that breaks something, for example change `0.1` to `0.2` in `demo/sla.py`. CI fails, and within a minute the diagnosis appears on the PR.

In this repo it watches every project's CI. The list is in `/.github/workflows/ci-log-doctor-diagnose.yml`.

## Limits I'm aware of

- PRs from **forks** don't populate `workflow_run.pull_requests`, so the diagnosis goes to the job summary only.
- Regex redaction is defence in depth, not a guarantee. GitHub's own secret masking still applies first.
- Huge logs are trimmed, so a cause buried mid-log with no error keyword can be missed. The model is told to say so rather than guess.

## What I'd add next

- Package it as a reusable composite action (`uses: eswarsurya/ci-log-doctor@v1`).
- Feed in the PR diff as well, so the model can point at the exact changed line.
- Track which suggestions were right (👍/👎 reactions) to measure usefulness.
