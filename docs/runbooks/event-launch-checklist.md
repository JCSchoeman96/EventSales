# Event Launch Checklist

Use this ordered gate before enabling live WooCommerce webhook cutover.

## 1. Code and CI

- [ ] `bash scripts/local_ci.sh` passed on the release commit
- [ ] `mix test --only launch_certification` passed
- [ ] `bash scripts/check_no_web_woocommerce_refs.sh` passed

## 2. Deploy proof

- [ ] `bash scripts/smoke_test_railway_release.sh` passed
- [ ] `bash scripts/cutover_dry_run.sh` passed
- [ ] `bash scripts/smoke_test_webhook_signature.exs` passed locally

## 3. Operational readiness

- [ ] Mapping review completed: [`mapping-review.md`](mapping-review.md)
- [ ] Backup timestamp recorded: [`database-backup-restore.md`](database-backup-restore.md)
- [ ] Oban backlog thresholds reviewed: [`oban-queue-backlog.md`](oban-queue-backlog.md)
- [ ] Reconciliation operator steps reviewed: [`reconciliation.md`](reconciliation.md)
- [ ] Incident and security runbooks reviewed

## 4. Cutover

- [ ] Follow [`live-webhook-cutover.md`](live-webhook-cutover.md)
- [ ] Confirm rollback steps are understood before switching WooCommerce webhook URL

## 5. Post-launch watch (first 30 minutes)

- [ ] `webhooks` queue depth stable in Oban Web
- [ ] No unexpected growth in discarded Oban jobs
- [ ] Reconciliation dashboard shows no critical missing-ingestion findings
- [ ] Dashboard totals move only on expected completed orders
