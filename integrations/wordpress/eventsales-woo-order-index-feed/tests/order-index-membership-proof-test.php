<?php

declare(strict_types=1);

/**
 * Local HPOS/legacy source-membership proof harness.
 *
 * This test deliberately requires an explicit loopback WordPress installation
 * and never falls back to a remote or production database. It writes only
 * synthetic rows whose IDs are allocated above the local source maximum and
 * removes those rows in the finally block.
 */

const EVENTSALES_PROOF_HPOS = 'hpos';
const EVENTSALES_PROOF_LEGACY = 'legacy';
const EVENTSALES_PROOF_OPTION = 'woocommerce_custom_orders_table_enabled';
const EVENTSALES_PROOF_START = '2099-01-10T00:00:00.000000Z';
const EVENTSALES_PROOF_CUTOFF = '2099-01-10T23:59:59.000000Z';

final class EventSales_Membership_Proof_Test
{
    private static int $failures = 0;

    public static function ok(string $label, bool $condition, string $detail = ''): void
    {
        if ($condition) {
            echo "PASS {$label}\n";

            return;
        }

        self::$failures++;
        echo "FAIL {$label}" . ($detail === '' ? '' : ": {$detail}") . "\n";
    }

    public static function same(string $label, $expected, $actual): void
    {
        self::ok(
            $label,
            $expected === $actual,
            'expected=' . self::display($expected) . ' actual=' . self::display($actual)
        );
    }

    public static function noFailures(): bool
    {
        return self::$failures === 0;
    }

    private static function display($value): string
    {
        return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?: '<unprintable>';
    }
}

function eventsales_proof_fail(string $message): never
{
    fwrite(STDERR, "BLOCKED {$message}\n");
    exit(2);
}

function eventsales_proof_identifier(string $identifier): string
{
    if (!preg_match('/^[A-Za-z0-9_]+$/D', $identifier)) {
        throw new RuntimeException('unsafe local table identifier');
    }

    return '`' . $identifier . '`';
}

function eventsales_proof_modes(): array
{
    global $argv;

    $requested = 'both';
    foreach (array_slice($argv, 1) as $argument) {
        if (str_starts_with($argument, '--mode=')) {
            $requested = substr($argument, 7);
        }
    }

    if ($requested === 'both') {
        return [EVENTSALES_PROOF_HPOS, EVENTSALES_PROOF_LEGACY];
    }

    if (in_array($requested, [EVENTSALES_PROOF_HPOS, EVENTSALES_PROOF_LEGACY], true)) {
        return [$requested];
    }

    eventsales_proof_fail('use --mode=hpos, --mode=legacy, or --mode=both');
}

