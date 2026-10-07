<?php

declare(strict_types=1);

$GLOBALS['wp_version'] = '5.6';
require __DIR__ . '/update-discovery-test-bootstrap.php';

final class Update_Discovery_Test
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

function assert_http_request_policy(): void
{
    foreach ($GLOBALS['http_requests'] as $index => $request) {
        $args = $request['args'];
        Update_Discovery_Test::same('request ' . $index . ' disables automatic redirects', 0, $args['redirection'] ?? null);
        Update_Discovery_Test::same('request ' . $index . ' uses five-second timeout', 5, $args['timeout'] ?? null);
        Update_Discovery_Test::same('request ' . $index . ' verifies TLS', true, $args['sslverify'] ?? null);
        Update_Discovery_Test::same('request ' . $index . ' sends no cookies', [], $args['cookies'] ?? null);
        Update_Discovery_Test::ok(
            'request ' . $index . ' sends no authorization header',
            !isset($args['headers']['Authorization'])
        );
        Update_Discovery_Test::same(
            'request ' . $index . ' sends a fixed safe user agent',
            'EventSales-WordPress-Update-Discovery/1.0',
            $args['user-agent'] ?? null
        );
    }
}

function assert_failure_category(string $label, array $responses, string $category): void
{
    reset_update_discovery_state();
    $GLOBALS['http_responses'] = $responses;

    $result = evaluate_plugin('eventsales-tickera-catalog-feed');
    Update_Discovery_Test::same($label . ' returns no update', false, $result);

    $diagnostics = EventSales_WP_Update_Discovery::read_diagnostics('7.1.2');
    Update_Discovery_Test::same(
        $label . ' category (' . (string) ($diagnostics['category'] ?? 'missing') . ')',
        $category,
        $diagnostics['category'] ?? null
    );
    Update_Discovery_Test::same(
        $label . ' negative cache TTL',
        900,
        $GLOBALS['transient_ttls']['eventsales_wp_update_discovery_v1'] ?? null
    );
}

Update_Discovery_Test::ok(
    'WordPress 5.6 discovery unsupported',
    !EventSales_WP_Update_Discovery::native_discovery_supported('5.6')
);
Update_Discovery_Test::ok(
    'WordPress 5.7 discovery unsupported',
    !EventSales_WP_Update_Discovery::native_discovery_supported('5.7')
);
Update_Discovery_Test::ok(
    'WordPress 5.8 discovery supported',
    EventSales_WP_Update_Discovery::native_discovery_supported('5.8')
);
Update_Discovery_Test::ok(
    'current WordPress discovery supported',
    EventSales_WP_Update_Discovery::native_discovery_supported('7.1.2')
);

foreach (['5.6', '5.7', '5.8', '7.1.2'] as $wpVersion) {
    reset_update_discovery_state();
    $GLOBALS['wp_version'] = $wpVersion;
    EventSales_WP_Update_Discovery::register_hooks();
    $registered = isset($GLOBALS['filters']['update_plugins_github.com']);
    Update_Discovery_Test::same(
        'native hook registration for WordPress ' . $wpVersion,
        version_compare($wpVersion, '5.8', '>='),
        $registered
    );
    if ($registered) {
        Update_Discovery_Test::same(
            'native hook accepts four arguments on WordPress ' . $wpVersion,
            4,
            $GLOBALS['filters']['update_plugins_github.com'][0]['accepted_args'] ?? null
        );
    }
}

$GLOBALS['wp_version'] = '7.1.2';
reset_update_discovery_state();
queue_valid_release();
$update = evaluate_plugin('eventsales-tickera-catalog-feed');
Update_Discovery_Test::same('valid newer release version', '0.1.2', $update['version'] ?? null);
Update_Discovery_Test::same(
    'details URL uses fixed repository and validated tag',
    'https://github.com/JCSchoeman96/EventSales/releases/tag/eventsales-wp-2026.10.04.1',
    $update['url'] ?? null
);
Update_Discovery_Test::same('response PHP floor', '8.0', $update['requires_php'] ?? null);
Update_Discovery_Test::same('response disables automatic updates', false, $update['autoupdate'] ?? null);
Update_Discovery_Test::ok('response omits package field', !array_key_exists('package', $update ?? []));
Update_Discovery_Test::same(
    'response has only notification fields',
    ['autoupdate', 'requires_php', 'slug', 'url', 'version'],
    (function () use ($update): array {
        $keys = array_keys($update ?? []);
        sort($keys);

        return $keys;
    })()
);
Update_Discovery_Test::same('positive cache TTL', 43200, $GLOBALS['transient_ttls']['eventsales_wp_update_discovery_v1'] ?? null);
Update_Discovery_Test::same('one release and one manifest request', 2, count($GLOBALS['http_requests']));
Update_Discovery_Test::same(
    'release lookup uses canonical GitHub API endpoint',
    'https://api.github.com/repos/JCSchoeman96/EventSales/releases/latest',
    $GLOBALS['http_requests'][0]['url'] ?? null
);
Update_Discovery_Test::same(
    'manifest retrieval uses fixed API asset endpoint',
    'https://api.github.com/repos/JCSchoeman96/EventSales/releases/assets/123',
    $GLOBALS['http_requests'][1]['url'] ?? null
);
Update_Discovery_Test::same(
    'release lookup accepts JSON only',
    'application/vnd.github+json',
    $GLOBALS['http_requests'][0]['args']['headers']['Accept'] ?? null
);
Update_Discovery_Test::same(
    'manifest request asks for asset bytes',
    'application/octet-stream',
    $GLOBALS['http_requests'][1]['args']['headers']['Accept'] ?? null
);
assert_http_request_policy();

