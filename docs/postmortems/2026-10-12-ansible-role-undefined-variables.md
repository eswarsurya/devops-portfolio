# Ansible role would have failed on every server while CI was green

**Date:** 12 Oct 2026 · **Project:** [ansible-linux-hardening](../../projects/ansible-linux-hardening) · **Impact:** none in use (lab project), but the role was broken for any real run

## Summary
A lint fix renamed the role's default variables from `hardening_*` to `linux_hardening_*`, but the tasks and the SSH template still used the old names. Any real run would have stopped at the first task with "undefined variable". CI stayed green because it only ran a syntax check and `ansible-lint`, and neither one executes the role.

## Timeline (12 Oct, Irish time)
- **13:20** A commit renames the variables in `defaults/main.yml` only, to satisfy an `ansible-lint` naming rule. CI passes.
- **17:28** The change is merged.
- **~17:35** A review of the role finds the mismatch between `defaults/` and `tasks/`.
- **17:42** Fix: tasks and template use the new names. CI gains a `converge` job that applies the role for real to a fresh Ubuntu 24.04 runner.
- **17:42–17:46** The first runs of the new job fail on a second bug the syntax check could never catch: `sshd -t` refuses to validate the config because `/run/sshd` doesn't exist. Ubuntu 24.04 starts sshd on demand, so the directory isn't there until the first connection.
- **17:49** The role creates `/run/sshd` before validating. The converge job passes: first run applies, second run reports `changed=0`, and the SSH and fail2ban checks pass.

## Root cause
The tests checked that the code was well-formed, not that it worked. A rename across files is exactly the change a syntax check can't catch.

## What changed
- CI now applies the role, applies it again to prove idempotency, and verifies the result (`sshd -T`, fail2ban active, audit script runs).
- The role handles Ubuntu 24.04's on-demand sshd.

## Lesson
A green pipeline only means the checks it runs passed. For configuration management, the useful check is running it against a real machine.
