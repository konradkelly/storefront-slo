package com.example.storefront;

import com.fasterxml.jackson.databind.JsonNode;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.actuate.observability.AutoConfigureObservability;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Boots the full app against a real Postgres. Subclasses pick the payment failure rate, which gives each
 * its own Spring context; the container is a JVM-wide singleton so both contexts share it.
 *
 * AutoConfigureObservability is required because Spring Boot tests otherwise replace the Prometheus
 * registry with a simple one, and these tests check what Prometheus actually scrapes.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "storefront.payment.latency-ms=0",
        "storefront.restock-level=50",
        // Keep the restocker out of the way so stock assertions are stable.
        "storefront.restock-interval-ms=3600000",
        "storefront.reservation-sweep-interval-ms=3600000"})
@AutoConfigureObservability
public abstract class IntegrationTest {

    protected static final int RESTOCK_LEVEL = 50;

    @ServiceConnection
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16.14");

    static {
        POSTGRES.start();
    }

    @Autowired
    protected TestRestTemplate http;

    @Autowired
    protected MeterRegistry registry;

    protected long firstProductId() {
        JsonNode products = http.getForObject("/products", JsonNode.class);
        assertThat(products).isNotEmpty();
        return products.get(0).get("id").asLong();
    }

    protected JsonNode product(long id) {
        return http.getForObject("/products/" + id, JsonNode.class);
    }

    protected int stockOf(long productId) {
        return product(productId).get("stock").asInt();
    }

    /** Creates a fresh cart holding one line item and returns its id. */
    protected String cartWith(long productId, int quantity) {
        String cartId = "test-" + UUID.randomUUID();
        ResponseEntity<JsonNode> res = http.postForEntity("/cart/items",
                Map.of("cartId", cartId, "productId", productId, "quantity", quantity), JsonNode.class);
        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        return cartId;
    }

    protected ResponseEntity<JsonNode> checkout(String cartId) {
        return http.postForEntity("/orders", Map.of("cartId", cartId), JsonNode.class);
    }

    protected JsonNode cart(String cartId) {
        return http.getForObject("/cart/" + cartId, JsonNode.class);
    }

    protected double checkouts(String status) {
        return registry.get("storefront.checkouts").tag("status", status).counter().count();
    }

    protected double paymentTimings(String outcome) {
        var timer = registry.find("storefront.payment.duration").tag("outcome", outcome).timer();
        return timer == null ? 0 : timer.count();
    }
}
