<?php

/**
 * Catalogue-change trigger and SnapshotGeneration rotation tests.
 *
 * Options are backed by an in-memory array so the SnapshotGeneration record
 * persists across calls and stays separate from the transient cache version.
 */

define('ABSPATH', __DIR__);
define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);
define('EVENTSALES_CATALOG_CHANGE_ENDPOINT', 'https://eventsales.example/webhooks/catalog-change/token');
define('EVENTSALES_CATALOG_CHANGE_SECRET', 'test-trigger-secret');
define('EVENTSALES_CATALOG_CHANGE_KEY_ID', 'test-key');

const CACHE_VERSION_OPTION = 'eventsales_tickera_catalog_feed_cache_version';
const SNAPSHOT_GENERATION_OPTION = 'eventsales_tickera_catalog_snapshot_generation';

$actions = [];
$scheduled = [];
$remote_requests = [];
$retry_actions = [];
$options = [];
$option_writes = [];
$passes = 0;
$failures = [];

class WP_Post
{
    public int $ID;

    public function __construct(int $id)
    {
        $this->ID = $id;
    }
}

function add_action(...$args) { global $actions; $actions[] = $args; }
function get_option($name, $default = false) { global $options; return array_key_exists($name, $options) ? $options[$name] : $default; }
function update_option($name, $value, $autoload = null) {
    global $options, $option_writes;
    $options[$name] = $value;
    $option_writes[$name] = ($option_writes[$name] ?? 0) + 1;
    return true;
}
function wp_is_post_autosave($id) { return false; }
function wp_is_post_revision($id) { return false; }
function get_post_type($id) { return $id === 2 ? 'product_variation' : 'product'; }
function wp_generate_uuid4() { return '123e4567-e89b-42d3-a456-426614174000'; }
function wp_json_encode($value) { return json_encode($value); }
function wp_parse_url($url, $component = -1) { return parse_url($url, $component); }
function wp_remote_post($url, $args) { global $remote_requests; $remote_requests[] = compact('url', 'args'); return ['response' => ['code' => 503]]; }
function wp_remote_retrieve_response_code($response) { return $response['response']['code']; }
function is_wp_error($value) { return false; }
function as_enqueue_async_action($hook, $args, $group) { global $scheduled; $scheduled[] = compact('hook', 'args', 'group'); }
function as_schedule_single_action($timestamp, $hook, $args, $group) { global $retry_actions; $retry_actions[] = compact('timestamp', 'hook', 'args', 'group'); }

function fire_test_action($hook, ...$args)
{
    global $actions;
    foreach ($actions as $registration) {
        if ($registration[0] === $hook) { ($registration[1])(...$args); }
    }
}

function check(string $label, bool $condition): void
{
    global $passes, $failures;

    if ($condition) {
        $passes++;

        return;
    }

    $failures[] = $label;
}

function cache_version(): int
{
    global $options;

    // The plugin reads this option with a default of 1 before its first write.
    return (int) ($options[CACHE_VERSION_OPTION] ?? 1);
}

function generation_record(): array
{
    global $options;

    return is_array($options[SNAPSHOT_GENERATION_OPTION] ?? null) ? $options[SNAPSHOT_GENERATION_OPTION] : [];
}

function generation_token(): string
{
    return (string) (generation_record()['generation_token'] ?? '');
}

require dirname(__DIR__) . '/eventsales-tickera-catalog-feed.php';

// --- coalescing and reason precedence (unchanged behaviour) ------------------
EventSales_Tickera_Catalog_Feed::record_catalog_change(1, 'saved');
EventSales_Tickera_Catalog_Feed::record_catalog_change(1, 'metadata_changed');
EventSales_Tickera_Catalog_Feed::record_catalog_change(2, 'saved');
EventSales_Tickera_Catalog_Feed::flush_catalog_changes();

if (count($scheduled) !== 2) { fwrite(STDERR, "expected two coalesced actions\n"); exit(1); }
check('two catalogue changes are coalesced', count($scheduled) === 2);

$first = json_decode($scheduled[0]['args']['raw_body'], true);
if ($first['reason'] !== 'metadata_changed') { fwrite(STDERR, "reason precedence failed\n"); exit(1); }
check('reason precedence keeps the higher priority reason', $first['reason'] === 'metadata_changed');

