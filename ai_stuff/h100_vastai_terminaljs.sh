#!/bin/bash

# DeepSeek AI H100 + Web Terminal Setup Script for Vast.ai
# Complete deployment with browser-based SSH access
# Usage: curl -sL https://your-domain.com/setup-deepseek-webterm.sh | sudo bash

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
echo "║  DeepSeek AI H100 + Web Terminal for Vast.ai            ║"
echo "║  1x H100 SXM | 80GB VRAM | Browser SSH + API            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Configuration
DEEPSEEK_DIR="/opt/deepseek"
WEBTERM_DIR="/opt/web-terminal"
DEEPSEEK_PORT=3000
WEBTERM_PORT=3001
SSH_PORT=22
NODE_VERSION="18"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    warn "Not running as root. Some commands may need sudo."
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for sudo access
if ! sudo -v; then
    error "This script requires sudo access"
fi

# Get configuration
echo ""
info "Please provide configuration details:"
echo "-------------------------------------"

# Get API port for DeepSeek
get_input "Enter DeepSeek API port" "3000" DEEPSEEK_PORT

# Get web terminal port
get_input "Enter Web Terminal port" "3001" WEBTERM_PORT

# Get API key (optional)
read -p "Enter API key for DeepSeek authentication (leave empty for no auth): " DEEPSEEK_API_KEY

# Get instance IP (auto-detected)
INSTANCE_IP=$(curl -s --fail ifconfig.me 2>/dev/null || curl -s --fail http://checkip.amazonaws.com 2>/dev/null || echo "UNKNOWN")
info "Detected instance IP: $INSTANCE_IP"

echo ""
log "Starting DeepSeek AI + Web Terminal Setup..."
log "DeepSeek Port: $DEEPSEEK_PORT"
log "Web Terminal Port: $WEBTERM_PORT"
log "Instance IP: $INSTANCE_IP"

# ============= PART 1: SYSTEM PREPARATION =============
log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

log "Installing required tools..."
apt-get install -y -qq curl wget git build-essential python3-pip python3-venv \
    nvidia-cuda-toolkit htop screen tmux nginx openssl

# Install Node.js
log "Installing Node.js $NODE_VERSION..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
    apt-get install -y -qq nodejs
fi
log "✓ Node.js $(node --version) installed"

# Install PM2 for process management
log "Installing PM2..."
npm install -g pm2

# Check NVIDIA drivers
log "Checking NVIDIA drivers..."
if ! command -v nvidia-smi &> /dev/null; then
    log "Installing NVIDIA drivers and CUDA..."
    apt-get install -y -qq nvidia-driver-545 nvidia-utils-545
else
    log "NVIDIA drivers already installed:"
    nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader
fi

# Install Docker (optional)
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

# Create swap file (for safety)
if [ ! -f /swapfile ]; then
    log "Creating swap file..."
    fallocate -l 32G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap file created (32GB)"
fi

# ============= PART 2: DEEPSEEK AI SETUP =============
log "Installing Python ML dependencies..."
pip3 install --upgrade pip
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
pip3 install transformers accelerate sentencepiece protobuf blobfile
pip3 install fastapi uvicorn pydantic python-multipart httpx huggingface-hub

log "Creating DeepSeek directory at $DEEPSEEK_DIR..."
mkdir -p $DEEPSEEK_DIR
mkdir -p $DEEPSEEK_DIR/models
mkdir -p $DEEPSEEK_DIR/logs
mkdir -p $DEEPSEEK_DIR/cache
cd $DEEPSEEK_DIR

# Create model download script
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

# Create DeepSeek API server
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
cat > $DEEPSEEK_DIR/launch_h100.sh << EOF
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
cd $DEEPSEEK_DIR

# If API key is provided in environment, use it
if [ -n "$DEEPSEEK_API_KEY" ]; then
    python3 api_server.py --port ${DEEPSEEK_PORT:-3000} --api-key "$DEEPSEEK_API_KEY"
else
    python3 api_server.py --port ${DEEPSEEK_PORT:-3000}
fi
EOF

chmod +x $DEEPSEEK_DIR/launch_h100.sh

# ============= PART 3: WEB TERMINAL SETUP =============
log "Setting up Web-based SSH Terminal..."

mkdir -p $WEBTERM_DIR
mkdir -p $WEBTERM_DIR/{public,server,ssl,logs}
cd $WEBTERM_DIR

# Create package.json
cat > $WEBTERM_DIR/package.json << 'EOF'
{
  "name": "web-ssh-terminal",
  "version": "1.0.0",
  "description": "Browser-based SSH terminal for H100 access",
  "main": "server/index.js",
  "scripts": {
    "start": "node server/index.js",
    "dev": "nodemon server/index.js"
  },
  "dependencies": {
    "@xterm/xterm": "^5.5.0",
    "@xterm/addon-fit": "^0.8.0",
    "@xterm/addon-attach": "^0.8.0",
    "@xterm/addon-web-links": "^0.8.0",
    "express": "^4.18.2",
    "socket.io": "^4.6.1",
    "ssh2": "^1.15.0",
    "helmet": "^7.0.0",
    "compression": "^1.7.4",
    "express-rate-limit": "^6.7.0"
  },
  "devDependencies": {
    "nodemon": "^2.0.22"
  }
}
EOF

# Install npm dependencies
cd $WEBTERM_DIR
npm install

# Create backend server
cat > $WEBTERM_DIR/server/index.js << 'EOF'
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const { Client } = require('ssh2');
const path = require('path');
const helmet = require('helmet');
const compression = require('compression');
const rateLimit = require('express-rate-limit');
const fs = require('fs');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
    cors: {
        origin: "*",
        methods: ["GET", "POST"]
    }
});

