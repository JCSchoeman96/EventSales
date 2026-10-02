<?php

/**
 * Catalogue-change trigger and SnapshotGeneration rotation tests.
 *
 * Options are backed by an in-memory array so the SnapshotGeneration record
 * persists across calls and stays separate from the transient cache version.
 */

define('ABSPATH', __DIR__);
define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);
define('EVENTSALES_CATALOG_CHANGE_ENDPOINT', 'https://eventsales.example/webhooks/catalog-change/PATH_TOKEN_DO_NOT_RENDER');
define('EVENTSALES_CATALOG_CHANGE_SECRET', 'SUPER_SECRET_DO_NOT_RENDER');
define('EVENTSALES_CATALOG_CHANGE_KEY_ID', 'KEY_ID_DO_NOT_PERSIST');

const CACHE_VERSION_OPTION = 'eventsales_tickera_catalog_feed_cache_version';
const SNAPSHOT_GENERATION_OPTION = 'eventsales_tickera_catalog_snapshot_generation';
const DELIVERY_TELEMETRY_OPTION = 'eventsales_catalog_change_delivery_telemetry';

$actions = [];
$scheduled = [];
$remote_requests = [];
$retry_actions = [];
$retry_schedule_calls = 0;
$retry_schedule_result = 1;
$options = [];
$option_writes = [];
$option_autoload = [];
$remote_response = ['response' => ['code' => 503]];
$passes = 0;
$failures = [];

class WP_Error
{
    public string $message;

    public function __construct(string $message)
    {
        $this->message = $message;
    }
}

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
    global $options, $option_writes, $option_autoload;
    $options[$name] = $value;
    $option_writes[$name] = ($option_writes[$name] ?? 0) + 1;
    $option_autoload[$name] = $autoload;
    return true;
}
function wp_is_post_autosave($id) { return false; }
function wp_is_post_revision($id) { return false; }
function get_post_type($id) { return $id === 2 ? 'product_variation' : 'product'; }
function wp_generate_uuid4() { return '123e4567-e89b-42d3-a456-426614174000'; }
function wp_json_encode($value) { return json_encode($value); }
function wp_parse_url($url, $component = -1) { return parse_url($url, $component); }
function wp_remote_post($url, $args) { global $remote_requests, $remote_response; $remote_requests[] = compact('url', 'args'); return $remote_response; }
function wp_remote_retrieve_response_code($response) { return $response['response']['code']; }
function is_wp_error($value) { return $value instanceof WP_Error; }
function as_enqueue_async_action($hook, $args, $group) { global $scheduled; $scheduled[] = compact('hook', 'args', 'group'); }
function as_schedule_single_action($timestamp, $hook, $args, $group) {
    global $retry_actions, $retry_schedule_calls, $retry_schedule_result;
    $retry_schedule_calls++;
    if ($retry_schedule_result > 0) $retry_actions[] = compact('timestamp', 'hook', 'args', 'group');
    return $retry_schedule_result;
}

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

function delivery_telemetry(): array
{
    if (!method_exists(EventSales_Tickera_Catalog_Feed::class, 'catalog_change_delivery_telemetry')) {
        return [];
    }

    return EventSales_Tickera_Catalog_Feed::catalog_change_delivery_telemetry();
}

function telemetry_json(): string
{
    global $options;

    return json_encode($options[DELIVERY_TELEMETRY_OPTION] ?? null) ?: '';
}

// --- telemetry defaults and separate feed identity -------------------------
check('telemetry accessor exists', method_exists(EventSales_Tickera_Catalog_Feed::class, 'catalog_change_delivery_telemetry'));
$never_attempted = delivery_telemetry();
check('never-attempted read does not create an option', !array_key_exists(DELIVERY_TELEMETRY_OPTION, $options));
check('missing telemetry returns NEVER_ATTEMPTED', ($never_attempted['state'] ?? null) === 'NEVER_ATTEMPTED');
check('telemetry has a separate version identity', ($never_attempted['telemetry_version'] ?? null) === '2026-10-02.v1'
    && EVENTSALES_CATALOG_CHANGE_TELEMETRY_VERSION === '2026-10-02.v1');
check('default telemetry has bounded fixed shape', count($never_attempted) === 8
    && array_keys($never_attempted) === [
        'telemetry_version', 'state', 'last_attempt_at_gmt', 'last_success_at_gmt',
        'last_terminal_failure_at_gmt', 'last_http_status', 'last_failure_category', 'last_attempt_number',
    ]);
