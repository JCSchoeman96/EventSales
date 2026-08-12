<?php

declare(strict_types=1);

define('ABSPATH', __DIR__);
define('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION', '2026-08-12.v1');

require dirname(__DIR__) . '/eventsales-woo-order-index-manifest-store.php';
require dirname(__DIR__) . '/eventsales-woo-order-membership-source.php';
require dirname(__DIR__) . '/eventsales-woo-order-manifest-builder.php';

final class E2B_Test
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

    public static function noFailures(): bool
    {
        return self::$failures === [];
    }
}

final class E2B_Fake_Source
{
    /** @var array<int, string> */
    public array $events;

    /** @var array<int, int> */
    public array $read_limits = [];

    public bool $opened = false;
    public bool $rolled_back = false;
    public bool $committed = false;

    /** @var array<int, array<string, mixed>> */
    private array $candidates;
    private int $candidate_index = 0;

    /** @var array<string, bool> */
    private array $failures;

    /**
     * @param array<int, string> $events
     * @param array<int, array<string, mixed>> $candidates
     * @param array<string, bool> $failures
     */
    public function __construct(array &$events, array $candidates, array $failures = [])
    {
        $this->events =& $events;
        $this->candidates = $candidates;
        $this->failures = $failures;
    }

    /** @return array<string, mixed> */
    public function preflight(): array
    {
        $this->events[] = 'source_preflight';
        if (($this->failures['preflight'] ?? false) === true) {
            return ['ok' => false, 'error' => 'fake_preflight_failed'];
        }

        return [
            'ok' => true,
            'mode' => 'hpos',
            'table' => 'wp_wc_orders',
            'source_definition' => 'fake-source-definition',
            'options_definition' => 'fake-options-definition',
        ];
    }

    /** @param array<string, mixed> $preflight */
    public function open_snapshot(array $preflight): array
    {
        $this->events[] = 'source_open';
        if (($this->failures['open'] ?? false) === true) {
            return ['ok' => false, 'error' => 'fake_snapshot_failed'];
        }
        $this->opened = true;

        return ['ok' => true, 'source_observed_at_gmt' => '2099-01-10T00:00:00.000000Z', 'mode' => 'hpos'];
    }

    /** @return array<string, mixed> */
    public function read_next_candidate(string $start, string $cutoff, int $limit): array
    {
        $this->events[] = 'source_read';
        $this->read_limits[] = $limit;
        if (($this->failures['read'] ?? false) === true) {
            return ['ok' => false, 'error' => 'fake_source_query_failed'];
        }
        if (!array_key_exists($this->candidate_index, $this->candidates)) {
            return ['ok' => false, 'error' => 'fake_candidate_missing'];
        }

        return $this->candidates[$this->candidate_index++];
    }

    /** @param array<string, mixed> $candidate */
    public function confirm_persisted(array $candidate): array
    {
        $this->events[] = ($candidate['terminal'] ?? false) === true ? 'confirm_terminal' : 'confirm';
        if (($this->failures['confirm'] ?? false) === true) {
            return ['ok' => false, 'error' => 'fake_confirmation_failed'];
        }

        return ['ok' => true, 'terminal' => ($candidate['terminal'] ?? false) === true];
    }

    /** @return array<string, mixed> */
    public function commit_snapshot(): array
    {
        $this->events[] = 'source_commit';
        $this->committed = true;
        $this->opened = false;
        if (($this->failures['commit'] ?? false) === true) {
            return ['ok' => false, 'error' => 'fake_source_commit_failed'];
        }

        return ['ok' => true, 'metrics' => ['mode' => 'hpos', 'chunks' => 2, 'matching_rows' => 2, 'rows_examined' => 6, 'largest_id_gap' => 0, 'snapshot_duration_ms' => 1.25]];
    }

    /** @return array<string, mixed> */
    public function rollback_snapshot(): array
    {
        $this->events[] = 'source_rollback';
        $this->rolled_back = true;
        $this->opened = false;

        return ['ok' => true];
    }

