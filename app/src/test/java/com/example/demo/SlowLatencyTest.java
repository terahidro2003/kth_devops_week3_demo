package com.example.demo;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.actuate.observability.AutoConfigureObservability;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {"demo.version=v2", "demo.latency-ms=80"})
@AutoConfigureObservability
class SlowLatencyTest {
    @Autowired
    private TestRestTemplate http;

    @Test
    void delayedHelloDoesNotSlowHealthAndStaysHttp200() {
        for (int i = 1; i <= 4; i++) {
            long helloStarted = System.nanoTime();
            var response = http.getForEntity("/hello-world", HelloController.DemoResponse.class);
            long helloMs = (System.nanoTime() - helloStarted) / 1_000_000L;
            assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
            assertThat(response.getHeaders().getCacheControl()).contains("no-store");
            assertThat(response.getBody().version()).isEqualTo("v2");
            assertThat(response.getBody().requestNumber()).isEqualTo(i);
            assertThat(response.getBody().outcome()).isEqualTo("ok");
            assertThat(response.getBody().latencyMs()).isGreaterThanOrEqualTo(80);
            assertThat(helloMs).isGreaterThanOrEqualTo(80);

            // Probes, page loads and info must not sleep or advance hello counter.
            long healthStarted = System.nanoTime();
            var health = http.getForEntity("/actuator/health", JsonNode.class);
            long healthMs = (System.nanoTime() - healthStarted) / 1_000_000L;
            assertThat(health.getStatusCode()).isEqualTo(HttpStatus.OK);
            assertThat(health.getBody().path("status").asText()).isEqualTo("UP");
            assertThat(healthMs).isLessThan(500);

            assertThat(http.getForEntity("/", String.class).getStatusCode()).isEqualTo(HttpStatus.OK);
            assertThat(http.getForObject("/api/info", HelloController.AppInfo.class))
                    .isEqualTo(new HelloController.AppInfo("v2", 80));
        }

        var metrics = http.getForEntity("/actuator/prometheus", String.class);
        assertThat(metrics.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertHelloCount(metrics.getBody(), "200", 4);
        assertThat(metrics.getBody().lines()
                .filter(line -> line.startsWith("http_server_requests_seconds_count{"))
                .filter(line -> line.contains("uri=\"/hello-world\""))
                .filter(line -> line.contains("status=\"500\""))
                .findAny()).isEmpty();

        var next = http.getForEntity("/hello-world", HelloController.DemoResponse.class);
        assertThat(next.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(next.getBody().requestNumber()).isEqualTo(5);
    }

    private void assertHelloCount(String metrics, String status, int expected) {
        String sample = metrics.lines()
                .filter(line -> line.startsWith("http_server_requests_seconds_count{"))
                .filter(line -> line.contains("uri=\"/hello-world\""))
                .filter(line -> line.contains("version=\"v2\""))
                .filter(line -> line.contains("status=\"" + status + "\""))
                .findFirst()
                .orElseThrow(() -> new AssertionError("Missing hello-world metric for HTTP " + status));
        double count = Double.parseDouble(sample.substring(sample.indexOf('}') + 1).trim().split("\\s+")[0]);
        assertThat(count).isEqualTo((double) expected);
    }
}
