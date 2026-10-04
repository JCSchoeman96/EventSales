<?php

declare(strict_types=1);

$validator = __DIR__ . '/published-release-validate.php';
if (is_file($validator)) {
    require_once $validator;
}

final class PublishedReleaseTest
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

    public static function finish(): void
    {
        if (self::$failures !== []) {
            fwrite(STDERR, "plugin-published-release-test failures:\n");
            foreach (self::$failures as $failure) {
                fwrite(STDERR, "  - {$failure}\n");
            }
            exit(1);
        }

        fwrite(STDOUT, 'plugin-published-release-test: ' . self::$passes . " assertions passed\n");
    }
}

if (!function_exists('published_release_validation_errors')) {
    PublishedReleaseTest::ok('published release validator is available', false);
    PublishedReleaseTest::finish();
    exit(1);
}

$redirectValidatorAvailable = function_exists('published_release_redirect_url_allowed');
PublishedReleaseTest::ok('asset redirect URL validator is available', $redirectValidatorAvailable);
if ($redirectValidatorAvailable) {
    PublishedReleaseTest::ok(
        'signed HTTPS URL from the exact GitHub asset host is allowed',
        published_release_redirect_url_allowed('https://release-assets.githubusercontent.com/path?X-Amz-Signature=fixture')
    );
    PublishedReleaseTest::ok(
        'explicit default HTTPS port is allowed',
        published_release_redirect_url_allowed('https://release-assets.githubusercontent.com:443/path')
    );
    foreach ([
        'http://release-assets.githubusercontent.com/path',
        'https://release-assets.githubusercontent.com.attacker.example/path',
        'https://user@release-assets.githubusercontent.com/path',
        'https://release-assets.githubusercontent.com:444/path',
        'https://release-assets.githubusercontent.com/path#fragment',
        "https://release-assets.githubusercontent.com/path\nX-Injected: yes",
        'https://release-assets.githubusercontent.com\\@attacker.example/path',
    ] as $unsafeRedirectUrl) {
        PublishedReleaseTest::ok(
            'unsafe asset redirect URL is rejected: ' . parse_url($unsafeRedirectUrl, PHP_URL_SCHEME),
            !published_release_redirect_url_allowed($unsafeRedirectUrl)
        );
    }
}

