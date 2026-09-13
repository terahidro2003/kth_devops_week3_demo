package com.example.demo;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.actuate.observability.AutoConfigureObservability;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;
import java.time.Duration;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {"demo.version=v2", "demo.failure-every=2"})
@AutoConfigureObservability
class FaultyWeatherTest {
    @Autowired
    private TestRestTemplate http;

    @Test
    void sunnyErrorsDoNotCrashTheServerAndAreVisibleInPrometheus() {
        for (int i = 1; i <= 6; i++) {
            boolean failed = i % 2 == 0;
            var response = http.getForEntity("/hello-world", HelloController.WeatherResponse.class);
            assertThat(response.getStatusCode()).isEqualTo(
                    failed ? HttpStatus.INTERNAL_SERVER_ERROR : HttpStatus.OK);
            assertThat(response.getHeaders().getCacheControl()).contains("no-store");
            assertThat(response.getBody()).isEqualTo(new HelloController.WeatherResponse(
                    "v2", i, "Stockholm", failed ? "Sunny" : "Cloudy", failed ? 30 : 3,
                    failed ? "error" : "ok",
                    failed ? "Something is clearly wrong. This cannot be Stockholm."
                            : "Everything looks normal. Welcome to Stockholm."));

            // Probes, page loads and info requests must not consume a weather turn.
            var health = http.getForEntity("/actuator/health", JsonNode.class);
            assertThat(health.getStatusCode()).isEqualTo(HttpStatus.OK);
            assertThat(health.getBody().path("status").asText()).isEqualTo("UP");
            assertThat(http.getForEntity("/", String.class).getStatusCode()).isEqualTo(HttpStatus.OK);
            assertThat(http.getForObject("/api/info", HelloController.AppInfo.class))
                    .isEqualTo(new HelloController.AppInfo("v2", 2));
        }

        // HTTP observations complete as each server request finishes.
        await().atMost(Duration.ofSeconds(5)).untilAsserted(() -> {
            var metrics = http.getForEntity("/actuator/prometheus", String.class);
            assertThat(metrics.getStatusCode()).isEqualTo(HttpStatus.OK);
            assertWeatherCount(metrics.getBody(), "200", 3);
            assertWeatherCount(metrics.getBody(), "500", 3);
        });
        var next = http.getForEntity("/hello-world", HelloController.WeatherResponse.class);
        assertThat(next.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(next.getBody().requestNumber()).isEqualTo(7);
    }

    private void assertWeatherCount(String metrics, String status, int expected) {
        String sample = metrics.lines()
                .filter(line -> line.startsWith("http_server_requests_seconds_count{"))
                .filter(line -> line.contains("uri=\"/hello-world\""))
                .filter(line -> line.contains("version=\"v2\""))
                .filter(line -> line.contains("status=\"" + status + "\""))
                .findFirst().orElseThrow(() -> new AssertionError("Missing weather metric for HTTP " + status));
        double count = Double.parseDouble(sample.substring(sample.indexOf('}') + 1).trim().split("\\s+")[0]);
        assertThat(count).isEqualTo((double) expected);
    }
}
