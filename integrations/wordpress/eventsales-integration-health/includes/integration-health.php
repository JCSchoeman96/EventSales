<?php

declare(strict_types=1);

/**
 * Read-only EventSales WordPress integration health observers.
 *
 * No writes, no network I/O, no order or catalogue authority.
 */

if (!defined('ABSPATH')) {
    exit;
}

final class EventSales_Integration_Health_States
{
    public const ABSENT = 'ABSENT';
    public const INACTIVE = 'INACTIVE';
    public const DISABLED = 'DISABLED';
    public const MISCONFIGURED = 'MISCONFIGURED';
    public const DEPENDENCY_UNAVAILABLE = 'DEPENDENCY_UNAVAILABLE';
    public const READY = 'READY';

    /** @return array<int, string> */
    public static function all(): array
    {
        return [
            self::ABSENT,
            self::INACTIVE,
            self::DISABLED,
            self::MISCONFIGURED,
            self::DEPENDENCY_UNAVAILABLE,
            self::READY,
        ];
    }
}

final class EventSales_Integration_Health_Plugins
{
    public const CATALOG_BASENAME = 'eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php';
    public const ORDER_INDEX_BASENAME = 'eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php';
    public const ORDER_LINE_BASENAME = 'eventsales-woo-order-line-identity/eventsales-woo-order-line-identity.php';

    public static function installed(string $basename): bool
    {
        if (!function_exists('get_plugins')) {
            $path = self::plugin_path($basename);

            return $path !== '' && is_readable($path);
        }

        $plugins = get_plugins();

        return isset($plugins[$basename]) && is_readable(self::plugin_path($basename));
    }

    public static function active(string $basename): bool
    {
        if (!function_exists('is_plugin_active')) {
            $active = $GLOBALS['active_plugins'] ?? [];

            return is_array($active) && in_array($basename, $active, true);
        }

        return is_plugin_active($basename);
    }

    public static function marketing_version(string $basename): ?string
    {
        if (!function_exists('get_plugins')) {
            return null;
        }

        $plugins = get_plugins();
        if (!isset($plugins[$basename]['Version'])) {
            return null;
        }

        $version = trim((string) $plugins[$basename]['Version']);

        return $version === '' ? null : $version;
    }

    private static function plugin_path(string $basename): string
    {
        if (!defined('WP_PLUGIN_DIR')) {
            return '';
        }

        $path = WP_PLUGIN_DIR . '/' . $basename;

        return is_string($path) ? $path : '';
    }

    public static function catalog_producer_active(): bool
    {
        $basename = self::CATALOG_BASENAME;

        return self::installed($basename)
            && self::active($basename)
            && class_exists('EventSales_Tickera_Catalog_Feed');
    }

    public static function non_empty_defined_constant(string $constant_name): bool
    {
        if (!defined($constant_name)) {
            return false;
        }

        $value = constant($constant_name);

        return is_scalar($value) && trim((string) $value) !== '';
    }
}

final class EventSales_Integration_Health_Dependencies
{
    /**
     * @return array{
     *   wordpress_version: ?string,
     *   php_version: string,
     *   woocommerce_available: bool,
     *   woocommerce_version: ?string,
     *   tickera_event_capability_available: bool,
     *   action_scheduler_enqueue_available: bool,
     *   action_scheduler_schedule_available: bool
     * }
     */
    public static function snapshot(): array
    {
        global $wp_version;

        $woo_version = null;
        if (defined('WC_VERSION')) {
            $woo_version = trim((string) WC_VERSION);
        }

        return [
            'wordpress_version' => isset($wp_version) ? (string) $wp_version : null,
            'php_version' => PHP_VERSION,
            'woocommerce_available' => class_exists('WooCommerce') || defined('WC_VERSION'),
            'woocommerce_version' => $woo_version !== '' ? $woo_version : null,
            'tickera_event_capability_available' => post_type_exists('tc_events'),
            'action_scheduler_enqueue_available' => function_exists('as_enqueue_async_action'),
            'action_scheduler_schedule_available' => function_exists('as_schedule_single_action'),
        ];
    }
}

