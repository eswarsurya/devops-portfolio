# Log4j (Log4Shell) remediation

`vulnerable/` is a Java service that depends on `log4j-core` 2.14.1, which is affected by
CVE-2021-44228 (Log4Shell, remote code execution through JNDI lookups in log messages) and the follow-up
CVEs 2021-45046 and 2021-45105. `fixed/` is the same service after the fix: Log4j upgraded to 2.24.1.

CI scans both with Trivy and checks that:

1. the vulnerable build **is** flagged for CVE-2021-44228 (the scanner would catch it), and
2. the fixed build has **no** critical findings.

## The remediation steps, as I would run them on a real estate

1. **Find every copy.** Scan source repositories (`trivy fs`), container images (`trivy image`) and servers
   (`find / -name 'log4j-core-*.jar'`, including jars nested inside fat jars and WARs).
2. **Upgrade.** Move to Log4j 2.17.1 or later (2.12.4 for Java 7, 2.3.2 for Java 6). Prefer the current release.
3. **Mitigate what cannot be upgraded today.** Remove the `JndiLookup` class from the jar:
   `zip -q -d log4j-core-*.jar org/apache/logging/log4j/core/lookup/JndiLookup.class`.
   The old `-Dlog4j2.formatMsgNoLookups=true` flag is **not** enough on its own (CVE-2021-45046).
4. **Block the attack path.** Deny outbound LDAP/RMI from application servers at the firewall.
5. **Verify and keep verifying.** Re-scan, and keep the scan in CI so the old version cannot come back.