// Security middleware
app.use(helmet({
    contentSecurityPolicy: {
        directives: {
            defaultSrc: ["'self'"],
            styleSrc: ["'self'", "'unsafe-inline'"],
            scriptSrc: ["'self'", "'unsafe-inline'", "'unsafe-eval'"],
            imgSrc: ["'self'", "data:", "https:"],
        },
    },
}));

// Compression
app.use(compression());

// Rate limiting
const limiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 100
});
app.use('/api/', limiter);

// Serve static files
app.use(express.static(path.join(__dirname, '../public')));

// SSH Connection handling
io.on('connection', (socket) => {
    console.log(`Client connected: ${socket.id}`);
    
    let sshClient = new Client();
    let stream;

    socket.on('connect-ssh', (config) => {
        console.log(`SSH connection attempt to ${config.host}:${config.port} as ${config.username}`);
        
        sshClient.on('ready', () => {
            console.log('SSH connection ready');
            
            sshClient.shell({ term: 'xterm-256color', cols: 80, rows: 24 }, (err, sshStream) => {
                if (err) {
                    socket.emit('data', `\r\n*** SSH shell error: ${err.message}\r\n`);
                    return;
                }
                
                stream = sshStream;
                
                stream.on('data', (data) => {
                    socket.emit('data', data.toString('utf-8'));
                });
                
                stream.on('close', () => {
                    console.log('SSH stream closed');
                    sshClient.end();
                    socket.emit('data', '\r\n*** SSH connection closed ***\r\n');
                });
                
                socket.emit('data', '\r\n*** SSH connection established to H100 ***\r\n');
                socket.emit('data', `Welcome to DeepSeek AI H100 Instance\r\n`);
                socket.emit('data', `Instance IP: ${config.host}\r\n`);
                socket.emit('data', `GPU: H100 80GB\r\n`);
                socket.emit('data', `DeepSeek API: http://localhost:3000\r\n`);
                socket.emit('data', `\r\n$ `);
            });
        });
        
        sshClient.on('error', (err) => {
            console.error('SSH connection error:', err);
            socket.emit('data', `\r\n*** SSH connection error: ${err.message}\r\n`);
        });
        
        sshClient.connect({
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password,
            privateKey: config.privateKey,
            readyTimeout: 20000
        });
    });
    
    socket.on('input', (data) => {
        if (stream && stream.writable) {
            stream.write(data);
        }
    });
    
    socket.on('resize', (cols, rows) => {
        if (stream && stream.setWindow) {
            stream.setWindow(rows, cols, 0, 0);
        }
    });
    
    socket.on('disconnect', () => {
        console.log(`Client disconnected: ${socket.id}`);
        if (stream) {
            stream.end();
        }
        sshClient.end();
    });
});

