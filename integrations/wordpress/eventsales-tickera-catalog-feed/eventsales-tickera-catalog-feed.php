<?php
/**
 * Plugin Name: EventSales Tickera Catalog Feed
 * Description: Exposes a sanitized, authenticated Tickera/WooCommerce catalog feed for EventSales catalog discovery.
 * Version: 0.1.0
 * Author: EventSales
 * License: GPL-2.0-or-later
 */

if (!defined('ABSPATH')) {
    exit;
}

if (!defined('EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION')) {
    define('EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION', '2026-08-07.v3');
}

if (!defined('EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION')) {
    define('EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION', 'source_risk.v3');
}

if (!defined('EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION')) {
    define('EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION', '2026-08-07.1');
}

if (!defined('EVENTSALES_TICKERA_CATALOG_NAMESPACE')) {
    define('EVENTSALES_TICKERA_CATALOG_NAMESPACE', 'eventsales/v1');
}

if (!defined('EVENTSALES_TICKERA_CATALOG_ROUTE')) {
    define('EVENTSALES_TICKERA_CATALOG_ROUTE', '/tickera-catalog');
}

final class EventSales_Tickera_Catalog_Feed
{
    /**
     * Test-only seam invoked between the before/after SnapshotGeneration reads.
     *
     * Production code never assigns this. It exists so tests can force a
     * mid-page catalogue generation change without touching production
     * authority. It cannot relax or bypass the equality requirement.
     *
     * @var callable|null
     */
    public static $test_generation_mutator = null;

    private static array $catalog_change_targets = [];
    private static int $catalog_change_sequence = 0;
    private const SOURCE = 'wordpress_tickera';
    private const CACHE_VERSION_OPTION = 'eventsales_tickera_catalog_feed_cache_version';
    private const SNAPSHOT_GENERATION_OPTION = 'eventsales_tickera_catalog_snapshot_generation';
    private const SECRET_OPTION = 'eventsales_tickera_catalog_secret';
    private const CACHE_TTL_OPTION = 'eventsales_tickera_catalog_cache_ttl';
    private const MAX_TIMESTAMP_SKEW_SECONDS = 300;
    private const DEFAULT_PER_PAGE = 100;
    /**
     * Legacy `2026-07-22.v2` page bound. Never applied to native
     * `2026-08-07.v3` pages, which are bounded by NATIVE_MAX_PER_PAGE.
     */
    private const LEGACY_MAX_PER_PAGE = 500;
    private const NATIVE_MAX_PER_PAGE = 100;
    private const MAX_EVIDENCE_PER_PAGE = 500;
    private const MAX_CATALOG_ROWS_PER_PAGE = 100;
    private const MAX_RAW_PRODUCER_CODE_BYTES = 64;
    private const MAX_EVIDENCE_VALUE_BYTES = 64;
    private const DEFAULT_CACHE_TTL_SECONDS = 120;
    private const MIN_CACHE_TTL_SECONDS = 30;
    private const MAX_CACHE_TTL_SECONDS = 300;

    private const NATIVE_ENVELOPE_KEYS = [
        'schema_version',
        'canonical_contract_version',
        'producer_version',
        'source',
        'source_system_id',
        'discovery_snapshot_id',
        'source_snapshot_at',
        'generated_at',
        'page',
        'per_page',
        'has_more',
        'filters',
        'events',
        'catalog_rows',
        'evidence',
    ];

    private const NATIVE_FILTER_KEYS = [
        'updated_since',
        'product_id',
        'variation_id',
        'event_id',
        'include_private',
    ];

    private const LIFECYCLE_VALUES = ['publish', 'private', 'draft', 'trash', 'deleted'];

    private const SUPPORTED_PRODUCT_TYPES = ['simple'];

    private const CAPABILITY_DIMENSIONS = ['payment_plan', 'membership', 'bundle', 'add_on'];

    private const PRODUCER_SOURCE_KEYS = [
        'lifecycle' => 'wp_posts.post_status',
        'ticket_template' => 'postmeta:_ticket_template',
        'event_link' => 'postmeta:_event_name+tc_events.resolve',
        'subscription' => 'wc_product_type+subscription_evidence',
        'product_type' => 'wc_get_product.type',
        'capability' => 'product_semantics_capability',
    ];

    private const PROVENANCE_KEYS = [
        'discovery_snapshot_id',
        'producer_version',
        'producer_source_key',
        'raw_producer_code',
        'woo_product_id',
        'woo_variation_id',
        'tickera_event_id',
    ];

    private const ALLOWED_QUERY_PARAMS = [
        'updated_since',
        'product_id',
        'variation_id',
        'event_id',
        'page',
        'per_page',
        'include_private',
    ];

    private const ALLOWED_META_KEYS = [
        'custom_produk_blad_toegang_naam',
        '_price',
        '_regular_price',
        '_ticket_template',
        '_subscription_period',
        '_subscription_length',
        '_subscription_price',
        '_subscription_sign_up_fee',
        '_wc_subscription_period',
        '_wc_subscription_length',
    ];

    private const ALLOWED_EVENT_META_KEYS = [
        'booking_fee_type',
        'booking_fee_value',
        'event_date_time',
        'event_end_date_time',
        'event_location',
    ];

    public static function register(): void
    {
        $controller = new self();

        register_rest_route(
            EVENTSALES_TICKERA_CATALOG_NAMESPACE,
            EVENTSALES_TICKERA_CATALOG_ROUTE,
            [
                'methods' => 'GET',
                'callback' => [$controller, 'handle_request'],
                'permission_callback' => '__return_true',
            ]
        );
    }

    /**
     * Every catalogue-relevant invalidation bumps the transient cache version
     * and rotates the durable SnapshotGeneration record.
     */
    public static function invalidate_cache(): void
    {
        $current = (int) get_option(self::CACHE_VERSION_OPTION, 1);
        update_option(self::CACHE_VERSION_OPTION, $current + 1, false);
        self::rotate_snapshot_generation();
    }

    /**
     * @return array{generation_token: string, generation_at: string}
     */
    public static function read_or_create_snapshot_generation(): array
    {
        $stored = get_option(self::SNAPSHOT_GENERATION_OPTION, null);
        $valid = self::valid_snapshot_generation($stored);

        if ($valid !== null) {
            return $valid;
        }

        return self::rotate_snapshot_generation();
    }

    /**
     * Replaces the whole SnapshotGeneration record with a new opaque token.
     *
     * @return array{generation_token: string, generation_at: string}
     */
    public static function rotate_snapshot_generation(): array
    {
        $record = [
            'generation_token' => self::generate_generation_token(),
            'generation_at' => self::utc_now(),
        ];

        update_option(self::SNAPSHOT_GENERATION_OPTION, $record, false);

        return $record;
    }

    /**
     * @param array{generation_token: string, generation_at: string}|null $left
     * @param array{generation_token: string, generation_at: string}|null $right
     */
    public static function snapshot_generations_equal(?array $left, ?array $right): bool
    {
        $left = self::valid_snapshot_generation($left);
        $right = self::valid_snapshot_generation($right);

        if ($left === null || $right === null) {
            return false;
        }

        return hash_equals($left['generation_token'], $right['generation_token'])
            && hash_equals($left['generation_at'], $right['generation_at']);
    }

    /**
     * Fails closed when the catalogue generation changed while a page was
     * being materialised. No page is emitted for a changed generation.
     *
     * @param array{generation_token: string, generation_at: string} $generation_before
     * @return array{generation_token: string, generation_at: string}
     */
    public static function require_stable_snapshot_generation(array $generation_before): array
    {
        if (self::$test_generation_mutator !== null && is_callable(self::$test_generation_mutator)) {
            call_user_func(self::$test_generation_mutator);
        }

        $generation_after = self::read_or_create_snapshot_generation();

        if (!self::snapshot_generations_equal($generation_before, $generation_after)) {
            throw new RuntimeException('snapshot_generation_changed_mid_page');
        }

        return $generation_after;
    }

