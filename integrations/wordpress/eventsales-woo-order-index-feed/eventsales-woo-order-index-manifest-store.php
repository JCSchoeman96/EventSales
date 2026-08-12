<?php

declare(strict_types=1);

/**
 * Durable source-side storage for immutable Woo order identity manifests.
 *
 * This class deliberately accepts already-resolved identity rows. It never
 * calls WooCommerce and it never decides membership from live order state.
 */
final class EventSales_Woo_Order_Index_Manifest_Store
{
    public const DEFAULT_TTL_SECONDS = 86400;
    public const MAX_TTL_SECONDS = 604800;
    public const MAX_PAGE_SIZE = 100;
    public const MAX_WRITE_BATCH = 100;

    private const STATUS_BUILDING = 'building';
    private const STATUS_READY = 'ready';
    private const STATUS_EXPIRED = 'expired';
    private const STATUS_FAILED = 'failed';
    private const TOKEN_BYTES = 32;
    private const MAX_SOURCE_ORDER_ID_BYTES = 191;
    private const MAX_SOURCE_SYSTEM_BYTES = 128;
    private const MAX_PREDICATE_VERSION_BYTES = 128;
    private const MAX_TERMINAL_EVIDENCE_BYTES = 255;
    private const CURSOR_DOMAIN = 'eventsales/woo-order-index/cursor/v1';

    /** @var object */
    private object $wpdb;

    /** @var callable(): DateTimeImmutable */
    private $clock;

    /**
     * @param object $wpdb WordPress wpdb-compatible object.
     * @param callable(): DateTimeImmutable|null $clock
     */
    public function __construct(object $wpdb, ?callable $clock = null)
    {
        $this->wpdb = $wpdb;
        $this->clock = $clock ?? static fn(): DateTimeImmutable => new DateTimeImmutable('now', new DateTimeZone('UTC'));
    }

    /**
     * Install the two durable manifest tables and database immutability
     * triggers. The operation is additive and safe to repeat.
     */
    public static function install_schema(object $wpdb): bool
    {
        try {
            [$manifest_table, $item_table] = self::table_names($wpdb);
            $manifest_identifier = self::identifier($manifest_table);
            $item_identifier = self::identifier($item_table);
            $constraint_tag = substr(hash('sha256', $manifest_table . '|' . $item_table), 0, 16);
            $manifest_status_constraint = self::identifier('eventsales_manifest_status_' . $constraint_tag);
            $manifest_count_constraint = self::identifier('eventsales_manifest_item_count_' . $constraint_tag);
            $item_order_constraint = self::identifier('eventsales_manifest_item_order_' . $constraint_tag);
            $item_id_constraint = self::identifier('eventsales_manifest_item_id_' . $constraint_tag);

            $manifest_sql = "CREATE TABLE IF NOT EXISTS {$manifest_identifier} (
                id BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT,
                token_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
                schema_version VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
                source_system VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
                backfill_start_gmt DATETIME(6) NOT NULL,
                backfill_cutoff_gmt DATETIME(6) NOT NULL,
                source_observed_at_gmt DATETIME(6) NOT NULL,
                membership_predicate_version VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
                status VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
                created_at_gmt DATETIME(6) NOT NULL,
                expires_at_gmt DATETIME(6) NOT NULL,
                completed_at_gmt DATETIME(6) NULL,
                item_count BIGINT(20) UNSIGNED NOT NULL DEFAULT 0,
                manifest_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
                terminal_evidence VARCHAR(255) CHARACTER SET ascii COLLATE ascii_bin NULL,
                PRIMARY KEY (id),
                UNIQUE KEY token_hash (token_hash),
                KEY status_expires (status, expires_at_gmt),
                CONSTRAINT {$manifest_status_constraint} CHECK (status IN ('building', 'ready', 'expired', 'failed')),
                CONSTRAINT {$manifest_count_constraint} CHECK (item_count >= 0)
            ) ENGINE=InnoDB DEFAULT CHARACTER SET utf8mb4 COLLATE=utf8mb4_unicode_ci";

            if ($wpdb->query($manifest_sql) === false) {
                return false;
            }

            $item_sql = "CREATE TABLE IF NOT EXISTS {$item_identifier} (
                manifest_id BIGINT(20) UNSIGNED NOT NULL,
                sequence BIGINT(20) UNSIGNED NOT NULL,
                source_order_id VARCHAR(191) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
                source_created_at_gmt DATETIME(6) NOT NULL,
                source_modified_at_gmt DATETIME(6) NOT NULL,
                PRIMARY KEY (manifest_id, sequence),
                UNIQUE KEY manifest_order (manifest_id, source_order_id),
                CONSTRAINT {$item_order_constraint} FOREIGN KEY (manifest_id)
                    REFERENCES {$manifest_identifier} (id) ON DELETE CASCADE,
                CONSTRAINT {$item_id_constraint} CHECK (source_order_id <> '')
            ) ENGINE=InnoDB DEFAULT CHARACTER SET utf8mb4 COLLATE=utf8mb4_unicode_ci";

            if ($wpdb->query($item_sql) === false) {
                return false;
            }

