package com.example.storefront;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.test.context.TestPropertySource;

import static org.assertj.core.api.Assertions.assertThat;

/** Every charge fails, so each checkout exercises the rollback path. */
@TestPropertySource(properties = "storefront.payment.failure-rate=1.0")
class PaymentFailureIntegrationTest extends IntegrationTest {

    @Test
    void failedPaymentReturns402RollsBackStockAndKeepsCart() {
        long productId = firstProductId();
        int stockBefore = stockOf(productId);
        double failedBefore = checkouts("payment_failed");
        double failedChargesBefore = paymentTimings("failure");
        String cartId = cartWith(productId, 3);

        ResponseEntity<JsonNode> res = checkout(cartId);

        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.PAYMENT_REQUIRED);
        // The stock decrement ran before the charge; the transaction must undo it.
        assertThat(stockOf(productId)).isEqualTo(stockBefore);
        assertThat(cart(cartId)).hasSize(1);
        assertThat(checkouts("payment_failed")).isEqualTo(failedBefore + 1);
        assertThat(paymentTimings("failure")).isEqualTo(failedChargesBefore + 1);
    }
}