    /** @return array<string, mixed> */
    public function metrics(): array
    {
        return ['mode' => 'hpos', 'chunks' => 2, 'matching_rows' => 2, 'rows_examined' => 6, 'largest_id_gap' => 0, 'snapshot_duration_ms' => 1.25];
    }
}

final class E2B_Fake_Store
{
    /** @var array<int, string> */
    public array $events;
    public bool $failed = false;
    public int $appended = 0;

    /** @var array<string, bool> */
    private array $failures;

    /** @param array<int, string> $events */
    public function __construct(array &$events, array $failures = [])
    {
        $this->events =& $events;
        $this->failures = $failures;
    }

    /** @param array<string, mixed> $scope */
    public function begin_manifest(array $scope): array
    {
        $this->events[] = 'manifest_begin';
        if (($this->failures['begin'] ?? false) === true) {
            return ['ok' => false, 'error' => 'fake_manifest_begin_failed'];
        }

        return [
            'ok' => true,
            'manifest_id' => 77,
            'token' => 'raw-builder-token',
            'source_observed_at_gmt' => $scope['source_observed_at_gmt'] ?? '2099-01-10T00:00:00.000000Z',
        ];
    }

    /** @param iterable<array<string, mixed>> $items */
    public function append_items(int $manifest_id, iterable $items): array
    {
        $this->events[] = 'append';
        if (($this->failures['append'] ?? false) === true) {
            return ['ok' => false, 'error' => 'fake_manifest_append_failed'];
        }
        foreach ($items as $item) {
            $this->appended++;
            if (isset($item['email'], $item['billing'], $item['payment'], $item['line_items'])) {
                return ['ok' => false, 'error' => 'fake_full_order_payload'];
            }
        }

        return ['ok' => true, 'count' => $this->appended];
    }

    /** @return array<string, mixed> */
    public function finalize_manifest(int $manifest_id): array
    {
        $this->events[] = 'manifest_finalize';
        if (($this->failures['finalize'] ?? false) === true) {
            return ['ok' => false, 'error' => 'fake_manifest_finalize_failed'];
        }

        return ['ok' => true, 'manifest_hash' => str_repeat('a', 64), 'terminal_evidence' => 'fake-terminal-evidence'];
    }

    /** @return array<string, mixed> */
    public function read_page(string $token, ?int $last_sequence, int $limit): array
    {
        $this->events[] = 'manifest_read';
        if (($this->failures['read_page'] ?? false) === true) {
            return ['ok' => false, 'error' => 'fake_manifest_read_failed'];
        }
        $items = [
            ['source_order_id' => '10', 'source_created_at_gmt' => '2099-01-10T01:00:00.000000Z', 'source_modified_at_gmt' => '2099-01-10T01:00:00.000000Z'],
            ['source_order_id' => '20', 'source_created_at_gmt' => '2099-01-10T02:00:00.000000Z', 'source_modified_at_gmt' => '2099-01-10T02:00:00.000000Z'],
        ];

        return [
            'ok' => true,
            'items' => array_slice($items, 0, $limit),
            'has_more' => $limit < count($items),
            'next_sequence' => $limit < count($items) ? $limit : null,
            'terminal_evidence' => $limit < count($items) ? null : 'fake-terminal-evidence',
        ];
    }

    public function fail_manifest(int $manifest_id): bool
    {
        $this->events[] = 'manifest_fail';
        $this->failed = true;

        return true;
    }
}

function e2b_candidate(array $rows, string $start, string $next, bool $terminal = false): array
{
    return [
        'ok' => true,
        'rows' => $rows,
        'candidate_start_id' => $start,
        'candidate_next_id' => $next,
        'candidate_limit' => 100,
        'terminal' => $terminal,
        'candidate_digest' => hash('sha256', $start . '|' . $next . '|' . (int) $terminal),
    ];
}

