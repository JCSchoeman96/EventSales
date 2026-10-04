<?php

declare(strict_types=1);

/**
 * Pure release manifest transition validation (WP-SOURCE-05).
 */

final class TransitionReport
{
    /** @var list<string> */
    public static array $errors = [];

    /** @var list<string> */
    public static array $notices = [];

    public static function fail(string $message): void
    {
        self::$errors[] = $message;
    }

    public static function notice(string $message): void
    {
        self::$notices[] = $message;
    }
}

/** @return array<string, mixed> */
function load_manifest(string $path): array
{
    if (!is_file($path)) {
        throw new InvalidArgumentException('Manifest not found: ' . $path);
    }

    $raw = file_get_contents($path);
    if ($raw === false) {
        throw new RuntimeException('Unable to read manifest: ' . $path);
    }

    return json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
}

function valid_sha256(?string $value): bool
{
    return is_string($value) && preg_match('/^[0-9a-f]{64}$/', $value) === 1;
}

/** @return list<string> */
function canonical_slugs(): array
{
    return [
        'eventsales-tickera-catalog-feed',
        'eventsales-woo-order-index-feed',
        'eventsales-woo-order-line-identity',
        'eventsales-integration-health',
    ];
}

/** @param array<string, mixed> $manifest */
function validate_release_manifest_structure(array $manifest, string $label): void
{
    $required = [
        'release_manifest_format_version',
        'suite_release_id',
        'suggested_tag',
        'source_commit',
        'source_tree',
        'requires_wordpress',
        'requires_php',
        'plugins',
    ];
    foreach ($required as $key) {
        if (!array_key_exists($key, $manifest)) {
            TransitionReport::fail("{$label} missing field {$key}");
        }
    }
    if (!is_array($manifest['plugins'] ?? null)) {
        TransitionReport::fail("{$label} plugins must be an array");

        return;
    }
    if (count($manifest['plugins']) !== 4) {
        TransitionReport::fail("{$label} must list exactly four plugins");
    }
    foreach ($manifest['plugins'] as $plugin) {
        if (!is_array($plugin)) {
            TransitionReport::fail("{$label} plugin entry must be object");
            continue;
        }
        foreach (['slug', 'marketing_version', 'archive_sha256'] as $field) {
            if (!isset($plugin[$field])) {
                TransitionReport::fail("{$label} plugin missing {$field}");
            }
        }
        if (!valid_sha256(isset($plugin['archive_sha256']) ? (string) $plugin['archive_sha256'] : null)) {
            TransitionReport::fail("{$label} invalid archive_sha256 for " . ($plugin['slug'] ?? '?'));
        }
    }
    $wp = (string) ($manifest['requires_wordpress'] ?? '');
    $php = (string) ($manifest['requires_php'] ?? '');
    if ($wp === '' || $php === '') {
        TransitionReport::fail("{$label} runtime floor fields must be non-empty");
    }
}

/** @param array<string, mixed> $manifest */
function plugins_by_slug(array $manifest): array
{
    $map = [];
    foreach ($manifest['plugins'] as $plugin) {
        $map[(string) $plugin['slug']] = $plugin;
    }

    return $map;
}

/** @param array<string, mixed> $plugin */
function contract_snapshot(array $plugin, array $manifest): array
{
    return [
        'catalog_schema_version' => $plugin['catalog_schema_version'] ?? null,
        'canonical_contract_version' => $plugin['canonical_contract_version'] ?? null,
        'producer_version' => $plugin['producer_version'] ?? null,
        'telemetry_version' => $plugin['telemetry_version'] ?? null,
        'order_index_schema_version' => $plugin['order_index_schema_version'] ?? null,
        'requires_wordpress' => $manifest['requires_wordpress'] ?? null,
        'requires_php' => $manifest['requires_php'] ?? null,
    ];
}

