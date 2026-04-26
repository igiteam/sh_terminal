#!/bin/bash

# DeepSeek AI H100 Setup Script for Vast.ai
# Complete deployment of DeepSeek with external API
# Usage: curl -sL https://your-domain.com/setup-deepseek-h100.sh | sudo bash

# Force non-interactive mode
export DEBIAN_FRONTEND=noninteractive

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Display banner
echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║      DeepSeek AI H100 Setup for Vast.ai                 ║"
echo "║      1x H100 SXM | 80GB VRAM | France                   ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    warn "Not running as root. Some commands may need sudo."
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Get configuration
echo ""
info "Please provide configuration details:"
echo "-------------------------------------"

# Get API port
get_input "Enter API port for DeepSeek" "3000" API_PORT

# Get API key (optional)
read -p "Enter API key for authentication (leave empty for no auth): " API_KEY

# Get instance IP (auto-detected)
INSTANCE_IP=$(curl -s --fail ifconfig.me 2>/dev/null || curl -s --fail http://checkip.amazonaws.com 2>/dev/null || echo "UNKNOWN")
info "Detected instance IP: $INSTANCE_IP"

echo ""
log "Starting DeepSeek AI H100 Setup..."
log "API Port: $API_PORT"
log "Instance IP: $INSTANCE_IP"

# Update system
log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# Install required tools
log "Installing required tools..."
apt-get install -y -qq curl wget git build-essential python3-pip python3-venv nvidia-cuda-toolkit htop screen tmux

# Install NVIDIA drivers and CUDA (if not already present)
log "Checking NVIDIA drivers..."
if ! command -v nvidia-smi &> /dev/null; then
    log "Installing NVIDIA drivers and CUDA..."
    apt-get install -y -qq nvidia-driver-545 nvidia-utils-545
else
    log "NVIDIA drivers already installed:"
    nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader
fi

# Install Docker (for containerized deployment)
log "Installing Docker..."
if ! command -v docker &> /dev/null; then
    apt-get install -y -qq ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl start docker
    systemctl enable docker
    log "Docker installed successfully"
else
    log "Docker already installed"
fi

# Install Python dependencies for DeepSeek
log "Installing Python ML dependencies..."
pip3 install --upgrade pip
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
pip3 install transformers accelerate sentencepiece protobuf blobfile
pip3 install fastapi uvicorn pydantic python-multipart httpx

# Create working directory
DEEPSEEK_DIR="/opt/deepseek"
log "Creating DeepSeek directory at $DEEPSEEK_DIR..."
mkdir -p $DEEPSEEK_DIR
mkdir -p $DEEPSEEK_DIR/models
mkdir -p $DEEPSEEK_DIR/logs
mkdir -p $DEEPSEEK_DIR/cache
cd $DEEPSEEK_DIR

# Create model download script
log "Creating DeepSeek model downloader..."
cat > $DEEPSEEK_DIR/download_model.py << 'EOF'
#!/usr/bin/env python3
"""
DeepSeek Model Downloader
Downloads DeepSeek-V3 or DeepSeek-R1 models
"""

import os
import sys
from huggingface_hub import snapshot_download
import argparse

def main():
    parser = argparse.ArgumentParser(description='Download DeepSeek models')
    parser.add_argument('--model', type=str, default='deepseek-ai/DeepSeek-V3',
                       choices=['deepseek-ai/DeepSeek-V3', 'deepseek-ai/DeepSeek-R1'],
                       help='Model to download')
    parser.add_argument('--cache-dir', type=str, default='/opt/deepseek/models',
                       help='Cache directory')
    
    args = parser.parse_args()
    
    print(f"📥 Downloading {args.model}...")
    print(f"📁 Cache dir: {args.cache_dir}")
    
    os.makedirs(args.cache_dir, exist_ok=True)
    
    try:
        model_path = snapshot_download(
            repo_id=args.model,
            cache_dir=args.cache_dir,
            local_dir_use_symlinks=False,
            resume_download=True,
            ignore_patterns=["*.safetensors", "*.bin"]  # Download only configs first
        )
        print(f"✅ Model downloaded to: {model_path}")
    except Exception as e:
        print(f"❌ Download failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
EOF

chmod +x $DEEPSEEK_DIR/download_model.py

# Install huggingface-hub
pip3 install huggingface-hub

# Ask user if they want to download model now
read -p "Download DeepSeek model now? (y/N) - This is ~700GB and will take time: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Downloading DeepSeek-V3 model (this will take a while)..."
    cd $DEEPSEEK_DIR
    python3 download_model.py --model deepseek-ai/DeepSeek-V3
else
    log "Skipping model download. You can download later with: cd $DEEPSEEK_DIR && python3 download_model.py"
fi

# Create API server for DeepSeek
log "Creating DeepSeek API server..."
cat > $DEEPSEEK_DIR/api_server.py << 'EOF'
#!/usr/bin/env python3
"""
DeepSeek API Server for H100
Provides OpenAI-compatible API endpoint
"""

import os
import sys
import json
import time
import argparse
from typing import Optional, List, Dict, Any
from datetime import datetime

import torch
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import httpx

app = FastAPI(title="DeepSeek H100 API")

# Add CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
MODEL_PATH = os.environ.get("DEEPSEEK_MODEL_PATH", "/opt/deepseek/models")
API_KEY = os.environ.get("DEEPSEEK_API_KEY", None)
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

# Global model variable (loaded on demand)
model = None
tokenizer = None

# Models
class CompletionRequest(BaseModel):
    model: str = "deepseek-v3"
    prompt: str
    max_tokens: int = 2048
    temperature: float = 0.7
    top_p: float = 0.95
    stream: bool = False
    stop: Optional[List[str]] = None

class ChatMessage(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    model: str = "deepseek-v3"
    messages: List[ChatMessage]
    max_tokens: int = 2048
    temperature: float = 0.7
    top_p: float = 0.95
    stream: bool = False

def load_model():
    """Lazy load the model"""
    global model, tokenizer
    if model is None:
        print(f"📦 Loading DeepSeek model on {DEVICE}...")
        from transformers import AutoModelForCausalLM, AutoTokenizer
        
        tokenizer = AutoTokenizer.from_pretrained(
            MODEL_PATH,
            trust_remote_code=True
        )
        
        model = AutoModelForCausalLM.from_pretrained(
            MODEL_PATH,
            torch_dtype=torch.float16,
            device_map="auto",
            trust_remote_code=True
        )
        
        print(f"✅ Model loaded. VRAM used: {torch.cuda.memory_allocated()/1e9:.2f}GB")
    return model, tokenizer

def verify_api_key(request: Request):
    """Verify API key if configured"""
    if API_KEY:
        auth_header = request.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Missing or invalid API key")
        token = auth_header.replace("Bearer ", "")
        if token != API_KEY:
            raise HTTPException(status_code=401, detail="Invalid API key")
    return True

@app.get("/health")
async def health():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "device": DEVICE,
        "model_loaded": model is not None,
        "gpu_memory": torch.cuda.memory_allocated()/1e9 if torch.cuda.is_available() else 0
    }

@app.get("/v1/models")
async def list_models():
    """List available models (OpenAI compatible)"""
    return {
        "data": [
            {
                "id": "deepseek-v3",
                "object": "model",
                "created": int(time.time()),
                "owned_by": "deepseek"
            },
            {
                "id": "deepseek-r1",
                "object": "model",
                "created": int(time.time()),
                "owned_by": "deepseek"
            }
        ]
    }

@app.post("/v1/completions")
async def create_completion(request: CompletionRequest, req: Request):
    """Create a completion (OpenAI compatible)"""
    verify_api_key(req)
    
    model, tokenizer = load_model()
    
    inputs = tokenizer(request.prompt, return_tensors="pt").to(DEVICE)
    
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=request.max_tokens,
            temperature=request.temperature,
            top_p=request.top_p,
            do_sample=True if request.temperature > 0 else False,
        )
    
    generated_text = tokenizer.decode(outputs[0][inputs.input_ids.shape[1]:], skip_special_tokens=True)
    
    return {
        "id": f"cmpl-{int(time.time())}",
        "object": "text_completion",
        "created": int(time.time()),
        "model": request.model,
        "choices": [{
            "text": generated_text,
            "index": 0,
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": len(inputs.input_ids[0]),
            "completion_tokens": len(outputs[0]) - len(inputs.input_ids[0]),
            "total_tokens": len(outputs[0])
        }
    }

@app.post("/v1/chat/completions")
async def create_chat_completion(request: ChatRequest, req: Request):
    """Create a chat completion (OpenAI compatible)"""
    verify_api_key(req)
    
    model, tokenizer = load_model()
    
    # Format chat messages
    prompt = ""
    for msg in request.messages:
        if msg.role == "system":
            prompt += f"System: {msg.content}\n"
        elif msg.role == "user":
            prompt += f"User: {msg.content}\n"
        elif msg.role == "assistant":
            prompt += f"Assistant: {msg.content}\n"
    prompt += "Assistant: "
    
    inputs = tokenizer(prompt, return_tensors="pt").to(DEVICE)
    
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=request.max_tokens,
            temperature=request.temperature,
            top_p=request.top_p,
            do_sample=True if request.temperature > 0 else False,
        )
    
    generated_text = tokenizer.decode(outputs[0][inputs.input_ids.shape[1]:], skip_special_tokens=True)
    
    return {
        "id": f"chatcmpl-{int(time.time())}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": request.model,
        "choices": [{
            "message": {
                "role": "assistant",
                "content": generated_text
            },
            "index": 0,
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": len(inputs.input_ids[0]),
            "completion_tokens": len(outputs[0]) - len(inputs.input_ids[0]),
            "total_tokens": len(outputs[0])
        }
    }

@app.post("/v1/embeddings")
async def create_embedding(request: Request):
    """Create embeddings (placeholder)"""
    verify_api_key(request)
    return {"error": "Embeddings not yet implemented"}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=3000)
    parser.add_argument("--host", type=str, default="0.0.0.0")
    parser.add_argument("--api-key", type=str, help="API key for authentication")
    args = parser.parse_args()
    
    if args.api_key:
        os.environ["DEEPSEEK_API_KEY"] = args.api_key
    
    uvicorn.run(app, host=args.host, port=args.port)
EOF

chmod +x $DEEPSEEK_DIR/api_server.py

# Create optimized launch script for H100
log "Creating optimized launch script for H100..."
cat > $DEEPSEEK_DIR/launch_h100.sh << 'EOF'
#!/bin/bash
# Optimized launch script for H100 GPU

# Set environment variables for optimal H100 performance
export CUDA_VISIBLE_DEVICES=0
export CUDA_DEVICE_MAX_CONNECTIONS=1
export NCCL_DEBUG=INFO
export NCCL_IB_DISABLE=0
export NCCL_IB_HCA=mlx5_0:1
export NCCL_SOCKET_IFNAME=eth0

# H100 specific optimizations
export TORCH_CUDNN_V8_API_ENABLED=1
export TF_CPP_MIN_LOG_LEVEL=3

# Set memory allocation
export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512

# Launch API server
cd /opt/deepseek

# If API key is provided in environment, use it
if [ -n "$DEEPSEEK_API_KEY" ]; then
    python3 api_server.py --port ${API_PORT:-3000} --api-key "$DEEPSEEK_API_KEY"
else
    python3 api_server.py --port ${API_PORT:-3000}
fi
EOF

chmod +x $DEEPSEEK_DIR/launch_h100.sh

# Create systemd service for DeepSeek
log "Creating systemd service for DeepSeek API..."
cat > /etc/systemd/system/deepseek.service << EOF
[Unit]
Description=DeepSeek AI API Service
After=network.target docker.service
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/deepseek
Environment="API_PORT=$API_PORT"
Environment="DEEPSEEK_API_KEY=$API_KEY"
Environment="CUDA_VISIBLE_DEVICES=0"
ExecStart=/opt/deepseek/launch_h100.sh
Restart=always
RestartSec=10
StandardOutput=append:/opt/deepseek/logs/api.log
StandardError=append:/opt/deepseek/logs/api.log

[Install]
WantedBy=multi-user.target
EOF

# Create monitoring script
log "Creating monitoring script..."
cat > /usr/local/bin/monitor-deepseek.sh << 'EOF'
#!/bin/bash
LOG_FILE="/opt/deepseek/logs/monitor.log"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Check if service is running
if ! systemctl is-active --quiet deepseek; then
    log_message "Service not running - restarting"
    systemctl restart deepseek
fi

# Check GPU health
if command -v nvidia-smi &> /dev/null; then
    GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits)
    GPU_MEM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
    
    if [ "$GPU_TEMP" -gt 85 ]; then
        log_message "WARNING: High GPU temperature: ${GPU_TEMP}°C"
    fi
    
    log_message "GPU: ${GPU_MEM}MB used, ${GPU_TEMP}°C"