    /**
     * @return array{generation_token: string, generation_at: string}|null
     */
    private static function valid_snapshot_generation($record): ?array
    {
        if (!is_array($record)) {
            return null;
        }

        $token = isset($record['generation_token']) ? (string) $record['generation_token'] : '';
        $generation_at = isset($record['generation_at']) ? (string) $record['generation_at'] : '';

        if (!preg_match('/^[a-f0-9]{32,}$/', $token)) {
            return null;
        }

        if (!preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/', $generation_at)) {
            return null;
        }

        return ['generation_token' => $token, 'generation_at' => $generation_at];
    }

    /**
     * Opaque token. Never derived from a counter, timestamp arithmetic, or the
     * previous token.
     */
    private static function generate_generation_token(): string
    {
        if (function_exists('random_bytes')) {
            try {
                return bin2hex(random_bytes(16));
            } catch (Throwable $error) {
                // Fall through to the WordPress UUID source.
            }
        }

        if (function_exists('wp_generate_uuid4')) {
            $uuid = strtolower(str_replace('-', '', (string) wp_generate_uuid4()));
            if (preg_match('/^[a-f0-9]{32,}$/', $uuid)) {
                return $uuid;
            }
        }

        return hash('sha256', uniqid('eventsales_tickera_catalog', true));
    }

    public static function record_catalog_change(int $post_id, string $reason = 'saved'): void
    {
        if (wp_is_post_autosave($post_id) || wp_is_post_revision($post_id)) {
            return;
        }
        $target_type = self::catalog_target_type($post_id);
        if ($target_type === null) {
            return;
        }
        self::$catalog_change_sequence++;
        $key = $target_type . ':' . $post_id;
        $candidate = ['target_type' => $target_type, 'target_id' => $post_id,
            'reason' => $reason, 'priority' => self::reason_priority($reason),
            'sequence' => self::$catalog_change_sequence, 'source_updated_at' => gmdate('Y-m-d\TH:i:s.u\Z')];
        $current = self::$catalog_change_targets[$key] ?? null;
        if ($current === null || $candidate['priority'] > $current['priority'] ||
            ($candidate['priority'] === $current['priority'] && $candidate['sequence'] > $current['sequence'])) {
            self::$catalog_change_targets[$key] = $candidate;
        }
    }

    public static function record_status_change(string $new_status, string $old_status, WP_Post $post): void
    {
        if ($new_status !== $old_status) {
            self::invalidate_and_record((int) $post->ID, 'status_changed');
        }
    }

    public static function record_meta_change($meta_id, int $post_id, string $meta_key): void
    {
        $allowed = array_merge(self::ALLOWED_META_KEYS, self::ALLOWED_EVENT_META_KEYS, ['_tc_is_ticket', '_event_name']);
        if (in_array($meta_key, $allowed, true)) {
            self::invalidate_and_record($post_id, 'metadata_changed');
        }
    }

    public static function record_trashed(int $post_id): void
    {
        self::invalidate_and_record($post_id, 'trashed');
    }

    public static function record_restored(int $post_id): void
    {
        self::invalidate_and_record($post_id, 'restored');
    }

    public static function record_deleted(int $post_id): void
    {
        self::invalidate_and_record($post_id, 'deleted');
    }

    public static function flush_catalog_changes(): void
    {
        if (!defined('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED') || !EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED) return;
        if (!function_exists('as_enqueue_async_action')) {
            error_log('eventsales_catalog_change_scheduler_unavailable');
            return;
        }
        foreach (self::$catalog_change_targets as $target) {
            unset($target['priority'], $target['sequence']);
            $target = array_merge(['version' => '2026-07-20.v1', 'signal_id' => wp_generate_uuid4(),
                'source' => self::SOURCE], $target);
            as_enqueue_async_action('eventsales_catalog_change_deliver',
                ['raw_body' => wp_json_encode($target), 'attempt' => 1], 'eventsales-catalog-change');
        }
        self::$catalog_change_targets = [];
    }

    public static function deliver_catalog_change(string $raw_body, int $attempt = 1): void
    {
        if (!defined('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED') || !EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED) return;
        $endpoint = defined('EVENTSALES_CATALOG_CHANGE_ENDPOINT') ? EVENTSALES_CATALOG_CHANGE_ENDPOINT : '';
        $secret = defined('EVENTSALES_CATALOG_CHANGE_SECRET') ? EVENTSALES_CATALOG_CHANGE_SECRET : '';
        $key_id = defined('EVENTSALES_CATALOG_CHANGE_KEY_ID') ? EVENTSALES_CATALOG_CHANGE_KEY_ID : '';
        if ($endpoint === '' || $secret === '' || $key_id === '') return;
        $timestamp = (string) time();
        $path = (string) wp_parse_url($endpoint, PHP_URL_PATH);
        $base = implode("\n", ['2026-07-20.v1', 'POST', $path, $timestamp, hash('sha256', $raw_body)]);
        $response = wp_remote_post($endpoint, ['timeout' => 5, 'body' => $raw_body, 'headers' => [
            'Content-Type' => 'application/json', 'Accept' => 'application/json',
            'X-EventSales-Trigger-Key-Id' => $key_id,
            'X-EventSales-Trigger-Timestamp' => $timestamp,
            'X-EventSales-Trigger-Signature' => 'v1=' . hash_hmac('sha256', $base, $secret),
        ]]);
        $status = is_wp_error($response) ? 0 : (int) wp_remote_retrieve_response_code($response);
        if (($status === 0 || in_array($status, [408, 425, 429], true) || $status >= 500) && $attempt < 5 && function_exists('as_schedule_single_action')) {
            $delays = [1 => 30, 2 => 120, 3 => 600, 4 => 1800];
            as_schedule_single_action(time() + $delays[$attempt], 'eventsales_catalog_change_deliver',
                ['raw_body' => $raw_body, 'attempt' => $attempt + 1], 'eventsales-catalog-change');
        }
    }

    private static function reason_priority(string $reason): int
    {
        return ['saved' => 1, 'metadata_changed' => 2, 'status_changed' => 3,
            'trashed' => 4, 'restored' => 4, 'deleted' => 5][$reason] ?? 1;
    }

    private static function invalidate_and_record(int $post_id, string $reason): void
    {
        if (self::catalog_target_type($post_id) === null) {
            return;
        }

        self::invalidate_cache();
        self::record_catalog_change($post_id, $reason);
    }

    private static function catalog_target_type(int $post_id): ?string
    {
        $types = ['tc_events' => 'event', 'product' => 'product', 'product_variation' => 'variation'];
        return $types[get_post_type($post_id)] ?? null;
    }

    public function handle_request(WP_REST_Request $request): WP_REST_Response
    {
        if (!$this->authorized($request)) {
            return $this->error_response('unauthorized', 401);
        }

        $params_result = $this->validated_params($request);
        if (is_wp_error($params_result)) {
            return $this->error_response(
                'invalid_request',
                400,
                $params_result->get_error_message()
            );
        }

        $params = $params_result;
        $cache_key = $this->cache_key($params);
        $cached = get_transient($cache_key);

        if (is_array($cached)) {
            return new WP_REST_Response($cached, 200);
        }

        try {
            $response = $this->build_response($params);
            set_transient($cache_key, $response, $this->cache_ttl());

            return new WP_REST_Response($response, 200);
        } catch (Throwable $error) {
            return $this->error_response('server_error', 500);
        }
    }

    private function authorized(WP_REST_Request $request): bool
    {
        $secret = $this->feed_secret();
        if ($secret === '') {
            return false;
        }

        $timestamp = trim((string) $request->get_header('x-eventsales-timestamp'));
        $signature = trim((string) $request->get_header('x-eventsales-signature'));

        if (!preg_match('/^\d+$/', $timestamp)) {
            return false;
        }

        if (abs(time() - (int) $timestamp) > self::MAX_TIMESTAMP_SKEW_SECONDS) {
            return false;
        }

        if (!preg_match('/^v1=([a-f0-9]{64})$/i', $signature, $matches)) {
            return false;
        }

        $base_string = implode("\n", [
            strtoupper($request->get_method()),
            $this->request_path(),
            $this->canonical_query($request),
            $timestamp,
        ]);

        $expected = hash_hmac('sha256', $base_string, $secret);

        return hash_equals(strtolower($matches[1]), strtolower($expected));
    }

