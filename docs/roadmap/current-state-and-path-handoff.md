# EventSales Current State & Path Handoff

| Field | Value |
|---|---|
| Document | Authoritative EventSales program checkpoint / path handoff |
| Status | Active handoff contract |
| Scope | Program state after Phase 5D; Path 1 activation; Path 2 pause/resume |
| Authority | This document wins for current program priority and Path 2 resume procedure |
| Durable Phase 5D evidence | `docs/phase-5d/native-v3-e2e-run-report.md` |
| Historical Phase 5D certification commit | `c286fd0e647199a261b6ef2ec3791617dacb5834` |
| Last updated | 2026-08-09 |

### Revision log

- `v1` — initial authoritative Path 1 / Path 2 handoff after Phase 5D COMPLETE

### Conflict rule

```text
VERIFIED FACT from merged Phase 5D report and this checkpoint
wins over chat history and speculative reconstruction

FUTURE PLAN (Path 1 milestones, Path 2 resume work)
must not be treated as completed work
```

---

## 1. Purpose

This document is the authoritative handoff between:

```text
completed/shared foundation + Path 2 catalogue foundation work
```

and:

```text
new active Path 1 management analytics work
```

It exists so future developers and agents do **not**:

* reconstruct program history from chat;
* continue Phase 5E accidentally;
* rerun the certified Phase 5D discovery;
* rebuild source identity incorrectly;
* treat unfinished catalogue automation as a blocker for management analytics;
* create unnecessary long-lived Path 1 / Path 2 repository branches.

Both paths continue on **one** `main` branch.

```text
PATH 1 DOES NOT WAIT FOR PHASE 5E.
```

Phase 5E belongs to the paused catalogue / source-risk automation track (Path 2).

---

## 2. Current Program State

```text
Current verified Phase 5D-complete main:
c286fd0e647199a261b6ef2ec3791617dacb5834

Phase 5C:
COMPLETE

Phase 5D:
COMPLETE

Certified native-v3 run:
0814f5db-67c0-4371-8742-0fa75dbc627e

Phase 5D result:
TECHNICAL_EXECUTION = PASS
DATA_REVIEW = BLOCKING_FINDINGS_PRESENT

Phase 5E:
UNLOCKED BUT INTENTIONALLY PAUSED

Active product priority:
PATH 1 — TRUSTED MANAGEMENT ANALYTICS
```

Program tracks:

```text
SHARED FOUNDATION
Status: ESTABLISHED

PATH 1 — MANAGEMENT ANALYTICS
Status: ACTIVE
Next milestone: M1 Truth & Identity Contract

PATH 2 — AUTOMATIC SYNC / CATALOGUE AUTOMATION
Status: PAUSED AT CERTIFIED CHECKPOINT

Path 2 checkpoint:
Phase 5D COMPLETE

Path 2 next task when resumed:
Phase 5E-00 — Exact Finding Inventory
```

---

## 3. What Has Been Completed

Important technical achievements already established (summary, not PR-by-PR history):

```text
✓ native-v3 WordPress producer implemented and certified
✓ bounded WordPress catalogue/event pagination
✓ bounded native evidence transport
✓ source-system identity
✓ event/product source semantics
✓ product/variation semantic separation
✓ variation-parent integrity work
✓ canonical source-risk normalization
✓ FindingPolicy
✓ deterministic plan.v3
✓ durable source-risk findings
✓ review-only native-v3 mode
✓ no native v3 AutoApply
✓ no Apply
✓ zero unintended catalogue/mapping writes
✓ real Local WordPress → Phoenix native-v3 E2E run certified
✓ durable Phase 5D run report merged
```

**VERIFIED FACT:** Phase 5C and Phase 5D are complete.

**VERIFIED FACT:** Phase 5E is **not** complete. It is unlocked but intentionally paused.

---

## 4. Shared Foundation Already Established

The following is shared architectural foundation. Path 1 must reuse these concepts and patterns rather than inventing parallel identity systems:

```text
source_system_id

source-scoped external identities

Tickera external event identity

WooCommerce parent product identity

WooCommerce variation identity

variation → exact parent validation

authoritative event-product relationships

bounded source pagination

source/discovery snapshot identity

idempotent external identities

fail-closed conflicts

no fuzzy/name-based authority
```

This foundation materially reduces Path 1 risk: management analytics can start from already-certified identity and source-scoping rules instead of rediscovering them.

