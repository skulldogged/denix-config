import argparse
import base64
import hashlib
import json
import os
import secrets
import socket
import string
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
ISSUER = os.environ.get("CAELESTIA_CHATGPT_ISSUER", "https://auth.openai.com")
API_ENDPOINT = os.environ.get(
    "CAELESTIA_CHATGPT_API_ENDPOINT",
    "https://chatgpt.com/backend-api/codex/responses",
)
LISTEN_HOST = os.environ.get("CAELESTIA_CHATGPT_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("CAELESTIA_CHATGPT_PORT", "11435"))
OAUTH_PORT = 1455
MODELS = [
    "gpt-5.3-codex-spark",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.5",
    "gpt-5.6-luna",
    "gpt-5.6-sol",
    "gpt-5.6-terra",
]
AUTH_FILE = Path(
    os.environ.get(
        "CAELESTIA_CHATGPT_AUTH_FILE",
        Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        / "caelestia-chatgpt/auth.json",
    )
)
TOKEN_LOCK = threading.Lock()


def base64url(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def parse_jwt(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except (IndexError, ValueError, json.JSONDecodeError):
        return {}


def account_id(tokens):
    for token_name in ("id_token", "access_token"):
        claims = parse_jwt(tokens.get(token_name, ""))
        nested = claims.get("https://api.openai.com/auth", {})
        value = claims.get("chatgpt_account_id") or nested.get("chatgpt_account_id")
        if value:
            return value
        organizations = claims.get("organizations") or []
        if organizations and organizations[0].get("id"):
            return organizations[0]["id"]
    return None


def load_auth():
    try:
        return json.loads(AUTH_FILE.read_text())
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None


def save_auth(tokens, previous=None):
    auth = {
        "access": tokens["access_token"],
        "refresh": tokens.get("refresh_token") or (previous or {}).get("refresh"),
        "expires": int(time.time()) + int(tokens.get("expires_in", 3600)),
        "account_id": account_id(tokens) or (previous or {}).get("account_id"),
    }
    if not auth["refresh"]:
        raise RuntimeError("OpenAI did not return a refresh token")

    AUTH_FILE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = AUTH_FILE.with_suffix(".tmp")
    descriptor = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(auth, handle)
        handle.write("\n")
    os.replace(temp, AUTH_FILE)
    os.chmod(AUTH_FILE, 0o600)
    return auth


def form_request(url, values):
    request = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(values).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def refresh_auth(auth):
    tokens = form_request(
        f"{ISSUER}/oauth/token",
        {
            "grant_type": "refresh_token",
            "refresh_token": auth["refresh"],
            "client_id": CLIENT_ID,
        },
    )
    return save_auth(tokens, auth)


def valid_auth(force_refresh=False):
    with TOKEN_LOCK:
        auth = load_auth()
        if not auth:
            raise PermissionError("Run `caelestia-chatgpt login` first")
        if force_refresh or auth.get("expires", 0) <= int(time.time()) + 30:
            auth = refresh_auth(auth)
        return auth


def generate_pkce():
    alphabet = string.ascii_letters + string.digits + "-._~"
    verifier = "".join(secrets.choice(alphabet) for _ in range(43))
    challenge = base64url(hashlib.sha256(verifier.encode()).digest())
    return verifier, challenge


def exchange_code(code, redirect_uri, verifier):
    return form_request(
        f"{ISSUER}/oauth/token",
        {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri,
            "client_id": CLIENT_ID,
            "code_verifier": verifier,
        },
    )


def login():
    verifier, challenge = generate_pkce()
    state = base64url(secrets.token_bytes(32))
    redirect_uri = f"http://localhost:{OAUTH_PORT}/auth/callback"
    authorize_url = f"{ISSUER}/oauth/authorize?" + urllib.parse.urlencode(
        {
            "response_type": "code",
            "client_id": CLIENT_ID,
            "redirect_uri": redirect_uri,
            "scope": "openid profile email offline_access",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "id_token_add_organizations": "true",
            "codex_cli_simplified_flow": "true",
            "state": state,
            "originator": "caelestia",
        }
    )
    result = {}

    class CallbackHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            params = urllib.parse.parse_qs(url.query)
            if url.path != "/auth/callback":
                self.send_error(404)
                return
            if params.get("state", [None])[0] != state:
                result["error"] = "Invalid OAuth state"
            elif params.get("error"):
                result["error"] = params.get("error_description", params["error"])[0]
            elif not params.get("code"):
                result["error"] = "Missing authorization code"
            else:
                result["code"] = params["code"][0]

            success = "code" in result
            self.send_response(200 if success else 400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            message = "ChatGPT connected to Caelestia. You can close this window." if success else result["error"]
            self.wfile.write(
                (f"<!doctype html><title>Caelestia ChatGPT</title><h1>{message}</h1>").encode()
            )

        def log_message(self, _format, *_args):
            return

    class DualStackCallbackServer(ThreadingHTTPServer):
        address_family = socket.AF_INET6

        def server_bind(self):
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            super().server_bind()

    try:
        server = DualStackCallbackServer(("::", OAUTH_PORT), CallbackHandler)
    except OSError as error:
        raise RuntimeError(f"Could not listen on OAuth callback port {OAUTH_PORT}: {error}") from error
    server.timeout = 1

    print("Opening the ChatGPT authorization page...")
    print(authorize_url)
    webbrowser.open(authorize_url)
    deadline = time.time() + 300
    while not result and time.time() < deadline:
        server.handle_request()
    server.server_close()

    if not result:
        raise TimeoutError("ChatGPT authorization timed out")
    if result.get("error"):
        raise RuntimeError(result["error"])
    save_auth(exchange_code(result["code"], redirect_uri, verifier))
    print("ChatGPT OAuth login saved for Caelestia.")


def response_input(messages):
    inputs = []
    instructions = []
    for message in messages:
        role = message.get("role", "user")
        content = message.get("content", "")
        if role in ("system", "developer"):
            if content:
                instructions.append(str(content))
            continue

        parts = []
        text_type = "output_text" if role == "assistant" else "input_text"
        if content:
            parts.append({"type": text_type, "text": str(content)})
        for image in message.get("images", []):
            parts.append({"type": "input_image", "image_url": f"data:image/jpeg;base64,{image}"})
        if parts:
            inputs.append({"role": role, "content": parts})
    return "\n\n".join(instructions), inputs


def response_tools(tools):
    converted = []
    for tool in tools or []:
        function = tool.get("function", {})
        if not function.get("name"):
            continue
        converted.append(
            {
                "type": "function",
                "name": function["name"],
                "description": function.get("description", ""),
                "parameters": function.get("parameters", {"type": "object", "properties": {}}),
                "strict": False,
            }
        )
    return converted


def upstream_request(payload, force_refresh=False):
    auth = valid_auth(force_refresh)
    headers = {
        "Authorization": f"Bearer {auth['access']}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "originator": "caelestia",
        "User-Agent": "caelestia-chatgpt/1.0",
        "session_id": str(uuid.uuid4()),
    }
    if auth.get("account_id"):
        headers["ChatGPT-Account-Id"] = auth["account_id"]
    request = urllib.request.Request(
        API_ENDPOINT,
        data=json.dumps(payload).encode(),
        headers=headers,
        method="POST",
    )
    try:
        return urllib.request.urlopen(request, timeout=600)
    except urllib.error.HTTPError as error:
        if error.code == 401 and not force_refresh:
            error.close()
            return upstream_request(payload, True)
        detail = error.read().decode(errors="replace")[:1000]
        raise RuntimeError(f"ChatGPT request failed ({error.code}): {detail}") from error


def iter_sse(response):
    event_name = None
    data_lines = []
    for raw_line in response:
        line = raw_line.decode(errors="replace").rstrip("\r\n")
        if not line:
            if data_lines:
                try:
                    yield event_name, json.loads("\n".join(data_lines))
                except json.JSONDecodeError:
                    pass
            event_name = None
            data_lines = []
        elif line.startswith("event:"):
            event_name = line[6:].strip()
        elif line.startswith("data:"):
            data_lines.append(line[5:].strip())


def make_payload(body):
    instructions, inputs = response_input(body.get("messages", []))
    payload = {
        "model": body.get("model") or "gpt-5.4",
        "input": inputs,
        "instructions": instructions or "You are a helpful desktop AI assistant.",
        "store": False,
        "include": ["reasoning.encrypted_content"],
        "reasoning": {"effort": "medium", "summary": "auto"},
        "text": {"verbosity": "medium"},
        "stream": True,
    }
    tools = response_tools(body.get("tools"))
    if tools:
        payload["tools"] = tools
    return payload


def collect_response(payload):
    text = []
    reasoning = []
    tool_calls = []
    with upstream_request(payload) as response:
        for event, data in iter_sse(response):
            event = event or data.get("type", "")
            if event == "response.output_text.delta":
                text.append(data.get("delta", ""))
            elif event == "response.reasoning_summary_text.delta":
                reasoning.append(data.get("delta", ""))
            elif event == "response.output_item.done":
                item = data.get("item", {})
                if item.get("type") == "function_call":
                    try:
                        arguments = json.loads(item.get("arguments", "{}"))
                    except json.JSONDecodeError:
                        arguments = {}
                    tool_calls.append(
                        {"function": {"name": item.get("name", ""), "arguments": arguments}}
                    )
    return "".join(text), "".join(reasoning), tool_calls


class ApiHandler(BaseHTTPRequestHandler):
    def json_response(self, status, value, content_type="application/json"):
        encoded = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        if self.path == "/api/tags":
            self.json_response(
                200,
                {"models": [{"name": model, "model": model} for model in MODELS]},
            )
        elif self.path == "/api/auth/status":
            self.json_response(200, {"authenticated": load_auth() is not None})
        else:
            self.send_error(404)

    def do_POST(self):
        try:
            body = self.read_json()
            if self.path == "/api/generate":
                payload = make_payload(
                    {
                        "model": body.get("model"),
                        "messages": [
                            {"role": "system", "content": body.get("system", "")},
                            {"role": "user", "content": body.get("prompt", "")},
                        ],
                    }
                )
                text, _reasoning, _tools = collect_response(payload)
                self.json_response(200, {"response": text, "done": True})
                return

            if self.path != "/api/chat":
                self.send_error(404)
                return

            payload = make_payload(body)
            response = upstream_request(payload)
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.end_headers()
            tool_calls = []
            with response:
                for event, data in iter_sse(response):
                    event = event or data.get("type", "")
                    message = None
                    if event == "response.output_text.delta":
                        message = {"role": "assistant", "content": data.get("delta", "")}
                    elif event == "response.reasoning_summary_text.delta":
                        message = {"role": "assistant", "content": "", "thinking": data.get("delta", "")}
                    elif event == "response.output_item.done":
                        item = data.get("item", {})
                        if item.get("type") == "function_call":
                            try:
                                arguments = json.loads(item.get("arguments", "{}"))
                            except json.JSONDecodeError:
                                arguments = {}
                            tool_calls.append(
                                {
                                    "function": {
                                        "name": item.get("name", ""),
                                        "arguments": arguments,
                                    }
                                }
                            )
                    if message is not None:
                        self.wfile.write((json.dumps({"message": message, "done": False}) + "\n").encode())
                        self.wfile.flush()
            if tool_calls:
                self.wfile.write(
                    (
                        json.dumps(
                            {
                                "message": {
                                    "role": "assistant",
                                    "content": "",
                                    "tool_calls": tool_calls,
                                },
                                "done": False,
                            }
                        )
                        + "\n"
                    ).encode()
                )
            self.wfile.write(
                (json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}) + "\n").encode()
            )
            self.wfile.flush()
        except PermissionError as error:
            self.json_response(401, {"error": str(error)})
        except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
            self.json_response(502, {"error": str(error)})

    def log_message(self, format_string, *args):
        print(f"caelestia-chatgpt: {format_string % args}", file=sys.stderr)


def serve():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), ApiHandler)
    print(f"Caelestia ChatGPT provider listening on http://{LISTEN_HOST}:{LISTEN_PORT}")
    server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description="ChatGPT OAuth provider for Caelestia Shell")
    parser.add_argument("command", choices=("serve", "login", "logout", "status"))
    args = parser.parse_args()
    if args.command == "serve":
        serve()
    elif args.command == "login":
        login()
    elif args.command == "logout":
        AUTH_FILE.unlink(missing_ok=True)
        print("Caelestia ChatGPT OAuth login removed.")
    else:
        auth = load_auth()
        print("authenticated" if auth else "not authenticated")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, TimeoutError, urllib.error.URLError) as error:
        print(f"caelestia-chatgpt: {error}", file=sys.stderr)
        raise SystemExit(1)
