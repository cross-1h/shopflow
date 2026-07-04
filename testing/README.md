# Testing: the pyramid

Phase 2 adds real testing, run in the pipeline, at three levels.

## Unit tests (fast, many)

Plain JUnit and Mockito tests of one class at a time, with no database or network. These already run in the `Test + Coverage` stage. Keep adding them for service logic.

## Integration tests (slower, fewer)

These prove a service works against real dependencies. `catalog-integration-test/ProductRepositoryIT.java` starts a real PostgreSQL in a throwaway container with Testcontainers and runs the repository against it.

To enable it, add to `catalog-service/pom.xml`:

```xml
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-testcontainers</artifactId>
  <scope>test</scope>
</dependency>
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>postgresql</artifactId>
  <scope>test</scope>
</dependency>
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>junit-jupiter</artifactId>
  <scope>test</scope>
</dependency>
```

Then copy the file to `catalog-service/src/test/java/com/shopflow/catalog/`. Docker must be running. The same pattern tests the Orders service against a real database.

## Contract tests (between services)

The Orders service calls the Catalog service. A contract test pins the shape of that call (the request and the JSON response) so a change to Catalog that would break Orders is caught before deploy, without running both services together. The common tools are Spring Cloud Contract or Pact. As a stretch task, add a contract for the `GET /products/{id}` call that Orders depends on.

## Smoke tests (after deploy)

`smoke-test.sh` hits the live system after a release: it lists products and places an order, and fails loudly if either does not work. Run it as the last step of a deploy:

```bash
./smoke-test.sh https://shop.YOURDOMAIN.com
```

## Why the shape matters

Many fast unit tests, fewer integration tests, very few end-to-end checks. That balance catches most bugs quickly and cheaply, and is exactly what you describe when an interviewer asks how you tested your work.
