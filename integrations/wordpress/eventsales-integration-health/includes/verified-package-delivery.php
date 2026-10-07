<?php

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

/**
 * Verified immutable GitHub release package delivery for native WordPress updates.
 *
 * Offers non-network package sentinels only after release, manifest, and asset
 * authority succeed. Downloads and hashes the exact release asset on demand.
 */
final class EventSales_WP_Verified_Package_Delivery
{
    public const PACKAGE_SCHEME = 'eventsales-verified';
    public const DIAGNOSTICS_KEY = 'eventsales_wp_verified_package_v1';
    public const RELEASE_ASSET_API_PREFIX = 'https://api.github.com/repos/JCSchoeman96/EventSales/releases/assets/';
    public const RELEASE_BY_ID_API_PREFIX = 'https://api.github.com/repos/JCSchoeman96/EventSales/releases/';

    public const MAX_PACKAGE_BYTES = 16 * 1024 * 1024;
    public const HTTP_TIMEOUT = 30;
    public const MAX_REDIRECTS = 3;
    public const MAX_RELEASE_RESPONSE_SIZE = 262144;
    public const MAX_MANIFEST_SIZE = 1048576;
    public const USER_AGENT = 'EventSales-WordPress-Verified-Package/1.0';

    /** @var array<string, array{main_file: string}> */
    private const PLUGINS = [
        'eventsales-tickera-catalog-feed' => ['main_file' => 'eventsales-tickera-catalog-feed.php'],
        'eventsales-woo-order-index-feed' => ['main_file' => 'eventsales-woo-order-index-feed.php'],
        'eventsales-woo-order-line-identity' => ['main_file' => 'eventsales-woo-order-line-identity.php'],
        'eventsales-integration-health' => ['main_file' => 'eventsales-integration-health.php'],
    ];

    /** @var list<string> */
    private const PACKAGE_FAILURE_CATEGORIES = [
        'package_release_invalid',
        'package_asset_missing',
        'package_asset_invalid',
        'package_redirect_rejected',
        'package_download_failed',
        'package_too_large',
        'package_size_mismatch',
        'package_hash_mismatch',
        'package_verified',
    ];

    /** @var list<string> */
    private const SUITE_STATIC_ASSETS = [
        'manifest.json',
        'SHA256SUMS',
        'release-manifest.json',
        'RELEASE_SHA256SUMS',
    ];

    public static function register_hooks(): void
    {
        if (!function_exists('add_filter')) {
            return;
        }

        global $wp_version;
        if (!isset($wp_version) || !is_string($wp_version)
            || !EventSales_WP_Update_Discovery::native_discovery_supported($wp_version)) {
            return;
        }

        add_filter('upgrader_pre_download', [self::class, 'filter_pre_download'], 10, 4);
        add_filter('auto_update_plugin', [self::class, 'filter_auto_update_plugin'], 10, 2);
    }

    public static function is_sentinel(string $package): bool
    {
        return str_starts_with($package, self::PACKAGE_SCHEME . '://');
    }

    public static function build_sentinel(int $githubReleaseId, int $assetId, string $slug): string
    {
        return self::PACKAGE_SCHEME . '://' . $githubReleaseId . '/' . $assetId . '/' . $slug;
    }

    /**
     * @return array{github_release_id: int, asset_id: int, slug: string}|null
     */
    public static function parse_sentinel(string $package, string $expectedBasename): ?array
    {
        if (!self::is_sentinel($package)) {
            return null;
        }

        $path = substr($package, strlen(self::PACKAGE_SCHEME . '://'));
        if (!preg_match('#^([1-9][0-9]*)/([1-9][0-9]*)/([a-z0-9-]+)$#', $path, $matches)) {
            return null;
        }

        $slug = $matches[3];
        if (!isset(self::PLUGINS[$slug])) {
            return null;
        }

        $expectedPluginBasename = $slug . '/' . self::PLUGINS[$slug]['main_file'];
        if ($expectedBasename !== $expectedPluginBasename) {
            return null;
        }

        return [
            'github_release_id' => (int) $matches[1],
            'asset_id' => (int) $matches[2],
            'slug' => $slug,
        ];
    }

