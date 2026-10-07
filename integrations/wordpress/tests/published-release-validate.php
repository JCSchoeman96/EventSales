<?php

declare(strict_types=1);

require_once __DIR__ . '/release-manifest-contract.php';

/** @var list<string> */
const PUBLISHED_RELEASE_ASSET_NAMES = [
    'eventsales-tickera-catalog-feed-0.1.2.zip',
    'eventsales-woo-order-index-feed-0.2.2.zip',
    'eventsales-woo-order-line-identity-0.1.2.zip',
    'eventsales-integration-health-0.1.2.zip',
    'manifest.json',
    'SHA256SUMS',
    'release-manifest.json',
    'RELEASE_SHA256SUMS',
];

/** @var array<string, string> */
const PUBLISHED_RELEASE_PLUGIN_MAIN_FILES = [
    'eventsales-tickera-catalog-feed' => 'eventsales-tickera-catalog-feed.php',
    'eventsales-woo-order-index-feed' => 'eventsales-woo-order-index-feed.php',
    'eventsales-woo-order-line-identity' => 'eventsales-woo-order-line-identity.php',
    'eventsales-integration-health' => 'eventsales-integration-health.php',
];

function published_release_valid_tag(string $tag): bool
{
    if (!str_starts_with($tag, 'eventsales-wp-')) {
        return false;
    }

    return suite_release_id_error(substr($tag, strlen('eventsales-wp-'))) === null;
}

function published_release_redirect_url_allowed(string $url): bool
{
    if (preg_match('/[\x00-\x20\x7f"\\\\]/', $url) === 1) {
        return false;
    }

    $parts = parse_url($url);
    if (!is_array($parts)) {
        return false;
    }

    return strtolower((string) ($parts['scheme'] ?? '')) === 'https'
        && strtolower((string) ($parts['host'] ?? '')) === 'release-assets.githubusercontent.com'
        && (!isset($parts['port']) || $parts['port'] === 443)
        && !isset($parts['user'])
        && !isset($parts['pass'])
        && !isset($parts['fragment'])
        && isset($parts['path'])
        && $parts['path'] !== '';
}

function published_release_url_origin(string $url): ?string
{
    if (preg_match('/[\x00-\x20\x7f"\\\\]/', $url) === 1) {
        return null;
    }

    $parts = parse_url($url);
    if (!is_array($parts)
        || strtolower((string) ($parts['scheme'] ?? '')) !== 'https'
        || !isset($parts['host'])
        || $parts['host'] === ''
        || isset($parts['user'])
        || isset($parts['pass'])
        || isset($parts['fragment'])) {
        return null;
    }

    return 'https://' . strtolower($parts['host']) . (isset($parts['port']) ? ':' . $parts['port'] : '');
}

function published_release_repository_matches(array $release, string $requestedTag): bool
{
    $apiUrl = $release['url'] ?? null;
    $htmlUrl = $release['html_url'] ?? null;
    if (!is_string($apiUrl) || !is_string($htmlUrl)) {
        return false;
    }

    $api = parse_url($apiUrl);
    $html = parse_url($htmlUrl);
    if (!is_array($api) || !is_array($html)) {
        return false;
    }

    if (strtolower((string) ($api['scheme'] ?? '')) !== 'https'
        || strtolower((string) ($api['host'] ?? '')) !== 'api.github.com'
        || isset($api['user']) || isset($api['pass']) || isset($api['port']) || isset($api['query']) || isset($api['fragment'])
        || strtolower((string) ($html['scheme'] ?? '')) !== 'https'
        || strtolower((string) ($html['host'] ?? '')) !== 'github.com'
        || isset($html['user']) || isset($html['pass']) || isset($html['port']) || isset($html['query']) || isset($html['fragment'])) {
        return false;
    }

    return preg_match(
        '#^/repos/JCSchoeman96/EventSales/releases/[1-9][0-9]*$#i',
        (string) ($api['path'] ?? '')
        ) === 1
        && (string) ($html['path'] ?? '') === '/JCSchoeman96/EventSales/releases/tag/' . $requestedTag;
}

