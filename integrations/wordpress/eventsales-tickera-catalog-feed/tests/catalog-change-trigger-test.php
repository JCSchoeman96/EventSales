<?php
define('ABSPATH', __DIR__);
define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);
define('EVENTSALES_CATALOG_CHANGE_ENDPOINT', 'https://eventsales.example/webhooks/catalog-change/token');
define('EVENTSALES_CATALOG_CHANGE_SECRET', 'test-trigger-secret');
define('EVENTSALES_CATALOG_CHANGE_KEY_ID', 'test-key');
$actions = []; $scheduled = []; $cache_updates = 0; $remote_requests = []; $retry_actions = [];
class WP_Post { public int $ID; public function __construct(int $id) { $this->ID = $id; } }
function add_action(...$args) { global $actions; $actions[] = $args; }
function get_option($name, $default = false) { return 1; }
function update_option($name, $value, $autoload = null) { global $cache_updates; $cache_updates++; return true; }
function wp_is_post_autosave($id) { return false; }
function wp_is_post_revision($id) { return false; }
function get_post_type($id) { return $id === 2 ? 'product_variation' : 'product'; }
function wp_generate_uuid4() { return '123e4567-e89b-42d3-a456-426614174000'; }
function wp_json_encode($value) { return json_encode($value); }
function wp_parse_url($url, $component = -1) { return parse_url($url, $component); }
function wp_remote_post($url, $args) { global $remote_requests; $remote_requests[] = compact('url', 'args'); return ['response' => ['code' => 503]]; }
function wp_remote_retrieve_response_code($response) { return $response['response']['code']; }
function is_wp_error($value) { return false; }
function as_enqueue_async_action($hook, $args, $group) { global $scheduled; $scheduled[] = compact('hook','args','group'); }
function as_schedule_single_action($timestamp, $hook, $args, $group) { global $retry_actions; $retry_actions[] = compact('timestamp','hook','args','group'); }
function fire_test_action($hook, ...$args) {
    global $actions;
    foreach ($actions as $registration) {
        if ($registration[0] === $hook) { ($registration[1])(...$args); }
    }
}
require dirname(__DIR__) . '/eventsales-tickera-catalog-feed.php';
EventSales_Tickera_Catalog_Feed::record_catalog_change(1, 'saved');
EventSales_Tickera_Catalog_Feed::record_catalog_change(1, 'metadata_changed');
EventSales_Tickera_Catalog_Feed::record_catalog_change(2, 'saved');
EventSales_Tickera_Catalog_Feed::flush_catalog_changes();
if (count($scheduled) !== 2) { fwrite(STDERR, "expected two coalesced actions\n"); exit(1); }
$first = json_decode($scheduled[0]['args']['raw_body'], true);
if ($first['reason'] !== 'metadata_changed') { fwrite(STDERR, "reason precedence failed\n"); exit(1); }

$before = $cache_updates;
EventSales_Tickera_Catalog_Feed::record_meta_change(1, 1, '_price');
if ($cache_updates !== $before + 1) { fwrite(STDERR, "metadata cache invalidation failed\n"); exit(1); }

$before = $cache_updates;
EventSales_Tickera_Catalog_Feed::record_status_change('publish', 'draft', new WP_Post(1));
if ($cache_updates !== $before + 1) { fwrite(STDERR, "status cache invalidation failed\n"); exit(1); }

foreach (['trashed_post', 'untrashed_post', 'before_delete_post'] as $hook) {
    $before = $cache_updates;
    fire_test_action($hook, 1);
    if ($cache_updates !== $before + 1) { fwrite(STDERR, "$hook cache invalidation failed\n"); exit(1); }
}

$raw_body = $scheduled[0]['args']['raw_body'];
EventSales_Tickera_Catalog_Feed::deliver_catalog_change($raw_body, 1);
if (count($remote_requests) !== 1) { fwrite(STDERR, "delivery request missing\n"); exit(1); }
$headers = $remote_requests[0]['args']['headers'];
$timestamp = $headers['X-EventSales-Trigger-Timestamp'];
$canonical = implode("\n", ['2026-07-20.v1', 'POST', '/webhooks/catalog-change/token', $timestamp, hash('sha256', $raw_body)]);
$expected = 'v1=' . hash_hmac('sha256', $canonical, EVENTSALES_CATALOG_CHANGE_SECRET);
if (!hash_equals($expected, $headers['X-EventSales-Trigger-Signature'])) { fwrite(STDERR, "delivery signature failed\n"); exit(1); }
if (count($retry_actions) !== 1 || $retry_actions[0]['args']['raw_body'] !== $raw_body || $retry_actions[0]['args']['attempt'] !== 2) {
    fwrite(STDERR, "retry did not preserve raw body\n"); exit(1);
}
echo "catalog change trigger tests passed\n";
