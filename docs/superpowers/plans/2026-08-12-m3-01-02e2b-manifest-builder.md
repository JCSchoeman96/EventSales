# M3-01/02E2B Production Manifest Builder + POST Activation Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Activate one authenticated, bounded Woo membership capture that owns its source continuation, persists every candidate into one E1 BUILDING manifest, commits only after source terminal confirmation, finalizes READY, and returns the first immutable E1 page.

**Architecture:** Harden EventSales_Woo_Order_Membership_Source into a one-shot source snapshot state machine with an internal confirmed cursor and one pending candidate. Add EventSales_Woo_Order_Manifest_Builder as the only source-to-E1 orchestration boundary; it owns the source-scoped MySQL named lock, five-second source capture budget, failure cleanup, and READY publication. Keep the REST controller limited to authentication, validation, builder invocation, and the shared E1 page response formatter.

**Tech Stack:** PHP 8 strict standalone WordPress integration, WooCommerce HPOS/legacy MySQL tables, WordPress wpdb, InnoDB REPEATABLE READ consistent snapshots, E1 immutable manifest store, standalone PHP harnesses, local WordPress/MySQL, and existing Mix quality commands.

---

## File map

Create:

- integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-manifest-builder.php — production source-to-E1 orchestration, source connection factory, source-scoped GET_LOCK, five-second budget, failure cleanup, and first READY page read.
- integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php — database-independent builder state, failure, lock, budget, and response-page tests using injected fakes.

Modify:

- integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-membership-source.php — remove arbitrary caller cursor authority and add replayable candidate/acknowledgement state.
- integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php — load the production source/builder, activate POST, inject a shared page formatter, and preserve HMAC-first ordering.
- integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php — migrate E2A capture calls to the acknowledged source API and add cursor, terminal, and commit adversarial assertions.
- integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php — replace the old POST-501 assumption with injected-builder response and authentication tests.
- integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-db-test.php — update the public POST expectation and E1 GET/response regression checks for the activated boundary.
- integrations/wordpress/eventsales-woo-order-index-feed/README.md — document POST activation, source D, internal continuation, five-second budget, replay/lock behavior, mode gates, and limit semantics.
- integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-contract.md — replace the E1-only POST-501 contract with the E2B public contract and retain E1 lifecycle/GET rules.
- integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof.md — document the source acknowledgement state machine, builder flow, and benchmark gate.

Do not modify:

- integrations/wordpress/eventsales-tickera-catalog-feed/
- any EventSales Elixir, SyncRun, SyncCursor, modified catch-up, M3-03+, or PR #188 files.

## Task 1: Write failing source-continuation tests

Files:

- Modify: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php
- Test target: integrations/wordpress/eventsales-woo-order-membership-source.php

- [ ] Step 1: Replace the proof helper arbitrary cursor call with the wished-for acknowledged API.

Change the proof capture loop from read_chunk with a caller-supplied cursor and local cursor assignment to this exact flow:

~~~
while (true) {
    $candidate = $adapter->read_next_candidate(
        EVENTSALES_PROOF_START,
        EVENTSALES_PROOF_CUTOFF,
        2
    );
    if (!($candidate['ok'] ?? false)) {
        throw new RuntimeException('source candidate failed');
    }

    if ($candidate['terminal'] === true) {
        $confirmed = $adapter->confirm_persisted($candidate);
        if (!($confirmed['ok'] ?? false)) {
            throw new RuntimeException('terminal confirmation failed');
        }
        break;
    }

    $appended = $store->append_items($manifest_id, $candidate['rows']);
    if (!($appended['ok'] ?? false)) {
        throw new RuntimeException('E1 append failed');
    }

    $confirmed = $adapter->confirm_persisted($candidate);
    if (!($confirmed['ok'] ?? false)) {
        throw new RuntimeException('source confirmation failed');
    }

    foreach ($candidate['rows'] as $row) {
        $captured[] = $row;
    }
}
~~~

The helper must never hold or pass a source cursor outside the adapter.

- [ ] Step 2: Add adversarial assertions for replay, jump rejection, and commit guards.

After opening a fresh adapter snapshot, add assertions equivalent to:

~~~
$candidate = $adapter->read_next_candidate(
    EVENTSALES_PROOF_START,
    EVENTSALES_PROOF_CUTOFF,
    2
);
$jumped = $candidate;
$jumped['candidate_next_id'] = (string) ((int) $candidate['candidate_next_id'] + 1000);

