<?php

declare(strict_types=1);

require_once __DIR__ . '/release-candidate-verify.php';

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

function expect_release_id_validation(string $releaseId, bool $shouldPass, string $label): void
{
    $root = repo_root();
    $command = [
        'bash',
        '-c',
        'source "$1" && validate_suite_release_id "$2"',
        'bash',
        $root . '/scripts/lib/wordpress_plugin_release_common.sh',
        $releaseId,
    ];
    $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, $root);
    if (!is_resource($process)) {
        ReleaseCandidateTest::ok($label, false);

        return;
    }
    fclose($pipes[1]);
    fclose($pipes[2]);
    $code = proc_close($process);
    ReleaseCandidateTest::ok($label, ($code === 0) === $shouldPass);
}

function run_candidate_verify(string $candidateDir): void
{
    $errors = release_candidate_verify($candidateDir, repo_root());
    ReleaseCandidateTest::ok('release-candidate-verify binding', $errors === []);
    if ($errors !== []) {
        foreach ($errors as $error) {
            ReleaseCandidateTest::ok('binding detail: ' . $error, false);
        }
    }

    $tamperRoot = sys_get_temp_dir() . '/es-wp-candidate-tamper-' . getmypid();
    if (is_dir($tamperRoot)) {
        exec('rm -rf ' . escapeshellarg($tamperRoot));
    }
    mkdir($tamperRoot);
    exec('cp -a ' . escapeshellarg($candidateDir) . '/. ' . escapeshellarg($tamperRoot));
    $releasePath = $tamperRoot . '/release-manifest.json';
    $release = json_decode((string) file_get_contents($releasePath), true, 512, JSON_THROW_ON_ERROR);
    $release['plugins'][0]['marketing_version'] = '9.9.9';
    file_put_contents($releasePath, json_encode($release, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);
    $tamperErrors = release_candidate_verify($tamperRoot, repo_root());
    ReleaseCandidateTest::ok('tampered release manifest rejected', $tamperErrors !== []);
    exec('rm -rf ' . escapeshellarg($tamperRoot));

    $calendarRoot = sys_get_temp_dir() . '/es-wp-candidate-calendar-' . getmypid();
    mkdir($calendarRoot);
    exec('cp -a ' . escapeshellarg($candidateDir) . '/. ' . escapeshellarg($calendarRoot));
    $calendarReleasePath = $calendarRoot . '/release-manifest.json';
    $calendarRelease = json_decode((string) file_get_contents($calendarReleasePath), true, 512, JSON_THROW_ON_ERROR);
    $calendarRelease['suite_release_id'] = '2026.02.31.1';
    $calendarRelease['suggested_tag'] = 'eventsales-wp-2026.02.31.1';
    file_put_contents($calendarReleasePath, json_encode($calendarRelease, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);
    $calendarErrors = release_candidate_verify($calendarRoot, repo_root());
    ReleaseCandidateTest::ok('invalid calendar suite_release_id rejected', $calendarErrors !== []);
    exec('rm -rf ' . escapeshellarg($calendarRoot));

    $phpFloorRoot = sys_get_temp_dir() . '/es-wp-candidate-php-' . getmypid();
    mkdir($phpFloorRoot);
    exec('cp -a ' . escapeshellarg($candidateDir) . '/. ' . escapeshellarg($phpFloorRoot));
    $phpRelease = json_decode((string) file_get_contents($phpFloorRoot . '/release-manifest.json'), true, 512, JSON_THROW_ON_ERROR);
    $phpRelease['requires_php'] = '7.4';
    file_put_contents(
        $phpFloorRoot . '/release-manifest.json',
        json_encode($phpRelease, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL
    );
    ReleaseCandidateTest::ok(
        'tampered requires_php rejected',
        release_candidate_verify($phpFloorRoot, repo_root()) !== []
    );
    exec('rm -rf ' . escapeshellarg($phpFloorRoot));

    $suitePathRoot = sys_get_temp_dir() . '/es-wp-candidate-suite-path-' . getmypid();
    mkdir($suitePathRoot);
    exec('cp -a ' . escapeshellarg($candidateDir) . '/. ' . escapeshellarg($suitePathRoot));
    $suitePathRelease = json_decode((string) file_get_contents($suitePathRoot . '/release-manifest.json'), true, 512, JSON_THROW_ON_ERROR);
    $suitePathRelease['suite_manifest_git_path'] = 'integrations/wordpress/other-suite.json';
    file_put_contents(
        $suitePathRoot . '/release-manifest.json',
        json_encode($suitePathRelease, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL
    );
    ReleaseCandidateTest::ok(
        'tampered suite_manifest_git_path rejected',
        release_candidate_verify($suitePathRoot, repo_root()) !== []
    );
    exec('rm -rf ' . escapeshellarg($suitePathRoot));
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

expect_release_id_validation('2026.10.04.1', true, 'accept valid calendar release id');
expect_release_id_validation('2026.02.31.1', false, 'reject impossible February date');
expect_release_id_validation('2023.02.29.1', false, 'reject non-leap Feb 29');
expect_release_id_validation('2024.02.29.1', true, 'accept leap-year Feb 29');

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
run_cmd_expect_fail(
    ['bash', $buildScript, '--ref', $head, '--release-id', '2026.02.31.1'],
    'reject invalid calendar release ID in builder'
);

$tree = trim((string) shell_exec('git -C ' . escapeshellarg($root) . ' rev-parse HEAD^{tree}'));
run_cmd_expect_fail(
    ['bash', $buildScript, '--ref', $tree, '--release-id', '2026.10.04.1'],
    'reject tree object instead of commit'
);

ReleaseCandidateTest::finish();
