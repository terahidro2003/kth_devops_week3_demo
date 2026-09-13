package com.example.demo;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {"demo.version=v1", "demo.failure-every=0"})
class HealthyWeatherTest {
    @Autowired
    private TestRestTemplate http;

    @Test
    void healthyAppServesThePageAndRepeatedColdForecasts() {
        var page = http.getForEntity("/", String.class);
        assertThat(page.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(page.getBody()).contains("Stockholm Weather", "id=\"refresh\"");
        assertThat(http.getForEntity("/app.js", String.class).getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(http.getForEntity("/style.css", String.class).getStatusCode()).isEqualTo(HttpStatus.OK);

        for (int i = 1; i <= 6; i++) {
            var response = http.getForEntity("/hello-world", HelloController.WeatherResponse.class);
            assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
            assertThat(response.getHeaders().getCacheControl()).contains("no-store");
            assertThat(response.getBody()).isEqualTo(new HelloController.WeatherResponse(
                    "v1", i, "Stockholm", "Cloudy", 3, "ok",
                    "Everything looks normal. Welcome to Stockholm."));
        }
        assertThat(http.getForObject("/api/info", HelloController.AppInfo.class))
                .isEqualTo(new HelloController.AppInfo("v1", 0));
        var health = http.getForEntity("/actuator/health", JsonNode.class);
        assertThat(health.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(health.getBody().path("status").asText()).isEqualTo("UP");
    }
}
