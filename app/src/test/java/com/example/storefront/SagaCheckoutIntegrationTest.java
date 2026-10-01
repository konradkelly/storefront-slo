package com.example.storefront;

import com.example.storefront.order.CustomerOrder;
import com.example.storefront.order.OrderLine;
import com.example.storefront.order.OrderLineRepository;
import com.example.storefront.order.OrderRepository;
import com.example.storefront.order.OrderService;
import com.example.storefront.order.OrderStatus;
import com.example.storefront.product.ProductRepository;
import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.test.context.TestPropertySource;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Behavior specific to the saga checkout. Payment takes 200 to 600ms here so that holding row locks
 * through the payment call would be impossible to miss.
 */
@TestPropertySource(properties = {
        "storefront.checkout-mode=saga",
        "storefront.payment.failure-rate=0",
        "storefront.payment.latency-ms=400"})
class SagaCheckoutIntegrationTest extends IntegrationTest {

    @Autowired
    OrderService orderService;

    @Autowired
    OrderRepository orders;

    @Autowired
    OrderLineRepository lines;

    @Autowired
    ProductRepository products;

    @Autowired
    TransactionTemplate tx;

    /**
     * The fix itself. Eight checkouts of the same product would take at least 8 x 200ms = 1.6s if each
     * held the product's row lock through payment, as single-tx does. With the lock released before
     * payment they overlap, so the batch finishes in about one payment's time.
     */
    @Test
    void concurrentCheckoutsOfTheSameProductDoNotQueueBehindPayment() {
        long productId = firstProductId();
        checkout(cartWith(productId, 1)); // warm up the request path so JIT time does not count
        List<String> carts = IntStream.range(0, 8).mapToObj(i -> cartWith(productId, 1)).toList();

        Instant start = Instant.now();
        List<HttpStatus> statuses = carts.stream()
                .map(cartId -> CompletableFuture.supplyAsync(() -> checkout(cartId)))
                .toList().stream()
                .map(CompletableFuture::join)
                .map(res -> HttpStatus.valueOf(res.getStatusCode().value()))
                .toList();
        Duration elapsed = Duration.between(start, Instant.now());

        assertThat(statuses).containsOnly(HttpStatus.CREATED);
        // Lower bound proves the 400ms payment latency is in effect, so the upper bound means something.
        assertThat(elapsed).isBetween(Duration.ofMillis(200), Duration.ofMillis(1300));
    }

    @Test
    void reservationLeftByACrashIsReleasedAndCannotBePaidAfterwards() {
        long productId = firstProductId();
        int stockBefore = stockOf(productId);
        double expiredBefore = registry.get("storefront.reservations.expired").counter().count();
        // What a pod leaves behind if it dies between reserving and settling.
        Long orderId = tx.execute(status -> {
            products.decrementStock(productId, 4);
            CustomerOrder order = orders.save(new CustomerOrder("test-crashed", 400, OrderStatus.PENDING));
            lines.save(new OrderLine(order.getId(), productId, 4));
            return order.getId();
        });
        assertThat(stockOf(productId)).isEqualTo(stockBefore - 4);

        // Not yet expired: the sweeper's normal cutoff leaves it alone.
        orderService.releaseExpiredReservations();
        assertThat(orders.findById(orderId).orElseThrow().getStatus()).isEqualTo(OrderStatus.PENDING);

        int released = orderService.releaseReservationsCreatedBefore(Instant.now().plusSeconds(1));

        assertThat(released).isGreaterThanOrEqualTo(1);
        assertThat(orders.findById(orderId).orElseThrow().getStatus()).isEqualTo(OrderStatus.FAILED);
        assertThat(stockOf(productId)).isEqualTo(stockBefore);
        assertThat(registry.get("storefront.reservations.expired").counter().count())
                .isEqualTo(expiredBefore + released);
        // A late payment confirmation must not resurrect it, and a second sweep must not return stock twice.
        Integer lateSettle = tx.execute(status -> orders.settle(orderId, OrderStatus.PAID));
        assertThat(lateSettle).isZero();
        assertThat(orderService.releaseReservationsCreatedBefore(Instant.now().plusSeconds(1))).isZero();
        assertThat(stockOf(productId)).isEqualTo(stockBefore);
    }

    @Test
    void successfulCheckoutRecordsTheReservedLines() {
        long productId = firstProductId();

        ResponseEntity<JsonNode> res = checkout(cartWith(productId, 2));

        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        List<OrderLine> reserved = lines.findByOrderId(res.getBody().get("id").asLong());
        assertThat(reserved).singleElement().satisfies(line -> {
            assertThat(line.getProductId()).isEqualTo(productId);
            assertThat(line.getQuantity()).isEqualTo(2);
        });
    }
}
