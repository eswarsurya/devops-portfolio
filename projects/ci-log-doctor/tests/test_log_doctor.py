import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

import log_doctor as ld  # noqa: E402

EXAMPLE = (pathlib.Path(__file__).parents[1] / "examples" / "failed-build.log").read_text()


# ---------------------------------------------------------------- redaction
def test_redacts_github_token():
    assert "ghp_" not in ld.redact("token ghp_abcdefghijklmnopqrstuvwxyz0123456789")


def test_redacts_anthropic_key():
    assert "sk-ant-" not in ld.redact("key sk-ant-api03-abcdefghijklmnop")


def test_redacts_aws_key_id():
    out = ld.redact("aws_access_key_id AKIAABCDEFGHIJKLMNOP")
    assert "AKIAABCDEFGHIJKLMNOP" not in out


def test_redacts_password_assignment():
    assert "hunter2" not in ld.redact("PASSWORD=hunter2")


def test_redacts_private_key_block():
    pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----"
    assert "MIIabc" not in ld.redact(pem)


def test_redacts_password_in_connection_url():
    out = ld.redact("DATABASE_URL=postgres://app:SuperSecret123@db:5432/app")
    assert "SuperSecret123" not in out
    assert "@db:5432/app" in out  # host kept - useful for debugging


def test_example_log_has_no_secrets_after_pipeline():
    out = ld.redact(ld.extract_relevant(EXAMPLE))
    assert "ghp_abcdefghijklmnopqrstuvwxyz0123456789" not in out
    assert "SuperSecret123" not in out


# ---------------------------------------------------------------- extraction
def test_extract_keeps_error_and_strips_timestamps():
    out = ld.extract_relevant(EXAMPLE)
    assert "AssertionError" in out
    assert "2026-10-12T" not in out


def test_extract_drops_irrelevant_middle_of_long_log():
    noise = "\n".join(f"compiling module {i}" for i in range(2000))
    log = noise + "\nERROR: cannot connect to db\n" + noise
    out = ld.extract_relevant(log, context=2)
    assert "cannot connect to db" in out
    assert out.count("compiling module") < 100


def test_extract_respects_max_chars_and_keeps_end():
    log = "\n".join(f"error line {i}" for i in range(5000))
    out = ld.extract_relevant(log, max_chars=1000)
    assert len(out) <= 1100
    assert "error line 4999" in out


def test_extract_empty_log():
    assert ld.extract_relevant("") == ""


# ---------------------------------------------------------------- output
def test_comment_has_marker_and_disclaimer():
    body = ld.format_comment("https://x/run/1", [("test", "**Root cause** x")], "m")
    assert body.startswith(ld.COMMENT_MARKER)
    assert "verify before merging" in body


def test_dry_run_without_api_key_shows_prompt():
    out = ld.diagnose("test", EXAMPLE, api_key=None, model="m")
    assert "dry run" in out and "Root cause" in out


# ---------------------------------------------------------------- HTTP (mocked)
def test_ask_claude_parses_text_blocks(monkeypatch):
    captured = {}

    def fake_request(method, url, headers, body=None):
        captured.update(url=url, headers=headers, body=body)
        return json.dumps({"content": [{"type": "text", "text": "**Root cause** sort order"}]}).encode()

    monkeypatch.setattr(ld, "_request", fake_request)
    out = ld.ask_claude("prompt", "sk-ant-test", "claude-haiku-5-5")
    assert out == "**Root cause** sort order"
    assert captured["headers"]["x-api-key"] == "sk-ant-test"
    assert captured["body"]["model"] == "claude-haiku-5-5"


def test_upsert_updates_existing_comment_instead_of_spamming(monkeypatch):
    calls = []

    def fake_request(method, url, headers, body=None):
        calls.append((method, url))
        if method == "GET":
            return json.dumps([{"url": "https://api/c/7", "body": ld.COMMENT_MARKER + " old"}]).encode()
        return b"{}"

    monkeypatch.setattr(ld, "_request", fake_request)
    ld.GitHub("t", "o/r").upsert_pr_comment(5, "new")
    assert ("PATCH", "https://api/c/7") in calls
    assert not any(m == "POST" for m, _ in calls)


def test_full_actions_flow(monkeypatch, tmp_path):
    event = {"workflow_run": {"id": 42, "html_url": "https://gh/run/42", "pull_requests": [{"number": 9}]}}
    ev = tmp_path / "event.json"
    ev.write_text(json.dumps(event))
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_EVENT_PATH", str(ev))
    monkeypatch.setenv("GITHUB_TOKEN", "t")
    monkeypatch.setenv("GITHUB_REPOSITORY", "o/r")
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    posted = {}

    def fake_request(method, url, headers, body=None):
        if url.endswith("/runs/42/jobs?per_page=100"):
            return json.dumps(
                {
                    "jobs": [
                        {"id": 1, "name": "test", "conclusion": "failure"},
                        {"id": 2, "name": "lint", "conclusion": "success"},
                    ]
                }
            ).encode()
        if url.endswith("/jobs/1/logs"):
            return EXAMPLE.encode()
        if "anthropic" in url:
            assert "ghp_abcdefghijklmnopqrstuvwxyz0123456789" not in json.dumps(body)
            return json.dumps(
                {"content": [{"type": "text", "text": "**Root cause** list not sorted"}]}
            ).encode()
        if method == "GET" and "/comments" in url:
            return b"[]"
        if method == "POST" and "/issues/9/comments" in url:
            posted["body"] = body["body"]
            return b"{}"
        raise AssertionError(f"unexpected call {method} {url}")

    monkeypatch.setattr(ld, "_request", fake_request)
    assert ld.run_in_actions() == 0
    assert "list not sorted" in posted["body"]
    assert "lint" not in posted["body"]  # successful jobs are ignored
    assert "list not sorted" in summary.read_text()



def test_missing_api_key_skips_log_download_and_writes_summary(monkeypatch, tmp_path):
    event = {"workflow_run": {"id": 42, "html_url": "https://gh/run/42", "pull_requests": []}}
    ev = tmp_path / "event.json"
    ev.write_text(json.dumps(event))
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_EVENT_PATH", str(ev))
    monkeypatch.setenv("GITHUB_TOKEN", "t")
    monkeypatch.setenv("GITHUB_REPOSITORY", "o/r")
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    def fail_if_called(*args, **kwargs):
        raise AssertionError("failed job logs must not be downloaded without an API key")

    monkeypatch.setattr(ld.GitHub, "failed_jobs", fail_if_called)
    assert ld.run_in_actions() == 0
    output = summary.read_text()
    assert "missing API key" in output
    assert "ANTHROPIC_API_KEY" in output
