<?php

declare(strict_types=1);

define('ABSPATH', __DIR__);
define('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION', '2026-08-12.v1');

require dirname(__DIR__) . '/eventsales-woo-order-index-manifest-store.php';
require dirname(__DIR__) . '/eventsales-woo-order-membership-source.php';

final class F4A_Test
{
    public static int $passes = 0;

    /** @var array<int, string> */
    public static array $failures = [];

    public static function ok(string $label, bool $condition): void
    {
        if ($condition) {
            self::$passes++;

            return;
        }

        self::$failures[] = $label;
    }

    public static function same(string $label, $expected, $actual): void
    {
        self::ok($label, $expected === $actual);
    }
}

if (is_file(dirname(__DIR__) . '/eventsales-woo-order-catchup-manifest-builder.php')) {
    require dirname(__DIR__) . '/eventsales-woo-order-catchup-manifest-builder.php';
}

final class F4A_Fake_Source
{
    /** @var array<int, string> */
    public array $events = [];

    /** @var array<int, int> */
    public array $limits = [];

    /** @var array<int, array<string, mixed>> */
    private array $candidates;

    private int $candidate_index = 0;

    public bool $committed = false;
    public bool $rolled_back = false;
    public bool $confirm_failed = false;

    /** @param array<int, array<string, mixed>> $candidates */
    public function __construct(array $candidates, private string $observed_at, array &$events)
    {
        $this->candidates = $candidates;
        $this->events =& $events;
    }

    /** @return array<string, mixed> */
    public function preflight(): array
    {
        $this->events[] = 'preflight';

        return ['ok' => true, 'mode' => 'hpos'];
    }

    /** @param array<string, mixed> $preflight */
    public function open_snapshot(array $preflight): array
    {
        $this->events[] = 'open';

        return ['ok' => true, 'source_observed_at_gmt' => $this->observed_at, 'mode' => 'hpos'];
    }

    /** @return array<string, mixed> */
    public function read_next_candidate(int $parent_manifest_id, int $limit): array
    {
        $this->events[] = 'read';
        $this->limits[] = $limit;

        return $this->candidates[$this->candidate_index++] ?? ['ok' => false, 'error' => 'candidate_missing'];
    }

    /** @param array<string, mixed> $candidate */
    public function confirm_persisted(array $candidate): array
    {
        $this->events[] = ($candidate['terminal'] ?? false) === true ? 'confirm_terminal' : 'confirm';
        if ($this->confirm_failed) {
            return ['ok' => false, 'error' => 'candidate_mismatch'];
        }

        return ['ok' => true, 'terminal' => ($candidate['terminal'] ?? false) === true];
    }

    /** @return array<string, mixed> */
    public function commit_snapshot(): array
    {
        $this->events[] = 'source_commit';
        $this->committed = true;

        return ['ok' => true, 'metrics' => ['mode' => 'hpos']];
    }

    /** @return array<string, mixed> */
    public function rollback_snapshot(): array
    {
        $this->events[] = 'source_rollback';
        $this->rolled_back = true;

        return ['ok' => true];
    }
}

final class F4A_Fake_Store
{
    /** @var array<int, string> */
    public array $events = [];

    /** @var array<string, mixed> */
    public array $parent;

    /** @var array<string, mixed>|null */
    public ?array $parent_on_revalidate = null;

    private int $parent_lookups = 0;

    /** @var array<string, mixed>|null */
    public ?array $scope = null;

    /** @var array<int, array<string, mixed>> */
    public array $appended = [];

    public bool $failed = false;
    public bool $append_failed = false;
    public bool $finalize_failed = false;

    /** @param array<string, mixed> $parent */
    public function __construct(array $parent, array &$events)
    {
        $this->parent = $parent;
        $this->events =& $events;
    }

    /** @return array<string, mixed> */
    public function resolve_parent_manifest(string $token, string $source_system): array
    {
        $this->events[] = 'parent_lookup';
        $this->parent_lookups++;

        if ($this->parent_lookups > 1 && $this->parent_on_revalidate !== null) {
            return $this->parent_on_revalidate;
        }

        return $this->parent;
    }

