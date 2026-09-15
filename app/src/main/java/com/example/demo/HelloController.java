package com.example.demo;

import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    private final String version;
    private final long latencyMs;
    private final AtomicLong requests = new AtomicLong();

    public HelloController(@Value("${demo.version}") String version,
                           @Value("${demo.latency-ms}") long latencyMs) {
        if (latencyMs < 0) {
            throw new IllegalArgumentException("demo.latency-ms must be zero or positive");
        }
        this.version = version;
        this.latencyMs = latencyMs;
    }

    // Keep the existing route so Grafana / analysis queries still match.
    @GetMapping("/hello-world")
    public ResponseEntity<DemoResponse> helloWorld() throws InterruptedException {
        long requestNumber = requests.incrementAndGet();
        long started = System.nanoTime();
        if (latencyMs > 0) {
            Thread.sleep(latencyMs);
        }
        long observedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
        return ResponseEntity.ok()
                .cacheControl(CacheControl.noStore())
                .body(new DemoResponse(version, requestNumber, observedMs, "ok"));
    }

    @GetMapping("/api/info")
    public ResponseEntity<AppInfo> info() {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore())
                .body(new AppInfo(version, latencyMs));
    }

    public record DemoResponse(String version, long requestNumber, long latencyMs, String outcome) {}

    public record AppInfo(String version, long latencyMs) {}
}
