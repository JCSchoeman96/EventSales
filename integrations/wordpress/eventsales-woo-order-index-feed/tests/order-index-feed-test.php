<?php

declare(strict_types=1);

/**
 * Focused contract tests for the M3-01/02D Woo order-index boundary.
 *
 * The plugin is loaded under a small WordPress REST mock. The tests exercise
 * the real producer boundary without connecting to WordPress, WooCommerce,
 * a database, or an EventSales runtime.
 */

define('ABSPATH', __DIR__);
define('EVENTSALES_TICKERA_CATALOG_SECRET', 'catalog-secret-only');

$GLOBALS['options'] = [
    'eventsales_woo_order_index_key_id' => 'order-index-key-1',
    'eventsales_woo_order_index_secret' => 'order-index-secret',
];
$GLOBALS['registered_routes'] = [];
$GLOBALS['woo_calls'] = 0;

function add_action($hook, $callback, $priority = 10, $accepted_args = 1)
{
    return true;
}

function register_rest_route($namespace, $route, $args)
{
    $GLOBALS['registered_routes'][] = [
        'namespace' => $namespace,
        'route' => $route,
        'args' => $args,
    ];

    return true;
}

function get_option($name, $default = false)
{
    return array_key_exists($name, $GLOBALS['options']) ? $GLOBALS['options'][$name] : $default;
}

function wc_get_orders(...$args)
{
    $GLOBALS['woo_calls']++;
    throw new RuntimeException('standard WooCommerce enumeration must not be called');
}

function wc_get_order(...$args)
{
    $GLOBALS['woo_calls']++;
    throw new RuntimeException('full WooCommerce order retrieval must not be called');
}

final class WP_REST_Request
{
    /** @var array<string, mixed> */
    private array $headers;

    /** @var array<string, mixed> */
    private array $query_params;

    /** @var array<string, mixed> */
    private array $url_params;