// API endpoint to check status
app.get('/api/status', (req, res) => {
    res.json({ 
        status: 'running', 
        timestamp: new Date().toISOString(),
        services: {
            deepseek: {
                port: process.env.DEEPSEEK_PORT || 3000,
                endpoint: `http://localhost:${process.env.DEEPSEEK_PORT || 3000}`
            }
        }
    });
});

// Serve main page
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, '../public/index.html'));
});

const PORT = process.env.PORT || 3001;
server.listen(PORT, '0.0.0.0', () => {
    console.log(`Web SSH Terminal running on http://0.0.0.0:${PORT}`);
    console.log(`DeepSeek API available at http://localhost:${process.env.DEEPSEEK_PORT || 3000}`);
});
EOF

# Create frontend with xterm.js
cat > $WEBTERM_DIR/public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DeepSeek H100 - Web Terminal</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #0b1729 0%, #1a2639 100%);
            height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
        }
        
        .container {
            width: 95%;
            max-width: 1400px;
            height: 90vh;
            background: #0f172a;
            border-radius: 12px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.5);
            overflow: hidden;
            display: flex;
            flex-direction: column;
            border: 1px solid #2d3a5e;
        }
        
        .header {
            background: #1e293b;
            color: #e2e8f0;
            padding: 15px 20px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            border-bottom: 1px solid #334155;
        }
        
        .title {
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .title h1 {
            font-size: 1.2rem;
            font-weight: 500;
        }
        
        .title .badge {
            background: #3b82f6;
            color: white;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 0.7rem;
            font-weight: 600;
        }
        
        .connection-form {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
            align-items: center;
        }
        
        .connection-form input {
            padding: 8px 12px;
            border: 1px solid #334155;
            background: #0f172a;
            color: #e2e8f0;
            border-radius: 6px;
            font-size: 14px;
            min-width: 120px;
        }
        
        .connection-form input::placeholder {
            color: #64748b;
        }
        
        .connection-form button {
            padding: 8px 20px;
            background: #3b82f6;
            color: white;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            font-weight: 600;
            transition: background 0.2s;
        }
        
        .connection-form button:hover {
            background: #2563eb;
        }
        
        .connection-form button.disconnect {
            background: #ef4444;
        }
        
        .connection-form button.disconnect:hover {
            background: #dc2626;
        }
        
        .status-indicator {
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 14px;
        }
        
        .status-dot {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            background: #ef4444;
            transition: background 0.3s;
        }
        
        .status-dot.connected {
            background: #10b981;
        }
        
        #terminal-container {
            flex: 1;
            padding: 10px;
            background: #0a0e1a;
        }
        
        .info-bar {
            background: #1e293b;
            color: #94a3b8;
            padding: 8px 20px;
            font-size: 12px;
            display: flex;
            gap: 20px;
            border-top: 1px solid #334155;
        }
        
        .info-bar span {
            color: #e2e8f0;
            font-weight: 600;
        }
        
        .info-bar .api-info {
            margin-left: auto;
            background: #2d3a5e;
            padding: 2px 8px;
            border-radius: 4px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="title">
                <h1>🔮 DeepSeek H100 Terminal</h1>
                <span class="badge">80GB VRAM</span>
            </div>
            <div class="connection-form">
                <input type="text" id="host" placeholder="Host" value="localhost">
                <input type="text" id="port" placeholder="Port" value="22">
                <input type="text" id="username" placeholder="Username" value="root">
                <input type="password" id="password" placeholder="Password">
                <button id="connect-btn">🔌 Connect SSH</button>
                <button id="disconnect-btn" class="disconnect" style="display: none;">🔌 Disconnect</button>
            </div>
            <div class="status-indicator">
                <div class="status-dot" id="status-dot"></div>
                <span id="status-text">Disconnected</span>
            </div>
        </div>
        
        <div id="terminal-container"></div>
        
        <div class="info-bar">
            <div>⚡ <span>H100 SXM</span> | 80GB VRAM | 2882 GB/s</div>
            <div>📡 <span>DeepSeek API</span> :3000</div>
            <div class="api-info">🔑 API Key: ${DEEPSEEK_API_KEY:-"Not Set"}</div>
        </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/socket.io@4.6.1/client-dist/socket.io.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.8.0/lib/addon-fit.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-web-links@0.8.0/lib/addon-web-links.min.js"></script>
    
    <script>
        const socket = io();
        const term = new Terminal({
            cursorBlink: true,
            cursorStyle: 'block',
            theme: {
                background: '#0a0e1a',
                foreground: '#e2e8f0',
                cursor: '#e2e8f0',
                selection: '#334155',
                black: '#1e293b',
                red: '#ef4444',
                green: '#10b981',
                yellow: '#f59e0b',
                blue: '#3b82f6',
                magenta: '#8b5cf6',
                cyan: '#06b6d4',
                white: '#e2e8f0'
            },
            fontSize: 14,
            fontFamily: 'Menlo, Monaco, "Courier New", monospace',
            scrollback: 50000
        });
        
        const fitAddon = new FitAddon();
        const webLinksAddon = new WebLinksAddon();
        
        term.loadAddon(fitAddon);
        term.loadAddon(webLinksAddon);
        
        term.open(document.getElementById('terminal-container'));
        fitAddon.fit();
        
        term.writeln('\x1b[1;36m╔══════════════════════════════════════════════════════════╗\x1b[0m');
        term.writeln('\x1b[1;36m║      DeepSeek AI H100 - Web Terminal Ready                ║\x1b[0m');
        term.writeln('\x1b[1;36m╚══════════════════════════════════════════════════════════╝\x1b[0m');
        term.writeln('');
        term.writeln('\x1b[1;33m📡 Enter SSH credentials above to connect\x1b[0m');
        term.writeln('');
        
        window.addEventListener('resize', () => {
            fitAddon.fit();
            if (socket.connected) {
                socket.emit('resize', term.cols, term.rows);
            }
        });
        
        term.onData(data => {
            if (socket.connected) {
                socket.emit('input', data);
            }
        });
        
        socket.on('data', (data) => {
            term.write(data);
        });
        
        socket.on('disconnect', () => {
            updateConnectionStatus(false);
            term.writeln('\r\n\x1b[1;31m*** Disconnected from server ***\x1b[0m\r\n');
        });
        
        const connectBtn = document.getElementById('connect-btn');
        const disconnectBtn = document.getElementById('disconnect-btn');
        const hostInput = document.getElementById('host');
        const portInput = document.getElementById('port');
        const usernameInput = document.getElementById('username');
        const passwordInput = document.getElementById('password');
        const statusDot = document.getElementById('status-dot');
        const statusText = document.getElementById('status-text');
        
        function updateConnectionStatus(connected) {
            if (connected) {
                statusDot.classList.add('connected');
                statusText.textContent = 'Connected';
                connectBtn.style.display = 'none';
                disconnectBtn.style.display = 'inline-block';
                hostInput.disabled = true;
                portInput.disabled = true;
                usernameInput.disabled = true;
                passwordInput.disabled = true;
            } else {
                statusDot.classList.remove('connected');
                statusText.textContent = 'Disconnected';
                connectBtn.style.display = 'inline-block';
                disconnectBtn.style.display = 'none';
                hostInput.disabled = false;
                portInput.disabled = false;
                usernameInput.disabled = false;
                passwordInput.disabled = false;
            }
        }
        
        connectBtn.addEventListener('click', () => {
            const config = {
                host: hostInput.value || 'localhost',
                port: parseInt(portInput.value) || 22,
                username: usernameInput.value,
                password: passwordInput.value
            };
            
            if (!config.username) {
                term.writeln('\x1b[1;31m❌ Please enter username\x1b[0m');
                return;
            }
            
            term.writeln(`\x1b[1;33m🔌 Connecting to ${config.username}@${config.host}:${config.port}...\x1b[0m`);
            socket.emit('connect-ssh', config);
            updateConnectionStatus(true);
        });
        
        disconnectBtn.addEventListener('click', () => {
            socket.disconnect();
            socket.connect();
            updateConnectionStatus(false);
            term.clear();
            term.writeln('\x1b[1;36m╔══════════════════════════════════════════════════════════╗\x1b[0m');
            term.writeln('\x1b[1;36m║      DeepSeek AI H100 - Web Terminal Ready                ║\x1b[0m');
            term.writeln('\x1b[1;36m╚══════════════════════════════════════════════════════════╝\x1b[0m');
            term.writeln('');
            term.writeln('\x1b[1;33m📡 Enter SSH credentials above to connect\x1b[0m');
        });
        
        passwordInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') {
                connectBtn.click();
            }
        });
        
        updateConnectionStatus(false);
        usernameInput.focus();
    </script>
