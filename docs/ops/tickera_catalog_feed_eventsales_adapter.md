# Tickera Catalog Feed EventSales Adapter

VS-26D lets EventSales catalog dry-runs consume the VS-26C WordPress Tickera Catalog Feed through the existing `DiscoverySource` seam.

This is a feed-consumer adapter only. It does not implement auto-apply, scheduled sync, unmapped alert resolution, Woo order catch-up, webhook shaping, CSV import changes, payment/scanner changes, `OrderUpserter` changes, or `MappingResolver` changes.

## Deployment Order

1. Deploy and activate the VS-26C WordPress plugin.
2. Configure `EVENTSALES_TICKERA_CATALOG_SECRET` in WordPress.
3. Configure the matching `TICKERA_CATALOG_FEED_SECRET` in EventSales.
4. Enable `TICKERA_CATALOG_FEED_ENABLED=true`.
5. Run a `product_id` dry-run before trying the full feed.

## Runtime Configuration

Use dedicated feed credentials. Do not reuse WooCommerce REST consumer keys or secrets.

Required when enabled:

```text
TICKERA_CATALOG_FEED_ENABLED=true
TICKERA_CATALOG_FEED_BASE_URL=https://voelgoed.co.za
TICKERA_CATALOG_FEED_SECRET=<shared feed HMAC secret>
```

Optional:

```text
TICKERA_CATALOG_FEED_TIMEOUT_MS=5000
TICKERA_CATALOG_FEED_PER_PAGE=100
TICKERA_CATALOG_FEED_MAX_PAGES=50
```

If `TICKERA_CATALOG_FEED_ENABLED=true` in production and either `TICKERA_CATALOG_FEED_BASE_URL` or `TICKERA_CATALOG_FEED_SECRET` is missing, the release raises during boot. If the feed is disabled or unset, EventSales does not configure the WordPress feed discovery adapter.

## Supported Scopes

Admins queue these from `/admin/catalog-sync`; EventSales fetches the feed in the Oban catalog sync worker, not from LiveView render.

```elixir
%{"kind" => "wordpress_feed", "mode" => "full"}
%{"kind" => "wordpress_feed", "product_id" => 109740}
%{"kind" => "wordpress_feed", "variation_id" => 109741}
%{"kind" => "wordpress_feed", "event_id" => 109316}
%{"kind" => "wordpress_feed", "updated_since" => "2026-07-05T10:00:00Z"}
```

Exactly one mode is allowed. Mixed scopes such as product plus event are rejected as invalid scope.

Full-feed and incremental scopes fetch all pages before handing `events`, `catalog_rows`, and `source_snapshot_at` to the existing catalog planner. Page-at-a-time normalization is not allowed because it can produce false findings for events whose rows are on later pages.

Manual JSON scopes remain the rollback and debug path. `ConfiguredDiscoverySource` dispatches `manual_rows` to `ManualRowsDiscoverySource` before checking the configured adapter.

## Auth Contract

Requests are signed to match VS-26C:

```text
METHOD + "\n" +
PATH + "\n" +
CANONICAL_QUERY + "\n" +
TIMESTAMP
```

Headers:

```text
X-EventSales-Timestamp: <unix timestamp>
X-EventSales-Signature: v1=<hex_hmac_sha256>
```

Canonical query params are scalar-only, nil values are dropped, keys are sorted, and values are RFC3986 percent-encoded. `page` and `per_page` are included in the signature.

EventSales must not log the shared secret, full signature, raw headers, raw response bodies, or URLs containing signed query params.

## Error Mapping

The adapter and client return safe atoms. The catalog sync worker stores bounded admin-visible strings:

```text
misconfigured -> catalog_feed_misconfigured
unauthorized -> catalog_feed_unauthorized
forbidden -> catalog_feed_forbidden
timeout -> catalog_feed_timeout
pagination_limit -> catalog_feed_pagination_limit
invalid_feed_response / invalid_json -> invalid_catalog_feed_response
rate_limited -> catalog_feed_rate_limited
server_error -> catalog_feed_server_error
transport_error -> catalog_feed_transport_error
```

Errors never include URLs, secrets, signatures, headers, or raw response bodies.

## Staging Smoke Test

1. Disable `TICKERA_CATALOG_FEED_ENABLED` and confirm manual JSON dry-runs still queue.
2. Enable the feed with matching WordPress/EventSales secrets.
3. Queue a WordPress feed product dry-run for a known product ID.
4. Queue a variation dry-run for a known variation ID.
5. Queue an updated-since dry-run with a strict RFC3339 timestamp.
6. Confirm a bad secret produces `catalog_feed_unauthorized`.
7. Confirm the dry-run preview uses the existing planner output and apply button.
8. Confirm no order/customer/payment/token/raw payload fields appear in logs or previews.

## Rollback

Unset or disable `TICKERA_CATALOG_FEED_ENABLED` and restart EventSales. Manual JSON dry-runs remain available from `/admin/catalog-sync`.

## Validation

Run:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
bash scripts/check_no_web_woocommerce_refs.sh
mix test
mix assets.build
bash scripts/local_ci.sh
```