final class EventSales_Integration_Health_Catalog
{
    /**
     * @return array<string, mixed>
     */
    public static function evaluate(): array
    {
        $basename = EventSales_Integration_Health_Plugins::CATALOG_BASENAME;
        $installed = EventSales_Integration_Health_Plugins::installed($basename);
        $active = $installed && EventSales_Integration_Health_Plugins::active($basename);
        $class_loaded = class_exists('EventSales_Tickera_Catalog_Feed');

        if (!$installed) {
            return self::report($basename, false, false, EventSales_Integration_Health_States::ABSENT);
        }

        if (!$active || !$class_loaded) {
            return self::report($basename, true, false, EventSales_Integration_Health_States::INACTIVE);
        }

        $auth = self::authentication_configured();

        if (!$auth) {
            return self::report($basename, true, true, EventSales_Integration_Health_States::MISCONFIGURED, $auth);
        }

        if (!self::contract_identity_available()) {
            return self::report(
                $basename,
                true,
                true,
                EventSales_Integration_Health_States::DEPENDENCY_UNAVAILABLE,
                $auth
            );
        }

        return self::report($basename, true, true, EventSales_Integration_Health_States::READY, $auth);
    }

    public static function contract_identity_available(): bool
    {
        return EventSales_Integration_Health_Plugins::non_empty_defined_constant('EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION')
            && EventSales_Integration_Health_Plugins::non_empty_defined_constant('EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION')
            && EventSales_Integration_Health_Plugins::non_empty_defined_constant('EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION');
    }

    public static function authentication_configured(): bool
    {
        if (defined('EVENTSALES_TICKERA_CATALOG_SECRET')) {
            $constant = trim((string) constant('EVENTSALES_TICKERA_CATALOG_SECRET'));
            if ($constant !== '') {
                return true;
            }
        }

        if (!function_exists('get_option')) {
            return false;
        }

        return trim((string) get_option('eventsales_tickera_catalog_secret', '')) !== '';
    }

    /**
     * @return array<string, mixed>
     */
    private static function report(
        string $basename,
        bool $installed,
        bool $active,
        string $status,
        ?bool $auth = null
    ): array {
        $auth ??= self::authentication_configured();

        return [
            'installed' => $installed,
            'active' => $active,
            'status' => $status,
            'plugin_version' => EventSales_Integration_Health_Plugins::marketing_version($basename),
            'schema_version' => defined('EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION')
                ? (string) EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION
                : null,
            'canonical_contract_version' => defined('EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION')
                ? (string) EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION
                : null,
            'producer_version' => defined('EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION')
                ? (string) EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION
                : null,
            'authentication_configured' => $auth,
        ];
    }
}

final class EventSales_Integration_Health_Catalog_Change_Sender
{
    /**
     * @return array<string, mixed>
     */
    public static function evaluate(): array
    {
        $basename = EventSales_Integration_Health_Plugins::CATALOG_BASENAME;
        $installed = EventSales_Integration_Health_Plugins::installed($basename);
        $producer_active = EventSales_Integration_Health_Plugins::catalog_producer_active();

        if (!$installed) {
            return self::with_delivery_telemetry(
                self::report(false, false, false, false, false, false, false, EventSales_Integration_Health_States::ABSENT)
            );
        }

        if (!$producer_active) {
            return self::with_delivery_telemetry(
                self::report(true, false, false, false, false, false, false, EventSales_Integration_Health_States::INACTIVE)
            );
        }

        $enabled = defined('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED')
            && EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED;

        if (!$enabled) {
            return self::with_delivery_telemetry(self::report(
                true,
                true,
                false,
                false,
                false,
                false,
                self::scheduler_available(),
                EventSales_Integration_Health_States::DISABLED
            ));
        }

        $endpoint = self::non_empty_constant('EVENTSALES_CATALOG_CHANGE_ENDPOINT');
        $key_id = self::non_empty_constant('EVENTSALES_CATALOG_CHANGE_KEY_ID');
        $secret = self::non_empty_constant('EVENTSALES_CATALOG_CHANGE_SECRET');
        $scheduler = self::scheduler_available();

        $status = EventSales_Integration_Health_States::READY;
        if (!$endpoint || !$key_id || !$secret) {
            $status = EventSales_Integration_Health_States::MISCONFIGURED;
        } elseif (!$scheduler) {
            $status = EventSales_Integration_Health_States::DEPENDENCY_UNAVAILABLE;
        }

        return self::with_delivery_telemetry(self::report(true, true, true, $endpoint, $key_id, $secret, $scheduler, $status));
    }

