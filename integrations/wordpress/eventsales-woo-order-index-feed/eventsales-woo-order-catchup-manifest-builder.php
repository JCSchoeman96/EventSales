<?php

declare(strict_types=1);

/**
 * Builds an immutable catch-up delta U over one READY E1 membership manifest.
 *
 * Parent membership is resolved before H opens. The source adapter owns the
 * one source-consistent snapshot and parent-sequence candidate/ACK cursor;
 * this class owns scope binding, budget, persistence ordering, and cleanup.
 */
final class EventSales_Woo_Order_Catchup_Manifest_Builder
{
    public const CAPTURE_BUDGET_SECONDS = 5;
    public const SOURCE_CHUNK_SIZE = 100;
    public const SCHEMA_VERSION = '2026-08-13.catchup.v1';
    public const MEMBERSHIP_PREDICATE_VERSION = 'm3-01-02f4a.catchup.v1';

    private object $wordpress_db;

    /** @var callable(object): object */
    private $source_db_factory;

    /** @var callable(object, object): object */
    private $source_adapter_factory;

    /** @var callable(object): object */
    private $manifest_store_factory;

    /** @var callable(object, string): bool */
    private $lock_acquirer;

    /** @var callable(object, string): void */
    private $lock_releaser;

    /** @var callable(): float */
    private $monotonic_clock;

    public function __construct(
        object $wordpress_db,
        ?callable $source_db_factory = null,
        ?callable $source_adapter_factory = null,
        ?callable $manifest_store_factory = null,
        ?callable $lock_acquirer = null,
        ?callable $lock_releaser = null,
        ?callable $monotonic_clock = null
    ) {
        $this->wordpress_db = $wordpress_db;
        $this->source_db_factory = $source_db_factory ?? [$this, 'create_source_db'];
        $this->source_adapter_factory = $source_adapter_factory ?? static function (object $wpdb, object $source_db): object {
            return new EventSales_Woo_Order_Catchup_Source($wpdb, $source_db);
        };
        $this->manifest_store_factory = $manifest_store_factory ?? static function (object $wpdb): object {
            return new EventSales_Woo_Order_Index_Manifest_Store($wpdb);
        };
        $this->lock_acquirer = $lock_acquirer ?? [$this, 'acquire_lock'];
        $this->lock_releaser = $lock_releaser ?? [$this, 'release_lock'];
        if ($monotonic_clock !== null) {
            $this->monotonic_clock = $monotonic_clock;
        } elseif (!function_exists('hrtime')) {
            throw new RuntimeException('monotonic_clock_unavailable');
        } else {
            $this->monotonic_clock = static function (): float {
                $nanoseconds = hrtime(true);
                if (!is_int($nanoseconds) && !is_float($nanoseconds)) {
                    throw new RuntimeException('monotonic_clock_unavailable');
                }

                return (float) $nanoseconds / 1_000_000_000.0;
            };
        }
    }

    /**
     * @param array<string, mixed> $scope
     * @return array<string, mixed>
     */
    public function build(array $scope): array
    {
        $validated = $this->validate_request($scope);
        if (!($validated['ok'] ?? false)) {
            return ['ok' => false, 'error' => 'invalid_scope'];
        }

        $lock_key = null;
        $lock_acquired = false;
        $source = null;
        $source_open = false;
        $store = null;
        $manifest_id = null;
        $manifest_building = false;

        try {
            try {
                $lock_key = $this->lock_key();
                $lock_acquired = (bool) call_user_func($this->lock_acquirer, $this->wordpress_db, $lock_key);
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'lock_unavailable'];
            }
            if (!$lock_acquired) {
                return ['ok' => false, 'error' => 'busy'];
            }

            try {
                $store = call_user_func($this->manifest_store_factory, $this->wordpress_db);
                if (!is_object($store)) {
                    return ['ok' => false, 'error' => 'manifest_storage_failed'];
                }
                $parent = $store->resolve_parent_manifest($validated['parent_token'], $validated['source_system']);
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }
            $parent_error = $this->validate_parent($parent, $validated['source_system']);
            if (!($parent_error['ok'] ?? false)) {
                return $parent_error;
            }

            try {
                $source_db = call_user_func($this->source_db_factory, $this->wordpress_db);
                if (!is_object($source_db)) {
                    return ['ok' => false, 'error' => 'source_preflight_failed'];
                }
                $source = call_user_func($this->source_adapter_factory, $this->wordpress_db, $source_db);
                if (!is_object($source)) {
                    return ['ok' => false, 'error' => 'source_preflight_failed'];
                }
                $preflight = $source->preflight();
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'source_preflight_failed'];
            }
            if (!is_array($preflight) || !($preflight['ok'] ?? false)) {
                return ['ok' => false, 'error' => 'source_preflight_failed'];
            }

