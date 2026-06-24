# Security Policy

GQuota reads local CLI/IDE credentials to query quota data directly from providers. Treat every token, account id, email, project id, and Keychain value as sensitive.

## Reporting

- Do not paste real credentials, screenshots with tokens, or raw credential files into public issues or pull requests.
- If GitHub private vulnerability reporting is enabled for the repository, use that path first.
- If private reporting is not available, open a public issue with a sanitized description only. Replace sensitive values with placeholders such as `REDACTED`, `acct-FAKE123`, `proj-FAKE123`, and `user@example.com`.

## Scope

Security reports that matter most for this project:

- Credential leakage in source, fixtures, docs, logs, crash output, or cache files.
- Accidental writes back to provider CLI/IDE credential files.
- Network paths that send credentials anywhere other than the intended provider endpoint.
- Unsafe handling of untrusted response data that could expose local data.

Out of scope:

- Provider endpoint availability, quota policy, account bans, or ToS enforcement decisions.
- Requests to add centralized proxying, shared credentials, or scraping of accounts you do not own.

## Local Checks

Before publishing releases or accepting fixture changes, run a secret scan over the working tree and git history. If a credential was ever committed, rotate it first, then clean history before making the repository public.

```bash
gitleaks detect --source . --redact
```
