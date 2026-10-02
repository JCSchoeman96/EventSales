<?php

declare(strict_types=1);

/**
 * Focused tests for EventSales WordPress integration health (read-only).
 */

define('ABSPATH', __DIR__);
define('WP_PLUGIN_DIR', dirname(__DIR__, 2));

$EVENTSALES_HEALTH_INCLUDES = dirname(__DIR__) . '/includes/integration-health.php';
$EVENTSALES_WP_PLUGIN_DIR = WP_PLUGIN_DIR;

$GLOBALS['options'] = [];
$GLOBALS['active_plugins'] = [];
$GLOBALS['plugin_registry'] = [];
$GLOBALS['post_types'] = [];
$GLOBALS['side_effects'] = [];
$GLOBALS['wpdb'] = null;

function add_action($hook, $callback, $priority = 10, $accepted_args = 1)
{
    return true;
}

function get_option($name, $default = false)
{
    return array_key_exists($name, $GLOBALS['options']) ? $GLOBALS['options'][$name] : $default;
}

function update_option($name, $value, $autoload = null)
{
    $GLOBALS['side_effects'][] = 'update_option';

    return true;
}

function delete_option($name)
{
    $GLOBALS['side_effects'][] = 'delete_option';

    return true;
}

function set_transient($name, $value, $expiration = 0)
{
    $GLOBALS['side_effects'][] = 'set_transient';

    return true;
}

function delete_transient($name)
{
    $GLOBALS['side_effects'][] = 'delete_transient';

    return true;
}

function wp_remote_get(...$args)
{
    $GLOBALS['side_effects'][] = 'wp_remote_get';

    return [];
}

function wp_remote_post(...$args)
{
    $GLOBALS['side_effects'][] = 'wp_remote_post';

    return [];
}

function wp_insert_post(...$args)
{
    $GLOBALS['side_effects'][] = 'wp_insert_post';

    return 0;
}

function wp_update_post(...$args)
{
    $GLOBALS['side_effects'][] = 'wp_update_post';

    return 0;
}

function get_plugins()
{
    return $GLOBALS['plugin_registry'];
}

function is_plugin_active($basename)
{
    return in_array($basename, $GLOBALS['active_plugins'], true);
}

function post_type_exists($type)
{
    return in_array($type, $GLOBALS['post_types'], true);
}

function wp_json_encode($value)
{
    return json_encode($value);
}

function __($text, $domain = 'default')
{
    return $text;
}

require dirname(__DIR__) . '/includes/integration-health.php';

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
        self::ok($label, $expected === $actual);
    }

    public static function contains_none(string $label, string $haystack, array $needles): void
    {
        foreach ($needles as $needle) {
            self::ok($label . ' lacks ' . $needle, strpos($haystack, $needle) === false);
        }
    }

    /** @param array<string, mixed> $result */
    public static function site_health_result_shape(string $label, array $result, string $expected_test_id): void
    {
        self::ok($label . ' has label', isset($result['label']) && is_string($result['label']));
        self::ok($label . ' has status', isset($result['status']) && is_string($result['status']));
        self::ok($label . ' has badge.label', isset($result['badge']['label']) && is_string($result['badge']['label']));
        self::ok($label . ' has badge.color', isset($result['badge']['color']) && is_string($result['badge']['color']));
        self::ok($label . ' has description', isset($result['description']) && is_string($result['description']));
        self::ok($label . ' has actions', array_key_exists('actions', $result));
        self::same($label . ' test id', $expected_test_id, $result['test'] ?? null);
    }
}

function eventsales_reset_test_state(): void
{
    $GLOBALS['options'] = [];
    $GLOBALS['active_plugins'] = [];
    $GLOBALS['plugin_registry'] = [];
    $GLOBALS['post_types'] = [];
    $GLOBALS['side_effects'] = [];
    $GLOBALS['wpdb'] = null;
}

function eventsales_register_plugin(string $basename, string $version = '0.0.0'): void
{
    $GLOBALS['plugin_registry'][$basename] = ['Version' => $version];
}

