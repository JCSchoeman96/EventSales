<?php

declare(strict_types=1);

/**
 * Source-consistent catch-up adapter over an immutable E1 parent manifest.
 *
 * It reuses the existing source adapter for connection, authority, snapshot,
 * and lifecycle checks while keeping catch-up membership and continuation
 * independent from the ordinary membership predicate.
 */
final class EventSales_Woo_Order_Catchup_Source
{
    public const MAX_CHUNK_SIZE = 100;

    private object $wordpress_db;
    private object $source_db;

    /** @var callable(): bool */
    private $mode_detector;

    private bool $collect_query_metrics;

    private bool $snapshot_open = false;
    private bool $terminal_seen = false;
    private int $confirmed_sequence = 0;
    private int $parent_manifest_id = 0;
    private int $parent_item_count = 0;

    /** @var array<string, mixed>|null */
    private ?array $pending_candidate = null;

    /** @var array<string, mixed>|null */
    private ?array $configuration = null;

    /** @var array<string, mixed> */
    private array $metrics = [];

    public function __construct(
        object $wordpress_db,
        object $source_db,
        ?callable $mode_detector = null,
        bool $collect_query_metrics = false
    ) {
        $this->wordpress_db = $wordpress_db;
        $this->source_db = $source_db;
        $this->collect_query_metrics = $collect_query_metrics;
        $this->mode_detector = $mode_detector ?? static function (): bool {
            $class = 'Automattic\\WooCommerce\\Utilities\\OrderUtil';
            $method = [$class, 'custom_orders_table_usage_is_enabled'];
            if (!is_callable($method)) {
                throw new RuntimeException('WooCommerce storage capability is unavailable');
            }

            return (bool) call_user_func($method);
        };
    }

    /** @return array<string, mixed> */
    public function preflight(): array
    {
        $ordinary = new EventSales_Woo_Order_Membership_Source(
            $this->wordpress_db,
            $this->source_db,
            $this->mode_detector
        );
        $result = $ordinary->preflight();
        if (!($result['ok'] ?? false)) {
            return $result;
        }

        $this->configuration = $result;

        return $result;
    }

    /**
     * Open H using the same source transaction and observation-boundary
     * semantics as E2B.
     *
     * @param array<string, mixed> $preflight
     * @return array<string, mixed>
     */
    public function open_snapshot(array $preflight, int $parent_manifest_id, int $parent_item_count): array
    {
        if ($parent_manifest_id < 1 || $parent_item_count < 0) {
            return ['ok' => false, 'error' => 'invalid_parent_manifest'];
        }

        $ordinary = new EventSales_Woo_Order_Membership_Source(
            $this->wordpress_db,
            $this->source_db,
            $this->mode_detector
        );
        $opened = $ordinary->open_snapshot($preflight);
        if (!($opened['ok'] ?? false)) {
            return $opened;
        }

        // Keep the proven E2B adapter alive only for the source transaction;
        // its public methods are not used for catch-up enumeration. The
        // dedicated adapter owns the same connection and transaction state.
        $this->source_adapter = $ordinary;
        $this->snapshot_open = true;
        $this->parent_manifest_id = $parent_manifest_id;
        $this->parent_item_count = $parent_item_count;
        $this->confirmed_sequence = 0;
        $this->pending_candidate = null;
        $this->terminal_seen = false;
        $this->metrics = [
            'mode' => $opened['mode'] ?? null,
            'table' => $opened['table'] ?? null,
            'parent_plan' => [],
            'source_plan' => [],
            'parent_rows_examined' => 0,
            'source_rows_examined' => 0,
            'chunks' => 0,
            'matching_rows' => 0,
            'snapshot_duration_ms' => 0.0,
        ];

        return $opened;
    }

    /** @var EventSales_Woo_Order_Membership_Source|null */
    private ?EventSales_Woo_Order_Membership_Source $source_adapter = null;

