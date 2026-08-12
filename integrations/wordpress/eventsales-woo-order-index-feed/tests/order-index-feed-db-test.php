<?php

declare(strict_types=1);

/**
 * Database-backed E1 contract tests.
 *
 * The harness intentionally uses the active local WordPress MySQL service,
 * never a remote or production database. Credentials are supplied through
 * environment variables so they are not written to output or source.
 */

$required = [
    'EVENTSALES_WP_ROOT',
    'EVENTSALES_WP_DB_HOST',
    'EVENTSALES_WP_DB_NAME',
    'EVENTSALES_WP_DB_USER',
    'EVENTSALES_WP_DB_PASSWORD',
];

foreach ($required as $name) {
    if (!is_string(getenv($name)) || getenv($name) === '') {
        fwrite(STDERR, "Missing required local database variable: {$name}\n");
        exit(2);
    }
}

$db_host = (string) getenv('EVENTSALES_WP_DB_HOST');
$host_without_socket = explode(':/', $db_host, 2)[0];
$host_without_port = preg_replace('/:\d+$/', '', $host_without_socket);
if (!in_array($host_without_port, ['127.0.0.1', 'localhost'], true)) {
    fwrite(STDERR, "Refusing non-loopback WordPress database host.\n");
    exit(2);
}

$wordpress_root = rtrim((string) getenv('EVENTSALES_WP_ROOT'), '/');
if (!is_file($wordpress_root . '/wp-includes/class-wpdb.php')) {
    fwrite(STDERR, "EVENTSALES_WP_ROOT is not a WordPress installation.\n");
    exit(2);
}

define('ABSPATH', $wordpress_root . '/');
define('WP_DEBUG', false);
define('WP_DEBUG_DISPLAY', false);
define('WP_CONTENT_DIR', $wordpress_root . '/wp-content');

if (!function_exists('absint')) {
    function absint($value): int
    {
        return abs((int) $value);
    }
}

if (!function_exists('wp_load_translations_early')) {
    function wp_load_translations_early(): void
    {
    }
}

if (!function_exists('__')) {
    function __($text, $domain = null): string
    {
        return (string) $text;
    }
}

if (!function_exists('apply_filters')) {
    function apply_filters($hook, $value, ...$args)
    {
        return $value;
    }
}

if (!function_exists('has_filter')) {
    function has_filter($hook_name, $callback = false)
    {
        return false;
    }
}

if (!function_exists('add_filter')) {
    function add_filter($hook_name, $callback, $priority = 10, $accepted_args = 1)
    {
        return true;
    }
}

if (!function_exists('wp_debug_backtrace_summary')) {
    function wp_debug_backtrace_summary($ignore_class = null, $skip_frames = 0, $pretty = true): string
    {
        return '';
    }
}

if (!function_exists('is_multisite')) {
    function is_multisite(): bool
    {
        return false;
    }
}

require_once $wordpress_root . '/wp-includes/class-wpdb.php';

mysqli_report(MYSQLI_REPORT_OFF);

$wpdb = new wpdb(
    (string) getenv('EVENTSALES_WP_DB_USER'),
    (string) getenv('EVENTSALES_WP_DB_PASSWORD'),
    (string) getenv('EVENTSALES_WP_DB_NAME'),
    $db_host
);
$wpdb->set_prefix((string) (getenv('EVENTSALES_WP_TABLE_PREFIX') ?: 'wp_'));
$wpdb->suppress_errors(true);

if ($wpdb->last_error !== '') {
    fwrite(STDERR, "Local WordPress database connection failed.\n");
    exit(2);
}

$GLOBALS['wpdb'] = $wpdb;
$GLOBALS['options'] = [
    'eventsales_woo_order_index_key_id' => 'order-index-key-1',
    'eventsales_woo_order_index_secret' => 'order-index-secret',
];
$GLOBALS['registered_routes'] = [];

function add_action($hook, $callback, $priority = 10, $accepted_args = 1)
{
    return true;
}

function register_activation_hook($file, $callback)
{
    return true;
}

function register_rest_route($namespace, $route, $args)
{
    $GLOBALS['registered_routes'][] = compact('namespace', 'route', 'args');

    return true;
}

function get_option($name, $default = false)
{
    return array_key_exists($name, $GLOBALS['options']) ? $GLOBALS['options'][$name] : $default;
}

function update_option($name, $value, $autoload = null)
{
    $GLOBALS['options'][$name] = $value;

    return true;
}

