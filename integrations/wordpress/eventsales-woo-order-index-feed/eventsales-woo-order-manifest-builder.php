<?php

declare(strict_types=1);

/**
 * Builds one immutable Woo membership manifest from one source snapshot.
 *
 * This class is deliberately the only source-to-E1 orchestration boundary.
 * The source adapter owns continuation, while this class owns ordering,
 * bounded runtime, failure cleanup, and source-scoped load control.
 */
final class EventSales_Woo_Order_Manifest_Builder
{
    public const CAPTURE_BUDGET_SECONDS = 5;
    public const SOURCE_CHUNK_SIZE = 100;
    public const MEMBERSHIP_PREDICATE_VERSION = 'm3-01-02e2b.snapshot.v1';

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
            return new EventSales_Woo_Order_Membership_Source($wpdb, $source_db);
        };
        $this->manifest_store_factory = $manifest_store_factory ?? static function (object $wpdb): object {
            return new EventSales_Woo_Order_Index_Manifest_Store($wpdb);
        };
        $this->lock_acquirer = $lock_acquirer ?? [$this, 'acquire_lock'];
        $this->lock_releaser = $lock_releaser ?? [$this, 'release_lock'];
        $this->monotonic_clock = $monotonic_clock ?? static fn(): float => microtime(true);
    }

    /**
     * Capture one validated source scope and return its first READY E1 page.
     *
     * @param array<string, mixed> $scope
     * @return array<string, mixed>
     */
    public function build(array $scope): array
    {
        $validated = $this->validate_scope($scope);
        if (!$validated['ok']) {
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
                $source_db = call_user_func($this->source_db_factory, $this->wordpress_db);
                if (!is_object($source_db)) {
                    return ['ok' => false, 'error' => 'source_preflight_failed'];
                }
                $source = call_user_func($this->source_adapter_factory, $this->wordpress_db, $source_db);
                if (!is_object($source)) {
                    return ['ok' => false, 'error' => 'source_preflight_failed'];
                }
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'source_preflight_failed'];
            }

            try {
                $preflight = $source->preflight();
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'source_preflight_failed'];
            }
            if (!is_array($preflight) || !($preflight['ok'] ?? false)) {
                return ['ok' => false, 'error' => $this->source_error_code($preflight, true)];
            }

            // The elapsed-time budget begins immediately before D is opened
            // and cannot be supplied or extended by the request.
            $capture_started_at = $this->now();
            try {
                $opened = $source->open_snapshot($preflight);
            } catch (Throwable $error) {
                return ['ok' => false, 'error' => 'source_snapshot_failed'];
            }
            if (!is_array($opened) || !($opened['ok'] ?? false)) {
                return ['ok' => false, 'error' => $this->source_error_code($opened, false)];
            }
            $source_open = true;

            $observed_at = $this->canonical_datetime($opened['source_observed_at_gmt'] ?? null);
            if ($observed_at === null) {
                return ['ok' => false, 'error' => 'source_snapshot_failed'];
            }

            try {
                $store = call_user_func($this->manifest_store_factory, $this->wordpress_db);
                if (!is_object($store)) {
                    return ['ok' => false, 'error' => 'manifest_storage_failed'];
                }
                $started = $store->begin_manifest([
                    'source_system' => $validated['source_system'],
                    'backfill_start_gmt' => $validated['backfill_start'],
                    'backfill_cutoff_gmt' => $validated['backfill_cutoff'],
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
                        $validated['backfill_start'],
                        $validated['backfill_cutoff'],
                        self::SOURCE_CHUNK_SIZE
                    );
                } catch (Throwable $error) {
                    return ['ok' => false, 'error' => 'source_snapshot_failed'];
                }
                if (!is_array($candidate) || !($candidate['ok'] ?? false) || !is_array($candidate['rows'] ?? null)) {
                    return ['ok' => false, 'error' => $this->source_error_code($candidate, false)];
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
                        return ['ok' => false, 'error' => $this->source_error_code($confirmed, false)];
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
                    return ['ok' => false, 'error' => $this->source_error_code($confirmed, false)];
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
            if (!is_array($page['items'] ?? null) || count($page['items']) > $validated['limit'] || count($page['items']) > self::SOURCE_CHUNK_SIZE) {
                return ['ok' => false, 'error' => 'manifest_storage_failed'];
            }

            return [
                'ok' => true,
                'status' => 'ready',
                'token' => (string) $started['token'],
                'manifest_hash' => (string) ($finalized['manifest_hash'] ?? ''),
                'manifest_expires_at_gmt' => (string) ($started['expires_at_gmt'] ?? ''),
                'source_observed_at_gmt' => $observed_at,
                'page' => $page,
                'metrics' => is_array($committed['metrics'] ?? null) ? $committed['metrics'] : [],
            ];
        } catch (Throwable $error) {
            $code = $error->getMessage();
            if ($code === 'capture_budget_exceeded') {
                return ['ok' => false, 'error' => 'capture_budget_exceeded'];
            }

            return ['ok' => false, 'error' => 'source_snapshot_failed'];
        } finally {
            if ($source_open && is_object($source)) {
                try {
                    $source->rollback_snapshot();
                } catch (Throwable $error) {
                    // The original bounded failure remains the public result.
                }
            }
            if ($manifest_building && $manifest_id !== null && is_object($store)) {
                try {
                    $store->fail_manifest($manifest_id);
                } catch (Throwable $error) {
                    // The original bounded failure remains the public result.
                }
            }
            if ($lock_acquired && is_string($lock_key)) {
                try {
                    call_user_func($this->lock_releaser, $this->wordpress_db, $lock_key);
                } catch (Throwable $error) {
                    // A failed release cannot be exposed as a sensitive error.
                }
            }
        }
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
        $has_fraction = strpos($value, '.') !== false;
        $format = $has_fraction ? '!Y-m-d\\TH:i:s.u\\Z' : '!Y-m-d\\TH:i:s\\Z';
        $date = DateTimeImmutable::createFromFormat($format, $value, new DateTimeZone('UTC'));
        $errors = DateTimeImmutable::getLastErrors();
        if ($date === false || ($errors !== false && ($errors['warning_count'] > 0 || $errors['error_count'] > 0))) {
            return null;
        }
        if ($date->format('Y-m-d\\TH:i:s') !== substr($value, 0, 19)) {
            return null;
        }
        if ($has_fraction && $date->format('u') !== str_pad(substr($value, 20, -1), 6, '0')) {
            return null;
        }

        return $date->format('Y-m-d\\TH:i:s.u\\Z');
    }

    /** @param array<string, mixed> $scope */
    private function validate_scope(array $scope): array
    {
        $expected = ['backfill_cutoff', 'backfill_start', 'limit', 'source_system'];
        $actual = array_map('strval', array_keys($scope));
        sort($actual, SORT_STRING);
        if ($actual !== $expected) {
            return ['ok' => false];
        }
        if (
            !is_string($scope['source_system'])
            || strlen($scope['source_system']) < 1
            || strlen($scope['source_system']) > 128
            || !preg_match('/^[A-Za-z0-9][A-Za-z0-9._:-]*$/D', $scope['source_system'])
            || !is_int($scope['limit'])
            || $scope['limit'] < 1
            || $scope['limit'] > EventSales_Woo_Order_Index_Manifest_Store::MAX_PAGE_SIZE
        ) {
            return ['ok' => false];
        }
        $start = $this->canonical_datetime($scope['backfill_start'] ?? null);
        $cutoff = $this->canonical_datetime($scope['backfill_cutoff'] ?? null);
        if ($start === null || $cutoff === null || strcmp($start, $cutoff) > 0) {
            return ['ok' => false];
        }

        return [
            'ok' => true,
            'source_system' => $scope['source_system'],
            'backfill_start' => $start,
            'backfill_cutoff' => $cutoff,
            'limit' => $scope['limit'],
        ];
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

    /** @param mixed $result */
    private function source_error_code($result, bool $preflight): string
    {
        $error = is_array($result) ? (string) ($result['error'] ?? '') : '';
        if (in_array($error, [
            'storage_authority_changed_at_boundary',
            'source_definition_changed_before_boundary',
            'source_definition_changed_at_boundary',
            'source_definition_changed_during_capture',
            'source_connection_identity_mismatch',
            'source_connection_is_not_writable_primary',
        ], true)) {
            return 'source_authority_changed';
        }

        return $preflight ? 'source_preflight_failed' : 'source_snapshot_failed';
    }
}