    public function __construct(
        private string $method,
        private string $route,
        array $query_params = [],
        private string $body = '',
        array $headers = [],
        array $url_params = []
    ) {
        $this->headers = [];

        foreach ($headers as $key => $value) {
            $this->headers[strtolower((string) $key)] = $value;
        }

        $this->query_params = $query_params;
        $this->url_params = $url_params;
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

    /** @return array<string, mixed> */
    public function get_url_params(): array
    {
        return $this->url_params;
    }

    public function get_param($key)
    {
        if (array_key_exists($key, $this->url_params)) {
            return $this->url_params[$key];
        }

        return $this->query_params[$key] ?? null;
    }

    public function get_body(): string
    {
        return $this->body;
    }

    /** @return array<string, mixed> */
    public function all_headers(): array
    {
        return $this->headers;
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
class_alias('EventSales_Woo_Order_Index_Feed', 'Feed');

final class FeedTestBuilder
{
    public int $calls = 0;

    /** @var array<int, array<string, mixed>> */
    public array $scopes = [];

    public bool $terminal = false;

    /** @var array<string, mixed>|null */
    public ?array $forced_result = null;

    /** @param array<string, mixed> $scope */
    public function build(array $scope): array
    {
        $this->calls++;
        $this->scopes[] = $scope;
        if ($this->forced_result !== null) {
            return $this->forced_result;
        }

        return [
            'ok' => true,
            'status' => 'ready',
            'token' => 'test-ready-token',
            'manifest_hash' => str_repeat('b', 64),
            'manifest_expires_at_gmt' => '2026-08-13T00:00:00.000000Z',
            'source_observed_at_gmt' => '2026-08-12T00:00:00.000000Z',
            'page' => [
                'ok' => true,
                'schema_version' => EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION,
                'manifest_hash' => str_repeat('b', 64),
                'expires_at_gmt' => '2026-08-13T00:00:00.000000Z',
                'source_observed_at_gmt' => '2026-08-12T00:00:00.000000Z',
                'items' => [[
                    'source_order_id' => '10',
                    'source_created_at_gmt' => '2026-08-01T00:00:00.000000Z',
                    'source_modified_at_gmt' => '2026-08-01T00:00:00.000000Z',
                ]],
                'has_more' => !$this->terminal,
                'next_sequence' => $this->terminal ? null : 1,
                'terminal_evidence' => $this->terminal ? 'stored-terminal-evidence' : null,
            ],
        ];
    }
}

function test_controller(FeedTestBuilder $builder): EventSales_Woo_Order_Index_Feed
{
    return new EventSales_Woo_Order_Index_Feed(
        static fn(object $database): object => $builder
    );
}

final class T
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
        if ($expected === $actual) {
            self::$passes++;

            return;
        }

        self::$failures[] = $label . ' [expected ' . self::render($expected) . ' got ' . self::render($actual) . ']';
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

/** @param array<string, mixed> $overrides */
function valid_payload(array $overrides = []): array
{
    return array_merge([
        'source_system' => 'wordpress_woo:localhost',
        'backfill_start' => '2026-08-01T00:00:00Z',
        'backfill_cutoff' => '2026-08-12T00:00:00Z',
        'limit' => 100,
    ], $overrides);
}

/**
 * @param array<string, mixed> $query
 * @param array<string, mixed> $headers
 */
function request_for(
    string $method,
    string $path,
    array $query = [],
    string $body = '',
    array $headers = [],
    array $url_params = []
): WP_REST_Request {
    $_SERVER['REQUEST_URI'] = $path;

    return new WP_REST_Request($method, $path, $query, $body, $headers, $url_params);
}

/**
 * @param array<string, mixed> $query
 * @param array<string, mixed> $body
 * @return array{request: WP_REST_Request, headers: array<string, string>}
 */
function signed_request(
    string $method,
    string $path,
    array $query = [],
    array $body = [],
    ?int $timestamp = null,
    string $key_id = 'order-index-key-1',
    string $secret = 'order-index-secret'
): array {
    $raw_body = $body === [] ? '' : (string) json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    $timestamp_text = (string) ($timestamp ?? time());
    $query_text = EventSales_Woo_Order_Index_Feed::canonical_query_string($query);
    $base = EventSales_Woo_Order_Index_Feed::canonical_signature_input(
        $method,
        $path,
        $query_text,
        $raw_body,
        $timestamp_text,
        $key_id
    );
    $headers = [
        'X-EventSales-Key-Id' => $key_id,
        'X-EventSales-Timestamp' => $timestamp_text,
        'X-EventSales-Signature' => 'v1=' . hash_hmac('sha256', $base, $secret),
    ];

    return [
        'request' => request_for($method, $path, $query, $raw_body, $headers),
        'headers' => $headers,
    ];
}

/** @return array{request: WP_REST_Request, headers: array<string, string>} */
function signed_raw_request(
    string $method,
    string $path,
    string $raw_body,
    array $query = [],
    ?int $timestamp = null,
    string $key_id = 'order-index-key-1',
    string $secret = 'order-index-secret'
): array {
    $timestamp_text = (string) ($timestamp ?? time());
    $base = EventSales_Woo_Order_Index_Feed::canonical_signature_input(
        $method,
        $path,
        EventSales_Woo_Order_Index_Feed::canonical_query_string($query),
        $raw_body,
        $timestamp_text,
        $key_id
    );
    $headers = [
        'X-EventSales-Key-Id' => $key_id,
        'X-EventSales-Timestamp' => $timestamp_text,
        'X-EventSales-Signature' => 'v1=' . hash_hmac('sha256', $base, $secret),
    ];

    return [
        'request' => request_for($method, $path, $query, $raw_body, $headers),
        'headers' => $headers,
    ];
}

/** @param array<string, mixed> $body */
function create_response(array $body = [], array $headers = []): WP_REST_Response
{
    $signed = signed_request(
        'POST',
        '/wp-json/eventsales/v1/woo-order-index/manifests',
        [],
        $body
    );

    $request = request_for(
        'POST',
        '/wp-json/eventsales/v1/woo-order-index/manifests',
        [],
        $signed['request']->get_body(),
        array_merge($signed['headers'], $headers)
    );

    return (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($request);
}

Feed::register();

T::section('route and credential boundary');

T::same('namespace constant', 'eventsales/v1', EVENTSALES_WOO_ORDER_INDEX_NAMESPACE);
T::same('create route constant', '/woo-order-index/manifests', EVENTSALES_WOO_ORDER_INDEX_CREATE_ROUTE);
T::same('fetch route constant', '/woo-order-index/manifests/(?P<token>[A-Za-z0-9._-]{1,128})', EVENTSALES_WOO_ORDER_INDEX_FETCH_ROUTE);
T::same('maximum request limit', 100, Feed::max_limit());
T::same('registered route count', 2, count($GLOBALS['registered_routes']));
T::same('registered namespace', 'eventsales/v1', $GLOBALS['registered_routes'][0]['namespace']);
T::same('registered create path', '/woo-order-index/manifests', $GLOBALS['registered_routes'][0]['route']);
T::same('registered fetch path', EVENTSALES_WOO_ORDER_INDEX_FETCH_ROUTE, $GLOBALS['registered_routes'][1]['route']);
T::same('key option is separate', 'eventsales_woo_order_index_key_id', Feed::key_id_option_name());
T::same('secret option is separate', 'eventsales_woo_order_index_secret', Feed::secret_option_name());

T::section('authentication');

$valid = signed_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    valid_payload()
);
$valid_builder = new FeedTestBuilder();
$valid_response = test_controller($valid_builder)->handle_manifest_create($valid['request']);
T::same('valid signature returns a READY manifest page', 200, $valid_response->get_status());
T::same('valid POST returns the requested item limit', 1, count($valid_response->get_data()['items'] ?? []));
T::same('valid POST returns a nonterminal cursor', true, $valid_response->get_data()['has_more'] ?? false);
T::ok('valid POST includes next_cursor only when nonterminal', array_key_exists('next_cursor', $valid_response->get_data()) && !array_key_exists('terminal_evidence', $valid_response->get_data()));
T::same('builder receives the validated POST scope', valid_payload(), $valid_builder->scopes[0] ?? null);

$terminal_builder = new FeedTestBuilder();
$terminal_builder->terminal = true;
$terminal_response = test_controller($terminal_builder)->handle_manifest_create($valid['request']);
T::same('terminal POST still returns READY', 200, $terminal_response->get_status());
T::ok('terminal POST omits next_cursor', !array_key_exists('next_cursor', $terminal_response->get_data()));
T::same('terminal POST returns stored terminal evidence', 'stored-terminal-evidence', $terminal_response->get_data()['terminal_evidence'] ?? null);

$failure_builder = new FeedTestBuilder();
$failure_builder->forced_result = ['ok' => false, 'error' => 'capture_budget_exceeded'];
$failure_response = test_controller($failure_builder)->handle_manifest_create($valid['request']);
T::same('builder failure is non-success', 503, $failure_response->get_status());
T::same('builder failure is bounded', 'capture_budget_exceeded', $failure_response->get_data()['error'] ?? null);
T::ok('builder failure exposes no token or source data', !array_key_exists('boundary_token', $failure_response->get_data()) && !array_key_exists('items', $failure_response->get_data()));

$busy_builder = new FeedTestBuilder();
$busy_builder->forced_result = ['ok' => false, 'error' => 'busy'];
$busy_response = test_controller($busy_builder)->handle_manifest_create($valid['request']);
T::same('concurrent builder failure is conflict', 409, $busy_response->get_status());
T::same('concurrent builder failure is bounded', 'busy', $busy_response->get_data()['error'] ?? null);

$known_vector_base = "POST\n"
    . "/wp-json/eventsales/v1/woo-order-index/manifests\n"
    . "query=alpha=one%20two&z=9\n"
    . "body_sha256=2aaae8b2e3403ab5cf257b5d896ce70ad63efc2ee587ac1b001e33ac6edadaa5\n"
    . "timestamp=1780000000\n"
    . "key_id=order-index-key-1";
T::same(
    'canonical signature input matches the independent vector',
    $known_vector_base,
    Feed::canonical_signature_input(
        'POST',
        '/wp-json/eventsales/v1/woo-order-index/manifests',
        'alpha=one%20two&z=9',
        '{"source_system":"wordpress_woo:localhost","backfill_start":"2026-08-01T00:00:00Z","backfill_cutoff":"2026-08-12T00:00:00Z","limit":100}',
        '1780000000',
        'order-index-key-1'
    )
);
T::same(
    'HMAC signature matches the independent vector',
    '743dcfc3c5f3366fef7df243aacdf7c5740629e6a0313fabbbaf3b2c79670f08',
    hash_hmac('sha256', $known_vector_base, 'order-index-secret')
);
$runtime_vector_body = '{"source_system":"wordpress_woo:localhost","backfill_start":"2026-08-01T00:00:00Z","backfill_cutoff":"2026-08-12T00:00:00Z","limit":100}';
$runtime_vector_timestamp = (string) time();
$runtime_vector_base = "POST\n"
    . "/wp-json/eventsales/v1/woo-order-index/manifests\n"
    . "query=alpha=one%20two&z=9\n"
    . "body_sha256=2aaae8b2e3403ab5cf257b5d896ce70ad63efc2ee587ac1b001e33ac6edadaa5\n"
    . "timestamp=" . $runtime_vector_timestamp . "\n"
    . "key_id=order-index-key-1";
$runtime_vector_response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create(request_for(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    ['alpha' => 'one two', 'z' => '9'],
    $runtime_vector_body,
    [
        'X-EventSales-Key-Id' => 'order-index-key-1',
        'X-EventSales-Timestamp' => $runtime_vector_timestamp,
        'X-EventSales-Signature' => 'v1=' . hash_hmac('sha256', $runtime_vector_base, 'order-index-secret'),
    ]
));
T::same('independent vector passes auth before query validation', 400, $runtime_vector_response->get_status());

$missing_signature_headers = $valid['headers'];
unset($missing_signature_headers['X-EventSales-Signature']);
$missing_signature = request_for(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    $valid['request']->get_body(),
    $missing_signature_headers
);
$auth_builder = new FeedTestBuilder();
$auth_controller = test_controller($auth_builder);
$response = $auth_controller->handle_manifest_create($missing_signature);
T::same('missing signature rejected', 401, $response->get_status());
T::same('missing signature runs no builder/source work', 0, $auth_builder->calls);

$malformed_headers = $valid['headers'];
$malformed_headers['X-EventSales-Signature'] = 'not-a-signature';
$response = $auth_controller->handle_manifest_create(request_for(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    $valid['request']->get_body(),
    $malformed_headers
));
T::same('malformed signature rejected', 401, $response->get_status());
T::same('wrong HMAC format runs no builder/source work', 0, $auth_builder->calls);

$unknown_key = signed_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    valid_payload(),
    null,
    'unknown-key',
    'order-index-secret'
);
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($unknown_key['request']);
T::same('unknown key id rejected', 401, $response->get_status());

$stale = signed_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    valid_payload(),
    time() - 301
);
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($stale['request']);
T::same('stale timestamp rejected', 401, $response->get_status());

$future = signed_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    valid_payload(),
    time() + 301
);
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($future['request']);
T::same('excessive future timestamp rejected', 401, $response->get_status());

