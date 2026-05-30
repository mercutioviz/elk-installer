# secrets/

This directory holds **encrypted** secrets used by the installer:

- The internal CA private key and cert chain
- Elasticsearch bootstrap passwords + per-role passwords
- Kibana encryption keys (`xpack.encryptedSavedObjects.encryptionKey`, etc.)
- Logstash keystore material
- Cloud snapshot credentials (S3 / Azure Blob / GCS)
- Any OIDC / SAML client secrets

## Encryption

We use **[sops](https://github.com/getsops/sops)** with **age** keys.

- The project's age public keys are listed in `.sops.yaml` (TBD — added when
  the TLS bootstrap phase lands). Each maintainer's age public key goes there;
  every secret file is automatically re-encrypted for all listed keys on save.
- Plaintext secrets are gitignored. Encrypted files (`.sops.yaml`-matched
  patterns, typically `*.enc.yaml` / `*.enc.json`) ARE committed.
- The control-node operator needs their age private key locally to decrypt.

## What never goes here

- Anything plaintext.
- Anything you would not want in the project repo even when encrypted —
  use an external secret store (Vault, cloud KMS) and reference it.

## Rotation

Rotating a secret is a one-line edit followed by `sops updatekeys`. The
`elk-doctor` command (when implemented) flags secrets older than the
configured rotation window.