    private function feed_secret(): string
    {
        if (defined('EVENTSALES_TICKERA_CATALOG_SECRET')) {
            $constant = trim((string) constant('EVENTSALES_TICKERA_CATALOG_SECRET'));
            if ($constant !== '') {
                return $constant;
            }
        }

        return trim((string) get_option(self::SECRET_OPTION, ''));
    }

    private function request_path(): string
    {
        $uri = isset($_SERVER['REQUEST_URI']) ? (string) wp_unslash($_SERVER['REQUEST_URI']) : '';
        $path = (string) wp_parse_url($uri, PHP_URL_PATH);

        if ($path !== '') {
            return $path;
        }

        $prefix = rest_get_url_prefix();

        return '/' . trim($prefix, '/') . '/' . trim(EVENTSALES_TICKERA_CATALOG_NAMESPACE, '/') . EVENTSALES_TICKERA_CATALOG_ROUTE;
    }

    private function canonical_query(WP_REST_Request $request): string
    {
        $params = [];

        foreach ($request->get_query_params() as $key => $value) {
            if (is_array($value) || is_object($value)) {
                continue;
            }

            $params[(string) $key] = (string) $value;
        }

        ksort($params, SORT_STRING);
        $pairs = [];

        foreach ($params as $key => $value) {
            $pairs[] = rawurlencode($key) . '=' . rawurlencode($value);
        }

        return implode('&', $pairs);
    }

    /**
     * @return array<string, mixed>|WP_Error
     */
    private function validated_params(WP_REST_Request $request)
    {
        foreach ($request->get_query_params() as $key => $value) {
            if (is_array($value) || is_object($value)) {
                return new WP_Error('invalid_request', 'Invalid ' . (string) $key);
            }
        }

        $params = [];

        foreach (self::ALLOWED_QUERY_PARAMS as $key) {
            $value = $request->get_param($key);
            if (is_array($value) || is_object($value)) {
                return new WP_Error('invalid_request', 'Invalid ' . $key);
            }
            $params[$key] = $value;
        }

        $page = $this->positive_integer($params['page'], 'page', 1);
        if (is_wp_error($page)) {
            return $page;
        }

        $per_page = self::validate_native_per_page($params['per_page']);
        if ($per_page === null) {
            return new WP_Error('invalid_request', 'Invalid per_page');
        }

        $product_id = $this->optional_positive_integer($params['product_id'], 'product_id');
        if (is_wp_error($product_id)) {
            return $product_id;
        }

        $variation_id = $this->optional_positive_integer($params['variation_id'], 'variation_id');
        if (is_wp_error($variation_id)) {
            return $variation_id;
        }

        $event_id = $this->optional_positive_integer($params['event_id'], 'event_id');
        if (is_wp_error($event_id)) {
            return $event_id;
        }

        $updated_since = $this->optional_rfc3339_datetime($params['updated_since']);
        if (is_wp_error($updated_since)) {
            return $updated_since;
        }

        $include_private = $this->boolean_param($params['include_private']);
        if (is_wp_error($include_private)) {
            return $include_private;
        }

        return [
            'updated_since' => $updated_since,
            'product_id' => $product_id,
            'variation_id' => $variation_id,
            'event_id' => $event_id,
            'page' => $page,
            'per_page' => $per_page,
            'include_private' => $include_private,
        ];
    }

    /**
     * Native `2026-08-07.v3` page bound. Returns null for a rejected value.
     */
    public static function validate_native_per_page($value): ?int
    {
        if ($value === null || $value === '') {
            return self::DEFAULT_PER_PAGE;
        }

        if (!preg_match('/^[1-9][0-9]*$/', (string) $value)) {
            return null;
        }

        $per_page = (int) $value;

        if ($per_page > self::NATIVE_MAX_PER_PAGE) {
            return null;
        }

        return $per_page;
    }

    public static function native_max_per_page(): int
    {
        return self::NATIVE_MAX_PER_PAGE;
    }

    /**
     * @return array<int, string>
     */
    public static function native_envelope_keys(): array
    {
        return self::NATIVE_ENVELOPE_KEYS;
    }

    /**
     * Normalizes a WordPress home URL into the exact string hashed into
     * `source_system_id`. Returns null when no usable origin exists.
     */
    public static function normalize_home_url($url): ?string
    {
        if (!is_string($url) || trim($url) === '') {
            return null;
        }

        $parts = function_exists('wp_parse_url') ? wp_parse_url(trim($url)) : parse_url(trim($url));

        if (!is_array($parts)) {
            return null;
        }

        $scheme = isset($parts['scheme']) ? strtolower((string) $parts['scheme']) : '';
        $host = isset($parts['host']) ? strtolower((string) $parts['host']) : '';

        if (!in_array($scheme, ['http', 'https'], true) || $host === '') {
            return null;
        }

        $port = isset($parts['port']) ? (int) $parts['port'] : 0;
        $default_port = $scheme === 'https' ? 443 : 80;
        $authority = $host;

        if ($port > 0 && $port !== $default_port) {
            $authority .= ':' . $port;
        }

        $path = isset($parts['path']) ? rtrim((string) $parts['path'], '/') : '';

        return $scheme . '://' . $authority . $path;
    }

    /**
     * Derive-only source identity. There is no override constant, option, or
     * filter: the identity is always `wordpress_tickera:<sha256(home)>`.
     */
    public static function derive_source_system_id($url): ?string
    {
        $normalized = self::normalize_home_url($url);

        if ($normalized === null) {
            return null;
        }

        return self::SOURCE . ':' . hash('sha256', $normalized);
    }

