package org.wsmt.worker;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

@Component
public class ProductListener {

    private static final Logger log = LoggerFactory.getLogger(ProductListener.class);
    private final ProductRepository repo;

    public ProductListener(ProductRepository repo) {
        this.repo = repo;
    }

    @RabbitListener(queues = "products.commands")
    @Transactional
    public Object handle(Map<String, Object> command) {
        String op = String.valueOf(command.get("op"));
        log.info("Received op={}", op);
        return switch (op) {
            case "LIST"   -> repo.findAll().stream().map(this::toMap).toList();
            case "GET"    -> getOne(asLong(command.get("id")));
            case "CREATE" -> toMap(repo.save(fromPayload(null, asMap(command.get("payload")))));
            case "UPDATE" -> update(asLong(command.get("id")), asMap(command.get("payload")));
            case "DELETE" -> { repo.deleteById(asLong(command.get("id"))); yield Map.of("deleted", true); }
            default -> Map.of("error", "unknown op: " + op);
        };
    }

    private Object getOne(Long id) {
        Optional<Product> p = repo.findById(id);
        return p.map(this::toMap).orElseGet(() -> Map.of("error", "not found"));
    }

    private Object update(Long id, Map<String, Object> payload) {
        return repo.findById(id)
                .map(existing -> toMap(repo.save(fromPayload(existing, payload))))
                .orElseGet(() -> Map.of("error", "not found"));
    }

    private Product fromPayload(Product target, Map<String, Object> payload) {
        Product p = target == null ? new Product() : target;
        p.setName((String) payload.get("name"));
        p.setDescription((String) payload.get("description"));
        Object price = payload.get("price");
        p.setPrice(price == null ? null : new BigDecimal(price.toString()));
        Object stock = payload.get("stock");
        p.setStock(stock == null ? null : ((Number) stock).intValue());
        return p;
    }

    private Map<String, Object> toMap(Product p) {
        Map<String, Object> m = new HashMap<>();
        m.put("id", p.getId());
        m.put("name", p.getName());
        m.put("description", p.getDescription());
        m.put("price", p.getPrice());
        m.put("stock", p.getStock());
        return m;
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> asMap(Object o) {
        return o instanceof Map ? (Map<String, Object>) o : Map.of();
    }

    private Long asLong(Object o) {
        if (o instanceof Number n) return n.longValue();
        return Long.parseLong(String.valueOf(o));
    }
}