check('feed schema identity remains v3', EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION === '2026-08-07.v3');
check('feed canonical identity remains source_risk.v3', EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION === 'source_risk.v3');
check('feed producer identity remains unchanged', EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION === '2026-08-07.1');

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
check('save and invalidation callbacks did not write delivery telemetry', ($option_writes[DELIVERY_TELEMETRY_OPTION] ?? 0) === 0);
$remote_response = ['response' => ['code' => 503]];
$retry_before = time();
EventSales_Tickera_Catalog_Feed::deliver_catalog_change($raw_body, 1);
$retry_after = time();
if (count($remote_requests) !== 1) { fwrite(STDERR, "delivery request missing\n"); exit(1); }
check('one delivery request was made', count($remote_requests) === 1);

$headers = $remote_requests[0]['args']['headers'];
$timestamp = $headers['X-EventSales-Trigger-Timestamp'];
$canonical = implode("\n", ['2026-07-20.v1', 'POST', '/webhooks/catalog-change/PATH_TOKEN_DO_NOT_RENDER', $timestamp, hash('sha256', $raw_body)]);
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
check('attempt one retains its 30 second retry delay', ($retry_actions[0]['timestamp'] ?? 0) >= $retry_before + 30
    && ($retry_actions[0]['timestamp'] ?? 0) <= $retry_after + 30);
check('503 attempt is recorded as retry scheduled', (delivery_telemetry()['state'] ?? null) === 'RETRY_SCHEDULED');
check('positive Action Scheduler ID records retry scheduled', $retry_schedule_result > 0
    && (delivery_telemetry()['state'] ?? null) === 'RETRY_SCHEDULED');
check('retry telemetry records only the closed HTTP category', (delivery_telemetry()['last_failure_category'] ?? null) === 'retryable_http');
check('retry telemetry records safe HTTP status and attempt', (delivery_telemetry()['last_http_status'] ?? null) === 503
    && (delivery_telemetry()['last_attempt_number'] ?? null) === 1);