    /** @param array<string, mixed> $scope */
    public function begin_manifest(array $scope): array
    {
        $this->events[] = 'manifest_begin';
        $this->scope = $scope;

        return [
            'ok' => true,
            'manifest_id' => 88,
            'token' => 'child-token',
            'expires_at_gmt' => '2099-01-12T00:00:00.000000Z',
        ];
    }

    /** @param iterable<array<string, mixed>> $items */
    public function append_items(int $manifest_id, iterable $items): array
    {
        $this->events[] = 'append';
        if ($this->append_failed) {
            return ['ok' => false, 'error' => 'manifest_storage_failed'];
        }
        foreach ($items as $item) {
            $this->appended[] = $item;
        }

        return ['ok' => true];
    }

    /** @return array<string, mixed> */
    public function finalize_manifest(int $manifest_id): array
    {
        $this->events[] = 'manifest_finalize';
        if ($this->finalize_failed) {
            return ['ok' => false, 'error' => 'manifest_finalize_failed'];
        }

        return [
            'ok' => true,
            'manifest_hash' => str_repeat('c', 64),
            'terminal_evidence' => 'v1;phase=catch_up;manifest_sha256=' . str_repeat('c', 64),
        ];
    }

    /** @return array<string, mixed> */
    public function read_page(string $token, ?int $last_sequence, int $limit): array
    {
        $this->events[] = 'manifest_read';

        return [
            'ok' => true,
            'schema_version' => '2026-08-13.catchup.v1',
            'phase' => 'catch_up',
            'manifest_hash' => str_repeat('c', 64),
            'expires_at_gmt' => '2099-01-12T00:00:00.000000Z',
            'source_observed_at_gmt' => '2099-01-11T00:00:00.000000Z',
            'items' => array_slice($this->appended, 0, $limit),
            'has_more' => false,
            'terminal_evidence' => 'v1;phase=catch_up;manifest_sha256=' . str_repeat('c', 64),
        ];
    }

    public function fail_manifest(int $manifest_id): bool
    {
        $this->events[] = 'manifest_fail';
        $this->failed = true;

        return true;
    }
}

function f4a_parent(array $overrides = []): array
{
    return array_merge([
        'ok' => true,
        'manifest_id' => 42,
        'manifest_hash' => str_repeat('a', 64),
        'source_system' => 'local-test',
        'backfill_start_gmt' => '2099-01-01T00:00:00.000000Z',
        'backfill_cutoff_gmt' => '2099-01-10T00:00:00.000000Z',
        'source_observed_at_gmt' => '2099-01-10T00:00:00.000000Z',
        'phase' => 'manifest_enumerate',
        'status' => 'ready',
        'item_count' => 2,
        'terminal_evidence' => 'v1;manifest_sha256=' . str_repeat('a', 64),
    ], $overrides);
}

function f4a_candidate(array $rows, int $start, int $end, int $parent_count, bool $terminal = false): array
{
    return [
        'ok' => true,
        'parent_manifest_id' => 42,
        'candidate_start_sequence' => $start,
        'candidate_end_sequence' => $end,
        'candidate_limit' => 100,
        'parent_count' => $parent_count,
        'terminal' => $terminal,
        'rows' => $rows,
        'candidate_digest' => hash('sha256', json_encode([$start, $end, $parent_count, $terminal, $rows], JSON_THROW_ON_ERROR)),
    ];
}

function f4a_builder(F4A_Fake_Source $source, F4A_Fake_Store $store, array &$events): object
{
    $database = (object) ['dbhost' => 'localhost', 'dbname' => 'test', 'prefix' => 'wp_'];

    return new EventSales_Woo_Order_Catchup_Manifest_Builder(
        $database,
        static function (object $wpdb) {
            return new stdClass();
        },
        static function (object $wpdb, object $source_db) use ($source): object {
            return $source;
        },
        static function (object $wpdb) use ($store): object {
            return $store;
        },
        static function (object $wpdb, string $lock_key) use (&$events): bool {
            $events[] = 'lock_acquired';

            return true;
        },
        static function (object $wpdb, string $lock_key) use (&$events): void {
            $events[] = 'lock_released';
        },
        static fn(): float => 0.0
    );
}

