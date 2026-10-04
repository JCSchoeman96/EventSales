<?php

declare(strict_types=1);

/**
 * WP-SOURCE-04 distribution certification tests (source + built packages).
 */

final class DistributionTest
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

    public static function same(string $label, mixed $expected, mixed $actual): void
    {
        if ($expected === $actual) {
            self::$passes++;

            return;
        }

        self::$failures[] = $label . ' (expected ' . var_export($expected, true) . ', got ' . var_export($actual, true) . ')';
    }

    public static function finish(): void
    {
        if (self::$failures !== []) {
            fwrite(STDERR, "plugin-distribution-test failures:\n");
            foreach (self::$failures as $failure) {
                fwrite(STDERR, "  - {$failure}\n");
            }
            exit(1);
        }

        fwrite(STDOUT, "plugin-distribution-test: " . self::$passes . " assertions passed\n");
    }
}

function repo_root(): string
{
    return dirname(__DIR__, 3);
}

function suite_manifest_git_path(): string
{
    return 'integrations/wordpress/eventsales-plugin-suite.json';
}

function suite_manifest_path(): string
{
    return dirname(__DIR__) . '/eventsales-plugin-suite.json';
}

/** @return array<string, mixed> */
function load_suite_manifest(): array
{
    $raw = file_get_contents(suite_manifest_path());
    if ($raw === false) {
        throw new RuntimeException('Unable to read suite manifest');
    }

    return json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
}

/** @return array<string, mixed> */
function load_suite_manifest_from_git(string $commit): array
{
    $gitPath = suite_manifest_git_path();
    $command = ['git', '-C', repo_root(), 'show', "{$commit}:{$gitPath}"];
    $process = proc_open(
        $command,
        [
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ],
        $pipes
    );
    if (!is_resource($process)) {
        throw new RuntimeException('Unable to run git show for suite manifest');
    }

    $stdout = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[2]);
    $exitCode = proc_close($process);
    if ($exitCode !== 0) {
        throw new RuntimeException('git show failed for suite manifest at ' . $commit);
    }

    if ($stdout === false || $stdout === '') {
        throw new RuntimeException('Empty suite manifest from git at ' . $commit);
    }

    return json_decode($stdout, true, 512, JSON_THROW_ON_ERROR);
}

/** @return array<string, string> */
function parse_plugin_header(string $mainFilePath): array
{
    $contents = file_get_contents($mainFilePath);
    if ($contents === false) {
        throw new RuntimeException('Unable to read plugin main file');
    }

    $headers = [];
    $patterns = [
        'name' => '/^\s*\*\s*Plugin Name:\s*(.+)$/mi',
        'version' => '/^\s*\*\s*Version:\s*(.+)$/mi',
        'requires_php' => '/^\s*\*\s*Requires PHP:\s*(.+)$/mi',
        'requires_at_least' => '/^\s*\*\s*Requires at least:\s*(.+)$/mi',
    ];

    foreach ($patterns as $key => $pattern) {
        if (preg_match($pattern, $contents, $matches) === 1) {
            $headers[$key] = trim($matches[1]);
        }
    }

    return $headers;
}

/** @return array<string, string> */
function read_defined_constants_from_main(string $mainFilePath): array
{
    $contents = file_get_contents($mainFilePath);
    if ($contents === false) {
        return [];
    }

    $constants = [];
    if (preg_match_all("/define\\('([A-Z0-9_]+)',\\s*'([^']*)'\\);/", $contents, $matches, PREG_SET_ORDER)) {
        foreach ($matches as $match) {
            $constants[$match[1]] = $match[2];
        }
    }

    return $constants;
}

