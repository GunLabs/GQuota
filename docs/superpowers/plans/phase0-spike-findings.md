# Phase 0 Spike Findings

Date: 2026-06-12
Worktree: `.worktrees/gquota-mvp`

## Interface Results

- OpenAI `GET https://chatgpt.com/backend-api/wham/usage`: HTTP 200
- Gemini `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`: initial HTTP 401, retry after Gemini CLI refresh HTTP 200
- Gemini `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`: HTTP 200

## OpenAI Field Shape

Captured fixture: `GQuotaKit/Tests/GQuotaKitTests/Fixtures/openai-wham-usage.json`

Relevant observed fields:

- Top-level identity and plan fields: `account_id`, `email`, `user_id`, `plan_type`
- Main quota object: `rate_limit.allowed`, `rate_limit.limit_reached`, `rate_limit.primary_window`, `rate_limit.secondary_window`
- Window fields: `limit_window_seconds`, `reset_after_seconds`, `reset_at`, `used_percent`
- Extra model/feature quotas: `additional_rate_limits[]`, with `limit_name`, `metered_feature`, and nested `rate_limit.primary_window` / `secondary_window`
- Credits: `credits.balance`, `credits.has_credits`, `credits.unlimited`, `credits.overage_limit_reached`, `credits.approx_cloud_messages`, `credits.approx_local_messages`
- Other observed quota fields: `rate_limit_reset_credits.available_count`, `spend_control.reached`, `spend_control.individual_limit`, `rate_limit_reached_type`, `code_review_rate_limit`

Observed `additional_rate_limits[]` count: 1. Fixture keeps real model/limit names, but identity fields are redacted.

## Gemini Field Shape

Captured fixtures:

- `GQuotaKit/Tests/GQuotaKitTests/Fixtures/gemini-loadCodeAssist.json`
- `GQuotaKit/Tests/GQuotaKitTests/Fixtures/gemini-retrieveUserQuota.json`

`loadCodeAssist` returned a project successfully after refresh. The real project id was replaced with `proj-FAKE123`.

Relevant observed `loadCodeAssist` fields:

- `cloudaicompanionProject`
- `currentTier.id`, `currentTier.name`, `currentTier.description`, `currentTier.userDefinedCloudaicompanionProject`, `currentTier.usesGcpTos`, `currentTier.privacyNotice`
- `allowedTiers[]` with the same tier shape plus `isDefault`
- `gcpManaged`
- `manageSubscriptionUri`

Relevant observed `retrieveUserQuota` fields:

- `buckets[]`
- Per bucket: `modelId`, `tokenType`, `remainingFraction`, `resetTime`

Observed `buckets[]` count: 4.

## Refresh Token Rotation

- OpenAI/Codex: `codex exec` lightweight command exited 0; refresh token hash was unchanged in this one check. MVP still keeps active token refresh disabled; broader rotation validation is required before enabling it.
- Gemini: `gemini -p` lightweight command exited 0; refresh token hash was unchanged in this one check. MVP still keeps active token refresh disabled; broader rotation validation is required before enabling it.

## Sanitization

- Real email values replaced with `user@example.com`.
- Real Gemini project id replaced with `proj-FAKE123`.
- Real OpenAI account/user identifiers replaced with fake placeholders.
- Any token-like values are replaced with `REDACTED`; no raw credential fields are intentionally stored in fixtures.
