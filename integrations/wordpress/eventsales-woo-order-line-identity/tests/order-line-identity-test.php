<?php

declare(strict_types=1);

/**
 * Focused producer tests for authoritative Tickera event identity on Woo order lines.
 */

define('ABSPATH', __DIR__);

$GLOBALS['registered_actions'] = [];
$GLOBALS['posts'] = [];
$GLOBALS['post_meta'] = [];
$GLOBALS['http_calls'] = 0;

function add_action($hook, $callback, $priority = 10, $accepted_args = 1)
{
    $GLOBALS['registered_actions'][] = [
        'hook' => $hook,
        'callback' => $callback,
        'priority' => $priority,
        'accepted_args' => $accepted_args,
    ];

    return true;
}

function get_post_meta($post_id, $key, $single = true)
{
    $post_id = (int) $post_id;
    $bucket = $GLOBALS['post_meta'][$post_id][$key] ?? [];

    if ($single) {
        return $bucket[0] ?? '';
    }

    return $bucket;
}

function get_post($post_id)
{
    return $GLOBALS['posts'][(int) $post_id] ?? null;
}

function wp_remote_post(...$args)
{
    $GLOBALS['http_calls']++;

    return new WP_Error('forbidden', 'network');
}

require dirname(__DIR__) . '/eventsales-tickera-event-resolver.php';
require dirname(__DIR__) . '/eventsales-woo-order-line-identity.php';

class_alias('EventSales_Tickera_Event_Resolver', 'Resolver');

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
        self::ok($label, $expected === $actual);
    }
}

/**
 * @param array<string, mixed> $meta
 */
function seed_product(int $product_id, array $meta, string $post_type = 'product', int $parent = 0): void
{
    $GLOBALS['posts'][$product_id] = (object) [
        'ID' => $product_id,
        'post_type' => $post_type,
        'post_parent' => $parent,
        'post_status' => 'publish',
        'post_title' => 'Display title must not be used ' . $product_id,
    ];

    foreach ($meta as $key => $value) {
        $GLOBALS['post_meta'][$product_id][$key] = is_array($value) ? $value : [$value];
    }
}

function seed_event(int $event_id, string $status = 'publish'): void
{
    $GLOBALS['posts'][$event_id] = (object) [
        'ID' => $event_id,
        'post_type' => 'tc_events',
        'post_parent' => 0,
        'post_status' => $status,
        'post_title' => 'Event title ' . $event_id,
    ];
}

function resolve_line(int $product_id, int $variation_id = 0): array
{
    return Resolver::resolve_for_product_line(
        $product_id,
        $variation_id,
        static fn (int $post_id): string => (string) get_post_meta($post_id, Resolver::META_TICKET_FLAG, true),
        static fn (int $post_id): array => get_post_meta($post_id, Resolver::META_EVENT_REFERENCE, false),
        static fn (int $post_id) => get_post($post_id)
    );
}

final class Mock_Order_Item_Product
{
    /** @var array<int, array{key: string, value: string}> */
    private array $meta = [];

    private bool $saved = false;

    public function __construct(
        private int $product_id,
        private int $variation_id = 0
    ) {
    }

    public function get_product_id(): int
    {
        return $this->product_id;
    }

    public function get_variation_id(): int
    {
        return $this->variation_id;
    }

    public function get_meta($key, $single = true)
    {
        $values = [];

        foreach ($this->meta as $row) {
            if ($row['key'] === $key) {
                $values[] = $row['value'];
            }
        }

        if ($single) {
            return $values[0] ?? '';
        }

        return $values;
    }

    public function add_meta_data(string $key, $value, bool $unique = false): void
    {
        if ($unique) {
            $this->meta = array_values(array_filter(
                $this->meta,
                static fn (array $row): bool => $row['key'] !== $key
            ));
        }

        $this->meta[] = ['key' => $key, 'value' => (string) $value];
    }

    public function save(): void
    {
        $this->saved = true;
    }

    public function was_saved(): bool
    {
        return $this->saved;
    }

    /** @return array<int, array{key: string, value: string}> */
    public function rest_meta_data(): array
    {
        $out = [];
        $id = 1;

        foreach ($this->meta as $row) {
            $out[] = [
                'id' => $id++,
                'key' => $row['key'],
                'value' => $row['value'],
            ];
        }

        return $out;
    }
}

// 1. product-only ticket resolves exact event
seed_event(100342);
seed_product(100344, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => '100342',
]);
T::same('product-only ticket resolves event', Resolver::STATE_RESOLVED, resolve_line(100344, 0)['state']);
T::same('product-only event id', 100342, resolve_line(100344, 0)['event_id']);