function eventsales_proof_bootstrap_wordpress(): object
{
    $root = rtrim((string) getenv('EVENTSALES_WP_ROOT'), '/');
    $expected_url = (string) getenv('EVENTSALES_WP_URL');
    if ($root === '' || $expected_url === '') {
        eventsales_proof_fail('set EVENTSALES_WP_ROOT and EVENTSALES_WP_URL for the local WordPress installation');
    }

    $parsed = parse_url($expected_url);
    if (
        !is_array($parsed)
        || !in_array(strtolower((string) ($parsed['host'] ?? '')), ['localhost', '127.0.0.1'], true)
        || (int) ($parsed['port'] ?? 80) !== 10059
    ) {
        eventsales_proof_fail('EVENTSALES_WP_URL must be http://localhost:10059 or http://127.0.0.1:10059');
    }

    if (!is_file($root . '/wp-load.php') || !is_file($root . '/wp-includes/class-wpdb.php')) {
        eventsales_proof_fail('EVENTSALES_WP_ROOT is not a WordPress installation');
    }

    $_SERVER['HTTP_HOST'] = (string) ($parsed['host'] ?? 'localhost') . ':10059';
    $_SERVER['SERVER_NAME'] = (string) ($parsed['host'] ?? 'localhost');
    $_SERVER['REQUEST_URI'] = '/';
    $_SERVER['HTTPS'] = 'off';

    define('WP_USE_THEMES', false);
    ob_start();
    require $root . '/wp-load.php';
    ob_end_clean();

    global $wpdb;
    if (!is_object($wpdb) || !is_a($wpdb, 'wpdb')) {
        eventsales_proof_fail('WordPress bootstrap did not provide wpdb');
    }
    $wpdb->suppress_errors(true);

    $home = (string) $wpdb->get_var($wpdb->prepare(
        'SELECT option_value FROM ' . eventsales_proof_identifier($wpdb->options) . ' WHERE option_name = %s LIMIT 1',
        'home'
    ));
    $home_parts = parse_url($home);
    if (
        !is_array($home_parts)
        || !in_array(strtolower((string) ($home_parts['host'] ?? '')), ['localhost', '127.0.0.1'], true)
        || (int) ($home_parts['port'] ?? 80) !== 10059
    ) {
        eventsales_proof_fail('WordPress home option is not the verified loopback site');
    }

    if (!class_exists('Automattic\\WooCommerce\\Utilities\\OrderUtil')) {
        eventsales_proof_fail('WooCommerce OrderUtil is not loaded; the proof refuses to guess storage mode');
    }

    $detector = ['Automattic\\WooCommerce\\Utilities\\OrderUtil', 'custom_orders_table_usage_is_enabled'];
    if (!is_callable($detector)) {
        eventsales_proof_fail('WooCommerce OrderUtil capability is unavailable');
    }

    return $wpdb;
}

function eventsales_proof_new_db(object $wpdb): object
{
    foreach (['dbuser', 'dbpassword', 'dbname', 'dbhost', 'prefix'] as $property) {
        if (!property_exists($wpdb, $property)) {
            eventsales_proof_fail('wpdb connection configuration is unavailable for a dedicated local source connection');
        }
    }

    $db = new wpdb($wpdb->dbuser, $wpdb->dbpassword, $wpdb->dbname, $wpdb->dbhost);
    $db->set_prefix($wpdb->prefix);
    $db->suppress_errors(true);
    if ($db->last_error !== '') {
        eventsales_proof_fail('dedicated local source database connection failed');
    }

    return $db;
}

function eventsales_proof_set_mode(object $wpdb, string $mode): void
{
    $value = $mode === EVENTSALES_PROOF_HPOS ? 'yes' : 'no';
    $updated = $wpdb->query($wpdb->prepare(
        'UPDATE ' . eventsales_proof_identifier($wpdb->options) . ' SET option_value = %s WHERE option_name = %s',
        $value,
        EVENTSALES_PROOF_OPTION
    ));
    if ($updated === false) {
        throw new RuntimeException('local storage-mode option update failed');
    }
    if ($updated === 0 && $wpdb->get_var($wpdb->prepare(
        'SELECT option_name FROM ' . eventsales_proof_identifier($wpdb->options) . ' WHERE option_name = %s LIMIT 1',
        EVENTSALES_PROOF_OPTION
    )) === null) {
        $inserted = $wpdb->query($wpdb->prepare(
            'INSERT INTO ' . eventsales_proof_identifier($wpdb->options)
            . ' (option_name, option_value, autoload) VALUES (%s, %s, %s)',
            EVENTSALES_PROOF_OPTION,
            $value,
            'no'
        ));
        if ($inserted === false) {
            throw new RuntimeException('local storage-mode option setup failed');
        }
    }

    eventsales_proof_clear_option_cache();
}

function eventsales_proof_clear_option_cache(): void
{
    if (function_exists('wp_cache_delete')) {
        wp_cache_delete(EVENTSALES_PROOF_OPTION, 'options');
        wp_cache_delete('alloptions', 'options');
    }
}

function eventsales_proof_restore_mode(object $wpdb, ?string $original_value, bool $had_original): void
{
    if ($had_original) {
        $wpdb->query($wpdb->prepare(
            'UPDATE ' . eventsales_proof_identifier($wpdb->options) . ' SET option_value = %s WHERE option_name = %s',
            (string) $original_value,
            EVENTSALES_PROOF_OPTION
        ));
    } else {
        $wpdb->query($wpdb->prepare(
            'DELETE FROM ' . eventsales_proof_identifier($wpdb->options) . ' WHERE option_name = %s',
            EVENTSALES_PROOF_OPTION
        ));
    }

    eventsales_proof_clear_option_cache();
}