foreach ([
    ['eventsales-tickera-catalog-feed', '0.1.1'],
    ['eventsales-woo-order-index-feed', '0.2.1'],
    ['eventsales-woo-order-line-identity', '0.1.1'],
    ['eventsales-integration-health', '0.1.1'],
] as [$slug, $version]) {
    Update_Discovery_Test::ok(
        'all four EventSales rows use cached release metadata for ' . $slug,
        is_array(evaluate_plugin($slug, $version))
    );
}
Update_Discovery_Test::same('four plugin rows share two HTTP requests', 2, count($GLOBALS['http_requests']));

reset_update_discovery_state();
queue_valid_release();
Update_Discovery_Test::same('same version returns no update', false, evaluate_plugin('eventsales-tickera-catalog-feed', '0.1.2'));
Update_Discovery_Test::same('older remote version returns no update', false, evaluate_plugin('eventsales-tickera-catalog-feed', '0.2.0'));
Update_Discovery_Test::same('malformed installed version returns no update', false, evaluate_plugin('eventsales-tickera-catalog-feed', 'latest'));
Update_Discovery_Test::same('comparison reused one cache', 2, count($GLOBALS['http_requests']));

foreach ([
    'newer WordPress floor' => ['requires_wordpress' => '99.0'],
    'newer PHP floor' => ['requires_php' => '99.0'],
] as $label => $manifestChanges) {
    reset_update_discovery_state();
    $manifest = valid_release_manifest($manifestChanges);
    queue_valid_release(json_encode($manifest, JSON_UNESCAPED_SLASHES));
    $GLOBALS['plugin_registry']['eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php'] = [
        'Version' => '0.1.1',
    ];
    Update_Discovery_Test::same(
        $label . ' produces no update response',
        false,
        evaluate_plugin('eventsales-tickera-catalog-feed')
    );
    Update_Discovery_Test::same(
        $label . ' is reported accurately in Site Health',
        'wp_version_unsupported',
        EventSales_WP_Update_Discovery::read_diagnostics('7.1.2')['category'] ?? null
    );
}

reset_update_discovery_state();
queue_valid_release();
evaluate_plugin('eventsales-tickera-catalog-feed');
$cachedPositive = $GLOBALS['site_transients']['eventsales_wp_update_discovery_v1'] ?? [];
$cachedPositive['expires_at'] = time() + 3600;
$GLOBALS['site_transients']['eventsales_wp_update_discovery_v1'] = $cachedPositive;
evaluate_plugin('eventsales-woo-order-index-feed', '0.2.1');
Update_Discovery_Test::ok(
    'positive cache check does not extend the original TTL',
    ($GLOBALS['transient_ttls']['eventsales_wp_update_discovery_v1'] ?? 43200) > 0
        && $GLOBALS['transient_ttls']['eventsales_wp_update_discovery_v1'] < 43200
);

reset_update_discovery_state();
$GLOBALS['transient_write_fail'] = true;
queue_valid_release();
foreach ([
    ['eventsales-tickera-catalog-feed', '0.1.1'],
    ['eventsales-woo-order-index-feed', '0.2.1'],
    ['eventsales-woo-order-line-identity', '0.1.1'],
    ['eventsales-integration-health', '0.1.1'],
] as [$slug, $installedVersion]) {
    Update_Discovery_Test::ok(
        'request-local metadata still reports update for ' . $slug,
        is_array(evaluate_plugin($slug, $installedVersion))
    );
}
Update_Discovery_Test::same('failed transient writes still make two remote requests total', 2, count($GLOBALS['http_requests']));
Update_Discovery_Test::ok(
    'failed transient writes leave no stored cache',
    !isset($GLOBALS['site_transients']['eventsales_wp_update_discovery_v1'])
);

