# VS-26E.0 Failure Matrix

| Failure | Durable/observed state | Retry? | Operator action | Certification |
|---|---|---:|---|---|
| Dirty/stale checkout | local mismatch | No | refresh pack/baseline | Blocked |
| Railway SHA unknown | topology gap | No | resolve read-only | Blocked |
| Direct migration path unknown | topology gap | No | inspect variable topology safely | Blocked |
| Duplicate active runs | DB query rows / migration failure | No automatic fix | investigate; no status rewrites | Blocked |
| Retry columns/constraints missing | schema mismatch | Deployment/migration only after approval | diagnose migration state | Not certified |
| Active-run index missing/invalid | schema mismatch | Migration/corrective PR | stop | Not certified |
| Unexpected active/retryable Oban job | queue conflict | Maybe after understanding | wait/cancel only via approved operation | Blocked |
| Feed disabled/misconfigured | safe config error | After approved config fix | correct without exposing values | Not certified |
| Feed unauthorized/forbidden | bounded error | After secret pairing fix | verify clocks/secret presence | Not certified |
| Feed timeout/rate limit/server/transport | `retry_scheduled` or failure | Worker bounded retry | observe attempts; review source | Conditional/blocked |
| Pagination limit | bounded error | No blind limit increase | inspect source size/config | Blocked |
| Invalid feed/schema/json | bounded error | After source/code correction | separate corrective work | Blocked |
| Worker claim race | discard/retry-safe | Built-in | verify owner/state | May continue if truthful |
| Findings persistence failure | transaction rollback/failure | bounded worker behavior | diagnose DB/code | Not certified |
| Blocking finding | ready preview or queue rejection | No Apply | resolve/revoke/no-go | Not certified for Apply |
| Missing snapshot | Apply rejected | No | stop | Blocked |
| Hash mismatch | Apply rejected | No | re-review current run/hash | Blocked |
| Run not ready/cancelled | Apply discarded/rejected | No | do not rewrite | No Apply |
| Apply transaction failure | run failed or unchanged | No blind retry | diagnose separate issue | Not certified |
| Cache/PubSub failure post-commit | durable catalog may be applied | bounded repair | verify DB; repair read model separately | Conditional |
| Recovery jobs unexpectedly large | Oban backlog | bounded investigation | stop further actions | At risk |
| Secret/PII/raw payload leak | evidence incident | N/A | contain/rotate/escalate | Blocked |
| Catalog mismatch after Apply | durable inconsistency | No ad-hoc repair | separate corrective plan | Not certified |
