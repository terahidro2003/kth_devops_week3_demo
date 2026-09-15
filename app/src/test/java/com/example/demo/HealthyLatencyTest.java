package com.example.demo;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {"demo.version=v1", "demo.latency-ms=0"})
class HealthyLatencyTest {
    @Autowired
    private TestRestTemplate http;

    @Test
    void healthyAppServesThePageAndFastHelloResponses() {
        var page = http.getForEntity("/", String.class);
        assertThat(page.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(page.getBody()).contains("Canary Demo", "id=\"refresh\"", "id=\"load-toggle\"");
        assertThat(http.getForEntity("/app.js", String.class).getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(http.getForEntity("/style.css", String.class).getStatusCode()).isEqualTo(HttpStatus.OK);

        for (int i = 1; i <= 6; i++) {
            long started = System.nanoTime();
            var response = http.getForEntity("/hello-world", HelloController.DemoResponse.class);
            long elapsedMs = (System.nanoTime() - started) / 1_000_000L;
            assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
            assertThat(response.getHeaders().getCacheControl()).contains("no-store");
            assertThat(response.getBody().version()).isEqualTo("v1");
            assertThat(response.getBody().requestNumber()).isEqualTo(i);
            assertThat(response.getBody().outcome()).isEqualTo("ok");
            assertThat(response.getBody().latencyMs()).isLessThan(200);
            assertThat(elapsedMs).isLessThan(500);
        }
        assertThat(http.getForObject("/api/info", HelloController.AppInfo.class))
                .isEqualTo(new HelloController.AppInfo("v1", 0));
        var health = http.getForEntity("/actuator/health", JsonNode.class);
        assertThat(health.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(health.getBody().path("status").asText()).isEqualTo("UP");
    }
}