reset_update_discovery_state();
queue_valid_release();
$unrelated = evaluate_plugin(
    'eventsales-tickera-catalog-feed',
    '0.1.1',
    'https://github.com/example/example',
    'some-other-plugin/some-other-plugin.php'
);
Update_Discovery_Test::same('unrelated github.com plugin passes through', false, $unrelated);
Update_Discovery_Test::same('unrelated github.com plugin makes no requests', 0, count($GLOBALS['http_requests']));

reset_update_discovery_state();
queue_valid_release();
Update_Discovery_Test::same(
    'EventSales basename with another Update URI is ignored',
    false,
    evaluate_plugin(
        'eventsales-tickera-catalog-feed',
        '0.1.1',
        'https://github.com/example/example'
    )
);
Update_Discovery_Test::same('wrong Update URI makes no requests', 0, count($GLOBALS['http_requests']));

reset_update_discovery_state();
queue_valid_release();
Update_Discovery_Test::same(
    'wrong EventSales basename ignored',
    false,
    evaluate_plugin(
        'eventsales-tickera-catalog-feed',
        '0.1.1',
        'https://github.com/JCSchoeman96/EventSales',
        'eventsales-tickera-catalog-feed/wrong.php'
    )
);
Update_Discovery_Test::same('wrong basename makes no requests', 0, count($GLOBALS['http_requests']));

assert_failure_category(
    'draft release rejected',
    [http_response(200, json_encode(valid_release_metadata(['draft' => true])))],
    'release_missing'
);
assert_failure_category(
    'prerelease rejected',
    [http_response(200, json_encode(valid_release_metadata(['prerelease' => true])))],
    'release_missing'
);
assert_failure_category(
    'missing manifest asset rejected',
    [http_response(200, json_encode(valid_release_metadata(['assets' => []])))],
    'manifest_missing'
);
assert_failure_category(
    'duplicate manifest assets rejected',
    [http_response(200, json_encode(valid_release_metadata(['assets' => [
        ['id' => 123, 'name' => 'release-manifest.json'],
        ['id' => 124, 'name' => 'release-manifest.json'],
    ]])))],
    'manifest_invalid'
);
assert_failure_category('invalid release JSON rejected', [http_response(200, '{')], 'manifest_invalid');
assert_failure_category(
    'invalid manifest JSON rejected',
    [
        http_response(200, json_encode(valid_release_metadata())),
        http_response(200, '{'),
    ],
    'manifest_invalid'
);

$invalidManifests = [
    'wrong release format' => ['release_manifest_format_version' => '2'],
    'invalid release id format' => ['suite_release_id' => '2026-10-04.1'],
    'invalid release calendar date' => ['suite_release_id' => '2026.02.31.1'],
    'tag mismatch' => ['suggested_tag' => 'eventsales-wp-2026.10.04.2'],
    'duplicate plugin slug' => (static function (): array {
        $manifest = valid_release_manifest();
        $manifest['plugins'][1]['slug'] = $manifest['plugins'][0]['slug'];

        return ['plugins' => $manifest['plugins']];
    })(),
    'missing plugin row' => (static function (): array {
        $manifest = valid_release_manifest();
        array_pop($manifest['plugins']);

        return ['plugins' => $manifest['plugins']];
    })(),
    'wrong canonical main file' => (static function (): array {
        $manifest = valid_release_manifest();
        $manifest['plugins'][0]['main_file'] = 'wrong.php';

        return ['plugins' => $manifest['plugins']];
    })(),
    'invalid archive SHA' => (static function (): array {
        $manifest = valid_release_manifest();
        $manifest['plugins'][0]['archive_sha256'] = 'bad';

        return ['plugins' => $manifest['plugins']];
    })(),
    'malformed remote marketing version' => (static function (): array {
        $manifest = valid_release_manifest();
        $manifest['plugins'][0]['marketing_version'] = 'not-a-version';

        return ['plugins' => $manifest['plugins']];
    })(),
    'malformed source commit' => ['source_commit' => 'ABCDEF'],
    'malformed source tree' => ['source_tree' => str_repeat('G', 40)],
    'malformed catalog protocol field' => (static function (): array {
        $manifest = valid_release_manifest();
        $manifest['plugins'][0]['catalog_schema_version'] = '2026.08.07.v3';

        return ['plugins' => $manifest['plugins']];
    })(),
    'malformed order index schema field' => (static function (): array {
        $manifest = valid_release_manifest();
        $manifest['plugins'][1]['order_index_schema_version'] = '2026-08-12';

        return ['plugins' => $manifest['plugins']];
    })(),
];