/** @return list<string> */
function published_release_metadata_errors(array $release, string $requestedTag): array
{
    $errors = [];

    if (!published_release_valid_tag($requestedTag)) {
        $errors[] = 'Requested tag is not a valid EventSales suite tag';
    }
    if (!published_release_repository_matches($release, $requestedTag)) {
        $errors[] = 'Release metadata does not identify JCSchoeman96/EventSales';
    }
    if (($release['tag_name'] ?? null) !== $requestedTag) {
        $errors[] = 'Release tag does not match the requested tag';
    }
    if (($release['draft'] ?? null) !== false) {
        $errors[] = 'Release must be published, not a draft';
    }
    if (($release['prerelease'] ?? null) !== false) {
        $errors[] = 'Prereleases are not accepted';
    }
    if (($release['immutable'] ?? null) !== true) {
        $errors[] = 'Release must report immutable=true';
    }

    $assets = $release['assets'] ?? null;
    if (!is_array($assets) || count($assets) !== count(PUBLISHED_RELEASE_ASSET_NAMES)) {
        $errors[] = 'Release must contain exactly the eight EventSales assets';

        return $errors;
    }

    $seenNames = [];
    $seenIds = [];
    foreach ($assets as $asset) {
        if (!is_array($asset)) {
            $errors[] = 'Release asset entry is malformed';
            continue;
        }

        $name = $asset['name'] ?? null;
        if (!is_string($name) || !in_array($name, PUBLISHED_RELEASE_ASSET_NAMES, true)) {
            $errors[] = 'Release contains an unexpected asset name';
            continue;
        }
        if (isset($seenNames[$name])) {
            $errors[] = 'Release contains a duplicate asset name';
        }
        $seenNames[$name] = true;

        $id = $asset['id'] ?? null;
        if (!is_int($id) || $id < 1) {
            $errors[] = "Release asset {$name} has an invalid asset ID";
        } elseif (isset($seenIds[$id])) {
            $errors[] = 'Release contains a duplicate asset ID';
        } else {
            $seenIds[$id] = true;
        }

        $digest = $asset['digest'] ?? null;
        if (!is_string($digest) || preg_match('/^sha256:[0-9a-f]{64}$/', $digest) !== 1) {
            $errors[] = "Release asset {$name} is missing a valid SHA-256 digest";
        }
    }

    $actualNames = array_keys($seenNames);
    $expectedNames = PUBLISHED_RELEASE_ASSET_NAMES;
    sort($actualNames);
    sort($expectedNames);
    if ($actualNames !== $expectedNames) {
        $errors[] = 'Release asset names do not match the exact EventSales asset set';
    }

    return array_values(array_unique($errors));
}

/** @return list<string> */
function published_release_directory_errors(string $directory, string $label): array
{
    if (!is_dir($directory)) {
        return ["{$label} asset directory is unavailable"];
    }

    $entries = scandir($directory);
    if ($entries === false) {
        return ["{$label} asset directory cannot be read"];
    }

    $actualFiles = [];
    foreach ($entries as $entry) {
        if ($entry === '.' || $entry === '..') {
            continue;
        }
        $path = $directory . '/' . $entry;
        if (is_link($path) || !is_file($path)) {
            return ["{$label} asset directory contains a non-file entry"];
        }
        $actualFiles[] = $entry;
    }

    sort($actualFiles);
    $expectedFiles = PUBLISHED_RELEASE_ASSET_NAMES;
    sort($expectedFiles);
    if ($actualFiles !== $expectedFiles) {
        return ["{$label} asset directory does not contain exactly the eight EventSales assets"];
    }

    return [];
}

/** @param list<string> $expectedFiles
 *  @param array<string, string> $actualHashes
 *  @return list<string>
 */
function published_release_checksum_errors(
    string $path,
    string $label,
    array $expectedFiles,
    array $actualHashes
): array {
    if (!is_file($path)) {
        return ["{$label} checksum file is missing"];
    }

    $lines = file($path, FILE_IGNORE_NEW_LINES);
    if ($lines === false) {
        return ["{$label} checksum file cannot be read"];
    }

    $entries = [];
    $errors = [];
    foreach ($lines as $line) {
        if (trim($line) === '') {
            continue;
        }
        if (preg_match('/^([0-9a-f]{64})  (\S+)\s*$/', $line, $matches) !== 1) {
            $errors[] = "{$label} contains a malformed checksum line";
            continue;
        }
        $name = $matches[2];
        if (isset($entries[$name])) {
            $errors[] = "{$label} contains a duplicate checksum target";
            continue;
        }
        $entries[$name] = $matches[1];
    }

    $expected = $expectedFiles;
    $actual = array_keys($entries);
    sort($expected);
    sort($actual);
    if ($actual !== $expected) {
        $errors[] = "{$label} does not cover its exact required file set";
    }

    foreach ($entries as $name => $hash) {
        if (!isset($actualHashes[$name]) || !hash_equals($actualHashes[$name], $hash)) {
            $errors[] = "{$label} SHA-256 mismatch for {$name}";
        }
    }

    return $errors;
}

