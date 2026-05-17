# Slice 8.5 Missing Catalog Mapping Recovery Worker Plan v2

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Recover order items left in `pending_mapping_resolution` when WooCommerce order webhooks arrive before product metadata or mapping is ready.

**Architecture:** `MissingCatalogResolutionWorker` is the only new WooCommerce REST caller. It fetches bounded product metadata through `WooCommerceClient`, writes informational metadata to an ETS-backed `ProductMetadataCache`, then asks `MissingCatalogResolver` to retry local mapping and mark still-unmapped rows through existing Ash actions.

**Tech Stack:** Elixir, Ash/AshPostgres, Oban, supervised GenServer + ETS, existing WooCommerce REST client/rate limiter/circuit breaker.

---

## Summary

- Complete existing placeholders:
  - `EventSales.Ingestion.Workers.MissingCatalogResolutionWorker`
  - `EventSales.Catalog.MissingCatalogResolver`
  - `EventSales.Catalog.ProductMetadataCache`
- Keep `MappingResolver` pure/local. Do not call WooCommerce REST from web modules, controllers, LiveViews, components, or `MappingResolver`.
- Use ETS for metadata cache in Slice 8.5 with keys `{source_system_id, woo_product_id, woo_variation_id}` and a 10-30 minute TTL.
- `ProductMetadataCache` is informational only. Cached metadata must never decide `event_id` or `ticket_type_id`, and no code in this slice may create `ProductMapping`.

## Public Interfaces

- `ProductMetadataCache`
  - `start_link(opts \\ [])`
  - `get(source_system_id, woo_product_id, woo_variation_id \\ nil) :: {:ok, metadata} | :miss`
  - `put(metadata, opts \\ []) :: :ok | {:error, :invalid_metadata}`
  - `invalidate(source_system_id, woo_product_id, woo_variation_id \\ nil) :: :ok`
  - `cleanup_expired() :: :ok`
  - `reset_for_test!() :: :ok`
  - Metadata shape: `%{source_system_id:, woo_product_id:, woo_variation_id:, name:, product_type:, status:, fetched_at:, expires_at:}` with nullable `woo_variation_id`, `product_type`, and `status`.
  - Store no credentials, auth headers, raw WooCommerce responses, response bodies, customer data, or secrets.

- `MissingCatalogResolver`
  - `recover_product(source_system_id, woo_product_id, woo_variation_id, opts \\ [])`
  - Returns `{:ok, %{mapped: non_neg_integer(), marked_unmapped: non_neg_integer(), unchanged: non_neg_integer()}} | {:error, term()}`
  - Reads matching pending `OrderItem` rows by loaded order source/product/variation.
  - Retries local mapping through `OrderItemMapper.map_item/1`.
  - Marks still-pending rows `:unmapped` using the existing `OrderItem` Ash `:mark_unmapped` action.
  - Must not create `ProductMapping`.

- `MissingCatalogResolutionWorker`
  - Oban worker in `:webhooks` queue, `max_attempts: 3`.
  - Args: `%{"source_system_id" => id, "woo_product_id" => id, "woo_variation_id" => id_or_nil}`.
  - Unique only across active states: `available`, `scheduled`, `executing`, `retryable`.
  - Do not include `completed` in uniqueness states.
  - Cache hit skips REST fetch and runs resolver.
  - Cache miss calls configured client `Application.get_env(:event_sales, :woocommerce_client, WooCommerceClient).fetch_product/2`.
  - Slice 8.5 fetches product metadata by `woo_product_id` only. If `woo_variation_id` is present, cache the fetched product metadata under the product+variation key as recovery context, not true variation metadata.
  - Do not call a WooCommerce variation endpoint in this slice.
  - `:not_found` marks matching pending items unmapped.
  - `:rate_limited`, `:server_error`, `:timeout`, `:transport_error`, `:queue_timeout`, and `:circuit_open` return `{:error, reason}` for Oban retry.
  - `:misconfigured`, `:unauthorized`, `:forbidden`, and `:invalid_request` discard without mutating pending rows except low-cardinality telemetry.

