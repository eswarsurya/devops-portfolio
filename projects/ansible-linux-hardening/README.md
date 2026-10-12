# Ansible Linux Hardening Lab

A safety-first Ansible project for applying a reviewable baseline to Ubuntu servers. It demonstrates configuration management, secure defaults, idempotency, validation and operational discipline.

**Status:** Source and CI checks are included. A successful run against a real Ubuntu VM is not claimed until you execute the lab and save the output.

## What it does
- Installs and enables fail2ban.
- Installs an SSH daemon drop-in with root login disabled.
- Leaves password authentication unchanged by default to reduce lockout risk; disabling it is an explicit variable.
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

The second apply should report no changes to managed configuration. The audit report task is available separately.

## Verify
    ansible -i inventory.ini all -b -m command -a 'sshd -t'
    ansible -i inventory.ini all -b -m command -a 'systemctl is-active fail2ban'
    ansible -i inventory.ini all -b -m command -a 'sshd -T | grep -E "permitrootlogin|passwordauthentication"'

GitHub Actions performs syntax and lint checks only; it does not connect to a server.

## Evidence to add after running
Record the Ubuntu version, Ansible version, syntax/lint output, first and second apply summaries, SSH validation and recovery test. Do not claim passing results until observed.