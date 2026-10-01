package com.example.storefront;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.test.context.TestPropertySource;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

@TestPropertySource(properties = "storefront.payment.failure-rate=0")
class CheckoutIntegrationTest extends IntegrationTest {

    @Test
    void successfulCheckoutCreatesOrderDecrementsStockAndCountsSuccess() {
        long productId = firstProductId();
        long price = product(productId).get("priceCents").asLong();
        int stockBefore = stockOf(productId);
        double successBefore = checkouts("success");
        String cartId = cartWith(productId, 2);

        ResponseEntity<JsonNode> res = checkout(cartId);

        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        assertThat(res.getBody().get("totalCents").asLong()).isEqualTo(price * 2);
        assertThat(stockOf(productId)).isEqualTo(stockBefore - 2);
        assertThat(cart(cartId)).isEmpty();
        assertThat(checkouts("success")).isEqualTo(successBefore + 1);
    }

    @Test
    void emptyCartIsRejectedWithoutCountingACheckout() {
        double total = checkouts("success") + checkouts("payment_failed") + checkouts("out_of_stock");

        ResponseEntity<JsonNode> res = checkout("test-never-filled");

        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(checkouts("success") + checkouts("payment_failed") + checkouts("out_of_stock")).isEqualTo(total);
    }

    @Test
    void outOfStockReturns409AndLeavesStockUntouched() {
        long productId = firstProductId();
        int stockBefore = stockOf(productId);
        double outOfStockBefore = checkouts("out_of_stock");
        String cartId = cartWith(productId, RESTOCK_LEVEL + 1);

        ResponseEntity<JsonNode> res = checkout(cartId);

        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.CONFLICT);
        assertThat(stockOf(productId)).isEqualTo(stockBefore);
        assertThat(checkouts("out_of_stock")).isEqualTo(outOfStockBefore + 1);
    }

    @Test
    void checkoutRequiresCartId() {
        ResponseEntity<JsonNode> res = http.postForEntity("/orders", Map.of(), JsonNode.class);

        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
    }

    /**
     * Guards the names that the README, dashboard, and alert rules query. Micrometer's Prometheus naming
     * can differ from the meter name (a trailing "_created" is stripped, for example), so check the scrape.
     */
    @Test
    void prometheusScrapeExposesDocumentedMetricNames() {
        checkout(cartWith(firstProductId(), 1));

        String scrape = http.getForObject("/actuator/prometheus", String.class);

        assertThat(scrape).contains(
                "storefront_checkouts_total{",
                "storefront_cart_items_added_total{",
                "storefront_order_value_dollars_sum{",
                "storefront_order_value_dollars_count{",
                "storefront_payment_duration_seconds_bucket{",
                "http_server_requests_seconds_bucket{",
                "hikaricp_connections_active{",
                "hikaricp_connections_pending{");
        assertThat(scrape).contains("application=\"storefront-api\"");
    }
}
