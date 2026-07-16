# EventSales VS-26E.0 Execution Pack

**Slice:** VS-26E.0 — Catalog Lifecycle Deployment and Baseline Certification  
**Pack version:** 1.0.0  
**Repository:** `JCSchoeman96/EventSales`  
**Authorised baseline:** `050d66e88d55270655833cd9c9b51476a4bfefeb`  
**GitHub tracker:** `#114`  
**Linear parent:** `JC-105`  
**Linear active gate:** `JC-106`  
**Linear review gate:** `JC-107`

## Purpose

This immutable pack prepares a controlled, evidence-driven certification of the Catalog Sync lifecycle already merged in PR #111. It does not add a feature. It proves that the merged lifecycle, migrations, Railway topology, signed WordPress catalog feed, dry-run findings, exact snapshot/hash gate, and optional human-approved Apply path work safely against the production source.

## Agent hand-off rule

The first agent hand-off is **planning/reconnaissance only**:

1. Validate the clean checkout and exact baseline.
2. Inspect every mandatory file in `FILE_INVENTORY.md`.
3. Verify repository assumptions against current code.
4. Identify Railway/operator facts that remain unknown.
5. Produce the execution plan and stop.
6. Do not change code, deploy, migrate, queue Catalog Sync, Apply a plan, or alter production data.

Later execution requires explicit approval through Linear `JC-109` and must follow the reviewed runbooks.

## Pack contents

- `VS-26E.0-FEATURE_PACK.md` — full contract.
- `CODING_AGENT_PROMPT.md` — reusable planning-first prompt.
- `REVIEWER_PROMPT.md` — independent pack/plan/evidence review prompt.
- `TOON_PROMPTS.md` — compact stage prompts.
- `ACCEPTANCE_CHECKLIST.md` — gated acceptance list.
- `FILE_INVENTORY.md` — exact repository inspection and scope map.
- `REPO_BASELINE.json` and `pack.json` — machine-readable metadata.
- report and Linear templates.
- `runbooks/` — preflight, deployment, dry-run, Apply, rollback, and failure procedures.
- `evidence/EVIDENCE_TEMPLATE.md` — redacted evidence structure.
- `checksums.sha256` — SHA-256 for every pack file except itself.

## Authority

GitHub `main` and reviewed PRs remain canonical technical truth. This ZIP is an immutable execution capsule. If `main` materially advances or a pack assumption changes, stop and issue a new semantic pack version.