// --- every catalogue-relevant invalidation rotates SnapshotGeneration -------
EventSales_Tickera_Catalog_Feed::read_or_create_snapshot_generation();
check('generation record is created on first read', generation_token() !== '');
check('generation token is opaque hex', (bool) preg_match('/^[a-f0-9]{32,}$/', generation_token()));
check('generation_at is rfc3339 z', (bool) preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/', (string) (generation_record()['generation_at'] ?? '')));
check('generation record has exactly two fields', count(generation_record()) === 2);

$observed_tokens = [generation_token()];

/**
 * @var array<string, callable> $invalidation_paths
 */
$invalidation_paths = [
    'invalidate_cache' => static function (): void {
        EventSales_Tickera_Catalog_Feed::invalidate_cache();
    },
    'metadata_changed' => static function (): void {
        EventSales_Tickera_Catalog_Feed::record_meta_change(1, 1, '_price');
    },
    'event_metadata_changed' => static function (): void {
        EventSales_Tickera_Catalog_Feed::record_meta_change(1, 1, '_event_name');
    },
    'status_changed' => static function (): void {
        EventSales_Tickera_Catalog_Feed::record_status_change('publish', 'draft', new WP_Post(1));
    },
    'trashed_post' => static function (): void {
        fire_test_action('trashed_post', 1);
    },
    'untrashed_post' => static function (): void {
        fire_test_action('untrashed_post', 1);
    },
    'before_delete_post' => static function (): void {
        fire_test_action('before_delete_post', 1);
    },
    'save_post_product' => static function (): void {
        fire_test_action('save_post_product', 1);
    },
    'save_post_product_variation' => static function (): void {
        fire_test_action('save_post_product_variation', 2);
    },
    'save_post_tc_events' => static function (): void {
        fire_test_action('save_post_tc_events', 1);
    },
];

foreach ($invalidation_paths as $label => $invalidate) {
    $version_before = cache_version();
    $token_before = generation_token();

    $invalidate();

    $version_after = cache_version();
    $token_after = generation_token();

    if ($version_after !== $version_before + 1) {
        fwrite(STDERR, "{$label} cache invalidation failed\n");
        exit(1);
    }

    check($label . ' bumps the cache version exactly once', $version_after === $version_before + 1);
    check($label . ' rotates the generation token', $token_after !== $token_before);
    check($label . ' keeps the generation token opaque', (bool) preg_match('/^[a-f0-9]{32,}$/', $token_after));
    check($label . ' keeps the generation record shape', count(generation_record()) === 2);

    $observed_tokens[] = $token_after;
}

check(
    'every invalidation minted a distinct generation token',
    count($observed_tokens) === count(array_unique($observed_tokens))
);

// two consecutive invalidations must not reuse a token
$token_before_pair = generation_token();
EventSales_Tickera_Catalog_Feed::invalidate_cache();
$token_middle = generation_token();
EventSales_Tickera_Catalog_Feed::invalidate_cache();
$token_last = generation_token();

check('first of two invalidations changes the token', $token_middle !== $token_before_pair);
check('second of two invalidations changes the token again', $token_last !== $token_middle);
check('two invalidations never reuse the original token', $token_last !== $token_before_pair);

// --- the cache version and SnapshotGeneration are separate records ----------
check('cache version option name differs from the generation option name', CACHE_VERSION_OPTION !== SNAPSHOT_GENERATION_OPTION);
check('cache version is stored as an integer', is_int($options[CACHE_VERSION_OPTION]));
check('generation record is stored as an array', is_array($options[SNAPSHOT_GENERATION_OPTION]));
check('generation record does not hold the cache version', !array_key_exists('cache_version', generation_record()));
check('cache version is not a generation token', (string) $options[CACHE_VERSION_OPTION] !== generation_token());
check('both options were written', ($option_writes[CACHE_VERSION_OPTION] ?? 0) > 0 && ($option_writes[SNAPSHOT_GENERATION_OPTION] ?? 0) > 0);
check(
    'each invalidation writes both options the same number of times',
    $option_writes[CACHE_VERSION_OPTION] === $option_writes[SNAPSHOT_GENERATION_OPTION] - 1
);

// a non-catalogue meta key must not invalidate anything
$version_before_noop = cache_version();
$token_before_noop = generation_token();
EventSales_Tickera_Catalog_Feed::record_meta_change(1, 1, '_unrelated_meta_key');
check('unrelated metadata does not bump the cache version', cache_version() === $version_before_noop);
check('unrelated metadata does not rotate the generation token', generation_token() === $token_before_noop);

// --- delivery signature and retry preservation (unchanged behaviour) --------
$raw_body = $scheduled[0]['args']['raw_body'];
EventSales_Tickera_Catalog_Feed::deliver_catalog_change($raw_body, 1);
if (count($remote_requests) !== 1) { fwrite(STDERR, "delivery request missing\n"); exit(1); }
check('one delivery request was made', count($remote_requests) === 1);

$headers = $remote_requests[0]['args']['headers'];
$timestamp = $headers['X-EventSales-Trigger-Timestamp'];
$canonical = implode("\n", ['2026-07-20.v1', 'POST', '/webhooks/catalog-change/token', $timestamp, hash('sha256', $raw_body)]);
$expected = 'v1=' . hash_hmac('sha256', $canonical, EVENTSALES_CATALOG_CHANGE_SECRET);
if (!hash_equals($expected, $headers['X-EventSales-Trigger-Signature'])) { fwrite(STDERR, "delivery signature failed\n"); exit(1); }
check('delivery signature is unchanged', hash_equals($expected, $headers['X-EventSales-Trigger-Signature']));

if (count($retry_actions) !== 1 || $retry_actions[0]['args']['raw_body'] !== $raw_body || $retry_actions[0]['args']['attempt'] !== 2) {
    fwrite(STDERR, "retry did not preserve raw body\n");
    exit(1);
}
check('retry preserves the raw body and attempt', count($retry_actions) === 1
    && $retry_actions[0]['args']['raw_body'] === $raw_body
    && $retry_actions[0]['args']['attempt'] === 2);

if ($failures !== []) {
    fwrite(STDERR, "catalog change trigger tests FAILED\n");

    foreach ($failures as $failure) {
        fwrite(STDERR, '  - ' . $failure . "\n");
    }

    fwrite(STDERR, sprintf("passed: %d, failed: %d\n", $passes, count($failures)));
    exit(1);
}

echo sprintf("catalog change trigger tests passed: %d assertions, 0 failures\n", $passes);
exit(0);
