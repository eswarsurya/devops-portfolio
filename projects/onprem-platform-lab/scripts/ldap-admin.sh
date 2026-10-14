#!/usr/bin/env bash
# Day-to-day LDAP administration against the lab directory.
#   ldap-admin.sh add-user <uid> <full name> <password>
#   ldap-admin.sh add-to-group <uid> <group>
#   ldap-admin.sh remove-from-group <uid> <group>
#   ldap-admin.sh list-group <group>
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }

BASE="dc=dublin-dc,dc=lab"
ADMIN="cn=admin,$BASE"
ldap() { local cmd=$1; shift; docker compose exec -T ldap "$cmd" -x -H ldap://localhost -D "$ADMIN" -w "$LDAP_ADMIN_PASSWORD" "$@"; }

case "${1:-}" in
  add-user)
    uid=$2; name=$3; pw=$4; sn=${name##* }
    printf 'dn: uid=%s,ou=people,%s\nobjectClass: inetOrgPerson\nuid: %s\ncn: %s\nsn: %s\nuserPassword: %s\n' \
      "$uid" "$BASE" "$uid" "$name" "$sn" "$pw" | ldap ldapadd ;;
  add-to-group|remove-from-group)
    op=add; [ "$1" = remove-from-group ] && op=delete
    printf 'dn: cn=%s,ou=groups,%s\nchangetype: modify\n%s: member\nmember: uid=%s,ou=people,%s\n' \
      "$3" "$BASE" "$op" "$2" "$BASE" | ldap ldapmodify ;;
  list-group)
    ldap ldapsearch -LLL -b "cn=$2,ou=groups,$BASE" member ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
