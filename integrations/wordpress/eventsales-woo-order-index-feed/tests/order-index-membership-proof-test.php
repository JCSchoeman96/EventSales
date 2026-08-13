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
    $database_host = trim((string) getenv('EVENTSALES_WP_DB_HOST'));
    if ($database_host !== '') {
        if (
            !str_starts_with($database_host, 'localhost')
            && !str_starts_with($database_host, '127.0.0.1')
        ) {
            eventsales_proof_fail('EVENTSALES_WP_DB_HOST must be loopback');
        }
        define('DB_HOST', $database_host);
    }
    ob_start();
    set_error_handler(static function (int $severity, string $message): bool {
        return $severity === E_WARNING && str_contains($message, 'Constant DB_HOST already defined');
    }, E_WARNING);
    require $root . '/wp-load.php';
    restore_error_handler();
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
 * Exercise the source-owned continuation state machine independently of E1.
 */
function eventsales_proof_assert_continuation(object $wpdb, string $mode): void
{
    $adapter = new EventSales_Woo_Order_Membership_Source($wpdb, eventsales_proof_new_db($wpdb));
    $preflight = $adapter->preflight();
    $opened = $adapter->open_snapshot($preflight);
    if (!($opened['ok'] ?? false)) {
        throw new RuntimeException('continuation snapshot failed: ' . (string) ($opened['error'] ?? 'unknown'));
    }

    $candidate = $adapter->read_next_candidate(EVENTSALES_PROOF_START, EVENTSALES_PROOF_CUTOFF, 2);
    if (!($candidate['ok'] ?? false) || ($candidate['terminal'] ?? true) === true) {
        throw new RuntimeException('continuation candidate failed');
    }

    $jumped = $candidate;
    $jumped['candidate_next_id'] = (string) ((int) $candidate['candidate_next_id'] + 1000);
    EventSales_Membership_Proof_Test::same(
        $mode . ' arbitrary source continuation jump is rejected',
        false,
        $adapter->confirm_persisted($jumped)['ok'] ?? true
    );
    EventSales_Membership_Proof_Test::same(
        $mode . ' unconfirmed candidate replays exactly',
        $candidate,
        $adapter->read_next_candidate(EVENTSALES_PROOF_START, EVENTSALES_PROOF_CUTOFF, 2)
    );
    EventSales_Membership_Proof_Test::same(
        $mode . ' source commit before candidate confirmation is rejected',
        false,
        $adapter->commit_snapshot()['ok'] ?? true
    );

    $not_terminal_adapter = new EventSales_Woo_Order_Membership_Source($wpdb, eventsales_proof_new_db($wpdb));
    $not_terminal_preflight = $not_terminal_adapter->preflight();
    $not_terminal_opened = $not_terminal_adapter->open_snapshot($not_terminal_preflight);
    if (!($not_terminal_opened['ok'] ?? false)) {
        throw new RuntimeException('not-terminal guard snapshot failed: ' . (string) ($not_terminal_opened['error'] ?? 'unknown'));
    }
    $not_terminal_candidate = $not_terminal_adapter->read_next_candidate(EVENTSALES_PROOF_START, EVENTSALES_PROOF_CUTOFF, 2);
    $not_terminal_adapter->confirm_persisted($not_terminal_candidate);
    EventSales_Membership_Proof_Test::same(
        $mode . ' source commit after nonterminal confirmation is rejected',
        false,
        $not_terminal_adapter->commit_snapshot()['ok'] ?? true
    );

    $terminal_adapter = new EventSales_Woo_Order_Membership_Source($wpdb, eventsales_proof_new_db($wpdb));
    $terminal_preflight = $terminal_adapter->preflight();
    $terminal_opened = $terminal_adapter->open_snapshot($terminal_preflight);
    if (!($terminal_opened['ok'] ?? false)) {
        throw new RuntimeException('terminal guard snapshot failed: ' . (string) ($terminal_opened['error'] ?? 'unknown'));
    }

    while (true) {
        $next = $terminal_adapter->read_next_candidate(EVENTSALES_PROOF_START, EVENTSALES_PROOF_CUTOFF, 2);
        if (!($next['ok'] ?? false)) {
            throw new RuntimeException('terminal guard candidate failed');
        }
        if (($next['terminal'] ?? false) === true) {
            EventSales_Membership_Proof_Test::same(
                $mode . ' source commit before terminal confirmation is rejected',
                false,
                $terminal_adapter->commit_snapshot()['ok'] ?? true
            );
            break;
        }

        EventSales_Membership_Proof_Test::same(
            $mode . ' source candidate confirmation succeeds',
            true,
            $terminal_adapter->confirm_persisted($next)['ok'] ?? false
        );
    }

    $terminal_success_adapter = new EventSales_Woo_Order_Membership_Source($wpdb, eventsales_proof_new_db($wpdb));
    $terminal_success_preflight = $terminal_success_adapter->preflight();
    $terminal_success_opened = $terminal_success_adapter->open_snapshot($terminal_success_preflight);
    if (!($terminal_success_opened['ok'] ?? false)) {
        throw new RuntimeException('terminal success snapshot failed: ' . (string) ($terminal_success_opened['error'] ?? 'unknown'));
    }

    $previous_end_id = '0';
    while (true) {
        $next = $terminal_success_adapter->read_next_candidate(EVENTSALES_PROOF_START, EVENTSALES_PROOF_CUTOFF, 2);
        if (!($next['ok'] ?? false)) {
            throw new RuntimeException('terminal success candidate failed');
        }
        EventSales_Membership_Proof_Test::same(
            $mode . ' candidate starts at the confirmed cursor',
            $previous_end_id,
            (string) ($next['candidate_start_id'] ?? '')
        );
        EventSales_Membership_Proof_Test::same(
            $mode . ' terminal path confirmation succeeds',
            true,
            $terminal_success_adapter->confirm_persisted($next)['ok'] ?? false
        );
        if (($next['terminal'] ?? false) === true) {
            EventSales_Membership_Proof_Test::same(
                $mode . ' duplicate terminal confirmation is rejected',
                false,
                $terminal_success_adapter->confirm_persisted($next)['ok'] ?? true
            );
            break;
        }
        $previous_end_id = (string) $next['candidate_next_id'];
    }

    EventSales_Membership_Proof_Test::same(
        $mode . ' source commit after terminal confirmation succeeds',
        true,
        $terminal_success_adapter->commit_snapshot()['ok'] ?? false
    );
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
    $first = true;
    try {
        while (true) {
            $candidate = $adapter->read_next_candidate(EVENTSALES_PROOF_START, EVENTSALES_PROOF_CUTOFF, 2);
            if (!($candidate['ok'] ?? false)) {
                throw new RuntimeException('source candidate failed: ' . (string) ($candidate['error'] ?? 'unknown'));
            }

            if (($candidate['terminal'] ?? false) === true) {
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
            'token' => (string) $started['token'],
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

/**
 * Run the production builder against the existing local source fixtures.
 * Query metrics are enabled only for this representative benchmark; the
 * production builder default does not run EXPLAIN ANALYZE.
 *
 * @return array<string, mixed>
 */
function eventsales_proof_production_capture(object $wpdb, string $mode, int $limit = 2): array
{
    $builder = new EventSales_Woo_Order_Manifest_Builder(
        $wpdb,
        null,
        static function (object $wordpress_db, object $source_db): object {
            return new EventSales_Woo_Order_Membership_Source($wordpress_db, $source_db, null, true);
        }
    );
    $identity_space_size = eventsales_proof_identity_space_size($wpdb, $mode);
    $memory_before = memory_get_usage(true);
    $result = $builder->build([
        'source_system' => 'local-proof:production:' . $mode,
        'backfill_start' => EVENTSALES_PROOF_START,
        'backfill_cutoff' => EVENTSALES_PROOF_CUTOFF,
        'limit' => $limit,
    ]);
    $peak_memory = memory_get_peak_usage(true);
    $result['benchmark'] = [
        'source_mode' => $mode,
        'capture' => 'e2b-production-builder-benchmark',
        'total_source_identity_space_size' => $identity_space_size,
        'php_memory_before_bytes' => $memory_before,
        'php_peak_memory_bytes' => $peak_memory,
        'php_peak_memory_delta_bytes' => max(0, $peak_memory - $memory_before),
    ];

    return $result;
}

/** @return array<string, mixed> */
function eventsales_proof_production_catchup(object $wpdb, string $parent_token, string $source_system, int $limit = 100): array
{
    $builder = new EventSales_Woo_Order_Catchup_Manifest_Builder(
        $wpdb,
        null,
        static function (object $wordpress_db, object $source_db): object {
            return new EventSales_Woo_Order_Catchup_Source($wordpress_db, $source_db, null, true);
        }
    );

    return $builder->build([
        'parent_token' => $parent_token,
        'source_system' => $source_system,
        'limit' => $limit,
    ]);
}

function eventsales_proof_identity_space_size(object $wpdb, string $mode): int
{
    $table = eventsales_proof_identifier(eventsales_proof_table($wpdb, $mode));
    $type_field = $mode === EVENTSALES_PROOF_HPOS ? 'type' : 'post_type';
    $count = $wpdb->get_var($wpdb->prepare(
        'SELECT COUNT(*) FROM ' . $table . ' WHERE ' . eventsales_proof_identifier($type_field) . ' = %s',
        'shop_order'
    ));
    if (!is_numeric($count)) {
        throw new RuntimeException('source identity-space count failed');
    }

    return (int) $count;
}

/** @return array<string, mixed> */
function eventsales_proof_builder_lock_key(object $wpdb): array
{
    $builder = new EventSales_Woo_Order_Manifest_Builder($wpdb);
    $method = new ReflectionMethod($builder, 'lock_key');
    $method->setAccessible(true);

    return ['builder' => $builder, 'key' => (string) $method->invoke($builder)];
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
function eventsales_proof_print_metrics(string $mode, array $metrics, ?array $benchmark = null): void
{
    echo 'METRICS ' . $mode . ' ' . json_encode([
        'source_mode' => $mode,
        'capture' => $benchmark === null ? 'e2a-proof-adapter' : 'e2b-production-builder-benchmark',
        'total_source_identity_space_size' => $benchmark['total_source_identity_space_size'] ?? null,
        'matching_identities' => $metrics['matching_rows'] ?? null,
        'plan' => $metrics['plan'] ?? [],
        'query_key' => $metrics['plan'][0]['key'] ?? null,
        'rows_examined' => $metrics['rows_examined'] ?? null,
        'chunks' => $metrics['chunks'] ?? null,
        'snapshot_duration_ms' => $metrics['snapshot_duration_ms'] ?? null,
        'php_peak_memory_bytes' => $benchmark['php_peak_memory_bytes'] ?? null,
        'php_peak_memory_delta_bytes' => $benchmark['php_peak_memory_delta_bytes'] ?? null,
        'largest_id_gap' => $metrics['largest_id_gap'] ?? null,
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR) . "\n";
}

/** @param array<string, mixed> $metrics */
function eventsales_proof_print_catchup_metrics(string $mode, array $metrics): void
{
    echo 'CATCHUP_METRICS ' . $mode . ' ' . json_encode([
        'source_mode' => $mode,
        'parent_plan' => $metrics['parent_plan'] ?? [],
        'source_plan' => $metrics['source_plan'] ?? [],
        'parent_rows_examined' => $metrics['parent_rows_examined'] ?? null,
        'source_rows_examined' => $metrics['source_rows_examined'] ?? null,
        'matching_identities' => $metrics['matching_rows'] ?? null,
        'chunks' => $metrics['chunks'] ?? null,
        'snapshot_duration_ms' => $metrics['snapshot_duration_ms'] ?? null,
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR) . "\n";
}

require_once dirname(__DIR__) . '/eventsales-woo-order-index-manifest-store.php';
require_once dirname(__DIR__) . '/eventsales-woo-order-membership-source.php';
require_once dirname(__DIR__) . '/eventsales-woo-order-manifest-builder.php';

$wpdb = eventsales_proof_bootstrap_wordpress();
$modes = eventsales_proof_modes();
if (!defined('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION')) {
    define('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION', '2026-08-12.v1');
}
if (!defined('EVENTSALES_WOO_ORDER_INDEX_KEY_ID')) {
    define('EVENTSALES_WOO_ORDER_INDEX_KEY_ID', 'local-proof-key');
}
if (!defined('EVENTSALES_WOO_ORDER_INDEX_SECRET')) {
    define('EVENTSALES_WOO_ORDER_INDEX_SECRET', 'local-proof-secret');
}
if (!class_exists('WP_REST_Request')) {
    require_once ABSPATH . WPINC . '/rest-api/class-wp-rest-request.php';
}
if (!class_exists('WP_REST_Response')) {
    require_once ABSPATH . WPINC . '/rest-api/class-wp-rest-response.php';
}
if (!class_exists('EventSales_Woo_Order_Index_Feed')) {
    require_once dirname(__DIR__) . '/eventsales-woo-order-index-feed.php';
}

/** @param array<string, mixed> $query @param array<string, mixed> $body */
function eventsales_proof_signed_request(string $method, string $path, array $query, array $body, array $url_params = []): WP_REST_Request
{
    $raw_body = $body === [] ? '' : (string) json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    $timestamp = (string) time();
    $base = EventSales_Woo_Order_Index_Feed::canonical_signature_input(
        $method,
        $path,
        EventSales_Woo_Order_Index_Feed::canonical_query_string($query),
        $raw_body,
        $timestamp,
        EVENTSALES_WOO_ORDER_INDEX_KEY_ID
    );
    $request = new WP_REST_Request($method, $path);
    $request->set_query_params($query);
    $request->set_url_params($url_params);
    $request->set_body($raw_body);
    $request->set_headers([
        'X-EventSales-Key-Id' => EVENTSALES_WOO_ORDER_INDEX_KEY_ID,
        'X-EventSales-Timestamp' => $timestamp,
        'X-EventSales-Signature' => 'v1=' . hash_hmac('sha256', $base, EVENTSALES_WOO_ORDER_INDEX_SECRET),
    ]);
    $_SERVER['REQUEST_URI'] = $path;

    return $request;
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
    'public feed loads the production source and builder only',
    strpos((string) file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-index-feed.php'), "eventsales-woo-order-membership-source.php") !== false
        && strpos((string) file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-index-feed.php'), "eventsales-woo-order-manifest-builder.php") !== false
        && strpos((string) file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-index-feed.php'), 'eventsales-tickera-catalog-feed') === false
);

try {
    foreach ($modes as $mode) {
        eventsales_proof_set_mode($wpdb, $mode);
        $fixtures = eventsales_proof_create_fixtures($wpdb, $mode);
        $ids = $fixtures['ids'];
        $source_db = eventsales_proof_new_db($wpdb);
        $mutation_db = eventsales_proof_new_db($wpdb);

        try {
            eventsales_proof_assert_continuation($wpdb, $mode);
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

            eventsales_proof_update_fixture($mutation_db, $mode, $ids['10'], null, '2099-01-11 00:00:00.000000');
            eventsales_proof_update_fixture($mutation_db, $mode, $ids['20'], null, '2099-01-09 00:00:00.000000');
            eventsales_proof_update_fixture($mutation_db, $mode, $ids['30'], '2099-01-11 00:00:00.000000', null);
            eventsales_proof_update_fixture($mutation_db, $mode, $ids['40'], '2099-01-09 00:00:00.000000', null);
            eventsales_proof_insert_fixture($mutation_db, $mode, $ids['post_d'], '2099-01-10 14:00:00.000000', '2099-01-11 00:00:00.000000', 'catchup-post-d');
            $catchup = eventsales_proof_production_catchup($wpdb, (string) $baseline['token'], 'local-proof:' . $mode);
            EventSales_Membership_Proof_Test::same($mode . ' catch-up returns READY', true, $catchup['ok'] ?? false);
            EventSales_Membership_Proof_Test::same($mode . ' catch-up phase', 'catch_up', $catchup['page']['phase'] ?? null);
            EventSales_Membership_Proof_Test::same(
                $mode . ' catch-up contains changed M members in parent order',
                [(string) $ids['10'], (string) $ids['20'], (string) $ids['30'], (string) $ids['40']],
                eventsales_proof_ids($catchup['page']['items'] ?? [])
            );
            $catchup_items_by_id = [];
            foreach ($catchup['page']['items'] ?? [] as $item) {
                $catchup_items_by_id[(string) $item['source_order_id']] = $item;
            }
            EventSales_Membership_Proof_Test::same($mode . ' catch-up includes backdated modified inequality', '2099-01-09T00:00:00.000000Z', $catchup_items_by_id[(string) $ids['20']]['source_modified_at_gmt'] ?? null);
            EventSales_Membership_Proof_Test::same($mode . ' catch-up includes backdated created inequality', '2099-01-09T00:00:00.000000Z', $catchup_items_by_id[(string) $ids['40']]['source_created_at_gmt'] ?? null);
            EventSales_Membership_Proof_Test::same($mode . ' catch-up source metrics mode', $mode, $catchup['metrics']['mode'] ?? null);
            EventSales_Membership_Proof_Test::ok($mode . ' catch-up parent plan captured', ($catchup['metrics']['parent_plan'] ?? []) !== []);
            EventSales_Membership_Proof_Test::ok($mode . ' catch-up source plan captured', ($catchup['metrics']['source_plan'] ?? []) !== []);
            EventSales_Membership_Proof_Test::ok($mode . ' catch-up parent rows examined captured', (int) ($catchup['metrics']['parent_rows_examined'] ?? -1) >= 0);
            EventSales_Membership_Proof_Test::ok($mode . ' catch-up source rows examined captured', (int) ($catchup['metrics']['source_rows_examined'] ?? -1) >= 0);
            EventSales_Membership_Proof_Test::ok($mode . ' catch-up snapshot is within five seconds', (float) ($catchup['metrics']['snapshot_duration_ms'] ?? 6000) <= 5000.0);
            eventsales_proof_print_catchup_metrics($mode, $catchup['metrics']);
            EventSales_Membership_Proof_Test::same($mode . ' catch-up excludes post-D nonmember', false, in_array((string) $ids['post_d'], eventsales_proof_ids($catchup['page']['items'] ?? []), true));
            $catchup_store = new EventSales_Woo_Order_Index_Manifest_Store($wpdb);
            $parent_metadata = $catchup_store->manifest_metadata((int) $baseline['manifest_id']);
            $child_metadata = $catchup_store->manifest_metadata((int) $catchup['manifest_id']);
            EventSales_Membership_Proof_Test::same($mode . ' catch-up preserves parent B', $parent_metadata['backfill_start_gmt'] ?? null, $child_metadata['backfill_start_gmt'] ?? null);
            EventSales_Membership_Proof_Test::same($mode . ' catch-up preserves parent C', $parent_metadata['backfill_cutoff_gmt'] ?? null, $child_metadata['backfill_cutoff_gmt'] ?? null);
            EventSales_Membership_Proof_Test::same($mode . ' catch-up binds parent hash', $baseline['manifest_hash'], $child_metadata['parent_manifest_hash'] ?? null);
            EventSales_Membership_Proof_Test::same($mode . ' catch-up binds D', $parent_metadata['source_observed_at_gmt'] ?? null, $child_metadata['catchup_from_gmt'] ?? null);
            EventSales_Membership_Proof_Test::ok($mode . ' catch-up H is not before D', ($child_metadata['source_observed_at_gmt'] ?? '') >= ($child_metadata['catchup_from_gmt'] ?? ''));

            eventsales_proof_delete_fixture($mutation_db, $mode, $ids['40']);
            $missing_catchup = eventsales_proof_production_catchup($wpdb, (string) $baseline['token'], 'local-proof:' . $mode);
            EventSales_Membership_Proof_Test::same($mode . ' deleted M member fails closed', 'catchup_member_unresolved', $missing_catchup['error'] ?? null);
            eventsales_proof_insert_fixture($mutation_db, $mode, $ids['40'], EVENTSALES_PROOF_CUTOFF, '2099-01-10 10:00:00.000000', 'catchup-restored');
            eventsales_proof_delete_fixture($mutation_db, $mode, $ids['post_d']);
            eventsales_proof_update_fixture($mutation_db, $mode, $ids['10'], null, '2099-01-10 10:00:00.000000');
            eventsales_proof_update_fixture($mutation_db, $mode, $ids['20'], null, '2099-01-10 12:00:00.000000');
            eventsales_proof_update_fixture($mutation_db, $mode, $ids['30'], '2099-01-10 12:00:00.000000', null);

            $production = eventsales_proof_production_capture($wpdb, $mode, 2);
            EventSales_Membership_Proof_Test::same($mode . ' production builder returns READY', true, $production['ok'] ?? false);
            EventSales_Membership_Proof_Test::same($mode . ' production builder status', 'ready', $production['status'] ?? null);
            EventSales_Membership_Proof_Test::same(
                $mode . ' production builder first page includes inclusive B/C members in order',
                [(string) $ids['10'], (string) $ids['20']],
                eventsales_proof_ids($production['page']['items'] ?? [])
            );
            EventSales_Membership_Proof_Test::same($mode . ' production POST page honors limit=2', 2, count($production['page']['items'] ?? []));
            EventSales_Membership_Proof_Test::same($mode . ' production first page is nonterminal', true, $production['page']['has_more'] ?? false);
            EventSales_Membership_Proof_Test::ok($mode . ' production first page has a continuation sequence', is_int($production['page']['next_sequence'] ?? null));
            $production_store = new EventSales_Woo_Order_Index_Manifest_Store($wpdb);
            $production_continuation = $production_store->read_page((string) $production['token'], (int) $production['page']['next_sequence'], 100);
            EventSales_Membership_Proof_Test::same(
                $mode . ' existing E1 reader returns remaining production identities',
                [(string) $ids['30'], (string) $ids['40']],
                eventsales_proof_ids($production_continuation['items'] ?? [])
            );
            EventSales_Membership_Proof_Test::same($mode . ' production GET continuation is terminal', false, $production_continuation['has_more'] ?? true);
            EventSales_Membership_Proof_Test::ok($mode . ' production GET continuation returns terminal evidence', is_string($production_continuation['terminal_evidence'] ?? null) && $production_continuation['terminal_evidence'] !== '');
            $post_builder = new EventSales_Woo_Order_Manifest_Builder($wpdb);
            $post_controller = new EventSales_Woo_Order_Index_Feed(static fn(object $database): object => $post_builder);
            $post_path = '/wp-json/eventsales/v1/woo-order-index/manifests';
            $post_response = $post_controller->handle_manifest_create(eventsales_proof_signed_request('POST', $post_path, [], [
                'source_system' => 'local-proof:http:' . $mode,
                'backfill_start' => EVENTSALES_PROOF_START,
                'backfill_cutoff' => EVENTSALES_PROOF_CUTOFF,
                'limit' => 2,
            ]));
            EventSales_Membership_Proof_Test::same($mode . ' authenticated production POST returns READY', 200, $post_response->get_status());
            EventSales_Membership_Proof_Test::same($mode . ' authenticated production POST returns first page', [(string) $ids['10'], (string) $ids['20']], eventsales_proof_ids($post_response->get_data()['items'] ?? []));
            EventSales_Membership_Proof_Test::ok($mode . ' authenticated production POST returns at most requested limit', count($post_response->get_data()['items'] ?? []) <= 2);
            EventSales_Membership_Proof_Test::ok($mode . ' authenticated production POST is nonterminal', ($post_response->get_data()['has_more'] ?? false) === true && isset($post_response->get_data()['next_cursor']) && !array_key_exists('terminal_evidence', $post_response->get_data()));
            $post_token = (string) ($post_response->get_data()['boundary_token'] ?? '');
            $get_path = '/wp-json/eventsales/v1/woo-order-index/manifests/' . $post_token;
            $get_response = $post_controller->handle_manifest_fetch(eventsales_proof_signed_request('GET', $get_path, ['cursor' => (string) $post_response->get_data()['next_cursor']], [], ['token' => $post_token]));
            EventSales_Membership_Proof_Test::same($mode . ' authenticated production GET continuation returns remaining identities', [(string) $ids['30'], (string) $ids['40']], eventsales_proof_ids($get_response->get_data()['items'] ?? []));
            EventSales_Membership_Proof_Test::same($mode . ' authenticated production GET continuation is terminal', false, $get_response->get_data()['has_more'] ?? true);
            EventSales_Membership_Proof_Test::ok($mode . ' authenticated production GET continuation returns final evidence', is_string($get_response->get_data()['terminal_evidence'] ?? null) && !array_key_exists('next_cursor', $get_response->get_data()));
            EventSales_Membership_Proof_Test::same($mode . ' production metrics mode', $mode, $production['benchmark']['source_mode'] ?? null);
            EventSales_Membership_Proof_Test::same($mode . ' production metrics matching identities', 4, $production['metrics']['matching_rows'] ?? null);
            EventSales_Membership_Proof_Test::ok($mode . ' production snapshot is within five seconds', (float) ($production['metrics']['snapshot_duration_ms'] ?? 6000) <= 5000.0);
            eventsales_proof_print_metrics($mode, $production['metrics'], $production['benchmark']);

            usleep(1000);
            $production_replay = eventsales_proof_production_capture($wpdb, $mode, 2);
            EventSales_Membership_Proof_Test::same($mode . ' later production replay is READY', true, $production_replay['ok'] ?? false);
            EventSales_Membership_Proof_Test::ok($mode . ' later production replay uses a new manifest', (int) ($production['manifest_id'] ?? 0) !== (int) ($production_replay['manifest_id'] ?? 0));
            EventSales_Membership_Proof_Test::ok($mode . ' later production replay uses a new token', (string) ($production['token'] ?? '') !== (string) ($production_replay['token'] ?? ''));
            EventSales_Membership_Proof_Test::ok($mode . ' later production replay establishes a new D', (string) ($production['source_observed_at_gmt'] ?? '') !== (string) ($production_replay['source_observed_at_gmt'] ?? ''));

            $lock_context = eventsales_proof_builder_lock_key($wpdb);
            $lock_db = eventsales_proof_new_db($wpdb);
            $lock_taken = $lock_db->get_var($lock_db->prepare('SELECT GET_LOCK(%s, 0)', $lock_context['key']));
            EventSales_Membership_Proof_Test::same($mode . ' source-scoped lock acquired for concurrency test', '1', (string) $lock_taken);
            try {
                $busy = $lock_context['builder']->build([
                    'source_system' => 'local-proof:busy:' . $mode,
                    'backfill_start' => EVENTSALES_PROOF_START,
                    'backfill_cutoff' => EVENTSALES_PROOF_CUTOFF,
                    'limit' => 2,
                ]);
                EventSales_Membership_Proof_Test::same($mode . ' simultaneous production capture returns busy', 'busy', $busy['error'] ?? null);
            } finally {
                $lock_db->get_var($lock_db->prepare('SELECT RELEASE_LOCK(%s)', $lock_context['key']));
            }

            $authority_builder = new EventSales_Woo_Order_Manifest_Builder(
                $wpdb,
                null,
                static function (object $wordpress_db, object $source_db) use ($mode): object {
                    $wrong_mode = $mode === EVENTSALES_PROOF_HPOS ? false : true;

                    return new EventSales_Woo_Order_Membership_Source($wordpress_db, $source_db, static function () use ($wrong_mode): bool {
                        return $wrong_mode;
                    });
                }
            );
            $authority_failure = $authority_builder->build([
                'source_system' => 'local-proof:authority:' . $mode,
                'backfill_start' => EVENTSALES_PROOF_START,
                'backfill_cutoff' => EVENTSALES_PROOF_CUTOFF,
                'limit' => 2,
            ]);
            EventSales_Membership_Proof_Test::same($mode . ' authority mismatch has no READY result', false, $authority_failure['ok'] ?? true);
            EventSales_Membership_Proof_Test::same($mode . ' authority mismatch is bounded', 'source_authority_changed', $authority_failure['error'] ?? null);

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
            $failed_candidate = $failed_adapter->read_next_candidate(EVENTSALES_PROOF_START, EVENTSALES_PROOF_CUTOFF, 2);
            $failed_store->append_items((int) $failed_start['manifest_id'], $failed_candidate['rows']);
            $failed_adapter->confirm_persisted($failed_candidate);
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
