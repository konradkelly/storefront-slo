package com.example.storefront.cart;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;

public interface CartItemRepository extends JpaRepository<CartItem, Long> {

    List<CartItem> findByCartId(String cartId);

    @Modifying
    @Query("delete from CartItem c where c.cartId = :cartId")
    void deleteByCartId(@Param("cartId") String cartId);
}