    /** @return array<string, mixed> */
    public function read_next_candidate(int $parent_manifest_id, int $limit = self::MAX_CHUNK_SIZE): array
    {
        if (!$this->snapshot_open || $this->source_adapter === null) {
            return ['ok' => false, 'error' => 'snapshot_not_open'];
        }
        if ($parent_manifest_id !== $this->parent_manifest_id) {
            return ['ok' => false, 'error' => 'parent_manifest_changed'];
        }
        if ($limit < 1 || $limit > self::MAX_CHUNK_SIZE) {
            return ['ok' => false, 'error' => 'invalid_chunk'];
        }
        if ($this->pending_candidate !== null) {
            if ((int) ($this->pending_candidate['candidate_limit'] ?? 0) !== $limit) {
                return ['ok' => false, 'error' => 'candidate_context_changed'];
            }

            return $this->pending_candidate;
        }
        if ($this->terminal_seen) {
            return ['ok' => false, 'error' => 'source_terminal_already_confirmed'];
        }

        if ($this->confirmed_sequence >= $this->parent_item_count) {
            $candidate = $this->candidate([], 0, $this->confirmed_sequence, $this->confirmed_sequence, $limit, true);
            $this->pending_candidate = $candidate;

            return $candidate;
        }

        $item_table = $this->item_table();
        $item_identifier = self::identifier($item_table);
        $query = 'SELECT sequence, source_order_id, source_created_at_gmt, source_modified_at_gmt '
            . 'FROM ' . $item_identifier . ' WHERE manifest_id = %d AND sequence > %d '
            . 'ORDER BY sequence ASC LIMIT %d';
        $prepared = $this->source_db->prepare(
            $query,
            $this->parent_manifest_id,
            $this->confirmed_sequence,
            $limit
        );
        if ($this->collect_query_metrics && $this->metrics['parent_plan'] === []) {
            $plan = $this->explain($prepared);
            if ($plan === null) {
                return ['ok' => false, 'error' => 'query_plan_unavailable'];
            }
            $this->metrics['parent_plan'] = $plan;
        }
        $parent_rows_examined_before = $this->collect_query_metrics ? $this->rows_examined() : null;
        $parent_analyzed_rows = null;
        if ($this->collect_query_metrics && $parent_rows_examined_before === null) {
            $parent_analyzed_rows = $this->explain_analyzed_rows($prepared);
            if ($parent_analyzed_rows === null) {
                return ['ok' => false, 'error' => 'rows_examined_unavailable'];
            }
        }
        $rows = $this->source_db->get_results($prepared, ARRAY_A);
        $parent_rows_examined_after = $parent_rows_examined_before === null ? null : $this->rows_examined();
        if ($this->collect_query_metrics && $parent_rows_examined_before !== null && $parent_rows_examined_after === null) {
            return ['ok' => false, 'error' => 'rows_examined_unavailable'];
        }
        if (!is_array($rows)) {
            return ['ok' => false, 'error' => 'parent_manifest_storage_failed'];
        }
        if ($this->collect_query_metrics) {
            $this->metrics['parent_rows_examined'] += $parent_analyzed_rows !== null
                ? $parent_analyzed_rows
                : max(0, $parent_rows_examined_after - $parent_rows_examined_before);
        }

        $normalized = [];
        foreach ($rows as $row) {
            if (!is_array($row) || !isset($row['sequence'])) {
                return ['ok' => false, 'error' => 'parent_manifest_storage_failed'];
            }
            $sequence = (int) $row['sequence'];
            if ($sequence !== ($this->confirmed_sequence + count($normalized) + 1)) {
                return ['ok' => false, 'error' => 'parent_manifest_sequence_invalid'];
            }
            $created = self::db_datetime_to_wire((string) ($row['source_created_at_gmt'] ?? ''));
            $modified = self::db_datetime_to_wire((string) ($row['source_modified_at_gmt'] ?? ''));
            if ($created === null || $modified === null || (string) ($row['source_order_id'] ?? '') === '') {
                return ['ok' => false, 'error' => 'parent_manifest_storage_failed'];
            }
            $normalized[] = [
                'sequence' => $sequence,
                'source_order_id' => (string) $row['source_order_id'],
                'source_created_at_gmt' => $created,
                'source_modified_at_gmt' => $modified,
            ];
        }
        if ($normalized === []) {
            return ['ok' => false, 'error' => 'parent_manifest_missing_items'];
        }

        $source_rows = $this->read_authoritative_rows($normalized);
        if (!($source_rows['ok'] ?? false)) {
            return $source_rows;
        }

        $changed = [];
        foreach ($normalized as $parent) {
            $id = $parent['source_order_id'];
            $current = $source_rows['rows'][$id] ?? null;
            if (!is_array($current)) {
                return ['ok' => false, 'error' => 'catchup_member_unresolved'];
            }
            if (
                $current['source_created_at_gmt'] !== $parent['source_created_at_gmt']
                || $current['source_modified_at_gmt'] !== $parent['source_modified_at_gmt']
            ) {
                $changed[] = [
                    'source_order_id' => $id,
                    'source_created_at_gmt' => $current['source_created_at_gmt'],
                    'source_modified_at_gmt' => $current['source_modified_at_gmt'],
                ];
            }
        }

        $end_sequence = (int) $normalized[count($normalized) - 1]['sequence'];
        $candidate = $this->candidate($changed, count($normalized), $this->confirmed_sequence, $end_sequence, $limit, false);
        $this->pending_candidate = $candidate;

        return $candidate;
    }