/** @return array<string, mixed> */
function published_release_fixture(): array
{
    $root = sys_get_temp_dir() . '/es-wp-published-release-' . bin2hex(random_bytes(6));
    $assetsDir = $root . '/assets';
    mkdir($assetsDir, 0777, true);

    $sourceCommit = str_repeat('a', 40);
    $sourceTree = str_repeat('b', 40);
    $canonicalMainAtBuild = str_repeat('c', 40);
    $releaseId = '2026.10.04.1';
    $tag = 'eventsales-wp-' . $releaseId;
    $plugins = [
        [
            'slug' => 'eventsales-tickera-catalog-feed',
            'main_file' => 'eventsales-tickera-catalog-feed.php',
            'marketing_version' => '0.1.2',
            'archive_filename' => 'eventsales-tickera-catalog-feed-0.1.2.zip',
            'archive_sha256' => '',
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
            'archive_sha256' => '',
            'order_index_schema_version' => '2026-08-12.v1',
        ],
        [
            'slug' => 'eventsales-woo-order-line-identity',
            'main_file' => 'eventsales-woo-order-line-identity.php',
            'marketing_version' => '0.1.2',
            'archive_filename' => 'eventsales-woo-order-line-identity-0.1.2.zip',
            'archive_sha256' => '',
        ],
        [
            'slug' => 'eventsales-integration-health',
            'main_file' => 'eventsales-integration-health.php',
            'marketing_version' => '0.1.2',
            'archive_filename' => 'eventsales-integration-health-0.1.2.zip',
            'archive_sha256' => '',
        ],
    ];

    foreach ($plugins as $index => &$plugin) {
        $bytes = 'synthetic plugin archive ' . $plugin['slug'];
        file_put_contents($assetsDir . '/' . $plugin['archive_filename'], $bytes);
        $plugin['archive_sha256'] = hash('sha256', $bytes);
    }
    unset($plugin);

    $releaseManifest = [
        'release_manifest_format_version' => '1',
        'suite_release_id' => $releaseId,
        'suggested_tag' => $tag,
        'source_commit' => $sourceCommit,
        'source_tree' => $sourceTree,
        'canonical_main_at_build' => $canonicalMainAtBuild,
        'suite_manifest_git_path' => 'integrations/wordpress/eventsales-plugin-suite.json',
        'distribution_format_version' => '1',
        'requires_wordpress' => '5.6',
        'requires_php' => '8.0',
        'plugins' => $plugins,
        'deterministic_source_content' => true,
        'deterministic_archive_bytes' => true,
    ];
    $distributionManifest = [
        'distribution_format_version' => '1',
        'source_commit' => $sourceCommit,
        'source_tree' => $sourceTree,
        'suite_manifest_git_path' => 'integrations/wordpress/eventsales-plugin-suite.json',
        'deterministic_source_content' => true,
        'deterministic_archive_bytes' => true,
        'plugins' => $plugins,
    ];

    file_put_contents(
        $assetsDir . '/manifest.json',
        json_encode($distributionManifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL
    );
    file_put_contents(
        $assetsDir . '/release-manifest.json',
        json_encode($releaseManifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL
    );

    $pluginSums = [];
    foreach ($plugins as $plugin) {
        $pluginSums[] = $plugin['archive_sha256'] . '  ' . $plugin['archive_filename'];
    }
    sort($pluginSums);
    file_put_contents($assetsDir . '/SHA256SUMS', implode(PHP_EOL, $pluginSums) . PHP_EOL);

    $releaseSumFiles = array_merge(
        array_column($plugins, 'archive_filename'),
        ['manifest.json', 'release-manifest.json']
    );
    sort($releaseSumFiles);
    $releaseSums = [];
    foreach ($releaseSumFiles as $filename) {
        $releaseSums[] = hash_file('sha256', $assetsDir . '/' . $filename) . '  ' . $filename;
    }
    file_put_contents($assetsDir . '/RELEASE_SHA256SUMS', implode(PHP_EOL, $releaseSums) . PHP_EOL);

    $assetNames = [
        'eventsales-tickera-catalog-feed-0.1.2.zip',
        'eventsales-woo-order-index-feed-0.2.2.zip',
        'eventsales-woo-order-line-identity-0.1.2.zip',
        'eventsales-integration-health-0.1.2.zip',
        'manifest.json',
        'SHA256SUMS',
        'release-manifest.json',
        'RELEASE_SHA256SUMS',
    ];
    $assets = [];
    foreach ($assetNames as $index => $name) {
        $assets[] = [
            'id' => 100 + $index,
            'name' => $name,
            'digest' => 'sha256:' . hash_file('sha256', $assetsDir . '/' . $name),
            'browser_download_url' => 'https://release-assets.githubusercontent.com/?X-Amz-Signature=fixture-secret',
        ];
    }

    return [
        'root' => $root,
        'assets_dir' => $assetsDir,
        'tag' => $tag,
        'source_commit' => $sourceCommit,
        'source_tree' => $sourceTree,
        'release' => [
            'url' => 'https://api.github.com/repos/JCSchoeman96/EventSales/releases/1',
            'html_url' => 'https://github.com/JCSchoeman96/EventSales/releases/tag/' . $tag,
            'tag_name' => $tag,
            'draft' => false,
            'prerelease' => false,
            'immutable' => true,
            'assets' => $assets,
        ],
        'tag_target' => $sourceCommit,
        'commit_tree' => $sourceTree,
        'ancestry' => [
            'source_to_main' => 'identical',
            'source_to_build' => 'identical',
            'build_to_main' => 'identical',
        ],
    ];
}

/** @param array<string, mixed> $fixture
 *  @param array<string, mixed>|null $release
 *  @param array<string, string>|null $ancestry
 *  @return list<string>
 */
function verify_published_fixture(
    array $fixture,
    ?array $release = null,
    ?string $requestedTag = null,
    ?string $tagTarget = null,
    ?string $commitTree = null,
    ?array $ancestry = null,
    ?string $candidateDir = null
): array {
    return published_release_validation_errors(
        $release ?? $fixture['release'],
        $requestedTag ?? $fixture['tag'],
        $tagTarget ?? $fixture['tag_target'],
        $commitTree ?? $fixture['commit_tree'],
        $ancestry ?? $fixture['ancestry'],
        $fixture['assets_dir'],
        $candidateDir
    );
}

function remove_published_fixture(array $fixture): void
{
    $iterator = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($fixture['root'], FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($iterator as $item) {
        $item->isDir() ? rmdir($item->getPathname()) : unlink($item->getPathname());
    }
    rmdir($fixture['root']);
}

/** @param array<string, mixed> $fixture */
function refresh_fixture_release_authorities(array &$fixture): void
{
    $sumFiles = [
        'eventsales-tickera-catalog-feed-0.1.2.zip',
        'eventsales-woo-order-index-feed-0.2.2.zip',
        'eventsales-woo-order-line-identity-0.1.2.zip',
        'eventsales-integration-health-0.1.2.zip',
        'manifest.json',
        'release-manifest.json',
    ];
    sort($sumFiles);

    $sumLines = [];
    foreach ($sumFiles as $name) {
        $sumLines[] = hash_file('sha256', $fixture['assets_dir'] . '/' . $name) . '  ' . $name;
    }
    file_put_contents($fixture['assets_dir'] . '/RELEASE_SHA256SUMS', implode(PHP_EOL, $sumLines) . PHP_EOL);

    foreach ($fixture['release']['assets'] as &$asset) {
        $asset['digest'] = 'sha256:' . hash_file('sha256', $fixture['assets_dir'] . '/' . $asset['name']);
    }
    unset($asset);
}

$fixture = published_release_fixture();
PublishedReleaseTest::ok(
    'public immutable release fixture validates without a token',
    verify_published_fixture($fixture) === []
);

$wrongRepository = $fixture['release'];
$wrongRepository['url'] = 'https://api.github.com/repos/another-owner/EventSales/releases/1';
$wrongRepository['html_url'] = 'https://github.com/another-owner/EventSales/releases/tag/' . $fixture['tag'];
PublishedReleaseTest::ok('wrong repository is rejected', verify_published_fixture($fixture, $wrongRepository) !== []);

$draft = $fixture['release'];
$draft['draft'] = true;
PublishedReleaseTest::ok('draft release is rejected', verify_published_fixture($fixture, $draft) !== []);

$prerelease = $fixture['release'];
$prerelease['prerelease'] = true;
PublishedReleaseTest::ok('prerelease is rejected', verify_published_fixture($fixture, $prerelease) !== []);

$mutable = $fixture['release'];
$mutable['immutable'] = false;
PublishedReleaseTest::ok('immutable false is rejected', verify_published_fixture($fixture, $mutable) !== []);

PublishedReleaseTest::ok(
    'wrong requested tag is rejected',
    verify_published_fixture($fixture, requestedTag: 'eventsales-wp-2026.10.05.1') !== []
);

PublishedReleaseTest::ok(
    'tag target mismatch is rejected',
    verify_published_fixture($fixture, tagTarget: str_repeat('d', 40)) !== []
);

PublishedReleaseTest::ok(
    'source outside canonical main history is rejected',
    verify_published_fixture($fixture, ancestry: [
        'source_to_main' => 'diverged',
        'source_to_build' => 'identical',
        'build_to_main' => 'identical',
    ]) !== []
);

foreach (['source_to_build', 'build_to_main'] as $ancestryKey) {
    $badAncestry = $fixture['ancestry'];
    $badAncestry[$ancestryKey] = 'diverged';
    PublishedReleaseTest::ok(
        "GitHub ancestry failure for {$ancestryKey} is rejected",
        verify_published_fixture($fixture, ancestry: $badAncestry) !== []
    );
}

$typeMismatchFixture = published_release_fixture();
$typeMismatchReleaseManifest = json_decode(
    (string) file_get_contents($typeMismatchFixture['assets_dir'] . '/release-manifest.json'),
    true,
    512,
    JSON_THROW_ON_ERROR
);
$typeMismatchDistributionManifest = json_decode(
    (string) file_get_contents($typeMismatchFixture['assets_dir'] . '/manifest.json'),
    true,
    512,
    JSON_THROW_ON_ERROR
);
$typeMismatchReleaseManifest['plugins'][0]['review_fixture'] = '7';
$typeMismatchDistributionManifest['plugins'][0]['review_fixture'] = 7;
file_put_contents(
    $typeMismatchFixture['assets_dir'] . '/release-manifest.json',
    json_encode($typeMismatchReleaseManifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL
);
file_put_contents(
    $typeMismatchFixture['assets_dir'] . '/manifest.json',
    json_encode($typeMismatchDistributionManifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL
);
refresh_fixture_release_authorities($typeMismatchFixture);
$typeMismatchErrors = verify_published_fixture($typeMismatchFixture);
PublishedReleaseTest::ok(
    'plugin manifest row type mismatch is rejected',
    in_array('Release and distribution plugin rows differ for eventsales-tickera-catalog-feed', $typeMismatchErrors, true)
);
remove_published_fixture($typeMismatchFixture);

PublishedReleaseTest::ok(
    'source tree mismatch is rejected',
    verify_published_fixture($fixture, commitTree: str_repeat('e', 40)) !== []
);

$missingAsset = $fixture['release'];
array_pop($missingAsset['assets']);
PublishedReleaseTest::ok('missing asset is rejected', verify_published_fixture($fixture, $missingAsset) !== []);

$duplicateAsset = $fixture['release'];
$duplicateAsset['assets'][] = $duplicateAsset['assets'][0];
PublishedReleaseTest::ok('duplicate asset is rejected', verify_published_fixture($fixture, $duplicateAsset) !== []);

$unexpectedAsset = $fixture['release'];
$unexpectedAsset['assets'][] = ['id' => 200, 'name' => 'source.zip', 'digest' => 'sha256:' . str_repeat('f', 64)];
PublishedReleaseTest::ok('unexpected asset is rejected', verify_published_fixture($fixture, $unexpectedAsset) !== []);

$wrongAssetName = $fixture['release'];
$wrongAssetName['assets'][0]['name'] = 'eventsales-tickera-catalog-feed-latest.zip';
PublishedReleaseTest::ok('wrong asset name is rejected', verify_published_fixture($fixture, $wrongAssetName) !== []);

$missingDigest = $fixture['release'];
unset($missingDigest['assets'][0]['digest']);
PublishedReleaseTest::ok('missing asset digest is rejected', verify_published_fixture($fixture, $missingDigest) !== []);

$wrongDigest = $fixture['release'];
$wrongDigest['assets'][0]['digest'] = 'sha256:' . str_repeat('f', 64);
PublishedReleaseTest::ok('wrong asset digest is rejected', verify_published_fixture($fixture, $wrongDigest) !== []);

$malformedRelease = $fixture['release'];
$malformedRelease['assets'] = 'not-an-array';
PublishedReleaseTest::ok('malformed GitHub release response is rejected', verify_published_fixture($fixture, $malformedRelease) !== []);

$badManifestFixture = published_release_fixture();
file_put_contents($badManifestFixture['assets_dir'] . '/release-manifest.json', '{not-json');
$badManifestErrors = verify_published_fixture($badManifestFixture);
PublishedReleaseTest::ok('malformed release manifest is rejected', $badManifestErrors !== []);
PublishedReleaseTest::ok(
    'verification errors do not expose signed asset query strings',
    !str_contains(implode(' ', $badManifestErrors), 'fixture-secret')
);
remove_published_fixture($badManifestFixture);

$wrongArchiveFixture = published_release_fixture();
file_put_contents(
    $wrongArchiveFixture['assets_dir'] . '/eventsales-tickera-catalog-feed-0.1.2.zip',
    'tampered archive'
);
PublishedReleaseTest::ok('wrong plugin ZIP SHA-256 is rejected', verify_published_fixture($wrongArchiveFixture) !== []);
remove_published_fixture($wrongArchiveFixture);

$candidateFixture = published_release_fixture();
$candidateDir = $candidateFixture['root'] . '/candidate';
mkdir($candidateDir);
foreach (scandir($candidateFixture['assets_dir']) ?: [] as $name) {
    if ($name === '.' || $name === '..') {
        continue;
    }
    copy($candidateFixture['assets_dir'] . '/' . $name, $candidateDir . '/' . $name);
}
PublishedReleaseTest::ok(
    'matching candidate bytes validate',
    verify_published_fixture($candidateFixture, candidateDir: $candidateDir) === []
);
file_put_contents($candidateDir . '/manifest.json', 'different candidate bytes');
PublishedReleaseTest::ok(
    'candidate bytes that differ from published assets are rejected',
    verify_published_fixture($candidateFixture, candidateDir: $candidateDir) !== []
);
remove_published_fixture($candidateFixture);

$metadataCliFixture = published_release_fixture();
$metadataPath = $metadataCliFixture['root'] . '/release.json';
file_put_contents($metadataPath, json_encode($metadataCliFixture['release'], JSON_UNESCAPED_SLASHES));
$metadataProcess = proc_open(
    [
        PHP_BINARY,
        __DIR__ . '/published-release-validate.php',
        '--metadata',
        $metadataPath,
        '--tag',
        $metadataCliFixture['tag'],
        '--metadata-only',
        '1',
    ],
    [1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
    $metadataPipes
);
if (is_resource($metadataProcess)) {
    $metadataOutput = stream_get_contents($metadataPipes[1]);
    fclose($metadataPipes[1]);
    $metadataError = stream_get_contents($metadataPipes[2]);
    fclose($metadataPipes[2]);
    $metadataExit = proc_close($metadataProcess);
    PublishedReleaseTest::ok(
        'public metadata CLI succeeds without credentials',
        $metadataExit === 0 && trim((string) $metadataOutput) === 'Published release metadata passed' && $metadataError === ''
    );
} else {
    PublishedReleaseTest::ok('public metadata CLI starts', false);
}
remove_published_fixture($metadataCliFixture);

$checksumFixture = published_release_fixture();
file_put_contents($checksumFixture['assets_dir'] . '/RELEASE_SHA256SUMS', "0  manifest.json\n");
PublishedReleaseTest::ok('wrong checksum authority is rejected', verify_published_fixture($checksumFixture) !== []);
remove_published_fixture($checksumFixture);

remove_published_fixture($fixture);
PublishedReleaseTest::finish();
