#!/usr/bin/env bash
set -e

CLIENT_ID="68789ff689798d7d715b1143"
CLIENT_SECRET="643231c3-c93e-40dd-a808-fcf2d680cdaf"
REDIRECT_URI="http://localhost:7890/callback"
WORKER_BIN="./RaindropShot.app/Contents/MacOS/RaindropShotWorker"

if [ ! -f "$WORKER_BIN" ]; then
    echo "Building RaindropShot..."
    make app
fi

AUTH_URL="https://raindrop.io/oauth/authorize?client_id=${CLIENT_ID}&redirect_uri=${REDIRECT_URI}&response_type=code"

echo "=========================================================="
echo " Raindrop.io OAuth Login"
echo "=========================================================="
echo ""
echo "1. Opening your browser to authorize RaindropShot:"
echo "   ${AUTH_URL}"
echo ""
echo "2. Waiting for authorization callback on localhost:7890..."
echo ""

# Start a temporary one-request HTTP server in python to catch the callback
CODE=$(python3 -c "
import http.server, socketserver, urllib.parse, sys

code = None

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        global code
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        if 'code' in qs:
            code = qs['code'][0]
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><body><h2>Raindrop.io Authorization Successful!</h2><p>You can close this tab and return to the terminal.</p></body></html>')
        else:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'Failed to get authorization code.')

    def log_message(self, format, *args):
        pass

server = socketserver.TCPServer(('127.0.0.1', 7890), Handler)
server.handle_request()
if code:
    print(code)
")

if [ -n "$CODE" ]; then
    echo "✓ Authorization code received: ${CODE:0:8}..."
    echo "Exchanging code for access token..."
    "$WORKER_BIN" --exchange-code "$CODE" --client-id "$CLIENT_ID" --client-secret "$CLIENT_SECRET" --redirect-uri "$REDIRECT_URI"
    echo ""
    echo "🎉 Setup complete! You can now launch the app:"
    echo "   open RaindropShot.app"
else
    echo "❌ Failed to receive authorization code."
    exit 1
fi
