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
    public const POST_TYPE_VARIATION = 'product_variation';

    public const STATE_NOT_APPLICABLE = 'NOT_APPLICABLE';
    public const STATE_RESOLVED = 'RESOLVED';
    public const STATE_UNRESOLVED = 'UNRESOLVED';
    public const STATE_CONFLICT = 'CONFLICT';

    public const OUTCOME_IDEMPOTENT = 'IDEMPOTENT';
    public const OUTCOME_WRITTEN = 'WRITTEN';
    public const OUTCOME_SKIPPED = 'SKIPPED';
    public const OUTCOME_CONFLICT_EXISTING = 'CONFLICT_EXISTING';

    /**
     * @param callable(int): array<int, mixed> $ticket_flag_reader
     * @param callable(int): array<int, string> $event_reference_reader
     * @param callable(int): ?object $post_loader
     */
    public static function resolve_for_product_line(
        int $product_id,
        int $variation_id,
        callable $ticket_flag_reader,
        callable $event_reference_reader,
        callable $post_loader
    ): array {
        if (!self::variation_line_integrity($product_id, $variation_id, $post_loader)) {
            return self::resolution(self::STATE_UNRESOLVED, null);
        }

        $authority_product_id = self::authority_product_id($product_id, $variation_id, $post_loader);

        if ($authority_product_id === null) {
            return self::resolution(self::STATE_UNRESOLVED, null);
        }

        if (!self::is_ticket_product($ticket_flag_reader($authority_product_id))) {
            return self::resolution(self::STATE_NOT_APPLICABLE, null);
        }

        $references = $event_reference_reader($authority_product_id);
        if ($references === []) {
            return self::resolution(self::STATE_UNRESOLVED, null);
        }

        $resolved_ids = [];

        foreach ($references as $raw_reference) {
            $raw = self::preserve_raw_meta_value($raw_reference);
            if ($raw === null) {
                return self::resolution(self::STATE_CONFLICT, null);
            }

            $trimmed = trim($raw);
            if ($trimmed === '') {
                return self::resolution(self::STATE_CONFLICT, null);
            }

            $parsed = self::positive_int_or_null($trimmed);
            if ($parsed === null) {
                return self::resolution(self::STATE_CONFLICT, null);
            }

            $event_post = $post_loader($parsed);
            if (!self::valid_event_post($event_post) || (int) $event_post->ID !== $parsed) {
                return self::resolution(self::STATE_CONFLICT, null);
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
        $analysis = self::analyze_existing_event_meta($existing_meta_values);

        if ($analysis['has_invalid']) {
            return ['outcome' => self::OUTCOME_CONFLICT_EXISTING, 'write' => null];
        }

        if (count($analysis['valid_ids']) > 1) {
            return ['outcome' => self::OUTCOME_CONFLICT_EXISTING, 'write' => null];
        }

        $existing = $analysis['valid_ids'];

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

        if ($existing[0] === $event_id) {
            return ['outcome' => self::OUTCOME_IDEMPOTENT, 'write' => null];
        }

        return ['outcome' => self::OUTCOME_CONFLICT_EXISTING, 'write' => null];
    }

    /**
     * @return array{valid_ids: array<int, int>, has_invalid: bool, physical_count: int}
     */
    public static function analyze_existing_event_meta($values): array
    {
        if (!is_array($values)) {
            $values = [$values];
        }

        $valid_ids = [];
        $has_invalid = false;
        $physical_count = 0;

        foreach ($values as $value) {
            $physical_count++;
            $id = self::positive_int_or_null(self::preserve_raw_meta_value($value));

            if ($id === null) {
                $has_invalid = true;

                continue;
            }

            $valid_ids[] = $id;
        }

        return [
            'valid_ids' => array_values(array_unique($valid_ids)),
            'has_invalid' => $has_invalid,
            'physical_count' => $physical_count,
        ];
    }

    /**
     * @return array<int, int>
     */
    public static function normalize_existing_event_ids($values): array
    {
        return self::analyze_existing_event_meta($values)['valid_ids'];
    }

    /**
     * Catalogue semantic: at least one physical `_tc_is_ticket` row equals exact `yes`.
     *
     * @param array<int, mixed> $ticket_flag_values
     */
    public static function is_ticket_product(array $ticket_flag_values): bool
    {
        foreach ($ticket_flag_values as $value) {
            $raw = self::preserve_raw_meta_value($value);
            if ($raw === 'yes') {
                return true;
            }
        }

        return false;
    }

    public static function variation_line_integrity(int $product_id, int $variation_id, callable $post_loader): bool
    {
        if ($variation_id <= 0) {
            return true;
        }

        if ($product_id <= 0) {
            return false;
        }

        $variation_post = $post_loader($variation_id);
        if ($variation_post === null) {
            return false;
        }

        if ((string) ($variation_post->post_type ?? '') !== self::POST_TYPE_VARIATION) {
            return false;
        }

        return (int) ($variation_post->post_parent ?? 0) === $product_id;
    }

    public static function authority_product_id(int $product_id, int $variation_id, callable $post_loader): ?int
    {
        if ($variation_id > 0) {
            if (!self::variation_line_integrity($product_id, $variation_id, $post_loader)) {
                return null;
            }

            $variation_post = $post_loader($variation_id);

            return $variation_post === null ? null : (int) ($variation_post->post_parent ?? 0);
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