            return self::install_triggers($wpdb, $manifest_table, $item_table);
        } catch (Throwable $error) {
            return false;
        }
    }

    /** @param object $wpdb */
    public static function activate(object $wpdb): bool
    {
        return self::install_schema($wpdb);
    }

    public static function generate_token(): string
    {
        return bin2hex(random_bytes(self::TOKEN_BYTES));
    }

    public static function token_hash(string $token): string
    {
        return hash('sha256', $token);
    }

    /**
     * Create a BUILDING manifest header. The caller receives the raw token;
     * only its SHA-256 lookup hash is persisted.
     *
     * @param array<string, mixed> $scope
     * @return array<string, mixed>
     */
    public function begin_manifest(array $scope, int $ttl_seconds = self::DEFAULT_TTL_SECONDS): array
    {
        if ($ttl_seconds < 1 || $ttl_seconds > self::MAX_TTL_SECONDS) {
            return ['ok' => false, 'error' => 'invalid_ttl'];
        }

        $validated_scope = self::validate_scope($scope);
        if (!$validated_scope['ok']) {
            return ['ok' => false, 'error' => 'invalid_scope'];
        }

        try {
            $now = $this->now();
            $expires = $now->modify('+' . $ttl_seconds . ' seconds');
            $token = self::generate_token();
            $token_hash = self::token_hash($token);
            [$manifest_table] = self::table_names($this->wpdb);
            $sql = $this->wpdb->prepare(
                'INSERT INTO ' . self::identifier($manifest_table) . ' '
                . '(token_hash, schema_version, source_system, backfill_start_gmt, backfill_cutoff_gmt, '
                . 'source_observed_at_gmt, membership_predicate_version, status, created_at_gmt, expires_at_gmt, item_count) '
                . 'VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %d)',
                $token_hash,
                EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION,
                $validated_scope['source_system'],
                $validated_scope['backfill_start_gmt'],
                $validated_scope['backfill_cutoff_gmt'],
                $validated_scope['source_observed_at_gmt'],
                $validated_scope['membership_predicate_version'],
                self::STATUS_BUILDING,
                self::db_datetime($now),
                self::db_datetime($expires),
                0
            );

            if ($this->wpdb->query($sql) === false) {
                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }

            $manifest_id = (int) $this->wpdb->insert_id;

            return [
                'ok' => true,
                'manifest_id' => $manifest_id,
                'token' => $token,
                'token_hash' => $token_hash,
                'status' => self::STATUS_BUILDING,
                'created_at_gmt' => self::wire_datetime($now),
                'expires_at_gmt' => self::wire_datetime($expires),
            ];
        } catch (Throwable $error) {
            return ['ok' => false, 'error' => 'manifest_storage_failed'];
        }
    }

    /**
     * Store a resolved identity set in bounded database batches. The input is
     * iterable so a builder may stream rows without an unbounded PHP array.
     * Each batch is committed only while the manifest remains BUILDING.
     *
     * @param iterable<int, array<string, mixed>> $items
     * @return array<string, mixed>
     */
    public function append_items(int $manifest_id, iterable $items): array
    {
        $batch = [];

        try {
            foreach ($items as $item) {
                $batch[] = $item;
                if (count($batch) >= self::MAX_WRITE_BATCH) {
                    $result = $this->append_batch($manifest_id, $batch);
                    if (!$result['ok']) {
                        return $result;
                    }
                    $batch = [];
                }
            }

            if ($batch !== []) {
                return $this->append_batch($manifest_id, $batch);
            }

            return ['ok' => true, 'manifest_id' => $manifest_id];
        } catch (Throwable $error) {
            return ['ok' => false, 'error' => 'invalid_items'];
        }
    }

    /**
     * Complete a BUILDING manifest only after checking contiguous sequences,
     * exact item count, and a deterministic hash over the frozen scope/items.
     *
     * @return array<string, mixed>
     */
    public function finalize_manifest(int $manifest_id): array
    {
        [$manifest_table] = self::table_names($this->wpdb);
        $manifest_identifier = self::identifier($manifest_table);
        $started = false;

        try {
            $manifest = $this->wpdb->get_row($this->wpdb->prepare(
                'SELECT * FROM ' . $manifest_identifier . ' WHERE id = %d',
                $manifest_id
            ), ARRAY_A);
            if (!is_array($manifest) || $manifest === []) {
                return ['ok' => false, 'error' => 'manifest_not_found'];
            }

            if ($manifest['status'] !== self::STATUS_BUILDING) {
                return ['ok' => false, 'error' => 'manifest_not_building'];
            }

            if ($this->is_expired($manifest['expires_at_gmt'])) {
                return ['ok' => false, 'error' => 'manifest_expired'];
            }

            // Hash the append-only BUILDING rows outside the promotion
            // transaction. The final lock below rejects any concurrent batch
            // that changed item_count after this bounded streaming pass.
            $integrity = $this->calculate_integrity($manifest);
            if (!$integrity['ok']) {
                return $integrity;
            }

            if ($this->wpdb->query('START TRANSACTION') === false) {
                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }
            $started = true;

            $locked_manifest = $this->wpdb->get_row($this->wpdb->prepare(
                'SELECT status, expires_at_gmt, item_count FROM ' . $manifest_identifier . ' WHERE id = %d FOR UPDATE',
                $manifest_id
            ), ARRAY_A);
            if (
                !is_array($locked_manifest)
                || $locked_manifest === []
                || $locked_manifest['status'] !== self::STATUS_BUILDING
                || (int) $locked_manifest['item_count'] !== (int) $integrity['item_count']
            ) {
                $this->rollback();

                return ['ok' => false, 'error' => 'manifest_changed_during_finalize'];
            }
            if ($this->is_expired((string) $locked_manifest['expires_at_gmt'])) {
                $this->rollback();

                return ['ok' => false, 'error' => 'manifest_expired'];
            }

            $completed_at = $this->now();
            $updated = $this->wpdb->query($this->wpdb->prepare(
                'UPDATE ' . $manifest_identifier . ' SET status = %s, completed_at_gmt = %s, '
                . 'manifest_hash = %s, terminal_evidence = %s WHERE id = %d AND status = %s',
                self::STATUS_READY,
                self::db_datetime($completed_at),
                $integrity['manifest_hash'],
                $integrity['terminal_evidence'],
                $manifest_id,
                self::STATUS_BUILDING
            ));
            if ($updated === false) {
                $this->rollback();

                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }

            if ($this->wpdb->query('COMMIT') === false) {
                $this->rollback();

                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }
            $started = false;

            return [
                'ok' => true,
                'manifest_id' => $manifest_id,
                'status' => self::STATUS_READY,
                'manifest_hash' => $integrity['manifest_hash'],
                'terminal_evidence' => $integrity['terminal_evidence'],
                'item_count' => $integrity['item_count'],
                'completed_at_gmt' => self::wire_datetime($completed_at),
            ];
        } catch (Throwable $error) {
            if ($started) {
                $this->rollback();
            }

            return ['ok' => false, 'error' => 'manifest_storage_failed'];
        }
    }

    /**
     * Narrow internal API for an already resolved identity set. It never
     * performs source membership work.
     *
     * @param array<string, mixed> $scope
     * @param iterable<int, array<string, mixed>> $items
     * @return array<string, mixed>
     */
    public function store_resolved_manifest(
        array $scope,
        iterable $items,
        int $ttl_seconds = self::DEFAULT_TTL_SECONDS
    ): array {
        $started = $this->begin_manifest($scope, $ttl_seconds);
        if (!$started['ok']) {
            return $started;
        }

        $appended = $this->append_items((int) $started['manifest_id'], $items);
        if (!$appended['ok']) {
            $this->fail_manifest((int) $started['manifest_id']);

            return [
                'ok' => false,
                'error' => $appended['error'] ?? 'invalid_items',
                'manifest_id' => $started['manifest_id'],
            ];
        }

        $finalized = $this->finalize_manifest((int) $started['manifest_id']);
        if (!$finalized['ok']) {
            $this->fail_manifest((int) $started['manifest_id']);

            return [
                'ok' => false,
                'error' => $finalized['error'] ?? 'manifest_storage_failed',
                'manifest_id' => $started['manifest_id'],
            ];
        }

        return array_merge($started, $finalized);
    }

    /**
     * Read one immutable READY page using a sequence keyset. The returned
     * next_sequence is internal state; the HTTP controller wraps it in an
     * authenticated cursor.
     *
     * @return array<string, mixed>
     */
    public function read_page(string $token, ?int $last_sequence, int $limit): array
    {
        if ($limit < 1 || $limit > self::MAX_PAGE_SIZE || ($last_sequence !== null && $last_sequence < 0)) {
            return ['ok' => false, 'error' => 'invalid_cursor'];
        }

        $token_hash = self::token_hash($token);
        [$manifest_table, $item_table] = self::table_names($this->wpdb);
        $manifest = $this->wpdb->get_row($this->wpdb->prepare(
            'SELECT id, schema_version, source_system, source_observed_at_gmt, expires_at_gmt, '
            . 'status, manifest_hash, terminal_evidence FROM ' . self::identifier($manifest_table)
            . ' WHERE token_hash = %s',
            $token_hash
        ), ARRAY_A);

        if (!is_array($manifest) || $manifest === []) {
            return ['ok' => false, 'error' => 'manifest_not_found'];
        }

        if ($this->is_expired($manifest['expires_at_gmt'])) {
            if (in_array($manifest['status'], [self::STATUS_BUILDING, self::STATUS_READY], true)) {
                $this->mark_expired((int) $manifest['id']);
            }

            return ['ok' => false, 'error' => 'manifest_expired'];
        }

        if ($manifest['status'] === self::STATUS_BUILDING) {
            return ['ok' => false, 'error' => 'manifest_not_ready'];
        }

        if ($manifest['status'] === self::STATUS_FAILED) {
            return ['ok' => false, 'error' => 'manifest_failed'];
        }

        if ($manifest['status'] !== self::STATUS_READY || $manifest['manifest_hash'] === null) {
            return ['ok' => false, 'error' => 'manifest_unavailable'];
        }

        $after = $last_sequence ?? 0;
        $rows = $this->wpdb->get_results($this->wpdb->prepare(
            'SELECT sequence, source_order_id, source_created_at_gmt, source_modified_at_gmt FROM '
            . self::identifier($item_table) . ' WHERE manifest_id = %d AND sequence > %d '
            . 'ORDER BY sequence ASC LIMIT %d',
            (int) $manifest['id'],
            $after,
            $limit + 1
        ), ARRAY_A);
        if (!is_array($rows)) {
            return ['ok' => false, 'error' => 'manifest_storage_failed'];
        }

        $has_more = count($rows) > $limit;
        if ($has_more) {
            array_pop($rows);
        }

        $items = [];
        foreach ($rows as $row) {
            $items[] = [
                'source_order_id' => (string) $row['source_order_id'],
                'source_created_at_gmt' => self::wire_datetime_from_db((string) $row['source_created_at_gmt']),
                'source_modified_at_gmt' => self::wire_datetime_from_db((string) $row['source_modified_at_gmt']),
            ];
        }

        $next_sequence = null;
        if ($has_more && $rows !== []) {
            $next_sequence = (int) $rows[count($rows) - 1]['sequence'];
        }

        return [
            'ok' => true,
            'manifest_id' => (int) $manifest['id'],
            'schema_version' => (string) $manifest['schema_version'],
            'source_system' => (string) $manifest['source_system'],
            'source_observed_at_gmt' => self::wire_datetime_from_db((string) $manifest['source_observed_at_gmt']),
            'expires_at_gmt' => self::wire_datetime_from_db((string) $manifest['expires_at_gmt']),
            'manifest_hash' => (string) $manifest['manifest_hash'],
            'items' => $items,
            'next_sequence' => $next_sequence,
            'has_more' => $has_more,
            'terminal_evidence' => (string) $manifest['terminal_evidence'],
        ];
    }

    /**
     * Cursor wire format:
     * base64url(canonical-json-payload).base64url(hmac-sha256(domain + "\n" + payload))
     * where the payload binds the exact manifest token hash and last sequence.
     */
    public static function encode_cursor(string $manifest_token_hash, int $last_sequence, string $secret): string
    {
        $payload = self::canonical_json([
            'last_sequence' => $last_sequence,
            'manifest_token_hash' => $manifest_token_hash,
            'v' => 1,
        ]);
        $signing_input = self::CURSOR_DOMAIN . "\n" . $payload;
        $mac = hash_hmac('sha256', $signing_input, $secret, true);

        return self::base64url_encode($payload) . '.' . self::base64url_encode($mac);
    }

    public static function decode_cursor(string $cursor, string $manifest_token_hash, string $secret): ?int
    {
        $parts = explode('.', $cursor);
        if (count($parts) !== 2 || $parts[0] === '' || $parts[1] === '') {
            return null;
        }

        $payload = self::base64url_decode($parts[0]);
        $mac = self::base64url_decode($parts[1]);
        if ($payload === null || $mac === null || strlen($mac) !== 32) {
            return null;
        }

        $expected = hash_hmac('sha256', self::CURSOR_DOMAIN . "\n" . $payload, $secret, true);
        if (!hash_equals($expected, $mac)) {
            return null;
        }

        try {
            $decoded = json_decode($payload, true, 16, JSON_THROW_ON_ERROR);
        } catch (Throwable $error) {
            return null;
        }

        if (!is_array($decoded) || array_keys($decoded) !== ['last_sequence', 'manifest_token_hash', 'v']) {
            return null;
        }

        if (
            $decoded['v'] !== 1
            || !is_int($decoded['last_sequence'])
            || $decoded['last_sequence'] < 1
            || !is_string($decoded['manifest_token_hash'])
            || !hash_equals($manifest_token_hash, $decoded['manifest_token_hash'])
        ) {
            return null;
        }

        return $decoded['last_sequence'];
    }

    /** @return array<string, mixed>|null */
    public function manifest_metadata(int $manifest_id): ?array
    {
        [$manifest_table] = self::table_names($this->wpdb);
        $row = $this->wpdb->get_row($this->wpdb->prepare(
            'SELECT id, status, expires_at_gmt, item_count, manifest_hash, terminal_evidence FROM '
            . self::identifier($manifest_table) . ' WHERE id = %d',
            $manifest_id
        ), ARRAY_A);
        if (!is_array($row) || $row === []) {
            return null;
        }

        $row['id'] = (int) $row['id'];
        $row['item_count'] = (int) $row['item_count'];
        $row['expires_at_gmt'] = self::wire_datetime_from_db((string) $row['expires_at_gmt']);

        return $row;
    }

    public function manifest_status(int $manifest_id): ?string
    {
        [$manifest_table] = self::table_names($this->wpdb);
        $status = $this->wpdb->get_var($this->wpdb->prepare(
            'SELECT status FROM ' . self::identifier($manifest_table) . ' WHERE id = %d',
            $manifest_id
        ));

        return $status === null ? null : (string) $status;
    }

    public function fail_manifest(int $manifest_id): bool
    {
        [$manifest_table] = self::table_names($this->wpdb);
        $result = $this->wpdb->query($this->wpdb->prepare(
            'UPDATE ' . self::identifier($manifest_table) . ' SET status = %s WHERE id = %d AND status = %s',
            self::STATUS_FAILED,
            $manifest_id,
            self::STATUS_BUILDING
        ));

        return $result !== false;
    }

    /**
     * Delete at most $batch_size expired, failed, or abandoned BUILDING
     * manifests. Expiry is checked against the injected clock, so reads and GC
     * remain correct without relying on cron execution.
     *
     * @return array{ok: bool, deleted_manifests: int}
     */
    public function garbage_collect(int $batch_size = 100): array
    {
        if ($batch_size < 1 || $batch_size > 100) {
            return ['ok' => false, 'deleted_manifests' => 0];
        }

        [$manifest_table] = self::table_names($this->wpdb);
        $now = $this->now();
        $rows = $this->wpdb->get_results($this->wpdb->prepare(
            'SELECT id, status, expires_at_gmt FROM ' . self::identifier($manifest_table)
            . ' WHERE status IN (%s, %s) OR expires_at_gmt <= %s '
            . 'ORDER BY expires_at_gmt ASC, id ASC LIMIT %d',
            self::STATUS_EXPIRED,
            self::STATUS_FAILED,
            self::db_datetime($now),
            $batch_size
        ), ARRAY_A);
        if (!is_array($rows)) {
            return ['ok' => false, 'deleted_manifests' => 0];
        }

        $deleted = 0;
        foreach ($rows as $row) {
            $id = (int) $row['id'];
            $status = (string) $row['status'];
            $expires_at = (string) $row['expires_at_gmt'];
            if (in_array($status, [self::STATUS_BUILDING, self::STATUS_READY], true) && !$this->is_expired($expires_at)) {
                continue;
            }

            if ($status === self::STATUS_BUILDING || $status === self::STATUS_READY) {
                $this->mark_expired($id);
            }

            $deleted_row = $this->wpdb->query($this->wpdb->prepare(
                'DELETE FROM ' . self::identifier($manifest_table) . ' WHERE id = %d '
                . 'AND status IN (%s, %s, %s)',
                $id,
                self::STATUS_EXPIRED,
                self::STATUS_FAILED,
                self::STATUS_BUILDING
            ));
            if ($deleted_row !== false && $deleted_row > 0) {
                $deleted++;
            }
        }

        return ['ok' => true, 'deleted_manifests' => $deleted];
    }

    /** @return array{ok: bool, manifest_hash?: string, terminal_evidence?: string, item_count?: int} */
    private function calculate_integrity(array $manifest): array
    {
        [$item_table] = array_slice(self::table_names($this->wpdb), 1);
        $item_identifier = self::identifier($item_table);
        $expected_count = (int) $manifest['item_count'];
        $context = hash_init('sha256');
        $header = [
            'backfill_cutoff_gmt' => self::wire_datetime_from_db((string) $manifest['backfill_cutoff_gmt']),
            'backfill_start_gmt' => self::wire_datetime_from_db((string) $manifest['backfill_start_gmt']),
            'item_count' => $expected_count,
            'membership_predicate_version' => (string) $manifest['membership_predicate_version'],
            'schema_version' => (string) $manifest['schema_version'],
            'source_observed_at_gmt' => self::wire_datetime_from_db((string) $manifest['source_observed_at_gmt']),
            'source_system' => (string) $manifest['source_system'],
        ];
        hash_update($context, self::canonical_json($header) . "\n");

        $last_sequence = 0;
        $seen = 0;
        while (true) {
            $rows = $this->wpdb->get_results($this->wpdb->prepare(
                'SELECT sequence, source_order_id, source_created_at_gmt, source_modified_at_gmt FROM '
                . $item_identifier . ' WHERE manifest_id = %d AND sequence > %d '
                . 'ORDER BY sequence ASC LIMIT %d',
                (int) $manifest['id'],
                $last_sequence,
                self::MAX_WRITE_BATCH
            ), ARRAY_A);
            if (!is_array($rows)) {
                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }
            if ($rows === []) {
                break;
            }

            foreach ($rows as $row) {
                $sequence = (int) $row['sequence'];
                if ($sequence !== $last_sequence + 1) {
                    return ['ok' => false, 'error' => 'manifest_incomplete'];
                }

                $record = [
                    'sequence' => $sequence,
                    'source_created_at_gmt' => self::wire_datetime_from_db((string) $row['source_created_at_gmt']),
                    'source_modified_at_gmt' => self::wire_datetime_from_db((string) $row['source_modified_at_gmt']),
                    'source_order_id' => (string) $row['source_order_id'],
                ];
                hash_update($context, self::canonical_json($record) . "\n");
                $last_sequence = $sequence;
                $seen++;
            }
        }

        if ($seen !== $expected_count || ($seen > 0 && $last_sequence !== $expected_count)) {
            return ['ok' => false, 'error' => 'manifest_incomplete'];
        }

        $manifest_hash = hash_final($context);
        $terminal_evidence = 'v1;manifest_sha256=' . $manifest_hash . ';item_count=' . $seen . ';last_sequence=' . $last_sequence;
        if (strlen($terminal_evidence) > self::MAX_TERMINAL_EVIDENCE_BYTES) {
            return ['ok' => false, 'error' => 'manifest_storage_failed'];
        }

        return [
            'ok' => true,
            'manifest_hash' => $manifest_hash,
            'terminal_evidence' => $terminal_evidence,
            'item_count' => $seen,
        ];
    }

    /** @param array<int, array<string, mixed>> $batch */
    private function append_batch(int $manifest_id, array $batch): array
    {
        [$manifest_table, $item_table] = self::table_names($this->wpdb);
        $manifest_identifier = self::identifier($manifest_table);
        $item_identifier = self::identifier($item_table);
        $started = false;

        try {
            if ($this->wpdb->query('START TRANSACTION') === false) {
                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }
            $started = true;

            $manifest = $this->wpdb->get_row($this->wpdb->prepare(
                'SELECT status, item_count FROM ' . $manifest_identifier . ' WHERE id = %d FOR UPDATE',
                $manifest_id
            ), ARRAY_A);
            if (!is_array($manifest) || $manifest === [] || $manifest['status'] !== self::STATUS_BUILDING) {
                $this->rollback();

                return ['ok' => false, 'error' => 'manifest_not_building'];
            }

            $sequence = (int) $manifest['item_count'];
            foreach ($batch as $item) {
                $normalized = self::normalize_item($item);
                if (!$normalized['ok']) {
                    $this->rollback();

                    return ['ok' => false, 'error' => 'invalid_items'];
                }
                $sequence++;
                $inserted = $this->wpdb->query($this->wpdb->prepare(
                    'INSERT INTO ' . $item_identifier . ' '
                    . '(manifest_id, sequence, source_order_id, source_created_at_gmt, source_modified_at_gmt) '
                    . 'VALUES (%d, %d, %s, %s, %s)',
                    $manifest_id,
                    $sequence,
                    $normalized['source_order_id'],
                    $normalized['source_created_at_gmt'],
                    $normalized['source_modified_at_gmt']
                ));
                if ($inserted === false) {
                    $this->rollback();

                    return ['ok' => false, 'error' => 'duplicate_or_invalid_item'];
                }
            }

            $updated = $this->wpdb->query($this->wpdb->prepare(
                'UPDATE ' . $manifest_identifier . ' SET item_count = %d WHERE id = %d AND status = %s',
                $sequence,
                $manifest_id,
                self::STATUS_BUILDING
            ));
            if ($updated === false) {
                $this->rollback();

                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }

            if ($this->wpdb->query('COMMIT') === false) {
                $this->rollback();

                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }
            $started = false;

            return ['ok' => true, 'manifest_id' => $manifest_id, 'item_count' => $sequence];
        } catch (Throwable $error) {
            if ($started) {
                $this->rollback();
            }

            return ['ok' => false, 'error' => 'duplicate_or_invalid_item'];
        }
    }

    private function mark_expired(int $manifest_id): bool
    {
        [$manifest_table] = self::table_names($this->wpdb);
        $result = $this->wpdb->query($this->wpdb->prepare(
            'UPDATE ' . self::identifier($manifest_table) . ' SET status = %s WHERE id = %d '
            . 'AND status IN (%s, %s) AND expires_at_gmt <= %s',
            self::STATUS_EXPIRED,
            $manifest_id,
            self::STATUS_BUILDING,
            self::STATUS_READY,
            self::db_datetime($this->now())
        ));

        return $result !== false;
    }

    private function is_expired(string $db_datetime): bool
    {
        $expires = self::date_from_db($db_datetime);

        return $expires !== null && $this->now() >= $expires;
    }

    private function now(): DateTimeImmutable
    {
        $now = ($this->clock)();
        if (!$now instanceof DateTimeImmutable) {
            throw new RuntimeException('clock must return DateTimeImmutable');
        }

        return $now->setTimezone(new DateTimeZone('UTC'));
    }

    private function rollback(): void
    {
        $this->wpdb->query('ROLLBACK');
    }

    /** @return array{ok: bool, source_system?: string, backfill_start_gmt?: string, backfill_cutoff_gmt?: string, source_observed_at_gmt?: string, membership_predicate_version?: string} */
    private static function validate_scope(array $scope): array
    {
        $expected = [
            'backfill_cutoff_gmt',
            'backfill_start_gmt',
            'membership_predicate_version',
            'source_observed_at_gmt',
            'source_system',
        ];
        $actual = array_map('strval', array_keys($scope));
        sort($actual, SORT_STRING);
        if ($actual !== $expected) {
            return ['ok' => false];
        }

        foreach (['source_system', 'membership_predicate_version'] as $field) {
            if (!is_string($scope[$field]) || trim($scope[$field]) === '' || preg_match('/[\x00-\x1F\x7F]/', $scope[$field])) {
                return ['ok' => false];
            }
        }

        if (
            strlen($scope['source_system']) > self::MAX_SOURCE_SYSTEM_BYTES
            || strlen($scope['membership_predicate_version']) > self::MAX_PREDICATE_VERSION_BYTES
            || !preg_match('/^[A-Za-z0-9][A-Za-z0-9._:-]*$/D', $scope['source_system'])
            || !preg_match('/^[A-Za-z0-9][A-Za-z0-9._:-]*$/D', $scope['membership_predicate_version'])
        ) {
            return ['ok' => false];
        }

        $dates = [];
        foreach (['backfill_start_gmt', 'backfill_cutoff_gmt', 'source_observed_at_gmt'] as $field) {
            $date = self::date_from_wire($scope[$field]);
            if ($date === null) {
                return ['ok' => false];
            }
            $dates[$field] = self::db_datetime($date);
        }

        if ($dates['backfill_start_gmt'] > $dates['backfill_cutoff_gmt']) {
            return ['ok' => false];
        }

        return [
            'ok' => true,
            'source_system' => trim($scope['source_system']),
            'backfill_start_gmt' => $dates['backfill_start_gmt'],
            'backfill_cutoff_gmt' => $dates['backfill_cutoff_gmt'],
            'source_observed_at_gmt' => $dates['source_observed_at_gmt'],
            'membership_predicate_version' => trim($scope['membership_predicate_version']),
        ];
    }

    /** @return array{ok: bool, source_order_id?: string, source_created_at_gmt?: string, source_modified_at_gmt?: string} */
    private static function normalize_item($item): array
    {
        if (!is_array($item)) {
            return ['ok' => false];
        }

        $expected = ['source_created_at_gmt', 'source_modified_at_gmt', 'source_order_id'];
        $actual = array_map('strval', array_keys($item));
        sort($actual, SORT_STRING);
        if ($actual !== $expected) {
            return ['ok' => false];
        }

        if (is_int($item['source_order_id'])) {
            $source_order_id = (string) $item['source_order_id'];
        } elseif (is_string($item['source_order_id'])) {
            $source_order_id = trim($item['source_order_id']);
        } else {
            return ['ok' => false];
        }

        if (
            $source_order_id === ''
            || strlen($source_order_id) > self::MAX_SOURCE_ORDER_ID_BYTES
            || preg_match('/[^\x21-\x7E]/', $source_order_id)
        ) {
            return ['ok' => false];
        }

        $created = self::date_from_wire($item['source_created_at_gmt']);
        $modified = self::date_from_wire($item['source_modified_at_gmt']);
        if ($created === null || $modified === null) {
            return ['ok' => false];
        }

        return [
            'ok' => true,
            'source_order_id' => $source_order_id,
            'source_created_at_gmt' => self::db_datetime($created),
            'source_modified_at_gmt' => self::db_datetime($modified),
        ];
    }

    private static function date_from_wire($value): ?DateTimeImmutable
    {
        if (!is_string($value) || !preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/D', $value)) {
            return null;
        }

        $format = strpos($value, '.') === false ? '!Y-m-d\\TH:i:s\\Z' : '!Y-m-d\\TH:i:s.u\\Z';
        $date = DateTimeImmutable::createFromFormat($format, $value, new DateTimeZone('UTC'));
        $errors = DateTimeImmutable::getLastErrors();
        if (
            $date === false
            || ($errors !== false && ($errors['warning_count'] > 0 || $errors['error_count'] > 0))
            || $date->format('Y-m-d\\TH:i:s') !== substr($value, 0, 19)
        ) {
            return null;
        }

        if (strpos($value, '.') !== false && $date->format('u') !== str_pad(substr($value, 20, -1), 6, '0')) {
            return null;
        }

        return $date->setTimezone(new DateTimeZone('UTC'));
    }

    private static function date_from_db(string $value): ?DateTimeImmutable
    {
        $date = DateTimeImmutable::createFromFormat('!Y-m-d H:i:s.u', $value, new DateTimeZone('UTC'));
        if ($date === false) {
            $date = DateTimeImmutable::createFromFormat('!Y-m-d H:i:s', $value, new DateTimeZone('UTC'));
        }

        return $date === false ? null : $date->setTimezone(new DateTimeZone('UTC'));
    }

    private static function db_datetime(DateTimeImmutable $date): string
    {
        return $date->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d H:i:s.u');
    }

    private static function wire_datetime(DateTimeImmutable $date): string
    {
        return $date->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d\\TH:i:s.u\\Z');
    }

    private static function wire_datetime_from_db(string $value): string
    {
        $date = self::date_from_db($value);

        return $date === null ? '' : self::wire_datetime($date);
    }

    /** @param object $wpdb @return array{0: string, 1: string} */
    private static function table_names(object $wpdb): array
    {
        $prefix = property_exists($wpdb, 'prefix') ? (string) $wpdb->prefix : '';
        if ($prefix === '' || !preg_match('/^[A-Za-z0-9_]+$/D', $prefix)) {
            throw new RuntimeException('invalid WordPress table prefix');
        }

        return [
            $prefix . 'eventsales_order_manifests',
            $prefix . 'eventsales_order_manifest_items',
        ];
    }

    private static function identifier(string $identifier): string
    {
        if (!preg_match('/^[A-Za-z0-9_]+$/D', $identifier)) {
            throw new RuntimeException('invalid SQL identifier');
        }

        return '`' . $identifier . '`';
    }

    private static function install_triggers(object $wpdb, string $manifest_table, string $item_table): bool
    {
        $tag = substr(hash('sha256', $manifest_table . '|' . $item_table), 0, 16);
        $header_trigger = 'eventsales_manifest_header_guard_' . $tag;
        $header_delete_trigger = 'eventsales_manifest_header_delete_guard_' . $tag;
        $item_insert_trigger = 'eventsales_manifest_item_insert_guard_' . $tag;
        $item_update_trigger = 'eventsales_manifest_item_update_guard_' . $tag;
        $item_delete_trigger = 'eventsales_manifest_item_delete_guard_' . $tag;
        $header_identifier = self::identifier($manifest_table);
        $item_identifier = self::identifier($item_table);

        $triggers = [
            $header_trigger => "CREATE TRIGGER " . self::identifier($header_trigger) . " BEFORE UPDATE ON {$header_identifier} FOR EACH ROW
BEGIN
    DECLARE stored_item_count BIGINT UNSIGNED DEFAULT 0;
    DECLARE stored_min_sequence BIGINT UNSIGNED DEFAULT 0;
    DECLARE stored_max_sequence BIGINT UNSIGNED DEFAULT 0;

    IF NOT (OLD.token_hash <=> NEW.token_hash) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'manifest token hash is immutable';
    END IF;

    IF NOT (
        OLD.schema_version <=> NEW.schema_version
        AND OLD.source_system <=> NEW.source_system
        AND OLD.backfill_start_gmt <=> NEW.backfill_start_gmt
        AND OLD.backfill_cutoff_gmt <=> NEW.backfill_cutoff_gmt
        AND OLD.source_observed_at_gmt <=> NEW.source_observed_at_gmt
        AND OLD.membership_predicate_version <=> NEW.membership_predicate_version
        AND OLD.created_at_gmt <=> NEW.created_at_gmt
        AND OLD.expires_at_gmt <=> NEW.expires_at_gmt
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'manifest scope is immutable';
    END IF;

    IF OLD.status = 'ready' THEN
        IF NEW.status = 'expired' THEN
            IF NOT (
                OLD.schema_version <=> NEW.schema_version
                AND OLD.source_system <=> NEW.source_system
                AND OLD.backfill_start_gmt <=> NEW.backfill_start_gmt
                AND OLD.backfill_cutoff_gmt <=> NEW.backfill_cutoff_gmt
                AND OLD.source_observed_at_gmt <=> NEW.source_observed_at_gmt
                AND OLD.membership_predicate_version <=> NEW.membership_predicate_version
                AND OLD.created_at_gmt <=> NEW.created_at_gmt
                AND OLD.expires_at_gmt <=> NEW.expires_at_gmt
                AND OLD.completed_at_gmt <=> NEW.completed_at_gmt
                AND OLD.item_count <=> NEW.item_count
                AND OLD.manifest_hash <=> NEW.manifest_hash
                AND OLD.terminal_evidence <=> NEW.terminal_evidence
            ) THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ready manifest membership is immutable';
            END IF;
        ELSE
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ready manifest lifecycle is closed';
        END IF;
    ELSEIF OLD.status IN ('failed', 'expired') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'terminal manifest lifecycle is closed';
    END IF;

    IF OLD.status = 'building' AND NEW.status = 'ready' THEN
        SELECT COUNT(*), COALESCE(MIN(sequence), 0), COALESCE(MAX(sequence), 0)
          INTO stored_item_count, stored_min_sequence, stored_max_sequence
          FROM {$item_identifier}
         WHERE manifest_id = OLD.id;

        IF NEW.manifest_hash IS NULL
            OR NEW.terminal_evidence IS NULL
            OR NEW.completed_at_gmt IS NULL
            OR NEW.item_count <> stored_item_count
            OR (stored_item_count > 0 AND (stored_min_sequence <> 1 OR stored_max_sequence <> stored_item_count)) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'manifest storage invariants are incomplete';
        END IF;
    END IF;
END",
            $header_delete_trigger => "CREATE TRIGGER " . self::identifier($header_delete_trigger) . " BEFORE DELETE ON {$header_identifier} FOR EACH ROW
BEGIN
    IF OLD.status = 'ready' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ready manifest cannot be deleted';
    END IF;
END",
            $item_insert_trigger => "CREATE TRIGGER " . self::identifier($item_insert_trigger) . " BEFORE INSERT ON {$item_identifier} FOR EACH ROW
BEGIN
    DECLARE current_status VARCHAR(16);
    SELECT status INTO current_status FROM {$header_identifier} WHERE id = NEW.manifest_id;
    IF current_status IS NULL OR current_status <> 'building' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'manifest items require BUILDING status';
    END IF;
END",
            $item_update_trigger => "CREATE TRIGGER " . self::identifier($item_update_trigger) . " BEFORE UPDATE ON {$item_identifier} FOR EACH ROW
BEGIN
    DECLARE current_status VARCHAR(16);
    SELECT status INTO current_status FROM {$header_identifier} WHERE id = OLD.manifest_id;
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'manifest items are append-only';
END",
            $item_delete_trigger => "CREATE TRIGGER " . self::identifier($item_delete_trigger) . " BEFORE DELETE ON {$item_identifier} FOR EACH ROW
BEGIN
    DECLARE current_status VARCHAR(16);
    SELECT status INTO current_status FROM {$header_identifier} WHERE id = OLD.manifest_id;
    IF current_status IS NULL OR current_status NOT IN ('expired', 'failed') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'manifest items are immutable';
    END IF;
END",
        ];

        foreach ($triggers as $name => $sql) {
            $exists = $wpdb->get_var($wpdb->prepare(
                "SHOW TRIGGERS WHERE `Trigger` = %s",
                $name
            ));
            if ($exists !== null) {
                continue;
            }
            if ($wpdb->query($sql) === false) {
                return false;
            }
        }

        return true;
    }

    /** @return array<string, mixed> */
    private static function canonical_json($value): string
    {
        if (is_null($value)) {
            return 'null';
        }
        if (is_bool($value)) {
            return $value ? 'true' : 'false';
        }
        if (is_int($value) || is_float($value)) {
            return (string) json_encode($value, JSON_PRESERVE_ZERO_FRACTION);
        }
        if (is_string($value)) {
            return (string) json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        }
        if (is_object($value)) {
            $value = get_object_vars($value);
        }
        if (!is_array($value)) {
            return 'null';
        }
        if ($value === [] || array_keys($value) === range(0, count($value) - 1)) {
            return '[' . implode(',', array_map([self::class, 'canonical_json'], $value)) . ']';
        }

        $keys = array_map('strval', array_keys($value));
        sort($keys, SORT_STRING);
        $pairs = [];
        foreach ($keys as $key) {
            $pairs[] = self::canonical_json($key) . ':' . self::canonical_json($value[$key]);
        }

        return '{' . implode(',', $pairs) . '}';
    }

    private static function base64url_encode(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }

    private static function base64url_decode(string $value): ?string
    {
        if (!preg_match('/^[A-Za-z0-9_-]+$/D', $value)) {
            return null;
        }

        $padding = strlen($value) % 4;
        if ($padding > 0) {
            $value .= str_repeat('=', 4 - $padding);
        }
        $decoded = base64_decode(strtr($value, '-_', '+/'), true);

        return $decoded === false ? null : $decoded;
    }
}