function run_transition(string $mode, string $fromPath, string $toPath): int
{
    $from = load_manifest($fromPath);
    $to = load_manifest($toPath);

    validate_release_manifest_structure($from, 'from');
    validate_release_manifest_structure($to, 'to');

    if (TransitionReport::$errors !== []) {
        return finish();
    }

    $fromPlugins = plugins_by_slug($from);
    $toPlugins = plugins_by_slug($to);

    foreach (canonical_slugs() as $slug) {
        if (!isset($fromPlugins[$slug], $toPlugins[$slug])) {
            TransitionReport::fail("Missing canonical slug {$slug} in from/to manifests");
        }
    }

    if (TransitionReport::$errors !== []) {
        return finish();
    }

    $strictIncrease = 0;
    $strictDecrease = 0;

    if ($mode === 'rollback') {
        if ($from['requires_wordpress'] !== $to['requires_wordpress']) {
            TransitionReport::fail('rollback blocked: requires_wordpress change requires explicit review');
        }
        if ($from['requires_php'] !== $to['requires_php']) {
            TransitionReport::fail('rollback blocked: requires_php change requires explicit review');
        }
    }

    foreach (canonical_slugs() as $slug) {
        $fp = $fromPlugins[$slug];
        $tp = $toPlugins[$slug];
        $fromVer = (string) $fp['marketing_version'];
        $toVer = (string) $tp['marketing_version'];
        $fromSha = strtolower((string) $fp['archive_sha256']);
        $toSha = strtolower((string) $tp['archive_sha256']);

        $cmp = version_compare($toVer, $fromVer);
        if ($fromVer === $toVer && $fromSha !== $toSha) {
            TransitionReport::fail("{$slug}: same marketing_version {$fromVer} with different archive_sha256");
        }

        $fromContract = contract_snapshot($fp, $from);
        $toContract = contract_snapshot($tp, $to);
        if ($fromVer === $toVer) {
            if ($fromContract !== $toContract) {
                TransitionReport::fail("{$slug}: same marketing_version {$fromVer} with different public contract fields");
            }
        }

        if ($mode === 'upgrade') {
            if ($cmp < 0) {
                TransitionReport::fail("{$slug}: upgrade requires target marketing_version >= source ({$toVer} < {$fromVer})");
            }
            if ($cmp > 0) {
                $strictIncrease++;
                $diffs = [];
                foreach ($fromContract as $key => $value) {
                    $newValue = $toContract[$key];
                    if ($value !== $newValue) {
                        $diffs[] = "{$key}: " . var_export($value, true) . ' -> ' . var_export($newValue, true);
                    }
                }
                if ($diffs !== []) {
                    TransitionReport::notice("{$slug} upgrade contract review: " . implode('; ', $diffs));
                }
            }
        } else {
            if ($cmp > 0) {
                TransitionReport::fail("{$slug}: rollback requires target marketing_version <= source ({$toVer} > {$fromVer})");
            }
            if ($cmp < 0) {
                $strictDecrease++;
            }

            $fromOrderSchema = $fromContract['order_index_schema_version'] ?? null;
            $toOrderSchema = $toContract['order_index_schema_version'] ?? null;
            if ($slug === 'eventsales-woo-order-index-feed') {
                if ($fromOrderSchema !== $toOrderSchema) {
                    TransitionReport::fail('rollback blocked: order_index_schema_version mismatch without backward-compatibility metadata');
                }
            }

            $catalogKeys = ['catalog_schema_version', 'canonical_contract_version', 'producer_version'];
            if ($slug === 'eventsales-tickera-catalog-feed') {
                foreach ($catalogKeys as $key) {
                    if (($fromContract[$key] ?? null) !== ($toContract[$key] ?? null)) {
                        TransitionReport::fail("rollback blocked: catalogue {$key} change requires explicit review");
                    }
                }
            }
        }
    }

    if ($mode === 'upgrade' && $strictIncrease === 0) {
        TransitionReport::fail('upgrade requires at least one plugin marketing_version to strictly increase');
    }
    if ($mode === 'rollback' && $strictDecrease === 0) {
        TransitionReport::fail('rollback requires at least one plugin marketing_version to strictly decrease');
    }

    return finish();
}

function finish(): int
{
    foreach (TransitionReport::$notices as $notice) {
        fwrite(STDOUT, "NOTICE: {$notice}\n");
    }
    if (TransitionReport::$errors !== []) {
        fwrite(STDERR, "Release transition validation failed:\n");
        foreach (TransitionReport::$errors as $error) {
            fwrite(STDERR, "  - {$error}\n");
        }

        return 1;
    }

    fwrite(STDOUT, "Release transition validation passed.\n");

    return 0;
}

$mode = '';
$from = '';
$to = '';
for ($i = 1; $i < $argc; $i++) {
    if ($argv[$i] === '--mode') {
        $mode = (string) ($argv[$i + 1] ?? '');
        $i++;
    } elseif ($argv[$i] === '--from') {
        $from = (string) ($argv[$i + 1] ?? '');
        $i++;
    } elseif ($argv[$i] === '--to') {
        $to = (string) ($argv[$i + 1] ?? '');
        $i++;
    }
}

if (realpath($argv[0]) === realpath(__FILE__)) {
    if ($mode === '' || $from === '' || $to === '') {
        fwrite(STDERR, "Usage: php release-transition-validate.php --mode upgrade|rollback --from <path> --to <path>\n");
        exit(1);
    }

    exit(run_transition($mode, $from, $to));
}