    /**
     * @param array<string, mixed> $release
     * @param array<string, mixed> $manifest
     * @return array<string, array{asset_id: int, asset_size: int, archive_sha256: string, archive_filename: string}>
     */
    public static function package_offers_for_release(array $release, array $manifest): array
    {
        if (($release['immutable'] ?? null) !== true) {
            return [];
        }

        $releaseId = $release['id'] ?? null;
        if (!is_int($releaseId) || $releaseId < 1) {
            return [];
        }

        if (($release['draft'] ?? null) !== false || ($release['prerelease'] ?? null) !== false) {
            return [];
        }

        $tag = $release['tag_name'] ?? null;
        if (!is_string($tag) || trim($tag) === '') {
            return [];
        }

        $pluginRows = $manifest['plugins'] ?? null;
        if (!is_array($pluginRows)) {
            return [];
        }

        $assets = $release['assets'] ?? null;
        if (!is_array($assets)) {
            return [];
        }

        $expectedNames = self::expected_asset_names($pluginRows);
        if (count($assets) !== count($expectedNames)) {
            return [];
        }

        /** @var array<string, array<string, mixed>> $assetsByName */
        $assetsByName = [];
        foreach ($assets as $asset) {
            if (!is_array($asset)) {
                return [];
            }

            $name = $asset['name'] ?? null;
            if (!is_string($name) || isset($assetsByName[$name])) {
                return [];
            }
            $assetsByName[$name] = $asset;
        }

        $actualNames = array_keys($assetsByName);
        sort($actualNames);
        $sortedExpected = $expectedNames;
        sort($sortedExpected);
        if ($actualNames !== $sortedExpected) {
            return [];
        }

        foreach (self::SUITE_STATIC_ASSETS as $staticName) {
            if (!self::valid_suite_static_asset($assetsByName[$staticName] ?? null)) {
                return [];
            }
        }

        $offers = [];
        foreach ($pluginRows as $row) {
            if (!is_array($row) || !is_string($row['slug'] ?? null)) {
                return [];
            }

            $slug = $row['slug'];
            $filename = $row['archive_filename'] ?? null;
            $sha = $row['archive_sha256'] ?? null;
            if (!is_string($filename) || !is_string($sha) || preg_match('/^[0-9a-f]{64}$/', $sha) !== 1) {
                return [];
            }

            $asset = $assetsByName[$filename] ?? null;
            $validated = self::valid_plugin_zip_asset($asset, $sha);
            if ($validated === null) {
                return [];
            }

            $offers[$slug] = [
                'asset_id' => $validated['asset_id'],
                'asset_size' => $validated['asset_size'],
                'archive_sha256' => $sha,
                'archive_filename' => $filename,
            ];
        }

        if (count($offers) !== count(self::PLUGINS)) {
            return [];
        }

        return $offers;
    }

    /**
     * @param mixed $update
     * @param object $item
     * @return mixed
     */
    public static function filter_auto_update_plugin($update, $item)
    {
        if (!is_object($item) || !isset($item->plugin) || !is_string($item->plugin)) {
            return $update;
        }

        foreach (self::PLUGINS as $slug => $plugin) {
            if ($item->plugin === $slug . '/' . $plugin['main_file']) {
                return false;
            }
        }

        return $update;
    }

    /**
     * @param mixed $reply
     * @param mixed $package
     * @param mixed $upgrader
     * @param array<string, mixed> $hook_extra
     * @return mixed
     */
    public static function filter_pre_download($reply, $package, $upgrader, array $hook_extra)
    {
        if ($reply !== false || !is_string($package) || !self::is_sentinel($package)) {
            return $reply;
        }

        if (class_exists('Plugin_Upgrader', false) && !($upgrader instanceof Plugin_Upgrader)) {
            return $reply;
        }

        $pluginBasename = $hook_extra['plugin'] ?? null;
        if (!is_string($pluginBasename) || $pluginBasename === '') {
            self::record_category('package_release_invalid');

            return new WP_Error('eventsales_package_invalid', 'EventSales package update requires a plugin target.');
        }

        $parsed = self::parse_sentinel($package, $pluginBasename);
        if ($parsed === null) {
            self::record_category('package_release_invalid');

            return new WP_Error('eventsales_package_invalid', 'EventSales package sentinel is invalid.');
        }

        if (isset($hook_extra['type']) && $hook_extra['type'] !== 'plugin') {
            self::record_category('package_release_invalid');

            return new WP_Error('eventsales_package_invalid', 'EventSales package updates apply only to plugins.');
        }

        if (isset($hook_extra['action']) && !in_array($hook_extra['action'], ['update', 'update-selected'], true)) {
            self::record_category('package_release_invalid');

            return new WP_Error('eventsales_package_invalid', 'EventSales package updates apply only to plugin updates.');
        }

        $verified = self::revalidate_and_download($parsed);
        if (is_wp_error($verified)) {
            return $verified;
        }

        self::record_category('package_verified');

        return $verified;
    }

