package com.example.storefront.cart;

import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Index;
import jakarta.persistence.Table;

/** Carts live in Postgres (not memory) so the API can scale to multiple replicas. */
@Entity
@Table(name = "cart_items", indexes = @Index(columnList = "cartId"))
public class CartItem {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    private String cartId;
    private Long productId;
    private int quantity;

    protected CartItem() {
    }

    public CartItem(String cartId, Long productId, int quantity) {
        this.cartId = cartId;
        this.productId = productId;
        this.quantity = quantity;
    }

    public Long getId() { return id; }
    public String getCartId() { return cartId; }
    public Long getProductId() { return productId; }
    public int getQuantity() { return quantity; }
}
