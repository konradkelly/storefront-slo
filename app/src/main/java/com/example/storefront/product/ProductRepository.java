package com.example.storefront.product;

import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.transaction.annotation.Transactional;

public interface ProductRepository extends JpaRepository<Product, Long> {

    /** Atomic decrement. Returns 0 if there was not enough stock. */
    @Modifying
    @Query("update Product p set p.stock = p.stock - :qty where p.id = :id and p.stock >= :qty")
    int decrementStock(@Param("id") Long id, @Param("qty") int qty);

    @Query("select p.id from Product p order by p.id")
    List<Long> findAllIdsOrdered();

    /** Restocks one product in its own transaction, so the restocker never holds more than one row lock. */
    @Transactional
    @Modifying
    @Query("update Product p set p.stock = :level where p.id = :id and p.stock < :level")
    int restockOne(@Param("id") Long id, @Param("level") int level);
}
