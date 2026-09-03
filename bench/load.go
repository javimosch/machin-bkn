// A closed-loop HTTP load generator, written in Go for one reason: the ruler
// must not be the thing being measured. A shell loop over curl spends more
// time forking than either server spends answering, and would report the
// harness's limits as the servers'.
//
// Closed loop means N workers each send one request and wait. That models a
// connection pool, not an open-world arrival process, so the number to trust
// here is the latency at a fixed concurrency — throughput follows from it.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

type hdrs []string

func (h *hdrs) String() string     { return "" }
func (h *hdrs) Set(v string) error { *h = append(*h, v); return nil }

func main() {
	var (
		url     = flag.String("url", "", "target URL")
		method  = flag.String("method", "GET", "HTTP method")
		body    = flag.String("body", "", "request body")
		conc    = flag.Int("c", 8, "concurrent workers")
		dur     = flag.Duration("d", 5*time.Second, "measurement duration")
		warm    = flag.Duration("warmup", 1*time.Second, "warmup, not measured")
		label   = flag.String("label", "", "scenario label")
		headers hdrs
	)
	flag.Var(&headers, "H", "header 'Name: value' (repeatable)")
	flag.Parse()
	if *url == "" {
		fmt.Fprintln(os.Stderr, "load: -url required")
		os.Exit(2)
	}

	// One transport shared by every worker, with room for all of them, so the
	// run measures request handling and not connection setup.
	tr := &http.Transport{
		MaxIdleConns:        *conc * 2,
		MaxIdleConnsPerHost: *conc * 2,
		MaxConnsPerHost:     *conc * 2,
		DisableCompression:  true,
	}
	client := &http.Client{Transport: tr, Timeout: 30 * time.Second}

	var (
		mu      sync.Mutex
		samples []time.Duration
		bad     atomic.Int64
		errs    atomic.Int64
		nbytes  atomic.Int64
	)

	run := func(d time.Duration, record bool) {
		deadline := time.Now().Add(d)
		var wg sync.WaitGroup
		for i := 0; i < *conc; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				local := make([]time.Duration, 0, 4096)
				for time.Now().Before(deadline) {
					var rdr io.Reader
					if *body != "" {
						rdr = bytes.NewReader([]byte(*body))
					}
					req, err := http.NewRequest(*method, *url, rdr)
					if err != nil {
						errs.Add(1)
						continue
					}
					for _, h := range headers {
						for j := 0; j < len(h); j++ {
							if h[j] == ':' {
								k, v := h[:j], h[j+1:]
								for len(v) > 0 && v[0] == ' ' {
									v = v[1:]
								}
								req.Header.Set(k, v)
								break
							}
						}
					}
					t0 := time.Now()
					resp, err := client.Do(req)
					if err != nil {
						errs.Add(1)
						continue
					}
					n, _ := io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
					el := time.Since(t0)
					if resp.StatusCode < 200 || resp.StatusCode >= 300 {
						bad.Add(1)
					}
					if record {
						nbytes.Add(n)
						local = append(local, el)
					}
				}
				if record && len(local) > 0 {
					mu.Lock()
					samples = append(samples, local...)
					mu.Unlock()
				}
			}()
		}
		wg.Wait()
	}

	run(*warm, false)
	bad.Store(0)
	errs.Store(0)
	start := time.Now()
	run(*dur, true)
	elapsed := time.Since(start)

	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	pct := func(p float64) float64 {
		if len(samples) == 0 {
			return 0
		}
		i := int(p / 100 * float64(len(samples)))
		if i >= len(samples) {
			i = len(samples) - 1
		}
		return float64(samples[i].Microseconds()) / 1000
	}
	out := map[string]any{
		"label": *label, "url": *url, "method": *method, "conc": *conc,
		"requests": len(samples),
		"seconds":  elapsed.Seconds(),
		"rps":      float64(len(samples)) / elapsed.Seconds(),
		"p50_ms":   pct(50), "p90_ms": pct(90), "p99_ms": pct(99),
		"max_ms":   pct(100),
		"non2xx":   bad.Load(), "errors": errs.Load(),
		"bytes": nbytes.Load(),
	}
	enc := json.NewEncoder(os.Stdout)
	enc.Encode(out)
}
