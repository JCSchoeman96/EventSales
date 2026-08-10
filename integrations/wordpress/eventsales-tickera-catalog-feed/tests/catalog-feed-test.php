<?php

declare(strict_types=1);

/**
 * Native 2026-08-07.v3 producer tests for the EventSales Tickera catalog feed.
 *
 * The plugin is loaded under a lightweight WordPress mock harness so the
 * producer helpers are exercised as real code instead of matched as strings.
 * The transport contract mirrored here matches the Phoenix
 * SourceRiskV3.ContractRegistry and SourceRiskV3.Evidence expectations.
 */

define('ABSPATH', __DIR__);
define('ARRAY_A', 'ARRAY_A');

$GLOBALS['options'] = [];
$GLOBALS['home_url'] = 'http://localhost:10059';

function add_action($hook, $callback, $priority = 10, $accepted_args = 1)
{
    return true;
}

function get_option($name, $default = false)
{
    return array_key_exists($name, $GLOBALS['options']) ? $GLOBALS['options'][$name] : $default;
}

function update_option($name, $value, $autoload = null)
{
    $GLOBALS['options'][$name] = $value;

    return true;
}

function wp_parse_url($url, $component = -1)
{
    return parse_url($url, $component);
}

function wp_json_encode($value)
{
    return json_encode($value);
}

function wp_generate_uuid4()
{
    return '123e4567-e89b-42d3-a456-426614174000';
}

function home_url($path = '')
{
    return $GLOBALS['home_url'] . $path;
}

function get_post_type($id)
{
    return 'product';
}

function wp_is_post_autosave($id)
{
    return false;
}

function wp_is_post_revision($id)
{
    return false;
}

require dirname(__DIR__) . '/eventsales-tickera-catalog-feed.php';

class_alias('EventSales_Tickera_Catalog_Feed', 'Feed');

final class T
{
    public static int $passes = 0;

    /** @var array<int, string> */
    public static array $failures = [];

    public static function ok(string $label, bool $condition): void
    {
        if ($condition) {
            self::$passes++;

            return;
        }

        self::$failures[] = $label;
    }

    public static function same(string $label, $expected, $actual): void
    {
        if ($expected === $actual) {
            self::$passes++;

            return;
        }

        self::$failures[] = $label . ' [expected ' . self::render($expected) . ' got ' . self::render($actual) . ']';
    }

    public static function throws(string $label, callable $callback, string $expected_message): void
    {
        try {
            $callback();
        } catch (Throwable $error) {
            if (strpos($error->getMessage(), $expected_message) !== false) {
                self::$passes++;

                return;
            }

            self::$failures[] = $label . ' [unexpected message ' . $error->getMessage() . ']';

            return;
        }

        self::$failures[] = $label . ' [no exception thrown]';
    }

    public static function section(string $name): void
    {
        echo '-- ' . $name . "\n";
    }

    private static function render($value): string
    {
        $encoded = json_encode($value);

        return $encoded === false ? var_export($value, true) : (string) $encoded;
    }
}

/**
 * Phoenix source_risk.v3 transport contract, mirrored for producer assertions.
 */
const SCOPE_TARGET_KEYS = [
    'event' => ['tickera_event_id'],
    'parent_product' => ['woo_product_id'],
    'variation' => ['woo_variation_id', 'woo_product_id'],
    'event_product_relationship' => ['woo_product_id'],
];

const DIMENSION_SCOPES = [
    'lifecycle' => ['event', 'parent_product', 'variation'],
    'ticket_template' => ['parent_product'],
    'event_link' => ['event_product_relationship'],
    'subscription' => ['parent_product'],
    'payment_plan' => ['parent_product'],
    'membership' => ['parent_product'],
    'bundle' => ['parent_product'],
    'add_on' => ['parent_product'],
    'product_type' => ['parent_product'],
];

const DIMENSION_STATES = [
    'lifecycle' => ['present', 'unknown', 'missing', 'invalid', 'producer_error'],
    'ticket_template' => ['present', 'absent', 'missing', 'unknown', 'unsupported', 'invalid', 'producer_error'],
    'event_link' => ['present', 'absent', 'missing', 'unknown', 'invalid', 'producer_error'],
    'subscription' => ['present', 'absent', 'unknown', 'unsupported', 'missing', 'invalid', 'producer_error'],
    'payment_plan' => ['unsupported', 'unknown', 'producer_error'],
    'membership' => ['unsupported', 'unknown', 'producer_error'],
    'bundle' => ['unsupported', 'unknown', 'producer_error'],
    'add_on' => ['unsupported', 'unknown', 'producer_error'],
    'product_type' => ['present', 'unsupported', 'unknown', 'missing', 'invalid', 'producer_error'],
];

const DIMENSION_SOURCE_KEYS = [
    'lifecycle' => 'wp_posts.post_status',
    'ticket_template' => 'postmeta:_ticket_template',
    'event_link' => 'postmeta:_event_name+tc_events.resolve',
    'subscription' => 'wc_product_type+subscription_evidence',
    'product_type' => 'wc_get_product.type',
    'payment_plan' => 'product_semantics_capability',
    'membership' => 'product_semantics_capability',
    'bundle' => 'product_semantics_capability',
    'add_on' => 'product_semantics_capability',
];

const EVIDENCE_ITEM_KEYS = [
    'dimension',
    'producer_scope',
    'target',
    'state',
    'producer_source_key',
    'completeness',
    'provenance',
    'value',
];

const FORBIDDEN_EVIDENCE_KEYS = [
    'origin',
    'authority',
    'authority_slot',
    'translation_rule_id',
    'alias_id',
    'severity',
    'disposition',
    'qualified_finding_id',
    'automation_eligible',
    'related_targets',
    'risk_codes',
];

const PROVENANCE_ALLOWLIST = [
    'discovery_snapshot_id',
    'producer_version',
    'producer_source_key',
    'raw_producer_code',
    'woo_product_id',
    'woo_variation_id',
    'tickera_event_id',
];

const FORBIDDEN_PROVENANCE_KEYS = [
    'origin',
    'authority_slot',
    'translation_rule_id',
    'alias_id',
    'canonical_contract_version',
    'run_id',
    'schema_version',
];

const COMPLETENESS_VALUES = ['exhaustive', 'partial', 'unknown'];

const VALUE_REQUIRED_FOR_PRESENT = ['lifecycle', 'product_type', 'event_link', 'ticket_template'];

const SNAPSHOT_ID = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2';

/**
 * @param array<string, mixed> $overrides
 * @return array<string, mixed>
 */
function observation(array $overrides = []): array
{
    return array_merge([
        'woo_product_id' => 109740,
        'woo_variation_id' => null,
        'tickera_event_id' => 55501,
        'event_status' => 'publish',
        'product_status' => 'publish',
        'variation_status' => null,
        'ticket_template_id' => '4242',
        'product_type' => 'simple',
        'is_subscription' => false,
        'event_reference_raw' => '55501',
    ], $overrides);
}

/**
 * @param array<int, array<string, mixed>> $items
 * @return array<string, mixed>|null
 */
function find_item(array $items, string $dimension, string $scope, ?int $target_id = null): ?array
{
    foreach ($items as $item) {
        if ($item['dimension'] !== $dimension || $item['producer_scope'] !== $scope) {
            continue;
        }

        if ($target_id !== null && !in_array($target_id, array_values($item['target']), true)) {
            continue;
        }

        return $item;
    }

    return null;
}

/**
 * @param array<int, array<string, mixed>> $items
 * @return array<int, string>
 */
function dimension_scope_pairs(array $items): array
{
    $pairs = array_map(
        static function (array $item): string {
            return $item['dimension'] . '/' . $item['producer_scope'];
        },
        $items
    );

    sort($pairs, SORT_STRING);

    return $pairs;
}

// ---------------------------------------------------------------------------
T::section('locked contract constants');

$plugin_source = (string) file_get_contents(dirname(__DIR__) . '/eventsales-tickera-catalog-feed.php');

foreach (
    [
        "'2026-08-07.v3'",
        "'source_risk.v3'",
        "'2026-08-07.1'",
        "'eventsales_tickera_catalog_snapshot_generation'",
        'wordpress_tickera:',
        "'eventsales_tickera_catalog_feed_cache_version'",
    ] as $needle
) {
    T::ok('plugin declares ' . $needle, strpos($plugin_source, $needle) !== false);
}

// The source identity is derive-only: no override constant, option, or filter.
preg_match_all("/if \(!defined\('([A-Z_]+)'\)\)/", $plugin_source, $defined_constants);
$declared = $defined_constants[1];
sort($declared, SORT_STRING);
T::same('plugin declares only the expected constants', [
    'ABSPATH',
    'EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION',
    'EVENTSALES_TICKERA_CATALOG_NAMESPACE',
    'EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION',
    'EVENTSALES_TICKERA_CATALOG_ROUTE',
    'EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION',
], $declared);
T::ok('plugin exposes no filter hook', strpos($plugin_source, 'apply_filters') === false);

T::same('schema version constant', '2026-08-07.v3', EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION);
T::same('canonical contract version constant', 'source_risk.v3', EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION);
T::same('producer version constant', '2026-08-07.1', EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION);
T::same('rest namespace unchanged', 'eventsales/v1', EVENTSALES_TICKERA_CATALOG_NAMESPACE);
T::same('rest route unchanged', '/tickera-catalog', EVENTSALES_TICKERA_CATALOG_ROUTE);

// ---------------------------------------------------------------------------
T::section('home url normalization');

T::same('lowercases scheme and host', 'https://example.com', Feed::normalize_home_url('HTTPS://Example.COM'));
T::same('strips trailing slash', 'https://example.com', Feed::normalize_home_url('https://example.com/'));
T::same('strips repeated trailing slashes', 'https://example.com', Feed::normalize_home_url('https://example.com///'));
T::same('strips default http port', 'http://example.com', Feed::normalize_home_url('http://example.com:80/'));
T::same('strips default https port', 'https://example.com', Feed::normalize_home_url('https://example.com:443'));
T::same('preserves non-default port', 'http://localhost:10059', Feed::normalize_home_url('http://localhost:10059'));
T::same('preserves meaningful path', 'http://localhost:10059/wp', Feed::normalize_home_url('HTTP://LocalHost:10059/wp/'));
T::same('drops query and fragment', 'http://localhost:10059/wp', Feed::normalize_home_url('http://localhost:10059/wp/?a=1#frag'));
T::same('rejects empty url', null, Feed::normalize_home_url(''));
T::same('rejects non-http scheme', null, Feed::normalize_home_url('ftp://example.com'));
T::same('rejects schemeless url', null, Feed::normalize_home_url('example.com/wp'));
T::same('rejects non-string url', null, Feed::normalize_home_url(null));

// ---------------------------------------------------------------------------
T::section('derive-only source_system_id');

