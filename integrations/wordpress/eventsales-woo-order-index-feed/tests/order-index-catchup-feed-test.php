<?php

declare(strict_types=1);

define('ABSPATH', __DIR__);
define('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION', '2026-08-12.v1');
define('ARRAY_A', 'ARRAY_A');

$GLOBALS['options'] = [
    'eventsales_woo_order_index_key_id' => 'order-index-key-1',
    'eventsales_woo_order_index_secret' => 'order-index-secret',
];
$GLOBALS['registered_routes'] = [];

function add_action($hook, $callback, $priority = 10, $accepted_args = 1)
{
    return true;
}

function register_rest_route($namespace, $route, $args)
{
    $GLOBALS['registered_routes'][] = ['namespace' => $namespace, 'route' => $route, 'args' => $args];

    return true;
}

function get_option($name, $default = false)
{
    return array_key_exists($name, $GLOBALS['options']) ? $GLOBALS['options'][$name] : $default;
}

final class WP_REST_Request
{
    public function __construct(
        private string $method,
        private string $route,
        private array $query_params = [],
        private string $body = '',
        private array $headers = [],
        private array $url_params = []
    ) {
        $normalized = [];
        foreach ($headers as $key => $value) {
            $normalized[strtolower((string) $key)] = $value;
        }
        $this->headers = $normalized;
    }

    public function get_method(): string { return $this->method; }
    public function get_route(): string { return $this->route; }
    public function get_header($key) { return $this->headers[strtolower((string) $key)] ?? ''; }
    public function get_query_params(): array { return $this->query_params; }
    public function get_url_params(): array { return $this->url_params; }
    public function get_param($key) { return $this->url_params[$key] ?? $this->query_params[$key] ?? null; }
    public function get_body(): string { return $this->body; }
}

final class WP_REST_Response
{
    public function __construct(private array $data, private int $status = 200) {}
    public function get_data(): array { return $this->data; }
    public function get_status(): int { return $this->status; }
}

require dirname(__DIR__) . '/eventsales-woo-order-index-feed.php';
EventSales_Woo_Order_Index_Feed::register();

final class F4A_Feed_Builder
{
    public int $calls = 0;

    public string $page_phase = 'catch_up';

    /** @var array<string, mixed>|null */
    public ?array $scope = null;

    public function build(array $scope): array
    {
        $this->calls++;
        $this->scope = $scope;

        return [
            'ok' => true,
            'status' => 'ready',
            'token' => 'child-token',
            'manifest_hash' => str_repeat('c', 64),
            'manifest_expires_at_gmt' => '2099-01-12T00:00:00.000000Z',
            'source_observed_at_gmt' => '2099-01-11T00:00:00.000000Z',
            'page' => [
                'ok' => true,
                'schema_version' => '2026-08-13.catchup.v1',
                'phase' => $this->page_phase,
                'manifest_hash' => str_repeat('c', 64),
                'expires_at_gmt' => '2099-01-12T00:00:00.000000Z',
                'source_observed_at_gmt' => '2099-01-11T00:00:00.000000Z',
                'items' => [],
                'has_more' => false,
                'terminal_evidence' => 'v1;phase=catch_up;manifest_sha256=' . str_repeat('c', 64),
            ],
        ];
    }
}

final class F4A_Unknown_Phase_Wpdb
{
    public string $prefix = 'f4a_';

    public function prepare(string $query, ...$arguments): string
    {
        return $query;
    }

    public function get_row(string $query, $output = null): array
    {
        return [
            'id' => 1,
            'schema_version' => '2026-08-13.catchup.v1',
            'phase' => 'unexpected_phase',
            'source_system' => 'local-test',
            'source_observed_at_gmt' => '2099-01-11 00:00:00.000000',
            'expires_at_gmt' => '2099-01-12 00:00:00.000000',
            'status' => 'ready',
            'manifest_hash' => str_repeat('c', 64),
            'terminal_evidence' => 'v1;phase=catch_up;manifest_sha256=' . str_repeat('c', 64),
        ];
    }

    public function get_results(string $query, $output = null): array
    {
        return [];
    }
}

