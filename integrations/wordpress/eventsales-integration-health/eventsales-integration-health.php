<?php
/**
 * Plugin Name: EventSales Integration Health
 * Description: Read-only Site Health observability for EventSales WordPress producer integrations.
 * Version: 0.1.0
 * Requires at least: 6.4
 * Requires PHP: 8.0
 * Author: EventSales
 * License: GPL-2.0-or-later
 */

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

require_once __DIR__ . '/includes/integration-health.php';

if (function_exists('add_filter')) {
    EventSales_Integration_Health_Site_Health::register_hooks();
}