final class WP_REST_Request
{
    /** @var array<string, mixed> */
    private array $headers;

    public function __construct(
        private string $method,
        private string $route,
        private array $query_params = [],
        private string $body = '',
        array $headers = [],
        private array $url_params = []
    ) {
        $this->headers = [];
        foreach ($headers as $key => $value) {
            $this->headers[strtolower((string) $key)] = $value;
        }
    }

    public function get_method(): string
    {
        return $this->method;
    }

    public function get_route(): string
    {
        return $this->route;
    }

    public function get_header($key)
    {
        return $this->headers[strtolower((string) $key)] ?? '';
    }

    /** @return array<string, mixed> */
    public function get_query_params(): array
    {
        return $this->query_params;
    }

    public function get_param($key)
    {
        return $this->url_params[$key] ?? $this->query_params[$key] ?? null;
    }

    public function get_body(): string
    {
        return $this->body;
    }
}

final class WP_REST_Response
{
    public function __construct(private array $data, private int $status = 200)
    {
    }

    /** @return array<string, mixed> */
    public function get_data(): array
    {
        return $this->data;
    }

    public function get_status(): int
    {
        return $this->status;
    }
}

require dirname(__DIR__) . '/eventsales-woo-order-index-feed.php';

final class T
{
    public static int $passes = 0;

    /** @var array<int, string> */
    public static array $failures = [];

    public static function ok(string $label, bool $condition): void
    {
        if ($condition) {
            self::$passes++;
        } else {
            self::$failures[] = $label;
        }
    }

    public static function same(string $label, $expected, $actual): void
    {
        if ($expected === $actual) {
            self::$passes++;
        } else {
            self::$failures[] = $label . ' [expected ' . self::render($expected) . ' got ' . self::render($actual) . ']';
        }
    }

    public static function section(string $name): void
    {
        echo '-- ' . $name . "\n";
    }

    private static function render($value): string
    {
        $encoded = json_encode($value);

        return $encoded === false ? var_export($value, true) : (string) $encoded;
    }
}

/** @return Generator<int, array<string, string>> */
function identity_rows(int $start, int $count, string $created = '2026-08-02T00:00:00Z'): Generator
{
    $created_at = new DateTimeImmutable($created, new DateTimeZone('UTC'));

    for ($offset = 0; $offset < $count; $offset++) {
        $id = $start + $offset;
        yield [
            'source_order_id' => (string) $id,
            'source_created_at_gmt' => $created_at->modify('+' . $offset . ' seconds')->format('Y-m-d\TH:i:s\Z'),
            'source_modified_at_gmt' => $created_at->modify('+' . ($offset + 1) . ' seconds')->format('Y-m-d\TH:i:s\Z'),
        ];
    }
}

function manifest_scope(array $overrides = []): array
{
    return array_merge([
        'source_system' => 'wordpress_woo:localhost',
        'backfill_start_gmt' => '2026-08-01T00:00:00Z',
        'backfill_cutoff_gmt' => '2026-08-12T00:00:00Z',
        'source_observed_at_gmt' => '2026-08-12T12:00:00Z',
        'membership_predicate_version' => 'woo_creation_window_v1',
    ], $overrides);
}

function db_query(string $sql): mixed
{
    global $wpdb;
    $result = $wpdb->query($sql);
    if ($result === false) {
        throw new RuntimeException('database query failed');
    }

    return $result;
}

function table_columns(string $table): array
{
    global $wpdb;

    return array_map(
        static fn(array $row): string => (string) $row['Field'],
        $wpdb->get_results("SHOW COLUMNS FROM `{$table}`", ARRAY_A)
    );
}

function table_indexes(string $table): array
{
    global $wpdb;

    return $wpdb->get_results("SHOW INDEX FROM `{$table}`", ARRAY_A);
}

function signed_request(
    string $method,
    string $path,
    array $query,
    string $body,
    array $url_params = [],
    string $secret = 'order-index-secret'
): WP_REST_Request {
    $timestamp = (string) time();
    $key_id = 'order-index-key-1';
    $signature_input = EventSales_Woo_Order_Index_Feed::canonical_signature_input(
        $method,
        $path,
        EventSales_Woo_Order_Index_Feed::canonical_query_string($query),
        $body,
        $timestamp,
        $key_id
    );
    $headers = [
        'X-EventSales-Key-Id' => $key_id,
        'X-EventSales-Timestamp' => $timestamp,
        'X-EventSales-Signature' => 'v1=' . hash_hmac('sha256', $signature_input, $secret),
    ];
    $_SERVER['REQUEST_URI'] = $path;
    if ($query !== []) {
        $_SERVER['REQUEST_URI'] .= '?' . EventSales_Woo_Order_Index_Feed::canonical_query_string($query);
    }

    return new WP_REST_Request($method, $path, $query, $body, $headers, $url_params);
}

