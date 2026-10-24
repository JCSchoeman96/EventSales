# Two-Stage Feature-Pack Workflow Amendment

## Purpose

EventSales may prepare detailed planning and prompt packs ahead of implementation so product and architecture decisions can be reviewed early without allowing stale code execution.

## Stage 1 — Planning pack

A planning pack may be created while a predecessor slice is still active when:

- its purpose is repository reconnaissance and implementation planning only;
- it records an exact planning baseline;
- it identifies assumptions that must be refreshed;
- it contains no authority to edit, merge, deploy, migrate or change external systems;
- the implementation WIP limit remains one active slice.

The planning pack may be independently reviewed and supplied to an agent. The resulting implementation plan may also be reviewed before the predecessor closes.

Use a pre-1.0 semantic version such as `0.9.0` and mark `execution_authority: false`.

## Stage 2 — Activation supplement

Before implementation begins, a separate activation gate must refresh:

- exact current `main` SHA;
- all material repository drift;
- predecessor certification and production evidence;
- final file inventory;
- migrations, constraints, indexes and queues;
- deployment and external-system facts;
- the exact scope approved from the reviewed plan;
- final stop conditions.

The activation supplement returns one of:

- `APPROVE`;
- `REFRESH REQUIRED`;
- `BLOCKED`.

Only `APPROVE` authorises implementation. It does not authorise merge or deployment.

## WIP

Multiple future planning packs may be prepared and reviewed, but only one implementation slice and one production-validation slice may be active at a time.

## Immutability

Issued planning ZIPs remain immutable. Material planning changes create a new pre-1.0 version. The activation supplement is separately versioned and hashed; it does not silently mutate the reviewed planning ZIP.