    /**
     * @return array<string, mixed>
     */
    private static function report(
        bool $catalog_installed,
        bool $catalog_active,
        bool $enabled,
        bool $endpoint_configured,
        bool $key_id_configured,
        bool $secret_configured,
        bool $scheduler_available,
        string $status
    ): array {
        return [
            'catalog_installed' => $catalog_installed,
            'catalog_active' => $catalog_active,
            'enabled' => $enabled,
            'endpoint_configured' => $endpoint_configured,
            'key_id_configured' => $key_id_configured,
            'secret_configured' => $secret_configured,
            'scheduler_available' => $scheduler_available,
            'status' => $status,
        ];
    }

    /**
     * Add sanitized producer telemetry without changing readiness.
     *
     * @param array<string, mixed> $report
     * @return array<string, mixed>
     */
    private static function with_delivery_telemetry(array $report): array
    {
        $telemetry_fields = [
            'delivery_telemetry_supported' => false,
            'delivery_telemetry_version' => null,
            'delivery_state' => null,
            'last_attempt_at_gmt' => null,
            'last_success_at_gmt' => null,
            'last_terminal_failure_at_gmt' => null,
            'last_http_status' => null,
            'last_failure_category' => null,
            'last_attempt_number' => null,
        ];

        if (!EventSales_Integration_Health_Plugins::catalog_producer_active()
            || !method_exists('EventSales_Tickera_Catalog_Feed', 'catalog_change_delivery_telemetry')) {
            return array_merge($report, $telemetry_fields);
        }

        $telemetry_fields['delivery_telemetry_supported'] = true;

        try {
            $telemetry = EventSales_Tickera_Catalog_Feed::catalog_change_delivery_telemetry();
        } catch (Throwable $error) {
            return array_merge($report, $telemetry_fields);
        }

        if (!is_array($telemetry)) {
            return array_merge($report, $telemetry_fields);
        }

        $version = $telemetry['telemetry_version'] ?? null;
        if (is_string($version) && preg_match('/^[0-9]{4}-[0-9]{2}-[0-9]{2}\\.v[0-9]+$/', $version) === 1) {
            $telemetry_fields['delivery_telemetry_version'] = $version;
        }

        $state = $telemetry['state'] ?? null;
        if (!in_array($state, ['NEVER_ATTEMPTED', 'RETRY_SCHEDULED', 'SUCCEEDED', 'TERMINAL_FAILURE'], true)) {
            return array_merge($report, $telemetry_fields);
        }

        $telemetry_fields['delivery_state'] = $state;
        if ($state === 'NEVER_ATTEMPTED') {
            return array_merge($report, $telemetry_fields);
        }

        $failure_category = $telemetry['last_failure_category'] ?? null;
        $categories = ['transport_error', 'retryable_http', 'non_retryable_http', 'retry_scheduler_unavailable'];
        $telemetry_fields['last_attempt_at_gmt'] = self::valid_telemetry_timestamp($telemetry['last_attempt_at_gmt'] ?? null);
        $telemetry_fields['last_success_at_gmt'] = self::valid_telemetry_timestamp($telemetry['last_success_at_gmt'] ?? null);
        $telemetry_fields['last_terminal_failure_at_gmt'] = self::valid_telemetry_timestamp($telemetry['last_terminal_failure_at_gmt'] ?? null);
        $telemetry_fields['last_http_status'] = self::valid_telemetry_http_status($telemetry['last_http_status'] ?? null);
        $telemetry_fields['last_failure_category'] = in_array($failure_category, $categories, true) ? $failure_category : null;
        $telemetry_fields['last_attempt_number'] = self::valid_telemetry_attempt($telemetry['last_attempt_number'] ?? null);

        return array_merge($report, $telemetry_fields);
    }

