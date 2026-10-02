<?php

declare(strict_types=1);

/**
 * Authoritative Tickera event resolution for Woo ticket lines.
 *
 * Authority matches the EventSales catalog producer:
 * parent product `_tc_is_ticket` = yes and `_event_name` positive integer
 * referencing an existing `tc_events` post ID.
 */

if (!defined('ABSPATH')) {
    exit;
}

final class EventSales_Tickera_Event_Resolver
{
    public const META_TICKERA_EVENT_ID = 'tickera_event_id';
    public const META_TICKET_FLAG = '_tc_is_ticket';
    public const META_EVENT_REFERENCE = '_event_name';
    public const POST_TYPE_EVENT = 'tc_events';

    public const STATE_NOT_APPLICABLE = 'NOT_APPLICABLE';
    public const STATE_RESOLVED = 'RESOLVED';
    public const STATE_UNRESOLVED = 'UNRESOLVED';
    public const STATE_CONFLICT = 'CONFLICT';

    public const OUTCOME_IDEMPOTENT = 'IDEMPOTENT';
    public const OUTCOME_WRITTEN = 'WRITTEN';
    public const OUTCOME_SKIPPED = 'SKIPPED';
    public const OUTCOME_CONFLICT_EXISTING = 'CONFLICT_EXISTING';

    /**
     * @param callable(int, string): array<int, string> $event_reference_reader
     * @param callable(int): ?object $post_loader
     */
    public static function resolve_for_product_line(
        int $product_id,
        int $variation_id,
        callable $ticket_flag_reader,
        callable $event_reference_reader,
        callable $post_loader
    ): array {
        $authority_product_id = self::authority_product_id($product_id, $variation_id, $post_loader);

        if ($authority_product_id === null) {
            return self::resolution(self::STATE_UNRESOLVED, null);
        }

        $ticket_flag = $ticket_flag_reader($authority_product_id);
        if ($ticket_flag !== 'yes') {
            return self::resolution(self::STATE_NOT_APPLICABLE, null);
        }

        $references = $event_reference_reader($authority_product_id);
        if ($references === []) {
            return self::resolution(self::STATE_UNRESOLVED, null);
        }

        $resolved_ids = [];

        foreach ($references as $raw_reference) {
            $parsed = self::positive_int_or_null(self::preserve_raw_meta_value($raw_reference));
            if ($parsed === null) {
                continue;
            }

            $event_post = $post_loader($parsed);
            if (!self::valid_event_post($event_post)) {
                continue;
            }

            if ((int) $event_post->ID !== $parsed) {
                continue;
            }

            $resolved_ids[$parsed] = true;
        }

        $unique = array_keys($resolved_ids);

        if (count($unique) === 1) {
            return self::resolution(self::STATE_RESOLVED, $unique[0]);
        }

        if (count($unique) > 1) {
            return self::resolution(self::STATE_CONFLICT, null);
        }

        return self::resolution(self::STATE_UNRESOLVED, null);
    }

    /**
     * @param array{state: string, event_id: ?int} $resolution
     */
    public static function apply_to_order_item_meta($existing_meta_values, array $resolution): array
    {
        $existing = self::normalize_existing_event_ids($existing_meta_values);

        if ($resolution['state'] === self::STATE_NOT_APPLICABLE) {
            return ['outcome' => self::OUTCOME_SKIPPED, 'write' => null];
        }

        if ($resolution['state'] === self::STATE_UNRESOLVED || $resolution['state'] === self::STATE_CONFLICT) {
            return ['outcome' => self::OUTCOME_SKIPPED, 'write' => null];
        }

        $event_id = $resolution['event_id'];
        if (!is_int($event_id) || $event_id < 1) {
            return ['outcome' => self::OUTCOME_SKIPPED, 'write' => null];
        }

        if ($existing === []) {
            return ['outcome' => self::OUTCOME_WRITTEN, 'write' => $event_id];
        }

        if (count($existing) === 1 && $existing[0] === $event_id) {
            return ['outcome' => self::OUTCOME_IDEMPOTENT, 'write' => null];
        }

        return ['outcome' => self::OUTCOME_CONFLICT_EXISTING, 'write' => null];
    }

    /**
     * @return array<int, int>
     */
    public static function normalize_existing_event_ids($values): array
    {
        if (!is_array($values)) {
            $values = [$values];
        }

        $parsed = [];

        foreach ($values as $value) {
            $id = self::positive_int_or_null(self::preserve_raw_meta_value($value));
            if ($id !== null) {
                $parsed[] = $id;
            }
        }

        return array_values(array_unique($parsed));
    }

    public static function authority_product_id(int $product_id, int $variation_id, callable $post_loader): ?int
    {
        if ($variation_id > 0) {
            $variation_post = $post_loader($variation_id);
            if ($variation_post === null) {
                return $product_id > 0 ? $product_id : null;
            }

            $parent = (int) ($variation_post->post_parent ?? 0);

            return $parent > 0 ? $parent : ($product_id > 0 ? $product_id : null);
        }

        return $product_id > 0 ? $product_id : null;
    }

    public static function preserve_raw_meta_value($value): ?string
    {
        if ($value === null) {
            return null;
        }

        if (is_string($value)) {
            return $value;
        }

        if (is_int($value) || is_float($value)) {
            return (string) $value;
        }

        return null;
    }

    public static function positive_int_or_null($value): ?int
    {
        $raw = self::preserve_raw_meta_value($value);
        if ($raw === null) {
            return null;
        }

        $trimmed = trim($raw);
        if ($trimmed === '' || !preg_match('/^[1-9][0-9]*$/', $trimmed)) {
            return null;
        }

        return (int) $trimmed;
    }

    /**
     * @return array{state: string, event_id: ?int}
     */
    private static function resolution(string $state, ?int $event_id): array
    {
        return [
            'state' => $state,
            'event_id' => $event_id,
        ];
    }

    private static function valid_event_post($post): bool
    {
        if ($post === null || !is_object($post)) {
            return false;
        }

        $type = isset($post->post_type) ? (string) $post->post_type : '';
        $status = isset($post->post_status) ? (string) $post->post_status : '';

        return $type === self::POST_TYPE_EVENT && $status !== 'trash';
    }
}
