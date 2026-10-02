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

/** Minimal WC_Meta_Data shape used by Woo get_meta($key, false). */
final class Mock_WC_Meta_Data
{
    public function __construct(
        private string $key,
        private $value
    ) {
    }

    /** @return array{key: string, value: mixed} */
    public function get_data(): array
    {
        return [
            'key' => $this->key,
            'value' => $this->value,
        ];
    }
}

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
    /** @var array<int, Mock_WC_Meta_Data|array{key: string, value: string}> */
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
        $objects = [];

        foreach ($this->meta as $row) {
            if ($row instanceof Mock_WC_Meta_Data) {
                if ($row->get_data()['key'] === $key) {
                    $objects[] = $row;
                }

                continue;
            }

            if ($row['key'] === $key) {
                $objects[] = new Mock_WC_Meta_Data($row['key'], $row['value']);
            }
        }

        if ($single) {
            if ($objects === []) {
                return '';
            }

            return $objects[0]->get_data()['value'];
        }

        return $objects;
    }

    public function seed_meta_object(string $key, $value): void
    {
        $this->meta[] = new Mock_WC_Meta_Data($key, $value);
    }

    public function add_meta_data(string $key, $value, bool $unique = false): void
    {
        if ($unique) {
            $this->meta = array_values(array_filter(
                $this->meta,
                static function ($row) use ($key): bool {
                    if ($row instanceof Mock_WC_Meta_Data) {
                        return $row->get_data()['key'] !== $key;
                    }

                    return $row['key'] !== $key;
                }
            ));
        }

        $this->meta[] = new Mock_WC_Meta_Data($key, (string) $value);
    }

    public function save(): void
    {
        $this->saved = true;
    }

    public function was_saved(): bool
    {
        return $this->saved;
    }

    /** @return array<int, string> */
    public function tickera_event_values(): array
    {
        $values = [];

        foreach ($this->meta as $row) {
            if ($row instanceof Mock_WC_Meta_Data) {
                $data = $row->get_data();
                if ($data['key'] === Resolver::META_TICKERA_EVENT_ID) {
                    $values[] = (string) $data['value'];
                }
            }
        }

        return $values;
    }
}

// --- resolver basics ---
seed_event(100342);
seed_product(100344, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => '100342',
]);
T::same('product-only ticket resolves event', Resolver::STATE_RESOLVED, resolve_line(100344, 0)['state']);
T::same('product-only event id', 100342, resolve_line(100344, 0)['event_id']);

seed_product(100345, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => '100342',
]);
seed_product(100346, [], 'product_variation', 100345);
$variation_resolution = resolve_line(100345, 100346);
T::same('variation ticket resolves event', Resolver::STATE_RESOLVED, $variation_resolution['state']);
T::same('variation uses parent event id', 100342, $variation_resolution['event_id']);

seed_product(200001, [Resolver::META_EVENT_REFERENCE => '100342']);
T::same('non-ticket is not applicable', Resolver::STATE_NOT_APPLICABLE, resolve_line(200001, 0)['state']);

seed_product(200002, [Resolver::META_TICKET_FLAG => 'yes']);
T::same('ticket without event reference is unresolved', Resolver::STATE_UNRESOLVED, resolve_line(200002, 0)['state']);

seed_event(300001);
seed_event(300002);
seed_product(200003, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => ['300001', '300002'],
]);
T::same('conflicting event references', Resolver::STATE_CONFLICT, resolve_line(200003, 0)['state']);

// --- _event_name fail-closed ---
seed_product(200010, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => ['100342', '100342'],
]);
T::same('duplicate valid event references resolve', Resolver::STATE_RESOLVED, resolve_line(200010, 0)['state']);

seed_product(200011, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => ['100342', 'garbage'],
]);
T::same('valid plus malformed reference is conflict', Resolver::STATE_CONFLICT, resolve_line(200011, 0)['state']);

seed_product(200012, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => 'not-an-id',
]);
T::same('malformed only reference is conflict', Resolver::STATE_CONFLICT, resolve_line(200012, 0)['state']);

seed_product(200013, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => '999999',
]);
T::same('unresolved positive event id is conflict', Resolver::STATE_CONFLICT, resolve_line(200013, 0)['state']);

// --- variation integrity ---
seed_product(200020, [
    Resolver::META_TICKET_FLAG => 'yes',
    Resolver::META_EVENT_REFERENCE => '100342',
]);
seed_product(200021, [], 'product_variation', 999999);
T::same('variation parent mismatch is unresolved', Resolver::STATE_UNRESOLVED, resolve_line(200020, 200021)['state']);

seed_product(200022, [], 'product', 0);
T::same('non-variation post type is unresolved', Resolver::STATE_UNRESOLVED, resolve_line(200020, 200022)['state']);

// --- existing meta decision (scalar inputs) ---
$idem = Resolver::apply_to_order_item_meta(['100342'], ['state' => Resolver::STATE_RESOLVED, 'event_id' => 100342]);
T::same('identical existing meta is idempotent', Resolver::OUTCOME_IDEMPOTENT, $idem['outcome']);