T::same(
    'arbitrary source continuation jump is rejected',
    false,
    $adapter->confirm_persisted($jumped)['ok'] ?? true
);
T::same(
    'unconfirmed candidate replays exactly',
    $candidate,
    $adapter->read_next_candidate(
        EVENTSALES_PROOF_START,
        EVENTSALES_PROOF_CUTOFF,
        2
    )
);
T::same(
    'source commit before candidate confirmation is rejected',
    false,
    $adapter->commit_snapshot()['ok'] ?? true
);
~~~

Use a separate fresh snapshot for the terminal guard: confirm every non-empty candidate, read the empty terminal candidate, assert commit fails before terminal confirmation, confirm the terminal candidate, and assert commit succeeds. Assert that an already-confirmed candidate cannot be acknowledged a second time.

- [ ] Step 3: Run the proof test and verify the failures are caused by the missing API.

Run:

~~~
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php --mode=hpos
~~~

Expected: the local harness either reports the new methods as undefined or fails the new cursor assertions; it must not silently pass. If local WordPress/MySQL variables are unavailable, preserve the test changes and use the database-independent builder red test in Task 3 for the first executable RED check.

- [ ] Step 4: Commit the failing-test checkpoint.

~~~
git add integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php
git commit -m "test: require acknowledged Woo source continuation"
~~~

## Task 2: Implement the source-owned continuation state machine

Files:

- Modify: integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-membership-source.php
- Test: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php

- [ ] Step 1: Replace arbitrary cursor fields with one-shot adapter state.

Add these properties and reset them only when the adapter is opened for its one source attempt:

~~~
private bool $snapshot_used = false;
private string $confirmed_cursor = '0';
/** @var array<string, mixed>|null */
private ?array $pending_candidate = null;
/** @var array<string, string>|null */
private ?array $capture_scope = null;
~~~

open_snapshot must reject reuse after a snapshot attempt, set snapshot_used after START TRANSACTION succeeds, and initialize confirmed_cursor, pending_candidate, capture_scope, and terminal state. rollback_snapshot must clear the pending candidate and close the snapshot; a builder retry must instantiate a new adapter and therefore a new D.

- [ ] Step 2: Implement read_next_candidate without an external source cursor.

Use this public API:

~~~
public function read_next_candidate(
    string $backfill_start_gmt,
    string $backfill_cutoff_gmt,
    int $limit = self::MAX_CHUNK_SIZE
): array
~~~

The method must:

1. require an open snapshot and 1 <= limit <= 100;
2. normalize and bind [B,C] on the first call, then reject any later scope change;
3. return the exact stored pending candidate without issuing another SQL query;
4. reject reads after terminal acknowledgement;
5. query only id > confirmed_cursor, exact shop_order, inclusive created bounds, ascending primary-ID order, and the bounded limit;
6. build a candidate containing candidate_start_id, candidate_next_id, rows, terminal, and a deterministic candidate digest;
7. store that candidate as pending before returning it;
8. mark no cursor advancement merely because the query returned rows.

The first source query must use the current internal confirmed_cursor, initialized to 0. A terminal candidate has rows = [], terminal = true, and candidate_next_id equal to the current confirmed cursor. It remains pending until acknowledged.

Use decimal-string comparison for IDs so large WordPress IDs do not overflow PHP integers. Preserve the existing identity-only row normalization, query-plan instrumentation, rows-examined metrics, chunk count, matching count, and largest-gap measurements. Replayed candidates must not increment query metrics a second time.

- [ ] Step 3: Implement exact candidate acknowledgement.

Use this API:

~~~
public function confirm_persisted(array $candidate): array
~~~

Require a pending candidate and compare the supplied candidate start ID, end ID, terminal flag, rows, and digest to the exact pending candidate. Return bounded candidate_mismatch or no_pending_candidate errors for stale, forged, duplicate, or out-of-order acknowledgements.

For a non-terminal candidate, require the end ID to be strictly greater than the confirmed cursor, advance confirmed_cursor only after the exact candidate matches, and clear pending_candidate. For a terminal candidate, require all preceding candidates to have been acknowledged by the single-pending invariant, set terminal_seen = true, and clear pending_candidate without advancing the cursor.

- [ ] Step 4: Tighten source commit rules.

Update commit_snapshot so it has both guards:

