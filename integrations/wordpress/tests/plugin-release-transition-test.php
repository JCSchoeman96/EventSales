<?php

declare(strict_types=1);

require_once __DIR__ . '/release-transition-validate.php';

final class ReleaseTransitionTest
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
            fwrite(STDERR, "plugin-release-transition-test failures:\n");
            foreach (self::$failures as $failure) {
                fwrite(STDERR, "  - {$failure}\n");
            }
            exit(1);
        }

        fwrite(STDOUT, 'plugin-release-transition-test: ' . self::$passes . " assertions passed\n");
    }
}

function repo_root(): string
{
    return dirname(__DIR__, 3);
}

/** @return array<string, mixed> */
function base_manifest_template(): array
{
    return [
        'release_manifest_format_version' => '1',
        'suite_release_id' => '2026.10.04.1',
        'suggested_tag' => 'eventsales-wp-2026.10.04.1',
        'source_commit' => str_repeat('a', 40),
        'source_tree' => str_repeat('b', 40),
        'canonical_main_at_build' => str_repeat('c', 40),
        'suite_manifest_git_path' => 'integrations/wordpress/eventsales-plugin-suite.json',
        'distribution_format_version' => '1',
        'requires_wordpress' => '5.6',
        'requires_php' => '8.0',
        'deterministic_source_content' => true,
        'deterministic_archive_bytes' => true,
        'plugins' => [
            plugin_row('eventsales-tickera-catalog-feed', '0.1.1', 'aa' . str_repeat('0', 62)),
            plugin_row('eventsales-woo-order-index-feed', '0.2.1', 'bb' . str_repeat('0', 62)),
            plugin_row('eventsales-woo-order-line-identity', '0.1.1', 'cc' . str_repeat('0', 62)),
            plugin_row('eventsales-integration-health', '0.1.1', 'dd' . str_repeat('0', 62)),
        ],
    ];
}

/** @return array<string, mixed> */
function plugin_row(string $slug, string $version, string $sha): array
{
    $row = [
        'slug' => $slug,
        'main_file' => $slug . '.php',
        'marketing_version' => $version,
        'archive_filename' => $slug . '-' . $version . '.zip',
        'archive_sha256' => $sha,
    ];
    if ($slug === 'eventsales-tickera-catalog-feed') {
        $row['catalog_schema_version'] = '2026-08-07.v3';
        $row['canonical_contract_version'] = 'source_risk.v3';
        $row['producer_version'] = '2026-08-07.1';
        $row['telemetry_version'] = '2026-10-02.v1';
    }
    if ($slug === 'eventsales-woo-order-index-feed') {
        $row['order_index_schema_version'] = '2026-08-12.v1';
    }

    return $row;
}

function write_manifest(array $manifest, string $path): void
{
    file_put_contents($path, json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);
}

function expect_transition(string $mode, string $fromPath, string $toPath, bool $shouldPass, string $label): void
{
    TransitionReport::$errors = [];
    TransitionReport::$notices = [];
    $code = run_transition($mode, $fromPath, $toPath);
    ReleaseTransitionTest::ok($label, ($code === 0) === $shouldPass);
}

$tmp = sys_get_temp_dir() . '/es-wp-transition-' . getmypid();
mkdir($tmp);

$baseline = base_manifest_template();
$baselinePath = $tmp . '/baseline.json';
write_manifest($baseline, $baselinePath);

$upgraded = $baseline;
$upgraded['suite_release_id'] = '2026.10.05.1';
$upgraded['plugins'] = [
    plugin_row('eventsales-tickera-catalog-feed', '0.1.2', 'ee' . str_repeat('0', 62)),
    plugin_row('eventsales-woo-order-index-feed', '0.2.1', 'bb' . str_repeat('0', 62)),
    plugin_row('eventsales-woo-order-line-identity', '0.1.1', 'cc' . str_repeat('0', 62)),
    plugin_row('eventsales-integration-health', '0.1.1', 'dd' . str_repeat('0', 62)),
];
$upgradedPath = $tmp . '/upgraded.json';
write_manifest($upgraded, $upgradedPath);

