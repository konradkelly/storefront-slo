package com.example.storefront.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;

public interface OrderRepository extends JpaRepository<CustomerOrder, Long> {

    /**
     * Moves a PENDING order to a final status. Returns 0 if something else (the other outcome, or the
     * expired-reservation sweeper on another replica) already finalized it, so each order is settled once.
     */
    @Modifying
    @Query("update CustomerOrder o set o.status = :to where o.id = :id and o.status = com.example.storefront.order.OrderStatus.PENDING")
    int settle(@Param("id") Long id, @Param("to") OrderStatus to);

    @Query("select o.id from CustomerOrder o where o.status = com.example.storefront.order.OrderStatus.PENDING and o.createdAt < :cutoff")
    List<Long> findPendingIdsCreatedBefore(@Param("cutoff") Instant cutoff);
}
