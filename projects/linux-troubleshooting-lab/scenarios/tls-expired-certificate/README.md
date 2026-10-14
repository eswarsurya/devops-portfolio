# Expired TLS certificate

**Reported symptom:** "Every client of payments-api fails with an SSL error since this morning. Nothing was deployed."

## What `break.sh` does

Builds a small private CA with `openssl` (a root valid for 10 years), then signs a server certificate for `api.lab.internal` with the right name but old dates: valid from 1 January 2024 to 30 June 2024 (`openssl ca -startdate/-enddate`). The HTTPS service listens on `127.0.0.1:18443`. Clients trust the lab CA and reach the name with `curl --resolve`.

## Investigate

1. **What does the client see?** `curl -v --cacert ca.pem https://api.lab.internal:18443/`. From CI:
   ```
   * TLSv1.3 (IN), TLS handshake, Certificate (11):
   * TLSv1.3 (OUT), TLS alert, certificate expired (557):
   * SSL certificate problem: certificate has expired
   curl: (60) SSL certificate problem: certificate has expired
   ```
   Exit 60 means the TCP connection and handshake started fine but the certificate failed verification. Exit 7 or 28 would be a network problem instead.
2. **Look at the handshake with `openssl s_client`.**
   ```
   openssl s_client -connect 127.0.0.1:18443 -servername api.lab.internal -CAfile ca.pem -verify_hostname api.lab.internal
   ```
   It prints `verify error:num=10:certificate has expired` and `Verify return code: 10 (certificate has expired)`. Other codes worth knowing: 62 hostname mismatch, 20/21 unknown issuer (missing intermediate or untrusted CA), 18/19 self-signed.
3. **Decode the certificate the server sends** (not the file you think it loaded):
   ```
   openssl s_client ... </dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
   notBefore=Jan  1 00:00:00 2024 GMT
   notAfter=Jun 30 00:00:00 2024 GMT
   X509v3 Subject Alternative Name: DNS:api.lab.internal
   ```
   `openssl x509 -checkend 0` says `Certificate will expire` (it already has).
4. **Rule out the name.** The SAN includes `api.lab.internal`, so the name is right. Only the dates are wrong. Also check the client clock (`timedatectl`): a wrong clock produces the same error.

## Root cause

The server certificate expired and nobody renewed it.

## Fix

`fix.sh` issues a new 90-day certificate for the same name from the same CA and restarts the service so it loads it. `curl` then verifies, and `openssl x509 -checkend` with 30 days passes.

## Prevention

- Automate renewal (ACME/Let's Encrypt with certbot, cert-manager in Kubernetes) and test the reload.
- Monitor the expiry of the certificate actually served on every endpoint (blackbox_exporter `probe_ssl_earliest_cert_expiry`), and alert 30 and 7 days ahead.
- Keep an inventory of internal certificates; the ones issued by hand are the ones that expire unnoticed.

## What CI checks

After `break.sh`, `curl` with the lab CA fails. `diagnose.sh` reports curl exit code 60, verify code 10, the exact `notAfter` date, and that the hostname matches (so the cause is expiry, not the name). After the fix, `curl` succeeds and the served certificate is valid for at least 30 more days.

## Interview questions this covers

- **Walk me through a TLS handshake.** ClientHello (versions, ciphers, SNI), ServerHello, the server's certificate chain, key exchange, Finished. The client verifies the chain to a trusted root, the dates, and that the name is in the SAN.
- **What is SNI and why pass `-servername`?** Server Name Indication tells a server hosting many names which certificate to send. Without it you may get the default certificate and a misleading name error.
- **"Unable to get local issuer certificate". What now?** The server is not sending its intermediate certificate, or the client does not trust the root. `s_client -showcerts` shows what is sent.
- **How do you check a remote certificate's expiry from the shell?** `echo | openssl s_client -connect host:443 -servername host 2>/dev/null | openssl x509 -noout -enddate`.