function eventsales_proof_table(object $wpdb, string $mode): string
{
    if ($mode === EVENTSALES_PROOF_HPOS) {
        $class = 'Automattic\\WooCommerce\\Internal\\DataStores\\Orders\\OrdersTableDataStore';
        $method = [$class, 'get_orders_table_name'];
        if (!is_callable($method)) {
            throw new RuntimeException('HPOS datastore table-name API is unavailable');
        }

        $table = (string) call_user_func($method);
        if ($table !== (string) $wpdb->prefix . 'wc_orders') {
            throw new RuntimeException('HPOS table-name API did not resolve the configured WordPress prefix');
        }

        return $table;
    }

    return (string) $wpdb->posts;
}

function eventsales_proof_insert_fixture(object $wpdb, string $mode, int $id, string $created, string $modified, string $marker, string $type = 'shop_order'): void
{
    $table = eventsales_proof_identifier(eventsales_proof_table($wpdb, $mode));
    if ($mode === EVENTSALES_PROOF_HPOS) {
        $result = $wpdb->query($wpdb->prepare(
            "INSERT INTO {$table} (id, type, status, date_created_gmt, date_updated_gmt) VALUES (%d, %s, %s, %s, %s)",
            $id,
            $type,
            'wc-pending',
            $created,
            $modified
        ));
    } else {
        $result = $wpdb->query($wpdb->prepare(
            "INSERT INTO {$table} (ID, post_author, post_date, post_date_gmt, post_content, post_title, post_excerpt,
                post_status, comment_status, ping_status, post_password, post_name, to_ping, pinged,
                post_content_filtered, post_parent, guid, menu_order, post_type, post_mime_type, comment_count,
                post_modified, post_modified_gmt)
             VALUES (%d, 0, %s, %s, '', %s, '', 'wc-pending', 'closed', 'closed', '', %s, '', '', '', 0, %s, 0,
                %s, '', 0, %s, %s)",
            $id,
            $created,
            $created,
            $marker,
            $marker . '-' . $id,
            'http://localhost:10059/?eventsales-proof=' . $id,
            $type,
            $modified,
            $modified
        ));
    }

    if ($result === false) {
        throw new RuntimeException('local fixture insert failed');
    }
}

function eventsales_proof_update_fixture(object $wpdb, string $mode, int $id, ?string $created, ?string $modified): void
{
    $table = eventsales_proof_identifier(eventsales_proof_table($wpdb, $mode));
    $sets = [];
    $values = [];
    if ($created !== null) {
        if ($mode === EVENTSALES_PROOF_HPOS) {
            $sets[] = 'date_created_gmt = %s';
            $values[] = $created;
        } else {
            $sets[] = 'post_date_gmt = %s';
            $values[] = $created;
            $sets[] = 'post_date = %s';
            $values[] = $created;
        }
    }
    if ($modified !== null) {
        if ($mode === EVENTSALES_PROOF_HPOS) {
            $sets[] = 'date_updated_gmt = %s';
            $values[] = $modified;
        } else {
            $sets[] = 'post_modified_gmt = %s';
            $values[] = $modified;
            $sets[] = 'post_modified = %s';
            $values[] = $modified;
        }
    }
    if ($sets === []) {
        return;
    }

    $values[] = $id;
    $result = $wpdb->query($wpdb->prepare(
        "UPDATE {$table} SET " . implode(', ', $sets) . ' WHERE ' . ($mode === EVENTSALES_PROOF_HPOS ? 'id' : 'ID') . ' = %d',
        ...$values
    ));
    if ($result === false) {
        throw new RuntimeException('local fixture update failed');
    }
}

