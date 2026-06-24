# Contributing

GQuota is a local, personal-use menu bar app. It reads local AI CLI/IDE credentials and calls provider endpoints directly from the user's machine.

## Accepted Contributions

- Parser fixes for provider response changes.
- Tests and sanitized fixtures.
- Documentation improvements.
- Local privacy and credential-handling hardening.
- UI changes that keep the app local-first and low-noise.

## Not Accepted

- Uploading credentials or quota responses to any GQuota backend.
- Centralized proxying of provider requests.
- Shared credentials, account pooling, or scraping accounts you do not own.
- Bypassing provider rate limits, abuse controls, or authentication flows.
- Logging raw tokens, account ids, project ids, emails, or Keychain output.

## Pull Request Rules

- Keep fixtures sanitized. Use placeholders such as `REDACTED`, `acct-FAKE123`, `proj-FAKE123`, and `user@example.com`.
- Do not paste real provider responses unless identity and credential fields are removed.
- Run the relevant tests before opening a PR:

```bash
cd GQuotaKit && swift test
```

- For privacy-sensitive changes, also run a secret scan:

```bash
gitleaks detect --source . --redact
```

## License

By contributing, you agree that your contribution is licensed under the MIT License.