/** @return array<string, array<string, mixed>> */
function published_release_plugin_map(array $manifest, string $label, array &$errors): array
{
    $rows = $manifest['plugins'] ?? null;
    if (!is_array($rows) || count($rows) !== count(PUBLISHED_RELEASE_PLUGIN_MAIN_FILES)) {
        $errors[] = "{$label} must list exactly four plugins";

        return [];
    }

    $plugins = [];
    foreach ($rows as $row) {
        if (!is_array($row)) {
            $errors[] = "{$label} contains a malformed plugin row";
            continue;
        }

        $slug = $row['slug'] ?? null;
        if (!is_string($slug) || !isset(PUBLISHED_RELEASE_PLUGIN_MAIN_FILES[$slug])) {
            $errors[] = "{$label} contains an unexpected plugin slug";
            continue;
        }
        if (isset($plugins[$slug])) {
            $errors[] = "{$label} contains a duplicate plugin slug";
            continue;
        }

        $mainFile = PUBLISHED_RELEASE_PLUGIN_MAIN_FILES[$slug];
        $version = $row['marketing_version'] ?? null;
        $filename = $row['archive_filename'] ?? null;
        $archiveHash = $row['archive_sha256'] ?? null;
        if (($row['main_file'] ?? null) !== $mainFile) {
            $errors[] = "{$label} has the wrong main file for {$slug}";
        }
        if (!is_string($version) || preg_match('/^\d+(?:\.\d+){1,3}$/', $version) !== 1) {
            $errors[] = "{$label} has an invalid marketing version for {$slug}";
        }
        if (!is_string($filename) || $filename !== $slug . '-' . (string) $version . '.zip') {
            $errors[] = "{$label} has an invalid archive filename for {$slug}";
        }
        if (!is_string($archiveHash) || preg_match('/^[0-9a-f]{64}$/', $archiveHash) !== 1) {
            $errors[] = "{$label} has an invalid archive SHA-256 for {$slug}";
        }

        if ($slug === 'eventsales-tickera-catalog-feed'
            && (!is_string($row['catalog_schema_version'] ?? null)
                || preg_match('/^\d{4}-\d{2}-\d{2}\.v[1-9][0-9]*$/', $row['catalog_schema_version']) !== 1
                || !is_string($row['canonical_contract_version'] ?? null)
                || preg_match('/^source_risk\.v[1-9][0-9]*$/', $row['canonical_contract_version']) !== 1
                || !is_string($row['producer_version'] ?? null)
                || preg_match('/^\d{4}-\d{2}-\d{2}\.[1-9][0-9]*$/', $row['producer_version']) !== 1
                || !is_string($row['telemetry_version'] ?? null)
                || preg_match('/^\d{4}-\d{2}-\d{2}\.v[1-9][0-9]*$/', $row['telemetry_version']) !== 1)) {
            $errors[] = "{$label} has invalid catalogue contract fields";
        }
        if ($slug === 'eventsales-woo-order-index-feed'
            && (!is_string($row['order_index_schema_version'] ?? null)
                || preg_match('/^\d{4}-\d{2}-\d{2}\.v[1-9][0-9]*$/', $row['order_index_schema_version']) !== 1)) {
            $errors[] = "{$label} has an invalid order-index schema version";
        }

        $plugins[$slug] = $row;
    }

    if (count($plugins) !== count(PUBLISHED_RELEASE_PLUGIN_MAIN_FILES)) {
        $errors[] = "{$label} does not contain every canonical plugin";
    }

    return $plugins;
}

/** @param array<string, mixed> $release
 *  @param array<string, string> $ancestryStatuses
 *  @return list<string>
 */