</body>
</html>
EOF

chmod -R 755 $WEBTERM_DIR

# Create PM2 ecosystem file for both services
cat > /opt/ecosystem.config.js << EOF
module.exports = {
    apps: [
        {
            name: 'deepseek-api',
            cwd: '$DEEPSEEK_DIR',
            script: 'launch_h100.sh',
            interpreter: 'bash',
            watch: false,
            instances: 1,
            exec_mode: 'fork',
            max_memory_restart: '80G',
            env: {
                DEEPSEEK_API_KEY: '$DEEPSEEK_API_KEY',
                DEEPSEEK_PORT: $DEEPSEEK_PORT,
                CUDA_VISIBLE_DEVICES: '0'
            },
            error_file: '$DEEPSEEK_DIR/logs/api-error.log',
            out_file: '$DEEPSEEK_DIR/logs/api-out.log'
        },
        {
            name: 'web-terminal',
            cwd: '$WEBTERM_DIR',
            script: 'server/index.js',
            interpreter: 'node',
            watch: false,
            instances: 1,
            exec_mode: 'fork',
            max_memory_restart: '1G',
            env: {
                PORT: $WEBTERM_PORT,
                DEEPSEEK_PORT: $DEEPSEEK_PORT
            },
            error_file: '$WEBTERM_DIR/logs/terminal-error.log',
            out_file: '$WEBTERM_DIR/logs/terminal-out.log'
        }
    ]
};
EOF