$wrong_secret = signed_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    valid_payload(),
    null,
    'order-index-key-1',
    'wrong-secret'
);
$response = $auth_controller->handle_manifest_create($wrong_secret['request']);
T::same('wrong secret rejected', 401, $response->get_status());
T::same('wrong HMAC secret runs no builder/source work', 0, $auth_builder->calls);

$missing_secret_options = $GLOBALS['options'];
$GLOBALS['options']['eventsales_woo_order_index_secret'] = '';
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($valid['request']);
T::same('missing order-index secret rejected', 401, $response->get_status());
$GLOBALS['options'] = $missing_secret_options;

$order_options = $GLOBALS['options'];
$GLOBALS['options'] = [
    'eventsales_woo_order_index_key_id' => 'order-index-key-1',
    'eventsales_tickera_catalog_secret' => 'catalog-secret-only',
];
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($valid['request']);
T::same('catalog-only configuration cannot authenticate order-index requests', 401, $response->get_status());
$GLOBALS['options'] = $order_options;

$catalog_signed = signed_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    valid_payload(),
    null,
    'order-index-key-1',
    'catalog-secret-only'
);
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($catalog_signed['request']);
T::same('catalog secret cannot replace order-index secret', 401, $response->get_status());

$tampered_body = request_for(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    (string) json_encode(valid_payload(['limit' => 99]), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE),
    $valid['headers']
);
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($tampered_body);
T::same('body tampering invalidates signature', 401, $response->get_status());