function eventsales_activate(string $basename): void
{
    if (!in_array($basename, $GLOBALS['active_plugins'], true)) {
        $GLOBALS['active_plugins'][] = $basename;
    }
}

/** @return object */
function eventsales_mock_wpdb(array $tables)
{
    return new class ($tables) {
        public string $prefix = 'wp_';

        /** @var array<int, string> */
        private array $tables;

        public function __construct(array $tables)
        {
            $this->tables = $tables;
        }

        public function prepare(string $query, ...$args): string
        {
            if (count($args) === 1 && strpos($query, '%s') !== false) {
                return str_replace('%s', "'" . (string) $args[0] . "'", $query);
            }

            return $query;
        }

        public function get_var(string $query)
        {
            if (preg_match("/SHOW TABLES LIKE '([^']+)'/", $query, $matches)) {
                $name = $matches[1];

                return in_array($name, $this->tables, true) ? $name : null;
            }

            return null;
        }
    };
}

function eventsales_load_catalog_producer(): void
{
    if (!class_exists('EventSales_Tickera_Catalog_Feed')) {
        require WP_PLUGIN_DIR . '/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php';
    }
}

function eventsales_load_order_index_producer(): void
{
    if (!class_exists('EventSales_Woo_Order_Index_Feed')) {
        require WP_PLUGIN_DIR . '/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php';
    }
}

function eventsales_load_order_line_producer(): void
{
    if (!class_exists('EventSales_Woo_Order_Line_Identity')) {
        require WP_PLUGIN_DIR . '/eventsales-woo-order-line-identity/eventsales-woo-order-line-identity.php';
    }
}

function eventsales_catalog_bootstrap_php(): string
{
    $plugin_dir = WP_PLUGIN_DIR;

    return "\$GLOBALS['plugin_registry']['" . EventSales_Integration_Health_Plugins::CATALOG_BASENAME . "'] = ['Version' => '0.1.0'];\n"
        . "\$GLOBALS['active_plugins'][] = '" . EventSales_Integration_Health_Plugins::CATALOG_BASENAME . "';\n"
        . "if (!function_exists('add_action')) { function add_action(...\$args) { return true; } }\n"
        . 'require ' . var_export($plugin_dir . '/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php', true) . ";\n";
}

function eventsales_run_isolated_probe(string $body, string $expect_status, string $label): void
{
    $probe = "<?php\n"
        . "define('ABSPATH', __DIR__);\n"
        . 'define(\'WP_PLUGIN_DIR\', ' . var_export(WP_PLUGIN_DIR, true) . ");\n"
        . "\$GLOBALS['options'] = [];\n"
        . "\$GLOBALS['active_plugins'] = [];\n"
        . "\$GLOBALS['plugin_registry'] = [];\n"
        . "\$GLOBALS['post_types'] = [];\n"
        . "function get_option(\$name, \$default = false) {\n"
        . "    return array_key_exists(\$name, \$GLOBALS['options']) ? \$GLOBALS['options'][\$name] : \$default;\n"
        . "}\n"
        . "function get_plugins() { return \$GLOBALS['plugin_registry']; }\n"
        . "function is_plugin_active(\$basename) { return in_array(\$basename, \$GLOBALS['active_plugins'], true); }\n"
        . "function post_type_exists(\$type) { return in_array(\$type, \$GLOBALS['post_types'], true); }\n"
        . "function wp_json_encode(\$value) { return json_encode(\$value); }\n"
        . "function __(\$text, \$domain = 'default') { return \$text; }\n"
        . "if (!function_exists('add_action')) { function add_action(...\$args) { return true; } }\n"
        . $body;

    $path = sys_get_temp_dir() . '/eventsales-probe-' . bin2hex(random_bytes(4)) . '.php';
    file_put_contents($path, $probe);
    $output = [];
    $exit = 0;
    exec('php ' . escapeshellarg($path), $output, $exit);
    @unlink($path);

    T::ok($label . ' probe exit zero', $exit === 0);
    T::same($label, $expect_status, $output[0] ?? '');
}