foreach ($invalidManifests as $label => $changes) {
    reset_update_discovery_state();
    queue_valid_release(json_encode(valid_release_manifest($changes), JSON_UNESCAPED_SLASHES));
    Update_Discovery_Test::same(
        $label . ' returns no update',
        false,
        evaluate_plugin('eventsales-tickera-catalog-feed')
    );
    Update_Discovery_Test::same(
        $label . ' is rejected as invalid manifest',
        $label === 'tag mismatch' ? 'tag_mismatch' : 'manifest_invalid',
        EventSales_WP_Update_Discovery::read_diagnostics('7.1.2')['category'] ?? null
    );
}

assert_failure_category(
    'release endpoint 404 rejected',
    [http_response(404)],
    'release_missing'
);
assert_failure_category(
    'release endpoint non-2xx rejected',
    [http_response(503)],
    'remote_http_error'
);
assert_failure_category(
    'release endpoint timeout rejected',
    [new WP_Error('connect_timeout')],
    'remote_timeout'
);

reset_update_discovery_state();
$GLOBALS['http_responses'] = [new WP_Error('connect_timeout')];
Update_Discovery_Test::same(
    'first plugin gets no update after timeout',
    false,
    evaluate_plugin('eventsales-tickera-catalog-feed')
);
foreach ([
    'eventsales-woo-order-index-feed',
    'eventsales-woo-order-line-identity',
    'eventsales-integration-health',
] as $slug) {
    Update_Discovery_Test::same(
        'negative cache suppresses retry for ' . $slug,
        false,
        evaluate_plugin($slug)
    );
}
Update_Discovery_Test::same('four plugin rows share one cached timeout', 1, count($GLOBALS['http_requests']));

reset_update_discovery_state();
$GLOBALS['transient_write_fail'] = true;
$GLOBALS['http_responses'] = [new WP_Error('connect_timeout')];
foreach ([
    'eventsales-tickera-catalog-feed',
    'eventsales-woo-order-index-feed',
    'eventsales-woo-order-line-identity',
    'eventsales-integration-health',
] as $slug) {
    Update_Discovery_Test::same(
        'request-local negative result suppresses retry for ' . $slug,
        false,
        evaluate_plugin($slug)
    );
}
Update_Discovery_Test::same('failed negative-cache write still makes one request', 1, count($GLOBALS['http_requests']));

assert_failure_category(
    'metadata redirect rejected',
    [http_response(302, '', ['Location' => 'https://release-assets.githubusercontent.com/metadata'])],
    'redirect_rejected'
);
assert_failure_category(
    'GitHub release tag mismatch rejected',
    [
        http_response(200, json_encode(valid_release_metadata(['tag_name' => 'eventsales-wp-2026.10.04.2']))),
        http_response(200, json_encode(valid_release_manifest(), JSON_UNESCAPED_SLASHES)),
    ],
    'tag_mismatch'
);

reset_update_discovery_state();
$GLOBALS['http_responses'] = [
    http_response(200, json_encode(valid_release_metadata())),
    http_response(302, '', ['Location' => 'https://release-assets.githubusercontent.com/path/manifest?token=temporary']),
    http_response(200, json_encode(valid_release_manifest(), JSON_UNESCAPED_SLASHES)),
];
$redirectedUpdate = evaluate_plugin('eventsales-tickera-catalog-feed');
Update_Discovery_Test::same('allowed GitHub asset redirect accepted', '0.1.2', $redirectedUpdate['version'] ?? null);
Update_Discovery_Test::same('allowed redirect made three HTTP calls', 3, count($GLOBALS['http_requests']));

assert_failure_category(
    'API asset redirect to unexpected host rejected',
    [
        http_response(200, json_encode(valid_release_metadata())),
        http_response(302, '', ['Location' => 'https://attacker.example/manifest']),
    ],
    'redirect_rejected'
);
assert_failure_category(
    'allowed asset host redirect to unexpected host rejected',
    [
        http_response(200, json_encode(valid_release_metadata())),
        http_response(302, '', ['Location' => 'https://release-assets.githubusercontent.com/path/manifest?token=temporary']),
        http_response(302, '', ['Location' => 'https://attacker.example/manifest']),
    ],
    'redirect_rejected'
);
assert_failure_category(
    'too many redirects rejected',
    [
        http_response(200, json_encode(valid_release_metadata())),
        http_response(302, '', ['Location' => 'https://release-assets.githubusercontent.com/1']),
        http_response(302, '', ['Location' => 'https://release-assets.githubusercontent.com/2']),
        http_response(302, '', ['Location' => 'https://release-assets.githubusercontent.com/3']),
        http_response(302, '', ['Location' => 'https://release-assets.githubusercontent.com/4']),
    ],
    'redirect_rejected'
);