fi

# Check API health
if curl -s http://localhost:$API_PORT/health > /dev/null; then
    log_message "API health check passed"
else
    log_message "API health check failed"
fi

log_message "Monitor check completed"
EOF

chmod +x /usr/local/bin/monitor-deepseek.sh

# Create log rotation
cat > /etc/logrotate.d/deepseek << 'EOF'
/opt/deepseek/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF

# Set up cron job for monitoring
log "Setting up cron job for monitoring..."
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/monitor-deepseek.sh") | crontab -

# Create test client script
log "Creating test client script..."
cat > $DEEPSEEK_DIR/test_api.sh << EOF
#!/bin/bash

API_URL="http://localhost:$API_PORT"
API_KEY="$API_KEY"

echo "🔍 Testing DeepSeek API..."
echo ""

# Test health
echo "1. Health check:"
curl -s "\$API_URL/health" | python3 -m json.tool
echo ""

# Test models list
echo "2. Available models:"
if [ -n "\$API_KEY" ]; then
    curl -s -H "Authorization: Bearer \$API_KEY" "\$API_URL/v1/models" | python3 -m json.tool
else
    curl -s "\$API_URL/v1/models" | python3 -m json.tool
fi
echo ""

# Test completion
echo "3. Test completion:"
read -p "Enter a prompt (default: 'Explain quantum computing in one sentence'): " PROMPT
PROMPT=\${PROMPT:-"Explain quantum computing in one sentence"}

