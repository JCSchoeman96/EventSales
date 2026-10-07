<?php

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

/**
 * Read-only EventSales release discovery for the native WordPress updater.
 *
 * GitHub release metadata may tell administrators that a newer reviewed
 * release exists. This class never requests a plugin archive and never gives
 * WordPress a raw GitHub package URL. Verified package delivery may offer a
 * non-network sentinel when immutable release execution authority succeeds.
 */
final class EventSales_WP_Update_Discovery
{
    /** @var array<string, array{main_file: string}> */
    public const PLUGINS = [
        'eventsales-tickera-catalog-feed' => ['main_file' => 'eventsales-tickera-catalog-feed.php'],
        'eventsales-woo-order-index-feed' => ['main_file' => 'eventsales-woo-order-index-feed.php'],
        'eventsales-woo-order-line-identity' => ['main_file' => 'eventsales-woo-order-line-identity.php'],
        'eventsales-integration-health' => ['main_file' => 'eventsales-integration-health.php'],
    ];
    public const UPDATE_URI = 'https://github.com/JCSchoeman96/EventSales';
    public const UPDATE_HOOK = 'update_plugins_github.com';
    public const CACHE_KEY = 'eventsales_wp_update_discovery_v1';

    private const RELEASES_API_URL = 'https://api.github.com/repos/JCSchoeman96/EventSales/releases/latest';
    private const RELEASE_ASSET_API_PREFIX = 'https://api.github.com/repos/JCSchoeman96/EventSales/releases/assets/';
    private const POSITIVE_CACHE_TTL = 43200;
    private const NEGATIVE_CACHE_TTL = 900;
    private const HTTP_TIMEOUT = 5;
    private const MAX_REDIRECTS = 3;
    private const MAX_RELEASE_RESPONSE_SIZE = 262144;
    private const MAX_MANIFEST_SIZE = 1048576;
    private const USER_AGENT = 'EventSales-WordPress-Update-Discovery/1.0';

    private static bool $skip_remote_for_site_health_request = false;
    private static bool $request_cache_loaded = false;
    private static ?array $request_metadata = null;

    /** @var list<string> */
    private const FAILURE_CATEGORIES = [
        'remote_timeout',
        'remote_http_error',
        'release_missing',
        'manifest_missing',
        'manifest_invalid',
        'tag_mismatch',
        'redirect_rejected',
    ];

    public static function native_discovery_supported(string $wordpressVersion): bool
    {
        $wordpressVersion = trim($wordpressVersion);

        return preg_match('/^\d+(?:\.\d+){1,3}$/', $wordpressVersion) === 1
            && version_compare($wordpressVersion, '5.8', '>=');
    }

    public static function register_hooks(): void
    {
        if (!function_exists('add_filter')) {
            return;
        }

        self::reset_request_state();
        add_filter('debug_information', [self::class, 'register_debug'], 10, 1);

        if (function_exists('add_action')) {
            add_action('load-site-health.php', [self::class, 'disable_remote_for_site_health_request'], 1, 0);
        }

        global $wp_version;
        if (!isset($wp_version) || !is_string($wp_version) || !self::native_discovery_supported($wp_version)) {
            return;
        }

        add_filter(self::UPDATE_HOOK, [self::class, 'filter_update'], 10, 4);
    }

    /** Reset in-request memoization when WordPress starts a new request. */
    public static function reset_request_state(): void
    {
        self::$skip_remote_for_site_health_request = false;
        self::$request_cache_loaded = false;
        self::$request_metadata = null;
    }

    public static function disable_remote_for_site_health_request(): void
    {
        self::$skip_remote_for_site_health_request = true;
    }

