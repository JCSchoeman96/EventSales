<?php
/**
 * Plugin Name: EventSales Woo Order Index Feed
 * Description: Provides authenticated Woo order identity manifest storage and a bounded READY reader.
 * Version: 0.2.0
 * Author: EventSales
 * License: GPL-2.0-or-later
 */

if (!defined('ABSPATH')) {
    exit;
}

if (!defined('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION')) {
    define('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION', '2026-08-12.v1');
}

if (!defined('EVENTSALES_WOO_ORDER_INDEX_NAMESPACE')) {
    define('EVENTSALES_WOO_ORDER_INDEX_NAMESPACE', 'eventsales/v1');
}

if (!defined('EVENTSALES_WOO_ORDER_INDEX_CREATE_ROUTE')) {
    define('EVENTSALES_WOO_ORDER_INDEX_CREATE_ROUTE', '/woo-order-index/manifests');
}

if (!defined('EVENTSALES_WOO_ORDER_INDEX_FETCH_ROUTE')) {
    define('EVENTSALES_WOO_ORDER_INDEX_FETCH_ROUTE', '/woo-order-index/manifests/(?P<token>[A-Za-z0-9._-]{1,128})');
}

require_once __DIR__ . '/eventsales-woo-order-index-manifest-store.php';

final class EventSales_Woo_Order_Index_Feed
{
    private const KEY_ID_OPTION = 'eventsales_woo_order_index_key_id';
    private const SECRET_OPTION = 'eventsales_woo_order_index_secret';
    private const MAX_TIMESTAMP_SKEW_SECONDS = 300;
    private const MAX_REQUEST_BYTES = 16384;
    private const MAX_LIMIT = 100;
    private const MAX_SOURCE_SYSTEM_BYTES = 128;
    private const MAX_TOKEN_BYTES = 128;

