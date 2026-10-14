# Rundeck with the tools its runbook jobs need
FROM rundeck/rundeck:5.8.0
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends mysql-client ldap-utils curl \
 && rm -rf /var/lib/apt/lists/*
COPY --chmod=755 scripts/check-replication.sh /opt/lab/check-replication.sh
COPY --chmod=755 rundeck/run-with-env.sh rundeck/ldap-audit.sh /opt/lab/
USER rundeck