$conflict_existing = Resolver::apply_to_order_item_meta(
    ['100342'],
    ['state' => Resolver::STATE_RESOLVED, 'event_id' => 100343]
);
T::same('different existing meta is not overwritten', Resolver::OUTCOME_CONFLICT_EXISTING, $conflict_existing['outcome']);
T::same('conflict does not schedule write', null, $conflict_existing['write']);

$multi_existing = Resolver::apply_to_order_item_meta(
    ['100342', '100343'],
    ['state' => Resolver::STATE_RESOLVED, 'event_id' => 100342]
);
T::same('multiple existing values are conflict', Resolver::OUTCOME_CONFLICT_EXISTING, $multi_existing['outcome']);

$invalid_existing = Resolver::apply_to_order_item_meta(
    ['not-an-id'],
    ['state' => Resolver::STATE_RESOLVED, 'event_id' => 100342]
);
T::same('invalid existing value blocks write', Resolver::OUTCOME_CONFLICT_EXISTING, $invalid_existing['outcome']);

// --- Woo meta object extraction ---
$extracted = EventSales_Woo_Order_Line_Identity::extract_tickera_event_meta_values(
    (static function (): object {
        $item = new Mock_Order_Item_Product(1, 0);
        $item->seed_meta_object(Resolver::META_TICKERA_EVENT_ID, '100342');

        return $item;
    })()
);
T::same('extract meta object value', '100342', $extracted[0] ?? null);

// --- hook-level idempotency with WC_Meta_Data objects ---
$idempotent_item = new Mock_Order_Item_Product(100344, 0);
$idempotent_item->seed_meta_object(Resolver::META_TICKERA_EVENT_ID, '100342');
EventSales_Woo_Order_Line_Identity::enrich_line_item($idempotent_item, 'key', [], new stdClass());
T::same('idempotent enrichment keeps single value', ['100342'], $idempotent_item->tickera_event_values());

$conflict_item = new Mock_Order_Item_Product(100344, 0);
$conflict_item->seed_meta_object(Resolver::META_TICKERA_EVENT_ID, '100343');
EventSales_Woo_Order_Line_Identity::enrich_line_item($conflict_item, 'key', [], new stdClass());
T::same('conflicting enrichment preserves existing', ['100343'], $conflict_item->tickera_event_values());

$multi_item = new Mock_Order_Item_Product(100344, 0);
$multi_item->seed_meta_object(Resolver::META_TICKERA_EVENT_ID, '100342');
$multi_item->seed_meta_object(Resolver::META_TICKERA_EVENT_ID, '100343');
EventSales_Woo_Order_Line_Identity::enrich_line_item($multi_item, 'key', [], new stdClass());
T::same('multiple existing meta rows unchanged', ['100342', '100343'], $multi_item->tickera_event_values());

$invalid_item = new Mock_Order_Item_Product(100344, 0);
$invalid_item->seed_meta_object(Resolver::META_TICKERA_EVENT_ID, 'not-an-id');
EventSales_Woo_Order_Line_Identity::enrich_line_item($invalid_item, 'key', [], new stdClass());
T::same('invalid existing meta preserved', ['not-an-id'], $invalid_item->tickera_event_values());

// fresh write still works
$fresh_item = new Mock_Order_Item_Product(100344, 0);
EventSales_Woo_Order_Line_Identity::enrich_line_item($fresh_item, 'key', [], new stdClass());
T::same('fresh checkout write', ['100342'], $fresh_item->tickera_event_values());

$resolver_source = file_get_contents(dirname(__DIR__) . '/eventsales-tickera-event-resolver.php');
$plugin_source = file_get_contents(dirname(__DIR__) . '/eventsales-woo-order-line-identity.php');
T::ok('resolver never reads post_title', strpos((string) $resolver_source, 'post_title') === false);
T::ok('plugin never reads post_title', strpos((string) $plugin_source, 'post_title') === false);

EventSales_Woo_Order_Line_Identity::enrich_line_item(new Mock_Order_Item_Product(100344), 'k', [], new stdClass());
T::same('no outbound HTTP during enrichment', 0, $GLOBALS['http_calls']);

T::ok('checkout hook registered', in_array('woocommerce_checkout_create_order_line_item', array_column($GLOBALS['registered_actions'], 'hook'), true));
T::ok('new order item hook registered', in_array('woocommerce_new_order_item', array_column($GLOBALS['registered_actions'], 'hook'), true));

$forbidden_transport = preg_match(
    '/wp_remote_|curl_exec|eventsales\\/v1|127\\.0\\.0\\.1:4001/i',
    (string) $plugin_source . (string) $resolver_source
);
T::same('forbidden transport absent from producer sources', 0, $forbidden_transport);

$admin_item = new Mock_Order_Item_Product(100344, 0);
EventSales_Woo_Order_Line_Identity::enrich_saved_line_item(1, $admin_item, 99);
T::ok('admin path persists meta via save()', $admin_item->was_saved());

if (T::$failures !== []) {
    fwrite(STDERR, implode("\n", T::$failures) . "\n");
    exit(1);
}

fwrite(STDOUT, 'OK ' . T::$passes . " assertions\n");
exit(0);
