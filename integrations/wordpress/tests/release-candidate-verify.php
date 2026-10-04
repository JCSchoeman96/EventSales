<?php

declare(strict_types=1);

/**
 * Tight release-candidate verification (distribution + release manifest binding).
 */

require_once __DIR__ . '/release-manifest-contract.php';

/** @return array<string, mixed>|null */
function load_suite_manifest_from_git(string $repoRoot, string $commit, string $gitPath): ?array
{
    $command = ['git', '-C', $repoRoot, 'show', "{$commit}:{$gitPath}"];
    $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($process)) {
        return null;
    }

    $stdout = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $exitCode = proc_close($process);
    if ($exitCode !== 0 || $stdout === false || $stdout === '') {
        return null;
    }

    try {
        return json_decode($stdout, true, 512, JSON_THROW_ON_ERROR);
    } catch (Throwable) {
        return null;
    }
}

/** @return list<string> */
function release_candidate_verify(string $candidateDir, ?string $repoRoot = null): array
{
    $errors = [];
    $candidateDir = rtrim($candidateDir, '/');
    $repoRoot ??= dirname(__DIR__, 3);

    $releasePath = $candidateDir . '/release-manifest.json';
    $distPath = $candidateDir . '/manifest.json';
    $sumsPath = $candidateDir . '/RELEASE_SHA256SUMS';

    if (!is_file($releasePath)) {
        return ['Missing release-manifest.json'];
    }
    if (!is_file($distPath)) {
        return ['Missing manifest.json'];
    }
    if (!is_file($sumsPath)) {
        return ['Missing RELEASE_SHA256SUMS'];
    }

    try {
        $release = json_decode((string) file_get_contents($releasePath), true, 512, JSON_THROW_ON_ERROR);
        $dist = json_decode((string) file_get_contents($distPath), true, 512, JSON_THROW_ON_ERROR);
    } catch (Throwable $e) {
        return ['Unable to parse manifest JSON: ' . $e->getMessage()];
    }

    if (($release['release_manifest_format_version'] ?? '') !== '1') {
        $errors[] = 'release_manifest_format_version must be 1';
    }

    foreach (release_manifest_contract_errors($release, 'release manifest') as $contractError) {
        $errors[] = $contractError;
    }

    $sourceCommit = strtolower((string) ($release['source_commit'] ?? ''));
    $sourceTree = strtolower((string) ($release['source_tree'] ?? ''));

    if ($sourceCommit !== strtolower((string) ($dist['source_commit'] ?? ''))) {
        $errors[] = 'source_commit mismatch between release and distribution manifests';
    }
    if ($sourceTree !== strtolower((string) ($dist['source_tree'] ?? ''))) {
        $errors[] = 'source_tree mismatch between release and distribution manifests';
    }

    if ($sourceCommit !== '' && preg_match('/^[0-9a-f]{40}$/', $sourceCommit)) {
        $command = ['git', '-C', $repoRoot, 'rev-parse', "{$sourceCommit}^{tree}"];
        $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        if (is_resource($process)) {
            $stdout = trim((string) stream_get_contents($pipes[1]));
            fclose($pipes[1]);
            fclose($pipes[2]);
            proc_close($process);
            if ($stdout !== $sourceTree) {
                $errors[] = 'source_tree does not match source_commit^{tree}';
            }
        } else {
            $errors[] = 'Unable to verify source_tree against git';
        }
    }

    foreach (
        [
            'deterministic_source_content' => true,
            'deterministic_archive_bytes' => true,
        ] as $field => $expected
    ) {
        if (($release[$field] ?? null) !== ($dist[$field] ?? null)) {
            $errors[] = "release/distribution mismatch for {$field}";
        }
        if (($dist[$field] ?? null) !== $expected) {
            $errors[] = "distribution manifest {$field} must be true";
        }
    }

    if (($release['distribution_format_version'] ?? '') !== (string) ($dist['distribution_format_version'] ?? '')) {
        $errors[] = 'distribution_format_version mismatch between release and distribution manifests';
    }

    $distSuitePath = (string) ($dist['suite_manifest_git_path'] ?? '');
    $releaseSuitePath = (string) ($release['suite_manifest_git_path'] ?? '');
    if ($distSuitePath === '' || $releaseSuitePath === '') {
        $errors[] = 'suite_manifest_git_path missing from release or distribution manifest';
    } elseif ($releaseSuitePath !== $distSuitePath) {
        $errors[] = 'suite_manifest_git_path mismatch between release and distribution manifests';
    }

    if ($sourceCommit !== '' && preg_match('/^[0-9a-f]{40}$/', $sourceCommit) && $releaseSuitePath !== '') {
        $suiteAtSource = load_suite_manifest_from_git($repoRoot, $sourceCommit, $releaseSuitePath);
        if ($suiteAtSource === null) {
            $errors[] = 'unable to load suite manifest from source_commit at suite_manifest_git_path';
        } else {
            $expectedPhp = (string) ($suiteAtSource['requires_php'] ?? '');
            $expectedWp = (string) ($suiteAtSource['requires_at_least_wordpress'] ?? '');
            if ((string) ($release['requires_php'] ?? '') !== $expectedPhp) {
                $errors[] = 'requires_php must match suite manifest at source_commit';
            }
            if ((string) ($release['requires_wordpress'] ?? '') !== $expectedWp) {
                $errors[] = 'requires_wordpress must match suite manifest at source_commit';
            }
        }
    }

    $distPlugins = [];
    foreach ($dist['plugins'] ?? [] as $plugin) {
        if (!is_array($plugin)) {
            continue;
        }
        $distPlugins[(string) $plugin['slug']] = $plugin;
    }
    $releasePlugins = [];
    foreach ($release['plugins'] ?? [] as $plugin) {
        if (!is_array($plugin)) {
            continue;
        }
        $releasePlugins[(string) $plugin['slug']] = $plugin;
    }

    if (count($distPlugins) !== 4 || count($releasePlugins) !== 4) {
        $errors[] = 'release and distribution manifests must each list four plugins';
    }

    foreach ($distPlugins as $slug => $distPlugin) {
        if (!isset($releasePlugins[$slug])) {
            $errors[] = "release manifest missing plugin {$slug}";
            continue;
        }
        if ($releasePlugins[$slug] != $distPlugin) {
            $errors[] = "release manifest plugin {$slug} does not exactly match distribution manifest";
        }
        $archiveName = (string) $distPlugin['archive_filename'];
        $archivePath = $candidateDir . '/' . $archiveName;
        if (!is_file($archivePath)) {
            $errors[] = "missing archive file {$archiveName}";
            continue;
        }
        $actualSha = strtolower(hash_file('sha256', $archivePath));
        $declaredSha = strtolower((string) $distPlugin['archive_sha256']);
        if ($actualSha !== $declaredSha) {
            $errors[] = "archive_sha256 mismatch on disk for {$slug}";
        }
    }

    $expectedSumTargets = [];
    foreach ($distPlugins as $plugin) {
        $expectedSumTargets[] = (string) $plugin['archive_filename'];
    }
    $expectedSumTargets[] = 'manifest.json';
    $expectedSumTargets[] = 'release-manifest.json';
    sort($expectedSumTargets);

    $sumTargets = [];
    $sumLines = file($sumsPath, FILE_IGNORE_NEW_LINES);
    if ($sumLines === false) {
        $errors[] = 'Unable to read RELEASE_SHA256SUMS';
    } else {
        foreach ($sumLines as $line) {
            if (trim($line) === '') {
                continue;
            }
            if (!preg_match('/^([0-9a-f]{64})\s+(\S+)\s*$/', $line, $matches)) {
                $errors[] = 'Malformed RELEASE_SHA256SUMS line';
                continue;
            }
            $sumTargets[] = $matches[2];
        }
        sort($sumTargets);
        if ($sumTargets !== $expectedSumTargets) {
            $errors[] = 'RELEASE_SHA256SUMS must cover exactly four ZIPs, manifest.json, and release-manifest.json';
        }
    }

    return $errors;
}

if (realpath($argv[0] ?? '') === realpath(__FILE__)) {
    $candidateDir = null;
    for ($i = 1; $i < $argc; $i++) {
        if ($argv[$i] === '--candidate' && isset($argv[$i + 1])) {
            $candidateDir = $argv[$i + 1];
            $i++;
        }
    }
    if ($candidateDir === null) {
        fwrite(STDERR, "Usage: php release-candidate-verify.php --candidate <dir>\n");
        exit(1);
    }

    $errors = release_candidate_verify($candidateDir);
    if ($errors !== []) {
        fwrite(STDERR, "release-candidate-verify failed:\n");
        foreach ($errors as $error) {
            fwrite(STDERR, "  - {$error}\n");
        }
        exit(1);
    }

    fwrite(STDOUT, "release-candidate-verify passed\n");
    exit(0);
}