~~~
if ($this->pending_candidate !== null) {
    $this->rollback_snapshot();
    return ['ok' => false, 'error' => 'source_candidate_unconfirmed'];
}

if (!$this->terminal_seen) {
    $this->rollback_snapshot();
    return ['ok' => false, 'error' => 'source_not_exhausted'];
}
~~~

Keep the existing final table-definition and authority checks and source COMMIT. A source commit is impossible before the empty candidate has been acknowledged. Remove the public arbitrary-cursor read_chunk API so the production adapter has no caller-supplied continuation path.

- [ ] Step 5: Run the focused source proof and lint.

Run:

~~~
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-membership-source.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php --mode=hpos
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php --mode=legacy
~~~

Expected: all existing E2A membership/adversarial assertions plus the new replay, jump, terminal, and commit assertions pass for each mode. Do not proceed with a failing source test after two targeted corrections; preserve the evidence and stop for review.

- [ ] Step 6: Commit the source state-machine implementation.

~~~
git add integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-membership-source.php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php
git commit -m "feat: own Woo source continuation inside snapshot adapter"
~~~

## Task 3: Write failing builder tests with injected fakes

Files:

- Create: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php
- Test target: integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-manifest-builder.php

- [ ] Step 1: Create the standalone test harness and fakes.

Define ABSPATH, EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION, and a small assertion helper. Require the E1 store, source adapter, and new builder file. Use a plain stdClass as the WordPress database object because the builder production lock and source factories will be replaced by injected callbacks.

The fake source must expose preflight, open_snapshot, read_next_candidate, confirm_persisted, commit_snapshot, rollback_snapshot, and metrics, and append operation names to a shared event log. The fake store must expose begin_manifest, append_items, finalize_manifest, read_page, and fail_manifest, return deterministic token/page metadata, and allow each failure point to be selected by test options. The lock callbacks must append lock_acquired and lock_released events and return either true or false.

- [ ] Step 2: Add the successful flow test before implementing the builder.

The success test must use two non-terminal candidates and one terminal candidate, request limit = 1, and assert:

~~~
T::same('source capture uses the internal maximum chunk', [100, 100, 100], $source->read_limits);
T::same('source cursor confirmation follows each append', ['append', 'confirm', 'append', 'confirm', 'confirm_terminal'], $events);
T::ok('source commits before E1 finalization', index_of('source_commit') < index_of('manifest_finalize'));
T::same('first POST page uses requested limit', 1, count($result['page']['items']));
T::same('builder returns READY status only', 'ready', $result['status']);
~~~

Also assert that lock_acquired occurs before source_preflight, that the result contains the raw token only in the internal success result, and that no full order or customer fields appear.

- [ ] Step 3: Add failure, budget, and lock tests.

Cover these exact cases:

~~~
lock false                   -> busy; source factory/preflight never called
preflight failure            -> source rollback if opened; no manifest READY
open failure                -> no manifest READY
E1 begin failure             -> source rollback; no source read
source query failure         -> source rollback + fail_manifest
E1 append failure            -> no source confirmation; source rollback + FAILED
candidate confirmation fail -> source rollback + FAILED
budget exceeded              -> no next source read; rollback + FAILED
source commit failure        -> FAILED; no finalize
E1 finalization failure      -> source already committed, FAILED where possible, no success
extra HTTP cursor/last_id    -> builder rejects scope before lock/source work
~~~

Drive the budget test with an injected monotonic clock that returns 0.0 for the first chunk and 5.001 before the next read. Assert EventSales_Woo_Order_Manifest_Builder::CAPTURE_BUDGET_SECONDS === 5 and public-facing error capture_budget_exceeded in the builder result.

- [ ] Step 4: Run the builder test and verify a feature-missing RED result.

Run:

~~~
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php
~~~

Expected: failure because the production builder file/class does not yet exist. Fix only harness syntax or fake-shape errors until the failure is specifically missing production behavior.

- [ ] Step 5: Commit the builder RED tests.

~~~
git add integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php
git commit -m "test: specify bounded manifest builder orchestration"
~~~

## Task 4: Implement the production manifest builder

Files:

- Create: integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-manifest-builder.php
- Test: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php

- [ ] Step 1: Add builder constants, constructor, and narrow dependency seams.

Implement a final class with:

~~~
final class EventSales_Woo_Order_Manifest_Builder
{
    public const CAPTURE_BUDGET_SECONDS = 5;
    public const SOURCE_CHUNK_SIZE = 100;
    public const MEMBERSHIP_PREDICATE_VERSION = 'm3-01-02e2b.snapshot.v1';

