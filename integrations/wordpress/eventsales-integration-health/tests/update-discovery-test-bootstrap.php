<?php

declare(strict_types=1);

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__);
}
if (!defined('WP_PLUGIN_DIR')) {
    define('WP_PLUGIN_DIR', dirname(__DIR__, 2));
}

$GLOBALS['filters'] ??= [];
$GLOBALS['http_responses'] ??= [];
$GLOBALS['http_requests'] ??= [];
$GLOBALS['site_transients'] ??= [];
$GLOBALS['transient_ttls'] ??= [];
$GLOBALS['transient_write_fail'] ??= false;
$GLOBALS['plugin_registry'] ??= [];
$GLOBALS['site_options'] ??= [];
$GLOBALS['temp_files'] ??= [];

if (!class_exists('WP_Error', false)) {
    final class WP_Error
    {
        public function __construct(public string $code)
        {
        }

        public function get_error_code(): string
        {
            return $this->code;
        }

        public function get_error_message(): string
        {
            return $this->code;
        }
    }
}

if (!function_exists('add_filter')) {
    function add_filter($hook, $callback, $priority = 10, $accepted_args = 1)
    {
        $GLOBALS['filters'][$hook][] = [
            'callback' => $callback,
            'priority' => $priority,
            'accepted_args' => $accepted_args,
        ];

        return true;
    }
}

if (!function_exists('add_action')) {
    function add_action($hook, $callback, $priority = 10, $accepted_args = 1)
    {
        return add_filter($hook, $callback, $priority, $accepted_args);
    }
}

if (!function_exists('get_plugins')) {
    function get_plugins()
    {
        return $GLOBALS['plugin_registry'];
    }
}

if (!function_exists('get_site_transient')) {
    function get_site_transient($name)
    {
        return $GLOBALS['site_transients'][$name] ?? false;
    }
}

if (!function_exists('set_site_transient')) {
    function set_site_transient($name, $value, $expiration = 0)
    {
        if ($GLOBALS['transient_write_fail']) {
            return false;
        }

        $GLOBALS['site_transients'][$name] = $value;
        $GLOBALS['transient_ttls'][$name] = $expiration;

        return true;
    }
}

if (!function_exists('get_site_option')) {
    function get_site_option(string $name, $default = false)
    {
        return $GLOBALS['site_options'][$name] ?? $default;
    }
}

if (!function_exists('update_site_option')) {
    function update_site_option(string $name, $value): bool
    {
        $GLOBALS['site_options'][$name] = $value;

        return true;
    }
}

if (!function_exists('wp_tempnam')) {
    function wp_tempnam(string $prefix = '')
    {
        $path = sys_get_temp_dir() . '/' . $prefix . uniqid('es', true) . '.zip';
        $GLOBALS['temp_files'][] = $path;

        return $path;
    }
}

if (!function_exists('wp_safe_remote_get')) {
    function wp_safe_remote_get($url, $args = [])
    {
        $GLOBALS['http_requests'][] = ['url' => $url, 'args' => $args];
        $response = array_shift($GLOBALS['http_responses']) ?? new WP_Error('unexpected_request');

        if (is_wp_error($response)) {
            return $response;
        }

        if (!empty($args['stream']) && isset($args['filename']) && is_string($args['filename'])) {
            $body = (string) ($response['body'] ?? '');
            $limit = (int) ($args['limit_response_size'] ?? PHP_INT_MAX);
            if (strlen($body) > $limit) {
                return new WP_Error('http_response_size_limit_exceeded');
            }
            file_put_contents($args['filename'], $body);
            $response['body'] = '';
        }

        return $response;
    }
}

if (!function_exists('is_wp_error')) {
    function is_wp_error($value)
    {
        return $value instanceof WP_Error;
    }
}

if (!function_exists('wp_remote_retrieve_response_code')) {
    function wp_remote_retrieve_response_code($response)
    {
        return (int) ($response['response']['code'] ?? 0);
    }
}

if (!function_exists('wp_remote_retrieve_header')) {
    function wp_remote_retrieve_header($response, $header)
    {
        foreach (($response['headers'] ?? []) as $name => $value) {
            if (strtolower((string) $name) === strtolower((string) $header)) {
                return $value;
            }
        }

        return '';
    }
}

if (!function_exists('wp_remote_retrieve_body')) {
    function wp_remote_retrieve_body($response)
    {
        return (string) ($response['body'] ?? '');
    }
}

if (!function_exists('__')) {
    function __($text, $domain = 'default')
    {
        return $text;
    }
}

function reset_update_discovery_state(): void
{
    $GLOBALS['filters'] = [];
    $GLOBALS['http_responses'] = [];
    $GLOBALS['http_requests'] = [];
    $GLOBALS['site_transients'] = [];
    $GLOBALS['transient_ttls'] = [];
    $GLOBALS['transient_write_fail'] = false;
    $GLOBALS['plugin_registry'] = [];

    if (class_exists(EventSales_WP_Update_Discovery::class, false)
        && method_exists(EventSales_WP_Update_Discovery::class, 'reset_request_state')) {
        EventSales_WP_Update_Discovery::reset_request_state();
    }
}

function http_response(int $status, string $body = '', array $headers = []): array
{
    return [
        'response' => ['code' => $status],
        'headers' => $headers,
        'body' => $body,
    ];
}

