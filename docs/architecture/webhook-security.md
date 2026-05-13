# Webhook Security

## Rules

- Verify WooCommerce webhook signatures against the exact raw request body bytes.
- Do not verify against decoded and re-encoded JSON.
- Use a secondary path token only as defense-in-depth, not as a replacement for HMAC verification.
- Reject invalid signatures and store only minimal metadata in `WebhookDeliveryFailure`.
- Never log webhook secrets, API keys, authorization headers, cookies, or full invalid payloads.

## Required Tests

- valid raw-body HMAC passes
- wrong signature rejected
- missing signature rejected
- re-encoded JSON does not falsely pass
- invalid request does not store full body
