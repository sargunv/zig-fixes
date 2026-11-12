---
title: TLS client does not check the cA basic constraint, so a leaf certificate can sign certificates for any host
priority: 1
area: lib/std
targets: [all]
upstream: [codeberg#35877]
affects-line: yes
---

## Symptom

`std.crypto.tls.Client` (and so `std.http.Client` and `zig fetch` over HTTPS)
accepts a chain in which an ordinary leaf certificate, valid for a domain the
attacker owns, signs a certificate for any other host. The reporter's repro
fetches `https://ziglang.org` from an attacker server and gets status 200
instead of `TlsInitializationFailed`. This allows MITM of HTTPS connections,
including the first fetch of a package before its hash is pinned.

## Evidence

- codeberg#35877 (0.17.0-dev.931), with a live repro server; a commenter
  reproduced it.
- Not reproduced here (needs the attacker host). The missing check was read at
  0.17.1.

## Root cause

`lib/std/crypto/Certificate.zig:259-300`: `Parsed.verify` checks issuer/subject
name match, validity dates and the signature only. Nothing checks that the
issuer has basic constraints `cA = TRUE` or honours `pathLenConstraint`
(RFC 5280 4.2.1.9), and `basic_constraints` is only listed as a known extension
(`Certificate.zig:124,149`). The chain walk in
`lib/std/crypto/tls/Client.zig:651` calls `prev_cert.verify(subject, now_sec)`
for each intermediate with no CA check.

## Fix sketch

Parse the basic constraints extension (cA flag, optional pathLen) in
`Certificate.parse`, and in `verify` (or the chain walk) reject an issuer that
is not a CA, tracking path length. Moderate; needs tests with crafted chains.

## Verification

A chain of a CA-issued leaf followed by a certificate it signed for another
host must fail TLS setup; existing `std.http` and package fetch tests still
pass.

## Notes

Upstream labels it Urgent. No fix on `origin/master`. Related crypto bugs in
this sweep (listed, not filed): codeberg#35921 (RSA-PSS assert on 2041-bit
keys), codeberg#36098 (CertificateRequest unsupported), codeberg#36580
(CertificateIssuerMismatch for a valid site).
