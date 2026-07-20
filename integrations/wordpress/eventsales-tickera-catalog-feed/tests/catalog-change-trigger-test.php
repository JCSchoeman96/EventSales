<?php
define('ABSPATH', __DIR__);
define('EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED', true);
$actions = []; $scheduled = [];
function add_action(...$args) { global $actions; $actions[] = $args; }
function wp_is_post_autosave($id) { return false; }
function wp_is_post_revision($id) { return false; }
function get_post_type($id) { return $id === 2 ? 'product_variation' : 'product'; }
function wp_generate_uuid4() { return '123e4567-e89b-42d3-a456-426614174000'; }
function wp_json_encode($value) { return json_encode($value); }
function as_enqueue_async_action($hook, $args, $group) { global $scheduled; $scheduled[] = compact('hook','args','group'); }
require dirname(__DIR__) . '/eventsales-tickera-catalog-feed.php';
EventSales_Tickera_Catalog_Feed::record_catalog_change(1, 'saved');
EventSales_Tickera_Catalog_Feed::record_catalog_change(1, 'metadata_changed');
EventSales_Tickera_Catalog_Feed::record_catalog_change(2, 'saved');
EventSales_Tickera_Catalog_Feed::flush_catalog_changes();
if (count($scheduled) !== 2) { fwrite(STDERR, "expected two coalesced actions\n"); exit(1); }
$first = json_decode($scheduled[0]['args']['raw_body'], true);
if ($first['reason'] !== 'metadata_changed') { fwrite(STDERR, "reason precedence failed\n"); exit(1); }
echo "catalog change trigger tests passed\n";
