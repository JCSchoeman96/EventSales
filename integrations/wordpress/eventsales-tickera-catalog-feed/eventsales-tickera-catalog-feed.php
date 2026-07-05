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
    define('EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION', '2026-07-05.v1');
}

if (!defined('EVENTSALES_TICKERA_CATALOG_NAMESPACE')) {
    define('EVENTSALES_TICKERA_CATALOG_NAMESPACE', 'eventsales/v1');
}

if (!defined('EVENTSALES_TICKERA_CATALOG_ROUTE')) {
    define('EVENTSALES_TICKERA_CATALOG_ROUTE', '/tickera-catalog');
}

final class EventSales_Tickera_Catalog_Feed
{
    private const SOURCE = 'wordpress_tickera';
    private const CACHE_VERSION_OPTION = 'eventsales_tickera_catalog_feed_cache_version';
    private const SECRET_OPTION = 'eventsales_tickera_catalog_secret';
    private const CACHE_TTL_OPTION = 'eventsales_tickera_catalog_cache_ttl';
    private const MAX_TIMESTAMP_SKEW_SECONDS = 300;
    private const DEFAULT_PER_PAGE = 100;
    private const MAX_PER_PAGE = 500;
    private const DEFAULT_CACHE_TTL_SECONDS = 120;
    private const MIN_CACHE_TTL_SECONDS = 30;
    private const MAX_CACHE_TTL_SECONDS = 300;

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

    public static function invalidate_cache(): void
    {
        $current = (int) get_option(self::CACHE_VERSION_OPTION, 1);
        update_option(self::CACHE_VERSION_OPTION, $current + 1, false);
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

        $per_page = $this->positive_integer($params['per_page'], 'per_page', self::DEFAULT_PER_PAGE);
        if (is_wp_error($per_page)) {
            return $per_page;
        }
        if ($per_page > self::MAX_PER_PAGE) {
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
        $version = (int) get_option(self::CACHE_VERSION_OPTION, 1);
        $payload = wp_json_encode([
            'schema_version' => EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION,
            'params' => $params,
        ]);

        return 'eventsales_tickera_catalog_' . $version . '_' . hash('sha256', (string) $payload);
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
        $generated_at = $this->utc_now();
        $catalog_rows = $this->catalog_rows($params);
        $events = $this->event_rows($params);

        return [
            'schema_version' => EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION,
            'source' => self::SOURCE,
            'source_snapshot_at' => $generated_at,
            'generated_at' => $generated_at,
            'page' => $params['page'],
            'per_page' => $params['per_page'],
            'has_more' => count($catalog_rows) > $params['per_page'],
            'filters' => [
                'updated_since' => $this->sql_datetime_to_iso8601($params['updated_since']),
                'product_id' => $params['product_id'],
                'variation_id' => $params['variation_id'],
                'event_id' => $params['event_id'],
                'include_private' => $params['include_private'],
            ],
            'events' => $events,
            'catalog_rows' => array_slice($catalog_rows, 0, $params['per_page']),
        ];
    }

    /**
     * @param array<string, mixed> $params
     * @return array<int, array<string, mixed>>
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
            return [];
        }

        return array_map(function (array $row): array {
            return $this->normalize_catalog_row($row);
        }, $rows);
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
        $values = [];

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
                COUNT(DISTINCT CASE WHEN {$linked_product_count_condition} THEN p.ID END) AS linked_ticket_products
            FROM {$posts} ev
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
            return [
                'tickera_event_id' => $this->nullable_int($row['tickera_event_id'] ?? null),
                'event_title' => $this->nullable_string($row['event_title'] ?? null),
                'event_slug' => $this->nullable_string($row['event_slug'] ?? null),
                'event_status' => $this->nullable_string($row['event_status'] ?? null),
                'event_source_updated_at' => $this->sql_datetime_to_iso8601($row['event_source_updated_at'] ?? null),
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
            'product_source_updated_at' => $this->sql_datetime_to_iso8601($row['product_source_updated_at'] ?? null),
            'ticket_display_name' => $this->nullable_string($row['ticket_display_name'] ?? null),
            'price' => $this->nullable_string($row['price'] ?? null),
            'regular_price' => $this->nullable_string($row['regular_price'] ?? null),
            'ticket_template_id' => $this->nullable_string($row['ticket_template_id'] ?? null),
            'woo_variation_id' => $variation_id,
            'variation_title' => $this->nullable_string($row['variation_title'] ?? null),
            'variation_status' => $this->nullable_string($row['variation_status'] ?? null),
            'variation_source_updated_at' => $this->sql_datetime_to_iso8601($row['variation_source_updated_at'] ?? null),
            'product_type' => $product_type,
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

    private function utc_now(): string
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