    /**
     * @param array{github_release_id: int, asset_id: int, slug: string} $parsed
     * @return string|WP_Error
     */
    public static function revalidate_and_download(array $parsed)
    {
        $releaseResponse = self::request_json(
            self::RELEASE_BY_ID_API_PREFIX . $parsed['github_release_id'],
            'application/vnd.github+json',
            self::MAX_RELEASE_RESPONSE_SIZE
        );
        if (isset($releaseResponse['error'])) {
            self::record_category('package_release_invalid');

            return self::bounded_error('package_release_invalid', 'EventSales release could not be verified.');
        }

        $release = $releaseResponse['json'];
        if (($release['immutable'] ?? null) !== true
            || ($release['draft'] ?? null) !== false
            || ($release['prerelease'] ?? null) !== false) {
            self::record_category('package_release_invalid');

            return self::bounded_error('package_release_invalid', 'EventSales release is not an immutable public release.');
        }

        $tag = $release['tag_name'] ?? null;
        if (!is_string($tag) || trim($tag) === '') {
            self::record_category('package_release_invalid');

            return self::bounded_error('package_release_invalid', 'EventSales release tag is missing.');
        }

        $manifestBody = self::download_manifest_for_release($release);
        if ($manifestBody === null) {
            self::record_category('package_asset_missing');

            return self::bounded_error('package_asset_missing', 'EventSales release manifest could not be retrieved.');
        }

        $manifest = self::decode_json_object($manifestBody);
        if ($manifest === null) {
            self::record_category('package_release_invalid');

            return self::bounded_error('package_release_invalid', 'EventSales release manifest is invalid.');
        }

        $validation = EventSales_WP_Update_Discovery::validate_release_manifest_for_tag($manifest, $tag);
        if (isset($validation['error'])) {
            self::record_category('package_release_invalid');

            return self::bounded_error('package_release_invalid', 'EventSales release manifest failed validation.');
        }

        $offers = self::package_offers_for_release($release, $manifest);
        $offer = $offers[$parsed['slug']] ?? null;
        if ($offer === null
            || $offer['asset_id'] !== $parsed['asset_id']) {
            self::record_category('package_asset_invalid');

            return self::bounded_error('package_asset_invalid', 'EventSales release asset no longer matches the offered package.');
        }

        return self::download_and_verify_asset($parsed['asset_id'], $offer['asset_size'], $offer['archive_sha256']);
    }

    /** @return array<string, mixed> */
    public static function read_diagnostics(): array
    {
        $stored = get_site_option(self::DIAGNOSTICS_KEY, []);
        if (!is_array($stored) || !is_string($stored['category'] ?? null)) {
            return ['category' => 'never_verified'];
        }

        $category = $stored['category'];
        if (!in_array($category, self::PACKAGE_FAILURE_CATEGORIES, true)) {
            return ['category' => 'never_verified'];
        }

        $result = ['category' => $category];
        if (is_string($stored['checked_at_gmt'] ?? null)) {
            $result['checked_at_gmt'] = $stored['checked_at_gmt'];
        }

        return $result;
    }

    /** @param list<array<string, mixed>> $pluginRows */
    private static function expected_asset_names(array $pluginRows): array
    {
        $names = self::SUITE_STATIC_ASSETS;
        foreach ($pluginRows as $row) {
            if (!is_array($row) || !is_string($row['archive_filename'] ?? null)) {
                return [];
            }
            $names[] = $row['archive_filename'];
        }

        return $names;
    }

    /** @param mixed $asset */
    private static function valid_suite_static_asset($asset): bool
    {
        if (!is_array($asset)) {
            return false;
        }

        $id = $asset['id'] ?? null;
        if (!is_int($id) || $id < 1) {
            return false;
        }

        if (($asset['state'] ?? 'uploaded') !== 'uploaded') {
            return false;
        }

        $size = $asset['size'] ?? null;
        if (!is_int($size) || $size < 1 || $size > self::MAX_PACKAGE_BYTES) {
            return false;
        }

        $digest = $asset['digest'] ?? null;

        return is_string($digest) && preg_match('/^sha256:[0-9a-f]{64}$/', $digest) === 1;
    }

    /**
     * @param mixed $asset
     * @return array{asset_id: int, asset_size: int}|null
     */
    private static function valid_plugin_zip_asset($asset, string $expectedSha): ?array
    {
        if (!is_array($asset)) {
            return null;
        }

        $id = $asset['id'] ?? null;
        if (!is_int($id) || $id < 1) {
            return null;
        }

        if (($asset['state'] ?? null) !== 'uploaded') {
            return null;
        }

        $size = $asset['size'] ?? null;
        if (!is_int($size) || $size < 1 || $size > self::MAX_PACKAGE_BYTES) {
            return null;
        }

        $digest = $asset['digest'] ?? null;
        if (!is_string($digest) || $digest !== 'sha256:' . $expectedSha) {
            return null;
        }

        return ['asset_id' => $id, 'asset_size' => $size];
    }