function published_release_validation_errors(
    array $release,
    string $requestedTag,
    string $tagTargetCommit,
    string $sourceTreeSha,
    array $ancestryStatuses,
    string $assetDirectory,
    ?string $candidateDirectory = null
): array {
    $errors = published_release_metadata_errors($release, $requestedTag);
    if ($errors !== []) {
        return $errors;
    }

    $directoryErrors = published_release_directory_errors($assetDirectory, 'Published release');
    if ($directoryErrors !== []) {
        return $directoryErrors;
    }

    $manifestPath = $assetDirectory . '/release-manifest.json';
    $distributionPath = $assetDirectory . '/manifest.json';
    try {
        $releaseManifest = json_decode((string) file_get_contents($manifestPath), true, 512, JSON_THROW_ON_ERROR);
        $distributionManifest = json_decode((string) file_get_contents($distributionPath), true, 512, JSON_THROW_ON_ERROR);
    } catch (Throwable) {
        return ['Release manifest JSON is malformed'];
    }
    if (!is_array($releaseManifest) || !is_array($distributionManifest)) {
        return ['Release manifest JSON must contain objects'];
    }

    $errors = array_merge($errors, release_manifest_contract_errors($releaseManifest, 'published release manifest'));
    if (($releaseManifest['suggested_tag'] ?? null) !== $requestedTag) {
        $errors[] = 'Release manifest suggested_tag does not match the release tag';
    }

    $sourceCommit = $releaseManifest['source_commit'] ?? null;
    $manifestTree = $releaseManifest['source_tree'] ?? null;
    $canonicalMainAtBuild = $releaseManifest['canonical_main_at_build'] ?? null;
    if (!is_string($sourceCommit) || !is_string($manifestTree) || !is_string($canonicalMainAtBuild)) {
        $errors[] = 'Release manifest Git identities are malformed';
    } else {
        if (!preg_match('/^[0-9a-f]{40}$/', $tagTargetCommit) || !hash_equals($sourceCommit, $tagTargetCommit)) {
            $errors[] = 'Release tag target does not match release manifest source_commit';
        }
        if (!preg_match('/^[0-9a-f]{40}$/', $sourceTreeSha) || !hash_equals($manifestTree, $sourceTreeSha)) {
            $errors[] = 'GitHub source tree does not match release manifest source_tree';
        }
        foreach (
            [
                'source_to_main' => 'source commit to current canonical main',
                'source_to_build' => 'source commit to canonical_main_at_build',
                'build_to_main' => 'canonical_main_at_build to current canonical main',
            ] as $key => $label
        ) {
            if (!in_array($ancestryStatuses[$key] ?? null, ['ahead', 'identical'], true)) {
                $errors[] = "GitHub ancestry check failed for {$label}";
            }
        }
    }

    if (($distributionManifest['source_commit'] ?? null) !== $sourceCommit) {
        $errors[] = 'Distribution manifest source_commit does not match release manifest';
    }
    if (($distributionManifest['source_tree'] ?? null) !== $manifestTree) {
        $errors[] = 'Distribution manifest source_tree does not match release manifest';
    }
    if (($distributionManifest['suite_manifest_git_path'] ?? null) !== 'integrations/wordpress/eventsales-plugin-suite.json'
        || ($releaseManifest['suite_manifest_git_path'] ?? null) !== 'integrations/wordpress/eventsales-plugin-suite.json') {
        $errors[] = 'Suite manifest path does not match the EventSales release authority';
    }
    if (($distributionManifest['distribution_format_version'] ?? null) !== '1'
        || ($releaseManifest['distribution_format_version'] ?? null) !== '1'
        || ($distributionManifest['distribution_format_version'] ?? null) !== ($releaseManifest['distribution_format_version'] ?? null)) {
        $errors[] = 'Distribution format versions do not match';
    }
    foreach (['deterministic_source_content', 'deterministic_archive_bytes'] as $field) {
        if (($distributionManifest[$field] ?? null) !== true || ($releaseManifest[$field] ?? null) !== true) {
            $errors[] = "Both manifests must declare {$field}=true";
        }
    }

    $releasePlugins = published_release_plugin_map($releaseManifest, 'Release manifest', $errors);
    $distributionPlugins = published_release_plugin_map($distributionManifest, 'Distribution manifest', $errors);
    foreach (PUBLISHED_RELEASE_PLUGIN_MAIN_FILES as $slug => $_mainFile) {
        if (!isset($releasePlugins[$slug], $distributionPlugins[$slug])) {
            continue;
        }
        $releasePlugin = $releasePlugins[$slug];
        $distributionPlugin = $distributionPlugins[$slug];
        ksort($releasePlugin, SORT_STRING);
        ksort($distributionPlugin, SORT_STRING);
        if ($releasePlugin !== $distributionPlugin) {
            $errors[] = "Release and distribution plugin rows differ for {$slug}";
        }
    }

    $actualHashes = [];
    foreach (PUBLISHED_RELEASE_ASSET_NAMES as $name) {
        $hash = hash_file('sha256', $assetDirectory . '/' . $name);
        if (!is_string($hash)) {
            $errors[] = "Unable to hash release asset {$name}";
            continue;
        }
        $actualHashes[$name] = $hash;
    }

    foreach ($release['assets'] as $asset) {
        $name = $asset['name'];
        if (!isset($actualHashes[$name])) {
            continue;
        }
        if (($asset['digest'] ?? null) !== 'sha256:' . $actualHashes[$name]) {
            $errors[] = "GitHub asset digest does not match downloaded bytes for {$name}";
        }
    }
    foreach ($releasePlugins as $slug => $plugin) {
        $filename = $plugin['archive_filename'] ?? null;
        if (!is_string($filename) || !isset($actualHashes[$filename])) {
            $errors[] = "Release manifest archive is missing for {$slug}";
            continue;
        }
        if (($plugin['archive_sha256'] ?? null) !== $actualHashes[$filename]) {
            $errors[] = "Release manifest archive SHA-256 does not match downloaded bytes for {$slug}";
        }
    }

    $pluginArchives = array_map(
        static fn (array $plugin): string => (string) $plugin['archive_filename'],
        array_values($releasePlugins)
    );
    $errors = array_merge(
        $errors,
        published_release_checksum_errors(
            $assetDirectory . '/SHA256SUMS',
            'SHA256SUMS',
            $pluginArchives,
            $actualHashes
        ),
        published_release_checksum_errors(
            $assetDirectory . '/RELEASE_SHA256SUMS',
            'RELEASE_SHA256SUMS',
            array_merge($pluginArchives, ['manifest.json', 'release-manifest.json']),
            $actualHashes
        )
    );

    if ($candidateDirectory !== null) {
        $candidateErrors = published_release_directory_errors($candidateDirectory, 'Candidate');
        $errors = array_merge($errors, $candidateErrors);
        if ($candidateErrors === []) {
            foreach (PUBLISHED_RELEASE_ASSET_NAMES as $name) {
                $candidateHash = hash_file('sha256', $candidateDirectory . '/' . $name);
                if (!is_string($candidateHash) || !isset($actualHashes[$name]) || !hash_equals($actualHashes[$name], $candidateHash)) {
                    $errors[] = "Candidate bytes do not match published asset {$name}";
                }
            }
        }
    }

    return array_values(array_unique($errors));
}

