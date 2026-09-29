package com.example.storefront.metrics;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.DistributionSummary;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * All custom business metrics live here so names and labels stay consistent.
 *
 * Prometheus names after Micrometer converts them:
 *   storefront_orders_created_total{status}
 *   storefront_cart_items_added_total
 *   storefront_order_value_dollars_sum / _count / _max
 *   storefront_payment_duration_seconds_bucket{outcome}
 *
 * Labels are kept to small, fixed sets. Never label by user, cart, or order id.
 */
@Component
public class StorefrontMetrics {

    public static final List<String> ORDER_STATUSES = List.of("success", "payment_failed", "out_of_stock");

    private final MeterRegistry registry;
    private final Counter cartItemsAdded;
    private final DistributionSummary orderValue;

    public StorefrontMetrics(MeterRegistry registry) {
        this.registry = registry;
        this.cartItemsAdded = Counter.builder("storefront.cart.items.added")
                .description("Items added to carts")
                .register(registry);
        this.orderValue = DistributionSummary.builder("storefront.order.value")
                .baseUnit("dollars")
                .description("Value of successful orders")
                .register(registry);
        // Register every status up front so each series exists at 0.
        // Otherwise rate() has nothing to work with until the first failure happens.
        ORDER_STATUSES.forEach(this::ordersCounter);
    }

    private Counter ordersCounter(String status) {
        return Counter.builder("storefront.orders.created")
                .description("Checkout attempts by result")
                .tag("status", status)
                .register(registry);
    }

    public void orderCreated(String status) {
        ordersCounter(status).increment();
    }

    public void cartItemAdded() {
        cartItemsAdded.increment();
    }

    public void recordOrderValue(long totalCents) {
        orderValue.record(totalCents / 100.0);
    }

    public Timer.Sample startPaymentTimer() {
        return Timer.start(registry);
    }

    public void stopPaymentTimer(Timer.Sample sample, String outcome) {
        sample.stop(Timer.builder("storefront.payment.duration")
                .description("Time spent in the payment provider")
                .tag("outcome", outcome)
                .publishPercentileHistogram()
                .register(registry));
    }
}