    /** @return array<string, mixed> */
    private static function request_json(string $url, string $accept, int $limit): array
    {
        $response = self::safe_get($url, $accept, $limit, null);
        if (is_wp_error($response)) {
            return ['error' => self::wp_error_category($response)];
        }

        $status = wp_remote_retrieve_response_code($response);
        if ($status === 404) {
            return ['error' => 'package_release_invalid', 'http_status' => $status];
        }
        if ($status >= 300 && $status < 400) {
            return ['error' => 'package_redirect_rejected', 'http_status' => $status];
        }
        if ($status !== 200) {
            return ['error' => 'package_download_failed', 'http_status' => $status];
        }

        $json = self::decode_json_object(wp_remote_retrieve_body($response));
        if ($json === null) {
            return ['error' => 'package_release_invalid', 'http_status' => $status];
        }

        return ['json' => $json, 'http_status' => $status];
    }

    /** @param array<string, mixed> $release */
    private static function download_manifest_for_release(array $release): ?string
    {
        $assets = $release['assets'] ?? null;
        if (!is_array($assets)) {
            return null;
        }

        $manifestAssets = [];
        foreach ($assets as $asset) {
            if (is_array($asset) && ($asset['name'] ?? null) === 'release-manifest.json') {
                $manifestAssets[] = $asset;
            }
        }
        if (count($manifestAssets) !== 1) {
            return null;
        }

        $assetId = $manifestAssets[0]['id'] ?? null;
        if (!is_int($assetId) || $assetId < 1) {
            return null;
        }

        $response = self::request_binary_asset($assetId, self::MAX_MANIFEST_SIZE, null);
        if (isset($response['error'])) {
            return null;
        }

        return $response['body'] ?? null;
    }

    /**
     * @return array{body?: string, error?: string}
     */
    private static function request_binary_asset(int $assetId, int $limit, ?string $tempPath): array
    {
        $url = self::RELEASE_ASSET_API_PREFIX . $assetId;
        $redirects = 0;

        while (true) {
            $response = self::safe_get($url, 'application/octet-stream', $limit, $tempPath);
            if (is_wp_error($response)) {
                return ['error' => self::wp_error_category($response)];
            }

            $status = wp_remote_retrieve_response_code($response);
            if ($status === 200) {
                if ($tempPath !== null) {
                    return [];
                }

                return ['body' => wp_remote_retrieve_body($response)];
            }

            if (in_array($status, [301, 302, 303, 307, 308], true)) {
                if ($redirects >= self::MAX_REDIRECTS) {
                    return ['error' => 'package_redirect_rejected'];
                }

                $location = wp_remote_retrieve_header($response, 'location');
                if (!self::allowed_asset_redirect($location)) {
                    return ['error' => 'package_redirect_rejected'];
                }

                $url = $location;
                $redirects++;
                continue;
            }

            if ($status === 404) {
                return ['error' => 'package_asset_missing'];
            }

            if ($status >= 300 && $status < 400) {
                return ['error' => 'package_redirect_rejected'];
            }

            return ['error' => 'package_download_failed'];
        }
    }

    /**
     * @return string|WP_Error
     */
    private static function download_and_verify_asset(int $assetId, int $expectedSize, string $expectedSha)
    {
        if (!function_exists('wp_tempnam')) {
            self::record_category('package_download_failed');

            return self::bounded_error('package_download_failed', 'EventSales package download is unavailable.');
        }

        $tempPath = wp_tempnam('eventsales-verified-package');
        if ($tempPath === false || $tempPath === '') {
            self::record_category('package_download_failed');

            return self::bounded_error('package_download_failed', 'EventSales package download could not start.');
        }

        $download = self::request_binary_asset($assetId, self::MAX_PACKAGE_BYTES + 1, $tempPath);
        if (isset($download['error'])) {
            self::unlink_quiet($tempPath);
            self::record_category($download['error']);

            return self::bounded_error($download['error'], 'EventSales package download failed.');
        }

        if (!is_file($tempPath) || !is_readable($tempPath)) {
            self::unlink_quiet($tempPath);
            self::record_category('package_download_failed');

            return self::bounded_error('package_download_failed', 'EventSales package download failed.');
        }

        $localSize = filesize($tempPath);
        if ($localSize === false || $localSize < 1) {
            self::unlink_quiet($tempPath);
            self::record_category('package_download_failed');

            return self::bounded_error('package_download_failed', 'EventSales package download failed.');
        }

        if ($localSize > self::MAX_PACKAGE_BYTES) {
            self::unlink_quiet($tempPath);
            self::record_category('package_too_large');

            return self::bounded_error('package_too_large', 'EventSales package exceeds the allowed size.');
        }

        if ($localSize !== $expectedSize) {
            self::unlink_quiet($tempPath);
            self::record_category('package_size_mismatch');

            return self::bounded_error('package_size_mismatch', 'EventSales package size does not match the release asset.');
        }

        $hash = hash_file('sha256', $tempPath);
        if (!is_string($hash) || $hash !== $expectedSha) {
            self::unlink_quiet($tempPath);
            self::record_category('package_hash_mismatch');

            return self::bounded_error('package_hash_mismatch', 'EventSales package hash does not match the release manifest.');
        }

        self::record_category('package_verified');

        return $tempPath;
    }

