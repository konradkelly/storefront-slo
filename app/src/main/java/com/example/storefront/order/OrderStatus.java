package com.example.storefront.order;

public enum OrderStatus {
    /** Stock is reserved and payment has not finished yet. */
    PENDING,
    PAID,
    /** Payment failed or the reservation expired; reserved stock has been returned. */
    FAILED
}
