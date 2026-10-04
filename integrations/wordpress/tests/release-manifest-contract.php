<?php

declare(strict_types=1);

/**
 * Shared release-manifest field contracts (WP-SOURCE-05).
 */

function suite_release_id_error(?string $releaseId): ?string
{
    if ($releaseId === null || $releaseId === '') {
        return 'suite_release_id missing';
    }
    if (!preg_match(
        '/^(\d{4})\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])\.([1-9][0-9]*)$/',
        $releaseId,
        $matches
    )) {
        return 'suite_release_id format invalid';
    }
    $year = (int) $matches[1];
    $month = (int) $matches[2];
    $day = (int) $matches[3];
    if (!checkdate($month, $day, $year)) {
        return 'suite_release_id calendar date invalid';
    }

    return null;
}

function git_identity_sha_error(string $label, mixed $value): ?string
{
    if (!is_string($value) || preg_match('/^[0-9a-f]{40}$/', strtolower($value)) !== 1) {
        return "{$label} must be 40-character lowercase hex";
    }

    return null;
}

/** @return list<string> */
function release_manifest_contract_errors(array $manifest, string $label): array
{
    $errors = [];

    if (($manifest['release_manifest_format_version'] ?? '') !== '1') {
        $errors[] = "{$label} release_manifest_format_version must be 1";
    }

    $releaseIdError = suite_release_id_error(isset($manifest['suite_release_id']) ? (string) $manifest['suite_release_id'] : null);
    if ($releaseIdError !== null) {
        $errors[] = "{$label} {$releaseIdError}";
    }

    $releaseId = (string) ($manifest['suite_release_id'] ?? '');
    $suggestedTag = (string) ($manifest['suggested_tag'] ?? '');
    if ($releaseId !== '' && $suggestedTag !== 'eventsales-wp-' . $releaseId) {
        $errors[] = "{$label} suggested_tag must equal eventsales-wp-<suite_release_id>";
    }

    foreach (['source_commit', 'source_tree', 'canonical_main_at_build'] as $field) {
        $fieldError = git_identity_sha_error("{$label} {$field}", $manifest[$field] ?? null);
        if ($fieldError !== null) {
            $errors[] = $fieldError;
        }
    }

    $requiresWordPress = (string) ($manifest['requires_wordpress'] ?? '');
    $requiresPhp = (string) ($manifest['requires_php'] ?? '');
    if ($requiresWordPress === '' || !preg_match('/^\d+(?:\.\d+)*$/', $requiresWordPress)) {
        $errors[] = "{$label} requires_wordpress must be a dotted version string";
    }
    if ($requiresPhp === '' || !preg_match('/^\d+(?:\.\d+)*$/', $requiresPhp)) {
        $errors[] = "{$label} requires_php must be a dotted version string";
    }

    if (!is_array($manifest['plugins'] ?? null)) {
        $errors[] = "{$label} plugins must be an array";

        return $errors;
    }
    if (count($manifest['plugins']) !== 4) {
        $errors[] = "{$label} must list exactly four plugins";
    }

    foreach ($manifest['plugins'] as $plugin) {
        if (!is_array($plugin)) {
            $errors[] = "{$label} plugin entry must be object";
            continue;
        }
        foreach (['slug', 'marketing_version', 'archive_sha256', 'archive_filename'] as $field) {
            if (!isset($plugin[$field])) {
                $errors[] = "{$label} plugin missing {$field}";
            }
        }
        $sha = isset($plugin['archive_sha256']) ? (string) $plugin['archive_sha256'] : '';
        if (!preg_match('/^[0-9a-f]{64}$/', $sha)) {
            $errors[] = "{$label} invalid archive_sha256 for " . ($plugin['slug'] ?? '?');
        }
    }

    return $errors;
}
