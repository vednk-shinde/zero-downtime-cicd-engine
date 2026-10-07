// Demo service used to exercise the deployment pipeline. It deliberately has the
// behaviours a deployment system must handle: slow startup (readiness gating),
// graceful shutdown (connection draining), injectable error rate (bad releases)
// and a crash endpoint (chaos / self-healing).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"
)

type config struct {
	Version      string
	Pod          string
	ErrorRate    float64       // fraction of /api/hello requests answered with 500
	StartupDelay time.Duration // how long /readyz reports not-ready after boot
	ShutdownWait time.Duration
	DrainDelay   time.Duration // keep serving after SIGTERM while endpoints propagate
}

func configFromEnv() config {
	f, _ := strconv.ParseFloat(os.Getenv("ERROR_RATE"), 64)
	d, _ := strconv.Atoi(os.Getenv("STARTUP_DELAY_SEC"))
	host, _ := os.Hostname()
	return config{
		Version:      envOr("VERSION", "dev"),
		Pod:          envOr("POD_NAME", host),
		ErrorRate:    f,
		StartupDelay: time.Duration(d) * time.Second,
		ShutdownWait: 10 * time.Second,
		DrainDelay:   5 * time.Second,
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

type app struct {
	cfg      config
	started  time.Time
	requests atomic.Int64
	errors   atomic.Int64
	rng      func() float64
	exit     func(int)
}

func newApp(cfg config) *app {
	return &app{cfg: cfg, started: time.Now(), rng: rand.Float64, exit: os.Exit}
}

func (a *app) handler() http.Handler {
	mux := http.NewServeMux()
	// Liveness: the process is up. Never depends on startup delay.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprintln(w, "ok") })
	// Readiness: gates traffic from Services.
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		if time.Since(a.started) < a.cfg.StartupDelay {
			http.Error(w, "starting", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "ready")
	})
	mux.HandleFunc("/api/hello", func(w http.ResponseWriter, _ *http.Request) {
		a.requests.Add(1)
		if a.cfg.ErrorRate > 0 && a.rng() < a.cfg.ErrorRate {
			a.errors.Add(1)
			http.Error(w, "injected failure", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"version": a.cfg.Version, "pod": a.cfg.Pod})
	})
	mux.HandleFunc("/version", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprintln(w, a.cfg.Version) })
	// Chaos hook: kill the process so Kubernetes' self-healing can be demonstrated.
	mux.HandleFunc("/crash", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "crashing")
		go func() { time.Sleep(50 * time.Millisecond); a.exit(1) }()
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, "app_requests_total %d\napp_errors_total %d\napp_info{version=%q} 1\n",
			a.requests.Load(), a.errors.Load(), a.cfg.Version)
	})
	return mux
}

func main() {
	cfg := configFromEnv()
	a := newApp(cfg)
	srv := &http.Server{Addr: ":" + envOr("PORT", "8080"), Handler: a.handler(), ReadHeaderTimeout: 5 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	go func() {
		<-ctx.Done()
		// Kubernetes removes the pod from endpoints concurrently with SIGTERM; keep
		// serving briefly, then drain in-flight requests.
		log.Println("SIGTERM: draining")
		time.Sleep(cfg.DrainDelay)
		sctx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownWait)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()
	log.Printf("version=%s pod=%s listening on %s", cfg.Version, cfg.Pod, srv.Addr)
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