$tampered_query = request_for(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    ['offset' => '0'],
    $valid['request']->get_body(),
    $valid['headers']
);
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($tampered_query);
T::same('query tampering invalidates signature', 401, $response->get_status());

$invalid_timestamp = $valid['headers'];
$invalid_timestamp['X-EventSales-Timestamp'] = 'yesterday';
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create(request_for(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    $valid['request']->get_body(),
    $invalid_timestamp
));
T::same('non-numeric timestamp rejected', 401, $response->get_status());

$oversized = signed_raw_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    str_repeat('x', 16385)
);
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($oversized['request']);
T::same('oversized request rejected before validation', 413, $response->get_status());

$oversized_query = signed_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    ['padding' => str_repeat('x', 16385)],
    valid_payload()
);
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($oversized_query['request']);
T::same('oversized query rejected before canonical HMAC work', 413, $response->get_status());

$raw_query_padding = str_repeat('x', 16385);
$raw_query = signed_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    ['padding' => $raw_query_padding],
    valid_payload()
);
$_SERVER['REQUEST_URI'] = '/wp-json/eventsales/v1/woo-order-index/manifests?padding=' . rawurlencode($raw_query_padding);
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($raw_query['request']);
T::same('raw URI query rejected before canonical HMAC work', 413, $response->get_status());