    private static function valid_telemetry_timestamp($value): ?string
    {
        if (!is_string($value) || preg_match('/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/', $value) !== 1) {
            return null;
        }

        $timestamp = strtotime($value);
        if ($timestamp === false || gmdate('Y-m-d\\TH:i:s\\Z', $timestamp) !== $value) {
            return null;
        }

        return $value;
    }

    private static function valid_telemetry_http_status($value): ?int
    {
        if (!is_int($value) || ($value !== 0 && ($value < 100 || $value > 599))) {
            return null;
        }

        return $value;
    }

    private static function valid_telemetry_attempt($value): ?int
    {
        if (!is_int($value) || $value < 1 || $value > 5) {
            return null;
        }

        return $value;
    }

    private static function scheduler_available(): bool
    {
        return function_exists('as_enqueue_async_action') && function_exists('as_schedule_single_action');
    }

    private static function non_empty_constant(string $name): bool
    {
        if (!defined($name)) {
            return false;
        }

        $value = constant($name);

        return is_scalar($value) && trim((string) $value) !== '';
    }
}

final class EventSales_Integration_Health_Order_Index
{
    /**
     * @return array<string, mixed>
     */
    public static function evaluate(): array
    {
        $basename = EventSales_Integration_Health_Plugins::ORDER_INDEX_BASENAME;
        $installed = EventSales_Integration_Health_Plugins::installed($basename);
        $active = $installed && EventSales_Integration_Health_Plugins::active($basename);
        $class_loaded = class_exists('EventSales_Woo_Order_Index_Feed');

        if (!$installed) {
            return self::report($basename, false, false, EventSales_Integration_Health_States::ABSENT, false, false);
        }

        if (!$active || !$class_loaded) {
            return self::report($basename, true, false, EventSales_Integration_Health_States::INACTIVE, false, false);
        }

        $auth = self::authentication_configured();

        if (!$auth) {
            return self::report(
                $basename,
                true,
                true,
                EventSales_Integration_Health_States::MISCONFIGURED,
                $auth,
                false
            );
        }

        $storage = self::storage_available();

        if (!$storage) {
            return self::report(
                $basename,
                true,
                true,
                EventSales_Integration_Health_States::DEPENDENCY_UNAVAILABLE,
                $auth,
                $storage
            );
        }

        if (!self::schema_version_available()) {
            return self::report(
                $basename,
                true,
                true,
                EventSales_Integration_Health_States::DEPENDENCY_UNAVAILABLE,
                $auth,
                $storage
            );
        }

        return self::report($basename, true, true, EventSales_Integration_Health_States::READY, $auth, $storage);
    }

    public static function schema_version_available(): bool
    {
        return EventSales_Integration_Health_Plugins::non_empty_defined_constant('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION');
    }

    public static function authentication_configured(): bool
    {
        return self::configured_value_present('EVENTSALES_WOO_ORDER_INDEX_KEY_ID', 'eventsales_woo_order_index_key_id')
            && self::configured_value_present('EVENTSALES_WOO_ORDER_INDEX_SECRET', 'eventsales_woo_order_index_secret');
    }

