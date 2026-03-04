#!/usr/bin/env python3
"""Minimal HTTP server to capture the SAML response from Entra ID.

Listens on 127.0.0.1:35001 — the hardcoded redirect URL that AWS Client VPN
uses for SAML federated auth. When the IdP POSTs the SAMLResponse, this server
captures it, writes it to a temp file, and exits.
"""

import http.server
import sys
import urllib.parse
import os

LISTEN_PORT = 35001
LISTEN_HOST = "127.0.0.1"


class SAMLHandler(http.server.BaseHTTPRequestHandler):
    saml_response = None

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        params = urllib.parse.parse_qs(body)

        saml = params.get("SAMLResponse", [None])[0]
        if saml:
            SAMLHandler.saml_response = saml
            # Write to the file the parent script is waiting on
            out_path = os.environ.get("SAML_RESPONSE_FILE", "/tmp/.aws-vpn-saml")
            with open(out_path, "w") as f:
                f.write(saml)

            # Redirect to GET /done — avoids Safari's "resubmit form?" warning
            # on page reload, and gives a clean URL in the address bar
            self.send_response(302)
            self.send_header("Location", "/done")
            self.end_headers()
        else:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Missing SAMLResponse")

    def do_GET(self):
        # After POST→redirect, show a minimal success page
        if self.path == "/done":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(
                b"<html><body style='font-family:system-ui;text-align:center;padding:60px'>"
                b"<h2>&#9989; VPN authentication complete</h2>"
                b"<p style='color:#666'>This tab will close automatically.</p>"
                b"</body></html>"
            )
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<html><body>Waiting for SAML auth...</body></html>")

    def log_message(self, format, *args):
        # Suppress default logging
        pass


def main():
    http.server.HTTPServer.allow_reuse_address = True
    server = http.server.HTTPServer((LISTEN_HOST, LISTEN_PORT), SAMLHandler)
    server.timeout = 120  # 2 min max wait

    while SAMLHandler.saml_response is None:
        server.handle_request()

    server.server_close()


if __name__ == "__main__":
    main()
