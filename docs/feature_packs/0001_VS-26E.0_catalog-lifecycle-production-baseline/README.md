# EventSales VS-26E.0 Execution Pack

**Slice:** VS-26E.0 — Catalog Lifecycle Deployment and Baseline Certification<br>
**Pack version:** 1.2.1<br>
**Repository:** `JCSchoeman96/EventSales`<br>
**Authorised review baseline:** `561deaf14a2460e1246c3853c9e595567ace48f8`
**Original planning baseline:** `050d66e88d55270655833cd9c9b51476a4bfefeb`<br>
**GitHub tracker:** `#114`<br>
**Linear historical parent:** `JC-105`<br>
**Linear current planning gate:** `JC-108`
**Remote supersession/review registration:** required before activation<br>
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

## Canonical PR merge rule

PR #117 must remain open and unmerged through independent pack review (`JC-107`), planning/reconnaissance (`JC-108`), and plan review (`JC-109`). The planning agent uses this ZIP against the authorised `main` baseline; it does not need the pack files merged into `main`. Because any PR merge deploys to Railway and runs the configured pre-deploy migration/bootstrap path, merging PR #117 is a production deployment boundary and requires explicit JC-109 authorisation.


## Current-main refresh

GitHub comparison proves current `main` is `561deaf14a2460e1246c3853c9e595567ace48f8`, five commits ahead of the original planning baseline. The changed paths are planning documents, slice ZIP artefacts, and file moves; no runtime, configuration, migration, or test files changed in that compare.

GitHub combined status reports the Railway deployment context as failing for current `main`. The active Railway deployment SHA and actual migration state remain unknown. This pack therefore authorises planning only until read-only Railway evidence resolves that state.

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
- `PATCH_NOTES.md` — v1.2.1 registration hygiene correction and inherited v1.2.0 contract corrections.
- `checksums.sha256` — SHA-256 for every pack file except itself.

## Authority

GitHub `main` and reviewed PRs remain canonical technical truth. This ZIP is an immutable execution capsule. If `main` materially advances or a pack assumption changes, stop and issue a new semantic pack version.

Version 1.2.1 supersedes v1.2.0. The v1.2.0 and v1.1.0 ZIPs remain immutable historical evidence, and v1.0.0 remains superseded. Version 1.2.1 is the only pack approved by this correction for registration and further planning, subject to remote GitHub/Linear registration and activation refresh.