$expected_source_system_id = 'wordpress_tickera:' . hash('sha256', 'http://localhost:10059');
T::same('derives from normalized home url', $expected_source_system_id, Feed::derive_source_system_id('http://localhost:10059/'));
T::same('derivation is normalization stable', $expected_source_system_id, Feed::derive_source_system_id('HTTP://LocalHost:10059'));
T::ok(
    'different host derives different identity',
    Feed::derive_source_system_id('http://localhost:10059') !== Feed::derive_source_system_id('http://localhost:10060')
);
T::same('underivable home url returns null', null, Feed::derive_source_system_id('nope'));
T::ok('identity is prefixed and hex', (bool) preg_match('/^wordpress_tickera:[a-f0-9]{64}$/', (string) Feed::derive_source_system_id('http://localhost:10059')));

// ---------------------------------------------------------------------------
T::section('canonical json');

T::same('sorts object keys', '{"a":2,"b":1}', Feed::canonical_json(['b' => 1, 'a' => 2]));
T::same('sorts nested object keys', '{"a":{"x":1,"y":2}}', Feed::canonical_json(['a' => ['y' => 2, 'x' => 1]]));
T::same('preserves list order', '[3,1,2]', Feed::canonical_json([3, 1, 2]));
T::same('encodes explicit null', 'null', Feed::canonical_json(null));
T::same('encodes booleans', '[true,false]', Feed::canonical_json([true, false]));
T::same('encodes integers as integers', '{"n":7}', Feed::canonical_json(['n' => 7]));
T::same('encodes utf-8 strings unescaped', '{"t":"Voëlgoed"}', Feed::canonical_json(['t' => 'Voëlgoed']));
T::same('does not escape slashes', '{"u":"http://a/b"}', Feed::canonical_json(['u' => 'http://a/b']));
T::same(
    'insertion order does not matter',
    Feed::canonical_json(['a' => 1, 'b' => ['c' => 2, 'd' => null]]),
    Feed::canonical_json(['b' => ['d' => null, 'c' => 2], 'a' => 1])
);
T::throws('rejects floats', static function (): void {
    Feed::canonical_json(['n' => 1.5]);
}, 'canonical_json_float_unsupported');

// ---------------------------------------------------------------------------
T::section('discovery snapshot identity');

$filters = [
    'updated_since' => null,
    'product_id' => null,
    'variation_id' => null,
    'event_id' => null,
    'include_private' => false,
];

$identity_json = Feed::canonical_discovery_json($expected_source_system_id, 'aaaabbbbccccddddeeeeffff00001111', $filters);
$snapshot_id = Feed::discovery_snapshot_id($expected_source_system_id, 'aaaabbbbccccddddeeeeffff00001111', $filters);

T::ok('identity json is canonical', (bool) preg_match('/^\{"canonical_contract_version"/', $identity_json));
T::ok('identity json carries generation token', strpos($identity_json, '"generation_token":"aaaabbbbccccddddeeeeffff00001111"') !== false);
T::ok('identity json excludes page', strpos($identity_json, '"page"') === false);
T::ok('identity json excludes per_page', strpos($identity_json, '"per_page"') === false);
T::ok('identity json excludes cursor', strpos($identity_json, '"cursor"') === false);
T::ok('snapshot id is sha256 hex', (bool) preg_match('/^[a-f0-9]{64}$/', $snapshot_id));
T::same('snapshot id is deterministic', $snapshot_id, Feed::discovery_snapshot_id($expected_source_system_id, 'aaaabbbbccccddddeeeeffff00001111', $filters));
T::ok(
    'snapshot id changes with generation token',
    $snapshot_id !== Feed::discovery_snapshot_id($expected_source_system_id, 'ffffeeeeddddccccbbbbaaaa11110000', $filters)
);
T::ok(
    'snapshot id changes with filters',
    $snapshot_id !== Feed::discovery_snapshot_id($expected_source_system_id, 'aaaabbbbccccddddeeeeffff00001111', array_merge($filters, ['product_id' => 109740]))
);
T::ok(
    'snapshot id changes with source system id',
    $snapshot_id !== Feed::discovery_snapshot_id('wordpress_tickera:' . hash('sha256', 'http://other'), 'aaaabbbbccccddddeeeeffff00001111', $filters)
);
T::same(
    'missing filter keys are explicit nulls',
    $identity_json,
    Feed::canonical_discovery_json($expected_source_system_id, 'aaaabbbbccccddddeeeeffff00001111', ['include_private' => false])
);
T::same(
    'page params never leak into identity',
    $snapshot_id,
    Feed::discovery_snapshot_id($expected_source_system_id, 'aaaabbbbccccddddeeeeffff00001111', array_merge($filters, ['page' => 3, 'per_page' => 25]))
);

// ---------------------------------------------------------------------------
T::section('snapshot generation record');

$GLOBALS['options'] = [];
$created = Feed::read_or_create_snapshot_generation();

