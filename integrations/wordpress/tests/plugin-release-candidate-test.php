<?php

declare(strict_types=1);

final class ReleaseCandidateTest
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
            fwrite(STDERR, "plugin-release-candidate-test failures:\n");
            foreach (self::$failures as $failure) {
                fwrite(STDERR, "  - {$failure}\n");
            }
            exit(1);
        }

        fwrite(STDOUT, 'plugin-release-candidate-test: ' . self::$passes . " assertions passed\n");
    }
}

function repo_root(): string
{
    return dirname(__DIR__, 3);
}

function run_cmd_expect_fail(array $command, string $label): void
{
    $process = proc_open(
        $command,
        [
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ],
        $pipes,
        repo_root()
    );
    if (!is_resource($process)) {
        ReleaseCandidateTest::ok($label, false);

        return;
    }
    fclose($pipes[1]);
    fclose($pipes[2]);
    $code = proc_close($process);
    ReleaseCandidateTest::ok($label, $code !== 0);
}

function run_candidate_verify(string $candidateDir): void
{
    $manifestPath = $candidateDir . '/release-manifest.json';
    ReleaseCandidateTest::ok('release-manifest.json exists', is_file($manifestPath));
    if (!is_file($manifestPath)) {
        return;
    }

    $manifest = json_decode((string) file_get_contents($manifestPath), true, 512, JSON_THROW_ON_ERROR);
    ReleaseCandidateTest::ok('release_manifest_format_version', ($manifest['release_manifest_format_version'] ?? '') === '1');
    ReleaseCandidateTest::ok('suite_release_id present', isset($manifest['suite_release_id']));
    ReleaseCandidateTest::ok('suggested_tag prefix', str_starts_with((string) ($manifest['suggested_tag'] ?? ''), 'eventsales-wp-'));
    ReleaseCandidateTest::ok('deterministic_archive_bytes true', ($manifest['deterministic_archive_bytes'] ?? false) === true);
    ReleaseCandidateTest::ok('RELEASE_SHA256SUMS exists', is_file($candidateDir . '/RELEASE_SHA256SUMS'));

    $distManifest = json_decode((string) file_get_contents($candidateDir . '/manifest.json'), true, 512, JSON_THROW_ON_ERROR);
    ReleaseCandidateTest::ok(
        'distribution source_commit matches release manifest',
        ($distManifest['source_commit'] ?? '') === ($manifest['source_commit'] ?? '')
    );
}

$candidateDir = null;
foreach (array_slice($argv, 1) as $arg) {
    if ($arg === '--candidate') {
        continue;
    }
    if (str_starts_with($arg, '--')) {
        continue;
    }
    $candidateDir = $arg;
}

if ($candidateDir !== null) {
    run_candidate_verify(rtrim($candidateDir, '/'));
    ReleaseCandidateTest::finish();
    exit(0);
}

$root = repo_root();
$head = trim((string) shell_exec('git -C ' . escapeshellarg($root) . ' rev-parse HEAD'));
ReleaseCandidateTest::ok('HEAD is 40-char sha', preg_match('/^[0-9a-f]{40}$/', $head) === 1);

$buildScript = $root . '/scripts/build_wordpress_plugin_release_candidate.sh';

run_cmd_expect_fail(
    ['bash', $buildScript, '--ref', 'not-a-sha', '--release-id', '2026.10.04.1'],
    'reject malformed SHA'
);
run_cmd_expect_fail(
    ['bash', $buildScript, '--ref', str_repeat('f', 40), '--release-id', '2026.10.04.1'],
    'reject unknown SHA'
);
run_cmd_expect_fail(
    ['bash', $buildScript, '--ref', $head, '--release-id', 'not-valid'],
    'reject invalid release ID'
);

$tree = trim((string) shell_exec('git -C ' . escapeshellarg($root) . ' rev-parse HEAD^{tree}'));
run_cmd_expect_fail(
    ['bash', $buildScript, '--ref', $tree, '--release-id', '2026.10.04.1'],
    'reject tree object instead of commit'
);

ReleaseCandidateTest::finish();