/** @return array<string, mixed> */
function e2b_scope(array $extra = []): array
{
    return array_merge([
        'source_system' => 'local-test',
        'backfill_start' => '2099-01-10T00:00:00.000000Z',
        'backfill_cutoff' => '2099-01-10T23:59:59.000000Z',
        'limit' => 1,
    ], $extra);
}

function e2b_index_of(array $events, string $event): int
{
    $index = array_search($event, $events, true);

    return $index === false ? PHP_INT_MAX : $index;
}

/**
 * @param array<string, bool> $source_failures
 * @param array<string, bool> $store_failures
 * @return array{builder: EventSales_Woo_Order_Manifest_Builder, source: E2B_Fake_Source, store: E2B_Fake_Store, events: array<int, string>}
 */
function e2b_builder(array $source_failures = [], array $store_failures = [], ?callable $clock = null, bool $lock = true): array
{
    $events = [];
    $source = new E2B_Fake_Source($events, [
        e2b_candidate([
            ['source_order_id' => '10', 'source_created_at_gmt' => '2099-01-10T01:00:00.000000Z', 'source_modified_at_gmt' => '2099-01-10T01:00:00.000000Z'],
        ], '0', '10'),
        e2b_candidate([
            ['source_order_id' => '20', 'source_created_at_gmt' => '2099-01-10T02:00:00.000000Z', 'source_modified_at_gmt' => '2099-01-10T02:00:00.000000Z'],
        ], '10', '20'),
        e2b_candidate([], '20', '20', true),
    ], $source_failures);
    $store = new E2B_Fake_Store($events, $store_failures);
    $database = new stdClass();
    $database->dbhost = 'localhost';
    $database->dbname = 'event_sales_test';
    $database->prefix = 'wp_';

    $builder = new EventSales_Woo_Order_Manifest_Builder(
        $database,
        static function (object $wpdb) use (&$events): object {
            $events[] = 'source_factory';

            return new stdClass();
        },
        static function (object $wpdb, object $source_db) use ($source): object {
            return $source;
        },
        static function (object $wpdb) use ($store): object {
            return $store;
        },
        static function (object $wpdb, string $lock_key) use (&$events, $lock): bool {
            $events[] = 'lock_acquired';

            return $lock;
        },
        static function (object $wpdb, string $lock_key) use (&$events): void {
            $events[] = 'lock_released';
        },
        $clock ?? static fn(): float => 0.0
    );

    return ['builder' => $builder, 'source' => $source, 'store' => $store, 'events' => &$events];
}

$success = e2b_builder();
$result = $success['builder']->build(e2b_scope());
E2B_Test::same('successful builder result is ok', true, $result['ok'] ?? false);
E2B_Test::same('successful builder status is READY', 'ready', $result['status'] ?? null);
E2B_Test::same('source capture uses internal maximum chunk', [100, 100, 100], $success['source']->read_limits);
$persist_events = array_values(array_filter($success['events'], static fn(string $event): bool => in_array($event, ['append', 'confirm', 'confirm_terminal'], true)));
E2B_Test::same('source cursor confirmation follows each append', ['append', 'confirm', 'append', 'confirm', 'confirm_terminal'], $persist_events);
E2B_Test::ok('source commits before E1 finalization', e2b_index_of($success['events'], 'source_commit') < e2b_index_of($success['events'], 'manifest_finalize'));
E2B_Test::same('first POST page uses requested limit', 1, count($result['page']['items'] ?? []));
E2B_Test::same('successful result keeps raw token internal', 'raw-builder-token', $result['token'] ?? null);
E2B_Test::ok('successful result does not contain customer or full order data', !str_contains(json_encode($result, JSON_THROW_ON_ERROR), 'email'));
E2B_Test::ok('lock is acquired before source preflight', e2b_index_of($success['events'], 'lock_acquired') < e2b_index_of($success['events'], 'source_preflight'));
E2B_Test::ok('lock is released after successful capture', e2b_index_of($success['events'], 'lock_released') > e2b_index_of($success['events'], 'manifest_read'));