    /** @param array<int, array<string, mixed>> $rows */
    private function candidate(array $rows, int $parent_count, int $start, int $end, int $limit, bool $terminal): array
    {
        return [
            'ok' => true,
            'parent_manifest_id' => $this->parent_manifest_id,
            'candidate_start_sequence' => $start,
            'candidate_end_sequence' => $end,
            'candidate_limit' => $limit,
            'parent_count' => $parent_count,
            'terminal' => $terminal,
            'rows' => $rows,
            'candidate_digest' => hash('sha256', json_encode([
                'parent_manifest_id' => $this->parent_manifest_id,
                'candidate_start_sequence' => $start,
                'candidate_end_sequence' => $end,
                'candidate_limit' => $limit,
                'parent_count' => $parent_count,
                'terminal' => $terminal,
                'rows' => $rows,
            ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)),
        ];
    }

    /** @param array<int, array<string, mixed>> $parent_rows */
    private function read_authoritative_rows(array $parent_rows): array
    {
        $configuration = $this->configuration;
        if (!is_array($configuration)) {
            return ['ok' => false, 'error' => 'source_preflight_failed'];
        }
        $ids = array_map(static fn(array $row): string => $row['source_order_id'], $parent_rows);
        $placeholders = implode(',', array_fill(0, count($ids), '%s'));
        $query = 'SELECT ' . self::identifier($configuration['id_field']) . ' AS source_order_id, '
            . self::identifier($configuration['type_field']) . ' AS source_type, '
            . self::identifier($configuration['created_field']) . ' AS source_created_at_gmt, '
            . self::identifier($configuration['modified_field']) . ' AS source_modified_at_gmt '
            . 'FROM ' . self::identifier($configuration['table']) . ' WHERE '
            . self::identifier($configuration['id_field']) . ' IN (' . $placeholders . ')';
        $prepared = $this->source_db->prepare($query, ...$ids);
        if ($this->collect_query_metrics && $this->metrics['source_plan'] === []) {
            $plan = $this->explain($prepared);
            if ($plan === null) {
                return ['ok' => false, 'error' => 'query_plan_unavailable'];
            }
            $this->metrics['source_plan'] = $plan;
        }
        $source_rows_examined_before = $this->collect_query_metrics ? $this->rows_examined() : null;
        $source_analyzed_rows = null;
        if ($this->collect_query_metrics && $source_rows_examined_before === null) {
            $source_analyzed_rows = $this->explain_analyzed_rows($prepared);
            if ($source_analyzed_rows === null) {
                return ['ok' => false, 'error' => 'rows_examined_unavailable'];
            }
        }
        $rows = $this->source_db->get_results($prepared, ARRAY_A);
        $source_rows_examined_after = $source_rows_examined_before === null ? null : $this->rows_examined();
        if ($this->collect_query_metrics && $source_rows_examined_before !== null && $source_rows_examined_after === null) {
            return ['ok' => false, 'error' => 'rows_examined_unavailable'];
        }
        if (!is_array($rows)) {
            return ['ok' => false, 'error' => 'source_chunk_query_failed'];
        }
        if ($this->collect_query_metrics) {
            $this->metrics['source_rows_examined'] += $source_analyzed_rows !== null
                ? $source_analyzed_rows
                : max(0, $source_rows_examined_after - $source_rows_examined_before);
        }

        $mapped = [];
        foreach ($rows as $row) {
            if (!is_array($row) || (string) ($row['source_type'] ?? '') !== 'shop_order') {
                continue;
            }
            $created = self::db_datetime_to_wire((string) ($row['source_created_at_gmt'] ?? ''));
            $modified = self::db_datetime_to_wire((string) ($row['source_modified_at_gmt'] ?? ''));
            if ($created === null || $modified === null) {
                return ['ok' => false, 'error' => 'catchup_member_unresolved'];
            }
            $mapped[(string) $row['source_order_id']] = [
                'source_order_id' => (string) $row['source_order_id'],
                'source_created_at_gmt' => $created,
                'source_modified_at_gmt' => $modified,
            ];
        }

        return ['ok' => true, 'rows' => $mapped];
    }

    /** @param array<string, mixed> $candidate */
    public function confirm_persisted(array $candidate): array
    {
        if (!$this->snapshot_open || $this->pending_candidate === null) {
            return ['ok' => false, 'error' => 'no_pending_candidate'];
        }
        $expected = $this->pending_candidate;
        if (
            ($candidate['parent_manifest_id'] ?? null) !== $expected['parent_manifest_id']
            || ($candidate['candidate_start_sequence'] ?? null) !== $expected['candidate_start_sequence']
            || ($candidate['candidate_end_sequence'] ?? null) !== $expected['candidate_end_sequence']
            || ($candidate['candidate_limit'] ?? null) !== $expected['candidate_limit']
            || ($candidate['parent_count'] ?? null) !== $expected['parent_count']
            || ($candidate['terminal'] ?? null) !== $expected['terminal']
            || ($candidate['rows'] ?? null) !== $expected['rows']
            || !is_string($candidate['candidate_digest'] ?? null)
            || !hash_equals($expected['candidate_digest'], $candidate['candidate_digest'])
        ) {
            return ['ok' => false, 'error' => 'candidate_mismatch'];
        }
        if ($expected['terminal'] === true) {
            if ($expected['candidate_start_sequence'] !== $this->parent_item_count) {
                return ['ok' => false, 'error' => 'candidate_mismatch'];
            }
            $this->terminal_seen = true;
            $this->pending_candidate = null;

            return ['ok' => true, 'terminal' => true, 'confirmed_sequence' => $this->confirmed_sequence];
        }
        if ($expected['candidate_end_sequence'] <= $this->confirmed_sequence || $expected['candidate_end_sequence'] > $this->parent_item_count) {
            return ['ok' => false, 'error' => 'candidate_not_forward'];
        }
        $this->confirmed_sequence = (int) $expected['candidate_end_sequence'];
        $this->metrics['chunks']++;
        $this->metrics['matching_rows'] += count($expected['rows']);
        $this->pending_candidate = null;

        return ['ok' => true, 'terminal' => false, 'confirmed_sequence' => $this->confirmed_sequence];
    }

    /** @return array<string, mixed> */
    public function commit_snapshot(): array
    {
        if (!$this->snapshot_open || $this->source_adapter === null) {
            return ['ok' => false, 'error' => 'snapshot_not_open'];
        }
        if ($this->pending_candidate !== null) {
            $this->rollback_snapshot();

            return ['ok' => false, 'error' => 'source_candidate_unconfirmed'];
        }
        if (!$this->terminal_seen || $this->confirmed_sequence !== $this->parent_item_count) {
            $this->rollback_snapshot();

            return ['ok' => false, 'error' => 'source_not_exhausted'];
        }

        $external_terminal = $this->source_adapter->confirm_external_terminal();
        if (!($external_terminal['ok'] ?? false)) {
            $this->rollback_snapshot();

            return ['ok' => false, 'error' => 'source_not_exhausted'];
        }

        $result = $this->source_adapter->commit_snapshot();
        if (!($result['ok'] ?? false)) {
            $this->snapshot_open = false;

            return $result;
        }
        $this->snapshot_open = false;
        $this->metrics['snapshot_duration_ms'] = $result['metrics']['snapshot_duration_ms'] ?? 0.0;
        $result['metrics'] = array_merge($result['metrics'] ?? [], $this->metrics);

        return $result;
    }

    /** @return array<string, mixed> */
    public function rollback_snapshot(): array
    {
        if (!$this->snapshot_open || $this->source_adapter === null) {
            return ['ok' => true];
        }
        $result = $this->source_adapter->rollback_snapshot();
        $this->snapshot_open = false;
        $this->pending_candidate = null;

        return $result;
    }

    /** @return array<string, mixed> */
    public function metrics(): array
    {
        return $this->metrics;
    }

    private static function identifier(string $identifier): string
    {
        if (!preg_match('/^[A-Za-z0-9_]+$/D', $identifier)) {
            throw new RuntimeException('unsafe_source_identifier');
        }

        return '`' . $identifier . '`';
    }

    private function item_table(): string
    {
        $prefix = (string) ($this->source_db->prefix ?? '');
        if ($prefix === '' || !preg_match('/^[A-Za-z0-9_]+$/D', $prefix)) {
            throw new RuntimeException('invalid WordPress table prefix');
        }

        return $prefix . 'eventsales_order_manifest_items';
    }

    /** @return array<int, array<string, mixed>>|null */
    private function explain(string $query): ?array
    {
        $rows = $this->source_db->get_results('EXPLAIN ' . $query, ARRAY_A);
        if (!is_array($rows)) {
            return null;
        }

        $plan = [];
        foreach ($rows as $row) {
            if (!is_array($row)) {
                return null;
            }
            $plan[] = [
                'select_type' => (string) ($row['select_type'] ?? ''),
                'table' => (string) ($row['table'] ?? ''),
                'type' => (string) ($row['type'] ?? ''),
                'possible_keys' => (string) ($row['possible_keys'] ?? ''),
                'key' => (string) ($row['key'] ?? ''),
                'rows' => (int) ($row['rows'] ?? 0),
                'extra' => (string) ($row['Extra'] ?? ''),
            ];
        }

        return $plan;
    }

    private function rows_examined(): ?int
    {
        $row = $this->source_db->get_row("SHOW SESSION STATUS LIKE 'Rows_examined'", ARRAY_A);
        if (!is_array($row) || !isset($row['Value']) || !is_numeric($row['Value'])) {
            return null;
        }

        return (int) $row['Value'];
    }

    private function explain_analyzed_rows(string $query): ?int
    {
        $rows = $this->source_db->get_results('EXPLAIN ANALYZE ' . $query, ARRAY_A);
        if (!is_array($rows)) {
            return null;
        }

        $largest = null;
        foreach ($rows as $row) {
            if (!is_array($row)) {
                continue;
            }
            $line = (string) ($row['EXPLAIN'] ?? '');
            if (preg_match_all('/actual time=[^)]* rows=(\d+) loops=(\d+)/', $line, $matches, PREG_SET_ORDER)) {
                foreach ($matches as $match) {
                    $observed = (int) $match[1] * (int) $match[2];
                    $largest = $largest === null ? $observed : max($largest, $observed);
                }
            }
        }

        return $largest;
    }

    private static function db_datetime_to_wire(string $value): ?string
    {
        $date = DateTimeImmutable::createFromFormat('!Y-m-d H:i:s.u', $value, new DateTimeZone('UTC'));
        $errors = DateTimeImmutable::getLastErrors();
        if ($date === false || ($errors !== false && ($errors['warning_count'] > 0 || $errors['error_count'] > 0))) {
            $date = DateTimeImmutable::createFromFormat('!Y-m-d H:i:s', $value, new DateTimeZone('UTC'));
            $errors = DateTimeImmutable::getLastErrors();
            if ($date === false || ($errors !== false && ($errors['warning_count'] > 0 || $errors['error_count'] > 0))) {
                return null;
            }
        }

        return $date->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d\\TH:i:s.u\\Z');
    }
}