    private const FUTURE_RESPONSE_KEYS = [
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

    private const FUTURE_ITEM_KEYS = [
        'source_order_id',
        'source_created_at_gmt',
        'source_modified_at_gmt',
    ];

    public static function register(): void
    {
        $controller = new self();

        register_rest_route(
            EVENTSALES_WOO_ORDER_INDEX_NAMESPACE,
            EVENTSALES_WOO_ORDER_INDEX_CREATE_ROUTE,
            [
                'methods' => 'POST',
                'callback' => [$controller, 'handle_manifest_create'],
                'permission_callback' => '__return_true',
            ]
        );

        register_rest_route(
            EVENTSALES_WOO_ORDER_INDEX_NAMESPACE,
            EVENTSALES_WOO_ORDER_INDEX_FETCH_ROUTE,
            [
                'methods' => 'GET',
                'callback' => [$controller, 'handle_manifest_fetch'],
                'permission_callback' => '__return_true',
            ]
        );
    }

    public static function max_limit(): int
    {
        return self::MAX_LIMIT;
    }

    public static function key_id_option_name(): string
    {
        return self::KEY_ID_OPTION;
    }

    public static function secret_option_name(): string
    {
        return self::SECRET_OPTION;
    }

    /**
     * @return array<int, string>
     */
    public static function future_response_keys(): array
    {
        return self::FUTURE_RESPONSE_KEYS;
    }

    /**
     * @return array<int, string>
     */
    public static function future_item_keys(): array
    {
        return self::FUTURE_ITEM_KEYS;
    }

    public function handle_manifest_create(WP_REST_Request $request): WP_REST_Response
    {
        if (!$this->request_size_is_bounded($request)) {
            return self::error_response('request_too_large', 413);
        }

        if (!$this->authorized($request)) {
            return self::error_response('unauthorized', 401);
        }

        $body = $this->decode_json_body((string) $request->get_body());
        if (!$body['ok']) {
            return self::error_response('invalid_request', 400);
        }

        $validation = self::validate_manifest_request($body['value'], $request->get_query_params());
        if (!$validation['ok']) {
            return self::error_response('invalid_request', 400);
        }

        return self::capability_unavailable();
    }

    private function manifest_store(): ?EventSales_Woo_Order_Index_Manifest_Store
    {
        $database = $GLOBALS['wpdb'] ?? null;
        if (!is_object($database)) {
            return null;
        }

        return new EventSales_Woo_Order_Index_Manifest_Store($database);
    }

    public function handle_manifest_fetch(WP_REST_Request $request): WP_REST_Response
    {
        if (!$this->request_size_is_bounded($request)) {
            return self::error_response('request_too_large', 413);
        }

        if (!$this->authorized($request)) {
            return self::error_response('unauthorized', 401);
        }

        $validation = self::validate_manifest_fetch_request(
            $request->get_param('token'),
            $request->get_query_params()
        );
        if (!$validation['ok']) {
            return self::error_response('invalid_request', 400);
        }

        $store = $this->manifest_store();
        if ($store === null) {
            return self::capability_unavailable();
        }

        $token = $validation['values']['token'];
        $last_sequence = null;
        if (isset($validation['values']['cursor'])) {
            $cursor_secret = self::configured_value('EVENTSALES_WOO_ORDER_INDEX_SECRET', self::SECRET_OPTION);
            $last_sequence = EventSales_Woo_Order_Index_Manifest_Store::decode_cursor(
                $validation['values']['cursor'],
                EventSales_Woo_Order_Index_Manifest_Store::token_hash($token),
                $cursor_secret
            );
            if ($last_sequence === null) {
                return self::error_response('invalid_request', 400);
            }
        }

        $page = $store->read_page($token, $last_sequence, self::MAX_LIMIT);
        if (!$page['ok']) {
            return self::manifest_read_error((string) ($page['error'] ?? 'manifest_unavailable'));
        }

        $response = [
            'schema_version' => $page['schema_version'],
            'phase' => 'manifest_enumerate',
            'boundary_token' => $token,
            'manifest_hash' => $page['manifest_hash'],
            'manifest_expires_at_gmt' => $page['expires_at_gmt'],
            'source_observed_at_gmt' => $page['source_observed_at_gmt'],
            'items' => $page['items'],
            'has_more' => $page['has_more'],
        ];

        if ($page['has_more']) {
            $response['next_cursor'] = EventSales_Woo_Order_Index_Manifest_Store::encode_cursor(
                EventSales_Woo_Order_Index_Manifest_Store::token_hash($token),
                (int) $page['next_sequence'],
                self::configured_value('EVENTSALES_WOO_ORDER_INDEX_SECRET', self::SECRET_OPTION)
            );
        } else {
            $response['terminal_evidence'] = $page['terminal_evidence'];
        }

        return new WP_REST_Response($response, 200);
    }

    /**
     * Validate the source-side manifest creation scope without consulting
     * WooCommerce or EventSales state.
     *
     * @param mixed $payload
     * @param mixed $query
     * @return array{ok: bool, values?: array<string, mixed>}
     */
    public static function validate_manifest_request($payload, $query): array
    {
        if (!is_array($payload) || self::is_list($payload) || !is_array($query) || $query !== []) {
            return ['ok' => false];
        }

        $expected_keys = ['backfill_cutoff', 'backfill_start', 'limit', 'source_system'];
        $actual_keys = array_map('strval', array_keys($payload));
        sort($actual_keys, SORT_STRING);
        if ($actual_keys !== $expected_keys) {
            return ['ok' => false];
        }

        if (!is_string($payload['source_system'])) {
            return ['ok' => false];
        }

        $source_system = trim($payload['source_system']);
        if (
            $source_system === ''
            || strlen($source_system) > self::MAX_SOURCE_SYSTEM_BYTES
            || !preg_match('/^[A-Za-z0-9][A-Za-z0-9._:-]*$/D', $source_system)
        ) {
            return ['ok' => false];
        }

        $start = self::parse_utc_datetime($payload['backfill_start']);
        $cutoff = self::parse_utc_datetime($payload['backfill_cutoff']);
        if ($start === null || $cutoff === null || $start > $cutoff) {
            return ['ok' => false];
        }

        if (!is_int($payload['limit']) || $payload['limit'] < 1 || $payload['limit'] > self::MAX_LIMIT) {
            return ['ok' => false];
        }

        return [
            'ok' => true,
            'values' => [
                'source_system' => $source_system,
                'backfill_start' => $payload['backfill_start'],
                'backfill_cutoff' => $payload['backfill_cutoff'],
                'limit' => $payload['limit'],
            ],
        ];
    }

    /**
     * @param mixed $token
     * @param mixed $query
     * @return array{ok: bool, values?: array<string, string>}
     */
    public static function validate_manifest_fetch_request($token, $query): array
    {
        if (
            !is_string($token)
            || $token === ''
            || strlen($token) > self::MAX_TOKEN_BYTES
            || !preg_match('/^[A-Za-z0-9._-]+$/D', $token)
            || !is_array($query)
        ) {
            return ['ok' => false];
        }

        $actual_keys = array_map('strval', array_keys($query));
        sort($actual_keys, SORT_STRING);
        if ($actual_keys !== [] && $actual_keys !== ['cursor']) {
            return ['ok' => false];
        }

        if (array_key_exists('cursor', $query)) {
            if (
                !is_string($query['cursor'])
                || strlen($query['cursor']) < 16
                || strlen($query['cursor']) > 512
                || !preg_match('/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/D', $query['cursor'])
            ) {
                return ['ok' => false];
            }
        }

        $values = ['token' => $token];
        if (array_key_exists('cursor', $query)) {
            $values['cursor'] = $query['cursor'];
        }

        return ['ok' => true, 'values' => $values];
    }

    /**
     * Canonical query encoding used by the order-index signature contract.
     * Scalar query values use RFC3986 encoding; arrays/objects are encoded as
     * canonical JSON so their presence is authenticated before validation.
     *
     * @param array<string|int, mixed> $query
     */
    public static function canonical_query_string(array $query): string
    {
        $keys = array_map('strval', array_keys($query));
        sort($keys, SORT_STRING);
        $pairs = [];

        foreach ($keys as $key) {
            $value = $query[$key] ?? null;
            if (is_array($value) || is_object($value)) {
                $encoded_value = self::canonical_json($value);
            } elseif (is_bool($value)) {
                $encoded_value = $value ? 'true' : 'false';
            } elseif ($value === null) {
                $encoded_value = '';
            } else {
                $encoded_value = (string) $value;
            }

            $pairs[] = rawurlencode($key) . '=' . rawurlencode($encoded_value);
        }

        return implode('&', $pairs);
    }

    public static function canonical_signature_input(
        string $method,
        string $path,
        string $canonical_query,
        string $raw_body,
        string $timestamp,
        string $key_id
    ): string {
        return implode("\n", [
            strtoupper($method),
            $path,
            'query=' . $canonical_query,
            'body_sha256=' . hash('sha256', $raw_body),
            'timestamp=' . $timestamp,
            'key_id=' . $key_id,
        ]);
    }

    private function authorized(WP_REST_Request $request): bool
    {
        $configured_key_id = self::configured_value('EVENTSALES_WOO_ORDER_INDEX_KEY_ID', self::KEY_ID_OPTION);
        $secret = self::configured_value('EVENTSALES_WOO_ORDER_INDEX_SECRET', self::SECRET_OPTION);
        $key_id = self::header_value($request, 'x-eventsales-key-id');
        $timestamp = self::header_value($request, 'x-eventsales-timestamp');
        $signature = self::header_value($request, 'x-eventsales-signature');

        if ($configured_key_id === '' || $secret === '' || $key_id === null || $timestamp === null || $signature === null) {
            return false;
        }

        if (!hash_equals($configured_key_id, $key_id) || !self::timestamp_is_current($timestamp)) {
            return false;
        }

        if (!preg_match('/^v1=([a-f0-9]{64})$/D', $signature, $matches)) {
            return false;
        }

        $canonical_query = self::canonical_query_string($request->get_query_params());
        $base = self::canonical_signature_input(
            $request->get_method(),
            $this->request_path($request),
            $canonical_query,
            (string) $request->get_body(),
            $timestamp,
            $key_id
        );
        $expected = hash_hmac('sha256', $base, $secret);

        return hash_equals($expected, $matches[1]);
    }

    private static function configured_value(string $constant_name, string $option_name): string
    {
        if (defined($constant_name)) {
            $value = constant($constant_name);

            return is_scalar($value) ? trim((string) $value) : '';
        }

        if (function_exists('get_option')) {
            $value = get_option($option_name, '');

            return is_scalar($value) ? trim((string) $value) : '';
        }

        return '';
    }

    private static function header_value(WP_REST_Request $request, string $name): ?string
    {
        $value = $request->get_header($name);
        if (!is_scalar($value)) {
            return null;
        }

        return trim((string) $value);
    }

    private static function timestamp_is_current(string $timestamp): bool
    {
        if (!preg_match('/^(0|[1-9][0-9]*)$/D', $timestamp)) {
            return false;
        }

        $parsed = filter_var($timestamp, FILTER_VALIDATE_INT);
        if (!is_int($parsed) || (string) $parsed !== $timestamp) {
            return false;
        }

        $now = time();

        return $parsed >= $now - self::MAX_TIMESTAMP_SKEW_SECONDS
            && $parsed <= $now + self::MAX_TIMESTAMP_SKEW_SECONDS;
    }

    private function request_size_is_bounded(WP_REST_Request $request): bool
    {
        $body_size = strlen((string) $request->get_body());
        if ($body_size > self::MAX_REQUEST_BYTES) {
            return false;
        }

        $content_length = self::header_value($request, 'content-length');
        if ($content_length !== null && $content_length !== '') {
            if (!preg_match('/^[0-9]+$/D', $content_length) || (int) $content_length > self::MAX_REQUEST_BYTES) {
                return false;
            }
        }

        $request_uri = isset($_SERVER['REQUEST_URI']) && is_string($_SERVER['REQUEST_URI'])
            ? $_SERVER['REQUEST_URI']
            : '';
        $query_string = parse_url($request_uri, PHP_URL_QUERY);
        if (is_string($query_string)) {
            return $body_size + strlen($query_string) <= self::MAX_REQUEST_BYTES;
        }

        $query_size = 0;

        return self::query_values_fit($request->get_query_params(), $query_size, self::MAX_REQUEST_BYTES - $body_size);
    }

    /**
     * Estimate parsed query size without canonicalizing or recursively
     * materializing query JSON. The raw URI length is authoritative when it is
     * available; this conservative fallback keeps test and non-HTTP callers
     * bounded as well.
     *
     * @param mixed $value
     */
    private static function query_values_fit($value, int &$size, int $limit, int $depth = 0): bool
    {
        if ($depth > 8 || $size > $limit) {
            return false;
        }

        if (is_object($value)) {
            $value = get_object_vars($value);
        }

        if (is_array($value)) {
            foreach ($value as $key => $item) {
                $size += strlen((string) $key) + 2;
                if (!self::query_values_fit($item, $size, $limit, $depth + 1)) {
                    return false;
                }
            }

            return $size <= $limit;
        }

        if ($value !== null && is_scalar($value)) {
            $size += strlen((string) $value) + 2;
        }

        return $size <= $limit;
    }

    /**
     * @return array{ok: bool, value?: mixed}
     */
    private function decode_json_body(string $raw_body): array
    {
        if (trim($raw_body) === '') {
            return ['ok' => false];
        }

        try {
            $value = json_decode($raw_body, true, 512, JSON_THROW_ON_ERROR);
        } catch (Throwable $error) {
            return ['ok' => false];
        }

        return ['ok' => true, 'value' => $value];
    }

    private function request_path(WP_REST_Request $request): string
    {
        $request_uri = isset($_SERVER['REQUEST_URI']) && is_string($_SERVER['REQUEST_URI'])
            ? $_SERVER['REQUEST_URI']
            : '';
        $path = parse_url($request_uri, PHP_URL_PATH);

        if (is_string($path) && $path !== '') {
            return $path;
        }

        $route = $request->get_route();
        if (is_string($route) && $route !== '') {
            return '/wp-json/' . ltrim($route, '/');
        }

        return '/wp-json/' . trim(EVENTSALES_WOO_ORDER_INDEX_NAMESPACE, '/') . EVENTSALES_WOO_ORDER_INDEX_CREATE_ROUTE;
    }

    private static function error_response(string $code, int $status): WP_REST_Response
    {
        return new WP_REST_Response(['error' => $code], $status);
    }

    private static function capability_unavailable(): WP_REST_Response
    {
        return new WP_REST_Response([
            'error' => 'manifest_capability_unavailable',
            'schema_version' => EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION,
            'capability' => 'woo_order_index_manifest',
            'capability_status' => 'not_implemented',
        ], 501);
    }

    private static function manifest_read_error(string $error): WP_REST_Response
    {
        return match ($error) {
            'manifest_expired' => self::error_response('manifest_expired', 410),
            'manifest_not_found' => self::error_response('manifest_not_found', 404),
            'manifest_not_ready', 'manifest_failed', 'manifest_unavailable' => self::error_response('manifest_unavailable', 404),
            default => self::error_response('manifest_unavailable', 404),
        };
    }

    /**
     * @param mixed $value
     */
    private static function parse_utc_datetime($value): ?DateTimeImmutable
    {
        if (!is_string($value) || !preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/D', $value)) {
            return null;
        }

        $has_fraction = strpos($value, '.') !== false;
        $format = $has_fraction ? '!Y-m-d\\TH:i:s.u\\Z' : '!Y-m-d\\TH:i:s\\Z';
        $date = DateTimeImmutable::createFromFormat($format, $value, new DateTimeZone('UTC'));
        $errors = DateTimeImmutable::getLastErrors();

        if (
            $date === false
            || ($errors !== false && ($errors['warning_count'] > 0 || $errors['error_count'] > 0))
            || $date->format('Y-m-d\\TH:i:s') !== substr($value, 0, 19)
        ) {
            return null;
        }

        if ($has_fraction) {
            $fraction = substr($value, 20, -1);
            if ($date->format('u') !== str_pad($fraction, 6, '0')) {
                return null;
            }
        }

        return $date;
    }

    /**
     * @param mixed $value
     */
    private static function canonical_json($value): string
    {
        if (is_null($value)) {
            return 'null';
        }

        if (is_bool($value)) {
            return $value ? 'true' : 'false';
        }

        if (is_int($value) || is_float($value)) {
            return (string) json_encode($value, JSON_PRESERVE_ZERO_FRACTION);
        }

        if (is_string($value)) {
            return (string) json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        }

        if (is_object($value)) {
            $value = get_object_vars($value);
        }

        if (!is_array($value)) {
            return 'null';
        }

        if (self::is_list($value)) {
            $items = [];
            foreach ($value as $item) {
                $items[] = self::canonical_json($item);
            }

            return '[' . implode(',', $items) . ']';
        }

        $keys = array_map('strval', array_keys($value));
        sort($keys, SORT_STRING);
        $pairs = [];
        foreach ($keys as $key) {
            $pairs[] = self::canonical_json($key) . ':' . self::canonical_json($value[$key]);
        }

        return '{' . implode(',', $pairs) . '}';
    }

    /**
     * @param array<int|string, mixed> $value
     */
    private static function is_list(array $value): bool
    {
        return $value === [] || array_keys($value) === range(0, count($value) - 1);
    }
}

if (function_exists('add_action')) {
    add_action('rest_api_init', ['EventSales_Woo_Order_Index_Feed', 'register']);
}

if (function_exists('register_activation_hook')) {
    register_activation_hook(__FILE__, static function (): void {
        $database = $GLOBALS['wpdb'] ?? null;
        if (is_object($database)) {
            EventSales_Woo_Order_Index_Manifest_Store::activate($database);
        }
    });
}
