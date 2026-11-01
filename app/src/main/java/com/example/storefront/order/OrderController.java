package com.example.storefront.order;

import com.example.storefront.metrics.StorefrontMetrics;
import com.example.storefront.payment.FakePaymentService.PaymentFailedException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

@RestController
@RequestMapping("/orders")
public class OrderController {

    public record CheckoutRequest(String cartId) {
    }

    private final OrderService orderService;
    private final StorefrontMetrics metrics;
    private final boolean bugMode;

    public OrderController(OrderService orderService, StorefrontMetrics metrics,
                           @Value("${storefront.bug-mode}") boolean bugMode) {
        this.orderService = orderService;
        this.metrics = metrics;
        this.bugMode = bugMode;
    }

    // Metrics are recorded here, after the transaction has committed or rolled back,
    // so a "success" count always means the order really exists.
    @PostMapping
    public ResponseEntity<?> checkout(@RequestBody CheckoutRequest req) {
        if (req.cartId() == null || req.cartId().isBlank()) {
            return ResponseEntity.badRequest().body(Map.of("error", "cartId is required"));
        }
        // The canary experiment's bad release (storefront.bug-mode): a 500 that no business counter sees, like an
        // unhandled exception would be.
        if (bugMode && ThreadLocalRandom.current().nextDouble() < 0.1) {
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of("error", "BUG_MODE"));
        }
        try {
            CustomerOrder order = orderService.checkout(req.cartId());
            metrics.orderCreated("success");
            metrics.recordOrderValue(order.getTotalCents());
            return ResponseEntity.status(HttpStatus.CREATED).body(order);
        } catch (OrderService.OutOfStockException e) {
            metrics.orderCreated("out_of_stock");
            return ResponseEntity.status(HttpStatus.CONFLICT).body(Map.of("error", e.getMessage()));
        } catch (PaymentFailedException e) {
            metrics.orderCreated("payment_failed");
            return ResponseEntity.status(HttpStatus.PAYMENT_REQUIRED).body(Map.of("error", e.getMessage()));
        } catch (OrderService.EmptyCartException e) {
            return ResponseEntity.badRequest().body(Map.of("error", e.getMessage()));
        }
    }
}
