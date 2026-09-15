# EPV Production Security Notes

## Enforced/recommended in this release

1. Strict mTLS in production connector units.
2. Client validates CA chain and server DNS/IP SAN by default.
3. TLS 1.2 minimum is preserved on the RHEL7/OpenSSL 1.0.2 path.
4. Server private key should be `0640 root:epvconnector`; client private key should normally be `0600 root:root`.
5. Connector databases are read-only to the service process; LKG copies are kept under the private runtime directory.
6. v2.3.3 client cache files are per executable/config namespace and use bounded locking.
7. Production service units do not enable sensitive `--debug` output.

## Known residual hardening items (not silently changed in this release)

These are retained for protocol/behavior compatibility and should be treated as future hardening work:

- Application-mode process authorization still accepts matching ancestors and contains legacy cmdline/hash matching behavior. It is not a strong process identity boundary against a hostile same-user process.
- `MODE_APP_CHECKSUM` still accepts a caller-provided checksum after parent validation rather than always independently deriving the supplied checksum mode from an already-open file descriptor.
- Passwords/tokens supplied on the command line can be visible to local process inspection depending on OS permissions. A future stdin/fd credential input mode is preferable.
- Legacy MD5 application mode remains available for compatibility; prefer SHA-256.
- Connector master encryption material is compiled into the current connector source. Future production hardening should move it to a root-owned key file, TPM/HSM, or PKCS#11 provider.
- `--insecure` exists for troubleshooting. Production automation should never use it.
- Sensitive connector `--debug` exists by explicit design; do not enable it in persistent production services.

These notes do not mean the release is unusable; they identify boundaries that should not be mistaken for stronger controls than they currently provide.