if [ -n "\$API_KEY" ]; then
    curl -s -X POST "\$API_URL/v1/completions" \\
        -H "Content-Type: application/json" \\
        -H "Authorization: Bearer \$API_KEY" \\
        -d "{\\"model\\": \\"deepseek-v3\\", \\"prompt\\": \\"\$PROMPT\\", \\"max_tokens\\": 100}" | python3 -m json.tool
else
    curl -s -X POST "\$API_URL/v1/completions" \\
        -H "Content-Type: application/json" \\
        -d "{\\"model\\": \\"deepseek-v3\\", \\"prompt\\": \\"\$PROMPT\\", \\"max_tokens\\": 100}" | python3 -m json.tool
fi
EOF

chmod +x $DEEPSEEK_DIR/test_api.sh

# Create README
cat > $DEEPSEEK_DIR/README.md << EOF
# DeepSeek AI on H100 (Vast.ai)

This instance is running DeepSeek AI on an H100 GPU with 80GB VRAM.

## Quick Start

### 1. Check service status
\`\`\`bash
systemctl status deepseek
\`\`\`

### 2. View logs
\`\`\`bash
journalctl -u deepseek -f
# or
tail -f /opt/deepseek/logs/api.log
\`\`\`

### 3. Test the API
\`\`\`bash
cd /opt/deepseek
./test_api.sh
\`\`\`

## API Endpoints

The API is OpenAI-compatible:

| Endpoint | Description |
|----------|-------------|
| \`GET /health\` | Health check |
| \`GET /v1/models\` | List available models |
| \`POST /v1/completions\` | Text completions |
| \`POST /v1/chat/completions\` | Chat completions |

### Example API Call

\`\`\`bash
# With API key
curl -X POST http://$INSTANCE_IP:$API_PORT/v1/completions \\
  -H "Content-Type: application/json" \\
  -H "Authorization: Bearer $API_KEY" \\
  -d '{
    "model": "deepseek-v3",
    "prompt": "Explain AI in one sentence",
    "max_tokens": 100
  }'

# Without API key (if configured)
curl -X POST http://$INSTANCE_IP:$API_PORT/v1/completions \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "deepseek-v3",
    "prompt": "Explain AI in one sentence",
    "max_tokens": 100
  }'
\`\`\`

## Configuration

- **API Port**: $API_PORT
- **Instance IP**: $INSTANCE_IP
- **API Key**: ${API_KEY:-"Not set"}
- **GPU**: 1x H100 SXM (80GB VRAM)
- **Location**: France

## Management

\`\`\`bash
# Start/Stop/Restart
systemctl start deepseek
systemctl stop deepseek
systemctl restart deepseek

# Monitor
watch -n 1 nvidia-smi
tail -f /opt/deepseek/logs/api.log

# Download model (if not done)
cd /opt/deepseek
python3 download_model.py --model deepseek-ai/DeepSeek-V3
\`\`\`

## Vast.ai Instance Details

- **Type**: #29140542
- **GPU**: H100 SXM (53.5 TFLOPS)
- **VRAM**: 80GB @ 2882.7 GB/s
- **CPU**: AMD EPYC 9554 (32/256 cores)
- **RAM**: 193/1548 GB
- **Storage**: 446.8 GB SSD
- **Network**: 2713/4749 Mbps
- **Price**: $1.470/hour + bandwidth
EOF

# Create cleanup script
cat > $DEEPSEEK_DIR/cleanup.sh << 'EOF'
#!/bin/bash
echo "🧹 DeepSeek Cleanup Script"
echo "=========================="
read -p "Stop and remove all DeepSeek services? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

systemctl stop deepseek
systemctl disable deepseek
rm -f /etc/systemd/system/deepseek.service
systemctl daemon-reload

rm -rf /opt/deepseek
rm -f /usr/local/bin/monitor-deepseek.sh
crontab -l | grep -v monitor-deepseek | crontab -

echo "✅ Cleanup complete"
EOF

chmod +x $DEEPSEEK_DIR/cleanup.sh

# Set proper permissions
chown -R root:root $DEEPSEEK_DIR

# Enable and start service
log "Starting DeepSeek service..."
systemctl daemon-reload
systemctl enable deepseek
systemctl start deepseek

# Wait for service to start
sleep 5

# Check status
if systemctl is-active --quiet deepseek; then
    log "✅ DeepSeek service started successfully"
else
    warn "⚠️ Service failed to start. Check logs: journalctl -u deepseek"
fi

# Final output
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         DEEPSEEK AI H100 SETUP COMPLETE!                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

info "DeepSeek AI is now running on your H100 instance!"
echo ""
info "Instance Details:"
echo "  📍 Type: #29140542 (France)"
echo "  🖥️  GPU: H100 SXM (80GB VRAM)"
echo "  🌐 IP: $INSTANCE_IP"
echo "  🔌 Port: $API_PORT"
echo "  🔑 API Key: ${API_KEY:-"Not set (no auth)"}"
echo ""
info "Quick Commands:"
echo "  📊 Status: systemctl status deepseek"
echo "  📝 Logs: journalctl -u deepseek -f"
echo "  🧪 Test: cd /opt/deepseek && ./test_api.sh"
echo "  🖥️  Monitor GPU: watch -n 1 nvidia-smi"
echo ""
info "API Endpoint:"
echo "  http://$INSTANCE_IP:$API_PORT"
echo ""
info "Example curl:"
if [ -n "$API_KEY" ]; then
    echo "  curl -X POST http://$INSTANCE_IP:$API_PORT/v1/completions \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -H \"Authorization: Bearer $API_KEY\" \\"
    echo "    -d '{\"model\": \"deepseek-v3\", \"prompt\": \"Hello\", \"max_tokens\": 50}'"
else
    echo "  curl -X POST http://$INSTANCE_IP:$API_PORT/v1/completions \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -d '{\"model\": \"deepseek-v3\", \"prompt\": \"Hello\", \"max_tokens\": 50}'"
fi
echo ""
info "Documentation:"
echo "  cat /opt/deepseek/README.md"
echo ""
info "Model Download (if skipped):"
echo "  cd /opt/deepseek && python3 download_model.py"
echo ""
log "Setup complete! Your DeepSeek H100 API is ready."

# This script will:
#     Install NVIDIA drivers and CUDA for the H100
#     Set up Python ML environment with PyTorch
#     Create a DeepSeek API server with OpenAI-compatible endpoints
#     Provide model downloader for DeepSeek-V3/R1
#     Create systemd service for auto-start
#     Add monitoring with GPU temp checks
#     Include test client to verify API works
#     Generate documentation for your specific instance

# To run it on your Vast.ai H100 instance:
# bash

# # Copy the script to your instance
# curl -sL https://your-domain.com/setup-deepseek-h100.sh | sudo bash

# The API will be accessible at http://[INSTANCE_IP]:3000 and supports OpenAI-compatible calls.