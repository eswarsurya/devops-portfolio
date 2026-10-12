# Ansible Linux Hardening Lab

A safety-first Ansible project for applying a reviewable baseline to Ubuntu servers. It demonstrates configuration management, secure defaults, idempotency, validation and operational discipline.

**Status:** CI applies the role to a fresh Ubuntu 24.04 GitHub Actions runner on every change, runs it a second time to confirm nothing changes, and checks the resulting SSH and fail2ban state. A run against a separate VM over SSH is not claimed yet.

## What it does
- Installs and enables fail2ban.
- Installs an SSH daemon drop-in with root login disabled.
- Leaves password authentication unchanged by default to reduce lockout risk; set `linux_hardening_disable_password_auth: true` to disable it.
- Validates SSH configuration before reloading the service.
- Deploys a host-audit helper that writes a timestamped report on the target.
- Uses handlers to reload SSH only when the managed configuration changes.

## Safety
- Use a disposable Ubuntu 22.04/24.04 VM first.
- Run with --check --diff, inspect the changes, keep a second SSH session open and ensure console recovery is available.
- Do not run against production without a change plan and recovery path.
- The project does not change firewall rules, SSH ports or user accounts.

## Requirements and run
Install Ansible Core 2.15+ on your workstation and use a test VM reachable over SSH.

    cp inventory.ini.example inventory.ini
    # Edit the host address and user; never commit real hosts or private keys.
    ansible-playbook -i inventory.ini playbook.yml --syntax-check
    ansible-playbook -i inventory.ini playbook.yml --check --diff
    ansible-playbook -i inventory.ini playbook.yml
    ansible-playbook -i inventory.ini playbook.yml

The second apply should report `changed=0`. To write a host report, run `sudo /usr/local/sbin/portfolio-host-audit` on the server; it saves to `/var/log/portfolio-hardening/`.

## Verify
    ansible -i inventory.ini all -b -m command -a 'sshd -t'
    ansible -i inventory.ini all -b -m command -a 'systemctl is-active fail2ban'
    ansible -i inventory.ini all -b -m command -a 'sshd -T | grep -E "permitrootlogin|passwordauthentication"'

In GitHub Actions, the `lint` job runs the syntax check and `ansible-lint`. The `converge` job applies the role to the runner itself (inventory in `ci/inventory.ini`), applies it again to prove idempotency, then checks `sshd -T`, fail2ban and the audit script.

## Evidence to add after running on a VM
When you run it against your own Ubuntu VM, add the redacted first and second apply summaries and the `sshd -T` output under `docs/`.
