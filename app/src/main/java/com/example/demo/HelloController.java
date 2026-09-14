package com.example.demo;

import java.util.concurrent.atomic.AtomicLong;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    private final String version;
    private final int failureEvery;
    private final AtomicLong requests = new AtomicLong();

    public HelloController(@Value("${demo.version}") String version,
                           @Value("${demo.failure-every}") int failureEvery) {
        if (failureEvery < 0) {
            throw new IllegalArgumentException("FAILURE_EVERY must be zero or positive");
        }
        this.version = version;
        this.failureEvery = failureEvery;
    }

    // Keep the existing route so the provisioned Grafana queries still match.
    @GetMapping("/hello-world")
    public ResponseEntity<WeatherResponse> helloWorld() {
        long requestNumber = requests.incrementAndGet();
        boolean failed = failureEvery > 0 && requestNumber % failureEvery == 0;
        WeatherResponse weather = new WeatherResponse(
                version, requestNumber, "Stockholm", failed ? "Sunny" : "Cloudy",
                failed ? 30 : 3, failed ? "error" : "ok",
                failed ? "Something is clearly wrong. This cannot be Stockholm."
                        : "Everything looks normal. Welcome to Stockholm.");

        // A deliberate HTTP error response, not a crash or a failed health check.
        return ResponseEntity.status(failed ? HttpStatus.INTERNAL_SERVER_ERROR : HttpStatus.OK)
                // The local HTTP/1.1 demo uses a connection-level Kubernetes Service.
                // Let the next browser request open a new connection and sample another pod.
                .header("Connection", "close")
                .cacheControl(CacheControl.noStore())
                .body(weather);
    }

    @GetMapping("/api/info")
    public ResponseEntity<AppInfo> info() {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore())
                .body(new AppInfo(version, failureEvery));
    }

    public record WeatherResponse(String version, long requestNumber, String city,
                                  String condition, int temperatureC, String outcome,
                                  String message) {}

    public record AppInfo(String version, int failureEvery) {}
}
