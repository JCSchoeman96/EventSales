<?php
/**
 * Plugin Name: EventSales Woo Order Line Identity
 * Description: Persists authoritative Tickera event identity on qualifying WooCommerce ticket order lines.
 * Version: 0.1.2
 * Requires at least: 5.6
 * Requires PHP: 8.0
 * Update URI: https://github.com/JCSchoeman96/EventSales
 * Author: EventSales
 * License: GPL-2.0-or-later
 */

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

require_once __DIR__ . '/eventsales-tickera-event-resolver.php';

final class EventSales_Woo_Order_Line_Identity
{
    public static function register(): void
    {
        add_action('woocommerce_checkout_create_order_line_item', [self::class, 'enrich_line_item'], 20, 4);
        add_action('woocommerce_new_order_item', [self::class, 'enrich_saved_line_item'], 20, 3);
    }

    /**
     * Checkout and programmatic order creation before the first item save.
     *
     * @param WC_Order_Item_Product $item
     * @param string                $cart_item_key
     * @param array<string, mixed>  $values
     * @param WC_Order              $order
     */
    public static function enrich_line_item($item, $cart_item_key, $values, $order): void
    {
        if (!is_object($item) || !method_exists($item, 'get_product_id')) {
            return;
        }

        self::maybe_write_item_meta($item, false);
    }

    /**
     * Admin, REST, and other flows that create order items through WC_Order_Item::save().
     *
     * @param int                   $item_id
     * @param WC_Order_Item_Product $item
     * @param int                   $order_id
     */
    public static function enrich_saved_line_item($item_id, $item, $order_id): void
    {
        if (!is_object($item) || !method_exists($item, 'get_product_id')) {
            return;
        }

        if ($item->get_meta(EventSales_Tickera_Event_Resolver::META_TICKERA_EVENT_ID, true) !== '') {
            return;
        }

        self::maybe_write_item_meta($item, true);
    }

    private static function maybe_write_item_meta($item, bool $persist_immediately): void
    {
        $product_id = (int) $item->get_product_id();
        $variation_id = (int) $item->get_variation_id();

        $resolution = EventSales_Tickera_Event_Resolver::resolve_for_product_line(
            $product_id,
            $variation_id,
            static fn (int $post_id): array => self::ticket_flag_values($post_id),
            static fn (int $post_id): array => self::event_reference_values($post_id),
            static fn (int $post_id) => get_post($post_id)
        );

        $existing = self::extract_tickera_event_meta_values($item);
        $decision = EventSales_Tickera_Event_Resolver::apply_to_order_item_meta($existing, $resolution);

        if ($decision['write'] === null) {
            return;
        }

        $item->add_meta_data(
            EventSales_Tickera_Event_Resolver::META_TICKERA_EVENT_ID,
            (string) $decision['write'],
            true
        );

        if ($persist_immediately && method_exists($item, 'save')) {
            $item->save();
        }
    }

    /**
     * WooCommerce returns WC_Meta_Data objects for get_meta($key, false).
     *
     * @return array<int, mixed>
     */
    public static function extract_tickera_event_meta_values($item): array
    {
        if (!is_object($item) || !method_exists($item, 'get_meta')) {
            return [];
        }

        $entries = $item->get_meta(EventSales_Tickera_Event_Resolver::META_TICKERA_EVENT_ID, false);
        if (!is_array($entries)) {
            return [];
        }

        $values = [];

        foreach ($entries as $entry) {
            $values[] = self::extract_meta_entry_value($entry);
        }

        return $values;
    }

    private static function extract_meta_entry_value($entry)
    {
        if (is_object($entry) && method_exists($entry, 'get_data')) {
            $data = $entry->get_data();

            return is_array($data) ? ($data['value'] ?? null) : null;
        }

        return $entry;
    }

    /**
     * @return array<int, mixed>
     */
    private static function ticket_flag_values(int $post_id): array
    {
        $values = get_post_meta($post_id, EventSales_Tickera_Event_Resolver::META_TICKET_FLAG, false);

        return is_array($values) ? $values : [];
    }

    /**
     * @return array<int, string>
     */
    private static function event_reference_values(int $post_id): array
    {
        $values = get_post_meta($post_id, EventSales_Tickera_Event_Resolver::META_EVENT_REFERENCE, false);

        if (!is_array($values)) {
            return [];
        }

        $normalized = [];

        foreach ($values as $value) {
            $raw = EventSales_Tickera_Event_Resolver::preserve_raw_meta_value($value);
            if ($raw !== null) {
                $normalized[] = $raw;
            }
        }

        return $normalized;
    }
}

EventSales_Woo_Order_Line_Identity::register();