// --- State model ---

eventsales_reset_test_state();
T::same('catalog absent', EventSales_Integration_Health_States::ABSENT, EventSales_Integration_Health_Catalog::evaluate()['status']);

eventsales_register_plugin(EventSales_Integration_Health_Plugins::CATALOG_BASENAME, '0.1.0');
T::same('catalog inactive', EventSales_Integration_Health_States::INACTIVE, EventSales_Integration_Health_Catalog::evaluate()['status']);
T::same('sender inactive when catalog inactive', EventSales_Integration_Health_States::INACTIVE, EventSales_Integration_Health_Catalog_Change_Sender::evaluate()['status']);

eventsales_activate(EventSales_Integration_Health_Plugins::CATALOG_BASENAME);
eventsales_load_catalog_producer();
T::same('sender disabled when catalog active', EventSales_Integration_Health_States::DISABLED, EventSales_Integration_Health_Catalog_Change_Sender::evaluate()['status']);
T::same('catalog misconfigured without secret', EventSales_Integration_Health_States::MISCONFIGURED, EventSales_Integration_Health_Catalog::evaluate()['status']);

$GLOBALS['options']['eventsales_tickera_catalog_secret'] = 'SUPER_SECRET_DO_NOT_RENDER';
T::same('catalog ready with option secret', EventSales_Integration_Health_States::READY, EventSales_Integration_Health_Catalog::evaluate()['status']);
T::ok('catalog auth is boolean', is_bool(EventSales_Integration_Health_Catalog::evaluate()['authentication_configured']));

// --- Catalogue versions ---

T::same('catalog schema', '2026-08-07.v3', EventSales_Integration_Health_Catalog::evaluate()['schema_version']);
T::same('catalog contract', 'source_risk.v3', EventSales_Integration_Health_Catalog::evaluate()['canonical_contract_version']);
T::same('catalog producer', '2026-08-07.1', EventSales_Integration_Health_Catalog::evaluate()['producer_version']);

// --- Sender (isolated PHP processes because sender constants cannot be undefined) ---

global $EVENTSALES_HEALTH_INCLUDES;

$sender_catalog = eventsales_catalog_bootstrap_php();
$sender_tail = 'require ' . var_export($EVENTSALES_HEALTH_INCLUDES, true) . ";\n"
    . "\$report = EventSales_Integration_Health_Catalog_Change_Sender::evaluate();\n"
    . "fwrite(STDOUT, \$report['status']);\n";

eventsales_run_isolated_probe(
    "define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);\n"
    . "define('EVENTSALES_CATALOG_CHANGE_ENDPOINT', 'https://eventsales.example/hooks/PATH_TOKEN_DO_NOT_RENDER');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_KEY_ID', 'key');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SECRET', 'SUPER_SECRET_DO_NOT_RENDER');\n"
    . "function as_enqueue_async_action(...\$args) { return 1; }\n"
    . "function as_schedule_single_action(...\$args) { return 1; }\n"
    . $sender_tail,
    EventSales_Integration_Health_States::ABSENT,
    'sender enabled without catalog producer'
);

eventsales_run_isolated_probe(
    "\$GLOBALS['plugin_registry']['" . EventSales_Integration_Health_Plugins::CATALOG_BASENAME . "'] = ['Version' => '0.1.0'];\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);\n"
    . "define('EVENTSALES_CATALOG_CHANGE_ENDPOINT', 'https://eventsales.example/hooks/PATH_TOKEN_DO_NOT_RENDER');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_KEY_ID', 'key');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SECRET', 'SUPER_SECRET_DO_NOT_RENDER');\n"
    . "function as_enqueue_async_action(...\$args) { return 1; }\n"
    . "function as_schedule_single_action(...\$args) { return 1; }\n"
    . $sender_tail,
    EventSales_Integration_Health_States::INACTIVE,
    'sender enabled with inactive catalog producer'
);

eventsales_run_isolated_probe(
    $sender_catalog
    . "define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);\n"
    . $sender_tail,
    EventSales_Integration_Health_States::MISCONFIGURED,
    'sender misconfigured'
);