function f4a_feed_request(string $method, string $path, array $body, array $url_params = []): WP_REST_Request
{
    $raw_body = (string) json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    $timestamp = (string) time();
    $base = EventSales_Woo_Order_Index_Feed::canonical_signature_input(
        $method,
        $path,
        '',
        $raw_body,
        $timestamp,
        'order-index-key-1'
    );

    return new WP_REST_Request($method, $path, [], $raw_body, [
        'X-EventSales-Key-Id' => 'order-index-key-1',
        'X-EventSales-Timestamp' => $timestamp,
        'X-EventSales-Signature' => 'v1=' . hash_hmac('sha256', $base, 'order-index-secret'),
    ], $url_params);
}

$builder = new F4A_Feed_Builder();
$feed = new EventSales_Woo_Order_Index_Feed(null, static fn(object $database): object => $builder);
$path = '/wp-json/eventsales/v1/woo-order-index/manifests/parent-token/catch-up';
$_SERVER['REQUEST_URI'] = $path;

$routes = array_column($GLOBALS['registered_routes'], 'route');
if (!in_array('/woo-order-index/manifests/(?P<parent_token>[A-Za-z0-9._-]{1,128})/catch-up', $routes, true)) {
    echo "FAIL catch-up route registered\n";
    exit(1);
}

$response = $feed->handle_manifest_catchup(f4a_feed_request(
    'POST',
    $path,
    ['source_system' => 'local-test', 'limit' => 100],
    ['parent_token' => 'parent-token']
));
$data = $response->get_data();
if ($response->get_status() !== 200 || ($data['phase'] ?? null) !== 'catch_up' || ($builder->scope ?? []) !== [
    'parent_token' => 'parent-token',
    'source_system' => 'local-test',
    'limit' => 100,
]) {
    echo "FAIL valid catch-up request\n";
    exit(1);
}

$phase_mismatch_builder = new F4A_Feed_Builder();
$phase_mismatch_builder->page_phase = 'manifest_enumerate';
$phase_mismatch_feed = new EventSales_Woo_Order_Index_Feed(null, static fn(object $database): object => $phase_mismatch_builder);
$phase_mismatch_response = $phase_mismatch_feed->handle_manifest_catchup(f4a_feed_request(
    'POST',
    $path,
    ['source_system' => 'local-test', 'limit' => 100],
    ['parent_token' => 'parent-token']
));
if ($phase_mismatch_response->get_status() !== 503 || ($phase_mismatch_response->get_data()['error'] ?? null) !== 'manifest_storage_failed') {
    echo "FAIL catch-up POST phase mismatch fails closed\n";
    exit(1);
}

$unknown_phase_store = new EventSales_Woo_Order_Index_Manifest_Store(new F4A_Unknown_Phase_Wpdb());
$unknown_phase_feed = new EventSales_Woo_Order_Index_Feed(
    null,
    null,
    static fn(object $database): object => $unknown_phase_store
);
$unknown_phase_path = '/wp-json/eventsales/v1/woo-order-index/manifests/child-token';
$_SERVER['REQUEST_URI'] = $unknown_phase_path;
$unknown_phase_response = $unknown_phase_feed->handle_manifest_fetch(f4a_feed_request(
    'GET',
    $unknown_phase_path,
    [],
    ['token' => 'child-token']
));
if ($unknown_phase_response->get_status() !== 503 || ($unknown_phase_response->get_data()['error'] ?? null) !== 'manifest_storage_failed') {
    echo "FAIL unknown GET phase fails closed\n";
    exit(1);
}

$_SERVER['REQUEST_URI'] = $path;
$invalid = $feed->handle_manifest_catchup(f4a_feed_request(
    'POST',
    $path,
    ['source_system' => 'local-test', 'limit' => 100, 'backfill_start' => '2099-01-01T00:00:00Z'],
    ['parent_token' => 'parent-token']
));
if ($invalid->get_status() !== 400 || $builder->calls !== 1) {
    echo "FAIL catch-up rejects client historical bounds\n";
    exit(1);
}

echo "M3-01/02F4A catch-up feed tests PASS\n";