    public function __construct(
        object $wordpress_db,
        ?callable $source_db_factory = null,
        ?callable $source_adapter_factory = null,
        ?callable $manifest_store_factory = null,
        ?callable $lock_acquirer = null,
        ?callable $lock_releaser = null,
        ?callable $monotonic_clock = null
    )
}
~~~

Production defaults must construct one dedicated wpdb source connection from the authoritative WordPress connection existing dbuser, dbpassword, dbname, dbhost, and prefix properties, suppressing database error output and never printing credentials. The default adapter must be EventSales_Woo_Order_Membership_Source(wordpress_db, source_db). The default store must be EventSales_Woo_Order_Index_Manifest_Store(wordpress_db). The default clock is microtime(true).

- [ ] Step 2: Implement a deterministic source-scoped lock key and zero-wait lock.

Derive a non-secret identity from the authoritative connection database host/name and table prefix, hash it, and keep the final MySQL named lock under 64 bytes:

~~~
eventsales:woo-order-index:capture:<30 hex identity hash>
~~~

Acquire with SELECT GET_LOCK(%s, 0). Treat result 1 as acquired, 0 as busy, and NULL or query failure as lock_unavailable. Release only an acquired lock with SELECT RELEASE_LOCK(%s) in finally. The lock must be load/concurrency control only; no membership or cursor decision may depend on it.

- [ ] Step 3: Implement build with exact ordering and no caller cursor.

Use this narrow input shape:

~~~
[
    'source_system' => string,
    'backfill_start' => canonical UTC string,
    'backfill_cutoff' => canonical UTC string,
    'limit' => int 1..100,
]
~~~

Reject missing or extra keys, cursor, last_id, page, offset, or a source chunk override before lock acquisition. Then perform exactly:

~~~
lock -> source connection -> adapter preflight -> open D
     -> E1 begin BUILDING
     -> repeated candidate read / append / exact confirm
     -> terminal candidate confirm
     -> budget check -> source COMMIT
     -> E1 finalize READY
     -> E1 read_page(token, null, request limit)
     -> return internal READY metadata/page
~~~

The builder starts the monotonic source-capture clock immediately before opening D and checks it before every source read, after every append and confirmation, after terminal confirmation, and before source commit. If elapsed time is greater than five seconds while D is open, return capture_budget_exceeded without another source read, roll back D, fail the BUILDING manifest, and never finalize.

For each non-terminal candidate, call append_items(manifest_id, candidate rows) and call confirm_persisted(candidate) only when append returns ok. For the empty terminal candidate, call confirm_persisted(candidate) without appending rows. Never update a source cursor in the builder.

- [ ] Step 4: Implement bounded cleanup and internal error mapping.

Track source_open, manifest_id, and lock_acquired. In a finally block, rollback an open source snapshot, call fail_manifest(manifest_id) for any non-READY attempt, and release the lock. Map internal failures to bounded codes:

~~~
preflight/open/connection failure -> source_preflight_failed or source_snapshot_failed
mode/definition/authority failure -> source_authority_changed
lock result 0                    -> busy
lock SQL/connection failure      -> lock_unavailable
begin/append/store read failure  -> manifest_storage_failed
source query/confirm failure     -> source_snapshot_failed
budget                           -> capture_budget_exceeded
source commit failure            -> source_snapshot_failed
finalize failure                -> manifest_finalize_failed
READY page read failure         -> manifest_storage_failed
~~~

Do not return raw exception messages, SQL, tokens, signatures, connection settings, filesystem paths, or source rows in an error. Preserve internal metrics only in the successful internal result for local benchmark assertions; never expose them through HTTP.

- [ ] Step 5: Run builder tests and PHP lint.

Run:

~~~
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-manifest-builder.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php
~~~

Expected: all injected builder tests pass, including lock-before-preflight, append-before-confirm, budget, rollback, commit-before-finalize, and no-READY-on-failure assertions.

- [ ] Step 6: Commit the builder.

~~~
git add integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-manifest-builder.php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php
git commit -m "feat: add bounded Woo manifest builder"
~~~

## Task 5: Write failing public POST tests

Files:

- Modify: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
- Modify: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-db-test.php
- Test target: integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php

- [ ] Step 1: Add a constructor-injected fake builder to the database-independent feed harness.

