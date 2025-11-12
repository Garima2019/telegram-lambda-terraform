import os, json, urllib.request, urllib.parse, logging, datetime
import boto3
from botocore.config import Config


logger = logging.getLogger()
logger.setLevel(logging.INFO)

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "8551321920:AAEjtSaf4L_nn-MqJe3EcO3IHoPFtDyrG5E")
S3_BUCKET = os.environ.get("S3_BUCKET", "")
OFFSET_KEY = os.environ.get("OFFSET_KEY", "state/offset.txt")
LOG_KEY = os.environ.get("LOG_KEY", "logs/chat-log.jsonl")
S3_ENDPOINT_URL = os.environ.get("S3_ENDPOINT_URL")
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION") or os.environ.get("AWS_REGION") or "us-east-1"


TG_API_BASE = f"https://api.telegram.org/bot{BOT_TOKEN}" if BOT_TOKEN else None
boto3_kwargs = {"config": Config(retries={"max_attempts": 2, "mode": "standard"}), "region_name": AWS_REGION}
s3 = boto3.client("s3", **boto3_kwargs)

boto3_kwargs = {
    "region_name": AWS_REGION,
    "config": Config(retries={"max_attempts": 2, "mode": "standard"},
                     signature_version="s3v4",
                     s3={"addressing_style": "path"}),  # use "virtual" if your endpoint supports it
}
if S3_ENDPOINT_URL:
    s3 = boto3.client("s3", endpoint_url=S3_ENDPOINT_URL, **boto3_kwargs)
else:
    s3 = boto3.client("s3", **boto3_kwargs)

def _s3_get_text(key, default=""):
    try:
        obj = s3.get_object(Bucket=S3_BUCKET, Key=key)
        return obj["Body"].read().decode("utf-8")
    except Exception as e:
        logger.info(f"s3 get miss for {key}: {e}")
        return default

# def _s3_put_text(key, text):
#     s3.put_object(Bucket=S3_BUCKET, Key=key, Body=text.encode("utf-8"))

def _s3_put_text(key, text):
    if not S3_BUCKET:
        # Fail fast and clearly instead of a cryptic signature error
        logger.error("S3_BUCKET is not set. Skipping S3 write for key=%s", key)
        raise RuntimeError("S3_BUCKET environment variable not set")

    try:
        s3.put_object(Bucket=S3_BUCKET, Key=key, Body=text.encode("utf-8"))
    except Exception as e:
        # Try to extract Botocore/Vendor-specific details for debugging
        try:
            err = getattr(e, "response", {})
            status = err.get("ResponseMetadata", {}).get("HTTPStatusCode")
            aws_err = err.get("Error", {}).get("Message") or err.get("Error", {}).get("Code")
            logger.error("S3 put_object failed. HTTPStatus=%s, AWS_Error=%s", status, aws_err)
        except Exception:
            logger.exception("S3 put_object failed (couldn't extract error details)")
        # Re-raise so caller sees failure (or you can choose to swallow)
        raise

def tg_get_updates(offset=None, timeout=0):
    assert TG_API_BASE, "TELEGRAM_BOT_TOKEN not set"
    params = {}
    if offset is not None:
        params["offset"] = offset
    if timeout:
        params["timeout"] = timeout
    url = TG_API_BASE + "/getUpdates?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))

def tg_send_message(chat_id, text):
    assert TG_API_BASE, "TELEGRAM_BOT_TOKEN not set"
    data = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode("utf-8")
    req = urllib.request.Request(TG_API_BASE + "/sendMessage", data=data)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))

def handle_command(text):
    if not text:
        return "I only understand text messages for now."
    t = text.strip()
    if t.startswith("/hello"):
        return "Hello! 😉"
    if t.startswith("/help"):
        return "Commands: /hello, /echo <text>, /help"
    if t.startswith("/echo"):
        parts = t.split(" ", 1)
        return parts[1] if len(parts) > 1 else "Usage: /echo <text>"
    return "Try /hello, /help, or /echo <text>."

def log_chat(entry: dict):
    try:
        existing = _s3_get_text(LOG_KEY, "")
        line = json.dumps(entry, ensure_ascii=False)
        new_body = (existing + ("\n" if existing and not existing.endswith("\n") else "") + line)
        _s3_put_text(LOG_KEY, new_body)
    except Exception as e:
        logger.error(f"failed to write log: {e}")

def lambda_handler(event, context):
    raw = _s3_get_text(OFFSET_KEY, "0").strip()
    try:
        last_offset = int(raw) if raw else 0
    except:
        last_offset = 0

    logger.info(f"Starting poll from offset={last_offset}")
    try:
        updates = tg_get_updates(offset=last_offset + 1, timeout=0)
    except Exception as e:
        logger.error(f"getUpdates failed: {e}")
        return {"ok": False, "error": str(e)}

    if not updates.get("ok"):
        logger.error(f"Telegram returned not ok: {updates}")
        return {"ok": False, "response": updates}

    max_update_id = last_offset
    processed = 0

    for upd in updates.get("result", []):
        max_update_id = max(max_update_id, upd.get("update_id", last_offset))
        msg = upd.get("message") or upd.get("edited_message")
        if not msg:
            continue
        chat_id = msg["chat"]["id"]
        text = msg.get("text", "")
        reply = handle_command(text)
        try:
            tg_send_message(chat_id, reply)
        except Exception as e:
            logger.error(f"sendMessage failed: {e}")
        log_chat({
            # "ts": datetime.datetime.utcnow().isoformat() + "Z",
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "chat_id": chat_id,
            "user": msg.get("from", {}),
            "text": text,
            "reply": reply
        })
        processed += 1

    if max_update_id != last_offset:
        _s3_put_text(OFFSET_KEY, str(max_update_id))

    return {"ok": True, "processed": processed, "new_offset": max_update_id}

# --- Add this section at the very end of your handly.py file ---

if __name__ == "__main__":
    # Create dummy event and context objects for local execution
    dummy_event = {}
    dummy_context = None

    print("--- Running lambda_handler locally ---")
    
    # Call the main logic
    result = lambda_handler(dummy_event, dummy_context)
    
    print("--- Execution Result ---")
    print(json.dumps(result, indent=4))