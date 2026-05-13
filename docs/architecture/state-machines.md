# State Machine Rules

Slice `0.4` proves that `AshStateMachine` is wired correctly by using the isolated `EventSales.AshBaseline.Resources.StateMachineProof` resource. That proof resource is not a business contract and exists only to validate extension behavior in this repo.

Real business ownership remains unchanged:

- Slice `4.0` introduces the first real `Order` and `OrderItem` status machines
- Slice `8.6` hardens `WebhookEvent`, `SyncRun`, `CsvImportBatch`, mapping flows, and the broader transition rules

External source sync actions must still be explicit and auditable when the real business resources adopt state transitions.
