#!/bin/bash
# Lists the members of the LDAP "sre" group for the weekly access review.
set -euo pipefail
ldapsearch -x -LLL -H ldap://ldap -D cn=readonly,dc=dublin-dc,dc=lab -w "$LDAP_READONLY_PASSWORD" \
  -b cn=sre,ou=groups,dc=dublin-dc,dc=lab member