Define FeedTestBuilder with a build(array scope): array method that records calls and returns a READY page containing two metadata-only items, a token, and a nonterminal next sequence. Instantiate the controller as:

~~~
$controller = new EventSales_Woo_Order_Index_Feed(
    static fn(object $database): object => $feed_test_builder
);
~~~

Use a signed POST with limit = 1 and assert status 200, one returned item, phase = manifest_enumerate, next_cursor present, and no terminal_evidence. Add a terminal fake page and assert the response omits next_cursor and includes terminal_evidence only then.

- [ ] Step 2: Prove authentication and validation happen before builder work.

Use the existing missing-signature, wrong-secret, stale-timestamp, malformed JSON, unknown-field, and malformed B/C cases with the injected builder. Assert the builder call count remains zero for each rejected request. Add a fake builder failure result for busy, capture_budget_exceeded, and manifest_finalize_failed; assert bounded non-200 responses contain only error and never contain token, manifest hash, SQL, raw body, credentials, or PII.

- [ ] Step 3: Replace old POST and GET 501 assertions.

Change the database-independent test valid authenticated POST expectation from 501 capability-unavailable to the injected 200 READY page. Change the no-WordPress-database fallback expectation to a bounded builder/storage-unavailable response. Keep GET page/offset rejection and E1 reader behavior unchanged.

In order-index-feed-db-test.php, change the public POST test to invoke the actual builder only when the local Woo runtime has been verified by the E2B local harness; otherwise assert that the activated boundary fails closed with a bounded preflight error rather than returning 501. The test must never use a remote endpoint.

- [ ] Step 4: Run the feed test and verify the controller RED result.

Run:

~~~
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
~~~

Expected: the fake-builder constructor or active POST response behavior is missing until Task 6. Fix only test harness issues, not production behavior, before committing the RED checkpoint.

- [ ] Step 5: Commit the public-contract RED tests.

~~~
git add integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-db-test.php
git commit -m "test: require authenticated READY manifest POST"
~~~

## Task 6: Activate POST and share the E1 page response formatter

Files:

- Modify: integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php
- Test: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php

- [ ] Step 1: Load only the production source and builder required by this feed.

After the E1 store require, add:

~~~
require_once __DIR__ . '/eventsales-woo-order-membership-source.php';
require_once __DIR__ . '/eventsales-woo-order-manifest-builder.php';
~~~

Do not load the catalog plugin, Woo REST enumeration, wc_get_orders, WP_Query, or any EventSales code.

- [ ] Step 2: Add optional constructor injection without changing production registration.

Add a nullable builder-factory property and constructor:

~~~
/** @var callable(object): object|null */
private $manifest_builder_factory;

public function __construct(?callable $manifest_builder_factory = null)
{
    $this->manifest_builder_factory = $manifest_builder_factory;
}
~~~

manifest_builder must use the injected factory in tests and otherwise construct EventSales_Woo_Order_Manifest_Builder with authoritative global wpdb. A missing database returns a bounded unavailable result; it must not call source work.

- [ ] Step 3: Replace the POST capability stub with builder invocation.

Keep request-size, HMAC, JSON, and exact scope validation in their current order. After validation:

~~~
$builder = $this->manifest_builder();
if ($builder === null) {
    return self::error_response('manifest_builder_unavailable', 503);
}

$built = $builder->build($validation['values']);
if (!($built['ok'] ?? false)) {
    return self::manifest_build_error((string) ($built['error'] ?? 'manifest_storage_failed'));
}

if (($built['status'] ?? null) !== 'ready') {
    return self::error_response('manifest_unavailable', 503);
}

return $this->manifest_page_response(
    (string) $built['token'],
    $built['page'],
    'manifest_enumerate'
);
~~~

The controller must reject any builder result whose status is not exactly ready; it must never format BUILDING as success.

- [ ] Step 4: Extract the existing GET response construction into one helper.

Create manifest_page_response(string token, array page, string phase): WP_REST_Response and use it from both POST and GET. Preserve exactly the existing E1 reader call and cursor encoding. The helper must emit next_cursor only when has_more is true and terminal_evidence only when it is false. POST passes the builder requested-limit page; GET keeps its fixed maximum of 100 and its existing authenticated cursor.

- [ ] Step 5: Add bounded builder error status mapping.

Map busy to HTTP 409 and all source, storage, budget, and finalization unavailable errors to HTTP 503 with only a stable error code. Keep malformed request at 400 and auth at 401. Do not expose raw builder errors not in the explicit allowlist; map them to manifest_unavailable.

