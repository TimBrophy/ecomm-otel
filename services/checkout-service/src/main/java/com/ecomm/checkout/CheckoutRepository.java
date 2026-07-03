package com.ecomm.checkout;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

/**
 * Spring Data JPA repository for CheckoutRecord.
 *
 * Spring Boot auto-generates the implementation at startup.
 * Additional query methods (e.g. findByEmail, findByOrderId) can be added
 * here when needed for the demo without writing any SQL.
 */
@Repository
public interface CheckoutRepository extends JpaRepository<CheckoutRecord, Long> {
}
