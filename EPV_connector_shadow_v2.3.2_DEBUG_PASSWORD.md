# EPV Connector Shadow v2.3.2 - Sensitive Debug Output

This release preserves the v2.3.1-shadow protocol and RHEL7/8/9/10 portability, and adds explicit sensitive-value debug output when `--debug` is enabled.

## New debug records

- AES token encryption: plaintext and encrypted value
- AES token decryption: encrypted value and plaintext
- Shadow DB secret lookup: encrypted `epa03` value
- Shadow DB secret decrypt: encrypted value and decrypted password
- Worker secret result: decrypted DB password

Example patterns:

```
[DEBUG] AES encrypt success plain=<plaintext> enc=<ciphertext>
[DEBUG] AES decrypt success enc=<ciphertext> plain=<plaintext>
[DEBUG] worker[0] DB password encrypted=<epa03>
[DEBUG] AES DB password decrypt success encrypted=<epa03> decrypted=<password>
[DEBUG] worker[0] DB password decrypted=<password>
```

These messages are emitted only when `--debug` is specified. They intentionally expose credentials/tokens and therefore should be used only during controlled troubleshooting.

## Normal mode

Without `--debug`, the new sensitive lines are not emitted.
