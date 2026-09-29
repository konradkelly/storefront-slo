package com.example.storefront.cart;

import com.example.storefront.metrics.StorefrontMetrics;
import com.example.storefront.product.ProductRepository;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;

@RestController
@RequestMapping("/cart")
public class CartController {

    public record AddItemRequest(String cartId, Long productId, int quantity) {
    }

    private final CartItemRepository cart;
    private final ProductRepository products;
    private final StorefrontMetrics metrics;

    public CartController(CartItemRepository cart, ProductRepository products, StorefrontMetrics metrics) {
        this.cart = cart;
        this.products = products;
        this.metrics = metrics;
    }

    @PostMapping("/items")
    @ResponseStatus(HttpStatus.CREATED)
    public CartItem add(@RequestBody AddItemRequest req) {
        if (req.cartId() == null || req.cartId().isBlank() || req.productId() == null || req.quantity() < 1) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "cartId, productId, and quantity >= 1 are required");
        }
        if (!products.existsById(req.productId())) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Product not found");
        }
        CartItem saved = cart.save(new CartItem(req.cartId(), req.productId(), req.quantity()));
        metrics.cartItemAdded();
        return saved;
    }

    @GetMapping("/{cartId}")
    public List<CartItem> get(@PathVariable String cartId) {
        return cart.findByCartId(cartId);
    }
}