    /**
     * @param mixed $update
     * @param array<string, mixed> $pluginData
     * @param array<int, string> $locales
     * @return mixed
     */
    public static function filter_update($update, array $pluginData, string $pluginFile, array $locales = [])
    {
        $slug = self::match_plugin($pluginData, $pluginFile);
        if ($slug === null) {
            return $update;
        }

        if (self::$skip_remote_for_site_health_request) {
            return $update;
        }

        global $wp_version;
        if (!isset($wp_version) || !is_string($wp_version) || !self::native_discovery_supported($wp_version)) {
            return $update;
        }

        $metadata = self::discover();
        if ($metadata === null || !isset($metadata['plugins'][$slug])) {
            return $update;
        }

        $installedVersion = $pluginData['Version'] ?? null;
        $remoteVersion = $metadata['plugins'][$slug]['version'];
        if (!self::valid_marketing_version($installedVersion)
            || version_compare($remoteVersion, (string) $installedVersion, '<=')) {
            return $update;
        }

        if (version_compare($wp_version, $metadata['requires_wordpress'], '<')
            || version_compare(PHP_VERSION, $metadata['requires_php'], '<')) {
            self::record_cached_category('wp_version_unsupported');

            return $update;
        }

        self::record_cached_category('update_available');

        $response = [
            'slug' => $slug,
            'version' => $remoteVersion,
            'url' => self::UPDATE_URI . '/releases/tag/' . $metadata['tag'],
            'requires_php' => $metadata['requires_php'],
            'autoupdate' => false,
        ];

        $packageOffer = $metadata['packages'][$slug] ?? null;
        $githubReleaseId = $metadata['github_release_id'] ?? null;
        if (is_array($packageOffer)
            && is_int($githubReleaseId)
            && $githubReleaseId > 0
            && isset($packageOffer['asset_id'])
            && is_int($packageOffer['asset_id'])
            && $packageOffer['asset_id'] > 0) {
            $response['package'] = EventSales_WP_Verified_Package_Delivery::build_sentinel(
                $githubReleaseId,
                $packageOffer['asset_id'],
                $slug
            );
        }

        return $response;
    }

    /**
     * @param array<string, mixed> $manifest
     * @return array{metadata?: array<string, mixed>, error?: string}
     */
    public static function validate_release_manifest_for_tag(array $manifest, string $releaseTag): array
    {
        return self::validate_manifest($manifest, $releaseTag);
    }

    /**
     * Add local facts from the discovery cache. This method never performs HTTP.
     *
     * @param array<string, mixed> $info
     * @return array<string, mixed>
     */
    public static function register_debug(array $info): array
    {
        $diagnostics = self::read_diagnostics();
        $fields = [
            'owner_active' => [
                'label' => 'Update discovery owner active',
                'value' => 'true',
            ],
            'native_discovery_supported' => [
                'label' => 'Native update discovery supported',
                'value' => $diagnostics['native_discovery_supported'] ? 'true' : 'false',
            ],
            'installed_event_sales_versions' => [
                'label' => 'Installed EventSales plugin versions',
                'value' => $diagnostics['installed_versions'],
            ],
            'last_metadata_check_category' => [
                'label' => 'Last update metadata check category',
                'value' => $diagnostics['category'],
            ],
            'last_metadata_check_time' => [
                'label' => 'Last update metadata check time (UTC)',
                'value' => $diagnostics['checked_at_gmt'] ?? 'n/a',
            ],
            'cached_suite_release_id' => [
                'label' => 'Cached EventSales suite release ID',
                'value' => $diagnostics['suite_release_id'] ?? 'n/a',
            ],
            'cached_remote_versions' => [
                'label' => 'Cached EventSales release versions',
                'value' => $diagnostics['remote_versions'] ?? 'n/a',
            ],
        ];

        if (isset($diagnostics['http_status'])) {
            $fields['last_http_status'] = [
                'label' => 'Last update metadata HTTP status',
                'value' => (string) $diagnostics['http_status'],
            ];
        }

        $info['eventsales_update_discovery'] = [
            'label' => 'EventSales update discovery',
            'fields' => $fields,
        ];

        return $info;
    }

    /**
     * @return array<string, mixed>
     */
    public static function read_diagnostics(?string $wordpressVersion = null): array
    {
        if ($wordpressVersion === null) {
            global $wp_version;
            $wordpressVersion = isset($wp_version) && is_string($wp_version) ? $wp_version : '';
        }

        $supported = self::native_discovery_supported($wordpressVersion);
        $cached = self::read_valid_cache();
        $result = [
            'native_discovery_supported' => $supported,
            'installed_versions' => self::format_installed_versions(),
            'category' => $supported ? 'never_checked' : 'wp_version_unsupported',
        ];

        if ($cached === null) {
            return $result;
        }

        if (isset($cached['checked_at_gmt'])) {
            $result['checked_at_gmt'] = $cached['checked_at_gmt'];
        }
        if (isset($cached['http_status'])) {
            $result['http_status'] = $cached['http_status'];
        }

        if (isset($cached['metadata'])) {
            $metadata = $cached['metadata'];
            $result['suite_release_id'] = $metadata['suite_release_id'];
            $result['remote_versions'] = self::format_remote_versions($metadata['plugins']);
            $result['category'] = $supported
                ? self::calculate_update_category($metadata, $cached['category'], $wordpressVersion)
                : 'wp_version_unsupported';

            return $result;
        }

        $result['category'] = $supported ? $cached['category'] : 'wp_version_unsupported';

        return $result;
    }