eventsales_run_isolated_probe(
    $sender_catalog
    . "define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);\n"
    . "define('EVENTSALES_CATALOG_CHANGE_ENDPOINT', 'https://eventsales.example/webhooks/catalog-change/PATH_TOKEN_DO_NOT_RENDER');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_KEY_ID', 'key');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SECRET', 'SUPER_SECRET_DO_NOT_RENDER');\n"
    . $sender_tail,
    EventSales_Integration_Health_States::DEPENDENCY_UNAVAILABLE,
    'sender missing scheduler'
);

eventsales_run_isolated_probe(
    "final class EventSales_Tickera_Catalog_Feed {}\n"
    . "\$GLOBALS['plugin_registry']['" . EventSales_Integration_Health_Plugins::CATALOG_BASENAME . "'] = ['Version' => '0.1.0'];\n"
    . "\$GLOBALS['active_plugins'][] = '" . EventSales_Integration_Health_Plugins::CATALOG_BASENAME . "';\n"
    . "\$GLOBALS['options']['eventsales_tickera_catalog_secret'] = 'local-secret';\n"
    . 'require ' . var_export($EVENTSALES_HEALTH_INCLUDES, true) . ";\n"
    . "fwrite(STDOUT, EventSales_Integration_Health_Catalog::evaluate()['status']);\n",
    EventSales_Integration_Health_States::DEPENDENCY_UNAVAILABLE,
    'catalog missing contract identity'
);

eventsales_run_isolated_probe(
    "final class EventSales_Woo_Order_Index_Feed {\n"
    . "  public static function key_id_option_name(): string { return 'eventsales_woo_order_index_key_id'; }\n"
    . "  public static function secret_option_name(): string { return 'eventsales_woo_order_index_secret'; }\n"
    . "}\n"
    . "\$GLOBALS['plugin_registry']['" . EventSales_Integration_Health_Plugins::ORDER_INDEX_BASENAME . "'] = ['Version' => '0.2.0'];\n"
    . "\$GLOBALS['active_plugins'][] = '" . EventSales_Integration_Health_Plugins::ORDER_INDEX_BASENAME . "';\n"
    . "\$GLOBALS['options']['eventsales_woo_order_index_key_id'] = 'kid';\n"
    . "\$GLOBALS['options']['eventsales_woo_order_index_secret'] = 'secret';\n"
    . "\$GLOBALS['wpdb'] = new class {\n"
    . "  public string \$prefix = 'wp_';\n"
    . "  public function prepare(string \$query, ...\$args): string { return str_replace('%s', \"'\".(string)\$args[0].\"'\", \$query); }\n"
    . "  public function get_var(string \$query) { preg_match(\"/SHOW TABLES LIKE '([^']+)'/\", \$query, \$m); return in_array(\$m[1], ['wp_eventsales_order_manifests','wp_eventsales_order_manifest_items'], true) ? \$m[1] : null; }\n"
    . "};\n"
    . 'require ' . var_export($EVENTSALES_HEALTH_INCLUDES, true) . ";\n"
    . "fwrite(STDOUT, EventSales_Integration_Health_Order_Index::evaluate()['status']);\n",
    EventSales_Integration_Health_States::DEPENDENCY_UNAVAILABLE,
    'order index missing schema version'
);

// --- Order index ---

eventsales_reset_test_state();
T::same('order index absent', EventSales_Integration_Health_States::ABSENT, EventSales_Integration_Health_Order_Index::evaluate()['status']);

eventsales_register_plugin(EventSales_Integration_Health_Plugins::ORDER_INDEX_BASENAME, '0.2.0');
eventsales_activate(EventSales_Integration_Health_Plugins::ORDER_INDEX_BASENAME);
eventsales_load_order_index_producer();
T::same('order index misconfigured', EventSales_Integration_Health_States::MISCONFIGURED, EventSales_Integration_Health_Order_Index::evaluate()['status']);

