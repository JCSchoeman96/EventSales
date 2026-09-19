# VS-26E.0 v1.2.1 Patch Notes

## Historical artefacts

The following ZIPs remain immutable historical evidence and must not be modified:

- `EventSales_VS-26E.0_v1.1.0_050d66e8.zip` — SHA-256 `a7cdbef20fdae4e1e2836820a894408a7c5a2d3bd0fe664fe95a29725a708f9d`.
- `EventSales_VS-26E.0_v1.2.0_561deaf1.zip` — SHA-256 `eacd57fe0da1ed6a827bfb0d72a093de4803be56b1955c16433ef1022e533497`.

## Why v1.2.1 exists

Registration-only execution on 19 July 2026 found seven checksum-covered trailing-space Markdown hard breaks in `README.md`. Retaining them caused `git diff --check` to fail; deleting them directly would have broken byte-for-byte fidelity with v1.2.0 and invalidated its internal checksum.

Version 1.2.1 resolves the conflict without weakening the repository quality gate:

1. Each of the seven trailing-space hard breaks is replaced with an explicit `<br>` marker.
2. The intended rendered line breaks are preserved.
3. Pack-version, supersession, ZIP-filename, and registration metadata are refreshed to v1.2.1.
4. Internal checksums are regenerated.
5. A new immutable ZIP and external SHA-256 are generated.

## Contract semantics unchanged

All substantive v1.2.0 review corrections remain unchanged, including:

- the review baseline `561deaf14a2460e1246c3853c9e595567ace48f8`;
- the Railway failure and unknown-active-SHA activation blockers;
- removal of the unsupported finding-payload hard-bound claim;
- full-feed performance and observed-size evidence requirements;
- the exact successor certificate fields;
- the requirement for remote GitHub/Linear registration before activation.

No runtime code, dependency, migration, configuration, WordPress setting, production job, Catalog Sync dry-run, Apply, merge, deployment, or production access is authorised by this patch.
