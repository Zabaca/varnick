#!/usr/bin/python3 -I
# Stands in for claude when the API can't be reached (check.sh): speaks just enough of the stream-json protocol to answer the
# SDK's control requests and then, per user message, stream "OK" and end with a success result. It logs the argv, cwd and the
# names (never the values) of the environment it was started with to $FAKE_CLAUDE_LOG.
#   FAKE_CLAUDE_HANG=1   never answers a user message, to check that a stop ends this process
#   FAKE_CLAUDE_RETRY=1  reports a retrying request, as a login that fails does
#   FAKE_CLAUDE_TRANSIENT=1  reports a retry for an overloaded API, then answers
import json, os, sys, time

log = open(os.environ.get("FAKE_CLAUDE_LOG", "/dev/null"), "a")
log.write(json.dumps({"argv": sys.argv, "cwd": os.getcwd(), "env": sorted(os.environ)}) + "\n")
log.flush()

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    log.write("in: " + line[:300] + "\n"); log.flush()
    if msg.get("type") == "control_request":
        send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {}}})
    elif msg.get("type") == "user":
        send({"type": "system", "subtype": "init", "session_id": "fake", "model": "fake", "tools": [], "cwd": os.getcwd()})
        if os.environ.get("FAKE_CLAUDE_HANG"):
            time.sleep(3600)
        if os.environ.get("FAKE_CLAUDE_RETRY"):
            send({"type": "system", "subtype": "api_retry", "attempt": 1, "max_retries": 10, "retry_delay_ms": 500,
                  "error_status": 401, "error": "authentication_failed", "uuid": "u1", "session_id": "fake"})
            time.sleep(3600)
        if os.environ.get("FAKE_CLAUDE_TRANSIENT"):
            send({"type": "system", "subtype": "api_retry", "attempt": 1, "max_retries": 10, "retry_delay_ms": 100,
                  "error_status": 529, "error": "overloaded", "uuid": "u0", "session_id": "fake"})
            time.sleep(0.3)
        send({"type": "stream_event", "uuid": "u2", "session_id": "fake", "parent_tool_use_id": None,
              "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "OK"}}})
        send({"type": "assistant", "session_id": "fake", "parent_tool_use_id": None,
              "message": {"id": "m1", "type": "message", "role": "assistant", "model": "fake",
                          "content": [{"type": "text", "text": "OK"}], "stop_reason": "end_turn", "usage": {}}})
        send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1, "result": "OK",
              "session_id": "fake", "total_cost_usd": 0, "duration_ms": 1, "duration_api_ms": 1,
              "usage": {}, "modelUsage": {}, "permission_denials": []})