# Start PM2 services
log "Starting PM2 services..."
pm2 start /opt/ecosystem.config.js
pm2 save
pm2 startup

# Create nginx configuration
log "Creating nginx reverse proxy..."
cat > /etc/nginx/sites-available/deepseek << EOF
server {
    listen 80;
    server_name _;
    
    # Web Terminal
    location / {
        proxy_pass http://localhost:$WEBTERM_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # DeepSeek API
    location /api/ {
        proxy_pass http://localhost:$DEEPSEEK_PORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
}
EOF

# Enable nginx site
ln -sf /etc/nginx/sites-available/deepseek /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# Create monitoring script
cat > /usr/local/bin/monitor-deepseek.sh << 'EOF'
#!/bin/bash
LOG_FILE="/opt/deepseek/logs/monitor.log"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Check PM2 processes
if ! pm2 list | grep -q "deepseek-api"; then
    log_message "DeepSeek API not running - restarting"
    pm2 restart deepseek-api
fi

if ! pm2 list | grep -q "web-terminal"; then
    log_message "Web Terminal not running - restarting"
    pm2 restart web-terminal
fi

# Check GPU health
if command -v nvidia-smi &> /dev/null; then
    GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits)
    GPU_MEM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
    GPU_MEM_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits)
    
    if [ "$GPU_TEMP" -gt 85 ]; then
        log_message "⚠️ High GPU temperature: ${GPU_TEMP}°C"
    fi
    
    log_message "GPU: ${GPU_MEM}MB/${GPU_MEM_TOTAL}MB used, ${GPU_TEMP}°C"
fi

# Check API health
if curl -s http://localhost:$DEEPSEEK_PORT/health > /dev/null; then
    log_message "DeepSeek API health check passed"
else
    log_message "❌ DeepSeek API health check failed"
fi

# Check Web Terminal health
if curl -s http://localhost:$WEBTERM_PORT/api/status > /dev/null; then
    log_message "Web Terminal health check passed"
else
    log_message "❌ Web Terminal health check failed"
fi

log_message "Monitor check completed"
EOF

chmod +x /usr/local/bin/monitor-deepseek.sh

# Set up cron for monitoring
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/monitor-deepseek.sh") | crontab -

# Create test script
cat > /opt/test-deepseek.sh << EOF
#!/bin/bash

echo "🔍 Testing DeepSeek H100 Setup"
echo "==============================="
echo ""

# Test DeepSeek API
echo "1. Testing DeepSeek API..."
if curl -s http://localhost:$DEEPSEEK_PORT/health | grep -q "healthy"; then
    echo "   ✅ DeepSeek API is running"
else
    echo "   ❌ DeepSeek API not responding"
fi

