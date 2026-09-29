package com.example.storefront.order;

import com.example.storefront.cart.CartItem;
import com.example.storefront.cart.CartItemRepository;
import com.example.storefront.payment.FakePaymentService;
import com.example.storefront.product.Product;
import com.example.storefront.product.ProductRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
public class OrderService {

    public static class EmptyCartException extends RuntimeException {
        public EmptyCartException() {
            super("Cart is empty");
        }
    }

    public static class OutOfStockException extends RuntimeException {
        public OutOfStockException(Long productId) {
            super("Product " + productId + " is out of stock");
        }
    }

    private final CartItemRepository cart;
    private final ProductRepository products;
    private final OrderRepository orders;
    private final FakePaymentService payment;

    public OrderService(CartItemRepository cart, ProductRepository products,
                        OrderRepository orders, FakePaymentService payment) {
        this.cart = cart;
        this.products = products;
        this.orders = orders;
        this.payment = payment;
    }

    /**
     * Reserves stock, charges payment, and records the order in one transaction.
     * Any exception rolls back the stock decrements.
     *
     * Note: the payment call happens while the transaction (and its DB connection) is open.
     * That is a realistic mistake, and it is deliberate here: raise PAYMENT_LATENCY_MS under
     * load and watch the HikariCP pool saturate on your dashboard.
     */
    @Transactional
    public CustomerOrder checkout(String cartId) {
        List<CartItem> items = cart.findByCartId(cartId);
        if (items.isEmpty()) {
            throw new EmptyCartException();
        }
        long total = 0;
        for (CartItem item : items) {
            Product product = products.findById(item.getProductId())
                    .orElseThrow(() -> new OutOfStockException(item.getProductId()));
            if (products.decrementStock(product.getId(), item.getQuantity()) == 0) {
                throw new OutOfStockException(product.getId());
            }
            total += product.getPriceCents() * item.getQuantity();
        }
        payment.charge(total);
        CustomerOrder order = orders.save(new CustomerOrder(cartId, total));
        cart.deleteByCartId(cartId);
        return order;
    }
}