Canonical references:

* `docs/phase-5b/source-risk-domain-model.md`
* `docs/phase-5b/source-risk-contract.md`
* `docs/phase-5b/phase-5c-implementation-boundary.md`
* `docs/phase-5d/native-v3-e2e-run-report.md`

---

## 5. Path 2 Work Completed So Far

Phase 5 catalogue / source-risk work primarily belongs to Path 2 (future automatic sync / catalogue automation).

```text
Phase 5C:
native-v3 producer/parser/normalization/policy/planning implementation complete

Phase 5D:
one real native-v3 E2E run completed and certified
```

Certified run:

```text
0814f5db-67c0-4371-8742-0fa75dbc627e
```

Certified result:

```text
TECHNICAL_EXECUTION = PASS
DATA_REVIEW = BLOCKING_FINDINGS_PRESENT
```

The pipeline technically succeeded while correctly surfacing source-risk blockers that require human disposition review. Those blockers do **not** reverse technical PASS.

---

## 6. Exact Path 2 Pause Point

Durable Phase 5D pause-point state (from the merged report):

```text
canonical facts = 213

findings = 119
blocking = 112
warning = 7

proposed actions = 66

event create = 10
ticket_type create = 28
product_mapping create = 28
```

Finding distribution:

```text
source_risk.add_on                    21
source_risk.bundle                    21
source_risk.membership                21
source_risk.payment_plan              21
source_risk.subscription_unresolved   19
source_risk.subscription               2
contract.contract_violation            7
variation_mapping_required             7
```

Plan hash:

```text
6add9ef1a6eaf1cef1fe10681fb9a70c1fb07cdfac125db12ea62c490e94d310
```

These findings remain **intentionally unresolved** pending Phase 5E disposition review. Do not “finish” them as part of Path 1 work.

---

## 7. Path 2 Work Explicitly Paused

```text
PAUSED — DO NOT CONTINUE WITHOUT EXPLICIT PATH 2 AUTHORIZATION
```

Do **not** continue any of the following while Path 1 is the active priority:

```text
Phase 5E finding disposition

manual catalogue Apply work

AutoApply work

automatic WordPress event creation/synchronization

automatic catalogue synchronization

automatic product/variation relationship mutation

owner automation

future safe-class Apply automation
```

Agents working on Path 1 must not opportunistically continue these tasks.

---

## 8. Active Priority — Path 1

The active product objective is now to provide management with a production-ready, read-only tool for accurate event sales, sales movement, velocity and marketing decision support.

Management requirements:

```text
trusted
read only
fast
accurate
easy to interpret
clear freshness
clear reconciliation/data-quality state
```

Management does **not** need catalogue Apply or AutoApply.

```text
PATH 1 DOES NOT WAIT FOR PHASE 5E.
```

---

## 9. Path 1 Immediate Goal

Initial Path 1 workflow (**FUTURE PLAN**, not yet implemented):

```text
OPERATOR RECEIVES/SELECTS TICKERA EVENT
        ↓
EventSales creates/links exact event
        ↓
Authoritative event products linked
        ↓
All valid variations linked to exact parents
        ↓
Historical sales imported
        ↓
Refunds/cancellations imported
        ↓
Financial totals reconciled
        ↓
ANALYTICS_READY
        ↓
Management dashboard
```

Critical sales-truth rule:

Historical sales may predate local EventSales event creation.

Local event creation timestamp is therefore **NOT** the beginning of sales truth.

---

## 10. Foundation Path 1 Must Reuse

Path 1 should reuse existing:

* source identity conventions;
* external event identity;
* Woo product identity;
* Woo variation identity;
* parent variation validation;
* source client patterns;
* bounded pagination concepts;
* fail-closed identity conflicts.

Do **not** rebuild parallel identity systems for analytics.

---

## 11. Boundaries Path 1 Must Not Inherit

Path 1 must remain simple.

Do **not** require the complete catalogue source-risk pipeline merely to calculate or read sales analytics.

Specifically, Path 1 should not unnecessarily route ordinary analytics identity through:

```text
FindingPolicy
→ Planner
→ Apply eligibility
→ AutoApply
```

unless an existing domain boundary genuinely requires it.

Path 1 requires:

```text
identity truth
sales truth
reconciliation truth
analytics truth
```