- [ ] Step 6: Run all database-independent PHP tests.

Run:

~~~
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-manifest-builder.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php
~~~

Expected: authenticated fake-builder POST succeeds only with READY metadata, invalid and unauthorized requests never call the builder, terminal fields are mutually exclusive, and all existing E1/D tests remain green.

- [ ] Step 7: Commit POST activation.

~~~
git add integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php
git commit -m "feat: activate authenticated Woo manifest POST"
~~~

## Task 7: Add local production-builder integration and performance gate

Files:

- Modify: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php
- Modify: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-db-test.php
- Modify: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof.md

- [ ] Step 1: Add a real local builder capture using existing verified fixtures.

In the E2A proof harness, add a helper that uses the production builder with the existing authoritative wpdb and default dedicated source connection. Use the existing per-mode fixture creation and cleanup and set the local HPOS marker exactly as the harness already does. Invoke the builder with limit = 2 and assert:

~~~
status = ready
exact four normal shop_order IDs
boundary B included
boundary C included
refund excluded
source commit precedes finalization
response contains <= 2 items
nonterminal response has next_cursor and no terminal_evidence
GET continuation returns the remaining identities and terminal evidence
~~~

Use a second build after the first completes and assert different manifest IDs/tokens and different source-observed boundary metadata. Do not attempt to resume a failed BUILDING manifest.

- [ ] Step 2: Add lock and failure-path integration checks.

On a separate local wpdb connection, acquire the exact builder lock with GET_LOCK(..., 0), call the builder, assert bounded busy, and assert no source snapshot or manifest BUILDING work started. Release the lock in a finally block.

Force a source-side query failure or authority mismatch through existing local mode/fixture controls and assert no READY manifest. Force an E1 append failure using the existing database test seam or a test-only injected store in the unit harness, then assert source rollback and failed status. Verify a finalization failure also produces no successful POST and does not reopen D.

- [ ] Step 3: Record representative HPOS and legacy metrics.

Run the harness against the verified local WordPress/MySQL installation after starting only the canonical local runtime:

~~~
bash scripts/dev_local.sh doctor
bash scripts/dev_local.sh status
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php --mode=hpos
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php --mode=legacy
~~~

The output and documentation must record separately for HPOS and legacy:

~~~
source mode
total source identity-space size
matching identities
rows examined
source chunks
snapshot wall time
PHP peak memory
largest emitted ID gap
query plan/key
~~~

The production capture path must not enable proof-only EXPLAIN ANALYZE unless its cost is included in the five-second measurement. If either enabled mode exceeds five seconds on the representative local dataset, stop E2B as BLOCKED and do not change the constant.

- [ ] Step 4: Verify five-second timeout behavior with a deterministic clock.

Use the builder unit harness to advance the monotonic clock beyond 5 between bounded chunks. Assert no subsequent source query, source rollback, E1 FAILED state, no finalize call, and bounded capture_budget_exceeded. This is the automated proof that timeout cannot be extended by client input.

- [ ] Step 5: Run the local E1 database regression.

Run the existing local-only command with environment variables supplied by the verified local harness without printing secrets:

~~~
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-db-test.php
~~~

Expected: E1 schema, lifecycle, immutability, and GET tests pass, POST is no longer 501, the first POST page respects limit, and GET continuation and terminal evidence remain unchanged.

- [ ] Step 6: Commit the integration and performance gate.

~~~
git add integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-db-test.php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof.md
git commit -m "test: certify production Woo manifest capture locally"
~~~

## Task 8: Update README and contract documentation

Files:

- Modify: integrations/wordpress/eventsales-woo-order-index-feed/README.md
- Modify: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-contract.md
- Modify: integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof.md

- [ ] Step 1: Document the activated public POST precisely.

State that POST is implemented only for storage modes that pass the representative five-second gate; it creates one source-consistent D, persists a single immutable E1 manifest, never exposes BUILDING, and retries always use a new manifest and new D. Document:

~~~
POST limit = first READY response page size, 1..100
source capture chunk = internal maximum 100
GET has no page, offset, or total count
boundary token identifies the manifest; HMAC remains access authority
~~~

- [ ] Step 2: Document HPOS/legacy operational status and limitations.

Include the actual local metrics from Task 7, query plan/key, finite five-second server budget, PHP memory bound, no full payload/PII guarantee, primary-ID traversal, and legacy scan, MVCC, and undo pressure. Do not claim unsupported scale or say millions are safe.

