package com.example.storefront.order;

import com.example.storefront.cart.CartItem;
import com.example.storefront.cart.CartItemRepository;
import com.example.storefront.metrics.StorefrontMetrics;
import com.example.storefront.payment.FakePaymentService;
import com.example.storefront.product.Product;
import com.example.storefront.product.ProductRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Duration;
import java.time.Instant;
import java.util.Comparator;
import java.util.List;

/**
 * Checkout runs in one of two modes, chosen with CHECKOUT_MODE:
 *
 * <ul>
 *   <li><b>single-tx</b>: reserve stock, charge payment, and record the order in one transaction.
 *       The row locks taken by the stock decrement are held for the whole payment call, so concurrent
 *       checkouts that share a product queue behind each other, and each one also holds a pooled
 *       connection while it waits. Kept on purpose so you can compare it against the fix.</li>
 *   <li><b>saga</b> (default): reserve stock and record a PENDING order in a short transaction, charge
 *       payment with no transaction open, then settle the order in a second short transaction.
 *       A failed payment runs a compensating step that returns the stock.</li>
 * </ul>
 *
 * Both modes lock product rows in id order, so two carts holding the same products in a different
 * order cannot deadlock.
 */
@Service
public class OrderService {

    private static final Logger log = LoggerFactory.getLogger(OrderService.class);

    public static class EmptyCartException extends RuntimeException {
        public EmptyCartException() {
            super("Cart is empty");
        }
    }

    public static class OutOfStockException extends RuntimeException {
        public OutOfStockException(Long productId) {
            super("Product " + productId + " is out of stock");
        }
    }

    /** Payment succeeded after the reservation had already been released. A real system would refund. */
    public static class ReservationExpiredException extends RuntimeException {
        public ReservationExpiredException(Long orderId) {
            super("Reservation for order " + orderId + " expired before payment completed");
        }
    }

    private record Reservation(Long orderId, long totalCents) {
    }

    private final CartItemRepository cart;
    private final ProductRepository products;
    private final OrderRepository orders;
    private final OrderLineRepository lines;
    private final FakePaymentService payment;
    private final StorefrontMetrics metrics;
    private final TransactionTemplate tx;
    private final boolean saga;
    private final Duration reservationTimeout;

    public OrderService(CartItemRepository cart, ProductRepository products, OrderRepository orders,
                        OrderLineRepository lines, FakePaymentService payment, StorefrontMetrics metrics,
                        TransactionTemplate tx,
                        @Value("${storefront.checkout-mode}") String checkoutMode,
                        @Value("${storefront.reservation-timeout-ms}") long reservationTimeoutMs) {
        this.cart = cart;
        this.products = products;
        this.orders = orders;
        this.lines = lines;
        this.payment = payment;
        this.metrics = metrics;
        this.tx = tx;
        this.saga = switch (checkoutMode) {
            case "saga" -> true;
            case "single-tx" -> false;
            default -> throw new IllegalArgumentException(
                    "storefront.checkout-mode must be 'saga' or 'single-tx', got '" + checkoutMode + "'");
        };
        this.reservationTimeout = Duration.ofMillis(reservationTimeoutMs);
        log.info("Checkout mode: {}", checkoutMode);
    }

    public CustomerOrder checkout(String cartId) {
        return saga ? checkoutWithReservation(cartId) : checkoutInOneTransaction(cartId);
    }

    private CustomerOrder checkoutInOneTransaction(String cartId) {
        return tx.execute(status -> {
            List<CartItem> items = cartItems(cartId);
            long total = takeStock(items);
            payment.charge(total);
            CustomerOrder order = orders.save(new CustomerOrder(cartId, total, OrderStatus.PAID));
            cart.deleteByCartId(cartId);
            return order;
        });
    }

    private CustomerOrder checkoutWithReservation(String cartId) {
        // 1. Reserve: locks are held only for the few milliseconds this transaction takes.
        Reservation reservation = tx.execute(status -> {
            List<CartItem> items = cartItems(cartId);
            long total = takeStock(items);
            CustomerOrder order = orders.save(new CustomerOrder(cartId, total, OrderStatus.PENDING));
            lines.saveAll(items.stream()
                    .map(i -> new OrderLine(order.getId(), i.getProductId(), i.getQuantity()))
                    .toList());
            return new Reservation(order.getId(), total);
        });

        // 2. Charge with no transaction or connection held. A real provider call would pass the
        //    order id as an idempotency key so a retry cannot charge twice.
        try {
            payment.charge(reservation.totalCents());
        } catch (RuntimeException e) {
            tx.executeWithoutResult(status -> release(reservation.orderId()));
            throw e;
        }

        // 3. Settle.
        return tx.execute(status -> {
            if (orders.settle(reservation.orderId(), OrderStatus.PAID) == 0) {
                log.warn("Order {} was charged after its reservation expired; it needs a refund",
                        reservation.orderId());
                throw new ReservationExpiredException(reservation.orderId());
            }
            cart.deleteByCartId(cartId);
            return orders.findById(reservation.orderId()).orElseThrow();
        });
    }

    /**
     * Releases reservations whose checkout never finished, for example because the pod died mid-payment.
     * Safe to run on every replica: settle() lets only one of them win each order.
     */
    @Scheduled(fixedDelayString = "${storefront.reservation-sweep-interval-ms}")
    public void releaseExpiredReservations() {
        releaseReservationsCreatedBefore(Instant.now().minus(reservationTimeout));
    }

    /** Returns how many reservations were released. */
    public int releaseReservationsCreatedBefore(Instant cutoff) {
        int released = 0;
        for (Long orderId : orders.findPendingIdsCreatedBefore(cutoff)) {
            if (Boolean.TRUE.equals(tx.execute(status -> release(orderId)))) {
                metrics.reservationExpired();
                released++;
            }
        }
        if (released > 0) {
            log.warn("Released {} expired reservation(s)", released);
        }
        return released;
    }

    /** Marks the order FAILED and returns its stock, unless it was already settled. Requires a transaction. */
    private boolean release(Long orderId) {
        if (orders.settle(orderId, OrderStatus.FAILED) == 0) {
            return false;
        }
        List<OrderLine> reserved = lines.findByOrderId(orderId).stream()
                .sorted(Comparator.comparing(OrderLine::getProductId))
                .toList();
        for (OrderLine line : reserved) {
            products.returnStock(line.getProductId(), line.getQuantity());
        }
        return true;
    }

    private List<CartItem> cartItems(String cartId) {
        List<CartItem> items = cart.findByCartId(cartId);
        if (items.isEmpty()) {
            throw new EmptyCartException();
        }
        return items;
    }

    /** Decrements stock for every item, locking rows in product id order. Returns the total in cents. */
    private long takeStock(List<CartItem> items) {
        long total = 0;
        for (CartItem item : items.stream().sorted(Comparator.comparing(CartItem::getProductId)).toList()) {
            Product product = products.findById(item.getProductId())
                    .orElseThrow(() -> new OutOfStockException(item.getProductId()));
            if (products.decrementStock(product.getId(), item.getQuantity()) == 0) {
                throw new OutOfStockException(product.getId());
            }
            total += product.getPriceCents() * item.getQuantity();
        }
        return total;
    }
}