            $capture_started_at = $this->now();
            try {
                $opened = $source->open_snapshot(
                    $preflight,
                    (int) $parent['manifest_id'],
                    (int) $parent['item_count']
                );
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'source_snapshot_failed'];
            }
            if (!is_array($opened) || !($opened['ok'] ?? false)) {
                return ['ok' => false, 'error' => $this->source_error_code($opened ?? [], false)];
            }
            $source_open = true;
            $this->assert_budget($capture_started_at);

            $observed_at = $this->canonical_datetime($opened['source_observed_at_gmt'] ?? null);
            if ($observed_at === null) {
                return ['ok' => false, 'error' => 'source_snapshot_failed'];
            }
            if ($observed_at < $parent['source_observed_at_gmt']) {
                return ['ok' => false, 'error' => 'source_snapshot_before_parent'];
            }

            try {
                $started = $store->begin_manifest([
                    'schema_version' => self::SCHEMA_VERSION,
                    'phase' => EventSales_Woo_Order_Index_Manifest_Store::PHASE_CATCH_UP,
                    'parent_manifest_hash' => $parent['manifest_hash'],
                    'catchup_from_gmt' => $parent['source_observed_at_gmt'],
                    'source_system' => $parent['source_system'],
                    'backfill_start_gmt' => $parent['backfill_start_gmt'],
                    'backfill_cutoff_gmt' => $parent['backfill_cutoff_gmt'],
                    'source_observed_at_gmt' => $observed_at,
                    'membership_predicate_version' => self::MEMBERSHIP_PREDICATE_VERSION,
                ]);
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }
            if (!is_array($started) || !($started['ok'] ?? false) || !is_numeric($started['manifest_id'] ?? null)) {
                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }
            $manifest_id = (int) $started['manifest_id'];
            $manifest_building = true;

            while (true) {
                $this->assert_budget($capture_started_at);
                try {
                    $candidate = $source->read_next_candidate(
                        (int) $parent['manifest_id'],
                        self::SOURCE_CHUNK_SIZE
                    );
                } catch (Throwable $error) {
                    return ['ok' => false, 'error' => 'source_snapshot_failed'];
                }
                $this->assert_budget($capture_started_at);
                if (!is_array($candidate) || !($candidate['ok'] ?? false) || !is_array($candidate['rows'] ?? null)) {
                    return ['ok' => false, 'error' => $this->source_error_code($candidate ?? [], false)];
                }
                if (count($candidate['rows']) > self::SOURCE_CHUNK_SIZE) {
                    return ['ok' => false, 'error' => 'source_snapshot_failed'];
                }

                if (($candidate['terminal'] ?? false) === true) {
                    if ($candidate['rows'] !== []) {
                        return ['ok' => false, 'error' => 'source_snapshot_failed'];
                    }
                    try {
                        $confirmed = $source->confirm_persisted($candidate);
                    } catch (Throwable $error) {
                        return ['ok' => false, 'error' => 'source_snapshot_failed'];
                    }
                    if (!is_array($confirmed) || !($confirmed['ok'] ?? false) || ($confirmed['terminal'] ?? false) !== true) {
                        return ['ok' => false, 'error' => $this->source_error_code($confirmed ?? [], false)];
                    }
                    $this->assert_budget($capture_started_at);
                    break;
                }

                try {
                    $appended = $store->append_items($manifest_id, $candidate['rows']);
                } catch (Throwable $error) {
                    return ['ok' => false, 'error' => 'manifest_storage_failed'];
                }
                if (!is_array($appended) || !($appended['ok'] ?? false)) {
                    return ['ok' => false, 'error' => 'manifest_storage_failed'];
                }
                $this->assert_budget($capture_started_at);

                try {
                    $confirmed = $source->confirm_persisted($candidate);
                } catch (Throwable $error) {
                    return ['ok' => false, 'error' => 'source_snapshot_failed'];
                }
                if (!is_array($confirmed) || !($confirmed['ok'] ?? false) || ($confirmed['terminal'] ?? true) !== false) {
                    return ['ok' => false, 'error' => $this->source_error_code($confirmed ?? [], false)];
                }
                $this->assert_budget($capture_started_at);
            }

            $this->assert_budget($capture_started_at);
            try {
                $committed = $source->commit_snapshot();
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'source_snapshot_failed'];
            }
            if (!is_array($committed) || !($committed['ok'] ?? false)) {
                return ['ok' => false, 'error' => $this->source_error_code($committed, false)];
            }
            $source_open = false;

            try {
                $revalidated_parent = $store->resolve_parent_manifest(
                    $validated['parent_token'],
                    $validated['source_system']
                );
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'parent_manifest_changed'];
            }
            if (!$this->same_parent($parent, $revalidated_parent)) {
                return ['ok' => false, 'error' => 'parent_manifest_changed'];
            }

            try {
                $finalized = $store->finalize_manifest($manifest_id);
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'manifest_finalize_failed'];
            }
            if (!is_array($finalized) || !($finalized['ok'] ?? false)) {
                return ['ok' => false, 'error' => 'manifest_finalize_failed'];
            }
            $manifest_building = false;

            try {
                $page = $store->read_page((string) $started['token'], null, $validated['limit']);
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }
            if (!is_array($page) || !($page['ok'] ?? false)) {
                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }

            return [
                'ok' => true,
                'status' => 'ready',
                'manifest_id' => $manifest_id,
                'token' => (string) $started['token'],
                'manifest_hash' => (string) ($finalized['manifest_hash'] ?? ''),
                'manifest_expires_at_gmt' => (string) ($started['expires_at_gmt'] ?? ''),
                'source_observed_at_gmt' => $observed_at,
                'page' => $page,
                'metrics' => is_array($committed['metrics'] ?? null) ? $committed['metrics'] : [],
            ];
        } catch (Throwable $error) {
            return ['ok' => false, 'error' => $error->getMessage() === 'capture_budget_exceeded' ? 'capture_budget_exceeded' : 'source_snapshot_failed'];
        } finally {
            if ($source_open && is_object($source)) {
                try {
                    $source->rollback_snapshot();
                } catch (Throwable $error) {
                }
            }
            if ($manifest_building && $manifest_id !== null && is_object($store)) {
                try {
                    $store->fail_manifest($manifest_id);
                } catch (Throwable $error) {
                }
            }
            if ($lock_acquired && is_string($lock_key)) {
                try {
                    call_user_func($this->lock_releaser, $this->wordpress_db, $lock_key);
                } catch (Throwable $error) {
                }
            }
        }
    }

    /** @param mixed $parent @return array<string, mixed> */
    private function validate_parent($parent, string $source_system): array
    {
        if (!is_array($parent) || !($parent['ok'] ?? false)) {
            $error = is_array($parent) ? (string) ($parent['error'] ?? 'parent_manifest_invalid') : 'parent_manifest_invalid';

            return ['ok' => false, 'error' => $this->parent_error_code($error)];
        }
        if (($parent['status'] ?? null) !== 'ready') {
            return ['ok' => false, 'error' => 'parent_manifest_not_ready'];
        }
        if (($parent['phase'] ?? null) !== EventSales_Woo_Order_Index_Manifest_Store::PHASE_MANIFEST_ENUMERATE) {
            return ['ok' => false, 'error' => 'parent_manifest_wrong_phase'];
        }
        if (($parent['source_system'] ?? null) !== $source_system) {
            return ['ok' => false, 'error' => 'parent_manifest_wrong_source'];
        }
        if (
            !is_int($parent['manifest_id'] ?? null)
            || $parent['manifest_id'] < 1
            || !is_int($parent['item_count'] ?? null)
            || $parent['item_count'] < 0
            || !is_string($parent['manifest_hash'] ?? null)
            || !preg_match('/^[a-f0-9]{64}$/D', $parent['manifest_hash'])
            || !is_string($parent['terminal_evidence'] ?? null)
            || $parent['terminal_evidence'] === ''
        ) {
            return ['ok' => false, 'error' => 'parent_manifest_invalid'];
        }
        foreach (['backfill_start_gmt', 'backfill_cutoff_gmt', 'source_observed_at_gmt'] as $field) {
            if ($this->canonical_datetime($parent[$field] ?? null) === null) {
                return ['ok' => false, 'error' => 'parent_manifest_invalid'];
            }
        }
        if ($parent['backfill_start_gmt'] > $parent['backfill_cutoff_gmt']) {
            return ['ok' => false, 'error' => 'parent_manifest_invalid'];
        }

        return ['ok' => true];
    }

    /** @param array<string, mixed> $scope @return array<string, mixed> */
    private function validate_request(array $scope): array
    {
        $expected = ['limit', 'parent_token', 'source_system'];
        $actual = array_map('strval', array_keys($scope));
        sort($actual, SORT_STRING);
        sort($expected, SORT_STRING);
        if ($actual !== $expected) {
            return ['ok' => false];
        }
        if (
            !is_string($scope['parent_token'])
            || $scope['parent_token'] === ''
            || strlen($scope['parent_token']) > 128
            || !preg_match('/^[A-Za-z0-9._-]+$/D', $scope['parent_token'])
            || !is_string($scope['source_system'])
            || $scope['source_system'] === ''
            || strlen($scope['source_system']) > 128
            || !preg_match('/^[A-Za-z0-9][A-Za-z0-9._:-]*$/D', $scope['source_system'])
            || !is_int($scope['limit'])
            || $scope['limit'] < 1
            || $scope['limit'] > EventSales_Woo_Order_Index_Manifest_Store::MAX_PAGE_SIZE
        ) {
            return ['ok' => false];
        }

        return [
            'ok' => true,
            'parent_token' => $scope['parent_token'],
            'source_system' => $scope['source_system'],
            'limit' => $scope['limit'],
        ];
    }

    private function create_source_db(object $wpdb): object
    {
        foreach (['dbuser', 'dbpassword', 'dbname', 'dbhost', 'prefix'] as $property) {
            if (!property_exists($wpdb, $property)) {
                throw new RuntimeException('source_connection_configuration_unavailable');
            }
        }
        if (!class_exists('wpdb')) {
            throw new RuntimeException('source_database_client_unavailable');
        }
        $source_db = new wpdb($wpdb->dbuser, $wpdb->dbpassword, $wpdb->dbname, $wpdb->dbhost);
        $source_db->set_prefix($wpdb->prefix);
        $source_db->suppress_errors(true);
        if ((string) ($source_db->last_error ?? '') !== '') {
            throw new RuntimeException('source_connection_failed');
        }

        return $source_db;
    }

    private function acquire_lock(object $wpdb, string $lock_key): bool
    {
        $result = $wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 0)', $lock_key));
        if ((string) $result === '1') {
            return true;
        }
        if ((string) $result === '0') {
            return false;
        }

        throw new RuntimeException('lock_unavailable');
    }

    private function release_lock(object $wpdb, string $lock_key): void
    {
        $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)', $lock_key));
    }

    private function lock_key(): string
    {
        foreach (['dbhost', 'dbname', 'prefix'] as $property) {
            if (!property_exists($this->wordpress_db, $property)) {
                throw new RuntimeException('lock_identity_unavailable');
            }
        }
        $identity = implode('|', [
            (string) $this->wordpress_db->dbhost,
            (string) $this->wordpress_db->dbname,
            (string) $this->wordpress_db->prefix,
        ]);

        return 'eventsales:woo-order-index:capture:' . substr(hash('sha256', $identity), 0, 29);
    }

    /** @param mixed $value */
    private function canonical_datetime($value): ?string
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

        return $date->format('Y-m-d\\TH:i:s.u\\Z');
    }

    private function now(): float
    {
        $value = call_user_func($this->monotonic_clock);
        if (!is_int($value) && !is_float($value)) {
            throw new RuntimeException('clock_unavailable');
        }

        return (float) $value;
    }

    private function assert_budget(float $started_at): void
    {
        if ($this->now() - $started_at > self::CAPTURE_BUDGET_SECONDS) {
            throw new RuntimeException('capture_budget_exceeded');
        }
    }

    /** @param array<string, mixed> $result */
    private function source_error_code(array $result, bool $preflight): string
    {
        $error = (string) ($result['error'] ?? '');
        if (in_array($error, [
            'catchup_member_unresolved',
            'parent_manifest_missing_items',
            'parent_manifest_sequence_invalid',
            'parent_manifest_storage_failed',
            'source_chunk_query_failed',
        ], true)) {
            return $error;
        }
        return $preflight ? 'source_preflight_failed' : 'source_snapshot_failed';
    }

    private function parent_error_code(string $error): string
    {
        return match ($error) {
            'manifest_not_found' => 'parent_manifest_not_found',
            'parent_manifest_expired' => 'parent_manifest_expired',
            'parent_manifest_wrong_source' => 'parent_manifest_wrong_source',
            'parent_manifest_wrong_phase' => 'parent_manifest_wrong_phase',
            'parent_manifest_not_ready' => 'parent_manifest_not_ready',
            default => 'parent_manifest_invalid',
        };
    }

    /** @param array<string, mixed> $original @param mixed $current */
    private function same_parent(array $original, $current): bool
    {
        if (!is_array($current) || !($current['ok'] ?? false)) {
            return false;
        }

        foreach (['manifest_id', 'item_count', 'manifest_hash', 'source_system', 'backfill_start_gmt', 'backfill_cutoff_gmt', 'source_observed_at_gmt', 'phase', 'status', 'schema_version', 'membership_predicate_version', 'terminal_evidence', 'expires_at_gmt'] as $field) {
            if (($current[$field] ?? null) !== ($original[$field] ?? null)) {
                return false;
            }
        }

        return true;
    }
}