/** @return array<string, string> */
function published_release_cli_arguments(array $arguments): array
{
    $parsed = [];
    for ($index = 0; $index < count($arguments); $index++) {
        $key = $arguments[$index];
        if (!str_starts_with($key, '--') || !isset($arguments[$index + 1])) {
            throw new InvalidArgumentException('Invalid command-line arguments');
        }
        $parsed[substr($key, 2)] = $arguments[++$index];
    }

    return $parsed;
}

if (realpath($argv[0] ?? '') === realpath(__FILE__)) {
    try {
        $options = published_release_cli_arguments(array_slice($argv, 1));
    } catch (Throwable) {
        fwrite(STDERR, "Usage: php published-release-validate.php --metadata <release.json> --tag <tag> [--metadata-only] [--tag-target <sha> --source-tree <sha> --ancestry <json> --assets-dir <dir> [--candidate-dir <dir>]\n");
        exit(2);
    }

    $metadataPath = $options['metadata'] ?? null;
    $requestedTag = $options['tag'] ?? null;
    if (!is_string($metadataPath) || !is_file($metadataPath) || !is_string($requestedTag)) {
        fwrite(STDERR, "Release metadata and tag are required\n");
        exit(2);
    }

    try {
        $release = json_decode((string) file_get_contents($metadataPath), true, 512, JSON_THROW_ON_ERROR);
    } catch (Throwable) {
        fwrite(STDERR, "GitHub release metadata is malformed\n");
        exit(1);
    }
    if (!is_array($release)) {
        fwrite(STDERR, "GitHub release metadata must contain an object\n");
        exit(1);
    }

    $errors = published_release_metadata_errors($release, $requestedTag);
    if (!isset($options['metadata-only'])) {
        foreach (['tag-target', 'source-tree', 'ancestry', 'assets-dir'] as $required) {
            if (!isset($options[$required])) {
                $errors[] = "Missing required verifier input {$required}";
            }
        }
        if ($errors === []) {
            try {
                $ancestry = json_decode($options['ancestry'], true, 512, JSON_THROW_ON_ERROR);
            } catch (Throwable) {
                $ancestry = null;
            }
            if (!is_array($ancestry)) {
                $errors[] = 'GitHub ancestry evidence is malformed';
            } else {
                $errors = published_release_validation_errors(
                    $release,
                    $requestedTag,
                    $options['tag-target'],
                    $options['source-tree'],
                    $ancestry,
                    $options['assets-dir'],
                    $options['candidate-dir'] ?? null
                );
            }
        }
    }

    if ($errors !== []) {
        fwrite(STDERR, "Published release verification failed:\n");
        foreach ($errors as $error) {
            fwrite(STDERR, "  - {$error}\n");
        }
        exit(1);
    }

    fwrite(STDOUT, $options['metadata-only'] ?? false
        ? "Published release metadata passed\n"
        : "Published release verification passed for {$requestedTag}\n");
}