T::same('record has exactly two keys', ['generation_at', 'generation_token'], (static function (array $record): array {
    $keys = array_keys($record);
    sort($keys, SORT_STRING);

    return $keys;
})($created));
T::ok('token is opaque hex of at least 32 chars', (bool) preg_match('/^[a-f0-9]{32,}$/', $created['generation_token']));
T::ok('generation_at is rfc3339 z', (bool) preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/', $created['generation_at']));
T::ok('record is persisted under the locked option', isset($GLOBALS['options']['eventsales_tickera_catalog_snapshot_generation']));
T::same('read is stable without invalidation', $created, Feed::read_or_create_snapshot_generation());

$GLOBALS['options']['eventsales_tickera_catalog_snapshot_generation'] = ['generation_token' => 'not-hex', 'generation_at' => 'nope'];
$repaired = Feed::read_or_create_snapshot_generation();
T::ok('invalid stored record is replaced', (bool) preg_match('/^[a-f0-9]{32,}$/', $repaired['generation_token']));

$GLOBALS['options']['eventsales_tickera_catalog_snapshot_generation'] = 7;
$repaired_scalar = Feed::read_or_create_snapshot_generation();
T::ok('non-array stored record is replaced', (bool) preg_match('/^[a-f0-9]{32,}$/', $repaired_scalar['generation_token']));

$rotated_tokens = [];
for ($i = 0; $i < 5; $i++) {
    $rotated_tokens[] = Feed::rotate_snapshot_generation()['generation_token'];
}
T::same('every rotation mints a new token', 5, count(array_unique($rotated_tokens)));
T::ok('rotation is not arithmetic', !in_array((string) ((int) $rotated_tokens[0] + 1), $rotated_tokens, true));

$generation_a = ['generation_token' => str_repeat('a', 32), 'generation_at' => '2026-08-07T10:00:00Z'];
$generation_b = ['generation_token' => str_repeat('b', 32), 'generation_at' => '2026-08-07T10:00:00Z'];
$generation_c = ['generation_token' => str_repeat('a', 32), 'generation_at' => '2026-08-07T10:00:01Z'];

T::ok('equality accepts identical records', Feed::snapshot_generations_equal($generation_a, $generation_a));
T::ok('equality rejects a changed token', !Feed::snapshot_generations_equal($generation_a, $generation_b));
T::ok('equality rejects a changed generation_at', !Feed::snapshot_generations_equal($generation_a, $generation_c));
T::ok('equality rejects null', !Feed::snapshot_generations_equal($generation_a, null));
T::ok('equality rejects invalid shape', !Feed::snapshot_generations_equal($generation_a, ['generation_token' => str_repeat('a', 32)]));

// ---------------------------------------------------------------------------
T::section('mid-page generation stability');

$GLOBALS['options'] = [];
Feed::$test_generation_mutator = null;
$before = Feed::read_or_create_snapshot_generation();
$after = Feed::require_stable_snapshot_generation($before);
T::same('stable generation returns the same record', $before, $after);

Feed::$test_generation_mutator = static function (): void {
    Feed::rotate_snapshot_generation();
};
T::throws('mid-page rotation fails closed', static function () use ($before): void {
    Feed::require_stable_snapshot_generation($before);
}, 'snapshot_generation_changed_mid_page');

Feed::$test_generation_mutator = null;
$current = Feed::read_or_create_snapshot_generation();
T::same('seam is inert once cleared', $current, Feed::require_stable_snapshot_generation($current));

// ---------------------------------------------------------------------------
T::section('native per_page bounds');

T::same('native max per page is 100', 100, Feed::native_max_per_page());
T::same('default per_page', 100, Feed::validate_native_per_page(null));
T::same('empty per_page uses default', 100, Feed::validate_native_per_page(''));
T::same('accepts 1', 1, Feed::validate_native_per_page('1'));
T::same('accepts 100', 100, Feed::validate_native_per_page('100'));
T::same('rejects 101', null, Feed::validate_native_per_page('101'));
T::same('rejects legacy 500', null, Feed::validate_native_per_page('500'));
T::same('rejects legacy 501', null, Feed::validate_native_per_page('501'));
T::same('rejects zero', null, Feed::validate_native_per_page('0'));
T::same('rejects negative', null, Feed::validate_native_per_page('-1'));
T::same('rejects non-numeric', null, Feed::validate_native_per_page('abc'));
T::same('rejects float text', null, Feed::validate_native_per_page('10.5'));

// ---------------------------------------------------------------------------
T::section('native envelope');

$envelope = Feed::native_envelope([
    'source_system_id' => $expected_source_system_id,
    'discovery_snapshot_id' => SNAPSHOT_ID,
    'source_snapshot_at' => '2026-08-07T10:00:00Z',
    'generated_at' => '2026-08-07T10:00:05Z',
    'page' => 1,
    'per_page' => 100,
    'has_more' => false,
    'filters' => $filters,
    'events' => [],
    'catalog_rows' => [],
    'evidence' => [],
]);

$expected_envelope_keys = [
    'schema_version',
    'canonical_contract_version',
    'producer_version',
    'source',
    'source_system_id',
    'discovery_snapshot_id',
    'source_snapshot_at',
    'generated_at',
    'page',
    'per_page',
    'has_more',
    'filters',
    'events',
    'catalog_rows',
    'evidence',
];

T::same('envelope key list is locked', $expected_envelope_keys, Feed::native_envelope_keys());
T::same('envelope has exactly the locked keys', $expected_envelope_keys, array_keys($envelope));
T::same('envelope key count', 15, count($envelope));
T::same('envelope schema version', '2026-08-07.v3', $envelope['schema_version']);
T::same('envelope canonical contract version', 'source_risk.v3', $envelope['canonical_contract_version']);
T::same('envelope producer version', '2026-08-07.1', $envelope['producer_version']);
T::same('envelope source', 'wordpress_tickera', $envelope['source']);
T::same('envelope filter keys are closed', ['event_id', 'include_private', 'product_id', 'updated_since', 'variation_id'], (static function (array $filters): array {
    $keys = array_keys($filters);
    sort($keys, SORT_STRING);

    return $keys;
})($envelope['filters']));
T::ok('envelope carries no legacy top-level keys', !array_key_exists('risk_codes', $envelope) && !array_key_exists('auto_apply', $envelope));

// ---------------------------------------------------------------------------
T::section('cache key generation binding');

$key_a = Feed::cache_key_for(['page' => 1, 'per_page' => 100], $generation_a, 4);
$key_b = Feed::cache_key_for(['page' => 1, 'per_page' => 100], $generation_b, 4);
$key_c = Feed::cache_key_for(['page' => 1, 'per_page' => 100], $generation_c, 4);
$key_d = Feed::cache_key_for(['page' => 2, 'per_page' => 100], $generation_a, 4);
$key_e = Feed::cache_key_for(['page' => 1, 'per_page' => 100], $generation_a, 5);

T::ok('cache key is deterministic', $key_a === Feed::cache_key_for(['page' => 1, 'per_page' => 100], $generation_a, 4));
T::ok('cache key changes with generation token', $key_a !== $key_b);
T::ok('cache key changes with generation_at', $key_a !== $key_c);
T::ok('cache key changes with params', $key_a !== $key_d);
T::ok('cache key changes with cache version', $key_a !== $key_e);
T::ok('cache key carries the cache version prefix', strpos($key_a, 'eventsales_tickera_catalog_4_') === 0);
T::ok('cache key fits a transient name', strlen($key_a) <= 172);

// ---------------------------------------------------------------------------
T::section('full-mode relationship discovery sql');

$rel = Feed::native_catalog_relationship_sql();

T::same('relationship seam exposes a closed key set', [
    'event_join',
    'event_join_predicate',
    'event_meta_join',
    'order_by',
    'public_event_where',
    'uses_inner_event_joins',
], (static function (array $rel): array {
    $keys = array_keys($rel);
    sort($keys, SORT_STRING);

    return $keys;
})($rel));

T::ok('event_meta is LEFT JOINed', strpos($rel['event_meta_join'], 'LEFT JOIN ') === 0);
T::ok('tc_events is LEFT JOINed', strpos($rel['event_join'], 'LEFT JOIN ') === 0);
T::same('full mode never uses inner event joins', false, $rel['uses_inner_event_joins']);
T::ok('event_meta join is keyed on _event_name', strpos($rel['event_meta_join'], "event_meta.meta_key = '_event_name'") !== false);
T::ok('event join is restricted to tc_events', strpos($rel['event_join_predicate'], "ev.post_type = 'tc_events'") !== false);

// Public mode still filters resolved events, but an unresolved or missing
// relationship must survive so event_link evidence can report it.
T::ok('public mode keeps unresolved relationships', strpos($rel['public_event_where'], 'ev.ID IS NULL OR') !== false);
T::ok('public mode still requires published resolved events', strpos($rel['public_event_where'], "ev.post_status = 'publish'") !== false);

// MySQL would happily CAST '55501abc' to 55501, so the REGEXP guard has to run
// before the CAST comparison or a malformed reference becomes a false link.
T::ok('event join guards CAST with a positive-integer REGEXP', strpos($rel['event_join_predicate'], "REGEXP '^[1-9][0-9]*$'") !== false);
T::ok(
    'REGEXP guard precedes the CAST comparison',
    strpos($rel['event_join_predicate'], 'REGEXP') < strpos($rel['event_join_predicate'], 'CAST(')
);
T::ok('event join compares the casted id', strpos($rel['event_join_predicate'], 'ev.ID = CAST(event_meta.meta_value AS UNSIGNED)') !== false);

// Multi-event LEFT JOINs and physical authority postmeta rows can repeat the
// same product/variation; finish the total order with event-id and meta_id
// tiebreakers so offset pages stay deterministic.
T::same(
    'catalogue ORDER BY is a total order ending in physical authority meta_ids',
    'ORDER BY ev.post_title ASC, p.post_title ASC, p.ID ASC, variation.ID ASC, ev.ID ASC, event_meta.meta_id ASC, ticket_template_meta.meta_id ASC',
    $rel['order_by']
);
T::ok('ORDER BY includes the event-id tiebreaker', strpos($rel['order_by'], 'ev.ID ASC') !== false);
T::ok('ORDER BY includes the event_meta.meta_id tiebreaker', strpos($rel['order_by'], 'event_meta.meta_id ASC') !== false);
T::ok('ORDER BY includes the ticket_template_meta.meta_id tiebreaker', strpos($rel['order_by'], 'ticket_template_meta.meta_id ASC') !== false);

$prefixed = Feed::native_catalog_relationship_sql('es_posts', 'es_postmeta');
T::ok('relationship joins honour the postmeta table', strpos($prefixed['event_meta_join'], 'es_postmeta ') !== false);
T::ok('relationship joins honour the posts table', strpos($prefixed['event_join'], 'es_posts ') !== false);

// Regression guards: the catalog query must build its relationship joins and
// its public filter from this seam only, never from a targeting conditional.
T::ok('relationship joins are no longer switched on targeting', strpos($plugin_source, "? 'LEFT JOIN' : 'JOIN'") === false);
T::ok('catalog rows join through the seam', strpos($plugin_source, "\$relationship['event_meta_join']") !== false);
T::ok('catalog rows resolve events through the seam', strpos($plugin_source, "\$relationship['event_join']") !== false);
T::ok(
    'catalog rows filter public events through the seam',
    strpos($plugin_source, "\$where[] = \$relationship['public_event_where'];") !== false
);
T::ok(
    'catalog rows order through the seam',
    strpos($plugin_source, "\$relationship['order_by']") !== false
);
T::ok(
    'plugin source still contains the event-id tiebreaker',
    strpos($plugin_source, 'ev.ID ASC') !== false
);
T::ok(
    'plugin source still contains the event_meta.meta_id tiebreaker',
    strpos($plugin_source, 'event_meta.meta_id ASC') !== false
);
T::ok(
    'plugin source still contains the ticket_template_meta.meta_id tiebreaker',
    strpos($plugin_source, 'ticket_template_meta.meta_id ASC') !== false
);

// ---------------------------------------------------------------------------
T::section('authority-bearing postmeta multiplicity sql');

/**
 * Capture the exact catalogue SQL through a fake $wpdb. Reflection invokes the
 * private catalog_rows method so production does not need a public test API.
 */
final class CapturingWpdb
{
    public string $posts = 'wp_posts';

    public string $postmeta = 'wp_postmeta';

    public string $captured_sql = '';

    /** @var array<int, mixed> */
    public array $captured_values = [];

    public function prepare($sql, $args = null)
    {
        $values = func_get_args();
        array_shift($values);

        if (isset($values[0]) && is_array($values[0])) {
            $values = $values[0];
        }

        $this->captured_sql = (string) $sql;
        $this->captured_values = $values;

        return (string) $sql;
    }

    public function get_results($prepared, $output = null)
    {
        return [];
    }
}

$wpdb = new CapturingWpdb();
$GLOBALS['wpdb'] = $wpdb;

$catalog_rows = new ReflectionMethod(Feed::class, 'catalog_rows');
$catalog_rows->setAccessible(true);
$catalog_rows->invoke(new Feed(), [
    'updated_since' => null,
    'product_id' => null,
    'variation_id' => null,
    'event_id' => null,
    'page' => 1,
    'per_page' => 100,
    'include_private' => false,
]);

$catalogue_sql = $wpdb->captured_sql;
$catalogue_values = $wpdb->captured_values;

T::ok('catalogue SQL was captured', $catalogue_sql !== '');
T::ok('MAX(event_meta.meta_value) is gone', strpos($catalogue_sql, 'MAX(event_meta.meta_value)') === false);
T::ok(
    '_ticket_template MAX CASE expression is gone',
    strpos($catalogue_sql, "MAX(CASE WHEN pm.meta_key = '_ticket_template' THEN pm.meta_value END)") === false
);
T::ok(
    'dedicated ticket_template_meta LEFT JOIN is present',
    strpos($catalogue_sql, 'LEFT JOIN wp_postmeta ticket_template_meta') !== false
    && strpos($catalogue_sql, "ticket_template_meta.meta_key = '_ticket_template'") !== false
);
T::ok(
    'event_reference_raw is selected directly',
    strpos($catalogue_sql, 'event_meta.meta_value AS event_reference_raw') !== false
);
T::ok(
    'ticket_template_id is selected directly',
    strpos($catalogue_sql, 'ticket_template_meta.meta_value AS ticket_template_id') !== false
);
T::ok('GROUP BY includes event_meta.meta_id', strpos($catalogue_sql, 'event_meta.meta_id') !== false);
T::ok('GROUP BY includes event_meta.meta_value', preg_match('/GROUP BY[\s\S]*event_meta\.meta_value/i', $catalogue_sql) === 1);
T::ok('GROUP BY includes ticket_template_meta.meta_id', preg_match('/GROUP BY[\s\S]*ticket_template_meta\.meta_id/i', $catalogue_sql) === 1);
T::ok('GROUP BY includes ticket_template_meta.meta_value', preg_match('/GROUP BY[\s\S]*ticket_template_meta\.meta_value/i', $catalogue_sql) === 1);
T::ok(
    'ORDER BY ends with physical authority meta_id tiebreakers',
    preg_match('/ev\.ID ASC,\s*event_meta\.meta_id ASC,\s*ticket_template_meta\.meta_id ASC/i', $catalogue_sql) === 1
);

$allowed_meta = (new ReflectionClass(Feed::class))->getConstant('ALLOWED_META_KEYS');
T::ok('ALLOWED_META_KEYS still lists _ticket_template', in_array('_ticket_template', $allowed_meta, true));

$aggregate_meta = (new ReflectionMethod(Feed::class, 'aggregate_meta_keys'));
$aggregate_meta->setAccessible(true);
$aggregate_keys = $aggregate_meta->invoke(null);
T::ok('aggregate pm keys exclude _ticket_template', !in_array('_ticket_template', $aggregate_keys, true));
T::ok(
    'captured prepare values exclude _ticket_template from the pm IN list',
    !in_array('_ticket_template', $catalogue_values, true)
);
T::ok(
    'plugin source still invalidates on ALLOWED_META_KEYS including _ticket_template',
    strpos($plugin_source, "'_ticket_template'") !== false
    && strpos($plugin_source, 'array_merge(self::ALLOWED_META_KEYS') !== false
);

// Structural/diagnostic MAX aggregation may remain; authority claims may not.
T::ok(
    'no first/last/MIN winner selection for event_meta authority',
    strpos($catalogue_sql, 'MIN(event_meta.meta_value)') === false
    && strpos($catalogue_sql, 'MAX(event_meta.meta_value)') === false
);
T::ok(
    'no first/last/MIN winner selection for ticket_template authority',
    strpos($catalogue_sql, 'MIN(ticket_template_meta.meta_value)') === false
    && strpos($catalogue_sql, 'MAX(ticket_template_meta.meta_value)') === false
);

// has_more uses LIMIT per_page + 1. The sentinel must never contribute evidence.
T::ok(
    'catalogue SQL LIMIT fetches the has_more sentinel (per_page + 1)',
    count($catalogue_values) >= 2
    && (int) $catalogue_values[count($catalogue_values) - 2] === 101
    && (int) $catalogue_values[count($catalogue_values) - 1] === 0
);
T::ok(
    'sentinel observations are sliced before native evidence generation',
    (static function (string $source): bool {
        $slice = strpos($source, "array_slice(\$catalog['observations'], 0, \$per_page)");
        $evidence = strpos($source, 'build_native_evidence($observations');

        return $slice !== false && $evidence !== false && $slice < $evidence;
    })($plugin_source)
);

// Subscription supporting-meta MAX aggregation is boolean detection only:
// any positive proof → present; otherwise unknown. It must not emit a varying
// canonical subscription value that would require F2-style multiplicity.
T::ok(
    'subscription meta remains MAX-aggregated only as positive boolean support',
    strpos($catalogue_sql, "MAX(CASE WHEN pm.meta_key = '_subscription_period'") !== false
    && strpos($catalogue_sql, "MAX(CASE WHEN pm.meta_key = '_subscription_price'") !== false
);
$subscription_present = find_item(
    Feed::build_native_evidence_for_row(observation(['is_subscription' => true]), SNAPSHOT_ID),
    'subscription',
    'parent_product'
);
$subscription_unknown = find_item(
    Feed::build_native_evidence_for_row(observation(['is_subscription' => false]), SNAPSHOT_ID),
    'subscription',
    'parent_product'
);
T::same('positive subscription proof is present without a canonical value', 'present', $subscription_present['state']);
T::ok('present subscription carries no varying value', !array_key_exists('value', $subscription_present));
T::same('no positive subscription proof stays unknown', 'unknown', $subscription_unknown['state']);
T::ok('unknown subscription is never absent', $subscription_unknown['state'] !== 'absent');

// ---------------------------------------------------------------------------
T::section('typed evidence for a fixture row');

$happy = Feed::build_native_evidence_for_row(observation(), SNAPSHOT_ID);

T::same('happy row emits ten closed observations', 10, count($happy));
T::same('happy row dimension/scope pairs', [
    'add_on/parent_product',
    'bundle/parent_product',
    'event_link/event_product_relationship',
    'lifecycle/event',
    'lifecycle/parent_product',
    'membership/parent_product',
    'payment_plan/parent_product',
    'product_type/parent_product',
    'subscription/parent_product',
    'ticket_template/parent_product',
], dimension_scope_pairs($happy));

$event_lifecycle = find_item($happy, 'lifecycle', 'event');
T::same('event lifecycle state', 'present', $event_lifecycle['state']);
T::same('event lifecycle value', 'publish', $event_lifecycle['value']);
T::same('event lifecycle target', ['tickera_event_id' => 55501], $event_lifecycle['target']);
T::same('event lifecycle source key', 'wp_posts.post_status', $event_lifecycle['producer_source_key']);

$parent_lifecycle = find_item($happy, 'lifecycle', 'parent_product');
T::same('parent lifecycle target', ['woo_product_id' => 109740], $parent_lifecycle['target']);
T::same('parent lifecycle value', 'publish', $parent_lifecycle['value']);

$ticket_template = find_item($happy, 'ticket_template', 'parent_product');
T::same('ticket template state', 'present', $ticket_template['state']);
T::same('ticket template value', '4242', $ticket_template['value']);
T::same('ticket template source key', 'postmeta:_ticket_template', $ticket_template['producer_source_key']);

$event_link = find_item($happy, 'event_link', 'event_product_relationship');
T::same('event link state', 'present', $event_link['state']);
T::same('event link value is the resolved event id', 55501, $event_link['value']);
T::ok('event link value is an integer', is_int($event_link['value']));
T::same('event link target is product scoped', ['woo_product_id' => 109740], $event_link['target']);
T::same('event link source key', 'postmeta:_event_name+tc_events.resolve', $event_link['producer_source_key']);
T::same('event link provenance carries the event id', 55501, $event_link['provenance']['tickera_event_id']);

$product_type = find_item($happy, 'product_type', 'parent_product');
T::same('supported product type state', 'present', $product_type['state']);
T::same('supported product type value', 'simple', $product_type['value']);
T::same('product type source key', 'wc_get_product.type', $product_type['producer_source_key']);

$subscription = find_item($happy, 'subscription', 'parent_product');
T::same('negative subscription is unknown', 'unknown', $subscription['state']);
T::ok('negative subscription carries no value', !array_key_exists('value', $subscription));
T::same('subscription source key', 'wc_product_type+subscription_evidence', $subscription['producer_source_key']);

foreach (['payment_plan', 'membership', 'bundle', 'add_on'] as $capability) {
    $item = find_item($happy, $capability, 'parent_product');
    T::same($capability . ' state is unsupported', 'unsupported', $item['state']);
    T::ok($capability . ' carries no value', !array_key_exists('value', $item));
    T::same($capability . ' source key', 'product_semantics_capability', $item['producer_source_key']);
    T::same($capability . ' completeness', 'unknown', $item['completeness']);
}

// ---------------------------------------------------------------------------
T::section('variation lifecycle is its own observation');

$with_variation = Feed::build_native_evidence_for_row(
    observation(['woo_variation_id' => 109741, 'variation_status' => 'draft']),
    SNAPSHOT_ID
);

T::same('variation row emits eleven observations', 11, count($with_variation));
$variation_lifecycle = find_item($with_variation, 'lifecycle', 'variation');
T::same('variation lifecycle target has both identities', ['woo_variation_id' => 109741, 'woo_product_id' => 109740], $variation_lifecycle['target']);
T::same('variation lifecycle uses variation status', 'draft', $variation_lifecycle['value']);
T::same('parent lifecycle is unchanged', 'publish', find_item($with_variation, 'lifecycle', 'parent_product')['value']);
T::ok(
    'parent status is never copied onto the variation',
    $variation_lifecycle['value'] !== find_item($with_variation, 'lifecycle', 'parent_product')['value']
);
T::same('variation provenance carries both ids', [109740, 109741], [
    $variation_lifecycle['provenance']['woo_product_id'],
    $variation_lifecycle['provenance']['woo_variation_id'],
]);

$variation_without_status = find_item(
    Feed::build_native_evidence_for_row(observation(['woo_variation_id' => 109741, 'variation_status' => null]), SNAPSHOT_ID),
    'lifecycle',
    'variation'
);
T::same('unobserved variation status is missing', 'missing', $variation_without_status['state']);
T::ok('missing variation lifecycle has no value', !array_key_exists('value', $variation_without_status));
T::same('missing variation lifecycle completeness', 'partial', $variation_without_status['completeness']);

// ---------------------------------------------------------------------------
T::section('closed lifecycle values and fail-closed states');

foreach (['publish', 'private', 'draft', 'trash', 'deleted'] as $status) {
    $item = find_item(Feed::build_native_evidence_for_row(observation(['product_status' => $status]), SNAPSHOT_ID), 'lifecycle', 'parent_product');
    T::same('lifecycle accepts ' . $status, 'present', $item['state']);
    T::same('lifecycle value ' . $status, $status, $item['value']);
}

$undeclared = find_item(Feed::build_native_evidence_for_row(observation(['product_status' => 'pending']), SNAPSHOT_ID), 'lifecycle', 'parent_product');
T::same('undeclared status is invalid', 'invalid', $undeclared['state']);
T::ok('invalid lifecycle carries no value', !array_key_exists('value', $undeclared));
T::same('invalid lifecycle keeps the raw code', 'pending', $undeclared['provenance']['raw_producer_code']);

// ---------------------------------------------------------------------------
T::section('ticket template, event link, subscription, product type states');

$no_template = find_item(Feed::build_native_evidence_for_row(observation(['ticket_template_id' => null]), SNAPSHOT_ID), 'ticket_template', 'parent_product');
T::same('missing template is absent', 'absent', $no_template['state']);
T::ok('absent template carries no value', !array_key_exists('value', $no_template));
T::same('absent template claims exhaustive no-ref proof', 'exhaustive', $no_template['completeness']);
T::ok('absent template keeps no raw code', !array_key_exists('raw_producer_code', $no_template['provenance']));

$empty_template = find_item(Feed::build_native_evidence_for_row(observation(['ticket_template_id' => '']), SNAPSHOT_ID), 'ticket_template', 'parent_product');
T::same('empty-string template meta is invalid', 'invalid', $empty_template['state']);
T::ok('empty template carries no canonical value', !array_key_exists('value', $empty_template));
T::same('empty template preserves raw empty provenance', '', $empty_template['provenance']['raw_producer_code']);
T::ok('empty template is never absent', $empty_template['state'] !== 'absent');

$whitespace_template = find_item(Feed::build_native_evidence_for_row(observation(['ticket_template_id' => " \t "]), SNAPSHOT_ID), 'ticket_template', 'parent_product');
T::same('whitespace-only template meta is invalid', 'invalid', $whitespace_template['state']);
T::same('whitespace template preserves exact raw provenance', " \t ", $whitespace_template['provenance']['raw_producer_code']);
T::ok('whitespace template is never absent', $whitespace_template['state'] !== 'absent');

$raw_template_path = find_item(
    Feed::build_native_evidence_for_row(observation(['ticket_template_raw' => '', 'ticket_template_id' => null]), SNAPSHOT_ID),
    'ticket_template',
    'parent_product'
);
T::same('ticket_template_raw empty wins over normalized null', 'invalid', $raw_template_path['state']);
T::same('ticket_template_raw empty preserves ""', '', $raw_template_path['provenance']['raw_producer_code']);

// An oversized template can neither be emitted as a value nor silently
// dropped from provenance, so the page fails closed instead.
T::throws('oversized template fails the page closed', static function (): void {
    Feed::build_native_evidence_for_row(observation(['ticket_template_id' => str_repeat('9', 80)]), SNAPSHOT_ID);
}, 'oversized_raw_producer_code');

$bounded_template = find_item(
    Feed::build_native_evidence_for_row(observation(['ticket_template_id' => str_repeat('9', 64)]), SNAPSHOT_ID),
    'ticket_template',
    'parent_product'
);
T::same('a template at the byte bound stays present', 'present', $bounded_template['state']);
T::same('bounded template keeps its exact value', str_repeat('9', 64), $bounded_template['value']);

// The value bound and the raw bound are both 64 bytes, so the first byte past
// the bound fails the page closed and ticket_template invalid is unreachable.
T::throws('one byte past the template bound fails closed', static function (): void {
    Feed::build_native_evidence_for_row(observation(['ticket_template_id' => str_repeat('9', 65)]), SNAPSHOT_ID);
}, 'oversized_raw_producer_code');

$unresolved_link = find_item(
    Feed::build_native_evidence_for_row(observation(['tickera_event_id' => null, 'event_status' => null, 'event_reference_raw' => '99999']), SNAPSHOT_ID),
    'event_link',
    'event_product_relationship'
);
T::same('unresolved event reference is invalid', 'invalid', $unresolved_link['state']);
T::ok('invalid event link carries no value', !array_key_exists('value', $unresolved_link));
T::same('invalid event link keeps the raw reference', '99999', $unresolved_link['provenance']['raw_producer_code']);

$absent_link_row = Feed::build_native_evidence_for_row(
    observation(['tickera_event_id' => null, 'event_status' => null, 'event_reference_raw' => null]),
    SNAPSHOT_ID
);
$absent_link = find_item($absent_link_row, 'event_link', 'event_product_relationship');
T::same('no reference at all is absent', 'absent', $absent_link['state']);
T::same('absent event link requires exhaustive proof', 'exhaustive', $absent_link['completeness']);
T::same('no event means no event lifecycle claim', null, find_item($absent_link_row, 'lifecycle', 'event'));

$positive_subscription = find_item(Feed::build_native_evidence_for_row(observation(['is_subscription' => true]), SNAPSHOT_ID), 'subscription', 'parent_product');
T::same('positive subscription is present', 'present', $positive_subscription['state']);
T::ok('positive subscription needs no value', !array_key_exists('value', $positive_subscription));
T::same('positive subscription completeness', 'partial', $positive_subscription['completeness']);

foreach ([true, false] as $is_subscription) {
    $item = find_item(Feed::build_native_evidence_for_row(observation(['is_subscription' => $is_subscription]), SNAPSHOT_ID), 'subscription', 'parent_product');
    T::ok('subscription never claims absent (' . var_export($is_subscription, true) . ')', $item['state'] !== 'absent');
}

// An observed but undeclared runtime token is a real conflicting observation,
// so it is invalid rather than unsupported.
$invalid_type = find_item(Feed::build_native_evidence_for_row(observation(['product_type' => 'variable']), SNAPSHOT_ID), 'product_type', 'parent_product');
T::same('observed undeclared product type is invalid', 'invalid', $invalid_type['state']);
T::ok('invalid product type carries no value', !array_key_exists('value', $invalid_type));
T::same('invalid product type keeps the raw code', 'variable', $invalid_type['provenance']['raw_producer_code']);

// Unsupported means the producer could not evaluate the dimension at all.
$unsupported_type = find_item(Feed::build_native_evidence_for_row(observation(['product_type' => null]), SNAPSHOT_ID), 'product_type', 'parent_product');
T::same('unobservable product type is unsupported', 'unsupported', $unsupported_type['state']);
T::ok('unsupported product type carries no value', !array_key_exists('value', $unsupported_type));
T::same('unsupported product type cannot claim proof', 'unknown', $unsupported_type['completeness']);
T::ok('unsupported product type has no raw code to keep', !array_key_exists('raw_producer_code', $unsupported_type['provenance']));

T::same('a row without a product identity emits nothing', [], Feed::build_native_evidence_for_row(observation(['woo_product_id' => null]), SNAPSHOT_ID));

// ---------------------------------------------------------------------------
T::section('event link raw/resolved matrix');

/**
 * @return array<string, mixed>
 */
function event_link_for($raw, $event_id): array
{
    $row = Feed::build_native_evidence_for_row(
        observation([
            'event_reference_raw' => $raw,
            'tickera_event_id' => $event_id,
            'event_status' => $event_id === null ? null : 'publish',
        ]),
        SNAPSHOT_ID
    );

    return find_item($row, 'event_link', 'event_product_relationship');
}

// present is the only positive claim, and it requires a valid raw positive
// integer that resolves to the same tc_events id.
$matched = event_link_for('55501', 55501);
T::same('matching raw and resolved id is present', 'present', $matched['state']);
T::same('present event link value is the resolved id', 55501, $matched['value']);
T::ok('present event link keeps no raw code', !array_key_exists('raw_producer_code', $matched['provenance']));
T::same('present event link provenance carries the event id', 55501, $matched['provenance']['tickera_event_id']);

$whitespace_matched = event_link_for('  55501  ', 55501);
T::same('surrounding whitespace still resolves to present', 'present', $whitespace_matched['state']);
T::same('trimmed reference keeps the integer value', 55501, $whitespace_matched['value']);

$unresolved = event_link_for('55501', null);
T::same('a valid reference that resolves to nothing is invalid', 'invalid', $unresolved['state']);
T::ok('unresolved event link carries no value', !array_key_exists('value', $unresolved));
T::same('unresolved event link keeps the raw reference', '55501', $unresolved['provenance']['raw_producer_code']);

// The SQL CAST of '55501abc' is 55501; the producer must not inherit that lie.
$cast_truncated = event_link_for('55501abc', 55501);
T::same('a CAST-truncated reference is invalid', 'invalid', $cast_truncated['state']);
T::ok('a CAST-truncated reference is never present', $cast_truncated['state'] !== 'present');
T::ok('CAST-truncated event link carries no value', !array_key_exists('value', $cast_truncated));
T::same('CAST-truncated event link keeps the exact raw bytes', '55501abc', $cast_truncated['provenance']['raw_producer_code']);
T::ok('CAST-truncated event link claims no event identity', !array_key_exists('tickera_event_id', $cast_truncated['provenance']));

$mismatched = event_link_for('55501', 55502);
T::same('a reference disagreeing with the resolved id is invalid', 'invalid', $mismatched['state']);
T::same('mismatched event link keeps the raw reference', '55501', $mismatched['provenance']['raw_producer_code']);

$non_numeric = event_link_for('abc', null);
T::same('a non-numeric reference is invalid', 'invalid', $non_numeric['state']);
T::same('non-numeric event link keeps the raw reference', 'abc', $non_numeric['provenance']['raw_producer_code']);

$no_reference = event_link_for(null, null);
T::same('no reference and no resolution is absent', 'absent', $no_reference['state']);
T::same('absent event link claims exhaustive proof', 'exhaustive', $no_reference['completeness']);
T::ok('absent event link keeps no raw code', !array_key_exists('raw_producer_code', $no_reference['provenance']));

// A resolved event without any raw reference cannot happen from this SQL, so it
// is reported as a producer fault instead of a source finding.
$impossible = event_link_for(null, 55501);
T::same('a resolved event without a reference is a producer error', 'producer_error', $impossible['state']);
T::same('producer_error claims no completeness', 'unknown', $impossible['completeness']);
T::ok('producer_error carries no value', !array_key_exists('value', $impossible));
T::ok('producer_error keeps no raw code', !array_key_exists('raw_producer_code', $impossible['provenance']));

foreach (['0', '-1', '00', '1.0', '+1', ' '] as $non_positive) {
    $item = event_link_for($non_positive, null);
    T::same('non-positive reference ' . json_encode($non_positive) . ' is not present', true, $item['state'] !== 'present');
}

$zero_reference = event_link_for('0', null);
T::same('a zero reference is invalid', 'invalid', $zero_reference['state']);
T::same('zero reference keeps its raw bytes', '0', $zero_reference['provenance']['raw_producer_code']);

$negative_reference = event_link_for('-1', null);
T::same('a negative reference is invalid', 'invalid', $negative_reference['state']);
T::same('negative reference keeps its raw bytes', '-1', $negative_reference['provenance']['raw_producer_code']);

// A whitespace-only reference is an observed empty meta value → invalid, never absent.
$whitespace_only = event_link_for(' ', null);
T::same('a whitespace-only reference is invalid', 'invalid', $whitespace_only['state']);
T::same('whitespace-only raw provenance is preserved exactly', ' ', $whitespace_only['provenance']['raw_producer_code']);
T::ok('whitespace-only reference is never absent', $whitespace_only['state'] !== 'absent');

$empty_event_meta = event_link_for('', null);
T::same('empty-string event meta is invalid', 'invalid', $empty_event_meta['state']);
T::same('empty event meta preserves raw empty provenance', '', $empty_event_meta['provenance']['raw_producer_code']);
T::ok('empty event meta is never absent', $empty_event_meta['state'] !== 'absent');
T::ok('empty raw provenance key is present', array_key_exists('raw_producer_code', $empty_event_meta['provenance']));

// ---------------------------------------------------------------------------
T::section('product type matrix');

/**
 * @return array<string, mixed>
 */
function product_type_for($type): array
{
    return find_item(
        Feed::build_native_evidence_for_row(observation(['product_type' => $type]), SNAPSHOT_ID),
        'product_type',
        'parent_product'
    );
}

$simple = product_type_for('simple');
T::same('simple is the only supported declared type', 'present', $simple['state']);
T::same('simple keeps its value', 'simple', $simple['value']);
T::same('simple claims exhaustive proof', 'exhaustive', $simple['completeness']);
T::ok('simple keeps no raw code', !array_key_exists('raw_producer_code', $simple['provenance']));

foreach (['variable', 'grouped', 'external', 'subscription', 'variable-subscription'] as $observed) {
    $item = product_type_for($observed);
    T::same('observed undeclared type ' . $observed . ' is invalid', 'invalid', $item['state']);
    T::ok('invalid type ' . $observed . ' carries no value', !array_key_exists('value', $item));
    T::same('invalid type ' . $observed . ' keeps the raw code', $observed, $item['provenance']['raw_producer_code']);
    T::same('invalid type ' . $observed . ' claims exhaustive proof', 'exhaustive', $item['completeness']);
}

foreach ([null, '', '   '] as $unobservable) {
    $item = product_type_for($unobservable);
    T::same('unobservable type ' . json_encode($unobservable) . ' is unsupported', 'unsupported', $item['state']);
    T::same('unobservable type ' . json_encode($unobservable) . ' completeness', 'unknown', $item['completeness']);
    T::ok('unobservable type ' . json_encode($unobservable) . ' carries no value', !array_key_exists('value', $item));
    T::ok(
        'unobservable type ' . json_encode($unobservable) . ' keeps no raw code',
        !array_key_exists('raw_producer_code', $item['provenance'])
    );
}

T::ok('undeclared types are never reported as unsupported', product_type_for('variable')['state'] !== 'unsupported');
T::ok('unobservable types are never reported as invalid', product_type_for(null)['state'] !== 'invalid');

// ---------------------------------------------------------------------------
T::section('oversized and malformed raw producer codes fail closed');

// Raw evidence is never truncated and never silently omitted: an unemittable
// raw code fails the whole page so Phoenix cannot mistake it for a clean read.
T::throws('oversized lifecycle raw code fails closed', static function (): void {
    Feed::build_native_evidence_for_row(observation(['product_status' => str_repeat('x', 65)]), SNAPSHOT_ID);
}, 'oversized_raw_producer_code');

T::throws('oversized ticket template raw code fails closed', static function (): void {
    Feed::build_native_evidence_for_row(observation(['ticket_template_id' => str_repeat('9', 80)]), SNAPSHOT_ID);
}, 'oversized_raw_producer_code');

T::throws('oversized product type raw code fails closed', static function (): void {
    Feed::build_native_evidence_for_row(observation(['product_type' => str_repeat('v', 65)]), SNAPSHOT_ID);
}, 'oversized_raw_producer_code');

T::throws('oversized event reference raw code fails closed', static function (): void {
    Feed::build_native_evidence_for_row(
        observation([
            'event_reference_raw' => str_repeat('9', 65),
            'tickera_event_id' => null,
            'event_status' => null,
        ]),
        SNAPSHOT_ID
    );
}, 'oversized_raw_producer_code');

T::throws('oversized variation lifecycle raw code fails closed', static function (): void {
    Feed::build_native_evidence_for_row(
        observation(['woo_variation_id' => 109741, 'variation_status' => str_repeat('z', 65)]),
        SNAPSHOT_ID
    );
}, 'oversized_raw_producer_code');

$at_bound = find_item(
    Feed::build_native_evidence_for_row(observation(['product_status' => str_repeat('x', 64)]), SNAPSHOT_ID),
    'lifecycle',
    'parent_product'
);
T::same('a raw code at exactly 64 bytes is emitted', str_repeat('x', 64), $at_bound['provenance']['raw_producer_code']);
T::same('a raw code at the bound is still invalid state', 'invalid', $at_bound['state']);

foreach (["\x80", "\xC3\x28", "abc\xFF"] as $index => $malformed) {
    T::throws('malformed utf-8 raw code ' . $index . ' fails closed', static function () use ($malformed): void {
        Feed::build_native_evidence_for_row(observation(['product_status' => $malformed]), SNAPSHOT_ID);
    }, 'invalid_raw_producer_code');
}

// Valid multibyte UTF-8 is bounded by bytes, not characters.
$multibyte = find_item(
    Feed::build_native_evidence_for_row(observation(['product_status' => 'gepubliseer_ë']), SNAPSHOT_ID),
    'lifecycle',
    'parent_product'
);
T::same('valid multibyte raw code is preserved exactly', 'gepubliseer_ë', $multibyte['provenance']['raw_producer_code']);

T::throws('multibyte raw code over 64 bytes fails closed', static function (): void {
    Feed::build_native_evidence_for_row(observation(['product_status' => str_repeat('ë', 33)]), SNAPSHOT_ID);
}, 'oversized_raw_producer_code');

// ---------------------------------------------------------------------------
T::section('evidence transport contract');

$contract_sample = array_merge(
    Feed::build_native_evidence_for_row(observation(['woo_variation_id' => 109741, 'variation_status' => 'private']), SNAPSHOT_ID),
    Feed::build_native_evidence_for_row(observation(['product_status' => 'pending', 'product_type' => 'variable', 'is_subscription' => true, 'ticket_template_id' => null]), SNAPSHOT_ID),
    Feed::build_native_evidence_for_row(observation(['tickera_event_id' => null, 'event_status' => null, 'event_reference_raw' => 'abc']), SNAPSHOT_ID)
);

foreach ($contract_sample as $index => $item) {
    $label = 'item ' . $index . ' (' . $item['dimension'] . '/' . $item['producer_scope'] . ')';

    T::ok($label . ' has only contract keys', array_diff(array_keys($item), EVIDENCE_ITEM_KEYS) === []);
    T::ok($label . ' has every required key', array_diff(array_slice(EVIDENCE_ITEM_KEYS, 0, 7), array_keys($item)) === []);

    foreach (FORBIDDEN_EVIDENCE_KEYS as $forbidden) {
        T::ok($label . ' omits ' . $forbidden, !array_key_exists($forbidden, $item));
    }

    T::ok($label . ' scope is allowed for the dimension', in_array($item['producer_scope'], DIMENSION_SCOPES[$item['dimension']], true));
    T::ok($label . ' state is allowed for the dimension', in_array($item['state'], DIMENSION_STATES[$item['dimension']], true));
    T::ok($label . ' completeness is closed', in_array($item['completeness'], COMPLETENESS_VALUES, true));
    T::same($label . ' producer_source_key', DIMENSION_SOURCE_KEYS[$item['dimension']], $item['producer_source_key']);

    $target_keys = array_keys($item['target']);
    sort($target_keys, SORT_STRING);
    $expected_target_keys = SCOPE_TARGET_KEYS[$item['producer_scope']];
    sort($expected_target_keys, SORT_STRING);
    T::same($label . ' target key set is exact', $expected_target_keys, $target_keys);

    foreach ($item['target'] as $target_value) {
        T::ok($label . ' target id is a positive integer', is_int($target_value) && $target_value > 0);
    }

    T::ok($label . ' provenance is allowlisted', array_diff(array_keys($item['provenance']), PROVENANCE_ALLOWLIST) === []);

    foreach (FORBIDDEN_PROVENANCE_KEYS as $forbidden) {
        T::ok($label . ' provenance omits ' . $forbidden, !array_key_exists($forbidden, $item['provenance']));
    }

    T::same($label . ' provenance snapshot id', SNAPSHOT_ID, $item['provenance']['discovery_snapshot_id']);
    T::same($label . ' provenance producer version', '2026-08-07.1', $item['provenance']['producer_version']);
    T::same($label . ' provenance source key mirrors the field', $item['producer_source_key'], $item['provenance']['producer_source_key']);

    if (isset($item['provenance']['raw_producer_code'])) {
        T::ok($label . ' raw code is bounded', strlen($item['provenance']['raw_producer_code']) <= 64);
    }

    foreach (['woo_product_id', 'woo_variation_id', 'tickera_event_id'] as $id_key) {
        if (array_key_exists($id_key, $item['provenance'])) {
            T::ok($label . ' provenance ' . $id_key . ' is a positive integer', is_int($item['provenance'][$id_key]) && $item['provenance'][$id_key] > 0);
        }
    }

    if ($item['state'] === 'present' && in_array($item['dimension'], VALUE_REQUIRED_FOR_PRESENT, true)) {
        T::ok($label . ' present state carries a value', array_key_exists('value', $item) && $item['value'] !== null);
    }

    if ($item['state'] !== 'present') {
        T::ok($label . ' non-present state carries no value', !array_key_exists('value', $item));
    }

    if (array_key_exists('value', $item) && is_string($item['value'])) {
        T::ok($label . ' string value is bounded', strlen($item['value']) <= 64 && $item['value'] !== '');
    }
}

$json = json_encode($contract_sample);
T::ok('evidence list is json encodable', is_string($json));
$decoded = json_decode((string) $json, true);
T::ok('target ids survive json as integers', is_int($decoded[0]['target']['tickera_event_id']));
T::ok(
    'event link value survives json as an integer',
    is_int(find_item($decoded, 'event_link', 'event_product_relationship')['value'])
);

// ---------------------------------------------------------------------------
T::section('page-level evidence deduplication and bounds');

$shared_product = [
    observation(['woo_variation_id' => 109741, 'variation_status' => 'publish']),
    observation(['woo_variation_id' => 109742, 'variation_status' => 'draft']),
];

$deduped = Feed::build_native_evidence($shared_product, SNAPSHOT_ID);
T::same('parent observations are emitted once per page', 12, count($deduped));
T::same(
    'each variation keeps its own lifecycle',
    2,
    count(array_filter($deduped, static function (array $item): bool {
        return $item['dimension'] === 'lifecycle' && $item['producer_scope'] === 'variation';
    }))
);
T::same(
    'parent lifecycle is not duplicated',
    1,
    count(array_filter($deduped, static function (array $item): bool {
        return $item['dimension'] === 'lifecycle' && $item['producer_scope'] === 'parent_product';
    }))
);
T::same(
    'event lifecycle is shared across rows',
    1,
    count(array_filter($deduped, static function (array $item): bool {
        return $item['dimension'] === 'lifecycle' && $item['producer_scope'] === 'event';
    }))
);

// Dedup is fingerprint-based: only fully identical records collapse. Identity
// alone is deliberately not unique, because two conflicting observations of the
// same identity must both reach Phoenix.
$fingerprints = array_map(static function (array $item): string {
    return Feed::canonical_json($item);
}, $deduped);
T::same('no fully identical evidence record repeats on a page', count($fingerprints), count(array_unique($fingerprints)));

$under_bound = [];
for ($i = 0; $i < 45; $i++) {
    $under_bound[] = observation([
        'woo_product_id' => 200000 + $i,
        'woo_variation_id' => 300000 + $i,
        'variation_status' => 'publish',
        'tickera_event_id' => 400000 + $i,
    ]);
}
$under_bound_evidence = Feed::build_native_evidence($under_bound, SNAPSHOT_ID);
T::same('45 fully distinct variation rows stay inside the bound', 495, count($under_bound_evidence));
T::ok('page bound is 500 items', count($under_bound_evidence) <= 500);
T::same(
    'worst-case variation density remains 11 evidence per row',
    11,
    (int) (count($under_bound_evidence) / count($under_bound))
);

// Exact Phase 5D worst-case boundary: 46 distinct variation observations emit
// 506 evidence records and must fail closed. Do not weaken this to a looser
// oversize fixture — 506 is the first closed failure for current density.
$exact_over_bound = $under_bound;
$exact_over_bound[] = observation([
    'woo_product_id' => 200045,
    'woo_variation_id' => 300045,
    'variation_status' => 'publish',
    'tickera_event_id' => 400045,
]);
$exact_over_density = 0;
foreach ($exact_over_bound as $row) {
    $exact_over_density += count(Feed::build_native_evidence_for_row($row, SNAPSHOT_ID));
}
T::same('46 fully distinct variation rows emit 506 evidence before the page bound', 506, $exact_over_density);
T::throws('46 variation rows fail closed at 506 evidence', static function () use ($exact_over_bound): void {
    Feed::build_native_evidence($exact_over_bound, SNAPSHOT_ID);
}, 'evidence_page_limit_exceeded');

T::same('an empty page emits no evidence', [], Feed::build_native_evidence([], SNAPSHOT_ID));

// ---------------------------------------------------------------------------
T::section('conflicting observations are preserved for phoenix');

/**
 * @param array<int, array<string, mixed>> $items
 * @return array<int, array<string, mixed>>
 */
function items_for_dimension(array $items, string $dimension): array
{
    return array_values(array_filter($items, static function (array $item) use ($dimension): bool {
        return $item['dimension'] === $dimension;
    }));
}

// One product resolving to two different events is a real source conflict. The
// producer must not pick a winner or collapse it away: Phoenix needs both
// records to raise a blocking_conflict.
$conflicting = [
    observation(['event_reference_raw' => '10', 'tickera_event_id' => 10]),
    observation(['event_reference_raw' => '20', 'tickera_event_id' => 20]),
];
$conflict_evidence = Feed::build_native_evidence($conflicting, SNAPSHOT_ID);
$conflicting_links = items_for_dimension($conflict_evidence, 'event_link');

T::same('both conflicting event links survive dedup', 2, count($conflicting_links));
T::same('conflicting event link values are both preserved', [10, 20], (static function (array $links): array {
    $values = array_map(static function (array $link) {
        return $link['value'];
    }, $links);
    sort($values, SORT_NUMERIC);

    return $values;
})($conflicting_links));
T::same('both conflicting links are positive present claims', ['present', 'present'], array_map(static function (array $link): string {
    return $link['state'];
}, $conflicting_links));

// The conflict shares one (dimension, scope, target) identity, which is exactly
// why identity alone can no longer be the dedup key.
T::same('conflicting links share a single identity', 1, count(array_unique(array_map(static function (array $link): string {
    return $link['dimension'] . '|' . $link['producer_scope'] . '|' . Feed::canonical_json($link['target']);
}, $conflicting_links))));
T::same('each conflicting link keeps its own event provenance', [10, 20], (static function (array $links): array {
    $ids = array_map(static function (array $link): int {
        return $link['provenance']['tickera_event_id'];
    }, $links);
    sort($ids, SORT_NUMERIC);

    return $ids;
})($conflicting_links));

// Identical parent-level records still collapse, so only the genuinely
// conflicting dimensions repeat.
T::same('identical parent records still collapse to one', 1, count(items_for_dimension($conflict_evidence, 'ticket_template')));
T::same('identical parent lifecycle still collapses to one', 1, count(array_filter($conflict_evidence, static function (array $item): bool {
    return $item['dimension'] === 'lifecycle' && $item['producer_scope'] === 'parent_product';
})));
T::same('each distinct event keeps its own lifecycle', 2, count(array_filter($conflict_evidence, static function (array $item): bool {
    return $item['dimension'] === 'lifecycle' && $item['producer_scope'] === 'event';
})));
T::same('only conflicting dimensions repeat across the page', 12, count($conflict_evidence));

// Two different malformed references are two distinct invalid observations even
// though both claim the same state and identity.
$invalid_variants = Feed::build_native_evidence(
    [
        observation(['event_reference_raw' => 'abc', 'tickera_event_id' => null, 'event_status' => null]),
        observation(['event_reference_raw' => 'def', 'tickera_event_id' => null, 'event_status' => null]),
    ],
    SNAPSHOT_ID
);
$invalid_links = items_for_dimension($invalid_variants, 'event_link');
T::same('invalid claims with different raw provenance both survive', 2, count($invalid_links));
T::same('each invalid claim keeps its own raw code', ['abc', 'def'], (static function (array $links): array {
    $codes = array_map(static function (array $link): string {
        return $link['provenance']['raw_producer_code'];
    }, $links);
    sort($codes, SORT_STRING);

    return $codes;
})($invalid_links));

// A truly repeated observation of the same product across variation rows is
// still emitted once.
$repeated = Feed::build_native_evidence([observation(), observation(), observation()], SNAPSHOT_ID);
T::same('a repeated identical row adds nothing', 10, count($repeated));

// ---------------------------------------------------------------------------
T::section('authority-bearing claim multiplicity reaches phoenix');

// Distinct _event_name physical rows must both survive as present event_link
// claims. Phoenix owns contract.evidence_conflict; the producer never emits it.
$duplicate_events = Feed::build_native_evidence(
    [
        observation(['event_reference_raw' => '10', 'tickera_event_id' => 10]),
        observation(['event_reference_raw' => '20', 'tickera_event_id' => 20]),
    ],
    SNAPSHOT_ID
);
$duplicate_event_links = items_for_dimension($duplicate_events, 'event_link');
T::same('duplicate event raw 10/20 yields exactly two event_link claims', 2, count($duplicate_event_links));
T::same('duplicate event raw 10/20 preserves both present claims', [10, 20], (static function (array $links): array {
    $values = array_map(static function (array $link) {
        return $link['value'];
    }, $links);
    sort($values, SORT_NUMERIC);

    return $values;
})($duplicate_event_links));
T::same('duplicate event claims stay present', ['present', 'present'], array_map(static function (array $link): string {
    return $link['state'];
}, $duplicate_event_links));
T::ok(
    'event_link provenance never emits meta_id',
    !array_key_exists('meta_id', $duplicate_event_links[0]['provenance'])
    && !array_key_exists('meta_id', $duplicate_event_links[1]['provenance'])
);

// Distinct _ticket_template physical rows must both survive.
$duplicate_templates = Feed::build_native_evidence(
    [
        observation(['ticket_template_raw' => 'template-a', 'ticket_template_id' => 'template-a']),
        observation(['ticket_template_raw' => 'template-b', 'ticket_template_id' => 'template-b']),
    ],
    SNAPSHOT_ID
);
$duplicate_template_items = items_for_dimension($duplicate_templates, 'ticket_template');
T::same('duplicate templates A/B yield exactly two ticket_template claims', 2, count($duplicate_template_items));
T::same('duplicate templates A/B both survive', ['template-a', 'template-b'], (static function (array $items): array {
    $values = array_map(static function (array $item): string {
        return (string) $item['value'];
    }, $items);
    sort($values, SORT_STRING);

    return $values;
})($duplicate_template_items));
T::same('duplicate template claims stay present', ['present', 'present'], array_map(static function (array $item): string {
    return $item['state'];
}, $duplicate_template_items));
T::ok(
    'ticket_template provenance never emits meta_id',
    !array_key_exists('meta_id', $duplicate_template_items[0]['provenance'])
    && !array_key_exists('meta_id', $duplicate_template_items[1]['provenance'])
);

// Empty/invalid and valid template claims must both survive without winner selection.
$empty_and_valid_templates = Feed::build_native_evidence(
    [
        observation(['ticket_template_raw' => '', 'ticket_template_id' => null]),
        observation(['ticket_template_raw' => 'template-a', 'ticket_template_id' => 'template-a']),
    ],
    SNAPSHOT_ID
);
$empty_and_valid_items = items_for_dimension($empty_and_valid_templates, 'ticket_template');
T::same('empty + valid template yields two claims', 2, count($empty_and_valid_items));
T::same(
    'empty + valid template preserves invalid empty and present template-a',
    ['invalid', 'present'],
    (static function (array $items): array {
        $states = array_map(static function (array $item): string {
            return $item['state'];
        }, $items);
        sort($states, SORT_STRING);

        return $states;
    })($empty_and_valid_items)
);
T::same(
    'empty template keeps raw empty provenance while valid keeps value',
    ['', 'template-a'],
    (static function (array $items): array {
        $tokens = [];

        foreach ($items as $item) {
            if ($item['state'] === 'invalid') {
                $tokens[] = (string) ($item['provenance']['raw_producer_code'] ?? 'missing');
            } else {
                $tokens[] = (string) $item['value'];
            }
        }

        sort($tokens, SORT_STRING);

        return $tokens;
    })($empty_and_valid_items)
);

// Two physically duplicated but semantically identical observations collapse
// through the existing complete-record fingerprint. meta_id is never part of
// provenance, so identical raw authority claims fingerprint-collapse.
$exact_duplicate_evidence = Feed::build_native_evidence(
    [
        observation([
            'ticket_template_raw' => 'template-a',
            'ticket_template_id' => 'template-a',
            'event_reference_raw' => '10',
            'tickera_event_id' => 10,
        ]),
        observation([
            'ticket_template_raw' => 'template-a',
            'ticket_template_id' => 'template-a',
            'event_reference_raw' => '10',
            'tickera_event_id' => 10,
        ]),
    ],
    SNAPSHOT_ID
);
T::same(
    'exact duplicate template observations collapse to one evidence record',
    1,
    count(items_for_dimension($exact_duplicate_evidence, 'ticket_template'))
);
T::same(
    'exact duplicate event_link observations collapse to one evidence record',
    1,
    count(items_for_dimension($exact_duplicate_evidence, 'event_link'))
);
T::same(
    'exact duplicate page still emits one closed parent/event set',
    10,
    count($exact_duplicate_evidence)
);

// Invalidation vocabulary still includes _ticket_template even though the
// generic pm aggregation pivot excludes it.
$version_before_template = (int) get_option('eventsales_tickera_catalog_feed_cache_version', 1);
Feed::record_meta_change(99, 109740, '_ticket_template');
T::ok(
    '_ticket_template still participates in catalogue invalidation',
    (int) get_option('eventsales_tickera_catalog_feed_cache_version', 1) > $version_before_template
);

// ---------------------------------------------------------------------------
T::section('bounded native event pagination');

if (!function_exists('get_the_terms')) {
    function get_the_terms($id, $taxonomy)
    {
        return [(object) ['slug' => 'simple']];
    }
}

/**
 * Fake $wpdb that captures SQL and returns configured catalogue/event rows.
 */
final class BoundedPageWpdb
{
    public string $posts = 'wp_posts';

    public string $postmeta = 'wp_postmeta';

    public string $captured_sql = '';

    /** @var array<int, mixed> */
    public array $captured_values = [];

    /** @var array<int, string> */
    public array $captured_sqls = [];

    /** @var array<int, array<string, mixed>> */
    public array $catalog_results = [];

    /** @var array<int, array<string, mixed>> */
    public array $event_results = [];

    public function prepare($sql, $args = null)
    {
        $values = func_get_args();
        array_shift($values);

        if (isset($values[0]) && is_array($values[0])) {
            $values = $values[0];
        }

        $this->captured_sql = (string) $sql;
        $this->captured_values = $values;
        $this->captured_sqls[] = (string) $sql;

        return (string) $sql;
    }

    public function get_results($prepared, $output = null)
    {
        $sql = (string) $prepared;

        if (strpos($sql, 'linked_ticket_products') !== false) {
            return $this->event_results;
        }

        return $this->catalog_results;
    }
}

/**
 * @return array<string, mixed>
 */
function fake_event_sql_row(int $id, int $linked = 0, ?string $title = null): array
{
    return [
        'tickera_event_id' => $id,
        'event_title' => $title ?? ('Event ' . $id),
        'event_slug' => 'event-' . $id,
        'event_status' => 'publish',
        'event_source_created_at' => '2026-07-31 10:00:00',
        'event_source_updated_at' => '2026-08-01 10:00:00',
        'event_start_at' => null,
        'event_end_at' => null,
        'event_location' => null,
        'booking_fee_type' => null,
        'booking_fee_value' => null,
        'linked_ticket_products' => $linked,
    ];
}

/**
 * @return array<string, mixed>
 */
function fake_catalog_sql_row(int $product_id, int $event_id): array
{
    return [
        'woo_product_id' => $product_id,
        'product_title' => 'Product ' . $product_id,
        'product_slug' => 'product-' . $product_id,
        'product_status' => 'publish',
        'product_source_updated_at' => '2026-08-01 10:00:00',
        'tickera_event_id' => $event_id,
        'event_title' => 'Event ' . $event_id,
        'event_slug' => 'event-' . $event_id,
        'event_status' => 'publish',
        'event_source_created_at' => '2026-07-31 10:00:00',
        'event_source_updated_at' => '2026-08-01 10:00:00',
        'woo_variation_id' => null,
        'variation_title' => null,
        'variation_status' => null,
        'variation_source_updated_at' => null,
        'event_reference_raw' => (string) $event_id,
        'ticket_display_name' => null,
        'price' => '10.00',
        'regular_price' => '10.00',
        'ticket_template_id' => '4242',
        'subscription_period' => null,
        'subscription_length' => null,
        'subscription_price' => null,
        'subscription_sign_up_fee' => null,
        'wc_subscription_period' => null,
        'wc_subscription_length' => null,
    ];
}

$params_page = static function (int $page, int $per_page): array {
    return [
        'updated_since' => null,
        'product_id' => null,
        'variation_id' => null,
        'event_id' => null,
        'page' => $page,
        'per_page' => $per_page,
        'include_private' => false,
    ];
};

$combined_has_more = new ReflectionMethod(Feed::class, 'combined_page_has_more');
$combined_has_more->setAccessible(true);
T::same('catalogue more, events done → has_more true', true, $combined_has_more->invoke(null, true, false));
T::same('catalogue done, events more → has_more true', true, $combined_has_more->invoke(null, false, true));
T::same('both more → has_more true', true, $combined_has_more->invoke(null, true, true));
T::same('both done → has_more false', false, $combined_has_more->invoke(null, false, false));

$event_wpdb = new BoundedPageWpdb();
$GLOBALS['wpdb'] = $event_wpdb;
$event_rows = new ReflectionMethod(Feed::class, 'event_rows');
$event_rows->setAccessible(true);

$event_wpdb->event_results = [];
$event_rows->invoke(new Feed(), $params_page(1, 100));
$event_sql_page1 = $event_wpdb->captured_sql;
$event_values_page1 = $event_wpdb->captured_values;

T::ok('event SQL was captured', $event_sql_page1 !== '');
T::ok('event SQL selects post_date_gmt as source creation authority', strpos($event_sql_page1, 'ev.post_date_gmt AS event_source_created_at') !== false);
T::ok('event SQL groups by post_date_gmt', preg_match('/GROUP BY[\s\S]*ev\.post_date_gmt/i', $event_sql_page1) === 1);
T::ok(
    'event SQL uses LIMIT/OFFSET placeholders',
    preg_match('/LIMIT\s+%d\s+OFFSET\s+%d/i', $event_sql_page1) === 1
);
T::ok(
    'event ORDER BY is title then ID',
    preg_match('/ORDER BY\s+ev\.post_title\s+ASC\s*,\s*ev\.ID\s+ASC/i', $event_sql_page1) === 1
);
T::same('page 1 event LIMIT is per_page+1', 101, (int) $event_values_page1[count($event_values_page1) - 2]);
T::same('page 1 event OFFSET is 0', 0, (int) $event_values_page1[count($event_values_page1) - 1]);

$event_wpdb->captured_values = [];
$event_rows->invoke(new Feed(), $params_page(2, 100));
$event_values_page2 = $event_wpdb->captured_values;
T::same('page 2 event LIMIT is per_page+1', 101, (int) $event_values_page2[count($event_values_page2) - 2]);
T::same('page 2 event OFFSET is 100', 100, (int) $event_values_page2[count($event_values_page2) - 1]);

$event_wpdb->event_results = array_map(
    static fn (int $id): array => fake_event_sql_row($id),
    range(1, 101)
);
$paged_events = $event_rows->invoke(new Feed(), $params_page(1, 100));
T::ok('event_rows returns bounded shape', is_array($paged_events) && isset($paged_events['rows'], $paged_events['has_more']));
T::same('sentinel excluded: emits exactly per_page events', 100, count($paged_events['rows']));
T::same('event sentinel sets has_more true', true, $paged_events['has_more']);
T::same('first emitted event id', 1, $paged_events['rows'][0]['tickera_event_id']);
T::same('last emitted event id excludes sentinel 101', 100, $paged_events['rows'][99]['tickera_event_id']);

$event_wpdb->event_results = [fake_event_sql_row(777, 0, 'Zero Product Event')];
$zero_product = $event_rows->invoke(new Feed(), $params_page(1, 100));
T::same('zero-product published event still emitted', 1, count($zero_product['rows']));
T::same('zero-product event id preserved', 777, $zero_product['rows'][0]['tickera_event_id']);
T::same('source creation serializes from post_date_gmt', '2026-07-31T10:00:00Z', $zero_product['rows'][0]['event_source_created_at']);
T::same('source update remains a separate clock', '2026-08-01T10:00:00Z', $zero_product['rows'][0]['event_source_updated_at']);
T::ok('source creation differs from event start metadata', $zero_product['rows'][0]['event_source_created_at'] !== $zero_product['rows'][0]['event_start_at']);
T::same('zero-product linked count is zero', 0, $zero_product['rows'][0]['linked_ticket_products']);
T::same('zero-product page has_more false', false, $zero_product['has_more']);
T::ok(
    'event SQL remains LEFT JOIN based (not catalogue-derived)',
    strpos($event_wpdb->captured_sql, 'LEFT JOIN wp_postmeta event_meta') !== false
    && strpos($event_wpdb->captured_sql, 'INNER JOIN wp_posts p') === false
);

// Catalogue sentinel regression: catalogue SQL still uses LIMIT per_page+1.
$catalog_wpdb = new BoundedPageWpdb();
$GLOBALS['wpdb'] = $catalog_wpdb;
$catalog_rows_method = new ReflectionMethod(Feed::class, 'catalog_rows');
$catalog_rows_method->setAccessible(true);
$catalog_rows_method->invoke(new Feed(), $params_page(1, 100));
$catalog_values = $catalog_wpdb->captured_values;
T::same('catalogue sentinel LIMIT remains per_page+1', 101, (int) $catalog_values[count($catalog_values) - 2]);
T::same('catalogue sentinel OFFSET remains 0', 0, (int) $catalog_values[count($catalog_values) - 1]);

Feed::read_or_create_snapshot_generation();
$build_response = new ReflectionMethod(Feed::class, 'build_response');
$build_response->setAccessible(true);

// Event-only continuation: catalogue exhausted, events remain.
$event_only_wpdb = new BoundedPageWpdb();
$event_only_wpdb->catalog_results = [];
$event_only_wpdb->event_results = array_map(
    static fn (int $id): array => fake_event_sql_row($id),
    range(1, 101)
);
$GLOBALS['wpdb'] = $event_only_wpdb;
$event_only_page = $build_response->invoke(new Feed(), $params_page(2, 100));
T::same('event-only page has empty catalog_rows', [], $event_only_page['catalog_rows']);
T::same('event-only page has empty evidence', [], $event_only_page['evidence']);
T::same('event-only page emits bounded events', 100, count($event_only_page['events']));
T::same('event-only continuation has_more true', true, $event_only_page['has_more']);
T::same('event-only page keeps shared page axis', 2, $event_only_page['page']);
T::same('event-only page keeps shared per_page', 100, $event_only_page['per_page']);
T::ok('event-only page has no event_page envelope key', !array_key_exists('event_page', $event_only_page));
T::ok('event-only page has no events_has_more envelope key', !array_key_exists('events_has_more', $event_only_page));

$event_only_wpdb->event_results = array_map(
    static fn (int $id): array => fake_event_sql_row($id),
    range(1, 50)
);
$event_only_final = $build_response->invoke(new Feed(), $params_page(3, 100));
T::same('final event-only page emits remaining events', 50, count($event_only_final['events']));
T::same('final event-only page has_more false', false, $event_only_final['has_more']);

// Catalogue-only continuation: events exhausted, catalogue remains.
$catalog_only_wpdb = new BoundedPageWpdb();
$catalog_only_wpdb->catalog_results = array_map(
    static fn (int $id): array => fake_catalog_sql_row($id, 10),
    range(1, 3)
);
$catalog_only_wpdb->event_results = [];
$GLOBALS['wpdb'] = $catalog_only_wpdb;
$catalog_only_page = $build_response->invoke(new Feed(), $params_page(2, 2));
T::same('catalogue-only page emits empty events', [], $catalog_only_page['events']);
T::same('catalogue-only page emits bounded catalog_rows', 2, count($catalog_only_page['catalog_rows']));
T::same('catalogue-only continuation has_more true', true, $catalog_only_page['has_more']);

$catalog_only_wpdb->catalog_results = array_map(
    static fn (int $id): array => fake_catalog_sql_row($id, 10),
    range(1, 1)
);
$catalog_only_final = $build_response->invoke(new Feed(), $params_page(3, 2));
T::same('final catalogue-only page emits remaining rows', 1, count($catalog_only_final['catalog_rows']));
T::same('final catalogue-only page has_more false', false, $catalog_only_final['has_more']);

// Both streams empty on page 1.
$empty_wpdb = new BoundedPageWpdb();
$empty_wpdb->catalog_results = [];
$empty_wpdb->event_results = [];
$GLOBALS['wpdb'] = $empty_wpdb;
$both_empty = $build_response->invoke(new Feed(), $params_page(1, 100));
T::same('both-empty page has empty catalog_rows', [], $both_empty['catalog_rows']);
T::same('both-empty page has empty events', [], $both_empty['events']);
T::same('both-empty page has_more false', false, $both_empty['has_more']);

// Both finished: catalogue and event sentinels absent together.
$both_done_wpdb = new BoundedPageWpdb();
$both_done_wpdb->catalog_results = [fake_catalog_sql_row(1, 10)];
$both_done_wpdb->event_results = [fake_event_sql_row(10, 1)];
$GLOBALS['wpdb'] = $both_done_wpdb;
$both_done = $build_response->invoke(new Feed(), $params_page(1, 100));
T::same('both-finished page has_more false', false, $both_done['has_more']);
T::same('both-finished emits one catalog row', 1, count($both_done['catalog_rows']));
T::same('both-finished emits one event', 1, count($both_done['events']));

// ---------------------------------------------------------------------------
if (T::$failures !== []) {
    fwrite(STDERR, "catalog feed native v3 tests FAILED\n");

    foreach (T::$failures as $failure) {
        fwrite(STDERR, '  - ' . $failure . "\n");
    }

    fwrite(STDERR, sprintf("passed: %d, failed: %d\n", T::$passes, count(T::$failures)));
    exit(1);
}

echo sprintf(
    "catalog feed native v3 tests passed: %d assertions, 0 failures\n",
    T::$passes
);
exit(0);
