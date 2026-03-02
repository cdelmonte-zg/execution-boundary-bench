"""
Minimal HTTP server for isolation benchmark.
Design constraints:
  - ~40MB RSS baseline (via pre-allocated buffer)
  - /ready endpoint for probe
  - /healthz for liveness
  - Stays idle after startup
  - No external dependencies
"""

import http.server
import json
import os
import time

# Pre-allocate ~40MB to simulate realistic baseline RSS
# This ensures we're measuring sandbox overhead, not just process overhead
_BALLAST = bytearray(40 * 1024 * 1024)

STARTUP_TIME = time.time()


class ReadinessHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ready":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "ready",
                "pid": os.getpid(),
                "uptime_seconds": round(time.time() - STARTUP_TIME, 3),
                "rss_mb": self._get_rss_mb()
            }).encode())
        elif self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Suppress request logging to avoid I/O noise
        pass

    @staticmethod
    def _get_rss_mb():
        try:
            with open("/proc/self/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        return round(int(line.split()[1]) / 1024, 1)
        except Exception:
            return -1
        return -1


if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", 8080), ReadinessHandler)
    print(f"Benchmark workload ready on :8080 (PID {os.getpid()})")
    server.serve_forever()