check('retry telemetry leaves terminal timestamp empty', (delivery_telemetry()['last_terminal_failure_at_gmt'] ?? null) === null);
check('retry telemetry timestamp is UTC seconds format', (bool) preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/', (string) (delivery_telemetry()['last_attempt_at_gmt'] ?? '')));
check('telemetry option disables autoload', ($option_autoload[DELIVERY_TELEMETRY_OPTION] ?? null) === false);
check('persisted telemetry has exactly the allowed keys', count($options[DELIVERY_TELEMETRY_OPTION] ?? []) === 8
    && array_keys($options[DELIVERY_TELEMETRY_OPTION] ?? []) === array_keys($never_attempted));
check('persisted telemetry contains only scalar or null values', count(array_filter(
    $options[DELIVERY_TELEMETRY_OPTION] ?? [],
    static fn ($value): bool => !is_scalar($value) && $value !== null
)) === 0);
check('telemetry omits retry payload fields', !array_key_exists('raw_body', $options[DELIVERY_TELEMETRY_OPTION] ?? [])
    && !array_key_exists('signal_id', $options[DELIVERY_TELEMETRY_OPTION] ?? [])
    && !array_key_exists('history', $options[DELIVERY_TELEMETRY_OPTION] ?? []));

// --- 2xx success ------------------------------------------------------------
$remote_response = ['response' => ['code' => 201], 'body' => 'RESPONSE_BODY_DO_NOT_PERSIST'];
$retry_actions = [];
EventSales_Tickera_Catalog_Feed::deliver_catalog_change($raw_body, 1);
$success_telemetry = delivery_telemetry();
check('2xx response is recorded as success', ($success_telemetry['state'] ?? null) === 'SUCCEEDED');
check('2xx response records its status and attempt', ($success_telemetry['last_http_status'] ?? null) === 201
    && ($success_telemetry['last_attempt_number'] ?? null) === 1);
check('success timestamp matches attempt timestamp', ($success_telemetry['last_success_at_gmt'] ?? null) === ($success_telemetry['last_attempt_at_gmt'] ?? null));
check('success clears failure fields', ($success_telemetry['last_terminal_failure_at_gmt'] ?? null) === null
    && ($success_telemetry['last_failure_category'] ?? null) === null);
check('success does not schedule retry', $retry_actions === []);
check('success telemetry excludes response body, secret and endpoint', strpos(telemetry_json(), 'RESPONSE_BODY_DO_NOT_PERSIST') === false
    && strpos(telemetry_json(), 'SUPER_SECRET_DO_NOT_RENDER') === false
    && strpos(telemetry_json(), 'PATH_TOKEN_DO_NOT_RENDER') === false);

// Verify the remaining existing Action Scheduler delays and argument contract.
$remote_response = ['response' => ['code' => 503]];
foreach ([2 => 120, 3 => 600, 4 => 1800] as $attempt_number => $delay) {
    $retry_actions = [];
    $retry_before = time();
    EventSales_Tickera_Catalog_Feed::deliver_catalog_change($raw_body, $attempt_number);
    $retry_after = time();
    check('attempt ' . $attempt_number . ' retains its retry delay', count($retry_actions) === 1
        && $retry_actions[0]['timestamp'] >= $retry_before + $delay
        && $retry_actions[0]['timestamp'] <= $retry_after + $delay);
    check('attempt ' . $attempt_number . ' increments the existing retry argument', count($retry_actions) === 1
        && ($retry_actions[0]['args']['raw_body'] ?? null) === $raw_body
        && ($retry_actions[0]['args']['attempt'] ?? null) === $attempt_number + 1);
}

// --- transport error is retryable and its message is never persisted --------
$remote_response = new WP_Error('WP_ERROR_DO_NOT_PERSIST');
$retry_actions = [];
EventSales_Tickera_Catalog_Feed::deliver_catalog_change('RAW_BODY_DO_NOT_PERSIST', 1);
$transport_telemetry = delivery_telemetry();
check('transport error is recorded as retry scheduled', ($transport_telemetry['state'] ?? null) === 'RETRY_SCHEDULED');
check('transport error uses status zero and closed category', ($transport_telemetry['last_http_status'] ?? null) === 0
    && ($transport_telemetry['last_failure_category'] ?? null) === 'transport_error');
check('transport retry preserves raw body only in scheduler args', count($retry_actions) === 1
    && ($retry_actions[0]['args']['raw_body'] ?? null) === 'RAW_BODY_DO_NOT_PERSIST'
    && ($retry_actions[0]['args']['attempt'] ?? null) === 2);
check('transport telemetry excludes error and body sentinels', strpos(telemetry_json(), 'WP_ERROR_DO_NOT_PERSIST') === false
    && strpos(telemetry_json(), 'RAW_BODY_DO_NOT_PERSIST') === false);

// --- retry exhaustion -------------------------------------------------------
$remote_response = ['response' => ['code' => 503]];
$retry_actions = [];
EventSales_Tickera_Catalog_Feed::deliver_catalog_change($raw_body, 5);
$exhausted_telemetry = delivery_telemetry();
check('attempt five is terminal', ($exhausted_telemetry['state'] ?? null) === 'TERMINAL_FAILURE');
check('attempt five records terminal timestamp and attempt', is_string($exhausted_telemetry['last_terminal_failure_at_gmt'] ?? null)
    && ($exhausted_telemetry['last_attempt_number'] ?? null) === 5);
check('attempt five does not schedule attempt six', $retry_actions === []);

// --- non-retryable response -------------------------------------------------
$remote_response = ['response' => ['code' => 401]];
$retry_actions = [];
EventSales_Tickera_Catalog_Feed::deliver_catalog_change($raw_body, 1);
$non_retryable_telemetry = delivery_telemetry();
check('non-retryable HTTP response is terminal', ($non_retryable_telemetry['state'] ?? null) === 'TERMINAL_FAILURE');
check('non-retryable HTTP response has closed category and status', ($non_retryable_telemetry['last_failure_category'] ?? null) === 'non_retryable_http'
    && ($non_retryable_telemetry['last_http_status'] ?? null) === 401);
check('non-retryable HTTP response schedules no retry', $retry_actions === []);

// --- retry scheduler returning zero is a terminal scheduling failure -------
$retry_schedule_result = 0;
$retry_schedule_calls = 0;
$retry_actions = [];
$remote_requests = [];
$remote_response = ['response' => ['code' => 503]];
$failed_schedule_body = 'RAW_BODY_FAILED_SCHEDULE_DO_NOT_PERSIST';
EventSales_Tickera_Catalog_Feed::deliver_catalog_change($failed_schedule_body, 1);
$failed_schedule_telemetry = delivery_telemetry();
check('zero scheduler result follows only one original HTTP attempt', count($remote_requests) === 1 && $retry_schedule_calls === 1);
check('zero scheduler result creates no usable retry action', $retry_actions === []);
check('zero scheduler result is a terminal delivery failure', ($failed_schedule_telemetry['state'] ?? null) === 'TERMINAL_FAILURE'
    && is_string($failed_schedule_telemetry['last_terminal_failure_at_gmt'] ?? null));
check('zero scheduler result uses the closed retry scheduling category', ($failed_schedule_telemetry['last_failure_category'] ?? null) === 'retry_schedule_failed');
check('zero scheduler result retains safe HTTP status and attempt', ($failed_schedule_telemetry['last_http_status'] ?? null) === 503
    && ($failed_schedule_telemetry['last_attempt_number'] ?? null) === 1);
check('zero scheduler result telemetry excludes payload and secrets', strpos(telemetry_json(), $failed_schedule_body) === false
    && strpos(telemetry_json(), 'SUPER_SECRET_DO_NOT_RENDER') === false
    && strpos(telemetry_json(), 'PATH_TOKEN_DO_NOT_RENDER') === false);
$retry_schedule_result = 1;

// --- persisted option redaction and scheduler-unavailable terminal state ----
$sentinels = [
    'SUPER_SECRET_DO_NOT_RENDER', 'PATH_TOKEN_DO_NOT_RENDER', 'KEY_ID_DO_NOT_PERSIST',
    'RAW_BODY_DO_NOT_PERSIST', 'RESPONSE_BODY_DO_NOT_PERSIST', 'WP_ERROR_DO_NOT_PERSIST',
    EVENTSALES_CATALOG_CHANGE_ENDPOINT,
];
foreach ($sentinels as $sentinel) {
    check('telemetry excludes sentinel ' . $sentinel, strpos(telemetry_json(), $sentinel) === false);
}

$writes_before_accessor = $option_writes[DELIVERY_TELEMETRY_OPTION] ?? 0;
$options[DELIVERY_TELEMETRY_OPTION]['raw_body'] = 'RAW_BODY_DO_NOT_PERSIST';
$normalized_telemetry = delivery_telemetry();
check('producer accessor drops unexpected stored keys', count($normalized_telemetry) === 8
    && !array_key_exists('raw_body', $normalized_telemetry));
check('producer accessor does not expose unexpected payload sentinels', strpos(json_encode($normalized_telemetry) ?: '', 'RAW_BODY_DO_NOT_PERSIST') === false);
check('producer accessor does not write telemetry', ($option_writes[DELIVERY_TELEMETRY_OPTION] ?? 0) === $writes_before_accessor);

$invalid_terminal_record = $exhausted_telemetry;
$invalid_terminal_record['last_attempt_number'] = 1;
$options[DELIVERY_TELEMETRY_OPTION] = $invalid_terminal_record;
check('producer accessor rejects retryable terminal failures before attempt five', (delivery_telemetry()['state'] ?? null) === 'NEVER_ATTEMPTED');

$no_scheduler_script = "<?php\n"
    . "define('ABSPATH', __DIR__);\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);\n"
    . "define('EVENTSALES_CATALOG_CHANGE_ENDPOINT', 'https://eventsales.example/PATH_TOKEN_DO_NOT_RENDER');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SECRET', 'SUPER_SECRET_DO_NOT_RENDER');\n"
    . "define('EVENTSALES_CATALOG_CHANGE_KEY_ID', 'KEY_ID_DO_NOT_PERSIST');\n"
    . "\$GLOBALS['options'] = [];\n"
    . "\$GLOBALS['remote_calls'] = 0;\n"
    . "function add_action(...\$args) { return true; }\n"
    . "function get_option(\$name, \$default = false) { return \$GLOBALS['options'][\$name] ?? \$default; }\n"
    . "function update_option(\$name, \$value, \$autoload = null) { \$GLOBALS['options'][\$name] = \$value; \$GLOBALS['autoload'] = \$autoload; return true; }\n"
    . "function wp_parse_url(\$url, \$component = -1) { return parse_url(\$url, \$component); }\n"
    . "function wp_remote_post(\$url, \$args) { \$GLOBALS['remote_calls']++; return ['response' => ['code' => 503]]; }\n"
    . "function wp_remote_retrieve_response_code(\$response) { return \$response['response']['code']; }\n"
    . "function is_wp_error(\$value) { return false; }\n"
    . 'require ' . var_export(dirname(__DIR__) . '/eventsales-tickera-catalog-feed.php', true) . ";\n"
    . "EventSales_Tickera_Catalog_Feed::deliver_catalog_change('RAW_BODY_DO_NOT_PERSIST', 1);\n"
    . "echo json_encode(['record' => \$GLOBALS['options']['eventsales_catalog_change_delivery_telemetry'] ?? null, 'autoload' => \$GLOBALS['autoload'] ?? null, 'scheduler' => function_exists('as_schedule_single_action'), 'remote_calls' => \$GLOBALS['remote_calls']]);\n";
$no_scheduler_path = sys_get_temp_dir() . '/eventsales-no-retry-scheduler-' . bin2hex(random_bytes(4)) . '.php';
file_put_contents($no_scheduler_path, $no_scheduler_script);
$no_scheduler_output = shell_exec('php ' . escapeshellarg($no_scheduler_path));
@unlink($no_scheduler_path);
$no_scheduler_result = json_decode((string) $no_scheduler_output, true);
check('missing retry scheduler probe returns clean JSON', is_array($no_scheduler_result));
check('missing scheduler creates no alternate retry function', ($no_scheduler_result['scheduler'] ?? null) === false);
check('missing scheduler performs only the original HTTP attempt', ($no_scheduler_result['remote_calls'] ?? null) === 1);
check('missing scheduler records terminal delivery failure', ($no_scheduler_result['record']['state'] ?? null) === 'TERMINAL_FAILURE');
check('missing scheduler uses closed failure category', ($no_scheduler_result['record']['last_failure_category'] ?? null) === 'retry_schedule_failed');
check('missing scheduler writes telemetry without autoload', ($no_scheduler_result['autoload'] ?? null) === false);

$disabled_sender_script = "<?php\n"
    . "define('ABSPATH', __DIR__);\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', false);\n"
    . "\$GLOBALS['options'] = [];\n"
    . "\$GLOBALS['remote_calls'] = 0;\n"
    . "function add_action(...\$args) { return true; }\n"
    . "function get_option(\$name, \$default = false) { return \$GLOBALS['options'][\$name] ?? \$default; }\n"
    . "function update_option(\$name, \$value, \$autoload = null) { \$GLOBALS['options'][\$name] = \$value; return true; }\n"
    . "function wp_remote_post(\$url, \$args) { \$GLOBALS['remote_calls']++; return ['response' => ['code' => 200]]; }\n"
    . 'require ' . var_export(dirname(__DIR__) . '/eventsales-tickera-catalog-feed.php', true) . ";\n"
    . "EventSales_Tickera_Catalog_Feed::deliver_catalog_change('RAW_BODY_DO_NOT_PERSIST', 1);\n"
    . "echo json_encode(['telemetry_written' => array_key_exists('eventsales_catalog_change_delivery_telemetry', \$GLOBALS['options']), 'remote_calls' => \$GLOBALS['remote_calls']]);\n";
$disabled_sender_path = sys_get_temp_dir() . '/eventsales-disabled-catalog-sender-' . bin2hex(random_bytes(4)) . '.php';
file_put_contents($disabled_sender_path, $disabled_sender_script);
$disabled_sender_output = shell_exec('php ' . escapeshellarg($disabled_sender_path));
@unlink($disabled_sender_path);
$disabled_sender_result = json_decode((string) $disabled_sender_output, true);
check('disabled sender probe returns clean JSON', is_array($disabled_sender_result));
check('disabled sender does not report a fake delivery', ($disabled_sender_result['telemetry_written'] ?? null) === false
    && ($disabled_sender_result['remote_calls'] ?? null) === 0);

$missing_config_script = "<?php\n"
    . "define('ABSPATH', __DIR__);\n"
    . "define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);\n"
    . "\$GLOBALS['options'] = [];\n"
    . "\$GLOBALS['remote_calls'] = 0;\n"
    . "function add_action(...\$args) { return true; }\n"
    . "function get_option(\$name, \$default = false) { return \$GLOBALS['options'][\$name] ?? \$default; }\n"
    . "function update_option(\$name, \$value, \$autoload = null) { \$GLOBALS['options'][\$name] = \$value; return true; }\n"
    . "function wp_remote_post(\$url, \$args) { \$GLOBALS['remote_calls']++; return ['response' => ['code' => 200]]; }\n"
    . 'require ' . var_export(dirname(__DIR__) . '/eventsales-tickera-catalog-feed.php', true) . ";\n"
    . "EventSales_Tickera_Catalog_Feed::deliver_catalog_change('RAW_BODY_DO_NOT_PERSIST', 1);\n"
    . "echo json_encode(['telemetry_written' => array_key_exists('eventsales_catalog_change_delivery_telemetry', \$GLOBALS['options']), 'remote_calls' => \$GLOBALS['remote_calls']]);\n";
$missing_config_path = sys_get_temp_dir() . '/eventsales-missing-catalog-sender-config-' . bin2hex(random_bytes(4)) . '.php';
file_put_contents($missing_config_path, $missing_config_script);
$missing_config_output = shell_exec('php ' . escapeshellarg($missing_config_path));
@unlink($missing_config_path);
$missing_config_result = json_decode((string) $missing_config_output, true);
check('missing sender configuration probe returns clean JSON', is_array($missing_config_result));
check('missing sender configuration does not report a fake delivery', ($missing_config_result['telemetry_written'] ?? null) === false
    && ($missing_config_result['remote_calls'] ?? null) === 0);

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
