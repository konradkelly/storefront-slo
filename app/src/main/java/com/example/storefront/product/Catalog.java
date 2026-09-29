package com.example.storefront.product;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.CommandLineRunner;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.List;

/** Seeds a small catalog and periodically restocks it so load tests can run indefinitely. */
@Component
public class Catalog implements CommandLineRunner {

    private final ProductRepository products;
    private final int restockLevel;

    public Catalog(ProductRepository products, @Value("${storefront.restock-level}") int restockLevel) {
        this.products = products;
        this.restockLevel = restockLevel;
    }

    @Override
    public void run(String... args) {
        if (products.count() > 0) {
            return;
        }
        products.saveAll(List.of(
                new Product("Trail Runner Shoes", 12999, restockLevel),
                new Product("Rain Shell Jacket", 18950, restockLevel),
                new Product("Insulated Water Bottle", 3495, restockLevel),
                new Product("Daypack 22L", 8900, restockLevel),
                new Product("Merino Wool Socks", 2295, restockLevel),
                new Product("Headlamp", 4499, restockLevel),
                new Product("Trekking Poles", 11995, restockLevel),
                new Product("Camp Mug", 1899, restockLevel)));
    }

    @Scheduled(fixedRateString = "${storefront.restock-interval-ms}", initialDelayString = "${storefront.restock-interval-ms}")
    public void restock() {
        for (Long id : products.findAllIdsOrdered()) {
            products.restockOne(id, restockLevel);
        }
    }
}
