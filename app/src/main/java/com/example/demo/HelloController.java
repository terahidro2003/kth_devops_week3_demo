package com.example.demo;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    /** Artificial delay so a "bad" image can breach the canary latency SLO. */
    @Value("${demo.delay-ms:0}")
    private long delayMs;

    @GetMapping("/hello-world")
    public String helloWorld() throws InterruptedException {
        if (delayMs > 0) {
            Thread.sleep(delayMs);
        }
        return "Hello, World!";
    }
}
