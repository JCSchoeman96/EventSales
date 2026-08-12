<?php

declare(strict_types=1);

/**
 * Non-public, identity-only WooCommerce source membership proof adapter.
 *
 * This class is intentionally not required by the public feed plugin. E2B may
 * compose it with the E1 manifest store after this proof is accepted.
 */
final class EventSales_Woo_Order_Membership_Source
{
    public const MODE_HPOS = 'hpos';
    public const MODE_LEGACY = 'legacy';
    public const HPOS_USAGE_OPTION = 'woocommerce_custom_orders_table_enabled';
    public const MAX_CHUNK_SIZE = 100;

    private object $wordpress_db;
    private object $source_db;

    /** @var callable(): bool */
    private $mode_detector;

    private bool $collect_query_metrics;

    /** @var array<string, mixed>|null */
    private ?array $configuration = null;

    private bool $snapshot_open = false;
    private bool $terminal_seen = false;
    private ?string $last_emitted_id = null;
    private float $snapshot_started_at = 0.0;

    /** @var array<string, mixed> */
    private array $metrics = [];

    /**
     * @param object $wordpress_db Authoritative WordPress wpdb connection used by E1.
     * @param object $source_db Dedicated source-read wpdb connection.
     * @param callable(): bool|null $mode_detector Woo-supported HPOS capability.
     * @param bool $collect_query_metrics Enable bounded EXPLAIN metrics for the proof harness.
     */
    public function __construct(object $wordpress_db, object $source_db, ?callable $mode_detector = null, bool $collect_query_metrics = false)
    {
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

    /**
     * Verify the Woo-selected mode and all source connection/schema
     * prerequisites without opening the membership snapshot.
     *
     * @return array<string, mixed>
     */
    public function preflight(): array
    {
        try {
            $mode = call_user_func($this->mode_detector) ? self::MODE_HPOS : self::MODE_LEGACY;
            $configuration = $this->configuration_for_mode($mode);
            $this->assert_same_authoritative_primary();
            $this->set_effective_repeatable_read();
            $configuration['source_definition'] = $this->assert_table_definition($configuration['table'], $configuration['fields'], $configuration['id_field']);
            $configuration['options_definition'] = $this->assert_table_definition($configuration['options_table'], ['option_name', 'option_value'], null);

            $this->configuration = $configuration;

            return [
                'ok' => true,
                'mode' => $mode,
                'table' => $configuration['table'],
                'id_field' => $configuration['id_field'],
                'created_field' => $configuration['created_field'],
                'modified_field' => $configuration['modified_field'],
                'type_field' => $configuration['type_field'],
                'options_table' => $configuration['options_table'],
                'source_definition' => $configuration['source_definition'],
                'options_definition' => $configuration['options_definition'],
            ];
        } catch (Throwable $error) {
            return ['ok' => false, 'error' => $this->error_code($error)];
        }
    }

    /**
     * Establish D and bind the preflight mode to the same InnoDB read view.
     *
     * @param array<string, mixed> $preflight
     * @return array<string, mixed>
     */
    public function open_snapshot(array $preflight): array
    {
        if ($this->snapshot_open) {
            return ['ok' => false, 'error' => 'snapshot_already_open'];
        }

        if (($preflight['ok'] ?? false) !== true || !in_array($preflight['mode'] ?? null, [self::MODE_HPOS, self::MODE_LEGACY], true)) {
            return ['ok' => false, 'error' => 'invalid_preflight'];
        }

        try {
            $configuration = $this->configuration_for_mode((string) $preflight['mode']);
            if (
                $configuration['table'] !== ($preflight['table'] ?? null)
                || $configuration['id_field'] !== ($preflight['id_field'] ?? null)
                || $configuration['created_field'] !== ($preflight['created_field'] ?? null)
                || $configuration['modified_field'] !== ($preflight['modified_field'] ?? null)
            ) {
                return ['ok' => false, 'error' => 'preflight_source_changed'];
            }

            $this->assert_same_authoritative_primary();
            $this->set_effective_repeatable_read();
            $source_definition = $this->assert_table_definition($configuration['table'], $configuration['fields'], $configuration['id_field']);
            $options_definition = $this->assert_table_definition($configuration['options_table'], ['option_name', 'option_value'], null);
            if (
                !is_string($preflight['source_definition'] ?? null)
                || !is_string($preflight['options_definition'] ?? null)
                || $source_definition !== $preflight['source_definition']
                || $options_definition !== $preflight['options_definition']
            ) {
                return ['ok' => false, 'error' => 'source_definition_changed_before_boundary'];
            }
            $configuration['source_definition'] = $source_definition;
            $configuration['options_definition'] = $options_definition;

            if ($this->source_db->query('START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY') === false) {
                throw new RuntimeException('snapshot_start_failed');
            }
            $this->snapshot_open = true;
            $this->snapshot_started_at = microtime(true);

            // This is the source-authoritative mode binding read. It is the
            // first data read after START and therefore comes from D.
            $markers = $this->source_db->get_col($this->source_db->prepare(
                'SELECT option_value FROM ' . self::identifier($configuration['options_table'])
                . ' WHERE option_name = %s',
                self::HPOS_USAGE_OPTION
            ));
            $marker = is_array($markers) && count($markers) === 1 ? trim((string) $markers[0]) : '';
            $expected_marker = $preflight['mode'] === self::MODE_HPOS ? 'yes' : 'no';
            if (!in_array($marker, ['yes', 'no'], true) || $marker !== $expected_marker) {
                return $this->fail_snapshot('storage_authority_changed_at_boundary');
            }

            $observed_at = $this->source_db->get_var('SELECT UTC_TIMESTAMP(6)');
            if (!is_string($observed_at) || self::db_datetime_to_wire($observed_at) === null) {
                return $this->fail_snapshot('source_clock_unavailable');
            }

            // A definition change that occurred between preflight and D is
            // rejected before any membership row is read. A change during the
            // snapshot is rejected by the read itself or by the final check.
            if (
                $this->assert_table_definition($configuration['table'], $configuration['fields'], $configuration['id_field']) !== $configuration['source_definition']
                || $this->assert_table_definition($configuration['options_table'], ['option_name', 'option_value'], null) !== $configuration['options_definition']
            ) {
                return $this->fail_snapshot('source_definition_changed_at_boundary');
            }

            $this->configuration = $configuration;
            $this->terminal_seen = false;
            $this->last_emitted_id = null;
            $this->metrics = [
                'mode' => $preflight['mode'],
                'table' => $configuration['table'],
                'plan' => [],
                'chunks' => 0,
                'matching_rows' => 0,
                'rows_examined' => 0,
                'largest_id_gap' => 0,
                'snapshot_duration_ms' => 0.0,
            ];

            return [
                'ok' => true,
                'mode' => $preflight['mode'],
                'table' => $configuration['table'],
                'source_observed_at_gmt' => self::db_datetime_to_wire($observed_at),
            ];
        } catch (Throwable $error) {
            if ($this->snapshot_open) {
                $this->rollback_snapshot();
            }

            return ['ok' => false, 'error' => $this->error_code($error)];
        }
    }

    /**
     * Read one bounded identity-only keyset chunk from D.
     *
     * @return array<string, mixed>
     */
    public function read_chunk(string $backfill_start_gmt, string $backfill_cutoff_gmt, string $last_id = '0', int $limit = self::MAX_CHUNK_SIZE): array
    {
        if (!$this->snapshot_open || $this->configuration === null) {
            return ['ok' => false, 'error' => 'snapshot_not_open'];
        }
        if ($limit < 1 || $limit > self::MAX_CHUNK_SIZE || !preg_match('/^(?:0|[1-9][0-9]*)$/D', $last_id)) {
            return ['ok' => false, 'error' => 'invalid_chunk'];
        }

        $start = self::wire_datetime_to_db($backfill_start_gmt);
        $cutoff = self::wire_datetime_to_db($backfill_cutoff_gmt);
        if ($start === null || $cutoff === null || strcmp($start, $cutoff) > 0) {
            return ['ok' => false, 'error' => 'invalid_bounds'];
        }

        $configuration = $this->configuration;
        $query = 'SELECT ' . self::identifier($configuration['id_field']) . ' AS source_order_id, '
            . self::identifier($configuration['created_field']) . ' AS source_created_at_gmt, '
            . self::identifier($configuration['modified_field']) . ' AS source_modified_at_gmt '
            . 'FROM ' . self::identifier($configuration['table']) . ' WHERE '
            . self::identifier($configuration['id_field']) . ' > %s AND '
            . self::identifier($configuration['type_field']) . ' = %s AND '
            . self::identifier($configuration['created_field']) . ' >= %s AND '
            . self::identifier($configuration['created_field']) . ' <= %s '
            . 'ORDER BY ' . self::identifier($configuration['id_field']) . ' ASC LIMIT %d';
        $prepared = $this->source_db->prepare($query, $last_id, 'shop_order', $start, $cutoff, $limit);

        try {
            if ($this->collect_query_metrics && $this->metrics['plan'] === []) {
                $plan = $this->explain($prepared);
                if ($plan === null) {
                    return ['ok' => false, 'error' => 'query_plan_unavailable'];
                }
                $this->metrics['plan'] = $plan;
            }

            $before_rows_examined = $this->collect_query_metrics ? $this->rows_examined() : null;
            $analyzed_rows = null;
            if ($this->collect_query_metrics && $before_rows_examined === null) {
                // MySQL 8.4 no longer exposes Rows_examined as a session
                // status variable. EXPLAIN ANALYZE is the bounded, source-
                // snapshot-compatible fallback for the proof metric.
                $analyzed_rows = $this->explain_analyzed_rows($prepared);
                if ($analyzed_rows === null) {
                    return ['ok' => false, 'error' => 'rows_examined_unavailable'];
                }
            }
            $rows = $this->source_db->get_results($prepared, 'ARRAY_A');
            $after_rows_examined = $before_rows_examined === null ? null : $this->rows_examined();
            if ($this->collect_query_metrics && $before_rows_examined !== null && $after_rows_examined === null) {
                return ['ok' => false, 'error' => 'rows_examined_unavailable'];
            }
            if (!is_array($rows)) {
                throw new RuntimeException('source_chunk_query_failed');
            }

            $normalized = [];
            foreach ($rows as $row) {
                if (!is_array($row)) {
                    throw new RuntimeException('source_chunk_row_invalid');
                }
                $normalized_row = $this->normalize_row($row);
                if ($normalized_row === null) {
                    throw new RuntimeException('source_chunk_row_invalid');
                }
                $normalized[] = $normalized_row;
            }

            if ($this->collect_query_metrics) {
                if ($analyzed_rows !== null) {
                    $this->metrics['rows_examined'] += $analyzed_rows;
                } else {
                    $this->metrics['rows_examined'] += max(0, $after_rows_examined - $before_rows_examined);
                }
            }
            if ($normalized === []) {
                $this->terminal_seen = true;

                return [
                    'ok' => true,
                    'rows' => [],
                    'next_id' => $last_id,
                    'terminal' => true,
                ];
            }

            $this->metrics['chunks']++;
            $this->metrics['matching_rows'] += count($normalized);
            foreach ($normalized as $row) {
                $id = $row['source_order_id'];
                if ($this->last_emitted_id !== null) {
                    $gap = self::decimal_gap($this->last_emitted_id, $id);
                    if ($gap !== null) {
                        $this->metrics['largest_id_gap'] = max((int) $this->metrics['largest_id_gap'], $gap);
                    }
                }
                $this->last_emitted_id = $id;
            }

            return [
                'ok' => true,
                'rows' => $normalized,
                'next_id' => $normalized[count($normalized) - 1]['source_order_id'],
                'terminal' => false,
            ];
        } catch (Throwable $error) {
            return ['ok' => false, 'error' => $this->error_code($error)];
        }
    }

    /**
     * Close D only after an empty terminal chunk has been observed.
     *
     * @return array<string, mixed>
     */
    public function commit_snapshot(): array
    {
        if (!$this->snapshot_open || $this->configuration === null) {
            return ['ok' => false, 'error' => 'snapshot_not_open'];
        }
        if (!$this->terminal_seen) {
            $this->rollback_snapshot();

            return ['ok' => false, 'error' => 'source_not_exhausted'];
        }

        try {
            if (
                $this->assert_table_definition($this->configuration['table'], $this->configuration['fields'], $this->configuration['id_field']) !== $this->configuration['source_definition']
                || $this->assert_table_definition($this->configuration['options_table'], ['option_name', 'option_value'], null) !== $this->configuration['options_definition']
            ) {
                throw new RuntimeException('source_definition_changed_during_capture');
            }
            if ($this->source_db->query('COMMIT') === false) {
                throw new RuntimeException('source_commit_failed');
            }
            $this->snapshot_open = false;
            $this->metrics['snapshot_duration_ms'] = round((microtime(true) - $this->snapshot_started_at) * 1000, 3);

            return ['ok' => true, 'metrics' => $this->metrics];
        } catch (Throwable $error) {
            $this->rollback_snapshot();

            return ['ok' => false, 'error' => $this->error_code($error)];
        }
    }

    /** @return array<string, mixed> */
    public function rollback_snapshot(): array
    {
        if (!$this->snapshot_open) {
            return ['ok' => true];
        }

        $result = $this->source_db->query('ROLLBACK');
        $this->snapshot_open = false;
        $this->metrics['snapshot_duration_ms'] = round((microtime(true) - $this->snapshot_started_at) * 1000, 3);

        return $result === false ? ['ok' => false, 'error' => 'source_rollback_failed'] : ['ok' => true];
    }

    /** @return array<string, mixed> */
    public function metrics(): array
    {
        return $this->metrics;
    }

    /** @return array<string, mixed> */
    private function configuration_for_mode(string $mode): array
    {
        $prefix = (string) ($this->wordpress_db->prefix ?? '');
        if ($prefix === '') {
            throw new RuntimeException('wordpress_prefix_unavailable');
        }

        if ($mode === self::MODE_HPOS) {
            $class = 'Automattic\\WooCommerce\\Internal\\DataStores\\Orders\\OrdersTableDataStore';
            $method = [$class, 'get_orders_table_name'];
            if (!is_callable($method)) {
                throw new RuntimeException('hpos_datastore_unavailable');
            }
            global $wpdb;
            if (!is_object($wpdb) || $wpdb !== $this->wordpress_db) {
                throw new RuntimeException('wordpress_global_connection_mismatch');
            }
            $table = (string) call_user_func($method);
            if ($table !== $prefix . 'wc_orders') {
                throw new RuntimeException('hpos_table_resolution_mismatch');
            }
            $options_table = (string) ($this->wordpress_db->options ?? $prefix . 'options');
            if ($options_table !== $prefix . 'options') {
                throw new RuntimeException('options_table_resolution_mismatch');
            }

            return [
                'mode' => self::MODE_HPOS,
                'table' => $table,
                'fields' => ['id', 'type', 'date_created_gmt', 'date_updated_gmt'],
                'id_field' => 'id',
                'type_field' => 'type',
                'created_field' => 'date_created_gmt',
                'modified_field' => 'date_updated_gmt',
                'options_table' => $options_table,
            ];
        }

        if ($mode === self::MODE_LEGACY) {
            $table = (string) ($this->wordpress_db->posts ?? $prefix . 'posts');
            if ($table !== $prefix . 'posts') {
                throw new RuntimeException('legacy_table_resolution_mismatch');
            }
            $options_table = (string) ($this->wordpress_db->options ?? $prefix . 'options');
            if ($options_table !== $prefix . 'options') {
                throw new RuntimeException('options_table_resolution_mismatch');
            }

            return [
                'mode' => self::MODE_LEGACY,
                'table' => $table,
                'fields' => ['ID', 'post_type', 'post_date_gmt', 'post_modified_gmt'],
                'id_field' => 'ID',
                'type_field' => 'post_type',
                'created_field' => 'post_date_gmt',
                'modified_field' => 'post_modified_gmt',
                'options_table' => $options_table,
            ];
        }

        throw new RuntimeException('unsupported_storage_mode');
    }

    private function assert_same_authoritative_primary(): void
    {
        $primary = $this->connection_identity($this->wordpress_db);
        $source = $this->connection_identity($this->source_db);
        if ($primary !== $source) {
            throw new RuntimeException('source_connection_identity_mismatch');
        }
        if ($source['global_read_only'] !== '0' || $source['transaction_read_only'] !== '0') {
            throw new RuntimeException('source_connection_is_not_writable_primary');
        }
    }

    /** @return array<string, string> */
    private function connection_identity(object $db): array
    {
        $row = $db->get_row(
            'SELECT DATABASE() AS database_name, @@hostname AS server_hostname, '
            . '@@port AS server_port, @@GLOBAL.read_only AS global_read_only, '
            . '@@SESSION.transaction_read_only AS transaction_read_only',
            'ARRAY_A'
        );
        if (!is_array($row) || $row === []) {
            throw new RuntimeException('source_connection_identity_unavailable');
        }

        $server_identity = $db->get_var('SELECT @@GLOBAL.server_uuid');
        if (!is_string($server_identity) || $server_identity === '') {
            $server_identity = $db->get_var('SELECT @@GLOBAL.server_id');
        }
        if (!is_string($server_identity) && !is_int($server_identity)) {
            throw new RuntimeException('source_server_identity_unavailable');
        }

        return [
            'database_name' => (string) ($row['database_name'] ?? ''),
            'server_hostname' => (string) ($row['server_hostname'] ?? ''),
            'server_port' => (string) ($row['server_port'] ?? ''),
            'server_identity' => (string) $server_identity,
            'global_read_only' => (string) ($row['global_read_only'] ?? ''),
            'transaction_read_only' => (string) ($row['transaction_read_only'] ?? ''),
        ];
    }

    private function set_effective_repeatable_read(): void
    {
        if ($this->source_db->query('SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ') === false) {
            throw new RuntimeException('isolation_setup_failed');
        }
        if ($this->read_isolation() !== 'REPEATABLE-READ') {
            throw new RuntimeException('effective_isolation_is_not_repeatable_read');
        }
    }

    private function read_isolation(): string
    {
        $value = $this->source_db->get_var('SELECT @@SESSION.transaction_isolation');
        if (!is_string($value) || $value === '') {
            $value = $this->source_db->get_var('SELECT @@SESSION.tx_isolation');
        }

        return strtoupper(str_replace('_', '-', (string) $value));
    }

    /**
     * @param array<int, string> $required_fields
     */
    private function assert_table_definition(string $table, array $required_fields, ?string $primary_field): string
    {
        $quoted = self::identifier($table);
        $status = $this->source_db->get_row($this->source_db->prepare(
            'SELECT ENGINE AS Engine FROM information_schema.tables WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s',
            $table
        ), 'ARRAY_A');
        if (!is_array($status) || strcasecmp((string) ($status['Engine'] ?? ''), 'InnoDB') !== 0) {
            throw new RuntimeException('source_table_is_not_innodb');
        }

        $columns = $this->source_db->get_results('SHOW COLUMNS FROM ' . $quoted, 'ARRAY_A');
        if (!is_array($columns)) {
            throw new RuntimeException('source_columns_unavailable');
        }
        $column_map = [];
        foreach ($columns as $column) {
            if (is_array($column) && isset($column['Field'])) {
                $column_map[(string) $column['Field']] = $column;
            }
        }
        foreach ($required_fields as $field) {
            if (!isset($column_map[$field])) {
                throw new RuntimeException('source_required_column_missing');
            }
        }

        $indexes = $this->source_db->get_results('SHOW INDEX FROM ' . $quoted, 'ARRAY_A');
        if (!is_array($indexes)) {
            throw new RuntimeException('source_indexes_unavailable');
        }
        $has_primary_identity = false;
        foreach ($indexes as $index) {
            if (
                is_array($index)
                && (string) ($index['Key_name'] ?? '') === 'PRIMARY'
                && (int) ($index['Seq_in_index'] ?? 0) === 1
                && (string) ($index['Column_name'] ?? '') === $primary_field
                && (int) ($index['Non_unique'] ?? 1) === 0
            ) {
                $has_primary_identity = true;
                break;
            }
        }
        if ($primary_field !== null && !$has_primary_identity) {
            throw new RuntimeException('source_identity_primary_key_missing');
        }

        $signature_columns = [];
        foreach ($column_map as $field => $column) {
            $signature_columns[$field] = [
                'type' => (string) ($column['Type'] ?? ''),
                'null' => (string) ($column['Null'] ?? ''),
                'default' => (string) ($column['Default'] ?? ''),
                'extra' => (string) ($column['Extra'] ?? ''),
            ];
        }
        ksort($signature_columns, SORT_STRING);
        $signature_indexes = [];
        foreach ($indexes as $index) {
            if (!is_array($index)) {
                continue;
            }
            $signature_indexes[] = [
                'key' => (string) ($index['Key_name'] ?? ''),
                'sequence' => (int) ($index['Seq_in_index'] ?? 0),
                'column' => (string) ($index['Column_name'] ?? ''),
                'non_unique' => (int) ($index['Non_unique'] ?? 0),
            ];
        }
        usort($signature_indexes, static function (array $left, array $right): int {
            return strcmp(json_encode($left) ?: '', json_encode($right) ?: '');
        });

        return hash('sha256', json_encode([
            'engine' => (string) ($status['Engine'] ?? ''),
            'columns' => $signature_columns,
            'indexes' => $signature_indexes,
        ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
    }

    /** @return array<int, array<string, mixed>>|null */
    private function explain(string $query): ?array
    {
        $rows = $this->source_db->get_results('EXPLAIN ' . $query, 'ARRAY_A');
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
        $row = $this->source_db->get_row("SHOW SESSION STATUS LIKE 'Rows_examined'", 'ARRAY_A');
        if (!is_array($row) || !isset($row['Value']) || !is_numeric($row['Value'])) {
            return null;
        }

        return (int) $row['Value'];
    }

    private function explain_analyzed_rows(string $query): ?int
    {
        $rows = $this->source_db->get_results('EXPLAIN ANALYZE ' . $query, 'ARRAY_A');
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

    /** @param array<string, mixed> $row */
    private function normalize_row(array $row): ?array
    {
        $id = (string) ($row['source_order_id'] ?? '');
        if (!preg_match('/^[1-9][0-9]*$/D', $id)) {
            return null;
        }
        $created = self::db_datetime_to_wire((string) ($row['source_created_at_gmt'] ?? ''));
        $modified = self::db_datetime_to_wire((string) ($row['source_modified_at_gmt'] ?? ''));
        if ($created === null || $modified === null) {
            return null;
        }

        return [
            'source_order_id' => $id,
            'source_created_at_gmt' => $created,
            'source_modified_at_gmt' => $modified,
        ];
    }

    private function fail_snapshot(string $error): array
    {
        $this->rollback_snapshot();

        return ['ok' => false, 'error' => $error];
    }

    private function error_code(Throwable $error): string
    {
        $message = $error->getMessage();
        if (preg_match('/^[a-z0-9_]+$/D', $message)) {
            return $message;
        }

        return 'source_capture_failed';
    }

    private static function identifier(string $identifier): string
    {
        if (!preg_match('/^[A-Za-z0-9_]+$/D', $identifier)) {
            throw new RuntimeException('unsafe_source_identifier');
        }

        return '`' . $identifier . '`';
    }

    private static function wire_datetime_to_db(string $value): ?string
    {
        if (!preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/D', $value)) {
            return null;
        }
        $fraction = strpos($value, '.') === false ? '000000' : str_pad(substr($value, 20, -1), 6, '0');
        $date = DateTimeImmutable::createFromFormat('!Y-m-d\\TH:i:s.u\\Z', substr($value, 0, 19) . '.' . $fraction . 'Z', new DateTimeZone('UTC'));
        $errors = DateTimeImmutable::getLastErrors();
        if ($date === false || ($errors !== false && ($errors['warning_count'] > 0 || $errors['error_count'] > 0))) {
            return null;
        }
        if ($date->format('Y-m-d\\TH:i:s') !== substr($value, 0, 19)) {
            return null;
        }

        return $date->format('Y-m-d H:i:s.u');
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

    private static function decimal_gap(string $previous, string $current): ?int
    {
        if (strlen($previous) > 18 || strlen($current) > 18) {
            return null;
        }
        $previous_int = (int) $previous;
        $current_int = (int) $current;
        if ($current_int <= $previous_int) {
            return null;
        }

        return $current_int - $previous_int - 1;
    }
}
