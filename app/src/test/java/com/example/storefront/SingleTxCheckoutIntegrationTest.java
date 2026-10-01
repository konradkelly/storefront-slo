package com.example.storefront;

import org.springframework.test.context.TestPropertySource;

/** Runs every checkout test again against the original single-transaction checkout. */
@TestPropertySource(properties = "storefront.checkout-mode=single-tx")
class SingleTxCheckoutIntegrationTest extends CheckoutIntegrationTest {
}