$GLOBALS['options']['eventsales_woo_order_index_key_id'] = 'kid';
$GLOBALS['options']['eventsales_woo_order_index_secret'] = 'ORDER_TOKEN_DO_NOT_RENDER';
T::same('order index missing storage', EventSales_Integration_Health_States::DEPENDENCY_UNAVAILABLE, EventSales_Integration_Health_Order_Index::evaluate()['status']);

$GLOBALS['wpdb'] = eventsales_mock_wpdb(['wp_eventsales_order_manifests', 'wp_eventsales_order_manifest_items']);
T::same('order index ready', EventSales_Integration_Health_States::READY, EventSales_Integration_Health_Order_Index::evaluate()['status']);
T::same('order index schema', '2026-08-12.v1', EventSales_Integration_Health_Order_Index::evaluate()['schema_version']);

// --- Order line identity ---

eventsales_reset_test_state();
T::same('order line absent', EventSales_Integration_Health_States::ABSENT, EventSales_Integration_Health_Order_Line_Identity::evaluate()['status']);

eventsales_register_plugin(EventSales_Integration_Health_Plugins::ORDER_LINE_BASENAME, '0.1.0');
eventsales_activate(EventSales_Integration_Health_Plugins::ORDER_LINE_BASENAME);
eventsales_load_order_line_producer();
$GLOBALS['post_types'] = [];
T::same('order line dependency missing', EventSales_Integration_Health_States::DEPENDENCY_UNAVAILABLE, EventSales_Integration_Health_Order_Line_Identity::evaluate()['status']);

if (!defined('WC_VERSION')) {
    define('WC_VERSION', '8.0.0');
}
$GLOBALS['post_types'] = ['tc_events'];
T::same('order line ready', EventSales_Integration_Health_States::READY, EventSales_Integration_Health_Order_Line_Identity::evaluate()['status']);

// --- Redaction and site health output (subprocess with sender constants) ---

$redaction_script = "<?php\n"
    . "define('ABSPATH', __DIR__);\n"
    . 'define(\'WP_PLUGIN_DIR\', ' . var_export($EVENTSALES_WP_PLUGIN_DIR, true) . ");\n"
    . "\$GLOBALS['options'] = [\n"
    . "    'eventsales_tickera_catalog_secret' => 'SUPER_SECRET_DO_NOT_RENDER',\n"
    . "    'eventsales_woo_order_index_key_id' => 'kid',\n"
    . "    'eventsales_woo_order_index_secret' => 'ORDER_TOKEN_DO_NOT_RENDER',\n"
    . "];\n"
    . "function add_action(...\$args) { return true; }\n"
    . "function get_option(\$name, \$default = false) {\n"
    . "    return array_key_exists(\$name, \$GLOBALS['options']) ? \$GLOBALS['options'][\$name] : \$default;\n"
    . "}\n"
    . "\$GLOBALS['active_plugins'] = [\n"
    . "    'eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php',\n"
    . "    'eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php',\n"
    . "];\n"
    . "\$GLOBALS['plugin_registry'] = [\n"
    . "    'eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php' => ['Version' => '0.1.0'],\n"
    . "    'eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php' => ['Version' => '0.2.0'],\n"
    . "];\n"
    . "\$GLOBALS['post_types'] = [];\n"
    . "function get_plugins() { return \$GLOBALS['plugin_registry']; }\n"
    . "function is_plugin_active(\$basename) { return in_array(\$basename, \$GLOBALS['active_plugins'], true); }\n"
    . "function post_type_exists(\$type) { return in_array(\$type, \$GLOBALS['post_types'], true); }\n"
    . "function wp_json_encode(\$value) { return json_encode(\$value); }\n"
    . "function __(\$text, \$domain = 'default') { return \$text; }\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);\n"
    . "define('EVENTSALES_CATALOG_CHANGE_ENDPOINT', 'https://example.test/hooks/PATH_TOKEN_DO_NOT_RENDER');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_KEY_ID', 'kid');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SECRET', 'SUPER_SECRET_DO_NOT_RENDER');\n"
    . 'require ' . var_export($EVENTSALES_WP_PLUGIN_DIR . '/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php', true) . ";\n"
    . 'require ' . var_export($EVENTSALES_WP_PLUGIN_DIR . '/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php', true) . ";\n"
    . 'require ' . var_export($EVENTSALES_HEALTH_INCLUDES, true) . ";\n"
    . "\$payload = [\n"
    . "    'snapshot' => EventSales_Integration_Health_Snapshot::build(),\n"
    . "    'catalog_test' => EventSales_Integration_Health_Site_Health::test_catalog_feed(),\n"
    . "    'debug' => EventSales_Integration_Health_Site_Health::register_debug([]),\n"
    . "];\n"
    . "fwrite(STDOUT, wp_json_encode(\$payload));\n";