function run_source_tests(): void
{
    $root = repo_root();
    $manifest = load_suite_manifest();
    $wpBase = dirname(__DIR__);

    DistributionTest::same('suite format_version', '1', (string) ($manifest['format_version'] ?? ''));
    DistributionTest::same('suite requires_php', '8.0', (string) ($manifest['requires_php'] ?? ''));
    DistributionTest::same('suite requires_at_least_wordpress', '5.2', (string) ($manifest['requires_at_least_wordpress'] ?? ''));
    DistributionTest::ok('suite lists four plugins', is_array($manifest['plugins'] ?? null) && count($manifest['plugins']) === 4);

    $readmePath = $wpBase . '/eventsales-tickera-catalog-feed/README.md';
    $readme = file_get_contents($readmePath);
    DistributionTest::ok('catalog README is readable', $readme !== false);
    if ($readme !== false) {
        DistributionTest::ok(
            'catalog README does not claim current schema 2026-07-08.v1',
            preg_match('/plugin emits schema version `2026-07-08\.v1`/i', $readme) !== 1
        );
        DistributionTest::ok(
            'catalog README documents current schema 2026-08-07.v3',
            str_contains($readme, '2026-08-07.v3')
        );
    }

    foreach ($manifest['plugins'] as $plugin) {
        $slug = (string) $plugin['slug'];
        $mainFile = (string) $plugin['main_file'];
        $mainPath = $wpBase . '/' . $slug . '/' . $mainFile;
        $headers = parse_plugin_header($mainPath);

        DistributionTest::ok("{$slug} main file exists", is_file($mainPath));
        DistributionTest::same("{$slug} header version", (string) $plugin['marketing_version'], $headers['version'] ?? '');
        DistributionTest::same("{$slug} Requires PHP", (string) $manifest['requires_php'], $headers['requires_php'] ?? '');
        DistributionTest::same("{$slug} Requires at least", (string) $manifest['requires_at_least_wordpress'], $headers['requires_at_least'] ?? '');
        DistributionTest::ok("{$slug} main filename matches slug", $mainFile === $slug . '.php');

        $constants = read_defined_constants_from_main($mainPath);
        if (isset($plugin['catalog_schema_version'])) {
            DistributionTest::same(
                'EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION',
                (string) $plugin['catalog_schema_version'],
                $constants['EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION'] ?? null
            );
        }
        if (isset($plugin['canonical_contract_version'])) {
            DistributionTest::same(
                'EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION',
                (string) $plugin['canonical_contract_version'],
                $constants['EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION'] ?? null
            );
        }
        if (isset($plugin['producer_version'])) {
            DistributionTest::same(
                'EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION',
                (string) $plugin['producer_version'],
                $constants['EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION'] ?? null
            );
        }
        if (isset($plugin['telemetry_version'])) {
            DistributionTest::same(
                'EVENTSALES_CATALOG_CHANGE_TELEMETRY_VERSION',
                (string) $plugin['telemetry_version'],
                $constants['EVENTSALES_CATALOG_CHANGE_TELEMETRY_VERSION'] ?? null
            );
        }
        if (isset($plugin['order_index_schema_version'])) {
            DistributionTest::same(
                'EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION',
                (string) $plugin['order_index_schema_version'],
                $constants['EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION'] ?? null
            );
        }
    }
}

/** @return list<string> */
function forbidden_path_patterns(): array
{
    return [
        '/\.env$/i',
        '/\.env\./i',
        '/wp-config\.php$/i',
        '/\.pem$/i',
        '/id_rsa/i',
        '/\.sql$/i',
    ];
}

/** @return list<string> */
function content_sentinels(): array
{
    return [
        'example-super-secret',
        'example-api-key',
        'example-path-token',
        'customer@example.test',
        'example payment transaction',
        'local DB password',
    ];
}