# Test Web Terminal
echo "2. Testing Web Terminal..."
if curl -s http://localhost:$WEBTERM_PORT/api/status | grep -q "running"; then
    echo "   ✅ Web Terminal is running"
    echo "   📍 Access at: http://$INSTANCE_IP:$WEBTERM_PORT"
else
    echo "   ❌ Web Terminal not responding"
fi

# Test GPU
echo "3. Checking GPU..."
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=name,memory.total,temperature.gpu --format=csv,noheader
    echo "   ✅ GPU is available"
else
    echo "   ❌ GPU not detected"
fi

echo ""
echo "🌐 Access URLs:"
echo "   Web Terminal: http://$INSTANCE_IP:$WEBTERM_PORT"
echo "   DeepSeek API: http://$INSTANCE_IP:$DEEPSEEK_PORT"
echo "   DeepSeek Health: http://$INSTANCE_IP:$DEEPSEEK_PORT/health"
echo ""
if [ -n "$DEEPSEEK_API_KEY" ]; then
    echo "🔑 API Key: $DEEPSEEK_API_KEY"
fi
EOF

chmod +x /opt/test-deepseek.sh

# Final output
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   DEEPSEEK H100 + WEB TERMINAL SETUP COMPLETE!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

info "Your H100 instance is now fully equipped!"
echo ""
info "📡 SERVICES RUNNING:"
echo "   • DeepSeek API:    http://$INSTANCE_IP:$DEEPSEEK_PORT"
echo "   • Web Terminal:    http://$INSTANCE_IP:$WEBTERM_PORT"
echo "   • SSH Access:      ssh user@$INSTANCE_IP -p $SSH_PORT"
echo ""
info "🔑 API Authentication:"
if [ -n "$DEEPSEEK_API_KEY" ]; then
    echo "   • API Key: $DEEPSEEK_API_KEY"
    echo "   • Use in requests: -H \"Authorization: Bearer $DEEPSEEK_API_KEY\""
else
    echo "   • No API key configured (open access)"
fi
echo ""
info "📊 MANAGEMENT COMMANDS:"
echo "   • PM2 Status:      pm2 list"
echo "   • View DeepSeek logs: pm2 logs deepseek-api"
echo "   • View Terminal logs: pm2 logs web-terminal"
echo "   • Monitor GPU:     watch -n 1 nvidia-smi"
echo "   • Test everything:  /opt/test-deepseek.sh"
echo ""
info "🌐 WEB TERMINAL ACCESS:"
echo "   • Open in browser: http://$INSTANCE_IP:$WEBTERM_PORT"
echo "   • Login with your SSH credentials"
echo "   • Full terminal access from anywhere!"
echo ""
info "🚀 DEEPSEEK API EXAMPLE:"
echo "curl -X POST http://$INSTANCE_IP:$DEEPSEEK_PORT/v1/completions \\"
echo "  -H \"Content-Type: application/json\" \\"
if [ -n "$DEEPSEEK_API_KEY" ]; then
    echo "  -H \"Authorization: Bearer $DEEPSEEK_API_KEY\" \\"
fi
echo "  -d '{\"model\": \"deepseek-v3\", \"prompt\": \"Hello\", \"max_tokens\": 50}'"
echo ""
info "📁 INSTALLATION PATHS:"
echo "   • DeepSeek: $DEEPSEEK_DIR"
echo "   • Web Terminal: $WEBTERM_DIR"
echo "   • PM2 Config: /opt/ecosystem.config.js"
echo ""
info "⏰ MODEL DOWNLOAD (if skipped):"
echo "   cd $DEEPSEEK_DIR && python3 download_model.py"
echo ""
log "✅ Setup complete! Your H100 is ready for action!"

# This extended script now gives you:
#     DeepSeek AI API running on port 3000 with OpenAI-compatible endpoints
#     Web-based SSH terminal on port 3001 - access your H100 from ANY browser
#     PM2 process management for both services with auto-restart
#     Nginx reverse proxy for clean access
#     GPU monitoring with temperature alerts
#     Health checks and auto-recovery
#     Beautiful terminal UI with xterm.js showing GPU stats and API info

# To use it:
# bash

# curl -sL https://your-domain.com/setup-deepseek-webterm.sh | sudo bash

# Then open http://[YOUR_VAST_IP]:3001 in any browser to access your H100 terminal!