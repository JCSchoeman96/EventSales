# Slice 14.0 — Reconciliation and Sync Runs

## Purpose

Catch missed/changed WooCommerce orders without hurting WordPress.

## Implementation scope

```text
SyncRun, SyncCursor, ReconcileOrdersWorker, scoped sync, shallow/deep sync, pause behavior, sync UI.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 14.0 — Reconciliation and Sync Runs for EventSales. |
| Objective | Catch missed/changed WooCommerce orders without hurting WordPress. |
| Output | SyncRun, SyncCursor, ReconcileOrdersWorker, scoped sync, shallow/deep sync, pause behavior, sync UI. |
| Note | Never full-scan during peak. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Manual sync requires event/date scope
- Cursor stored/resumed
- Modified orders only
- REST concurrency max 2
- Pause on 429/timeouts/500s
- Counts/failures recorded
- Confirmation/rate limit/audit

## Architecture guardrails

Never full-scan during peak.

## Completion checklist

- [ ] Files/modules for this slice are created in the approved folder structure.
- [ ] Relevant Ash resources/actions/policies are implemented only where this slice owns them.
- [ ] Oban worker behavior is tested if this slice includes async work.
- [ ] LiveView/controller behavior is tested if this slice includes web UI or intake.
- [ ] Telemetry is emitted where the slice touches ingestion, REST, Oban, cache, or hot state.
- [ ] Cache invalidation is handled where durable data changes affect dashboard state.
- [ ] The global acceptance command passes.

## Stop condition

Stop and report if implementing this slice would require a direct WooCommerce call from LiveView, an untested state transition, a hardcoded secret, a Redis-as-truth shortcut, or a skipped policy/test.