    public static function storage_available(): bool
    {
        global $wpdb;

        if (!is_object($wpdb) || !property_exists($wpdb, 'prefix')) {
            return false;
        }

        $prefix = (string) $wpdb->prefix;
        if ($prefix === '' || !preg_match('/^[A-Za-z0-9_]+$/D', $prefix)) {
            return false;
        }

        $manifest = $prefix . 'eventsales_order_manifests';
        $items = $prefix . 'eventsales_order_manifest_items';

        if (!preg_match('/^[A-Za-z0-9_]+$/D', $manifest) || !preg_match('/^[A-Za-z0-9_]+$/D', $items)) {
            return false;
        }

        if (!method_exists($wpdb, 'get_var') || !method_exists($wpdb, 'prepare')) {
            return false;
        }

        $found_manifest = $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $manifest));
        $found_items = $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $items));

        return $found_manifest === $manifest && $found_items === $items;
    }

    private static function configured_value_present(string $constant_name, string $fallback_option): bool
    {
        if (class_exists('EventSales_Woo_Order_Index_Feed')) {
            if ($constant_name === 'EVENTSALES_WOO_ORDER_INDEX_KEY_ID') {
                $fallback_option = EventSales_Woo_Order_Index_Feed::key_id_option_name();
            }
            if ($constant_name === 'EVENTSALES_WOO_ORDER_INDEX_SECRET') {
                $fallback_option = EventSales_Woo_Order_Index_Feed::secret_option_name();
            }
        }

        if (defined($constant_name)) {
            $value = constant($constant_name);

            return is_scalar($value) && trim((string) $value) !== '';
        }

        if (!function_exists('get_option')) {
            return false;
        }

        $value = get_option($fallback_option, '');

        return is_scalar($value) && trim((string) $value) !== '';
    }

    /**
     * @return array<string, mixed>
     */
    private static function report(
        string $basename,
        bool $installed,
        bool $active,
        string $status,
        bool $auth,
        bool $storage
    ): array {
        return [
            'installed' => $installed,
            'active' => $active,
            'status' => $status,
            'plugin_version' => EventSales_Integration_Health_Plugins::marketing_version($basename),
            'schema_version' => defined('EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION')
                ? (string) EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION
                : null,
            'authentication_configured' => $auth,
            'storage_available' => $storage,
        ];
    }
}

final class EventSales_Integration_Health_Order_Line_Identity
{
    /**
     * @return array<string, mixed>
     */
    public static function evaluate(): array
    {
        $basename = EventSales_Integration_Health_Plugins::ORDER_LINE_BASENAME;
        $installed = EventSales_Integration_Health_Plugins::installed($basename);
        $active = $installed && EventSales_Integration_Health_Plugins::active($basename);
        $class_loaded = class_exists('EventSales_Woo_Order_Line_Identity');

        $woo = class_exists('WooCommerce') || defined('WC_VERSION');
        $tickera = post_type_exists('tc_events');

        if (!$installed) {
            return self::report($basename, false, false, EventSales_Integration_Health_States::ABSENT, $woo, $tickera);
        }

        if (!$active || !$class_loaded) {
            return self::report($basename, true, false, EventSales_Integration_Health_States::INACTIVE, $woo, $tickera);
        }

        if (!$woo || !$tickera) {
            return self::report(
                $basename,
                true,
                true,
                EventSales_Integration_Health_States::DEPENDENCY_UNAVAILABLE,
                $woo,
                $tickera
            );
        }

        return self::report($basename, true, true, EventSales_Integration_Health_States::READY, $woo, $tickera);
    }

    /**
     * @return array<string, mixed>
     */
    private static function report(
        string $basename,
        bool $installed,
        bool $active,
        string $status,
        bool $woo,
        bool $tickera
    ): array {
        return [
            'installed' => $installed,
            'active' => $active,
            'status' => $status,
            'plugin_version' => EventSales_Integration_Health_Plugins::marketing_version($basename),
            'woocommerce_dependency_available' => $woo,
            'tickera_event_capability_available' => $tickera,
        ];
    }
}

final class EventSales_Integration_Health_Snapshot
{
    /**
     * @return array<string, mixed>
     */
    public static function build(): array
    {
        return [
            'dependencies' => EventSales_Integration_Health_Dependencies::snapshot(),
            'catalog_feed' => EventSales_Integration_Health_Catalog::evaluate(),
            'catalog_change_sender' => EventSales_Integration_Health_Catalog_Change_Sender::evaluate(),
            'order_index_feed' => EventSales_Integration_Health_Order_Index::evaluate(),
            'order_line_identity' => EventSales_Integration_Health_Order_Line_Identity::evaluate(),
        ];
    }

