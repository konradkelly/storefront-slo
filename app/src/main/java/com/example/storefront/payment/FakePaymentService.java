package com.example.storefront.payment;

import com.example.storefront.metrics.StorefrontMetrics;
import io.micrometer.core.instrument.Timer;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.util.concurrent.ThreadLocalRandom;

/**
 * Simulates a slow, occasionally failing payment provider.
 * Tune with PAYMENT_FAILURE_RATE (0.0 to 1.0) and PAYMENT_LATENCY_MS.
 */
@Service
public class FakePaymentService {

    public static class PaymentFailedException extends RuntimeException {
        public PaymentFailedException(String message) {
            super(message);
        }
    }

    private final double failureRate;
    private final long latencyMs;
    private final StorefrontMetrics metrics;

    public FakePaymentService(@Value("${storefront.payment.failure-rate}") double failureRate,
                              @Value("${storefront.payment.latency-ms}") long latencyMs,
                              StorefrontMetrics metrics) {
        this.failureRate = failureRate;
        this.latencyMs = latencyMs;
        this.metrics = metrics;
    }

    public void charge(long amountCents) {
        Timer.Sample sample = metrics.startPaymentTimer();
        String outcome = "success";
        try {
            long jitter = latencyMs / 2;
            long delay = latencyMs + (jitter > 0 ? ThreadLocalRandom.current().nextLong(-jitter, jitter + 1) : 0);
            Thread.sleep(Math.max(0, delay));
            if (ThreadLocalRandom.current().nextDouble() < failureRate) {
                outcome = "failure";
                throw new PaymentFailedException("Card declined");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            outcome = "failure";
            throw new PaymentFailedException("Payment interrupted");
        } finally {
            metrics.stopPaymentTimer(sample, outcome);
        }
    }
}