    /** @param array<string, mixed> $pluginData */
    private static function match_plugin(array $pluginData, string $pluginFile): ?string
    {
        if (($pluginData['UpdateURI'] ?? null) !== self::UPDATE_URI) {
            return null;
        }

        foreach (self::PLUGINS as $slug => $plugin) {
            if ($pluginFile === $slug . '/' . $plugin['main_file']) {
                return $slug;
            }
        }

        return null;
    }

    /** @return array<string, mixed>|null */
    private static function discover(): ?array
    {
        if (self::$request_cache_loaded) {
            return self::$request_metadata;
        }

        $cached = self::read_valid_cache();
        if ($cached !== null) {
            self::$request_cache_loaded = true;
            self::$request_metadata = $cached['metadata'] ?? null;

            return $cached['metadata'] ?? null;
        }

        $result = self::fetch_latest_release();
        if (isset($result['metadata'])) {
            $cache = [
                'category' => 'current',
                'checked_at_gmt' => gmdate('Y-m-d H:i:s'),
                'expires_at' => time() + self::POSITIVE_CACHE_TTL,
                'metadata' => $result['metadata'],
            ];
            set_site_transient(self::CACHE_KEY, $cache, self::POSITIVE_CACHE_TTL);
            self::$request_cache_loaded = true;
            self::$request_metadata = $result['metadata'];

            return $result['metadata'];
        }

        $cache = [
            'category' => $result['error'] ?? 'remote_http_error',
            'checked_at_gmt' => gmdate('Y-m-d H:i:s'),
        ];
        if (isset($result['http_status'])) {
            $cache['http_status'] = $result['http_status'];
        }
        set_site_transient(self::CACHE_KEY, $cache, self::NEGATIVE_CACHE_TTL);
        self::$request_cache_loaded = true;
        self::$request_metadata = null;

        return null;
    }

    /** @return array<string, mixed> */
    private static function fetch_latest_release(): array
    {
        $releaseResponse = self::request_json(self::RELEASES_API_URL, 'application/vnd.github+json', self::MAX_RELEASE_RESPONSE_SIZE);
        if (isset($releaseResponse['error'])) {
            return self::failure($releaseResponse['error'], $releaseResponse['http_status'] ?? null);
        }

        $release = $releaseResponse['json'];
        if (($release['draft'] ?? null) !== false || ($release['prerelease'] ?? null) !== false) {
            return self::failure('release_missing', $releaseResponse['http_status']);
        }

        $tag = $release['tag_name'] ?? null;
        if (!is_string($tag) || trim($tag) === '') {
            return self::failure('release_missing', $releaseResponse['http_status']);
        }

        $assets = $release['assets'] ?? null;
        if (!is_array($assets)) {
            return self::failure('manifest_missing', $releaseResponse['http_status']);
        }

        $manifestAssets = [];
        foreach ($assets as $asset) {
            if (is_array($asset) && ($asset['name'] ?? null) === 'release-manifest.json') {
                $manifestAssets[] = $asset;
            }
        }
        if ($manifestAssets === []) {
            return self::failure('manifest_missing', $releaseResponse['http_status']);
        }
        if (count($manifestAssets) !== 1) {
            return self::failure('manifest_invalid', $releaseResponse['http_status']);
        }

        $assetId = $manifestAssets[0]['id'] ?? null;
        if (!is_int($assetId) || $assetId < 1) {
            return self::failure('manifest_invalid', $releaseResponse['http_status']);
        }

        $assetResponse = self::request_manifest_asset($assetId);
        if (isset($assetResponse['error'])) {
            return self::failure($assetResponse['error'], $assetResponse['http_status'] ?? null);
        }

        $manifest = self::decode_json_object($assetResponse['body']);
        if ($manifest === null) {
            return self::failure('manifest_invalid', $assetResponse['http_status']);
        }

        $validation = self::validate_manifest($manifest, $tag);
        if (isset($validation['error'])) {
            return self::failure($validation['error'], $assetResponse['http_status']);
        }

        $metadata = $validation['metadata'];
        $releaseId = $release['id'] ?? null;
        if (is_int($releaseId) && $releaseId > 0) {
            $metadata['github_release_id'] = $releaseId;
            $packages = EventSales_WP_Verified_Package_Delivery::package_offers_for_release($release, $manifest);
            if ($packages !== []) {
                $metadata['packages'] = $packages;
            }
        }

        return [
            'metadata' => $metadata,
            'http_status' => $assetResponse['http_status'],
        ];
    }