    /**
     * Canonical JSON: recursively lexicographically sorted object keys,
     * explicit null, boolean literals, integers as integers, UTF-8, and no
     * insignificant whitespace.
     */
    public static function canonical_json($value): string
    {
        if ($value === null) {
            return 'null';
        }

        if (is_bool($value)) {
            return $value ? 'true' : 'false';
        }

        if (is_int($value)) {
            return (string) $value;
        }

        if (is_float($value)) {
            throw new RuntimeException('canonical_json_float_unsupported');
        }

        if (is_string($value)) {
            return (string) json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        }

        if (!is_array($value)) {
            throw new RuntimeException('canonical_json_unsupported_type');
        }

        if (self::is_json_list($value)) {
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
     * Canonical identity document for `discovery_snapshot_id`.
     *
     * Page, per_page, and cursor state are never part of snapshot identity.
     *
     * @param array<string, mixed> $filters
     */
    public static function canonical_discovery_json(string $source_system_id, string $generation_token, array $filters): string
    {
        return self::canonical_json([
            'schema_version' => EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION,
            'canonical_contract_version' => EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION,
            'producer_version' => EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION,
            'source' => self::SOURCE,
            'source_system_id' => $source_system_id,
            'generation_token' => $generation_token,
            'filters' => self::native_filter_identity($filters),
        ]);
    }

    /**
     * @param array<string, mixed> $filters
     */
    public static function discovery_snapshot_id(string $source_system_id, string $generation_token, array $filters): string
    {
        return hash('sha256', self::canonical_discovery_json($source_system_id, $generation_token, $filters));
    }

    /**
     * @param array<string, mixed> $filters
     * @return array<string, mixed>
     */
    private static function native_filter_identity(array $filters): array
    {
        $identity = [];

        foreach (self::NATIVE_FILTER_KEYS as $key) {
            $identity[$key] = array_key_exists($key, $filters) ? $filters[$key] : null;
        }

        return $identity;
    }

    /**
     * @param array<int|string, mixed> $value
     */
    private static function is_json_list(array $value): bool
    {
        return $value === [] || array_keys($value) === range(0, count($value) - 1);
    }

    private function positive_integer($value, string $name, int $default)
    {
        if ($value === null || $value === '') {
            return $default;
        }

        if (!preg_match('/^[1-9][0-9]*$/', (string) $value)) {
            return new WP_Error('invalid_request', 'Invalid ' . $name);
        }

        return (int) $value;
    }

    private function optional_positive_integer($value, string $name)
    {
        if ($value === null || $value === '') {
            return null;
        }

        if (!preg_match('/^[1-9][0-9]*$/', (string) $value)) {
            return new WP_Error('invalid_request', 'Invalid ' . $name);
        }

        return (int) $value;
    }

    private function optional_rfc3339_datetime($value)
    {
        if ($value === null || $value === '') {
            return null;
        }

        $text = (string) $value;
        if (!preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/', $text)) {
            return new WP_Error('invalid_request', 'Invalid updated_since');
        }

        try {
            $datetime = new DateTimeImmutable($text);
        } catch (Exception $error) {
            return new WP_Error('invalid_request', 'Invalid updated_since');
        }

        return $datetime->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d H:i:s');
    }

    private function boolean_param($value)
    {
        if ($value === null || $value === '') {
            return false;
        }

        $normalized = strtolower((string) $value);
        if (in_array($normalized, ['1', 'true', 'yes'], true)) {
            return true;
        }
        if (in_array($normalized, ['0', 'false', 'no'], true)) {
            return false;
        }

        return new WP_Error('invalid_request', 'Invalid include_private');
    }

    /**
     * @param array<string, mixed> $params
     */
    private function cache_key(array $params): string
    {
        return self::cache_key_for(
            $params,
            self::read_or_create_snapshot_generation(),
            (int) get_option(self::CACHE_VERSION_OPTION, 1)
        );
    }

    /**
     * Cached pages are bound to the SnapshotGeneration record, so a rotated
     * generation can never serve a page materialised under the old generation.
     *
     * @param array<string, mixed> $params
     * @param array{generation_token: string, generation_at: string} $generation
     */
    public static function cache_key_for(array $params, array $generation, int $cache_version): string
    {
        $payload = self::canonical_json([
            'schema_version' => EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION,
            'canonical_contract_version' => EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION,
            'producer_version' => EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION,
            'generation_token' => (string) ($generation['generation_token'] ?? ''),
            'generation_at' => (string) ($generation['generation_at'] ?? ''),
            'params' => self::canonical_params($params),
        ]);

        return 'eventsales_tickera_catalog_' . $cache_version . '_' . hash('sha256', $payload);
    }

    /**
     * @param array<string, mixed> $params
     * @return array<string, mixed>
     */
    private static function canonical_params(array $params): array
    {
        $canonical = [];

        foreach ($params as $key => $value) {
            if ($value === null || is_bool($value) || is_int($value)) {
                $canonical[(string) $key] = $value;
                continue;
            }

            $canonical[(string) $key] = (string) $value;
        }

        return $canonical;
    }

    private function cache_ttl(): int
    {
        if (defined('EVENTSALES_TICKERA_CATALOG_CACHE_TTL')) {
            $ttl = (int) constant('EVENTSALES_TICKERA_CATALOG_CACHE_TTL');
        } else {
            $ttl = (int) get_option(self::CACHE_TTL_OPTION, self::DEFAULT_CACHE_TTL_SECONDS);
        }

        return max(self::MIN_CACHE_TTL_SECONDS, min(self::MAX_CACHE_TTL_SECONDS, $ttl));
    }

    /**
     * @param array<string, mixed> $params
     * @return array<string, mixed>
     */
    private function build_response(array $params): array
    {
        $generation_before = self::read_or_create_snapshot_generation();

        $source_system_id = self::derive_source_system_id(self::home_url_value());
        if ($source_system_id === null) {
            throw new RuntimeException('source_system_id_underivable');
        }

        $filters = [
            'updated_since' => $this->sql_datetime_to_iso8601($params['updated_since']),
            'product_id' => $params['product_id'],
            'variation_id' => $params['variation_id'],
            'event_id' => $params['event_id'],
            'include_private' => $params['include_private'],
        ];

        $discovery_snapshot_id = self::discovery_snapshot_id(
            $source_system_id,
            $generation_before['generation_token'],
            $filters
        );

        $per_page = (int) $params['per_page'];
        $catalog = $this->catalog_rows($params);
        $catalog_rows = array_slice($catalog['rows'], 0, $per_page);
        $observations = array_slice($catalog['observations'], 0, $per_page);

        if (count($catalog_rows) > self::MAX_CATALOG_ROWS_PER_PAGE) {
            throw new RuntimeException('catalog_rows_page_limit_exceeded');
        }

        $events = $this->event_rows($params);
        $evidence = self::build_native_evidence($observations, $discovery_snapshot_id);
        $envelope = self::native_envelope([
            'source_system_id' => $source_system_id,
            'discovery_snapshot_id' => $discovery_snapshot_id,
            'source_snapshot_at' => $generation_before['generation_at'],
            'generated_at' => self::utc_now(),
            'page' => (int) $params['page'],
            'per_page' => $per_page,
            'has_more' => count($catalog['rows']) > $per_page,
            'filters' => $filters,
            'events' => $events,
            'catalog_rows' => $catalog_rows,
            'evidence' => $evidence,
        ]);

        self::require_stable_snapshot_generation($generation_before);

        return $envelope;
    }

    /**
     * Assembles the exact native envelope: fifteen keys, no extras.
     *
     * @param array<string, mixed> $page
     * @return array<string, mixed>
     */
    public static function native_envelope(array $page): array
    {
        return [
            'schema_version' => EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION,
            'canonical_contract_version' => EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION,
            'producer_version' => EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION,
            'source' => self::SOURCE,
            'source_system_id' => $page['source_system_id'],
            'discovery_snapshot_id' => $page['discovery_snapshot_id'],
            'source_snapshot_at' => $page['source_snapshot_at'],
            'generated_at' => $page['generated_at'],
            'page' => $page['page'],
            'per_page' => $page['per_page'],
            'has_more' => $page['has_more'],
            'filters' => $page['filters'],
            'events' => $page['events'],
            'catalog_rows' => $page['catalog_rows'],
            'evidence' => $page['evidence'],
        ];
    }

    private static function home_url_value(): string
    {
        return function_exists('home_url') ? (string) home_url() : '';
    }

    /**
     * @param array<string, mixed> $params
     * @return array{rows: array<int, array<string, mixed>>, observations: array<int, array<string, mixed>>}
     */
    private function catalog_rows(array $params): array
    {
        global $wpdb;

        $posts = $wpdb->posts;
        $postmeta = $wpdb->postmeta;
        $targeted = $params['product_id'] !== null || $params['variation_id'] !== null || $params['include_private'];
        $where = [
            "p.post_type = 'product'",
            "is_ticket.meta_value = 'yes'",
        ];
        $values = [];

        $joins = [
            "JOIN {$postmeta} is_ticket ON is_ticket.post_id = p.ID AND is_ticket.meta_key = '_tc_is_ticket'",
            ($targeted ? 'LEFT JOIN' : 'JOIN') . " {$postmeta} event_meta ON event_meta.post_id = p.ID AND event_meta.meta_key = '_event_name'",
            ($targeted ? 'LEFT JOIN' : 'JOIN') . " {$posts} ev ON ev.ID = CAST(event_meta.meta_value AS UNSIGNED) AND ev.post_type = 'tc_events'",
            "LEFT JOIN {$postmeta} pm ON pm.post_id = p.ID AND pm.meta_key IN (" . $this->sql_placeholders(count(self::ALLOWED_META_KEYS)) . ')',
            "LEFT JOIN {$posts} variation ON variation.post_parent = p.ID AND variation.post_type = 'product_variation'",
        ];
        $values = array_merge($values, self::ALLOWED_META_KEYS);

        if (!$targeted) {
            $where[] = "p.post_status = 'publish'";
            $where[] = "ev.post_status = 'publish'";
            $where[] = "(variation.ID IS NULL OR variation.post_status = 'publish')";
        } else {
            $where[] = "(variation.ID IS NULL OR variation.post_type = 'product_variation')";
        }

        if ($params['product_id'] !== null) {
            $where[] = 'p.ID = %d';
            $values[] = $params['product_id'];
        }

        if ($params['variation_id'] !== null) {
            $where[] = 'variation.ID = %d';
            $values[] = $params['variation_id'];
        }

        if ($params['event_id'] !== null) {
            $where[] = 'ev.ID = %d';
            $values[] = $params['event_id'];
        }

        if ($params['updated_since'] !== null) {
            $where[] = '(p.post_modified_gmt > %s OR ev.post_modified_gmt > %s OR variation.post_modified_gmt > %s)';
            $values[] = $params['updated_since'];
            $values[] = $params['updated_since'];
            $values[] = $params['updated_since'];
        }

        $limit = (int) $params['per_page'] + 1;
        $offset = ((int) $params['page'] - 1) * (int) $params['per_page'];

        $sql = "
            SELECT
                p.ID AS woo_product_id,
                p.post_title AS product_title,
                p.post_name AS product_slug,
                p.post_status AS product_status,
                p.post_modified_gmt AS product_source_updated_at,
                ev.ID AS tickera_event_id,
                ev.post_title AS event_title,
                ev.post_name AS event_slug,
                ev.post_status AS event_status,
                ev.post_modified_gmt AS event_source_updated_at,
                variation.ID AS woo_variation_id,
                variation.post_title AS variation_title,
                variation.post_status AS variation_status,
                variation.post_modified_gmt AS variation_source_updated_at,
                MAX(event_meta.meta_value) AS event_reference_raw,
                MAX(CASE WHEN pm.meta_key = 'custom_produk_blad_toegang_naam' THEN pm.meta_value END) AS ticket_display_name,
                MAX(CASE WHEN pm.meta_key = '_price' THEN pm.meta_value END) AS price,
                MAX(CASE WHEN pm.meta_key = '_regular_price' THEN pm.meta_value END) AS regular_price,
                MAX(CASE WHEN pm.meta_key = '_ticket_template' THEN pm.meta_value END) AS ticket_template_id,
                MAX(CASE WHEN pm.meta_key = '_subscription_period' THEN pm.meta_value END) AS subscription_period,
                MAX(CASE WHEN pm.meta_key = '_subscription_length' THEN pm.meta_value END) AS subscription_length,
                MAX(CASE WHEN pm.meta_key = '_subscription_price' THEN pm.meta_value END) AS subscription_price,
                MAX(CASE WHEN pm.meta_key = '_subscription_sign_up_fee' THEN pm.meta_value END) AS subscription_sign_up_fee,
                MAX(CASE WHEN pm.meta_key = '_wc_subscription_period' THEN pm.meta_value END) AS wc_subscription_period,
                MAX(CASE WHEN pm.meta_key = '_wc_subscription_length' THEN pm.meta_value END) AS wc_subscription_length
            FROM {$posts} p
            " . implode("\n", $joins) . '
            WHERE ' . implode(' AND ', $where) . '
            GROUP BY
                p.ID,
                p.post_title,
                p.post_name,
                p.post_status,
                p.post_modified_gmt,
                ev.ID,
                ev.post_title,
                ev.post_name,
                ev.post_status,
                ev.post_modified_gmt,
                variation.ID,
                variation.post_title,
                variation.post_status,
                variation.post_modified_gmt
            ORDER BY ev.post_title ASC, p.post_title ASC, p.ID ASC, variation.ID ASC
            LIMIT %d OFFSET %d';

        $values[] = $limit;
        $values[] = $offset;

        $prepared = $wpdb->prepare($sql, $values);
        $rows = $wpdb->get_results($prepared, ARRAY_A);

        if (!is_array($rows)) {
            return ['rows' => [], 'observations' => []];
        }

        $normalized = [];
        $observations = [];

        foreach ($rows as $row) {
            if (!is_array($row)) {
                continue;
            }

            $normalized_row = $this->normalize_catalog_row($row);
            $normalized[] = $normalized_row;
            $observations[] = $this->native_observation($row, $normalized_row);
        }

        return ['rows' => $normalized, 'observations' => $observations];
    }

    /**
     * Typed producer observation for one catalog row. Separate from the
     * structural transport row so evidence never depends on legacy
     * diagnostic fields.
     *
     * @param array<string, mixed> $raw_row
     * @param array<string, mixed> $normalized_row
     * @return array<string, mixed>
     */
    private function native_observation(array $raw_row, array $normalized_row): array
    {
        return [
            'woo_product_id' => $normalized_row['woo_product_id'],
            'woo_variation_id' => $normalized_row['woo_variation_id'],
            'tickera_event_id' => $normalized_row['tickera_event_id'],
            'event_status' => $normalized_row['event_status'],
            'product_status' => $normalized_row['product_status'],
            'variation_status' => $normalized_row['variation_status'],
            'ticket_template_id' => $normalized_row['ticket_template_id'],
            'product_type' => $normalized_row['product_type'],
            'is_subscription' => $normalized_row['is_subscription'],
            'event_reference_raw' => $this->nullable_string($raw_row['event_reference_raw'] ?? null),
        ];
    }

    /**
     * @param array<string, mixed> $params
     * @return array<int, array<string, mixed>>
     */
    private function event_rows(array $params): array
    {
        global $wpdb;

        $posts = $wpdb->posts;
        $postmeta = $wpdb->postmeta;
        $targeted = $params['product_id'] !== null || $params['variation_id'] !== null || $params['event_id'] !== null || $params['include_private'];
        $where = ["ev.post_type = 'tc_events'"];
        $values = self::ALLOWED_EVENT_META_KEYS;

        if (!$targeted) {
            $where[] = "ev.post_status = 'publish'";
        }

        if ($params['event_id'] !== null) {
            $where[] = 'ev.ID = %d';
            $values[] = $params['event_id'];
        }

        if ($params['product_id'] !== null) {
            $where[] = 'p.ID = %d';
            $values[] = $params['product_id'];
        }

        if ($params['variation_id'] !== null) {
            $where[] = 'variation.ID = %d';
            $values[] = $params['variation_id'];
        }

        if ($params['updated_since'] !== null) {
            $where[] = '(ev.post_modified_gmt > %s OR p.post_modified_gmt > %s OR variation.post_modified_gmt > %s)';
            $values[] = $params['updated_since'];
            $values[] = $params['updated_since'];
            $values[] = $params['updated_since'];
        }

        $linked_product_count_condition = $targeted
            ? "is_ticket.meta_value = 'yes'"
            : "is_ticket.meta_value = 'yes' AND p.post_status = 'publish'";

        $sql = "
            SELECT
                ev.ID AS tickera_event_id,
                ev.post_title AS event_title,
                ev.post_name AS event_slug,
                ev.post_status AS event_status,
                ev.post_modified_gmt AS event_source_updated_at,
                MAX(CASE WHEN evm.meta_key = 'event_date_time' THEN evm.meta_value END) AS event_start_at,
                MAX(CASE WHEN evm.meta_key = 'event_end_date_time' THEN evm.meta_value END) AS event_end_at,
                MAX(CASE WHEN evm.meta_key = 'event_location' THEN evm.meta_value END) AS event_location,
                MAX(CASE WHEN evm.meta_key = 'booking_fee_type' THEN evm.meta_value END) AS booking_fee_type,
                MAX(CASE WHEN evm.meta_key = 'booking_fee_value' THEN evm.meta_value END) AS booking_fee_value,
                COUNT(DISTINCT CASE WHEN {$linked_product_count_condition} THEN p.ID END) AS linked_ticket_products
            FROM {$posts} ev
            LEFT JOIN {$postmeta} evm
                ON evm.post_id = ev.ID
                AND evm.meta_key IN (" . $this->sql_placeholders(count(self::ALLOWED_EVENT_META_KEYS)) . ")
            LEFT JOIN {$postmeta} event_meta
                ON event_meta.meta_key = '_event_name'
                AND CAST(event_meta.meta_value AS UNSIGNED) = ev.ID
            LEFT JOIN {$posts} p
                ON p.ID = event_meta.post_id
                AND p.post_type = 'product'
            LEFT JOIN {$postmeta} is_ticket
                ON is_ticket.post_id = p.ID
                AND is_ticket.meta_key = '_tc_is_ticket'
            LEFT JOIN {$posts} variation
                ON variation.post_parent = p.ID
                AND variation.post_type = 'product_variation'
            WHERE " . implode(' AND ', $where) . '
            GROUP BY
                ev.ID,
                ev.post_title,
                ev.post_name,
                ev.post_status,
                ev.post_modified_gmt
            ORDER BY ev.post_title ASC';

        $prepared = empty($values) ? $sql : $wpdb->prepare($sql, $values);
        $rows = $wpdb->get_results($prepared, ARRAY_A);

        if (!is_array($rows)) {
            return [];
        }

        return array_map(function (array $row): array {
            $event_status = $this->status_classification($row['event_status'] ?? null);

            return [
                'tickera_event_id' => $this->nullable_int($row['tickera_event_id'] ?? null),
                'event_title' => $this->nullable_string($row['event_title'] ?? null),
                'event_slug' => $this->nullable_string($row['event_slug'] ?? null),
                'event_status' => $this->nullable_string($row['event_status'] ?? null),
                'event_status_classification' => $event_status,
                'target_observation' => $this->target_observation($event_status),
                'risk_codes' => $this->event_risk_codes($event_status),
                'event_source_updated_at' => $this->sql_datetime_to_iso8601($row['event_source_updated_at'] ?? null),
                'event_start_at' => $this->event_datetime_to_iso8601($row['event_start_at'] ?? null),
                'event_end_at' => $this->event_datetime_to_iso8601($row['event_end_at'] ?? null),
                'event_location' => $this->nullable_string($row['event_location'] ?? null),
                'booking_fee_type' => $this->normalized_booking_fee_type($row['booking_fee_type'] ?? null),
                'booking_fee_value' => $this->nullable_string($row['booking_fee_value'] ?? null),
                'linked_ticket_products' => $this->nullable_int($row['linked_ticket_products'] ?? 0) ?? 0,
            ];
        }, $rows);
    }

    /**
     * @param array<string, mixed> $row
     * @return array<string, mixed>
     */
    private function normalize_catalog_row(array $row): array
    {
        $product_id = $this->nullable_int($row['woo_product_id'] ?? null);
        $variation_id = $this->nullable_int($row['woo_variation_id'] ?? null);
        $product_type = $this->product_type($product_id);
        $subscription_period = $this->first_non_empty([
            $row['subscription_period'] ?? null,
            $row['wc_subscription_period'] ?? null,
        ]);
        $subscription_length = $this->first_non_empty([
            $row['subscription_length'] ?? null,
            $row['wc_subscription_length'] ?? null,
        ]);
        $is_subscription = $this->is_subscription_product($product_type, $row, $subscription_period, $subscription_length);
        $review_reasons = $this->review_reasons($row, $variation_id, $is_subscription);
        $product_status = $this->status_classification($row['product_status'] ?? null);
        $variation_status = $this->status_classification($row['variation_status'] ?? null);
        $target_observation = $this->target_observation($product_status);
        $unknown_semantics = [
            'payment_plan' => 'unknown',
            'membership' => 'unknown',
            'bundle' => 'unknown',
            'add_on' => 'unknown',
        ];
        $review_reasons[] = 'unknown_product_semantics';
        $review_reasons = array_values(array_unique($review_reasons));

        return [
            'tickera_event_id' => $this->nullable_int($row['tickera_event_id'] ?? null),
            'event_title' => $this->nullable_string($row['event_title'] ?? null),
            'event_slug' => $this->nullable_string($row['event_slug'] ?? null),
            'event_status' => $this->nullable_string($row['event_status'] ?? null),
            'event_source_updated_at' => $this->sql_datetime_to_iso8601($row['event_source_updated_at'] ?? null),
            'woo_product_id' => $product_id,
            'product_title' => $this->nullable_string($row['product_title'] ?? null),
            'product_slug' => $this->nullable_string($row['product_slug'] ?? null),
            'product_status' => $this->nullable_string($row['product_status'] ?? null),
            'product_status_classification' => $product_status,
            'product_source_updated_at' => $this->sql_datetime_to_iso8601($row['product_source_updated_at'] ?? null),
            'ticket_display_name' => $this->nullable_string($row['ticket_display_name'] ?? null),
            'price' => $this->nullable_string($row['price'] ?? null),
            'regular_price' => $this->nullable_string($row['regular_price'] ?? null),
            'ticket_template_id' => $this->nullable_string($row['ticket_template_id'] ?? null),
            'woo_variation_id' => $variation_id,
            'variation_title' => $this->nullable_string($row['variation_title'] ?? null),
            'variation_status' => $this->nullable_string($row['variation_status'] ?? null),
            'variation_status_classification' => $variation_id === null ? null : $variation_status,
            'variation_source_updated_at' => $this->sql_datetime_to_iso8601($row['variation_source_updated_at'] ?? null),
            'product_type' => $product_type,
            'ticket_template_present' => $this->nullable_string($row['ticket_template_id'] ?? null) !== null,
            'subscription_classification' => $is_subscription ? 'subscription' : 'not_subscription',
            'product_semantics' => $unknown_semantics,
            'target_observation' => $target_observation,
            'risk_codes' => $review_reasons,
            'is_subscription' => $is_subscription,
            'subscription_period' => $this->nullable_string($subscription_period),
            'subscription_length' => $this->nullable_string($subscription_length),
            'requires_review' => !empty($review_reasons),
            'review_reasons' => $review_reasons,
        ];
    }

    private function product_type(?int $product_id): ?string
    {
        if ($product_id === null) {
            return null;
        }

        if (function_exists('wc_get_product')) {
            $product = wc_get_product($product_id);
            if (is_object($product) && method_exists($product, 'get_type')) {
                $type = $product->get_type();
                if (is_string($type) && $type !== '') {
                    return $type;
                }
            }
        }

        $terms = get_the_terms($product_id, 'product_type');
        if (is_array($terms) && isset($terms[0]) && isset($terms[0]->slug)) {
            return (string) $terms[0]->slug;
        }

        return null;
    }

    /**
     * @param array<string, mixed> $row
     */
    private function is_subscription_product(?string $product_type, array $row, ?string $subscription_period, ?string $subscription_length): bool
    {
        if ($product_type !== null && strpos($product_type, 'subscription') !== false) {
            return true;
        }

        return $subscription_period !== null
            || $subscription_length !== null
            || $this->nullable_string($row['subscription_price'] ?? null) !== null
            || $this->nullable_string($row['subscription_sign_up_fee'] ?? null) !== null;
    }

    /**
     * @param array<string, mixed> $row
     * @return array<int, string>
     */
    private function review_reasons(array $row, ?int $variation_id, bool $is_subscription): array
    {
        $reasons = [];
        $product_status = $this->nullable_string($row['product_status'] ?? null);
        $event_status = $this->nullable_string($row['event_status'] ?? null);
        $ticket_template_id = $this->nullable_string($row['ticket_template_id'] ?? null);

        if ($product_status === 'private') {
            $reasons[] = 'private_product';
        } elseif ($product_status !== null && $product_status !== 'publish') {
            $reasons[] = 'draft_product';
        }

        if ($event_status === null) {
            $reasons[] = 'missing_tickera_event';
        } elseif ($event_status === 'private') {
            $reasons[] = 'private_event';
        } elseif ($event_status !== 'publish') {
            $reasons[] = 'draft_event';
        }

        if ($is_subscription) {
            $reasons[] = 'subscription_product';
            $reasons[] = 'payment_plan_product';
        }

        if ($variation_id !== null) {
            $reasons[] = 'variation_mapping_required';
        }

        if ($ticket_template_id === null) {
            $reasons[] = 'missing_ticket_template';
        }

        return array_values(array_unique($reasons));
    }

    private function status_classification($value): string
    {
        $status = $this->nullable_string($value);

        if (in_array($status, ['publish', 'private', 'draft', 'trash'], true)) {
            return $status;
        }

        return 'unknown';
    }

    private function target_observation(string $status): string
    {
        if ($status === 'trash') {
            return 'trashed';
        }

        if ($status === 'unknown') {
            return 'unknown';
        }

        return 'present';
    }

    /**
     * @return array<int, string>
     */
    private function event_risk_codes(string $status): array
    {
        if ($status === 'publish') {
            return [];
        }

        return [$status === 'unknown' ? 'missing_source_risk_data' : $status . '_event'];
    }

    /**
     * Builds the deduplicated, bounded native evidence list for one page.
     *
     * Parent-level observations repeat across variation rows of the same
     * product, so identity `(dimension, producer_scope, target)` is emitted
     * once per page. Exceeding the page bound fails closed: evidence is never
     * truncated.
     *
     * @param array<int, array<string, mixed>> $observations
     * @return array<int, array<string, mixed>>
     */
    public static function build_native_evidence(array $observations, string $discovery_snapshot_id): array
    {
        $evidence = [];
        $seen = [];

        foreach ($observations as $observation) {
            if (!is_array($observation)) {
                continue;
            }

            foreach (self::build_native_evidence_for_row($observation, $discovery_snapshot_id) as $item) {
                $identity = $item['dimension'] . '|' . $item['producer_scope'] . '|' . self::canonical_json($item['target']);

                if (isset($seen[$identity])) {
                    continue;
                }

                $seen[$identity] = true;
                $evidence[] = $item;
            }
        }

        if (count($evidence) > self::MAX_EVIDENCE_PER_PAGE) {
            throw new RuntimeException('evidence_page_limit_exceeded');
        }

        return $evidence;
    }

    /**
     * @param array<string, mixed> $observation
     * @return array<int, array<string, mixed>>
     */
    public static function build_native_evidence_for_row(array $observation, string $discovery_snapshot_id): array
    {
        $product_id = self::positive_int_or_null($observation['woo_product_id'] ?? null);

        if ($product_id === null) {
            return [];
        }

        $variation_id = self::positive_int_or_null($observation['woo_variation_id'] ?? null);
        $event_id = self::positive_int_or_null($observation['tickera_event_id'] ?? null);
        $items = [];

        if ($event_id !== null) {
            $items[] = self::lifecycle_evidence(
                'event',
                ['tickera_event_id' => $event_id],
                $observation['event_status'] ?? null,
                ['tickera_event_id' => $event_id],
                $discovery_snapshot_id
            );
        }

        $items[] = self::lifecycle_evidence(
            'parent_product',
            ['woo_product_id' => $product_id],
            $observation['product_status'] ?? null,
            ['woo_product_id' => $product_id],
            $discovery_snapshot_id
        );

        // A variation lifecycle is always its own observation of the variation
        // post status. Parent status is never copied onto a variation.
        if ($variation_id !== null) {
            $items[] = self::lifecycle_evidence(
                'variation',
                ['woo_variation_id' => $variation_id, 'woo_product_id' => $product_id],
                $observation['variation_status'] ?? null,
                ['woo_product_id' => $product_id, 'woo_variation_id' => $variation_id],
                $discovery_snapshot_id
            );
        }

        $items[] = self::ticket_template_evidence($product_id, $observation['ticket_template_id'] ?? null, $discovery_snapshot_id);
        $items[] = self::event_link_evidence($product_id, $event_id, $observation['event_reference_raw'] ?? null, $discovery_snapshot_id);
        $items[] = self::subscription_evidence($product_id, !empty($observation['is_subscription']), $discovery_snapshot_id);
        $items[] = self::product_type_evidence($product_id, $observation['product_type'] ?? null, $discovery_snapshot_id);

        foreach (self::CAPABILITY_DIMENSIONS as $dimension) {
            $items[] = self::capability_evidence($dimension, $product_id, $discovery_snapshot_id);
        }

        return $items;
    }

    /**
     * @param array<string, int> $target
     * @param array<string, int> $identity
     * @return array<string, mixed>
     */
    private static function lifecycle_evidence(string $scope, array $target, $status, array $identity, string $discovery_snapshot_id): array
    {
        $source_key = self::PRODUCER_SOURCE_KEYS['lifecycle'];
        $clean = self::nullable_trimmed($status);

        if ($clean === null) {
            return self::evidence_item('lifecycle', $scope, $target, 'missing', null, $source_key, 'partial', $identity, null, $discovery_snapshot_id);
        }

        if (in_array($clean, self::LIFECYCLE_VALUES, true)) {
            return self::evidence_item('lifecycle', $scope, $target, 'present', $clean, $source_key, 'exhaustive', $identity, null, $discovery_snapshot_id);
        }

        // An undeclared WordPress status fails closed instead of being mapped.
        return self::evidence_item('lifecycle', $scope, $target, 'invalid', null, $source_key, 'exhaustive', $identity, $clean, $discovery_snapshot_id);
    }

    /**
     * @return array<string, mixed>
     */
    private static function ticket_template_evidence(int $product_id, $template_id, string $discovery_snapshot_id): array
    {
        $source_key = self::PRODUCER_SOURCE_KEYS['ticket_template'];
        $target = ['woo_product_id' => $product_id];
        $identity = ['woo_product_id' => $product_id];
        $template = self::nullable_trimmed($template_id);

        if ($template === null) {
            return self::evidence_item('ticket_template', 'parent_product', $target, 'absent', null, $source_key, 'exhaustive', $identity, null, $discovery_snapshot_id);
        }

        if (strlen($template) > self::MAX_EVIDENCE_VALUE_BYTES) {
            return self::evidence_item('ticket_template', 'parent_product', $target, 'invalid', null, $source_key, 'exhaustive', $identity, $template, $discovery_snapshot_id);
        }

        return self::evidence_item('ticket_template', 'parent_product', $target, 'present', $template, $source_key, 'exhaustive', $identity, null, $discovery_snapshot_id);
    }

    /**
     * @return array<string, mixed>
     */
    private static function event_link_evidence(int $product_id, ?int $event_id, $event_reference_raw, string $discovery_snapshot_id): array
    {
        $source_key = self::PRODUCER_SOURCE_KEYS['event_link'];
        $target = ['woo_product_id' => $product_id];

        if ($event_id !== null) {
            return self::evidence_item(
                'event_link',
                'event_product_relationship',
                $target,
                'present',
                $event_id,
                $source_key,
                'exhaustive',
                ['woo_product_id' => $product_id, 'tickera_event_id' => $event_id],
                null,
                $discovery_snapshot_id
            );
        }

        $reference = self::nullable_trimmed($event_reference_raw);
        $identity = ['woo_product_id' => $product_id];

        if ($reference !== null) {
            // A reference exists but does not resolve to a tc_events post.
            return self::evidence_item('event_link', 'event_product_relationship', $target, 'invalid', null, $source_key, 'exhaustive', $identity, $reference, $discovery_snapshot_id);
        }

        // Absent is only claimed after an exhaustive no-reference observation.
        return self::evidence_item('event_link', 'event_product_relationship', $target, 'absent', null, $source_key, 'exhaustive', $identity, null, $discovery_snapshot_id);
    }

    /**
     * @return array<string, mixed>
     */
    private static function subscription_evidence(int $product_id, bool $is_subscription, string $discovery_snapshot_id): array
    {
        $source_key = self::PRODUCER_SOURCE_KEYS['subscription'];
        $target = ['woo_product_id' => $product_id];
        $identity = ['woo_product_id' => $product_id];

        if ($is_subscription) {
            return self::evidence_item('subscription', 'parent_product', $target, 'present', null, $source_key, 'partial', $identity, null, $discovery_snapshot_id);
        }

        // No safe negative subscription proof exists in this producer.
        return self::evidence_item('subscription', 'parent_product', $target, 'unknown', null, $source_key, 'unknown', $identity, null, $discovery_snapshot_id);
    }

    /**
     * @return array<string, mixed>
     */
    private static function product_type_evidence(int $product_id, $product_type, string $discovery_snapshot_id): array
    {
        $source_key = self::PRODUCER_SOURCE_KEYS['product_type'];
        $target = ['woo_product_id' => $product_id];
        $identity = ['woo_product_id' => $product_id];
        $type = self::nullable_trimmed($product_type);

        if ($type === null) {
            return self::evidence_item('product_type', 'parent_product', $target, 'unknown', null, $source_key, 'unknown', $identity, null, $discovery_snapshot_id);
        }

        if (in_array($type, self::SUPPORTED_PRODUCT_TYPES, true)) {
            return self::evidence_item('product_type', 'parent_product', $target, 'present', $type, $source_key, 'exhaustive', $identity, null, $discovery_snapshot_id);
        }

        // Undeclared WooCommerce types fail closed with the raw code only.
        return self::evidence_item('product_type', 'parent_product', $target, 'unsupported', null, $source_key, 'exhaustive', $identity, $type, $discovery_snapshot_id);
    }

    /**
     * @return array<string, mixed>
     */
    private static function capability_evidence(string $dimension, int $product_id, string $discovery_snapshot_id): array
    {
        return self::evidence_item(
            $dimension,
            'parent_product',
            ['woo_product_id' => $product_id],
            'unsupported',
            null,
            self::PRODUCER_SOURCE_KEYS['capability'],
            'unknown',
            ['woo_product_id' => $product_id],
            null,
            $discovery_snapshot_id
        );
    }

    /**
     * @param array<string, int> $target
     * @param array<string, int> $identity
     * @return array<string, mixed>
     */
    private static function evidence_item(
        string $dimension,
        string $scope,
        array $target,
        string $state,
        $value,
        string $producer_source_key,
        string $completeness,
        array $identity,
        ?string $raw_producer_code,
        string $discovery_snapshot_id
    ): array {
        $provenance = [
            'discovery_snapshot_id' => $discovery_snapshot_id,
            'producer_version' => EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION,
            'producer_source_key' => $producer_source_key,
        ];

        foreach (['woo_product_id', 'woo_variation_id', 'tickera_event_id'] as $key) {
            $id = self::positive_int_or_null($identity[$key] ?? null);
            if ($id !== null) {
                $provenance[$key] = $id;
            }
        }

        if ($raw_producer_code !== null && strlen($raw_producer_code) <= self::MAX_RAW_PRODUCER_CODE_BYTES) {
            $provenance['raw_producer_code'] = $raw_producer_code;
        }

        $item = [
            'dimension' => $dimension,
            'producer_scope' => $scope,
            'target' => $target,
            'state' => $state,
            'producer_source_key' => $producer_source_key,
            'completeness' => $completeness,
            'provenance' => array_intersect_key($provenance, array_flip(self::PROVENANCE_KEYS)),
        ];

        if ($value !== null) {
            $item['value'] = $value;
        }

        return $item;
    }

    private static function positive_int_or_null($value): ?int
    {
        if ($value === null || $value === '' || is_bool($value) || is_array($value) || is_object($value)) {
            return null;
        }

        if (is_int($value)) {
            return $value > 0 ? $value : null;
        }

        $clean = trim((string) $value);

        return preg_match('/^[1-9][0-9]*$/', $clean) ? (int) $clean : null;
    }

    private static function nullable_trimmed($value): ?string
    {
        if ($value === null || is_array($value) || is_object($value) || is_bool($value)) {
            return null;
        }

        $clean = trim((string) $value);

        return $clean === '' ? null : $clean;
    }

    private function error_response(string $error, int $status, ?string $message = null): WP_REST_Response
    {
        $body = ['error' => $error];

        if ($message !== null && $message !== '') {
            $body['message'] = $message;
        }

        return new WP_REST_Response($body, $status);
    }

    private function sql_placeholders(int $count): string
    {
        return implode(',', array_fill(0, $count, '%s'));
    }

    private static function utc_now(): string
    {
        return gmdate('Y-m-d\TH:i:s\Z');
    }

    private function sql_datetime_to_iso8601($value): ?string
    {
        $clean = $this->nullable_string($value);
        if ($clean === null) {
            return null;
        }

        try {
            $datetime = new DateTimeImmutable($clean, new DateTimeZone('UTC'));
        } catch (Exception $error) {
            return null;
        }

        return $datetime->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d\TH:i:s\Z');
    }

    private function event_datetime_to_iso8601($value): ?string
    {
        $clean = $this->nullable_string($value);
        if ($clean === null) {
            return null;
        }

        $timezone = function_exists('wp_timezone') ? wp_timezone() : new DateTimeZone('UTC');

        try {
            $datetime = new DateTimeImmutable($clean, $timezone);
        } catch (Exception $error) {
            return null;
        }

        return $datetime->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d\TH:i:s\Z');
    }

    private function normalized_booking_fee_type($value): ?string
    {
        $clean = $this->nullable_string($value);
        if ($clean === null) {
            return null;
        }

        $normalized = strtolower($clean);

        if (in_array($normalized, ['fixed', 'percentage'], true)) {
            return $normalized;
        }

        return null;
    }

    private function nullable_int($value): ?int
    {
        if ($value === null || $value === '') {
            return null;
        }

        return (int) $value;
    }

    private function nullable_string($value): ?string
    {
        if ($value === null) {
            return null;
        }

        $clean = trim((string) $value);

        return $clean === '' ? null : $clean;
    }

    /**
     * @param array<int, mixed> $values
     */
    private function first_non_empty(array $values): ?string
    {
        foreach ($values as $value) {
            $clean = $this->nullable_string($value);
            if ($clean !== null) {
                return $clean;
            }
        }

        return null;
    }
}

add_action('rest_api_init', ['EventSales_Tickera_Catalog_Feed', 'register']);
add_action('save_post_product', ['EventSales_Tickera_Catalog_Feed', 'invalidate_cache']);
add_action('save_post_product_variation', ['EventSales_Tickera_Catalog_Feed', 'invalidate_cache']);
add_action('save_post_tc_events', ['EventSales_Tickera_Catalog_Feed', 'invalidate_cache']);
add_action('save_post_product', ['EventSales_Tickera_Catalog_Feed', 'record_catalog_change']);
add_action('save_post_product_variation', ['EventSales_Tickera_Catalog_Feed', 'record_catalog_change']);
add_action('save_post_tc_events', ['EventSales_Tickera_Catalog_Feed', 'record_catalog_change']);
add_action('transition_post_status', ['EventSales_Tickera_Catalog_Feed', 'record_status_change'], 10, 3);
add_action('added_post_meta', ['EventSales_Tickera_Catalog_Feed', 'record_meta_change'], 10, 3);
add_action('updated_post_meta', ['EventSales_Tickera_Catalog_Feed', 'record_meta_change'], 10, 3);
add_action('deleted_post_meta', ['EventSales_Tickera_Catalog_Feed', 'record_meta_change'], 10, 3);
add_action('trashed_post', ['EventSales_Tickera_Catalog_Feed', 'record_trashed']);
add_action('untrashed_post', ['EventSales_Tickera_Catalog_Feed', 'record_restored']);
add_action('before_delete_post', ['EventSales_Tickera_Catalog_Feed', 'record_deleted']);
add_action('shutdown', ['EventSales_Tickera_Catalog_Feed', 'flush_catalog_changes']);
add_action('eventsales_catalog_change_deliver', ['EventSales_Tickera_Catalog_Feed', 'deliver_catalog_change'], 10, 2);