$redaction_path = sys_get_temp_dir() . '/eventsales-redaction-' . bin2hex(random_bytes(4)) . '.php';
file_put_contents($redaction_path, $redaction_script);
$redaction_output = shell_exec('php ' . escapeshellarg($redaction_path));
@unlink($redaction_path);
$sentinals = ['SUPER_SECRET_DO_NOT_RENDER', 'PATH_TOKEN_DO_NOT_RENDER', 'ORDER_TOKEN_DO_NOT_RENDER'];
T::contains_none('redaction subprocess output', (string) $redaction_output, $sentinals);

// --- No side effects during evaluation ---

eventsales_reset_test_state();
eventsales_register_plugin(EventSales_Integration_Health_Plugins::CATALOG_BASENAME, '0.1.0');
eventsales_activate(EventSales_Integration_Health_Plugins::CATALOG_BASENAME);
eventsales_load_catalog_producer();
$GLOBALS['options']['eventsales_tickera_catalog_secret'] = 'local-secret';
eventsales_register_plugin(EventSales_Integration_Health_Plugins::ORDER_INDEX_BASENAME, '0.2.0');
eventsales_activate(EventSales_Integration_Health_Plugins::ORDER_INDEX_BASENAME);
eventsales_load_order_index_producer();
$GLOBALS['options']['eventsales_woo_order_index_key_id'] = 'kid';
$GLOBALS['options']['eventsales_woo_order_index_secret'] = 'local-secret';
$GLOBALS['wpdb'] = eventsales_mock_wpdb(['wp_eventsales_order_manifests', 'wp_eventsales_order_manifest_items']);
if (!defined('WC_VERSION')) {
    define('WC_VERSION', '8.0.0');
}
$GLOBALS['post_types'] = ['tc_events'];
eventsales_register_plugin(EventSales_Integration_Health_Plugins::ORDER_LINE_BASENAME, '0.1.0');
eventsales_activate(EventSales_Integration_Health_Plugins::ORDER_LINE_BASENAME);
eventsales_load_order_line_producer();

EventSales_Integration_Health_Snapshot::build();
EventSales_Integration_Health_Site_Health::test_catalog_feed();
EventSales_Integration_Health_Site_Health::test_order_index_feed();
EventSales_Integration_Health_Site_Health::register_debug([]);
T::same('no side effects during health evaluation', [], $GLOBALS['side_effects']);

// --- Source must not call mutation or network APIs ---

$health_source = (string) file_get_contents(dirname(__DIR__) . '/includes/integration-health.php');
$forbidden = [
    'wp_remote_get',
    'wp_remote_post',
    'update_option',
    'delete_option',
    'set_transient',
    'delete_transient',
    'as_enqueue_async_action',
    'as_schedule_single_action',
    'wp_insert_post',
    'wp_update_post',
];
foreach ($forbidden as $function) {
    T::ok('health source avoids ' . $function, preg_match('/\b' . $function . '\s*\(/', $health_source) !== 1);
}

T::ok('health source avoids wc_get_order', strpos($health_source, 'wc_get_order') === false);

// --- Sender ready path (scheduler stubs loaded in subprocess) ---