function eventsales_proof_delete_fixture(object $wpdb, string $mode, int $id): void
{
    $table = eventsales_proof_identifier(eventsales_proof_table($wpdb, $mode));
    $wpdb->query($wpdb->prepare(
        "DELETE FROM {$table} WHERE " . ($mode === EVENTSALES_PROOF_HPOS ? 'id' : 'ID') . ' = %d',
        $id
    ));
}

/** @return array{ids: array<string, int>, all: array<int>} */
function eventsales_proof_create_fixtures(object $wpdb, string $mode): array
{
    $table = eventsales_proof_identifier(eventsales_proof_table($wpdb, $mode));
    $id_column = $mode === EVENTSALES_PROOF_HPOS ? 'id' : 'ID';
    $maximum = (int) $wpdb->get_var("SELECT COALESCE(MAX({$id_column}), 100000) FROM {$table}");
    $base = $maximum + 1000;
    $marker = 'eventsales-membership-proof-' . bin2hex(random_bytes(8));
    $ids = [
        '10' => $base + 10,
        '20' => $base + 20,
        '30' => $base + 30,
        '40' => $base + 40,
        'outside' => $base + 50,
        'post_d' => $base + 60,
        'refund' => $base + 70,
    ];
    $rows = [
        ['10', EVENTSALES_PROOF_START, '2099-01-10T10:00:00.000000Z'],
        ['20', '2099-01-10T12:00:00.000000Z', '2099-01-10T12:00:00.000000Z'],
        ['30', '2099-01-10T12:00:00.000000Z', '2099-01-10T12:00:00.000000Z'],
        ['40', EVENTSALES_PROOF_CUTOFF, '2099-01-10T10:00:00.000000Z'],
        ['outside', '2099-01-09T23:59:59.000000Z', '2099-01-09T23:59:59.000000Z'],
    ];

    try {
        foreach ($rows as [$label, $created, $modified]) {
            eventsales_proof_insert_fixture(
                $wpdb,
                $mode,
                $ids[$label],
                str_replace('T', ' ', substr($created, 0, -1)),
                str_replace('T', ' ', substr($modified, 0, -1)),
                $marker
            );
        }
        eventsales_proof_insert_fixture(
            $wpdb,
            $mode,
            $ids['refund'],
            '2099-01-10 15:00:00.000000',
            '2099-01-10 15:00:00.000000',
            $marker,
            'shop_order_refund'
        );
    } catch (Throwable $error) {
        foreach ($ids as $id) {
            eventsales_proof_delete_fixture($wpdb, $mode, $id);
        }
        throw $error;
    }

    return ['ids' => $ids, 'all' => array_values($ids)];
}

function eventsales_proof_scope(string $mode, string $observed): array
{
    return [
        'source_system' => 'local-proof:' . $mode,
        'backfill_start_gmt' => EVENTSALES_PROOF_START,
        'backfill_cutoff_gmt' => EVENTSALES_PROOF_CUTOFF,
        'source_observed_at_gmt' => $observed,
        'membership_predicate_version' => 'm3-01-02e2a.snapshot.v1.' . $mode,
    ];
}

/**
 * Capture one source snapshot into a separate BUILDING E1 manifest.
 *
 * @param callable|null $after_first_chunk Called after the first E1 append.
 * @return array<string, mixed>
 */
