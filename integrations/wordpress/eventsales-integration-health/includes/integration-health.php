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

        return self::report($basename, true, true, EventSales_Integration_Health_States::READY, $auth);
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
        $enabled = defined('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED')
            && EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED;

        if (!$enabled) {
            return [
                'enabled' => false,
                'endpoint_configured' => false,
                'key_id_configured' => false,
                'secret_configured' => false,
                'scheduler_available' => self::scheduler_available(),
                'status' => EventSales_Integration_Health_States::DISABLED,
            ];
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

        return [
            'enabled' => true,
            'endpoint_configured' => $endpoint,
            'key_id_configured' => $key_id,
            'secret_configured' => $secret,
            'scheduler_available' => $scheduler,
            'status' => $status,
        ];
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

        return self::report($basename, true, true, EventSales_Integration_Health_States::READY, $auth, $storage);
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
            'Status %s. Enabled: %s. Endpoint configured: %s. Key configured: %s. Secret configured: %s. Scheduler: %s.',
            $report['status'],
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
    private static function result_from_report(string $label, string $status, string $description): array
    {
        return [
            'label' => $label,
            'status' => EventSales_Integration_Health_Snapshot::site_health_status_for_component($status),
            'description' => $description,
            'actions' => '',
        ];
    }
}
