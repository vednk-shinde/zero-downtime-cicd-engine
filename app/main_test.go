package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func get(h http.Handler, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
	return rec
}

func TestHelloReportsVersion(t *testing.T) {
	a := newApp(config{Version: "v9", Pod: "p1"})
	rec := get(a.handler(), "/api/hello")
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"version":"v9"`) {
		t.Fatalf("unexpected response %d %s", rec.Code, rec.Body.String())
	}
}

func TestReadinessGatedByStartupDelay(t *testing.T) {
	a := newApp(config{StartupDelay: time.Hour})
	if get(a.handler(), "/readyz").Code != 503 {
		t.Fatal("should not be ready during startup delay")
	}
	if get(a.handler(), "/healthz").Code != 200 {
		t.Fatal("liveness must not depend on readiness")
	}
	a.started = time.Now().Add(-2 * time.Hour)
	if get(a.handler(), "/readyz").Code != 200 {
		t.Fatal("should be ready after the delay")
	}
}

func TestInjectedErrorRate(t *testing.T) {
	a := newApp(config{ErrorRate: 0.5})
	a.rng = func() float64 { return 0.1 } // < 0.5 -> fail
	if get(a.handler(), "/api/hello").Code != 500 {
		t.Fatal("expected injected 500")
	}
	a.rng = func() float64 { return 0.9 }
	if get(a.handler(), "/api/hello").Code != 200 {
		t.Fatal("expected success")
	}
	if a.errors.Load() != 1 || a.requests.Load() != 2 {
		t.Fatalf("counters wrong: %d/%d", a.errors.Load(), a.requests.Load())
	}
}

func TestCrashEndpointExits(t *testing.T) {
	a := newApp(config{})
	code := make(chan int, 1)
	a.exit = func(c int) { code <- c }
	get(a.handler(), "/crash")
	select {
	case c := <-code:
		if c != 1 {
			t.Fatalf("exit code %d", c)
		}
	case <-time.After(time.Second):
		t.Fatal("process did not exit")
	}
}

func TestMetrics(t *testing.T) {
	a := newApp(config{Version: "v1"})
	get(a.handler(), "/api/hello")
	body := get(a.handler(), "/metrics").Body.String()
	if !strings.Contains(body, "app_requests_total 1") || !strings.Contains(body, `app_info{version="v1"} 1`) {
		t.Fatalf("bad metrics: %s", body)
	}
}
