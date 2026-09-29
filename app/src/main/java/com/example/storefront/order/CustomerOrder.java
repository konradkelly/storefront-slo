package com.example.storefront.order;

import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

@Entity
@Table(name = "orders")
public class CustomerOrder {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    private String cartId;
    private long totalCents;
    private Instant createdAt;

    protected CustomerOrder() {
    }

    public CustomerOrder(String cartId, long totalCents) {
        this.cartId = cartId;
        this.totalCents = totalCents;
        this.createdAt = Instant.now();
    }

    public Long getId() { return id; }
    public String getCartId() { return cartId; }
    public long getTotalCents() { return totalCents; }
    public Instant getCreatedAt() { return createdAt; }
}
