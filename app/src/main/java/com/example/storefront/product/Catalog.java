package com.example.storefront.product;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Periodically restocks the catalog so load tests can run indefinitely. The catalog itself is seeded by the
 * Flyway migration V2__seed_catalog.sql. Restocking is safe to run on every replica at once: each update only
 * raises stock that is below the restock level.
 */
@Component
public class Catalog {

    private final ProductRepository products;
    private final int restockLevel;

    public Catalog(ProductRepository products, @Value("${storefront.restock-level}") int restockLevel) {
        this.products = products;
        this.restockLevel = restockLevel;
    }

    @Scheduled(fixedRateString = "${storefront.restock-interval-ms}", initialDelayString = "${storefront.restock-interval-ms}")
    public void restock() {
        for (Long id : products.findAllIdsOrdered()) {
            products.restockOne(id, restockLevel);
        }
    }
}
