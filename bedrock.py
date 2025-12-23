
#!/usr/bin/env python3
import json
import sys
from pathlib import Path
import boto3

# ---------- Config ----------
MODEL_ID = "amazon.titan-text-express-v1"
REGION = "us-east-1"           # Bedrock Titan Text Express is available in us-east-1
AWS_PROFILE = "Deepak"         # Your CLI profile
LOG_FILE = "FinalOutput.rtf"   # Replace with the log file you want to send (or use test.sh output)
# ----------------------------

def load_logs(path: str) -> str:
    p = Path(path)
    if not p.exists():
        print(f"ERROR: Log file not found: {path}", file=sys.stderr)
        sys.exit(1)
    # Read as text; if RTF, still fine as text for summarization
    return p.read_text(encoding="utf-8", errors="ignore")

def build_payload(log_text: str) -> dict:
    """
    Titan Text Express expects:
      - 'inputText': your prompt
      - 'textGenerationConfig': generation parameters (optional but useful)
    """
    prompt = (
        "You are an assistant analyzing Kubernetes + Dapr test output.\n"
        "Summarize the following logs, highlight any errors or warnings, and confirm whether the pub/sub test succeeded.\n\n"
        "Logs:\n" + log_text
    )

    return {
        "inputText": prompt,
        "textGenerationConfig": {
            "temperature": 0.3,
            "topP": 0.9,
            "maxTokenCount": 1024,  # Set as needed; lower for concise outputs
            # "stopSequences": ["\n\n"]  # optional
        }
    }

def main():
    logs = load_logs(LOG_FILE)
    payload = build_payload(logs)

    # Set up a session with your profile
    session = boto3.Session(profile_name=AWS_PROFILE, region_name=REGION)
    bedrock_runtime = session.client("bedrock-runtime")

    response = bedrock_runtime.invoke_model(
        modelId=MODEL_ID,
        accept="application/json",
        contentType="application/json",
        body=json.dumps(payload)
    )

    # Response body is a streaming-like object; read and decode
    body_bytes = response["body"].read()
    body = json.loads(body_bytes.decode("utf-8"))

    # Titan Text returns 'outputText' in the top-level object
    output_text = body.get("outputText") or body.get("results") or body
    print("\n=== Bedrock (Titan) Analysis ===\n")
    print(output_text)

if __name__ == "__main__":
    main()