$malformed_json = signed_raw_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    '{"source_system":'
);
$response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($malformed_json['request']);
T::same('malformed JSON rejected without an exception response', 400, $response->get_status());

T::section('request validation');

$valid_validation = Feed::validate_manifest_request(valid_payload(), []);
T::ok('valid B/C accepted through validation', $valid_validation['ok'] === true);
T::same('valid limit retained', 100, $valid_validation['values']['limit'] ?? null);
T::ok('B greater than C rejected', !Feed::validate_manifest_request(valid_payload([
    'backfill_start' => '2026-08-13T00:00:00Z',
]), [])['ok']);
T::ok('malformed B rejected', !Feed::validate_manifest_request(valid_payload([
    'backfill_start' => '2026-08-01',
]), [])['ok']);
T::ok('malformed C rejected', !Feed::validate_manifest_request(valid_payload([
    'backfill_cutoff' => '2026-08-12T00:00:00',
]), [])['ok']);
T::ok('natural-language B rejected', !Feed::validate_manifest_request(valid_payload([
    'backfill_start' => 'yesterday',
]), [])['ok']);
T::ok('UTC offset timestamp rejected', !Feed::validate_manifest_request(valid_payload([
    'backfill_cutoff' => '2026-08-12T00:00:00+00:00',
]), [])['ok']);
T::ok('limit zero rejected', !Feed::validate_manifest_request(valid_payload(['limit' => 0]), [])['ok']);
T::ok('limit 101 rejected', !Feed::validate_manifest_request(valid_payload(['limit' => 101]), [])['ok']);
T::ok('source array rejected', !Feed::validate_manifest_request(valid_payload([
    'source_system' => ['wordpress_woo'],
]), [])['ok']);
T::ok('date object rejected', !Feed::validate_manifest_request(valid_payload([
    'backfill_start' => ['date' => '2026-08-01T00:00:00Z'],
]), [])['ok']);
T::ok('limit object rejected', !Feed::validate_manifest_request(valid_payload([
    'limit' => ['value' => 100],
]), [])['ok']);
T::ok('limit string rejected', !Feed::validate_manifest_request(valid_payload([
    'limit' => '100',
]), [])['ok']);
T::ok('page continuation rejected', !Feed::validate_manifest_request(valid_payload(), ['page' => '1'])['ok']);
T::ok('offset continuation rejected', !Feed::validate_manifest_request(valid_payload(), ['offset' => '0'])['ok']);
T::ok('total count option rejected', !Feed::validate_manifest_request(valid_payload(), ['total' => '1'])['ok']);
T::ok('unknown body field rejected', !Feed::validate_manifest_request(valid_payload([
    'customer_email' => 'customer@example.test',
]), [])['ok']);
T::ok('missing start rejects unbounded range', !Feed::validate_manifest_request([
    'source_system' => 'wordpress_woo:localhost',
    'backfill_cutoff' => '2026-08-12T00:00:00Z',
    'limit' => 100,
], [])['ok']);
T::ok('missing cutoff rejects unbounded range', !Feed::validate_manifest_request([
    'source_system' => 'wordpress_woo:localhost',
    'backfill_start' => '2026-08-01T00:00:00Z',
    'limit' => 100,
], [])['ok']);