    /**
     * @param array<string, mixed> $snapshot
     */
    public static function site_health_status_for_component(string $component_status): string
    {
        if ($component_status === EventSales_Integration_Health_States::READY) {
            return 'good';
        }

        if ($component_status === EventSales_Integration_Health_States::DISABLED) {
            return 'good';
        }

        if ($component_status === EventSales_Integration_Health_States::INACTIVE) {
            return 'recommended';
        }

        return 'critical';
    }

    /**
     * @param array<string, mixed> $field
     */
    public static function format_debug_value($field): string
    {
        if (is_bool($field)) {
            return $field ? 'true' : 'false';
        }

        if ($field === null) {
            return 'n/a';
        }

        if (is_scalar($field)) {
            return (string) $field;
        }

        return wp_json_encode($field) ?: '';
    }
}

final class EventSales_Integration_Health_Site_Health
{
    public const TEST_CATALOG_FEED = 'eventsales_catalog_feed';
    public const TEST_CATALOG_CHANGE_SENDER = 'eventsales_catalog_change_sender';
    public const TEST_ORDER_INDEX_FEED = 'eventsales_order_index_feed';
    public const TEST_ORDER_LINE_IDENTITY = 'eventsales_order_line_identity';

    public static function register_hooks(): void
    {
        add_filter('site_status_tests', [self::class, 'register_tests']);
        add_filter('debug_information', [self::class, 'register_debug']);
    }

    /**
     * @param array<string, mixed> $tests
     * @return array<string, mixed>
     */
    public static function register_tests(array $tests): array
    {
        $tests['direct']['eventsales_catalog_feed'] = [
            'label' => __('EventSales Tickera catalog feed', 'eventsales-integration-health'),
            'test' => [self::class, 'test_catalog_feed'],
        ];
        $tests['direct']['eventsales_catalog_change_sender'] = [
            'label' => __('EventSales catalogue-change sender', 'eventsales-integration-health'),
            'test' => [self::class, 'test_catalog_change_sender'],
        ];
        $tests['direct']['eventsales_order_index_feed'] = [
            'label' => __('EventSales Woo order index feed', 'eventsales-integration-health'),
            'test' => [self::class, 'test_order_index_feed'],
        ];
        $tests['direct']['eventsales_order_line_identity'] = [
            'label' => __('EventSales Woo order line identity', 'eventsales-integration-health'),
            'test' => [self::class, 'test_order_line_identity'],
        ];

        return $tests;
    }

    /**
     * @return array<string, mixed>
     */
    public static function test_catalog_feed(): array
    {
        $report = EventSales_Integration_Health_Catalog::evaluate();

        return self::result_from_report(
            self::TEST_CATALOG_FEED,
            __('EventSales Tickera catalog feed', 'eventsales-integration-health'),
            (string) $report['status'],
            self::catalog_description($report)
        );
    }

    /**
     * @return array<string, mixed>
     */
    public static function test_catalog_change_sender(): array
    {
        $report = EventSales_Integration_Health_Catalog_Change_Sender::evaluate();

        return self::result_from_report(
            self::TEST_CATALOG_CHANGE_SENDER,
            __('EventSales catalogue-change sender', 'eventsales-integration-health'),
            (string) $report['status'],
            self::sender_description($report)
        );
    }

    /**
     * @return array<string, mixed>
     */
    public static function test_order_index_feed(): array
    {
        $report = EventSales_Integration_Health_Order_Index::evaluate();

        return self::result_from_report(
            self::TEST_ORDER_INDEX_FEED,
            __('EventSales Woo order index feed', 'eventsales-integration-health'),
            (string) $report['status'],
            self::order_index_description($report)
        );
    }

