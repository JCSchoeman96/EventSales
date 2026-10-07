<?php
/**
 * Plugin Name: EventSales Integration Health
 * Description: Read-only Site Health observability for EventSales WordPress producer integrations.
 * Version: 0.1.3
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

require_once __DIR__ . '/includes/integration-health.php';
require_once __DIR__ . '/includes/update-discovery.php';
require_once __DIR__ . '/includes/verified-package-delivery.php';

if (function_exists('add_filter')) {
    EventSales_Integration_Health_Site_Health::register_hooks();
    EventSales_WP_Update_Discovery::register_hooks();
    EventSales_WP_Verified_Package_Delivery::register_hooks();
}