reset_update_discovery_state();
queue_valid_release();
evaluate_plugin('eventsales-tickera-catalog-feed');
$requestsBeforeSiteHealth = count($GLOBALS['http_requests']);
$debugInfo = EventSales_WP_Update_Discovery::register_debug([]);
Update_Discovery_Test::ok('Site Health includes update discovery details', isset($debugInfo['eventsales_update_discovery']));
Update_Discovery_Test::same(
    'Site Health reports cached release id',
    '2026.10.04.1',
    $debugInfo['eventsales_update_discovery']['fields']['cached_suite_release_id']['value'] ?? null
);
Update_Discovery_Test::same(
    'Site Health rendering makes no remote calls',
    $requestsBeforeSiteHealth,
    count($GLOBALS['http_requests'])
);

reset_update_discovery_state();
$GLOBALS['wp_version'] = '7.1.2';
EventSales_WP_Update_Discovery::register_hooks();
$loadSiteHealthHook = $GLOBALS['filters']['load-site-health.php'][0]['callback'] ?? null;
Update_Discovery_Test::ok('Site Health request guard is registered', is_callable($loadSiteHealthHook));
if (is_callable($loadSiteHealthHook)) {
    call_user_func($loadSiteHealthHook);
}
queue_valid_release();
Update_Discovery_Test::same(
    'core update check on Site Health does not fetch release metadata',
    false,
    evaluate_plugin('eventsales-tickera-catalog-feed')
);
Update_Discovery_Test::same('Site Health update check makes no HTTP requests', 0, count($GLOBALS['http_requests']));
$siteHealthDebug = EventSales_WP_Update_Discovery::register_debug([]);
Update_Discovery_Test::same(
    'Site Health stays never checked without an earlier cache',
    'never_checked',
    $siteHealthDebug['eventsales_update_discovery']['fields']['last_metadata_check_category']['value'] ?? null
);

reset_update_discovery_state();
$GLOBALS['wp_version'] = '5.7';
EventSales_WP_Update_Discovery::register_hooks();
$unsupportedDebug = EventSales_WP_Update_Discovery::register_debug([]);
Update_Discovery_Test::same(
    'unsupported WordPress reports capability unavailable',
    'wp_version_unsupported',
    $unsupportedDebug['eventsales_update_discovery']['fields']['last_metadata_check_category']['value'] ?? null
);
Update_Discovery_Test::same('unsupported WordPress makes no remote calls', 0, count($GLOBALS['http_requests']));

$GLOBALS['wp_version'] = '7.1.2';
reset_update_discovery_state();
queue_immutable_release();
$immutableUpdate = evaluate_plugin('eventsales-woo-order-line-identity', '0.1.1');
Update_Discovery_Test::ok('immutable release includes verified sentinel package', isset($immutableUpdate['package']));
Update_Discovery_Test::ok(
    'package field never contains raw GitHub ZIP URL',
    is_string($immutableUpdate['package'] ?? null)
        && EventSales_WP_Verified_Package_Delivery::is_sentinel($immutableUpdate['package'])
);

reset_update_discovery_state();
$manifest = valid_release_manifest();
$badDigestManifest = json_encode($manifest, JSON_UNESCAPED_SLASHES);
queue_immutable_release($badDigestManifest, [
    'assets' => immutable_release_assets($manifest, [
        'eventsales-woo-order-line-identity-0.1.2.zip' => ['digest' => 'sha256:' . str_repeat('0', 64)],
    ]),
]);
$digestMismatch = evaluate_plugin('eventsales-woo-order-line-identity', '0.1.1');
Update_Discovery_Test::ok('digest mismatch omits package', !array_key_exists('package', $digestMismatch ?? []));
Update_Discovery_Test::same('digest mismatch still notifies', '0.1.2', $digestMismatch['version'] ?? null);

if (Update_Discovery_Test::$failures !== []) {
    fwrite(STDERR, "Update discovery test failures:\n - " . implode("\n - ", Update_Discovery_Test::$failures) . "\n");
    exit(1);
}

echo 'Update discovery tests passed: ' . Update_Discovery_Test::$passes . "\n";