$lock_busy = e2b_builder([], [], null, false);
$busy_result = $lock_busy['builder']->build(e2b_scope());
E2B_Test::same('concurrent capture returns busy', 'busy', $busy_result['error'] ?? null);
E2B_Test::ok('busy capture does not run source work', !in_array('source_preflight', $lock_busy['events'], true) && !in_array('source_factory', $lock_busy['events'], true));

$preflight_failure = e2b_builder(['preflight' => true]);
$preflight_result = $preflight_failure['builder']->build(e2b_scope());
E2B_Test::same('preflight failure is bounded', 'source_preflight_failed', $preflight_result['error'] ?? null);
E2B_Test::ok('preflight failure has no READY finalization', !in_array('manifest_finalize', $preflight_failure['events'], true));

$open_failure = e2b_builder(['open' => true]);
$open_result = $open_failure['builder']->build(e2b_scope());
E2B_Test::same('snapshot open failure is bounded', 'source_snapshot_failed', $open_result['error'] ?? null);
E2B_Test::ok('open failure has no READY finalization', !in_array('manifest_finalize', $open_failure['events'], true));

$begin_failure = e2b_builder([], ['begin' => true]);
$begin_result = $begin_failure['builder']->build(e2b_scope());
E2B_Test::same('manifest begin failure is bounded', 'manifest_storage_failed', $begin_result['error'] ?? null);
E2B_Test::ok('manifest begin failure reads no source candidate', !in_array('source_read', $begin_failure['events'], true));
E2B_Test::ok('manifest begin failure rolls source back', in_array('source_rollback', $begin_failure['events'], true));

$query_failure = e2b_builder(['read' => true]);
$query_result = $query_failure['builder']->build(e2b_scope());
E2B_Test::same('source query failure is bounded', 'source_snapshot_failed', $query_result['error'] ?? null);
E2B_Test::ok('source query failure fails manifest', $query_failure['store']->failed);

$append_failure = e2b_builder([], ['append' => true]);
$append_result = $append_failure['builder']->build(e2b_scope());
E2B_Test::same('E1 append failure is bounded', 'manifest_storage_failed', $append_result['error'] ?? null);
E2B_Test::ok('E1 append failure confirms no candidate', !in_array('confirm', $append_failure['events'], true));
E2B_Test::ok('E1 append failure rolls source back and fails manifest', in_array('source_rollback', $append_failure['events'], true) && $append_failure['store']->failed);

$confirm_failure = e2b_builder(['confirm' => true]);
$confirm_result = $confirm_failure['builder']->build(e2b_scope());
E2B_Test::same('candidate confirmation failure is bounded', 'source_snapshot_failed', $confirm_result['error'] ?? null);
E2B_Test::ok('candidate confirmation failure does not finalize', !in_array('manifest_finalize', $confirm_failure['events'], true));

$budget_clock_values = [0.0, 0.0, 0.0, 5.001];
$budget_clock = static function () use (&$budget_clock_values): float {
    return array_shift($budget_clock_values) ?? 5.001;
};
$budget = e2b_builder([], [], $budget_clock);
$budget_result = $budget['builder']->build(e2b_scope());
E2B_Test::same('capture budget is fixed at five seconds', 5, EventSales_Woo_Order_Manifest_Builder::CAPTURE_BUDGET_SECONDS);
E2B_Test::same('budget failure is bounded', 'capture_budget_exceeded', $budget_result['error'] ?? null);
E2B_Test::same('budget failure reads no next candidate', 1, count($budget['source']->read_limits));
E2B_Test::ok('budget failure rolls source back and fails manifest', in_array('source_rollback', $budget['events'], true) && $budget['store']->failed);

