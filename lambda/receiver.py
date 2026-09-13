"""
receiver.py

Public entry point behind API Gateway for the Meta WhatsApp Cloud API
webhook. It has three jobs:

1. Answer Meta's GET /webhook verification handshake (hub.mode /
   hub.verify_token / hub.challenge).
2. On POST /webhook, verify the request actually came from Meta by checking
   the X-Hub-Signature-256 HMAC-SHA256 header against the App Secret, so a
   forged request to the (public) webhook URL can't trigger a Bedrock
   invocation or a spoofed reply just by claiming to be from an allowed
   sender.
3. Immediately return HTTP 200 and hand a verified payload off to the
   `processor` Lambda function asynchronously (InvocationType="Event").
   Meta expects a 200 within a few seconds and retries aggressively (and
   repeatedly) if it does not get one, so this function must never wait on
   anything slow (like Bedrock).

Only the Python 3.12 standard library and boto3 (bundled with the Lambda
runtime) are used — no third-party dependencies, no build step.
"""
import base64
import hashlib
import hmac
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

ssm = boto3.client("ssm")
lambda_client = boto3.client("lambda")

PROCESSOR_FUNCTION_NAME = os.environ["PROCESSOR_FUNCTION_NAME"]
VERIFY_TOKEN_PARAM = os.environ["VERIFY_TOKEN_PARAM"]
APP_SECRET_PARAM = os.environ["APP_SECRET_PARAM"]

# Cached for the lifetime of the execution environment to avoid an SSM call
# on every single request.
_secrets_cache = {}


def _get_secret(param_name):
    if param_name not in _secrets_cache:
        response = ssm.get_parameter(Name=param_name, WithDecryption=True)
        _secrets_cache[param_name] = response["Parameter"]["Value"]
    return _secrets_cache[param_name]


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "text/plain"},
        "body": body,
    }


def _handle_verification(event):
    """Answer Meta's GET /webhook handshake used when saving the webhook
    configuration in the Meta Developer Portal."""
    params = event.get("queryStringParameters") or {}
    mode = params.get("hub.mode")
    token = params.get("hub.verify_token")
    challenge = params.get("hub.challenge")

    # hmac.compare_digest rather than == : a plain string comparison
    # short-circuits on the first differing byte, a timing side-channel for
    # a value that's otherwise compared like a secret.
    if mode == "subscribe" and token is not None and hmac.compare_digest(token, _get_secret(VERIFY_TOKEN_PARAM)):
        logger.info("Webhook verification succeeded.")
        return _response(200, challenge or "")

    logger.warning("Webhook verification failed (mode=%s).", mode)
    return _response(403, "Verification failed")


def _decode_body(event):
    body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")
    return body


def _get_header(event, name):
    """API Gateway HTTP API v2 lower-cases and de-duplicates header names."""
    headers = event.get("headers") or {}
    return headers.get(name.lower())


def _has_valid_signature(body, signature_header):
    """Verify Meta's X-Hub-Signature-256 header: 'sha256=<hex hmac>' computed
    over the raw request body using the Meta App Secret. Protects the public
    webhook URL from forged POSTs — without this, anyone who finds the URL
    could claim an allowed phone number as the sender and trigger Bedrock
    invocations or a spoofed reply for free."""
    if not signature_header or not signature_header.startswith("sha256="):
        return False

    provided_digest = signature_header[len("sha256=") :]
    app_secret = _get_secret(APP_SECRET_PARAM)
    expected_digest = hmac.new(
        app_secret.encode("utf-8"), body.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    return hmac.compare_digest(expected_digest, provided_digest)


def _handle_event(event):
    """Verify the request signature, then acknowledge the payload
    immediately and hand it off to the processor Lambda asynchronously so
    Meta always sees a fast 200 OK, regardless of how long Bedrock takes to
    generate a reply."""
    body = _decode_body(event)
    signature = _get_header(event, "X-Hub-Signature-256")

    if not _has_valid_signature(body, signature):
        logger.warning("Rejecting webhook POST with missing/invalid signature.")
        return _response(403, "Invalid signature")

    try:
        lambda_client.invoke(
            FunctionName=PROCESSOR_FUNCTION_NAME,
            InvocationType="Event",
            Payload=body.encode("utf-8"),
        )
    except Exception:
        # We still return 200 below to avoid Meta retry storms; log loudly
        # so a broken hand-off is visible in CloudWatch / alarms instead of
        # silently swallowing user messages forever.
        logger.exception("Failed to invoke the processor function.")

    return _response(200, "EVENT_RECEIVED")


def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method") or event.get("httpMethod")
    logger.info("Received %s request.", method)

    if method == "GET":
        return _handle_verification(event)

    if method == "POST":
        return _handle_event(event)

    return _response(405, "Method Not Allowed")