/** @return array<string, mixed> */
function valid_release_manifest(array $changes = []): array
{
    $plugins = [
        [
            'slug' => 'eventsales-tickera-catalog-feed',
            'main_file' => 'eventsales-tickera-catalog-feed.php',
            'marketing_version' => '0.1.2',
            'archive_filename' => 'eventsales-tickera-catalog-feed-0.1.2.zip',
            'archive_sha256' => str_repeat('a', 64),
            'catalog_schema_version' => '2026-08-07.v3',
            'canonical_contract_version' => 'source_risk.v3',
            'producer_version' => '2026-08-07.1',
            'telemetry_version' => '2026-10-02.v1',
        ],
        [
            'slug' => 'eventsales-woo-order-index-feed',
            'main_file' => 'eventsales-woo-order-index-feed.php',
            'marketing_version' => '0.2.2',
            'archive_filename' => 'eventsales-woo-order-index-feed-0.2.2.zip',
            'archive_sha256' => str_repeat('b', 64),
            'order_index_schema_version' => '2026-08-12.v1',
        ],
        [
            'slug' => 'eventsales-woo-order-line-identity',
            'main_file' => 'eventsales-woo-order-line-identity.php',
            'marketing_version' => '0.1.2',
            'archive_filename' => 'eventsales-woo-order-line-identity-0.1.2.zip',
            'archive_sha256' => str_repeat('c', 64),
        ],
        [
            'slug' => 'eventsales-integration-health',
            'main_file' => 'eventsales-integration-health.php',
            'marketing_version' => '0.1.2',
            'archive_filename' => 'eventsales-integration-health-0.1.2.zip',
            'archive_sha256' => str_repeat('d', 64),
        ],
    ];

    $manifest = [
        'release_manifest_format_version' => '1',
        'suite_release_id' => '2026.10.04.1',
        'suggested_tag' => 'eventsales-wp-2026.10.04.1',
        'source_commit' => str_repeat('1', 40),
        'source_tree' => str_repeat('2', 40),
        'requires_wordpress' => '5.6',
        'requires_php' => '8.0',
        'plugins' => $plugins,
    ];

    return array_replace($manifest, $changes);
}

/** @return array<string, mixed> */
function valid_release_metadata(array $changes = []): array
{
    $release = [
        'tag_name' => 'eventsales-wp-2026.10.04.1',
        'draft' => false,
        'prerelease' => false,
        'assets' => [
            ['id' => 101, 'name' => 'eventsales-tickera-catalog-feed-0.1.2.zip'],
            ['id' => 102, 'name' => 'eventsales-woo-order-index-feed-0.2.2.zip'],
            ['id' => 103, 'name' => 'eventsales-woo-order-line-identity-0.1.2.zip'],
            ['id' => 104, 'name' => 'eventsales-integration-health-0.1.2.zip'],
            ['id' => 123, 'name' => 'release-manifest.json'],
        ],
    ];

    return array_replace($release, $changes);
}

/** @return list<array<string, mixed>> */
function immutable_release_assets(array $manifest, array $overrides = []): array
{
    $assets = [];
    $id = 200;
    foreach ($manifest['plugins'] as $row) {
        $name = $row['archive_filename'];
        $assets[] = array_replace([
            'id' => $id++,
            'name' => $name,
            'state' => 'uploaded',
            'size' => 128,
            'digest' => 'sha256:' . $row['archive_sha256'],
        ], $overrides[$name] ?? []);
    }

    foreach (['manifest.json', 'SHA256SUMS', 'release-manifest.json', 'RELEASE_SHA256SUMS'] as $staticName) {
        $assets[] = array_replace([
            'id' => $id++,
            'name' => $staticName,
            'state' => 'uploaded',
            'size' => 64,
            'digest' => 'sha256:' . str_repeat('f', 64),
        ], $overrides[$staticName] ?? []);
    }

    return $assets;
}

function queue_valid_release(?string $manifestBody = null, array $releaseChanges = []): void
{
    $manifestBody ??= json_encode(valid_release_manifest(), JSON_UNESCAPED_SLASHES);
    $GLOBALS['http_responses'][] = http_response(
        200,
        json_encode(valid_release_metadata($releaseChanges), JSON_UNESCAPED_SLASHES)
    );
    $GLOBALS['http_responses'][] = http_response(200, $manifestBody);
}

function queue_immutable_release(?string $manifestBody = null, array $releaseChanges = []): void
{
    $manifestBody ??= json_encode(valid_release_manifest(), JSON_UNESCAPED_SLASHES);
    $manifest = json_decode($manifestBody, true);
    $release = valid_release_metadata(array_replace([
        'id' => 405862040,
        'immutable' => true,
        'assets' => immutable_release_assets($manifest),
    ], $releaseChanges));

    $GLOBALS['http_responses'][] = http_response(200, json_encode($release, JSON_UNESCAPED_SLASHES));
    $GLOBALS['http_responses'][] = http_response(200, $manifestBody);
}

function evaluate_plugin(string $slug, string $installedVersion = '0.1.1', ?string $uri = null, ?string $basename = null)
{
    $files = [
        'eventsales-tickera-catalog-feed' => 'eventsales-tickera-catalog-feed.php',
        'eventsales-woo-order-index-feed' => 'eventsales-woo-order-index-feed.php',
        'eventsales-woo-order-line-identity' => 'eventsales-woo-order-line-identity.php',
        'eventsales-integration-health' => 'eventsales-integration-health.php',
    ];
    $mainFile = $files[$slug] ?? 'unknown.php';
    $pluginFile = $basename ?? $slug . '/' . $mainFile;
    $pluginData = [
        'UpdateURI' => $uri ?? 'https://github.com/JCSchoeman96/EventSales',
        'Version' => $installedVersion,
        'Name' => 'EventSales test plugin',
    ];

    return EventSales_WP_Update_Discovery::filter_update(false, $pluginData, $pluginFile, []);
}

if (!class_exists('EventSales_WP_Update_Discovery', false)) {
    require dirname(__DIR__) . '/eventsales-integration-health.php';
}