    /** @return array<string, mixed>|WP_Error */
    private static function safe_get(string $url, string $accept, int $limit, ?string $tempPath)
    {
        if (!function_exists('wp_safe_remote_get')) {
            return new WP_Error('http_api_unavailable');
        }

        $parts = parse_url($url);
        if (!is_array($parts) || strtolower((string) ($parts['scheme'] ?? '')) !== 'https') {
            return new WP_Error('invalid_url');
        }

        $host = strtolower((string) ($parts['host'] ?? ''));
        if ($host !== 'api.github.com' && $host !== 'release-assets.githubusercontent.com') {
            return new WP_Error('invalid_url');
        }

        $args = [
            'timeout' => self::HTTP_TIMEOUT,
            'redirection' => 0,
            'blocking' => true,
            'headers' => [
                'Accept' => $accept,
            ],
            'cookies' => [],
            'sslverify' => true,
            'reject_unsafe_urls' => true,
            'limit_response_size' => $limit,
            'user-agent' => self::USER_AGENT,
        ];

        if ($tempPath !== null) {
            $args['stream'] = true;
            $args['filename'] = $tempPath;
        }

        return wp_safe_remote_get($url, $args);
    }

    private static function allowed_asset_redirect($location): bool
    {
        if (!is_string($location) || trim($location) !== $location || $location === '') {
            return false;
        }

        $parts = parse_url($location);
        if (!is_array($parts)
            || strtolower((string) ($parts['scheme'] ?? '')) !== 'https'
            || strtolower((string) ($parts['host'] ?? '')) !== 'release-assets.githubusercontent.com'
            || (isset($parts['port']) && $parts['port'] !== 443)
            || isset($parts['user'])
            || isset($parts['pass'])
            || isset($parts['fragment'])
            || !isset($parts['path'])
            || $parts['path'] === '') {
            return false;
        }

        return true;
    }

    /** @return array<string, mixed>|null */
    private static function decode_json_object(string $body): ?array
    {
        $decoded = json_decode($body, true, 512);
        if (json_last_error() !== JSON_ERROR_NONE || !is_array($decoded) || $decoded === []) {
            return null;
        }

        return $decoded;
    }

    private static function wp_error_category($error): string
    {
        $details = '';
        if (is_object($error) && method_exists($error, 'get_error_code')) {
            $details .= ' ' . (string) $error->get_error_code();
        }
        if (is_object($error) && method_exists($error, 'get_error_message')) {
            $details .= ' ' . (string) $error->get_error_message();
        }

        return preg_match('/timeout|timed[ _-]?out|curl error 28/i', $details) === 1
            ? 'package_download_failed'
            : 'package_download_failed';
    }

    private static function bounded_error(string $category, string $message): WP_Error
    {
        $safeCategory = in_array($category, self::PACKAGE_FAILURE_CATEGORIES, true)
            ? $category
            : 'package_download_failed';

        return new WP_Error('eventsales_' . $safeCategory, $message, ['category' => $safeCategory]);
    }

    private static function record_category(string $category): void
    {
        if (!in_array($category, self::PACKAGE_FAILURE_CATEGORIES, true)) {
            $category = 'package_download_failed';
        }

        update_site_option(self::DIAGNOSTICS_KEY, [
            'category' => $category,
            'checked_at_gmt' => gmdate('Y-m-d H:i:s'),
        ]);
    }

    private static function unlink_quiet(string $path): void
    {
        if (is_file($path)) {
            @unlink($path);
        }
    }
}