## Implementation Changes

- Supervise `ProductMetadataCache` in `EventSales.Application` before Oban.
- Add telemetry helper names to `EventSales.Telemetry`:
  - `[:event_sales, :catalog, :missing_catalog, :recovery, :start]`
  - `[:event_sales, :catalog, :missing_catalog, :recovery, :stop]`
  - `[:event_sales, :catalog, :missing_catalog, :recovery, :exception]`
  - `[:event_sales, :catalog, :product_metadata_cache, :hit]`
  - `[:event_sales, :catalog, :product_metadata_cache, :miss]`
  - `[:event_sales, :catalog, :product_metadata_cache, :put]`
- Telemetry metric metadata must stay low-cardinality:
  - `source: :woocommerce`
  - `result: :mapped | :marked_unmapped | :unchanged | :retryable_error | :discarded`
  - `reason: atom`
  - `cache: :hit | :miss | :put`
- Do not include `source_system_id`, `woo_product_id`, `woo_variation_id`, `order_item_id`, or `job_id` as telemetry metric tags. Use bounded logs for debugging IDs if needed.
- Update boundary tests so `WooCommerceClient` is allowed only under ingestion clients and `MissingCatalogResolutionWorker`; all web modules and `MappingResolver` remain forbidden.
- Do not add a second REST limiter in the worker. `WooCommerceClient` owns REST concurrency, rate limiting, circuit breaking, timeout, and typed errors.

## Task Plan

1. Product metadata cache
   - Add `test/event_sales/catalog/product_metadata_cache_test.exs`.
   - Prove miss before write, idempotent put, bounded stored fields, TTL expiry as `:miss`, key-specific invalidate, and `reset_for_test!/0`.
   - Implement the supervised ETS GenServer and wire it into `EventSales.Application`.

2. Missing catalog resolver
   - Add `test/event_sales/catalog/missing_catalog_resolver_test.exs`.
   - Prove it maps affected pending rows when a local mapping now exists, leaves already mapped/non-ticket/ignored rows unchanged, marks still-pending matching rows unmapped, and is safe to run twice.
   - Prove it never creates `ProductMapping`.

3. Recovery worker
   - Add `test/event_sales/ingestion/missing_catalog_resolution_worker_test.exs`.
   - Use a fake configured Woo client module, not real HTTP.
   - Prove cache miss fetches product metadata through the configured client boundary, cache hit skips the client, fetched metadata is cached, affected item is remapped, `:not_found` marks unmapped, transient errors retry, auth/config errors discard without mutation, and duplicate active jobs are safe.
   - Do not re-test the hard REST concurrency cap here; existing Slice 7.5 client tests own it. Add only a small integration check with `WooCommerceClient` fake transport if needed to prove the worker uses the client boundary.

4. Integration and boundaries
   - Add or adjust `test/event_sales/sales/order_upserter_test.exs` to assert unknown products still create pending items.
   - Update `test/event_sales/domain_boundaries_test.exs` for the new worker-only REST allowance.
   - Run `bash scripts/check_no_web_woocommerce_refs.sh`.

## Test Plan

Focused checks:
- `mix test test/event_sales/catalog/product_metadata_cache_test.exs`
- `mix test test/event_sales/catalog/missing_catalog_resolver_test.exs`
- `mix test test/event_sales/ingestion/missing_catalog_resolution_worker_test.exs`
- `mix test test/event_sales/sales/order_upserter_test.exs`
- `mix test test/event_sales/domain_boundaries_test.exs`
- `bash scripts/check_no_web_woocommerce_refs.sh`

Required completion gates:
- `mix format --check-formatted`
- `mix test`
- `mix quality.fast`
- Before PR update/open: `mix quality.pr`
- Before final ready state: `mix quality.ci`

## Assumptions

- Slice 8.5 does not auto-create `ProductMapping`; admin/catalog workflows still own mapping creation.
- Woo product metadata cannot safely decide which EventSales event/ticket type a product belongs to.
- Product metadata recovery provides context and triggers a local mapping retry only.
- Product variation REST endpoints are out of scope for this slice.