function run_dist_tests(string $distDir): void
{
    $manifestPath = $distDir . '/manifest.json';
    DistributionTest::ok('dist manifest.json exists', is_file($manifestPath));
    $manifestRaw = file_get_contents($manifestPath);
    DistributionTest::ok('dist manifest readable', $manifestRaw !== false);
    if ($manifestRaw === false) {
        return;
    }

    $manifest = json_decode($manifestRaw, true, 512, JSON_THROW_ON_ERROR);
    $sourceCommit = (string) ($manifest['source_commit'] ?? '');
    $suite = load_suite_manifest_from_git($sourceCommit);

    DistributionTest::same('manifest suite_manifest_git_path', suite_manifest_git_path(), (string) ($manifest['suite_manifest_git_path'] ?? ''));
    DistributionTest::same('manifest distribution_format_version', '1', (string) ($manifest['distribution_format_version'] ?? ''));
    DistributionTest::ok('manifest source_commit is 40-char hex', is_string($manifest['source_commit'] ?? null) && preg_match('/^[0-9a-f]{40}$/', $manifest['source_commit']) === 1);
    DistributionTest::ok('manifest source_tree is 40-char hex', is_string($manifest['source_tree'] ?? null) && preg_match('/^[0-9a-f]{40}$/', $manifest['source_tree']) === 1);
    DistributionTest::ok('manifest deterministic_source_content', ($manifest['deterministic_source_content'] ?? false) === true);
    DistributionTest::ok('manifest deterministic_archive_bytes is false', ($manifest['deterministic_archive_bytes'] ?? true) === false);

    $shaPath = $distDir . '/SHA256SUMS';
    DistributionTest::ok('SHA256SUMS exists', is_file($shaPath));

    $expectedSlugs = array_map(static fn (array $p): string => (string) $p['slug'], $suite['plugins']);
    $foundSlugs = [];

    foreach ($manifest['plugins'] as $pluginEntry) {
        $slug = (string) $pluginEntry['slug'];
        $foundSlugs[] = $slug;
        $archiveName = (string) $pluginEntry['archive_filename'];
        $archivePath = $distDir . '/' . $archiveName;
        DistributionTest::ok("archive exists for {$slug}", is_file($archivePath));

        $declaredSha = strtolower((string) ($pluginEntry['archive_sha256'] ?? ''));
        $actualSha = strtolower(hash_file('sha256', $archivePath));
        DistributionTest::same("archive sha256 {$slug}", $declaredSha, $actualSha);

        $zip = new ZipArchive();
        $open = $zip->open($archivePath);
        DistributionTest::ok("zip opens {$slug}", $open === true);
        if ($open !== true) {
            continue;
        }

        $rootDirs = [];
        $mainFile = (string) $pluginEntry['main_file'];
        $mainMember = $slug . '/' . $mainFile;
        $hasMain = false;
        for ($i = 0; $i < $zip->numFiles; $i++) {
            $name = $zip->getNameIndex($i);
            if ($name === false) {
                continue;
            }
            if (str_ends_with($name, '/')) {
                $parts = explode('/', rtrim($name, '/'));
                if ($parts[0] !== '') {
                    $rootDirs[$parts[0]] = true;
                }
                continue;
            }
            if (str_contains($name, '../') || str_starts_with($name, '/') || preg_match('/^[A-Za-z]:/', $name) === 1) {
                DistributionTest::ok("safe zip path {$slug}: {$name}", false);
                continue;
            }
            $parts = explode('/', $name);
            if ($parts[0] !== '') {
                $rootDirs[$parts[0]] = true;
            }
            if ($name === $mainMember) {
                $hasMain = true;
            }
            if (str_starts_with($name, 'tests/') || str_contains($name, '/tests/')) {
                DistributionTest::ok("tests excluded {$slug}: {$name}", false);
            }
            foreach (forbidden_path_patterns() as $pattern) {
                if (preg_match($pattern, $name) === 1) {
                    DistributionTest::ok("forbidden path pattern {$slug}: {$name}", false);
                }
            }
            if (str_ends_with($name, '.php') || str_ends_with($name, 'README.md')) {
                $contents = $zip->getFromIndex($i);
                if ($contents !== false) {
                    foreach (content_sentinels() as $sentinel) {
                        if (str_contains($contents, $sentinel)) {
                            DistributionTest::ok("sentinel excluded {$slug} in {$name}", false);
                        }
                    }
                    if (preg_match('#/(home|Users)/#', $contents) === 1) {
                        DistributionTest::ok("absolute path sentinel excluded {$slug} in {$name}", false);
                    }
                }
            } else {
                DistributionTest::ok("unexpected member {$slug}: {$name}", false);
            }
        }
        $zip->close();

        DistributionTest::ok("single root folder {$slug}", count($rootDirs) === 1 && array_key_exists($slug, $rootDirs));
        DistributionTest::ok("main file present {$slug}", $hasMain);

        $suitePlugin = null;
        foreach ($suite['plugins'] as $candidate) {
            if ($candidate['slug'] === $slug) {
                $suitePlugin = $candidate;
                break;
            }
        }
        DistributionTest::ok("suite plugin metadata for {$slug}", is_array($suitePlugin));
        if (is_array($suitePlugin)) {
            DistributionTest::same("marketing_version {$slug}", (string) $suitePlugin['marketing_version'], (string) $pluginEntry['marketing_version']);
        }
    }

    sort($expectedSlugs);
    sort($foundSlugs);
    DistributionTest::same('manifest plugin slugs', $expectedSlugs, $foundSlugs);

    $zipCount = count(glob($distDir . '/*.zip') ?: []);
    DistributionTest::same('four zip archives only', 4, $zipCount);

    $expectedPlugins = $suite['plugins'];
    $actualPlugins = $manifest['plugins'];
    DistributionTest::ok('dist manifest plugin count matches commit suite', count($expectedPlugins) === count($actualPlugins));
    foreach ($expectedPlugins as $index => $expectedPlugin) {
        $actualPlugin = $actualPlugins[$index] ?? null;
        DistributionTest::ok("dist manifest plugin index {$index} present", is_array($actualPlugin));
        if (!is_array($actualPlugin)) {
            continue;
        }
        DistributionTest::same("dist manifest slug {$index}", (string) $expectedPlugin['slug'], (string) $actualPlugin['slug']);
        DistributionTest::same(
            "dist manifest marketing_version {$index}",
            (string) $expectedPlugin['marketing_version'],
            (string) $actualPlugin['marketing_version']
        );
        $expectedArchive = sprintf(
            '%s-%s.zip',
            (string) $expectedPlugin['slug'],
            (string) $expectedPlugin['marketing_version']
        );
        DistributionTest::same("dist archive filename {$index}", $expectedArchive, (string) $actualPlugin['archive_filename']);
    }
}

$mode = 'source';
$distDir = null;
foreach (array_slice($argv, 1) as $arg) {
    if ($arg === '--source') {
        $mode = 'source';
    } elseif ($arg === '--dist') {
        $mode = 'dist';
    } elseif ($distDir === null && $arg !== '--dist') {
        $distDir = $arg;
    }
}

if ($mode === 'source') {
    run_source_tests();
    DistributionTest::finish();
    exit(0);
}

if ($distDir === null || !is_dir($distDir)) {
    fwrite(STDERR, "Missing --dist directory argument\n");
    exit(1);
}

run_source_tests();
run_dist_tests(rtrim($distDir, '/'));
DistributionTest::finish();
