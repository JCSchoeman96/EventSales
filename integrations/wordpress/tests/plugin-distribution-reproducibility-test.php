<?php

declare(strict_types=1);

final class ReproducibilityTest
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
            fwrite(STDERR, "plugin-distribution-reproducibility-test failures:\n");
            foreach (self::$failures as $failure) {
                fwrite(STDERR, "  - {$failure}\n");
            }
            exit(1);
        }

        fwrite(STDOUT, 'plugin-distribution-reproducibility-test: ' . self::$passes . " assertions passed\n");
    }
}

/** @return array<string, mixed> */
function load_json(string $path): array
{
    $raw = file_get_contents($path);
    if ($raw === false) {
        throw new RuntimeException('Unable to read ' . $path);
    }

    return json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
}

/** @return array<string, string> */
function zip_member_metadata(string $zipPath): array
{
    $zip = new ZipArchive();
    if ($zip->open($zipPath) !== true) {
        throw new RuntimeException('Unable to open zip ' . $zipPath);
    }
    $meta = [];
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $name = $zip->getNameIndex($i);
        if ($name === false || str_ends_with($name, '/')) {
            continue;
        }
        $stat = $zip->statIndex($i);
        $data = $zip->getFromIndex($i);
        $meta[$name] = json_encode([
            'crc' => $stat['crc'] ?? null,
            'size' => $stat['size'] ?? null,
            'comp_method' => $stat['comp_method'] ?? null,
            'sha256' => hash('sha256', $data === false ? '' : $data),
        ], JSON_THROW_ON_ERROR);
    }
    $zip->close();
    ksort($meta);

    return $meta;
}

if ($argc < 3) {
    fwrite(STDERR, "Usage: php plugin-distribution-reproducibility-test.php <dist-a> <dist-b>\n");
    exit(1);
}

$dirA = rtrim($argv[1], '/');
$dirB = rtrim($argv[2], '/');

$manifestA = load_json($dirA . '/manifest.json');
$manifestB = load_json($dirB . '/manifest.json');

ReproducibilityTest::same('source_commit match', $manifestA['source_commit'], $manifestB['source_commit']);
ReproducibilityTest::same('source_tree match', $manifestA['source_tree'], $manifestB['source_tree']);
ReproducibilityTest::ok('deterministic_archive_bytes A', ($manifestA['deterministic_archive_bytes'] ?? false) === true);
ReproducibilityTest::ok('deterministic_archive_bytes B', ($manifestB['deterministic_archive_bytes'] ?? false) === true);

foreach ($manifestA['plugins'] as $index => $pluginA) {
    $pluginB = $manifestB['plugins'][$index] ?? null;
    ReproducibilityTest::ok("plugin index {$index} present in B", is_array($pluginB));
    if (!is_array($pluginB)) {
        continue;
    }
    $slug = (string) $pluginA['slug'];
    ReproducibilityTest::same("slug {$slug}", $pluginA['slug'], $pluginB['slug']);
    ReproducibilityTest::same("archive_sha256 {$slug}", $pluginA['archive_sha256'], $pluginB['archive_sha256']);

    $archive = (string) $pluginA['archive_filename'];
    $pathA = $dirA . '/' . $archive;
    $pathB = $dirB . '/' . $archive;
    ReproducibilityTest::same("file sha256 {$slug}", hash_file('sha256', $pathA), hash_file('sha256', $pathB));

    $metaA = zip_member_metadata($pathA);
    $metaB = zip_member_metadata($pathB);
    ReproducibilityTest::same("zip member set {$slug}", array_keys($metaA), array_keys($metaB));
    ReproducibilityTest::same("zip member metadata {$slug}", $metaA, $metaB);
}

ReproducibilityTest::finish();