$malformed_scope_builder = new FeedTestBuilder();
$malformed_scope = signed_request(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    valid_payload(['backfill_start' => '2026-08-01'])
);
$malformed_scope_response = test_controller($malformed_scope_builder)->handle_manifest_create($malformed_scope['request']);
T::same('malformed source scope is rejected before builder work', 400, $malformed_scope_response->get_status());
T::same('malformed source scope invokes no builder', 0, $malformed_scope_builder->calls);

$valid_get = signed_request(
    'GET',
    '/wp-json/eventsales/v1/woo-order-index/manifests/opaque-token',
    [],
    []
);
$get_request = request_for(
    'GET',
    '/wp-json/eventsales/v1/woo-order-index/manifests/opaque-token',
    [],
    '',
    $valid_get['headers'],
    ['token' => 'opaque-token']
);
$fetch_response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_fetch($get_request);
T::same('valid fetch token fails closed without local storage', 503, $fetch_response->get_status());
T::ok('fetch page rejected', !Feed::validate_manifest_fetch_request('opaque-token', ['page' => '1'])['ok']);
T::ok('fetch offset rejected', !Feed::validate_manifest_fetch_request('opaque-token', ['offset' => '0'])['ok']);
T::ok('fetch malformed token rejected', !Feed::validate_manifest_fetch_request(['token'], [])['ok']);

T::section('metadata-only privacy contract');

$expected_future_response_keys = [
    'schema_version',
    'phase',
    'boundary_token',
    'manifest_hash',
    'manifest_expires_at_gmt',
    'source_observed_at_gmt',
    'items',
    'next_cursor',
    'has_more',
    'terminal_evidence',
];
$expected_future_item_keys = [
    'source_order_id',
    'source_created_at_gmt',
    'source_modified_at_gmt',
];
T::same('future response envelope is versioned and closed', $expected_future_response_keys, Feed::future_response_keys());
T::same('future identity item is metadata-only', $expected_future_item_keys, Feed::future_item_keys());

