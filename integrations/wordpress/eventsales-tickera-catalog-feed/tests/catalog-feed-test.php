<?php

declare(strict_types=1);

$plugin = file_get_contents(dirname(__DIR__) . '/eventsales-tickera-catalog-feed.php');

if ($plugin === false) {
    fwrite(STDERR, "Unable to read catalog feed plugin.\n");
    exit(1);
}

$required = [
    "'2026-07-22.v2'",
    "'event_status_classification'",
    "'product_status_classification'",
    "'variation_status_classification'",
    "'ticket_template_present'",
    "'subscription_classification'",
    "'product_semantics'",
    "'target_observation'",
    "'risk_codes'",
    "'unknown_product_semantics'",
];

foreach ($required as $needle) {
    if (strpos($plugin, $needle) === false) {
        fwrite(STDERR, "Missing v2 feed contract token: {$needle}\n");
        exit(1);
    }
}

echo "catalog feed v2 contract: ok\n";