if (class_exists('EventSales_Woo_Order_Catchup_Manifest_Builder')) {
    $events = [];
    $changed = [
        ['source_order_id' => '10', 'source_created_at_gmt' => '2099-01-10T01:00:00.000000Z', 'source_modified_at_gmt' => '2099-01-11T01:00:00.000000Z'],
        ['source_order_id' => '20', 'source_created_at_gmt' => '2099-01-10T02:00:00.000000Z', 'source_modified_at_gmt' => '2099-01-12T02:00:00.000000Z'],
    ];
    $source = new F4A_Fake_Source([
        f4a_candidate($changed, 0, 2, 2),
        f4a_candidate([], 2, 2, 0, true),
    ], '2099-01-11T00:00:00.000000Z', $events);
    $store = new F4A_Fake_Store(f4a_parent(), $events);
    $builder = f4a_builder($source, $store, $events);
    $result = $builder->build(['parent_token' => 'parent-token', 'source_system' => 'local-test', 'limit' => 100]);
    F4A_Test::same('changed parent members produce READY child', true, $result['ok'] ?? false);
    F4A_Test::same('source H is retained', '2099-01-11T00:00:00.000000Z', $result['source_observed_at_gmt'] ?? null);
    F4A_Test::same('catch-up source chunk is fixed at 100', [100, 100], $source->limits);
    F4A_Test::same('changed rows preserve parent sequence order', $changed, $store->appended);
    F4A_Test::same('child phase is catch_up', 'catch_up', $store->scope['phase'] ?? null);
    F4A_Test::same('child schema version is explicit', '2026-08-13.catchup.v1', $store->scope['schema_version'] ?? null);
    F4A_Test::same('child predicate version is explicit', 'm3-01-02f4a.catchup.v1', $store->scope['membership_predicate_version'] ?? null);
    F4A_Test::same('child binds exact parent hash', str_repeat('a', 64), $store->scope['parent_manifest_hash'] ?? null);
    F4A_Test::same('child catch-up origin is parent D', '2099-01-10T00:00:00.000000Z', $store->scope['catchup_from_gmt'] ?? null);
    F4A_Test::same('child preserves parent B', '2099-01-01T00:00:00.000000Z', $store->scope['backfill_start_gmt'] ?? null);
    F4A_Test::same('child preserves parent C', '2099-01-10T00:00:00.000000Z', $store->scope['backfill_cutoff_gmt'] ?? null);
    F4A_Test::ok('source commits before child READY finalization', array_search('source_commit', $events, true) < array_search('manifest_finalize', $events, true));

    $revalidation_events = [];
    $revalidation_source = new F4A_Fake_Source([
        f4a_candidate($changed, 0, 2, 2),
        f4a_candidate([], 2, 2, 0, true),
    ], '2099-01-11T00:00:00.000000Z', $revalidation_events);
    $revalidation_store = new F4A_Fake_Store(f4a_parent(), $revalidation_events);
    $revalidation_store->parent_on_revalidate = f4a_parent(['manifest_hash' => str_repeat('b', 64)]);
    $revalidation = f4a_builder($revalidation_source, $revalidation_store, $revalidation_events)->build([
        'parent_token' => 'parent-token',
        'source_system' => 'local-test',
        'limit' => 100,
    ]);
    F4A_Test::same('parent mutation blocks child READY', 'parent_manifest_changed', $revalidation['error'] ?? null);
    F4A_Test::ok('parent mutation does not finalize child', !in_array('manifest_finalize', $revalidation_events, true));

    foreach ([
        'unknown parent' => [['ok' => false, 'error' => 'manifest_not_found'], 'parent_manifest_not_found'],
        'BUILDING parent' => [f4a_parent(['status' => 'building']), 'parent_manifest_not_ready'],
        'FAILED parent' => [f4a_parent(['status' => 'failed']), 'parent_manifest_not_ready'],
        'EXPIRED parent' => [f4a_parent(['status' => 'expired']), 'parent_manifest_not_ready'],
        'wrong source parent' => [f4a_parent(['source_system' => 'other-source']), 'parent_manifest_wrong_source'],
        'catch-up parent' => [f4a_parent(['phase' => 'catch_up']), 'parent_manifest_wrong_phase'],
    ] as $label => [$parent, $expected_error]) {
        $rejection_events = [];
        $rejection_source = new F4A_Fake_Source([], '2099-01-11T00:00:00.000000Z', $rejection_events);
        $rejection_store = new F4A_Fake_Store($parent, $rejection_events);
        $rejection = f4a_builder($rejection_source, $rejection_store, $rejection_events)->build([
            'parent_token' => 'parent-token',
            'source_system' => 'local-test',
            'limit' => 100,
        ]);
        F4A_Test::same($label . ' is rejected before H', $expected_error, $rejection['error'] ?? null);
        F4A_Test::ok($label . ' opens no source snapshot', !in_array('open', $rejection_events, true));
    }

    $client_h_events = [];
    $client_h_source = new F4A_Fake_Source([], '2099-01-11T00:00:00.000000Z', $client_h_events);
    $client_h_store = new F4A_Fake_Store(f4a_parent(), $client_h_events);
    $client_h = f4a_builder($client_h_source, $client_h_store, $client_h_events)->build([
        'parent_token' => 'parent-token',
        'source_system' => 'local-test',
        'limit' => 100,
        'source_observed_at_gmt' => '2099-01-11T00:00:00.000000Z',
    ]);
    F4A_Test::same('client-supplied H is rejected', 'invalid_scope', $client_h['error'] ?? null);

    $unchanged_events = [];
    $unchanged_source = new F4A_Fake_Source([
        f4a_candidate([], 0, 3, 3),
        f4a_candidate([], 3, 3, 0, true),
    ], '2099-01-10T00:00:00.000000Z', $unchanged_events);
    $unchanged_store = new F4A_Fake_Store(f4a_parent(['item_count' => 3]), $unchanged_events);
    $unchanged = f4a_builder($unchanged_source, $unchanged_store, $unchanged_events)->build([
        'parent_token' => 'parent-token',
        'source_system' => 'local-test',
        'limit' => 20,
    ]);
    F4A_Test::same('unchanged M produces READY zero-item U', true, $unchanged['ok'] ?? false);
    F4A_Test::same('unchanged M appends no identities', [], $unchanged_store->appended);
    F4A_Test::same('unchanged M still ACKs nonterminal candidate', ['append'], array_values(array_filter($unchanged_store->events, static fn(string $event): bool => $event === 'append')));

    $unresolved_events = [];
    $unresolved_source = new F4A_Fake_Source([
        ['ok' => false, 'error' => 'catchup_member_unresolved'],
    ], '2099-01-11T00:00:00.000000Z', $unresolved_events);
    $unresolved_store = new F4A_Fake_Store(f4a_parent(), $unresolved_events);
    $unresolved = f4a_builder($unresolved_source, $unresolved_store, $unresolved_events)->build([
        'parent_token' => 'parent-token',
        'source_system' => 'local-test',
        'limit' => 100,
    ]);
    F4A_Test::same('unresolved M member fails closed', 'catchup_member_unresolved', $unresolved['error'] ?? null);
    F4A_Test::ok('unresolved M member cannot commit or finalize', !$unresolved_source->committed && !in_array('manifest_finalize', $unresolved_store->events, true));

    $append_failure_events = [];
    $append_failure_source = new F4A_Fake_Source([
        f4a_candidate($changed, 0, 2, 2),
    ], '2099-01-11T00:00:00.000000Z', $append_failure_events);
    $append_failure_store = new F4A_Fake_Store(f4a_parent(), $append_failure_events);
    $append_failure_store->append_failed = true;
    $append_failure = f4a_builder($append_failure_source, $append_failure_store, $append_failure_events)->build([
        'parent_token' => 'parent-token',
        'source_system' => 'local-test',
        'limit' => 100,
    ]);
    F4A_Test::same('append failure is bounded', 'manifest_storage_failed', $append_failure['error'] ?? null);
    F4A_Test::ok('append failure confirms no candidate or source commit', !in_array('confirm', $append_failure_events, true) && !$append_failure_source->committed);
    F4A_Test::ok('append failure rolls source back and fails child', $append_failure_source->rolled_back && $append_failure_store->failed);

    $confirm_failure_events = [];
    $confirm_failure_source = new F4A_Fake_Source([
        f4a_candidate($changed, 0, 2, 2),
    ], '2099-01-11T00:00:00.000000Z', $confirm_failure_events);
    $confirm_failure_source->confirm_failed = true;
    $confirm_failure_store = new F4A_Fake_Store(f4a_parent(), $confirm_failure_events);
    $confirm_failure = f4a_builder($confirm_failure_source, $confirm_failure_store, $confirm_failure_events)->build([
        'parent_token' => 'parent-token',
        'source_system' => 'local-test',
        'limit' => 100,
    ]);
    F4A_Test::same('candidate confirmation mismatch is bounded', 'source_snapshot_failed', $confirm_failure['error'] ?? null);
    F4A_Test::ok('confirmation mismatch prevents source commit and child READY', !$confirm_failure_source->committed && !in_array('manifest_finalize', $confirm_failure_events, true));

    $budget_events = [];
    $budget_source = new F4A_Fake_Source([
        f4a_candidate($changed, 0, 2, 2),
    ], '2099-01-11T00:00:00.000000Z', $budget_events);
    $budget_store = new F4A_Fake_Store(f4a_parent(), $budget_events);
    $budget_clock_values = [0.0, 0.0, 0.0, 5.001];
    $budget_clock = static function () use (&$budget_clock_values): float {
        return array_shift($budget_clock_values) ?? 5.001;
    };
    $budget_builder = new EventSales_Woo_Order_Catchup_Manifest_Builder(
        (object) ['dbhost' => 'localhost', 'dbname' => 'test', 'prefix' => 'wp_'],
        static fn(object $wpdb): object => new stdClass(),
        static fn(object $wpdb, object $source_db): object => $budget_source,
        static fn(object $wpdb): object => $budget_store,
        static fn(object $wpdb, string $lock_key): bool => true,
        static function (object $wpdb, string $lock_key): void {
        },
        $budget_clock
    );
    $budget_result = $budget_builder->build([
        'parent_token' => 'parent-token',
        'source_system' => 'local-test',
        'limit' => 100,
    ]);
    F4A_Test::same('catch-up capture budget is fixed at five seconds', 5, EventSales_Woo_Order_Catchup_Manifest_Builder::CAPTURE_BUDGET_SECONDS);
    F4A_Test::same('catch-up capture budget failure is bounded', 'capture_budget_exceeded', $budget_result['error'] ?? null);
    F4A_Test::ok('catch-up budget failure rolls source back and fails child', $budget_source->rolled_back && $budget_store->failed);
    F4A_Test::ok('catch-up budget failure publishes no READY child', !in_array('manifest_finalize', $budget_events, true));

    $before_d_events = [];
    $before_d_source = new F4A_Fake_Source([], '2099-01-09T23:59:59.000000Z', $before_d_events);
    $before_d_store = new F4A_Fake_Store(f4a_parent(), $before_d_events);
    $before_d = f4a_builder($before_d_source, $before_d_store, $before_d_events)->build([
        'parent_token' => 'parent-token',
        'source_system' => 'local-test',
        'limit' => 100,
    ]);
    F4A_Test::same('H before D fails closed', 'source_snapshot_before_parent', $before_d['error'] ?? null);
    F4A_Test::ok('H before D opens no child', !in_array('manifest_begin', $before_d_store->events, true));
}

if (F4A_Test::$failures !== []) {
    foreach (F4A_Test::$failures as $failure) {
        echo "FAIL {$failure}\n";
    }
    echo 'M3-01/02F4A catch-up builder tests FAIL: ' . count(F4A_Test::$failures) . ' failures, ' . F4A_Test::$passes . " passes\n";
    exit(1);
}

if (!class_exists('EventSales_Woo_Order_Catchup_Manifest_Builder')) {
    echo "FAIL catch-up builder class is not implemented\n";
    exit(1);
}

echo 'M3-01/02F4A catch-up builder tests PASS: ' . F4A_Test::$passes . " assertions\n";