$sender_ready_script = "<?php\n"
    . "define('ABSPATH', __DIR__);\n"
    . 'define(\'WP_PLUGIN_DIR\', ' . var_export(WP_PLUGIN_DIR, true) . ");\n"
    . "\$GLOBALS['options'] = [];\n"
    . "\$GLOBALS['active_plugins'] = [];\n"
    . "\$GLOBALS['plugin_registry'] = [];\n"
    . "function get_plugins() { return \$GLOBALS['plugin_registry']; }\n"
    . "function is_plugin_active(\$basename) { return in_array(\$basename, \$GLOBALS['active_plugins'], true); }\n"
    . "function add_action(...\$args) { return true; }\n"
    . "function as_enqueue_async_action(...\$args) { return 1; }\n"
    . "function as_schedule_single_action(...\$args) { return 1; }\n"
    . "function wp_json_encode(\$value) { return json_encode(\$value); }\n"
    . "function __(\$text, \$domain = 'default') { return \$text; }\n"
    . eventsales_catalog_bootstrap_php()
    . "define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);\n"
    . "define('EVENTSALES_CATALOG_CHANGE_ENDPOINT', 'https://example.test/hooks/token');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_KEY_ID', 'kid');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SECRET', 'secret');\n"
    . 'require ' . var_export($EVENTSALES_HEALTH_INCLUDES, true) . ";\n"
    . "\$report = EventSales_Integration_Health_Catalog_Change_Sender::evaluate();\n"
    . "if (\$report['status'] !== EventSales_Integration_Health_States::READY) {\n"
    . "    fwrite(STDERR, 'expected READY got ' . \$report['status'] . PHP_EOL);\n"
    . "    exit(1);\n"
    . "}\n";

$sender_ready_path = sys_get_temp_dir() . '/eventsales-sender-ready-' . bin2hex(random_bytes(4)) . '.php';
file_put_contents($sender_ready_path, $sender_ready_script);
$sender_exit = 0;
passthru('php ' . escapeshellarg($sender_ready_path), $sender_exit);
@unlink($sender_ready_path);
T::ok('sender ready with scheduler', $sender_exit === 0);

// --- Inactive installed ---

eventsales_reset_test_state();
eventsales_register_plugin(EventSales_Integration_Health_Plugins::ORDER_INDEX_BASENAME, '0.2.0');
T::same('order index inactive', EventSales_Integration_Health_States::INACTIVE, EventSales_Integration_Health_Order_Index::evaluate()['status']);

T::site_health_result_shape(
    'catalog feed site health',
    EventSales_Integration_Health_Site_Health::test_catalog_feed(),
    EventSales_Integration_Health_Site_Health::TEST_CATALOG_FEED
);
T::site_health_result_shape(
    'catalog sender site health',
    EventSales_Integration_Health_Site_Health::test_catalog_change_sender(),
    EventSales_Integration_Health_Site_Health::TEST_CATALOG_CHANGE_SENDER
);
T::site_health_result_shape(
    'order index site health',
    EventSales_Integration_Health_Site_Health::test_order_index_feed(),
    EventSales_Integration_Health_Site_Health::TEST_ORDER_INDEX_FEED
);
T::site_health_result_shape(
    'order line site health',
    EventSales_Integration_Health_Site_Health::test_order_line_identity(),
    EventSales_Integration_Health_Site_Health::TEST_ORDER_LINE_IDENTITY
);

$test_ids = [
    EventSales_Integration_Health_Site_Health::test_catalog_feed()['test'],
    EventSales_Integration_Health_Site_Health::test_catalog_change_sender()['test'],
    EventSales_Integration_Health_Site_Health::test_order_index_feed()['test'],
    EventSales_Integration_Health_Site_Health::test_order_line_identity()['test'],
];
T::same('site health test ids are unique', 4, count(array_unique($test_ids)));

if (T::$failures !== []) {
    fwrite(STDERR, "FAILURES:\n- " . implode("\n- ", T::$failures) . "\n");
    exit(1);
}

fwrite(STDOUT, 'OK (' . T::$passes . " assertions)\n");
exit(0);