    /** @return array<string, mixed> */
    private static function request_json(string $url, string $accept, int $limit): array
    {
        $response = self::safe_get($url, $accept, $limit);
        if (is_wp_error($response)) {
            return self::failure(self::wp_error_category($response));
        }

        $status = wp_remote_retrieve_response_code($response);
        if ($status === 404) {
            return self::failure('release_missing', $status);
        }
        if ($status >= 300 && $status < 400) {
            return self::failure('redirect_rejected', $status);
        }
        if ($status !== 200) {
            return self::failure('remote_http_error', $status);
        }

        $json = self::decode_json_object(wp_remote_retrieve_body($response));
        if ($json === null) {
            return self::failure('manifest_invalid', $status);
        }

        return ['json' => $json, 'http_status' => $status];
    }

    /** @return array<string, mixed>|WP_Error */
    private static function safe_get(string $url, string $accept, int $limit)
    {
        if (!function_exists('wp_safe_remote_get')) {
            return new WP_Error('http_api_unavailable');
        }

        return wp_safe_remote_get($url, [
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
        ]);
    }

    /** @return array<string, mixed> */
    private static function request_manifest_asset(int $assetId): array
    {
        $url = self::RELEASE_ASSET_API_PREFIX . $assetId;
        $redirects = 0;

        while (true) {
            $response = self::safe_get($url, 'application/octet-stream', self::MAX_MANIFEST_SIZE);
            if (is_wp_error($response)) {
                return self::failure(self::wp_error_category($response));
            }

            $status = wp_remote_retrieve_response_code($response);
            if ($status === 200) {
                return [
                    'body' => wp_remote_retrieve_body($response),
                    'http_status' => $status,
                ];
            }

            if (in_array($status, [301, 302, 303, 307, 308], true)) {
                if ($redirects >= self::MAX_REDIRECTS) {
                    return self::failure('redirect_rejected', $status);
                }

                $location = wp_remote_retrieve_header($response, 'location');
                if (!self::allowed_asset_redirect($location)) {
                    return self::failure('redirect_rejected', $status);
                }

                $url = $location;
                $redirects++;
                continue;
            }

            if ($status === 404) {
                return self::failure('manifest_missing', $status);
            }

            if ($status >= 300 && $status < 400) {
                return self::failure('redirect_rejected', $status);
            }

            return self::failure('remote_http_error', $status);
        }
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

    /** @param array<string, mixed> $manifest
     *  @return array<string, mixed>
     */
    private static function validate_manifest(array $manifest, string $releaseTag): array
    {
        if (($manifest['release_manifest_format_version'] ?? null) !== '1') {
            return self::failure('manifest_invalid');
        }

        $releaseId = $manifest['suite_release_id'] ?? null;
        if (!is_string($releaseId) || !self::valid_suite_release_id($releaseId)) {
            return self::failure('manifest_invalid');
        }

        $expectedTag = 'eventsales-wp-' . $releaseId;
        if (($manifest['suggested_tag'] ?? null) !== $expectedTag || $releaseTag !== $expectedTag) {
            return self::failure('tag_mismatch');
        }

        foreach (['source_commit', 'source_tree'] as $field) {
            if (!is_string($manifest[$field] ?? null) || preg_match('/^[0-9a-f]{40}$/', $manifest[$field]) !== 1) {
                return self::failure('manifest_invalid');
            }
        }

        foreach (['requires_wordpress', 'requires_php'] as $field) {
            if (!self::valid_dotted_version($manifest[$field] ?? null)) {
                return self::failure('manifest_invalid');
            }
        }

        $pluginRows = $manifest['plugins'] ?? null;
        if (!is_array($pluginRows) || count($pluginRows) !== count(self::PLUGINS)
            || array_keys($pluginRows) !== range(0, count(self::PLUGINS) - 1)) {
            return self::failure('manifest_invalid');
        }

        $validatedPlugins = [];
        foreach ($pluginRows as $row) {
            if (!is_array($row) || !is_string($row['slug'] ?? null) || !isset(self::PLUGINS[$row['slug']])) {
                return self::failure('manifest_invalid');
            }

            $slug = $row['slug'];
            if (isset($validatedPlugins[$slug])
                || ($row['main_file'] ?? null) !== self::PLUGINS[$slug]['main_file']
                || !self::valid_marketing_version($row['marketing_version'] ?? null)
                || !is_string($row['archive_sha256'] ?? null)
                || preg_match('/^[0-9a-f]{64}$/', $row['archive_sha256']) !== 1
                || ($row['archive_filename'] ?? null) !== $slug . '-' . $row['marketing_version'] . '.zip') {
                return self::failure('manifest_invalid');
            }

            if ($slug === 'eventsales-tickera-catalog-feed'
                && (!self::matches_pattern($row['catalog_schema_version'] ?? null, '/^\d{4}-\d{2}-\d{2}\.v[1-9][0-9]*$/')
                    || !self::matches_pattern($row['canonical_contract_version'] ?? null, '/^source_risk\.v[1-9][0-9]*$/')
                    || !self::matches_pattern($row['producer_version'] ?? null, '/^\d{4}-\d{2}-\d{2}\.[1-9][0-9]*$/')
                    || !self::matches_pattern($row['telemetry_version'] ?? null, '/^\d{4}-\d{2}-\d{2}\.v[1-9][0-9]*$/'))) {
                return self::failure('manifest_invalid');
            }

            if ($slug === 'eventsales-woo-order-index-feed'
                && !self::matches_pattern($row['order_index_schema_version'] ?? null, '/^\d{4}-\d{2}-\d{2}\.v[1-9][0-9]*$/')) {
                return self::failure('manifest_invalid');
            }

            $validatedPlugins[$slug] = ['version' => $row['marketing_version']];
        }

        if (count($validatedPlugins) !== count(self::PLUGINS)) {
            return self::failure('manifest_invalid');
        }

        return [
            'metadata' => [
                'suite_release_id' => $releaseId,
                'tag' => $expectedTag,
                'requires_wordpress' => $manifest['requires_wordpress'],
                'requires_php' => $manifest['requires_php'],
                'plugins' => $validatedPlugins,
            ],
        ];
    }

    private static function valid_suite_release_id(string $releaseId): bool
    {
        if (preg_match('/^(\d{4})\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])\.([1-9][0-9]*)$/', $releaseId, $matches) !== 1) {
            return false;
        }

        return checkdate((int) $matches[2], (int) $matches[3], (int) $matches[1]);
    }

    private static function valid_dotted_version($version): bool
    {
        return is_string($version) && preg_match('/^\d+(?:\.\d+){1,3}$/', $version) === 1;
    }

    private static function valid_marketing_version($version): bool
    {
        return self::valid_dotted_version($version);
    }

    private static function matches_pattern($value, string $pattern): bool
    {
        return is_string($value) && preg_match($pattern, $value) === 1;
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

    /** @return array<string, mixed> */
    private static function failure(string $category, ?int $httpStatus = null): array
    {
        $result = [
            'error' => in_array($category, self::FAILURE_CATEGORIES, true) ? $category : 'remote_http_error',
        ];
        if ($httpStatus !== null && $httpStatus >= 100 && $httpStatus <= 599) {
            $result['http_status'] = $httpStatus;
        }

        return $result;
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
            ? 'remote_timeout'
            : 'remote_http_error';
    }

    /** @return array<string, mixed>|null */
    private static function read_valid_cache(): ?array
    {
        $cached = get_site_transient(self::CACHE_KEY);
        if (!is_array($cached)
            || !is_string($cached['category'] ?? null)
            || !in_array($cached['category'], array_merge(self::FAILURE_CATEGORIES, ['current', 'update_available', 'wp_version_unsupported']), true)
            || !is_string($cached['checked_at_gmt'] ?? null)) {
            return null;
        }

        if (isset($cached['metadata'])) {
            if (!in_array($cached['category'], ['current', 'update_available', 'wp_version_unsupported'], true)
                || !is_int($cached['expires_at'] ?? null)
                || $cached['expires_at'] <= time()
                || !self::valid_cached_metadata($cached['metadata'])) {
                return null;
            }

            return $cached;
        }

        if (!in_array($cached['category'], self::FAILURE_CATEGORIES, true)) {
            return null;
        }
        if (isset($cached['http_status']) && (!is_int($cached['http_status']) || $cached['http_status'] < 100 || $cached['http_status'] > 599)) {
            return null;
        }

        return $cached;
    }

    /** @param mixed $metadata */
    private static function valid_cached_metadata($metadata): bool
    {
        if (!is_array($metadata)
            || !is_string($metadata['suite_release_id'] ?? null)
            || !self::valid_suite_release_id($metadata['suite_release_id'])
            || ($metadata['tag'] ?? null) !== 'eventsales-wp-' . $metadata['suite_release_id']
            || !self::valid_dotted_version($metadata['requires_wordpress'] ?? null)
            || !self::valid_dotted_version($metadata['requires_php'] ?? null)
            || !is_array($metadata['plugins'] ?? null)
            || count($metadata['plugins']) !== count(self::PLUGINS)) {
            return false;
        }

        foreach (self::PLUGINS as $slug => $_plugin) {
            if (!isset($metadata['plugins'][$slug]['version'])
                || !self::valid_marketing_version($metadata['plugins'][$slug]['version'])) {
                return false;
            }
        }

        if (isset($metadata['github_release_id'])
            && (!is_int($metadata['github_release_id']) || $metadata['github_release_id'] < 1)) {
            return false;
        }

        if (isset($metadata['packages'])) {
            if (!is_array($metadata['packages']) || count($metadata['packages']) !== count(self::PLUGINS)) {
                return false;
            }
            foreach (self::PLUGINS as $slug => $_plugin) {
                $offer = $metadata['packages'][$slug] ?? null;
                if (!is_array($offer)
                    || !is_int($offer['asset_id'] ?? null)
                    || $offer['asset_id'] < 1
                    || !is_int($offer['asset_size'] ?? null)
                    || $offer['asset_size'] < 1
                    || !is_string($offer['archive_sha256'] ?? null)
                    || preg_match('/^[0-9a-f]{64}$/', $offer['archive_sha256']) !== 1
                    || !is_string($offer['archive_filename'] ?? null)) {
                    return false;
                }
            }
        }

        return true;
    }

    /** @param array<string, mixed> $metadata */
    private static function calculate_update_category(array $metadata, string $fallback, string $wordpressVersion): string
    {
        if (!function_exists('get_plugins')) {
            return $fallback;
        }

        $installed = get_plugins();
        if (!is_array($installed)) {
            return $fallback;
        }

        $updateAvailable = false;
        foreach (self::PLUGINS as $slug => $plugin) {
            $basename = $slug . '/' . $plugin['main_file'];
            $installedVersion = $installed[$basename]['Version'] ?? null;
            if (self::valid_marketing_version($installedVersion)
                && version_compare($metadata['plugins'][$slug]['version'], (string) $installedVersion, '>')) {
                $updateAvailable = true;
                break;
            }
        }

        if (!$updateAvailable) {
            return 'current';
        }

        if (version_compare($wordpressVersion, $metadata['requires_wordpress'], '<')
            || version_compare(PHP_VERSION, $metadata['requires_php'], '<')) {
            return 'wp_version_unsupported';
        }

        return 'update_available';
    }

    private static function record_cached_category(string $category): void
    {
        $cached = self::read_valid_cache();
        if ($cached === null || !isset($cached['metadata'])) {
            return;
        }

        $cached['category'] = in_array($category, ['current', 'update_available', 'wp_version_unsupported'], true)
            ? $category
            : 'current';
        $remainingTtl = max(1, $cached['expires_at'] - time());
        set_site_transient(self::CACHE_KEY, $cached, $remainingTtl);
    }

    private static function format_installed_versions(): string
    {
        if (!function_exists('get_plugins')) {
            return 'n/a';
        }

        $plugins = get_plugins();
        if (!is_array($plugins)) {
            return 'n/a';
        }

        $versions = [];
        foreach (self::PLUGINS as $slug => $plugin) {
            $basename = $slug . '/' . $plugin['main_file'];
            if (isset($plugins[$basename]['Version']) && is_scalar($plugins[$basename]['Version'])) {
                $versions[] = $slug . ': ' . (string) $plugins[$basename]['Version'];
            }
        }

        return $versions === [] ? 'n/a' : implode(', ', $versions);
    }

    /** @param array<string, array{version: string}> $plugins */
    private static function format_remote_versions(array $plugins): string
    {
        $versions = [];
        foreach (self::PLUGINS as $slug => $_plugin) {
            if (isset($plugins[$slug]['version'])) {
                $versions[] = $slug . ': ' . $plugins[$slug]['version'];
            }
        }

        return $versions === [] ? 'n/a' : implode(', ', $versions);
    }
}