function eventsales_proof_capture(object $wpdb, object $source_db, string $mode, ?callable $after_first_chunk = null): array
{
    $adapter = new EventSales_Woo_Order_Membership_Source($wpdb, $source_db, null, true);
    $preflight = $adapter->preflight();
    if (!($preflight['ok'] ?? false) || ($preflight['mode'] ?? null) !== $mode) {
        throw new RuntimeException('preflight failed: ' . (string) ($preflight['error'] ?? 'wrong mode'));
    }

    $opened = $adapter->open_snapshot($preflight);
    if (!($opened['ok'] ?? false)) {
        throw new RuntimeException('snapshot failed: ' . (string) ($opened['error'] ?? 'unknown'));
    }

    $store = new EventSales_Woo_Order_Index_Manifest_Store($wpdb);
    $started = $store->begin_manifest(eventsales_proof_scope($mode, (string) $opened['source_observed_at_gmt']));
    if (!($started['ok'] ?? false)) {
        $adapter->rollback_snapshot();
        throw new RuntimeException('E1 BUILDING start failed: ' . json_encode($started, JSON_UNESCAPED_SLASHES));
    }

    $manifest_id = (int) $started['manifest_id'];
    $captured = [];
    $cursor = '0';
    $first = true;
    try {
        while (true) {
            $chunk = $adapter->read_chunk(EVENTSALES_PROOF_START, EVENTSALES_PROOF_CUTOFF, $cursor, 2);
            if (!($chunk['ok'] ?? false)) {
                throw new RuntimeException('source chunk failed: ' . (string) ($chunk['error'] ?? 'unknown'));
            }
            if ($chunk['rows'] === []) {
                break;
            }

            $appended = $store->append_items($manifest_id, $chunk['rows']);
            if (!($appended['ok'] ?? false)) {
                throw new RuntimeException('E1 append failed');
            }
            foreach ($chunk['rows'] as $row) {
                $captured[] = $row;
            }

            $cursor = (string) $chunk['next_id'];
            if ($first && $after_first_chunk !== null) {
                $after_first_chunk();
            }
            $first = false;
        }

        $committed = $adapter->commit_snapshot();
        if (!($committed['ok'] ?? false)) {
            throw new RuntimeException('source commit failed');
        }

        $finalized = $store->finalize_manifest($manifest_id);
        if (!($finalized['ok'] ?? false)) {
            throw new RuntimeException('E1 finalize failed');
        }

        $page = $store->read_page((string) $started['token'], null, 100);
        if (!($page['ok'] ?? false)) {
            throw new RuntimeException('E1 READY read failed');
        }

        return [
            'manifest_id' => $manifest_id,
            'manifest_hash' => $finalized['manifest_hash'],
            'items' => $page['items'],
            'captured' => $captured,
            'metrics' => $committed['metrics'],
            'status' => $store->manifest_status($manifest_id),
        ];
    } catch (Throwable $error) {
        $adapter->rollback_snapshot();
        $store->fail_manifest($manifest_id);
        throw $error;
    }
}

function eventsales_proof_ids(array $rows): array
{
    return array_map(static fn(array $row): string => (string) $row['source_order_id'], $rows);
}