not catalogue automation authority.

---

## 12. Locked Architectural Invariants

```text
1. External numeric IDs are never globally unique.

2. source_system_id + external ID defines external identity.

3. Names, titles and SKUs are never authoritative relationship evidence.

4. Product/event conflicts fail closed.

5. A variation must belong to its exact source and exact parent product.

6. Variation semantics may not leak between siblings.

7. Historical sales preserve immutable source order/item/product/variation identities.

8. Sales may exist before the local EventSales event.

9. Unknown identity is never silently assigned.

10. Financial mismatches block ANALYTICS_READY.

11. Money uses Decimal / exact database numeric / integer minor units — never binary floating point.

12. Duplicate import/retry must not duplicate sales.

13. Management remains read-only.

14. AI may explain analytics but may not calculate authoritative financial metrics.

15. Apply and AutoApply remain independent of management analytics.
```

Related existing programme decisions (identity, completed-order sales recognition, freshness) remain recorded in `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md` and must not be silently weakened.

---

## 13. Current Certified Phase 5 Evidence

Durable evidence source:

`docs/phase-5d/native-v3-e2e-run-report.md`

Contract identity for the certified run:

```text
schema:
2026-08-07.v3

canonical contract:
source_risk.v3

producer:
2026-08-07.1

plan:
tickera_catalog_plan.v3

run:
0814f5db-67c0-4371-8742-0fa75dbc627e
```

Important safety outcome:

```text
AutoApply jobs = 0
Apply jobs = 0
catalogue/mapping writes = 0
```

Do not duplicate the full Phase 5D report here. Use that document as the durable evidence source.

Do **not** rerun Phase 5D merely to resume Path 2 or to obtain unpersisted raw page telemetry.

---

## 14. Path 1 Starting Sequence

Active Path 1 roadmap (**FUTURE PLAN**):

```text
M1 — Truth & Identity Contract

M2 — Operator Event Onboarding

M3 — Historical Sales Backfill

M4 — Financial Reconciliation

M5 — Analytics Read Model

M6 — Management Dashboard

M7 — Production Certification / Pilot
```

```text
CURRENT NEXT STEP:
M1
```

This checkpoint does **not** implement M1.

---

## 15. How To Resume Path 2 Later

```text
TO RESUME PATH 2:

1. Start from the THEN-CURRENT main branch.

2. Do NOT branch from the historical Phase 5D checkpoint and discard subsequent Path 1 work.

3. Read:
   - docs/roadmap/current-state-and-path-handoff.md
   - Path 2 automatic-sync planning document (when present in the repository)
   - docs/phase-5d/native-v3-e2e-run-report.md
   - relevant Phase 5B/5C contract documents

4. Verify that subsequent Path 1 changes have not invalidated locked source/catalogue identity invariants.

5. Do NOT rerun Phase 5D merely to resume work.

6. Use certified Phase 5D run:
   0814f5db-67c0-4371-8742-0fa75dbc627e

7. Resume at:
   Phase 5E-00 — Exact Finding Inventory

8. Continue Phase 5E disposition review before future Apply/AutoApply work.
```

Phase 5E-00 and later Path 2 work require **explicit Path 2 authorization**.

---

## 16. Repository / Git Checkpoint

```text
Historical Path 2 Phase 5D certification commit:
c286fd0e647199a261b6ef2ec3791617dacb5834
```

This SHA identifies the repository state when Phase 5D was completed.

It is a **historical certification point**, not a permanent development branch.

Do **not** create a long-lived divergent Path 1 / Path 2 branch model.

Both paths evolve through `main`.

This task is the documentation checkpoint only. No annotated Git tag is created by this document.

---

## 17. Program Status Summary

```text
EVENTSALES PROGRAM STATUS

SHARED FOUNDATION
ESTABLISHED

PATH 1 — TRUSTED MANAGEMENT ANALYTICS
ACTIVE

Current Path 1 task:
M1 — Truth & Identity Contract

PATH 2 — AUTOMATIC SYNC / CATALOGUE AUTOMATION
PAUSED

Certified Path 2 checkpoint:
Phase 5D COMPLETE

Path 2 resume point:
Phase 5E-00 — Exact Finding Inventory

Certified native-v3 run:
0814f5db-67c0-4371-8742-0fa75dbc627e

Do not resume Path 2 without explicit authorization.
```