- [ ] Step 3: Document concurrency, replay, and failure semantics.

Document the source-scoped zero-wait MySQL named lock as load control only, simultaneous requests returning bounded busy, later signed replay intentionally creating a new D, source rollback on any pre-READY failure, source commit before E1 finalization, and finalization failure never becoming successful POST.

- [ ] Step 4: Run documentation consistency checks.

Run:

~~~
rg -n "501|not_implemented|POST remains|read_chunk|arbitrary cursor|limit = -1|millions|TODO|TBD" integrations/wordpress/eventsales-woo-order-index-feed docs/superpowers/plans/2026-08-12-m3-01-02e2b-manifest-builder.md
~~~

Remove only stale E1 or E2A POST-501 or arbitrary-cursor claims that conflict with the activated contract. Preserve historical E2A proof evidence where it remains accurate.

- [ ] Step 5: Commit documentation.

~~~
git add integrations/wordpress/eventsales-woo-order-index-feed/README.md integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-contract.md integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof.md
git commit -m "docs: publish E2B manifest POST contract"
~~~

## Task 9: Complete focused verification and quality gates

Files:

- All changed PHP and documentation from Tasks 1–8.

- [ ] Step 1: Lint every changed PHP file.

Run:

~~~
git diff --name-only 1b6784183c2955a22d71bb2b365effe3e8d0e1a0 | rg '\.php$' | while read -r file; do php -l "$file" || exit 1; done
~~~

Expected: no syntax errors and no secret or customer data in output.

- [ ] Step 2: Run all focused standalone tests.

Run:

~~~
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php --mode=hpos
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php --mode=legacy
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-db-test.php
~~~

Expected: all pass. If representative legacy capture exceeds the fixed five-second budget, stop and report BLOCKED instead of changing CAPTURE_BUDGET_SECONDS.

- [ ] Step 3: Run repository quality checks.

Run:

~~~
git diff --check
mix quality.fast
~~~

When verified local Postgres is available, also run:

~~~
mix quality.pr
~~~

Do not run unrelated production, Railway, VPS, or Redis checks.

- [ ] Step 4: Review scope and boundaries.

Run:

~~~
git status --short
git diff --stat 1b6784183c2955a22d71bb2b365effe3e8d0e1a0
git diff --check 1b6784183c2955a22d71bb2b365effe3e8d0e1a0
~~~

Confirm changed files are limited to the builder, source, controller, tests, README, contract docs, spec, and plan; catalog plugin hash is unchanged; no PR #188 files are touched; and no EventSales Elixir or forbidden M3 scope entered the diff.

- [ ] Step 5: Commit the final verified checkpoint.

~~~
git add integrations/wordpress/eventsales-woo-order-index-feed docs/superpowers/specs/2026-08-12-m3-01-02e2b-manifest-builder-design.md docs/superpowers/plans/2026-08-12-m3-01-02e2b-manifest-builder.md
git commit -m "test: complete E2B production manifest certification"
~~~

## Task 10: Publish a draft PR and stop

- [ ] Step 1: Read the GitHub publishing skill and inspect the final branch.

Use the repository GitHub workflow only after local verification. Confirm the current branch is path1/m3-01-02e2b-manifest-builder, the baseline ancestor is 1b6784183c2955a22d71bb2b365effe3e8d0e1a0, and PR #188 is not modified.

- [ ] Step 2: Push and open a draft PR.

Use draft PR title:

~~~
Path 1 M3-01/02E2B: activate atomic Woo manifest creation
~~~

The PR description must summarize the source acknowledgement state machine, one-D/E1 ordering, five-second gate, source-scoped lock/replay semantics, HPOS/legacy benchmark evidence, privacy boundary, and exact tests. Open it as DRAFT and do not mark it ready.

- [ ] Step 3: Capture final evidence for the required report.

Record final branch, HEAD SHA, PR number, exact changed files, POST status, builder path, continuation semantics, D semantics, HPOS/legacy status and metrics, budget, E1/source/failure behavior, response contract, authentication result, replay and lock decision, test results, quality results, catalog/PR #188 boundaries, and any blocker.

- [ ] Step 4: Stop.

Do not implement EventSales Elixir consumption, modified catch-up H, SyncRun or SyncCursor changes, refunds, M3-03+, or unrelated cleanup after the draft PR is opened.