$read_budget_clock_values = [0.0, 0.0, 0.0, 5.001];
$read_budget_clock = static function () use (&$read_budget_clock_values): float {
    return array_shift($read_budget_clock_values) ?? 5.001;
};
$read_budget = e2b_builder([], [], $read_budget_clock);
$read_budget_result = $read_budget['builder']->build(e2b_scope());
E2B_Test::same('source read crossing budget is bounded', 'capture_budget_exceeded', $read_budget_result['error'] ?? null);
E2B_Test::same('source read crossing budget reads one candidate', 1, count($read_budget['source']->read_limits));
E2B_Test::same('source read crossing budget does not append candidate', 0, $read_budget['store']->appended);
E2B_Test::ok('source read crossing budget does not confirm candidate', !in_array('confirm', $read_budget['events'], true));
E2B_Test::ok('source read crossing budget does not commit source', !$read_budget['source']->committed);
E2B_Test::ok('source read crossing budget rolls back and fails manifest', $read_budget['source']->rolled_back && $read_budget['store']->failed);

$terminal_budget_clock_values = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 5.001];
$terminal_budget_clock = static function () use (&$terminal_budget_clock_values): float {
    return array_shift($terminal_budget_clock_values) ?? 5.001;
};
$terminal_budget = e2b_builder([], [], $terminal_budget_clock);
$terminal_budget_result = $terminal_budget['builder']->build(e2b_scope());
E2B_Test::same('terminal source read crossing budget is bounded', 'capture_budget_exceeded', $terminal_budget_result['error'] ?? null);
E2B_Test::ok('terminal source read crossing budget does not confirm terminal', !in_array('confirm_terminal', $terminal_budget['events'], true));
E2B_Test::ok('terminal source read crossing budget does not commit source', !$terminal_budget['source']->committed);
E2B_Test::ok('terminal source read crossing budget rolls back and fails manifest', $terminal_budget['source']->rolled_back && $terminal_budget['store']->failed);

$open_budget_clock_values = [0.0, 5.001];
$open_budget_clock = static function () use (&$open_budget_clock_values): float {
    return array_shift($open_budget_clock_values) ?? 5.001;
};
$open_budget = e2b_builder([], [], $open_budget_clock);
$open_budget_result = $open_budget['builder']->build(e2b_scope());
E2B_Test::same('snapshot open crossing budget is bounded', 'capture_budget_exceeded', $open_budget_result['error'] ?? null);
E2B_Test::ok('snapshot open crossing budget begins no manifest', !in_array('manifest_begin', $open_budget['events'], true));
E2B_Test::ok('snapshot open crossing budget begins no source read', !in_array('source_read', $open_budget['events'], true));
E2B_Test::ok('snapshot open crossing budget rolls back source', $open_budget['source']->rolled_back);

$commit_failure = e2b_builder(['commit' => true]);
$commit_result = $commit_failure['builder']->build(e2b_scope());
E2B_Test::same('source commit failure is bounded', 'source_snapshot_failed', $commit_result['error'] ?? null);
E2B_Test::ok('source commit failure does not finalize', !in_array('manifest_finalize', $commit_failure['events'], true));

$finalize_failure = e2b_builder([], ['finalize' => true]);
$finalize_result = $finalize_failure['builder']->build(e2b_scope());
E2B_Test::same('manifest finalization failure is bounded', 'manifest_finalize_failed', $finalize_result['error'] ?? null);
E2B_Test::ok('manifest finalization failure occurs after source commit', e2b_index_of($finalize_failure['events'], 'source_commit') < e2b_index_of($finalize_failure['events'], 'manifest_finalize'));

$invalid_scope = e2b_builder();
$invalid_result = $invalid_scope['builder']->build(e2b_scope(['last_id' => '999']));
E2B_Test::same('caller source cursor is rejected', 'invalid_scope', $invalid_result['error'] ?? null);
E2B_Test::same('caller source cursor is rejected before lock', [], $invalid_scope['events']);

if (E2B_Test::noFailures()) {
    echo 'M3-01/02E2B manifest builder tests PASS: ' . E2B_Test::$passes . " assertions\n";
    exit(0);
}

foreach (E2B_Test::$failures as $failure) {
    echo "FAIL {$failure}\n";
}
echo 'M3-01/02E2B manifest builder tests FAIL: ' . count(E2B_Test::$failures) . ' failures, ' . E2B_Test::$passes . " passes\n";
exit(1);
