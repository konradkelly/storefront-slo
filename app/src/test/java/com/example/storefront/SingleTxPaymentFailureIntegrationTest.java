package com.example.storefront;

import org.springframework.test.context.TestPropertySource;

/** Runs every payment failure test again against the original single-transaction checkout. */
@TestPropertySource(properties = "storefront.checkout-mode=single-tx")
class SingleTxPaymentFailureIntegrationTest extends PaymentFailureIntegrationTest {
}