// 2. variation ticket resolves via parent authority
seed_product(100345, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => '100342',
]);
seed_product(100346, [], 'product_variation', 100345);
$variation_resolution = resolve_line(100345, 100346);
T::same('variation ticket resolves event', Resolver::STATE_RESOLVED, $variation_resolution['state']);
T::same('variation uses parent event id', 100342, $variation_resolution['event_id']);

// 3. non-ticket product
seed_product(200001, [Resolver::META_EVENT_REFERENCE => '100342']);
T::same('non-ticket is not applicable', Resolver::STATE_NOT_APPLICABLE, resolve_line(200001, 0)['state']);

// 4. absent relationship
seed_product(200002, [Resolver::META_TICKET_FLAG => 'yes']);
T::same('ticket without event reference is unresolved', Resolver::STATE_UNRESOLVED, resolve_line(200002, 0)['state']);

// 5. conflicting references
seed_event(300001);
seed_event(300002);
seed_product(200003, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => ['300001', '300002'],
]);
T::same('conflicting event references', Resolver::STATE_CONFLICT, resolve_line(200003, 0)['state']);

// 6. titles are never consulted — resolver source must not call get_the_title
$resolver_source = file_get_contents(dirname(__DIR__) . '/eventsales-tickera-event-resolver.php');
$plugin_source = file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-line-identity.php');
T::ok('resolver never reads post_title', strpos((string) $resolver_source, 'post_title') === false);
T::ok('plugin never reads post_title', strpos((string) $plugin_source, 'post_title') === false);
T::ok('resolver never uses slug matching', strpos((string) $resolver_source, 'post_name') === false);

// 7. idempotent existing meta
$idem = Resolver::apply_to_order_item_meta(['100342'], ['state' => Resolver::STATE_RESOLVED, 'event_id' => 100342]);
T::same('identical existing meta is idempotent', Resolver::OUTCOME_IDEMPOTENT, $idem['outcome']);

// 8. conflicting existing meta
$conflict_existing = Resolver::apply_to_order_item_meta(
    ['100342'],
    ['state' => Resolver::STATE_RESOLVED, 'event_id' => 100343]
);
T::same('different existing meta is not overwritten', Resolver::OUTCOME_CONFLICT_EXISTING, $conflict_existing['outcome']);
T::same('conflict does not schedule write', null, $conflict_existing['write']);

// 9. invalid ids are never written
$invalid = Resolver::apply_to_order_item_meta([], ['state' => Resolver::STATE_RESOLVED, 'event_id' => 0]);
T::same('zero event id is not written', null, $invalid['write']);
seed_product(200004, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => 'not-an-id',
]);
T::same('malformed event reference is unresolved', Resolver::STATE_UNRESOLVED, resolve_line(200004, 0)['state']);

// 10. REST-shaped meta_data exposure
$item = new Mock_Order_Item_Product(100344, 0);
EventSales_Woo_Order_Line_Identity::enrich_line_item($item, 'key', [], new stdClass());
$meta = $item->rest_meta_data();
T::ok('checkout hook writes tickera_event_id meta', count($meta) === 1);
T::same('meta key', Resolver::META_TICKERA_EVENT_ID, $meta[0]['key'] ?? '');
T::same('meta value string', '100342', $meta[0]['value'] ?? '');

// 11. no customer/payment keys introduced
foreach ($meta as $row) {
    T::ok('meta key allowlisted', $row['key'] === Resolver::META_TICKERA_EVENT_ID);
}

// 12. no EventSales network request in hook path
EventSales_Woo_Order_Line_Identity::enrich_line_item(new Mock_Order_Item_Product(100344), 'k', [], new stdClass());
T::same('no outbound HTTP during enrichment', 0, $GLOBALS['http_calls']);

// 13–14. sibling plugins untouched — this test file only loads order-line identity

T::ok('checkout hook registered', in_array('woocommerce_checkout_create_order_line_item', array_column($GLOBALS['registered_actions'], 'hook'), true));
T::ok('new order item hook registered', in_array('woocommerce_new_order_item', array_column($GLOBALS['registered_actions'], 'hook'), true));

$forbidden_transport = preg_match(
    '/wp_remote_|curl_exec|eventsales\\/v1|127\\.0\\.0\\.1:4001/i',
    (string) $plugin_source . (string) $resolver_source
);
T::same('forbidden transport absent from producer sources', 0, $forbidden_transport);

// new_order_item persistence path
$admin_item = new Mock_Order_Item_Product(100344, 0);
EventSales_Woo_Order_Line_Identity::enrich_saved_line_item(1, $admin_item, 99);
T::ok('admin path persists meta via save()', $admin_item->was_saved());

if (T::$failures !== []) {
    fwrite(STDERR, implode("\n", T::$failures) . "\n");
    exit(1);
}

fwrite(STDOUT, 'OK ' . T::$passes . " assertions\n");
exit(0);
