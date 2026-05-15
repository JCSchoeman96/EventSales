# Slice 5.1 — Raw Body Signature and Replay Guard

## Task
Implement raw-body WooCommerce webhook signature verification and replay-guard metadata handling.

## Objective
Prevent forged or incorrectly verified webhook requests from entering the ingestion pipeline.

## Output
- `lib/event_sales/ingestion/security/raw_body_reader.ex`
- `lib/event_sales/ingestion/security/webhook_signature.ex`
- `lib/event_sales/ingestion/security/webhook_replay_guard.ex`
- controller tests with exact raw-body signatures

## Strict Tests
- Valid HMAC over raw body passes.
- Re-encoded JSON with same semantic content but different bytes does not falsely pass.
- Missing/wrong signature rejected.
- Wrong path token rejected.
- Invalid request stores only failure metadata.
- Duplicate delivery is idempotent, not double processed.

## Note
Do not verify against decoded JSON. Do not log secrets or full invalid payloads.