function eventsales_proof_item_digest(array $rows): string
{
    return hash('sha256', json_encode($rows, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
}

/** @param array<string, mixed> $metrics */
function eventsales_proof_print_metrics(string $mode, array $metrics): void
{
    echo 'METRICS ' . $mode . ' ' . json_encode([
        'plan' => $metrics['plan'] ?? [],
        'rows_examined' => $metrics['rows_examined'] ?? null,
        'matching_rows' => $metrics['matching_rows'] ?? null,
        'chunks' => $metrics['chunks'] ?? null,
        'snapshot_duration_ms' => $metrics['snapshot_duration_ms'] ?? null,
        'largest_id_gap' => $metrics['largest_id_gap'] ?? null,
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR) . "\n";
}

require_once dirname(__DIR__) . '/eventsales-woo-order-index-manifest-store.php';
require_once dirname(__DIR__) . '/eventsales-woo-order-membership-source.php';

$wpdb = eventsales_proof_bootstrap_wordpress();
$modes = eventsales_proof_modes();
if (!defined('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION')) {
    define('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION', '2026-08-12.v1');
}
$original_option = $wpdb->get_var($wpdb->prepare(
    'SELECT option_value FROM ' . eventsales_proof_identifier($wpdb->options) . ' WHERE option_name = %s LIMIT 1',
    EVENTSALES_PROOF_OPTION
));
$had_original_option = $original_option !== null;
if (!EventSales_Woo_Order_Index_Manifest_Store::install_schema($wpdb)) {
    eventsales_proof_fail('E1 manifest schema installation failed on the local database');
}
EventSales_Membership_Proof_Test::ok(
    'public feed does not load the proof adapter',
    strpos((string) file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-index-feed.php'), 'EventSales_Woo_Order_Membership_Source') === false
);

try {
    foreach ($modes as $mode) {
        eventsales_proof_set_mode($wpdb, $mode);
        $fixtures = eventsales_proof_create_fixtures($wpdb, $mode);
        $ids = $fixtures['ids'];
        $source_db = eventsales_proof_new_db($wpdb);
        $mutation_db = eventsales_proof_new_db($wpdb);

        try {
            $baseline = eventsales_proof_capture($wpdb, $source_db, $mode);
            EventSales_Membership_Proof_Test::same(
                $mode . ' baseline membership',
                [(string) $ids['10'], (string) $ids['20'], (string) $ids['30'], (string) $ids['40']],
                eventsales_proof_ids($baseline['items'])
            );
            EventSales_Membership_Proof_Test::same(
                $mode . ' refund resource excluded',
                false,
                in_array((string) $ids['refund'], eventsales_proof_ids($baseline['items']), true)
            );
            EventSales_Membership_Proof_Test::same($mode . ' baseline READY', 'ready', $baseline['status']);
            EventSales_Membership_Proof_Test::ok($mode . ' bounded chunks', (int) $baseline['metrics']['chunks'] >= 2);
            EventSales_Membership_Proof_Test::ok($mode . ' plan captured', $baseline['metrics']['plan'] !== []);
            EventSales_Membership_Proof_Test::ok($mode . ' rows examined captured', $baseline['metrics']['rows_examined'] >= 0);
            EventSales_Membership_Proof_Test::ok($mode . ' snapshot duration captured', (float) $baseline['metrics']['snapshot_duration_ms'] >= 0.0);
            EventSales_Membership_Proof_Test::ok($mode . ' largest ID gap captured', (int) $baseline['metrics']['largest_id_gap'] >= 0);
            eventsales_proof_print_metrics($mode, $baseline['metrics']);

            $replay = eventsales_proof_capture($wpdb, eventsales_proof_new_db($wpdb), $mode);
            EventSales_Membership_Proof_Test::same(
                $mode . ' replay membership',
                eventsales_proof_ids($baseline['items']),
                eventsales_proof_ids($replay['items'])
            );
            EventSales_Membership_Proof_Test::same(
                $mode . ' replay item digest',
                eventsales_proof_item_digest($baseline['items']),
                eventsales_proof_item_digest($replay['items'])
            );
            EventSales_Membership_Proof_Test::ok(
                $mode . ' replay scope hashes boundary D separately',
                $baseline['manifest_hash'] !== $replay['manifest_hash']
            );

            $preflight_adapter = new EventSales_Woo_Order_Membership_Source($wpdb, eventsales_proof_new_db($wpdb));
            $preflight = $preflight_adapter->preflight();
            eventsales_proof_set_mode($wpdb, $mode === EVENTSALES_PROOF_HPOS ? EVENTSALES_PROOF_LEGACY : EVENTSALES_PROOF_HPOS);
            $mode_race = $preflight_adapter->open_snapshot($preflight);
            EventSales_Membership_Proof_Test::same($mode . ' storage authority race fails closed', false, $mode_race['ok'] ?? false);
            EventSales_Membership_Proof_Test::ok($mode . ' storage authority race has error', isset($mode_race['error']));
            eventsales_proof_set_mode($wpdb, $mode);

            $adversarial = eventsales_proof_capture($wpdb, eventsales_proof_new_db($wpdb), $mode, function () use ($wpdb, $mutation_db, $mode, $ids): void {
                eventsales_proof_update_fixture($mutation_db, $mode, $ids['10'], null, '2099-01-11 00:00:00.000000');
                eventsales_proof_update_fixture($mutation_db, $mode, $ids['40'], null, '2099-01-11 00:00:00.000000');
                eventsales_proof_update_fixture($mutation_db, $mode, $ids['30'], '2099-01-11 00:00:00.000000', null);
                eventsales_proof_update_fixture($mutation_db, $mode, $ids['outside'], '2099-01-10 13:00:00.000000', null);
                eventsales_proof_delete_fixture($mutation_db, $mode, $ids['40']);
                eventsales_proof_insert_fixture($mutation_db, $mode, $ids['post_d'], '2099-01-10 14:00:00.000000', '2099-01-11 00:00:00.000000', 'post-d');
            });
            EventSales_Membership_Proof_Test::same(
                $mode . ' concurrent membership remains frozen',
                [(string) $ids['10'], (string) $ids['20'], (string) $ids['30'], (string) $ids['40']],
                eventsales_proof_ids($adversarial['items'])
            );
            $by_id = [];
            foreach ($adversarial['items'] as $item) {
                $by_id[(string) $item['source_order_id']] = $item;
            }
            EventSales_Membership_Proof_Test::same($mode . ' seen modified timestamp frozen', '2099-01-10T10:00:00.000000Z', $by_id[(string) $ids['10']]['source_modified_at_gmt'] ?? null);
            EventSales_Membership_Proof_Test::same($mode . ' unseen modified timestamp frozen', '2099-01-10T10:00:00.000000Z', $by_id[(string) $ids['40']]['source_modified_at_gmt'] ?? null);
            EventSales_Membership_Proof_Test::same($mode . ' creation mutation does not remove member', true, isset($by_id[(string) $ids['30']]));
            EventSales_Membership_Proof_Test::same($mode . ' unseen deletion does not remove member', true, isset($by_id[(string) $ids['40']]));
            EventSales_Membership_Proof_Test::same($mode . ' post-D backdate does not add member', false, isset($by_id[(string) $ids['outside']]));
            EventSales_Membership_Proof_Test::same($mode . ' post-D historical insert does not add member', false, isset($by_id[(string) $ids['post_d']]));
            EventSales_Membership_Proof_Test::same($mode . ' equal creation timestamps included once', 2, count(array_filter($adversarial['items'], static fn(array $item): bool => in_array((string) $item['source_order_id'], [(string) $ids['20'], (string) $ids['30']], true))));
            EventSales_Membership_Proof_Test::same($mode . ' equal modified timestamps included once', 2, count(array_filter($adversarial['items'], static fn(array $item): bool => in_array((string) $item['source_order_id'], [(string) $ids['10'], (string) $ids['40']], true))));

            $failed_adapter = new EventSales_Woo_Order_Membership_Source($wpdb, eventsales_proof_new_db($wpdb));
            $failed_preflight = $failed_adapter->preflight();
            $failed_open = $failed_adapter->open_snapshot($failed_preflight);
            $failed_store = new EventSales_Woo_Order_Index_Manifest_Store($wpdb);
            $failed_start = $failed_store->begin_manifest(eventsales_proof_scope($mode, (string) $failed_open['source_observed_at_gmt']));
            $failed_chunk = $failed_adapter->read_chunk(EVENTSALES_PROOF_START, EVENTSALES_PROOF_CUTOFF, '0', 2);
            $failed_store->append_items((int) $failed_start['manifest_id'], $failed_chunk['rows']);
            $failed_adapter->rollback_snapshot();
            $failed_store->fail_manifest((int) $failed_start['manifest_id']);
            EventSales_Membership_Proof_Test::same($mode . ' failed capture is not READY', 'failed', $failed_store->manifest_status((int) $failed_start['manifest_id']));
            $retry = eventsales_proof_capture($wpdb, eventsales_proof_new_db($wpdb), $mode);
            EventSales_Membership_Proof_Test::same($mode . ' retry uses a new manifest', false, (int) $retry['manifest_id'] === (int) $failed_start['manifest_id']);
        } finally {
            foreach ($fixtures['all'] as $id) {
                eventsales_proof_delete_fixture($wpdb, $mode, (int) $id);
            }
        }
    }
} finally {
    eventsales_proof_restore_mode($wpdb, $original_option === null ? null : (string) $original_option, $had_original_option);
}

echo EventSales_Membership_Proof_Test::noFailures() ? "M3-01/02E2A membership proof PASS\n" : "M3-01/02E2A membership proof FAIL\n";
exit(EventSales_Membership_Proof_Test::noFailures() ? 0 : 1);