expect_transition('upgrade', $baselinePath, $upgradedPath, true, 'valid upgrade');

$downgraded = $baseline;
$downgraded['plugins'] = [
    plugin_row('eventsales-tickera-catalog-feed', '0.1.0', 'ff' . str_repeat('0', 62)),
    plugin_row('eventsales-woo-order-index-feed', '0.2.0', '11' . str_repeat('0', 62)),
    plugin_row('eventsales-woo-order-line-identity', '0.1.0', '22' . str_repeat('0', 62)),
    plugin_row('eventsales-integration-health', '0.1.0', '33' . str_repeat('0', 62)),
];
$downgradedPath = $tmp . '/downgraded.json';
write_manifest($downgraded, $downgradedPath);

expect_transition('rollback', $baselinePath, $downgradedPath, true, 'valid code rollback same order-index schema');

$badUpgradeLower = $baseline;
$badUpgradeLower['plugins'][0] = plugin_row('eventsales-tickera-catalog-feed', '0.1.0', '99' . str_repeat('0', 62));
$badUpgradeLowerPath = $tmp . '/bad-upgrade-lower.json';
write_manifest($badUpgradeLower, $badUpgradeLowerPath);
expect_transition('upgrade', $baselinePath, $badUpgradeLowerPath, false, 'upgrade with lower target version fails');

$unchanged = $baseline;
$unchangedPath = $tmp . '/unchanged.json';
write_manifest($unchanged, $unchangedPath);
expect_transition('upgrade', $baselinePath, $unchangedPath, false, 'upgrade with all versions unchanged fails');

$sameVersionNewSha = $baseline;
$sameVersionNewSha['plugins'][0] = plugin_row('eventsales-tickera-catalog-feed', '0.1.1', '77' . str_repeat('0', 62));
$sameVersionNewShaPath = $tmp . '/same-version-new-sha.json';
write_manifest($sameVersionNewSha, $sameVersionNewShaPath);
expect_transition('upgrade', $baselinePath, $sameVersionNewShaPath, false, 'same version different archive hash fails');

$sameVersionNewContract = $baseline;
$sameVersionNewContract['plugins'][0]['catalog_schema_version'] = '2026-09-01.v1';
$sameVersionNewContractPath = $tmp . '/same-version-new-contract.json';
write_manifest($sameVersionNewContract, $sameVersionNewContractPath);
expect_transition('upgrade', $baselinePath, $sameVersionNewContractPath, false, 'same version different public contract fails');

$badRollbackHigher = $baseline;
$badRollbackHigher['plugins'][0] = plugin_row('eventsales-tickera-catalog-feed', '0.2.0', '88' . str_repeat('0', 62));
$badRollbackHigherPath = $tmp . '/bad-rollback-higher.json';
write_manifest($badRollbackHigher, $badRollbackHigherPath);
expect_transition('rollback', $baselinePath, $badRollbackHigherPath, false, 'rollback with higher target version fails');

expect_transition('rollback', $baselinePath, $unchangedPath, false, 'rollback with all versions unchanged fails');

$schemaRollback = $baseline;
$schemaRollback['plugins'][1] = plugin_row('eventsales-woo-order-index-feed', '0.2.0', '55' . str_repeat('0', 62));
$schemaRollback['plugins'][1]['order_index_schema_version'] = '2026-07-01.v1';
$schemaRollbackPath = $tmp . '/schema-rollback.json';
write_manifest($schemaRollback, $schemaRollbackPath);
expect_transition('rollback', $baselinePath, $schemaRollbackPath, false, 'rollback across order-index schema fails');

$floorRollback = $downgraded;
$floorRollback['requires_php'] = '7.4';
$floorRollbackPath = $tmp . '/floor-rollback.json';
write_manifest($floorRollback, $floorRollbackPath);
expect_transition('rollback', $baselinePath, $floorRollbackPath, false, 'rollback with requires_php floor change fails');

ReleaseTransitionTest::finish();
