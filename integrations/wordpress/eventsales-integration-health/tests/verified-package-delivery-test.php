<?php

declare(strict_types=1);

$GLOBALS['wp_version'] = '7.1.2';

require __DIR__ . '/update-discovery-test-bootstrap.php';

final class Plugin_Upgrader
{
}

final class Verified_Package_Test
{
    public static int $passes = 0;

    /** @var list<string> */
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
}

function reset_verified_package_state(): void
{
    reset_update_discovery_state();
    $GLOBALS['site_options'] = [];
    $GLOBALS['temp_files'] = [];
}

function apply_filters(string $hook, $value, ...$args)
{
    foreach ($GLOBALS['filters'][$hook] ?? [] as $filter) {
        $value = $filter['callback']($value, ...$args);
    }

    return $value;
}

$basename = 'eventsales-woo-order-line-identity/eventsales-woo-order-line-identity.php';
$lineAssetId = 202;
$sentinel = EventSales_WP_Verified_Package_Delivery::build_sentinel(405862040, $lineAssetId, 'eventsales-woo-order-line-identity');

Verified_Package_Test::ok('sentinel recognized', EventSales_WP_Verified_Package_Delivery::is_sentinel($sentinel));
Verified_Package_Test::same(
    'sentinel parses',
    ['github_release_id' => 405862040, 'asset_id' => $lineAssetId, 'slug' => 'eventsales-woo-order-line-identity'],
    EventSales_WP_Verified_Package_Delivery::parse_sentinel($sentinel, $basename)
);
Verified_Package_Test::ok('malformed scheme rejected', EventSales_WP_Verified_Package_Delivery::parse_sentinel('https://evil', $basename) === null);
Verified_Package_Test::ok('malformed ids rejected', EventSales_WP_Verified_Package_Delivery::parse_sentinel('eventsales-verified://0/1/slug', $basename) === null);
Verified_Package_Test::ok('wrong slug rejected', EventSales_WP_Verified_Package_Delivery::parse_sentinel($sentinel, 'eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php') === null);

reset_verified_package_state();
queue_immutable_release();
$update = evaluate_plugin('eventsales-woo-order-line-identity', '0.1.1');
Verified_Package_Test::ok('immutable release offers package sentinel', isset($update['package']));
Verified_Package_Test::same('package sentinel matches offer', $sentinel, $update['package'] ?? null);
Verified_Package_Test::ok(
    'package is not a raw GitHub URL',
    is_string($update['package'] ?? null)
        && !str_contains($update['package'], 'github.com')
        && !str_contains($update['package'], 'release-assets.githubusercontent.com')
);

reset_verified_package_state();
queue_valid_release();
$notifyOnly = evaluate_plugin('eventsales-woo-order-line-identity', '0.1.1');
Verified_Package_Test::ok('notification-only release has no package', !array_key_exists('package', $notifyOnly ?? []));

reset_verified_package_state();
queue_immutable_release(null, ['immutable' => false]);
$mutable = evaluate_plugin('eventsales-woo-order-line-identity', '0.1.1');
Verified_Package_Test::ok('non-immutable release has no package', !array_key_exists('package', $mutable ?? []));

reset_verified_package_state();
EventSales_WP_Verified_Package_Delivery::register_hooks();
Verified_Package_Test::ok('pre-download hook registered', isset($GLOBALS['filters']['upgrader_pre_download']));
Verified_Package_Test::ok('auto_update hook registered', isset($GLOBALS['filters']['auto_update_plugin']));

Verified_Package_Test::same('EventSales auto update denied', false, apply_filters('auto_update_plugin', true, (object) ['plugin' => $basename]));
Verified_Package_Test::same('unrelated auto update preserved true', true, apply_filters('auto_update_plugin', true, (object) ['plugin' => 'other/other.php']));
Verified_Package_Test::same('unrelated auto update preserved false', false, apply_filters('auto_update_plugin', false, (object) ['plugin' => 'other/other.php']));

$zipBytes = str_repeat('Z', 128);
$manifest = valid_release_manifest();
$manifest['plugins'][2]['archive_sha256'] = hash('sha256', $zipBytes);
$manifestBody = json_encode($manifest, JSON_UNESCAPED_SLASHES);
$zipSha = $manifest['plugins'][2]['archive_sha256'];
$releaseById = valid_release_metadata([
    'id' => 405862040,
    'immutable' => true,
    'assets' => immutable_release_assets($manifest),
]);
$parsed = EventSales_WP_Verified_Package_Delivery::parse_sentinel($sentinel, $basename);
if (!is_array($parsed)) {
    Verified_Package_Test::ok('parse sentinel for download tests', false);
    $parsed = ['github_release_id' => 0, 'asset_id' => 0, 'slug' => ''];
}

