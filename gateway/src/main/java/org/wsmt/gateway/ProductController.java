package org.wsmt.gateway;

import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.amqp.AmqpException;
import org.springframework.amqp.core.MessageDeliveryMode;
import org.springframework.amqp.core.MessagePostProcessor;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/products")
public class ProductController {

    private final RabbitTemplate rabbit;
    private final String exchange;
    private final String routingKey;

    public ProductController(RabbitTemplate rabbit,
                             @Value("${app.exchange}") String exchange,
                             @Value("${app.routingKey}") String routingKey) {
        this.rabbit = rabbit;
        this.exchange = exchange;
        this.routingKey = routingKey;
    }

    public record ProductDto(
            Long id,
            @NotBlank @Size(max = 120) String name,
            @Size(max = 500) String description,
            @NotNull @DecimalMin("0.0") BigDecimal price,
            @NotNull @Min(0) Integer stock
    ) {}

    @GetMapping
    public Object list() { return send(Map.of("op", "LIST")); }

    @GetMapping("/{id}")
    public Object get(@PathVariable long id) { return send(Map.of("op", "GET", "id", id)); }

    @PostMapping
    public Object create(@Valid @RequestBody ProductDto p) {
        return send(Map.of("op", "CREATE", "payload", p));
    }

    @PutMapping("/{id}")
    public Object update(@PathVariable long id, @Valid @RequestBody ProductDto p) {
        return send(Map.of("op", "UPDATE", "id", id, "payload", p));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Object> delete(@PathVariable long id) {
        send(Map.of("op", "DELETE", "id", id));
        return ResponseEntity.noContent().build();
    }

    private Object send(Map<String, Object> command) {
        MessagePostProcessor persistent = m -> {
            m.getMessageProperties().setDeliveryMode(MessageDeliveryMode.PERSISTENT);
            return m;
        };
        try {
            Object reply = rabbit.convertSendAndReceive(exchange, routingKey, command, persistent);
            if (reply == null) {
                throw new AmqpException("No reply from any worker (timeout).");
            }
            return reply;
        } catch (AmqpException ex) {
            throw new RuntimeException("Messaging failure: " + ex.getMessage(), ex);
        }
    }
}
