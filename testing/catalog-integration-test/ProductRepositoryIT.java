package com.shopflow.catalog;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Integration test. Unlike a unit test, this starts a REAL PostgreSQL in a
 * throwaway Docker container (via Testcontainers) and runs the repository
 * against it. That proves the data layer works against the actual database,
 * not a fake. Requires Docker to be running when you run the tests.
 *
 * To use this, add to catalog-service/pom.xml (test scope):
 *   spring-boot-testcontainers, org.testcontainers:postgresql, org.testcontainers:junit-jupiter
 * and place this file at:
 *   catalog-service/src/test/java/com/shopflow/catalog/ProductRepositoryIT.java
 */
@DataJpaTest
@Testcontainers
@org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase(replace = org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase.Replace.NONE)
class ProductRepositoryIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16");

    @Autowired
    private ProductRepository repository;

    @Test
    void savesAndReadsBackProducts() {
        repository.saveAll(List.of(
                new Product("Test Item A", 10.0, 5),
                new Product("Test Item B", 20.0, 3)
        ));

        List<Product> all = repository.findAll();

        assertThat(all).hasSize(2);
        assertThat(all).extracting(Product::getName)
                .containsExactlyInAnyOrder("Test Item A", "Test Item B");
    }
}