function queue_revalidate_download(string $manifestBody, array $releaseById, string $zipBytes): void
{
    $GLOBALS['http_responses'][] = http_response(200, json_encode($releaseById, JSON_UNESCAPED_SLASHES));
    $GLOBALS['http_responses'][] = http_response(200, $manifestBody);
    $GLOBALS['http_responses'][] = http_response(200, $zipBytes);
}

reset_verified_package_state();
queue_revalidate_download($manifestBody, $releaseById, $zipBytes);
$result = EventSales_WP_Verified_Package_Delivery::revalidate_and_download($parsed);
Verified_Package_Test::ok('HTTP 200 download verifies', is_string($result));
if (is_string($result)) {
    Verified_Package_Test::same('verified file hash', $zipSha, hash_file('sha256', $result));
}
Verified_Package_Test::same('package_verified category', 'package_verified', EventSales_WP_Verified_Package_Delivery::read_diagnostics()['category']);

reset_verified_package_state();
$GLOBALS['http_responses'][] = http_response(200, json_encode($releaseById, JSON_UNESCAPED_SLASHES));
$GLOBALS['http_responses'][] = http_response(200, $manifestBody);
$GLOBALS['http_responses'][] = http_response(302, '', ['Location' => 'https://release-assets.githubusercontent.com/repos/a/b/c']);
$GLOBALS['http_responses'][] = http_response(200, $zipBytes);
Verified_Package_Test::ok('HTTP 302 redirect accepted', is_string(EventSales_WP_Verified_Package_Delivery::revalidate_and_download($parsed)));

reset_verified_package_state();
$GLOBALS['http_responses'][] = http_response(200, json_encode($releaseById, JSON_UNESCAPED_SLASHES));
$GLOBALS['http_responses'][] = http_response(200, $manifestBody);
$GLOBALS['http_responses'][] = http_response(302, '', ['Location' => 'https://evil.example/asset']);
Verified_Package_Test::ok('wrong redirect host rejected', is_wp_error(EventSales_WP_Verified_Package_Delivery::revalidate_and_download($parsed)));

reset_verified_package_state();
queue_revalidate_download($manifestBody, $releaseById, $zipBytes);
Verified_Package_Test::ok('sentinel release id revalidated by id', is_string(EventSales_WP_Verified_Package_Delivery::revalidate_and_download($parsed)));

reset_verified_package_state();
$GLOBALS['http_responses'][] = http_response(404);
Verified_Package_Test::ok('missing release fails safely', is_wp_error(EventSales_WP_Verified_Package_Delivery::revalidate_and_download($parsed)));

reset_verified_package_state();
queue_revalidate_download($manifestBody, $releaseById, str_repeat('X', 129));
Verified_Package_Test::ok('oversized stream rejected', is_wp_error(EventSales_WP_Verified_Package_Delivery::revalidate_and_download($parsed)));
Verified_Package_Test::same('oversized category', 'package_size_mismatch', EventSales_WP_Verified_Package_Delivery::read_diagnostics()['category']);

reset_verified_package_state();
queue_revalidate_download($manifestBody, $releaseById, str_repeat('Y', 128));
Verified_Package_Test::ok('wrong hash rejected', is_wp_error(EventSales_WP_Verified_Package_Delivery::revalidate_and_download($parsed)));
Verified_Package_Test::same('hash mismatch category', 'package_hash_mismatch', EventSales_WP_Verified_Package_Delivery::read_diagnostics()['category']);

reset_verified_package_state();
$upgrader = new Plugin_Upgrader();
Verified_Package_Test::same(
    'unrelated package passes through',
    false,
    EventSales_WP_Verified_Package_Delivery::filter_pre_download(false, 'https://downloads.wordpress.org/plugin.zip', $upgrader, ['plugin' => $basename])
);

$diag = json_encode(EventSales_WP_Verified_Package_Delivery::read_diagnostics());
Verified_Package_Test::ok('diagnostics omit temp paths', !str_contains($diag, sys_get_temp_dir()));

if (Verified_Package_Test::$failures !== []) {
    fwrite(STDERR, "Verified package test failures:\n - " . implode("\n - ", Verified_Package_Test::$failures) . "\n");
    exit(1);
}

echo 'Verified package tests passed: ' . Verified_Package_Test::$passes . "\n";