$raw_sensitive_body = (string) json_encode([
    'source_system' => 'wordpress_woo:localhost',
    'backfill_start' => '2026-08-01T00:00:00Z',
    'backfill_cutoff' => '2026-08-12T00:00:00Z',
    'limit' => 100,
    'billing_email' => 'customer@example.test',
    'payment_token' => 'payment-secret',
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
$sensitive_timestamp = (string) time();
$sensitive_signature_base = EventSales_Woo_Order_Index_Feed::canonical_signature_input(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    '',
    $raw_sensitive_body,
    $sensitive_timestamp,
    'order-index-key-1'
);
$sensitive_headers = [
    'X-EventSales-Key-Id' => 'order-index-key-1',
    'X-EventSales-Timestamp' => $sensitive_timestamp,
    'X-EventSales-Signature' => 'v1=' . hash_hmac('sha256', $sensitive_signature_base, 'order-index-secret'),
];
$sensitive_response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create(request_for(
    'POST',
    '/wp-json/eventsales/v1/woo-order-index/manifests',
    [],
    $raw_sensitive_body,
    $sensitive_headers
));
$sensitive_json = json_encode($sensitive_response->get_data());
T::same('sensitive body is rejected as invalid request', 400, $sensitive_response->get_status());
T::ok('errors do not echo customer/payment fields', !preg_match('/customer|billing|shipping|payment|line_item|order_total/i', (string) $sensitive_json));
T::ok('errors do not echo secret or signature', strpos((string) $sensitive_json, 'order-index-secret') === false && strpos((string) $sensitive_json, (string) $sensitive_headers['X-EventSales-Signature']) === false);
T::ok('errors do not echo raw body', strpos((string) $sensitive_json, 'customer@example.test') === false && strpos((string) $sensitive_json, 'payment-secret') === false);

$unauthorized_response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($missing_signature);
$unauthorized_json = json_encode($unauthorized_response->get_data());
T::ok('unauthorized/error envelope has no PII fields', !preg_match('/customer|billing|shipping|payment|line_item|order_total|notes|raw_payload/i', (string) $unauthorized_json));

T::section('activated READY boundary');

$post_data = $valid_response->get_data();
T::same('activated POST status code', 200, $valid_response->get_status());
T::same('activated POST phase', 'manifest_enumerate', $post_data['phase'] ?? null);
T::same('activated POST boundary token', 'test-ready-token', $post_data['boundary_token'] ?? null);
T::same('activated POST response schema version', EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION, $post_data['schema_version'] ?? null);
T::ok('nonterminal POST has no terminal evidence', !array_key_exists('terminal_evidence', $post_data));
T::ok('terminal response has no cursor', !array_key_exists('next_cursor', $terminal_response->get_data()));
T::ok('POST has no page or offset fields', !array_key_exists('page', $post_data) && !array_key_exists('offset', $post_data));
T::same('standard Woo enumeration never called', 0, $GLOBALS['woo_calls']);

$fetch_data = $fetch_response->get_data();
T::same('GET fails closed without local storage', 503, $fetch_response->get_status());
T::same('GET storage error is bounded', 'manifest_storage_unavailable', $fetch_data['error'] ?? null);

$unavailable_response = (new EventSales_Woo_Order_Index_Feed())->handle_manifest_create($valid['request']);
T::same('production POST without WordPress storage fails closed', 503, $unavailable_response->get_status());
T::same('production POST storage error is bounded', 'manifest_builder_unavailable', $unavailable_response->get_data()['error'] ?? null);

$plugin_source = (string) file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-index-feed.php');
foreach (['wc_get_orders', 'wc_get_order', 'WP_Query', '$wpdb', 'OrderUpserter', 'set_transient', 'update_option', 'wp_insert_post'] as $forbidden) {
    T::ok('plugin source excludes ' . $forbidden, strpos($plugin_source, $forbidden) === false);
}

$catalog_plugin = dirname(__DIR__) . '/../eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php';
T::same(
    'catalog plugin remains byte-for-byte unchanged',
    '92a120800d1c2b224e741ca5c8f310478c4732b1883a0c001d21f839ee1207f2',
    hash_file('sha256', $catalog_plugin)
);
T::ok('catalog plugin does not declare order-index credentials', strpos((string) file_get_contents($catalog_plugin), 'EVENTSALES_WOO_ORDER_INDEX_') === false);

if (T::$failures !== []) {
    fwrite(STDERR, "Failures:\n");
    foreach (T::$failures as $failure) {
        fwrite(STDERR, '- ' . $failure . "\n");
    }
    exit(1);
}

echo 'order-index feed tests passed: ' . T::$passes . " assertions, 0 failures\n";