    /**
     * @return array<string, mixed>
     */
    public static function test_order_line_identity(): array
    {
        $report = EventSales_Integration_Health_Order_Line_Identity::evaluate();

        return self::result_from_report(
            self::TEST_ORDER_LINE_IDENTITY,
            __('EventSales Woo order line identity', 'eventsales-integration-health'),
            (string) $report['status'],
            self::order_line_description($report)
        );
    }

    /**
     * @param array<string, mixed> $info
     * @return array<string, mixed>
     */
    public static function register_debug(array $info): array
    {
        $snapshot = EventSales_Integration_Health_Snapshot::build();
        $fields = [];

        foreach ($snapshot as $section => $payload) {
            if (!is_array($payload)) {
                continue;
            }

            foreach ($payload as $key => $value) {
                $fields[$section . '.' . $key] = [
                    'label' => $section . ' — ' . $key,
                    'value' => EventSales_Integration_Health_Snapshot::format_debug_value($value),
                ];
            }
        }

        $info['eventsales'] = [
            'label' => __('EventSales integrations', 'eventsales-integration-health'),
            'description' => __('Read-only integration readiness (no secrets).', 'eventsales-integration-health'),
            'fields' => $fields,
        ];

        return $info;
    }

    /**
     * @param array<string, mixed> $report
     */
    private static function catalog_description(array $report): string
    {
        return sprintf(
            'Status %s. Schema %s. Contract %s. Producer %s. Authentication configured: %s.',
            $report['status'],
            $report['schema_version'] ?? 'n/a',
            $report['canonical_contract_version'] ?? 'n/a',
            $report['producer_version'] ?? 'n/a',
            EventSales_Integration_Health_Snapshot::format_debug_value($report['authentication_configured'])
        );
    }

    /**
     * @param array<string, mixed> $report
     */
    private static function sender_description(array $report): string
    {
        return sprintf(
            'Status %s. Catalog active: %s. Enabled: %s. Endpoint configured: %s. Key configured: %s. Secret configured: %s. Scheduler: %s.',
            $report['status'],
            EventSales_Integration_Health_Snapshot::format_debug_value($report['catalog_active'] ?? false),
            EventSales_Integration_Health_Snapshot::format_debug_value($report['enabled']),
            EventSales_Integration_Health_Snapshot::format_debug_value($report['endpoint_configured']),
            EventSales_Integration_Health_Snapshot::format_debug_value($report['key_id_configured']),
            EventSales_Integration_Health_Snapshot::format_debug_value($report['secret_configured']),
            EventSales_Integration_Health_Snapshot::format_debug_value($report['scheduler_available'])
        );
    }

    /**
     * @param array<string, mixed> $report
     */
    private static function order_index_description(array $report): string
    {
        return sprintf(
            'Status %s. Schema %s. Authentication configured: %s. Storage available: %s.',
            $report['status'],
            $report['schema_version'] ?? 'n/a',
            EventSales_Integration_Health_Snapshot::format_debug_value($report['authentication_configured']),
            EventSales_Integration_Health_Snapshot::format_debug_value($report['storage_available'])
        );
    }

    /**
     * @param array<string, mixed> $report
     */
    private static function order_line_description(array $report): string
    {
        return sprintf(
            'Status %s. WooCommerce available: %s. Tickera tc_events available: %s.',
            $report['status'],
            EventSales_Integration_Health_Snapshot::format_debug_value($report['woocommerce_dependency_available']),
            EventSales_Integration_Health_Snapshot::format_debug_value($report['tickera_event_capability_available'])
        );
    }

    /**
     * @return array<string, mixed>
     */
    private static function result_from_report(string $test_id, string $label, string $status, string $description): array
    {
        return [
            'label' => $label,
            'status' => EventSales_Integration_Health_Snapshot::site_health_status_for_component($status),
            'badge' => [
                'label' => __('EventSales', 'eventsales-integration-health'),
                'color' => 'blue',
            ],
            'description' => $description,
            'actions' => '',
            'test' => $test_id,
        ];
    }
}