$manifest_table = $wpdb->prefix . 'eventsales_order_manifests';
$item_table = $wpdb->prefix . 'eventsales_order_manifest_items';

register_shutdown_function(static function () use ($manifest_table, $item_table): void {
    global $wpdb;
    if (!isset($wpdb) || !is_object($wpdb)) {
        return;
    }

    $wpdb->query("DROP TABLE IF EXISTS `{$item_table}`");
    $wpdb->query("DROP TABLE IF EXISTS `{$manifest_table}`");
});

try {
    db_query("DROP TABLE IF EXISTS `{$item_table}`");
    db_query("DROP TABLE IF EXISTS `{$manifest_table}`");

    $now = new DateTimeImmutable('2026-08-12T12:00:00Z');
    $store = new EventSales_Woo_Order_Index_Manifest_Store($wpdb, static function () use (&$now): DateTimeImmutable {
        return $now;
    });

    T::section('schema and database invariants');
    T::ok('schema installation succeeds', EventSales_Woo_Order_Index_Manifest_Store::install_schema($wpdb));
    T::ok('schema installation is idempotent', EventSales_Woo_Order_Index_Manifest_Store::install_schema($wpdb));
    T::ok('manifest table exists', $wpdb->get_var("SHOW TABLES LIKE '{$manifest_table}'") === $manifest_table);
    T::ok('item table exists', $wpdb->get_var("SHOW TABLES LIKE '{$item_table}'") === $item_table);

    $manifest_columns = table_columns($manifest_table);
    $item_columns = table_columns($item_table);
    T::ok('manifest header has no raw token column', !in_array('token', $manifest_columns, true));
    T::same('manifest header fields are bounded to the contract', [
        'id',
        'token_hash',
        'schema_version',
        'source_system',
        'backfill_start_gmt',
        'backfill_cutoff_gmt',
        'source_observed_at_gmt',
        'membership_predicate_version',
        'status',
        'created_at_gmt',
        'expires_at_gmt',
        'completed_at_gmt',
        'item_count',
        'manifest_hash',
        'terminal_evidence',
    ], $manifest_columns);
    T::same('manifest items contain identity metadata only', [
        'manifest_id',
        'sequence',
        'source_order_id',
        'source_created_at_gmt',
        'source_modified_at_gmt',
    ], $item_columns);

    $indexes = table_indexes($manifest_table);
    $item_indexes = table_indexes($item_table);
    $token_index = array_values(array_filter($indexes, static fn(array $row): bool => $row['Key_name'] === 'token_hash'));
    $status_index = array_values(array_filter($indexes, static fn(array $row): bool => $row['Key_name'] === 'status_expires'));
    $item_order_index = array_values(array_filter($item_indexes, static fn(array $row): bool => $row['Key_name'] === 'manifest_order'));
    $item_primary = array_values(array_filter($item_indexes, static fn(array $row): bool => $row['Key_name'] === 'PRIMARY'));
    T::same('token hash is unique', 0, (int) ($token_index[0]['Non_unique'] ?? 1));
    T::same('status/expiry cleanup index is ordered', ['status', 'expires_at_gmt'], array_column($status_index, 'Column_name'));
    T::same('source order identity is unique per manifest', 0, (int) ($item_order_index[0]['Non_unique'] ?? 1));
    T::same('manifest sequence is the paging primary key', ['manifest_id', 'sequence'], array_column($item_primary, 'Column_name'));

    T::section('token, immutable storage, and deterministic hash');
    $token_a = EventSales_Woo_Order_Index_Manifest_Store::generate_token();
    $token_b = EventSales_Woo_Order_Index_Manifest_Store::generate_token();
    T::ok('tokens have at least 128 bits of entropy', strlen($token_a) >= 32 && preg_match('/^[a-f0-9]+$/D', $token_a) === 1);
    T::ok('token generation is not sequential', $token_a !== $token_b);

    $first = $store->store_resolved_manifest(manifest_scope(), identity_rows(1001, 3));
    T::ok('resolved identity set becomes READY', $first['ok'] === true && $first['status'] === 'ready');
    T::same('default TTL is 24 hours', '2026-08-13T12:00:00.000000Z', $first['expires_at_gmt'] ?? null);
    T::ok('raw token is returned only by the internal result', is_string($first['token'] ?? null));
    T::same('stored token is lookup hash only', hash('sha256', $first['token']), $first['token_hash']);
    $stored_token = $wpdb->get_var($wpdb->prepare("SELECT token_hash FROM `{$manifest_table}` WHERE id = %d", $first['manifest_id']));
    T::same('raw token is not stored in the header', $first['token_hash'], $stored_token);
    T::ok('raw token does not affect membership hash', $first['manifest_hash'] === $store->store_resolved_manifest(manifest_scope(), identity_rows(1001, 3))['manifest_hash']);
    T::ok('item mutation changes membership hash', $first['manifest_hash'] !== $store->store_resolved_manifest(
        manifest_scope(),
        identity_rows(1001, 3, '2026-08-03T00:00:00Z')
    )['manifest_hash']);
    T::ok('scope B/C/D changes membership hash', $first['manifest_hash'] !== $store->store_resolved_manifest(
        manifest_scope(['backfill_cutoff_gmt' => '2026-08-11T00:00:00Z']),
        identity_rows(1001, 3)
    )['manifest_hash']);

    $first_page = $store->read_page($first['token'], null, 100);
    T::ok('READY manifest is readable', $first_page['ok'] === true);
    T::same('sequence is deterministic', [1001, 1002, 1003], array_map(
        static fn(array $item): int => (int) $item['source_order_id'],
        $first_page['items']
    ));
    T::same('identity response has no PII fields', [
        'source_order_id',
        'source_created_at_gmt',
        'source_modified_at_gmt',
    ], array_keys($first_page['items'][0]));
    T::same('terminal evidence is stored and returned', $first['terminal_evidence'], $first_page['terminal_evidence']);
    T::same('terminal page has no continuation', false, $first_page['has_more']);

    T::section('lifecycle and immutability');
    $building = $store->begin_manifest(manifest_scope());
    T::ok('BUILDING manifest is created', $building['ok'] === true && $building['status'] === 'building');
    T::same('BUILDING manifest has no readable membership', 'manifest_not_ready', $store->read_page($building['token'], null, 100)['error'] ?? null);
    T::ok('append accepts synthetic identity rows', $store->append_items($building['manifest_id'], identity_rows(2001, 2))['ok'] === true);
    T::ok('finalization promotes only complete storage', $store->finalize_manifest($building['manifest_id'])['ok'] === true);
    T::same('finalized BUILDING manifest is READY', 'ready', $store->manifest_status($building['manifest_id']));
    T::ok('API cannot append to READY', $store->append_items($building['manifest_id'], identity_rows(3001, 1))['ok'] === false);

    $ready_item_id = $wpdb->get_var($wpdb->prepare("SELECT source_order_id FROM `{$item_table}` WHERE manifest_id = %d LIMIT 1", $building['manifest_id']));
    T::ok('database blocks READY item update', $wpdb->query($wpdb->prepare(
        "UPDATE `{$item_table}` SET source_order_id = %s WHERE manifest_id = %d AND source_order_id = %s",
        '9999',
        $building['manifest_id'],
        $ready_item_id
    )) === false);
    T::ok('database blocks READY item delete', $wpdb->query($wpdb->prepare(
        "DELETE FROM `{$item_table}` WHERE manifest_id = %d AND source_order_id = %s",
        $building['manifest_id'],
        $ready_item_id
    )) === false);
    T::ok('database blocks READY item append', $wpdb->query($wpdb->prepare(
        "INSERT INTO `{$item_table}` (manifest_id, sequence, source_order_id, source_created_at_gmt, source_modified_at_gmt) VALUES (%d, %d, %s, %s, %s)",
        $building['manifest_id'],
        99,
        '9999',
        '2026-08-02T00:00:00.000000Z',
        '2026-08-02T00:00:01.000000Z'
    )) === false);
    T::ok('database blocks READY membership header mutation', $wpdb->query($wpdb->prepare(
        "UPDATE `{$manifest_table}` SET backfill_cutoff_gmt = %s WHERE id = %d",
        '2026-08-13T00:00:00.000000Z',
        $building['manifest_id']
    )) === false);

    $duplicate = $store->begin_manifest(manifest_scope());
    T::ok('duplicate source identity is rejected within one manifest', $store->append_items($duplicate['manifest_id'], [
        [
            'source_order_id' => '77',
            'source_created_at_gmt' => '2026-08-02T00:00:00Z',
            'source_modified_at_gmt' => '2026-08-02T00:00:01Z',
        ],
        [
            'source_order_id' => '77',
            'source_created_at_gmt' => '2026-08-02T00:00:00Z',
            'source_modified_at_gmt' => '2026-08-02T00:00:01Z',
        ],
    ])['ok'] === false);
    $same_order_other_manifest = $store->begin_manifest(manifest_scope(['source_observed_at_gmt' => '2026-08-12T12:01:00Z']));
    T::ok('same source identity is allowed in another manifest', $store->append_items($same_order_other_manifest['manifest_id'], [
        [
            'source_order_id' => '77',
            'source_created_at_gmt' => '2026-08-02T00:00:00Z',
            'source_modified_at_gmt' => '2026-08-02T00:00:01Z',
        ],
    ])['ok'] === true);

    $incomplete = $store->begin_manifest(manifest_scope(['source_observed_at_gmt' => '2026-08-12T12:02:00Z']));
    $store->append_items($incomplete['manifest_id'], identity_rows(4001, 2));
    db_query($wpdb->prepare(
        "UPDATE `{$manifest_table}` SET item_count = %d WHERE id = %d",
        1,
        $incomplete['manifest_id']
    ));
    T::ok('incomplete manifest cannot become READY', $store->finalize_manifest($incomplete['manifest_id'])['ok'] === false);
    T::same('incomplete manifest remains non-terminal', 'building', $store->manifest_status($incomplete['manifest_id']));
    T::ok('failed manifest is not readable', $store->fail_manifest($incomplete['manifest_id']) && $store->read_page($incomplete['token'], null, 100)['ok'] === false);

    T::section('TTL, expiration, and bounded garbage collection');
    $max_ttl = $store->begin_manifest(manifest_scope(['source_observed_at_gmt' => '2026-08-12T12:03:00Z']), 7 * 86400);
    T::same('hard maximum TTL is seven days', '2026-08-19T12:00:00.000000Z', $max_ttl['expires_at_gmt'] ?? null);
    T::same('hard maximum TTL rejects longer values', 'invalid_ttl', $store->begin_manifest(manifest_scope(['source_observed_at_gmt' => '2026-08-12T12:04:00Z']), 7 * 86400 + 1)['error'] ?? null);

    $expired_building = $store->begin_manifest(manifest_scope(['source_observed_at_gmt' => '2026-08-12T12:05:00Z']), 1);
    $expired_ready = $store->store_resolved_manifest(manifest_scope(['source_observed_at_gmt' => '2026-08-12T12:06:00Z']), identity_rows(5001, 1), 1);
    $active_ready = $store->store_resolved_manifest(manifest_scope(['source_observed_at_gmt' => '2026-08-12T12:07:00Z']), identity_rows(6001, 1), 7 * 86400);
    $now = $now->modify('+2 seconds');
    T::same('expired READY read fails closed', 'manifest_expired', $store->read_page($expired_ready['token'], null, 100)['error'] ?? null);
    T::same('read does not renew expiry', $expired_ready['expires_at_gmt'], $store->manifest_metadata($expired_ready['manifest_id'])['expires_at_gmt']);
    $gc_one = $store->garbage_collect(1);
    $gc_two = $store->garbage_collect(1);
    T::ok('GC is bounded by requested batch size', ($gc_one['deleted_manifests'] ?? 2) <= 1 && ($gc_two['deleted_manifests'] ?? 2) <= 1);
    T::ok('abandoned BUILDING state is GC eligible', $store->manifest_status($expired_building['manifest_id']) === null);
    T::ok('active READY manifest is retained', $store->manifest_status($active_ready['manifest_id']) === 'ready');

    T::section('bounded replayable paging and authenticated GET');
    $large = $store->store_resolved_manifest(manifest_scope(['source_observed_at_gmt' => '2026-08-12T12:08:00Z']), identity_rows(7001, 205));
    $large_page_one = $store->read_page($large['token'], null, 100);
    $large_page_two = $store->read_page($large['token'], $large_page_one['next_sequence'], 100);
    $large_page_two_replay = $store->read_page($large['token'], $large_page_one['next_sequence'], 100);
    $large_page_three = $store->read_page($large['token'], $large_page_two['next_sequence'], 100);
    T::same('first page is bounded to 100', 100, count($large_page_one['items']));
    T::same('second page is bounded to 100', 100, count($large_page_two['items']));
    T::same('terminal page is the remaining five items', 5, count($large_page_three['items']));
    T::same('sequence keyset has no offset drift', 7100, (int) end($large_page_one['items'])['source_order_id']);
    T::same('replay returns identical IDs and order', $large_page_two['items'], $large_page_two_replay['items']);
    T::same('terminal evidence is stable across replay', $large_page_three['terminal_evidence'], $store->read_page($large['token'], $large_page_two['next_sequence'], 100)['terminal_evidence']);

    $controller = new EventSales_Woo_Order_Index_Feed();
    $large_path = '/wp-json/eventsales/v1/woo-order-index/manifests/' . $large['token'];
    $http_page_one = $controller->handle_manifest_fetch(signed_request('GET', $large_path, [], '', ['token' => $large['token']]));
    T::same('authenticated READY GET succeeds', 200, $http_page_one->get_status());
    T::same('authenticated GET returns at most 100 items', 100, count($http_page_one->get_data()['items']));
    T::same('HTTP page 1 is nonterminal', true, $http_page_one->get_data()['has_more']);
    T::ok('authenticated GET returns an opaque cursor', is_string($http_page_one->get_data()['next_cursor'] ?? null));
    T::ok('HTTP page 1 omits terminal evidence', !array_key_exists('terminal_evidence', $http_page_one->get_data()));
    $cursor = $http_page_one->get_data()['next_cursor'];
    $http_page_two = $controller->handle_manifest_fetch(signed_request('GET', $large_path, ['cursor' => $cursor], '', ['token' => $large['token']]));
    $http_page_two_replay = $controller->handle_manifest_fetch(signed_request('GET', $large_path, ['cursor' => $cursor], '', ['token' => $large['token']]));
    T::same('cursor page returns the next deterministic page', 100, count($http_page_two->get_data()['items']));
    T::same('HTTP page 2 is nonterminal', true, $http_page_two->get_data()['has_more']);
    T::ok('HTTP page 2 returns a continuation cursor', is_string($http_page_two->get_data()['next_cursor'] ?? null));
    T::ok('HTTP page 2 omits terminal evidence', !array_key_exists('terminal_evidence', $http_page_two->get_data()));
    T::same('same cursor replays the same page', $http_page_two->get_data()['items'], $http_page_two_replay->get_data()['items']);
    $terminal_cursor = $http_page_two->get_data()['next_cursor'];
    $http_page_three = $controller->handle_manifest_fetch(signed_request(
        'GET',
        $large_path,
        ['cursor' => $terminal_cursor],
        '',
        ['token' => $large['token']]
    ));
    $http_page_three_replay = $controller->handle_manifest_fetch(signed_request(
        'GET',
        $large_path,
        ['cursor' => $terminal_cursor],
        '',
        ['token' => $large['token']]
    ));
    T::same('HTTP page 3 contains the remaining five items', 5, count($http_page_three->get_data()['items']));
    T::same('HTTP page 3 is terminal', false, $http_page_three->get_data()['has_more']);
    T::ok('HTTP page 3 omits the continuation cursor', !array_key_exists('next_cursor', $http_page_three->get_data()));
    T::same('HTTP page 3 exposes stored terminal evidence', $large['terminal_evidence'], $http_page_three->get_data()['terminal_evidence'] ?? null);
    T::same('terminal replay preserves item ordering', $http_page_three->get_data()['items'], $http_page_three_replay->get_data()['items']);
    T::same('terminal replay preserves evidence', $http_page_three->get_data()['terminal_evidence'], $http_page_three_replay->get_data()['terminal_evidence']);

    $_SERVER['REQUEST_URI'] = $large_path;
    $unauthenticated_response = $controller->handle_manifest_fetch(new WP_REST_Request(
        'GET',
        $large_path,
        [],
        '',
        [],
        ['token' => $large['token']]
    ));
    $unauthenticated_data = $unauthenticated_response->get_data();
    T::same('valid manifest URL without HMAC is unauthorized', 401, $unauthenticated_response->get_status());
    T::ok('unauthenticated response has no items', !array_key_exists('items', $unauthenticated_data));
    T::ok('unauthenticated response has no manifest hash', !array_key_exists('manifest_hash', $unauthenticated_data));
    T::ok('unauthenticated response has no terminal evidence', !array_key_exists('terminal_evidence', $unauthenticated_data));
    $wrong_hmac_response = $controller->handle_manifest_fetch(signed_request(
        'GET',
        $large_path,
        [],
        '',
        ['token' => $large['token']],
        'wrong-order-index-secret'
    ));
    $wrong_hmac_data = $wrong_hmac_response->get_data();
    T::same('wrong HMAC is unauthorized before membership lookup', 401, $wrong_hmac_response->get_status());
    T::ok('wrong HMAC response has no items', !array_key_exists('items', $wrong_hmac_data));
    T::ok('wrong HMAC response has no manifest hash', !array_key_exists('manifest_hash', $wrong_hmac_data));
    T::ok('wrong HMAC response has no terminal evidence', !array_key_exists('terminal_evidence', $wrong_hmac_data));
    $tampered_cursor_response = $controller->handle_manifest_fetch(
        signed_request(
            'GET',
            $large_path,
            ['cursor' => substr($cursor, 0, -1) . 'x'],
            '',
            ['token' => $large['token']]
        )
    );
    T::same('tampered cursor fails closed', 400, $tampered_cursor_response->get_status());

    $other_manifest = $store->store_resolved_manifest(manifest_scope(['source_observed_at_gmt' => '2026-08-12T12:09:00Z']), identity_rows(8001, 1));
    $other_path = '/wp-json/eventsales/v1/woo-order-index/manifests/' . $other_manifest['token'];
    $other_cursor_response = $controller->handle_manifest_fetch(
        signed_request('GET', $other_path, ['cursor' => $cursor], '', ['token' => $other_manifest['token']])
    );
    T::same('cursor is bound to the manifest', 400, $other_cursor_response->get_status());
    $unknown_token = str_repeat('a', 64);
    $unknown_token_response = $controller->handle_manifest_fetch(
        signed_request(
            'GET',
            '/wp-json/eventsales/v1/woo-order-index/manifests/' . $unknown_token,
            [],
            '',
            ['token' => $unknown_token]
        )
    );
    T::same('unknown token fails closed without membership', 404, $unknown_token_response->get_status());

    $post_body = (string) json_encode([
        'source_system' => 'wordpress_woo:localhost',
        'backfill_start' => '2026-08-01T00:00:00Z',
        'backfill_cutoff' => '2026-08-12T00:00:00Z',
        'limit' => 100,
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    $post_response = $controller->handle_manifest_create(signed_request(
        'POST',
        '/wp-json/eventsales/v1/woo-order-index/manifests',
        [],
        $post_body
    ));
    T::same('activated public POST fails closed without verified Woo runtime', 503, $post_response->get_status());
    T::same('activated public POST exposes bounded preflight failure', 'source_preflight_failed', $post_response->get_data()['error'] ?? null);
    T::ok('failed public POST does not expose BUILDING metadata', !array_key_exists('boundary_token', $post_response->get_data()) && !array_key_exists('items', $post_response->get_data()));

    T::section('source and catalog boundaries');
    $source = file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-index-feed.php')
        . file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-index-manifest-store.php')
        . file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-membership-source.php')
        . file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-manifest-builder.php');
    foreach (['wc_get_orders', 'wc_get_order', 'WP_Query', '$wpdb->posts', 'wp_posts', 'wc/v3'] as $forbidden) {
        T::ok('no live Woo enumeration reference: ' . $forbidden, strpos($source, $forbidden) === false);
    }
    $catalog_plugin = dirname(__DIR__) . '/../eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php';
    T::same(
        'catalog plugin remains byte-for-byte unchanged',
        '92a120800d1c2b224e741ca5c8f310478c4732b1883a0c001d21f839ee1207f2',
        hash_file('sha256', $catalog_plugin)
    );
} catch (Throwable $error) {
    T::$failures[] = 'unexpected database harness error: ' . $error->getMessage();
}

if (T::$failures !== []) {
    fwrite(STDERR, "Failures:\n");
    foreach (T::$failures as $failure) {
        fwrite(STDERR, '- ' . $failure . "\n");
    }
    exit(1);
}

echo 'order-index feed database tests passed: ' . T::$passes . " assertions, 0 failures\n";
