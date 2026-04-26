#!/bin/bash

# DeepSeek AI H200 + Vector Database + Web Terminal Setup
# Optimized for DigitalOcean 1× H200 (141GB VRAM) Droplet
# Usage: curl -sL https://your-domain.com/setup-deepseek-h200-do.sh | sudo bash

# Force non-interactive mode
export DEBIAN_FRONTEND=noninteractive

set -e  # Exit on error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Display banner
echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     DeepSeek H200 + VectorDB - DigitalOcean Optimized         ║"
echo "║     1× H200 | 141GB VRAM | 24 vCPU | 240GB RAM               ║"
echo "║     Cost: $3.89/hr - Making every GPU cycle count!            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ===== DIGITALOCEAN OPTIMIZED CONFIGURATION =====
DEEPSEEK_DIR="/opt/deepseek"
WEBTERM_DIR="/opt/web-terminal"
VECTORDB_DIR="/opt/vectordb"
UPLOAD_DIR="/opt/uploads"
TEMPLATES_DIR="/opt/templates"
MODELS_DIR="/opt/models"
SCRATCH_DIR="/mnt/scratch"

DEEPSEEK_PORT=3000
WEBTERM_PORT=3001
VECTORDB_PORT=3002
UPLOAD_PORT=3003

# DigitalOcean H200 Specs
NUM_GPUS=1
GPU_MEM_GB=141
TOTAL_RAM_GB=240
CPU_CORES=24

# Performance tuning for single H200
BATCH_SIZE=32
EMBEDDING_DIM=1024
MAX_SEARCH_RESULTS=100
CACHE_SIZE_GB=100  # Use 100GB for cache

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
info "DigitalOcean H200 Configuration:"
echo "-------------------------------------"
echo "GPU: 1× H200 (141GB VRAM)"
echo "vCPU: 24 cores"
echo "RAM: 240GB"
echo "Boot Disk: 720GB NVMe"
echo "Scratch Disk: 5TB NVMe"
echo "Cost: $3.89/hour"
echo ""

read -p "Enter DeepSeek API port [3000]: " input
DEEPSEEK_PORT=${input:-3000}

read -p "Enter Web Terminal port [3001]: " input
WEBTERM_PORT=${input:-3001}

read -p "Enter VectorDB API port [3002]: " input
VECTORDB_PORT=${input:-3002}

read -p "Enter API key for authentication (leave empty for no auth): " DEEPSEEK_API_KEY

INSTANCE_IP=$(curl -s --fail ifconfig.me 2>/dev/null || curl -s --fail http://checkip.amazonaws.com 2>/dev/null || echo "UNKNOWN")
info "Detected instance IP: $INSTANCE_IP"

# ===== PART 1: SYSTEM OPTIMIZATION FOR H200 =====
log "Optimizing system for H200 GPU..."

# Update system
apt-get update -qq
apt-get upgrade -y -qq

# Install essentials
apt-get install -y -qq curl wget git build-essential python3-pip python3-venv \
    nvidia-cuda-toolkit htop screen tmux nginx openssl \
    infiniband-diags ibverbs-utils libaio-dev \
    postgresql postgresql-contrib redis-server \
    tesseract-ocr poppler-utils ffmpeg libmagic-dev \
    tmux htop iotop iftop nvtop  # Monitoring tools

# Install Node.js 18
log "Installing Node.js 18..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    apt-get install -y -qq nodejs
fi

# Install PM2
npm install -g pm2

# Check NVIDIA driver
log "Checking NVIDIA driver..."
if ! command -v nvidia-smi &> /dev/null; then
    log "Installing NVIDIA drivers..."
    apt-get install -y -qq nvidia-driver-545 nvidia-utils-545
    log "NVIDIA driver installed. A reboot may be required."
else
    log "NVIDIA drivers already installed:"
    nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader
fi

# Install Docker with NVIDIA support
log "Installing Docker with NVIDIA container toolkit..."
if ! command -v docker &> /dev/null; then
    apt-get install -y -qq ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    apt-get install -y -qq nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
fi

# Create directories with scratch disk optimization
log "Creating directories on fast NVMe storage..."
mkdir -p $DEEPSEEK_DIR/{models,logs,cache,config,embeddings}
mkdir -p $WEBTERM_DIR/{public,server,ssl,logs}
mkdir -p $VECTORDB_DIR/{data,logs,config,models,embeddings,indices}
mkdir -p $UPLOAD_DIR/{temp,processed,failed,documents,images,videos,audio,code,archives}
mkdir -p $TEMPLATES_DIR/{bash,ios,android,web,backend,frontend,database,devops,ai,ml}
mkdir -p $MODELS_DIR/{embeddings,rerankers,summarizers}
mkdir -p $SCRATCH_DIR/{milvus,cache,temp}

# Create optimized swap (use if needed, but with 240GB RAM, probably not)
if [ ! -f /swapfile ] && [ "$TOTAL_RAM_GB" -lt "128" ]; then
    log "Creating swap file (64GB)..."
    fallocate -l 64G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ===== PART 2: PYTHON ENVIRONMENT OPTIMIZED FOR H200 =====
log "Setting up Python environment optimized for H200..."
python3 -m venv /opt/venv
source /opt/venv/bin/activate

# Install Python packages with H200 optimizations
pip install --upgrade pip setuptools wheel

# Core ML packages with CUDA 12.1 support (optimized for H200)
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install transformers accelerate sentencepiece protobuf blobfile
pip install xformers --index-url https://download.pytorch.org/whl/cu121
pip install flash-attn --no-build-isolation

# Vector database packages
pip install pymilvus milvus pymilvus-orm
pip install chromadb
pip install qdrant-client
pip install pgvector psycopg2-binary

# Embedding models optimized for GPU
pip install sentence-transformers
pip install langchain langchain-community langchain-core
pip install llama-index

# Document processing
pip install pypdf pdfplumber pypdf2
pip install docx2txt python-docx
pip install openpyxl xlrd xlsxwriter
pip install markdown beautifulsoup4 lxml
pip install tiktoken
pip install pytesseract pillow
pip install python-magic
pip install ftfy regex tqdm

# File handling
pip install aiofiles aiohttp
pip install python-multipart
pip install watchfiles

# Web frameworks
pip install fastapi uvicorn[standard]
pip install pydantic pydantic-settings
pip install httpx requests websockets
pip install python-jose[cryptography] passlib[bcrypt]
pip install python-multipart email-validator

# Data processing optimized for GPU
pip install numpy pandas polars
pip install scipy scikit-learn
pip install nltk spacy textblob
pip install faiss-gpu
pip install cuml-cu12  # RAPIDS for single GPU

# Utilities
pip install redis celery
pip install sqlalchemy alembic
pip install loguru
pip install python-dotenv

# Download NLTK and spaCy models
python3 -c "import nltk; nltk.download('punkt'); nltk.download('averaged_perceptron_tagger'); nltk.download('stopwords')"
python3 -m spacy download en_core_web_sm

# ===== PART 3: MILVUS VECTOR DATABASE FOR H200 =====
vectordb "Setting up Milvus vector database optimized for single H200..."

# Create Milvus docker-compose for single GPU
cat > $VECTORDB_DIR/docker-compose.yml << 'EOF'
version: '3.5'

services:
  etcd:
    container_name: milvus-etcd
    image: quay.io/coreos/etcd:v3.5.5
    environment:
      - ETCD_AUTO_COMPACTION_MODE=revision
      - ETCD_AUTO_COMPACTION_RETENTION=1000
      - ETCD_QUOTA_BACKEND_BYTES=4294967296
      - ETCD_SNAPSHOT_COUNT=50000
    volumes:
      - ${DOCKER_VOLUME_DIRECTORY:-.}/volumes/etcd:/etcd
    command: etcd -advertise-client-urls=http://127.0.0.1:2379 -listen-client-urls http://0.0.0.0:2379 --data-dir /etcd
    restart: always

  minio:
    container_name: milvus-minio
    image: minio/minio:RELEASE.2023-03-20T20-16-18Z
    environment:
      MINIO_ACCESS_KEY: minioadmin
      MINIO_SECRET_KEY: minioadmin
    ports:
      - "9001:9001"
      - "9000:9000"
    volumes:
      - /mnt/scratch/milvus/minio:/minio_data
    command: minio server /minio_data --console-address ":9001"
    restart: always

  milvus:
    container_name: milvus-standalone
    image: milvusdb/milvus:v2.3.9-gpu
    command: ["milvus", "run", "standalone"]
    security_opt:
    - seccomp:unconfined
    environment:
      ETCD_ENDPOINTS: etcd:2379
      MINIO_ADDRESS: minio:9000
    volumes:
      - /mnt/scratch/milvus/data:/var/lib/milvus
      - ${DOCKER_VOLUME_DIRECTORY:-.}/milvus.yaml:/milvus/configs/milvus.yaml
    ports:
      - "19530:19530"
      - "9091:9091"
    depends_on:
      - "etcd"
      - "minio"
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=0
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
    restart: always

  attu:
    container_name: attu
    image: zilliz/attu:v2.3.4
    environment:
      MILVUS_URL: milvus:19530
    ports:
      - "3000:3000"
    depends_on:
      - milvus
    restart: always
EOF

# Create Milvus configuration optimized for single H200
cat > $VECTORDB_DIR/milvus.yaml << 'EOF'
# Milvus configuration optimized for 1× H200 (141GB VRAM)

etcd:
  endpoints:
    - etcd:2379

minio:
  address: minio
  port: 9000
  accessKeyID: minioadmin
  secretAccessKey: minioadmin
  useSSL: false
  bucketName: a-bucket

# GPU configuration for single H200
gpu:
  initMemSize: 0
  maxMemSize: 141000  # MB for H200
  enable: true
  cache_capacity: 120  # GB for cache
  search_resources:
    - gpu0
  build_index_resources:
    - gpu0

# Query configuration
queryNode:
  enableDisk: true
  maxDiskUsagePercentage: 95
  maxResultWindow: 10000
  maxGroupSize: 4096
  maxOutputSize: 4096
  maxCollectionNumPerLoader: 4

# Index configuration
indexNode:
  enableDisk: true
  maxDiskUsagePercentage: 95

# Data node configuration
dataNode:
  enableDisk: true
  memoryLimit: 32  # GB
  flowGraph:
    maxQueueLength: 512
    maxParallelism: 4

# Proxy configuration
proxy:
  http:
    enabled: true
    debug_mode: false
    port: 8080
  grpc:
    port: 19530
  maxFieldNum: 64
  maxShardNum: 16
  maxDimension: 16384

# Common configuration
common:
  security:
    authorizationEnabled: false
  retention:
    duration: 432000  # 5 days
    checkInterval: 300

# Query configuration
query:
  topK: 10000
  rangeSearch:
    defaultRadius: 1.0
    defaultRange: 1.0
  groupBy:
    enabled: true
    maxGroupSize: 256

# Auto index configuration
autoIndex:
  enable: true
  params:
    index_type: IVF_SQ8
    metric_type: IP
    nlist: 4096
    nprobe: 16

# GPU index parameters for H200
gpuIndex:
  ivf_flat:
    nlist: 4096
    nprobe: 16
  ivf_sq8:
    nlist: 4096
    nprobe: 16
  ivf_pq:
    nlist: 4096
    nprobe: 16
    m: 8
    nbits: 8
  hnsw:
    M: 32
    efConstruction: 200
    efSearch: 64
  annoy:
    n_trees: 64
    search_k: 2000

# Performance tuning for H200
performance:
  indexBuilding:
    maxThreads: 24
    maxGpuMemory: 141000  # MB
    batchSize: 500000
  search:
    maxThreads: 48
    beamWidth: 8
    gpuPoolSize: 1
  insert:
    maxThreads: 16
    batchSize: 25000

# Cache configuration for H200
cache:
  memoryLimit: 141000  # MB
  cacheSize: 120000  # MB
  insertBufferSize: 1048576
  deleteBufferSize: 1048576

# Log configuration
log:
  level: info
  file:
    rootPath: /var/lib/milvus/logs
    maxSize: 1024
    maxAge: 7
    maxBackups: 10
EOF

# Start Milvus with scratch disk for performance
cd $VECTORDB_DIR
docker-compose -f docker-compose.yml up -d

# ===== PART 4: FILE UPLOAD SERVICE OPTIMIZED FOR H200 =====
log "Creating optimized file upload service..."

cat > $UPLOAD_DIR/upload_service.py << 'EOF'
#!/usr/bin/env python3
"""
File Upload Service optimized for 1× H200
"""

import os
import sys
import json
import asyncio
import hashlib
import magic
from pathlib import Path
from datetime import datetime
from typing import List, Optional, Dict, Any
import uuid
import shutil

import aiofiles
from fastapi import FastAPI, File, UploadFile, Form, HTTPException, BackgroundTasks
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
from pydantic import BaseModel
import aiohttp
import torch
from PIL import Image

# Document processing
import pypdf
import docx2txt

app = FastAPI(title="H200 File Upload & Vectorization Service")

# Add CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
UPLOAD_DIR = "/opt/uploads"
TEMP_DIR = f"{UPLOAD_DIR}/temp"
PROCESSED_DIR = f"{UPLOAD_DIR}/processed"
FAILED_DIR = f"{UPLOAD_DIR}/failed"
SCRATCH_DIR = "/mnt/scratch/temp"
VECTORDB_URL = "http://localhost:3002"
MAX_FILE_SIZE = 10 * 1024 * 1024 * 1024  # 10GB
CHUNK_SIZE = 1024 * 1024  # 1MB

# Ensure directories exist
for dir_path in [UPLOAD_DIR, TEMP_DIR, PROCESSED_DIR, FAILED_DIR, SCRATCH_DIR]:
    os.makedirs(dir_path, exist_ok=True)

# GPU setup
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "CPU"
gpu_memory = torch.cuda.get_device_properties(0).total_memory / 1e9 if torch.cuda.is_available() else 0

print(f"🚀 Upload Service running on {gpu_name}")
print(f"💾 GPU Memory: {gpu_memory:.1f}GB")
print(f"📁 Upload directory: {UPLOAD_DIR}")

class FileInfo(BaseModel):
    id: str
    filename: str
    file_size: int
    file_type: str
    mime_type: str
    upload_time: str
    status: str
    hash: str
    metadata: Dict[str, Any] = {}
    vector_ids: List[str] = []
    collection: Optional[str] = None

# File type detection
def detect_file_type(content: bytes, filename: str) -> Dict[str, str]:
    mime = magic.from_buffer(content[:2048], mime=True)
    ext = os.path.splitext(filename)[1].lower().lstrip('.')
    
    categories = {
        'document': ['pdf', 'docx', 'doc', 'txt', 'rtf', 'md'],
        'image': ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'tiff', 'webp'],
        'code': ['py', 'js', 'html', 'css', 'java', 'cpp', 'sh', 'bash'],
        'data': ['csv', 'json', 'xml', 'yaml', 'yml'],
    }
    
    category = 'other'
    for cat, extensions in categories.items():
        if ext in extensions:
            category = cat
            break
    
    return {
        'mime_type': mime,
        'extension': ext,
        'category': category,
        'filename': filename
    }

# Text extraction functions
async def extract_text_from_pdf(file_path: str) -> str:
    async with aiofiles.open(file_path, 'rb') as f:
        pdf_content = await f.read()
    pdf = pypdf.PdfReader(io.BytesIO(pdf_content))
    return '\n'.join([page.extract_text() for page in pdf.pages if page.extract_text()])

async def extract_text_from_docx(file_path: str) -> str:
    return docx2txt.process(file_path)

async def extract_text(file_path: str, file_info: Dict[str, str]) -> str:
    category = file_info['category']
    try:
        if category == 'document':
            if file_info['extension'] == 'pdf':
                return await extract_text_from_pdf(file_path)
            elif file_info['extension'] in ['docx', 'doc']:
                return await extract_text_from_docx(file_path)
            else:
                async with aiofiles.open(file_path, 'r', errors='ignore') as f:
                    return await f.read()
        else:
            async with aiofiles.open(file_path, 'r', errors='ignore') as f:
                return await f.read()
    except Exception as e:
        print(f"Error extracting text: {e}")
        return ""

def chunk_text(text: str, chunk_size: int = 500, overlap: int = 100) -> List[str]:
    """Split text into overlapping chunks (optimized for H200)"""
    chunks = []
    start = 0
    text_len = len(text)
    
    while start < text_len:
        end = min(start + chunk_size, text_len)
        
        # Try to end at a sentence
        if end < text_len:
            for punct in ['. ', '! ', '? ', '\n']:
                last_punct = text.rfind(punct, start, end)
                if last_punct != -1:
                    end = last_punct + len(punct)
                    break
        
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        
        start = end - overlap
    
    return chunks

async def vectorize_chunks(chunks: List[str], file_info: FileInfo) -> List[str]:
    """Send chunks to vector database"""
    async with aiohttp.ClientSession() as session:
        vector_ids = []
        
        for i, chunk in enumerate(chunks):
            payload = {
                'text': chunk,
                'metadata': {
                    'file_id': file_info.id,
                    'filename': file_info.filename,
                    'file_type': file_info.file_type,
                    'chunk_index': i,
                    'total_chunks': len(chunks),
                },
                'collection': file_info.collection or 'default'
            }
            
            try:
                async with session.post('http://localhost:3002/v1/vectors', json=payload) as resp:
                    if resp.status == 200:
                        result = await resp.json()
                        vector_ids.append(result['vector_id'])
            except Exception as e:
                print(f"Error vectorizing chunk {i}: {e}")
        
        return vector_ids

@app.post("/upload")
async def upload_file(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    collection: str = Form("default"),
    chunk_size: int = Form(500)
):
    """Upload a single file"""
    import time
    start_time = time.time()
    
    file_id = str(uuid.uuid4())
    temp_path = f"{SCRATCH_DIR}/{file_id}_{file.filename}"
    
    try:
        # Read file in chunks
        file_size = 0
        async with aiofiles.open(temp_path, 'wb') as out_file:
            while chunk := await file.read(CHUNK_SIZE):
                await out_file.write(chunk)
                file_size += len(chunk)
                
                if file_size > MAX_FILE_SIZE:
                    raise HTTPException(413, "File too large")
        
        # Calculate hash
        sha256 = hashlib.sha256()
        async with aiofiles.open(temp_path, 'rb') as f:
            while chunk := await f.read(CHUNK_SIZE):
                sha256.update(chunk)
        file_hash = sha256.hexdigest()
        
        # Detect file type
        async with aiofiles.open(temp_path, 'rb') as f:
            content = await f.read(2048)
        file_info_dict = detect_file_type(content, file.filename)
        
        file_info = FileInfo(
            id=file_id,
            filename=file.filename,
            file_size=file_size,
            file_type=file_info_dict['category'],
            mime_type=file_info_dict['mime_type'],
            upload_time=datetime.now().isoformat(),
            status='processing',
            hash=file_hash,
            collection=collection
        )
        
        # Move to processing
        processed_path = f"{PROCESSED_DIR}/{file_id}_{file.filename}"
        shutil.move(temp_path, processed_path)
        
        # Extract text
        text = await extract_text(processed_path, file_info_dict)
        
        if text:
            # Chunk text (smaller chunks for better precision)
            text_chunks = chunk_text(text, chunk_size, 100)
            
            # Vectorize chunks
            vector_ids = await vectorize_chunks(text_chunks, file_info)
            file_info.vector_ids = vector_ids
            file_info.status = 'completed'
            file_info.metadata = {
                'text_length': len(text),
                'num_chunks': len(text_chunks),
                'chunk_size': chunk_size
            }
        else:
            file_info.status = 'no_text_extracted'
        
        processing_time = time.time() - start_time
        
        return {
            "success": True,
            "file_id": file_id,
            "message": f"File processed in {processing_time:.2f}s",
            "file_info": file_info.dict(),
            "processing_time": processing_time
        }
    
    except Exception as e:
        if os.path.exists(temp_path):
            failed_path = f"{FAILED_DIR}/{file_id}_{file.filename}"
            shutil.move(temp_path, failed_path)
        raise HTTPException(500, f"Upload failed: {str(e)}")

@app.get("/files")
async def list_files(limit: int = 100, offset: int = 0):
    """List uploaded files"""
    files = []
    for file_path in Path(PROCESSED_DIR).glob("*"):
        if file_path.is_file():
            stat = file_path.stat()
            name_parts = file_path.name.split('_', 1)
            
            if len(name_parts) == 2:
                file_id, filename = name_parts
                files.append({
                    "id": file_id,
                    "filename": filename,
                    "size": stat.st_size,
                    "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                    "status": "processed"
                })
    
    files = files[offset:offset+limit]
    return {"files": files}

@app.get("/stats")
async def get_stats():
    """Get upload service statistics"""
    processed = len(list(Path(PROCESSED_DIR).glob("*")))
    failed = len(list(Path(FAILED_DIR).glob("*")))
    
    total_size = sum(f.stat().st_size for f in Path(PROCESSED_DIR).glob("*") if f.is_file())
    
    return {
        "total_files": processed,
        "failed_files": failed,
        "total_size_gb": total_size / (1024**3),
        "gpu_name": gpu_name,
        "gpu_memory_gb": gpu_memory,
        "device": str(device)
    }

if __name__ == "__main__":
    uvicorn.run(
        "upload_service:app",
        host="0.0.0.0",
        port=int(os.environ.get("UPLOAD_PORT", 3003)),
        reload=False
    )
EOF

# ===== PART 5: VECTOR DATABASE API OPTIMIZED FOR H200 =====
vectordb "Creating Vector Database API optimized for H200..."

cat > $VECTORDB_DIR/vectordb_api.py << 'EOF'
#!/usr/bin/env python3
"""
Vector Database API optimized for single H200 GPU
"""

import os
import sys
import json
import time
import asyncio
import uuid
from typing import List, Dict, Any, Optional
from datetime import datetime

import torch
import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

# Milvus
from pymilvus import (
    connections,
    utility,
    Collection,
    CollectionSchema,
    FieldSchema,
    DataType
)

# Embedding models
from sentence_transformers import SentenceTransformer
import torch.nn.functional as F

app = FastAPI(title="H200 Vector Database API")

# Add CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ===== CONFIGURATION =====
MILVUS_HOST = os.environ.get("MILVUS_HOST", "localhost")
MILVUS_PORT = os.environ.get("MILVUS_PORT", "19530")
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "BAAI/bge-small-en-v1.5")  # Smaller model for single GPU
EMBEDDING_DIMENSION = int(os.environ.get("EMBEDDING_DIMENSION", "384"))  # bge-small dimension
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

# Connect to Milvus
connections.connect(host=MILVUS_HOST, port=MILVUS_PORT)

# Initialize embedding model
model = None

def load_model():
    """Lazy load embedding model onto GPU"""
    global model
    if model is None:
        print(f"📦 Loading embedding model: {EMBEDDING_MODEL}")
        model = SentenceTransformer(EMBEDDING_MODEL, device=DEVICE)
        print(f"✅ Model loaded on {DEVICE}")
        
        # Print GPU memory usage
        if torch.cuda.is_available():
            mem_allocated = torch.cuda.memory_allocated(0) / 1e9
            mem_total = torch.cuda.get_device_properties(0).total_memory / 1e9
            print(f"💾 GPU Memory: {mem_allocated:.1f}GB / {mem_total:.1f}GB")
    
    return model

# Models
class VectorCreate(BaseModel):
    text: str
    metadata: Dict[str, Any] = {}
    collection: str = "default"

class SearchRequest(BaseModel):
    text: str
    top_k: int = 10
    collection: Optional[str] = None
    min_score: float = 0.0

class SearchResponse(BaseModel):
    results: List[Dict[str, Any]]
    time_ms: float

# Helper functions
def compute_embedding(text: str) -> List[float]:
    """Compute embedding using GPU"""
    model = load_model()
    
    with torch.no_grad():
        embedding = model.encode(text, convert_to_tensor=True)
        return embedding.cpu().tolist()

def compute_embeddings_batch(texts: List[str]) -> List[List[float]]:
    """Compute embeddings in batch (optimized for H200)"""
    model = load_model()
    
    # Process in batches to maximize GPU utilization
    batch_size = 32
    all_embeddings = []
    
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i+batch_size]
        with torch.no_grad():
            embeddings = model.encode(batch, convert_to_tensor=True)
            all_embeddings.extend(embeddings.cpu().tolist())
    
    return all_embeddings

def ensure_collection(name: str, dimension: int = EMBEDDING_DIMENSION):
    """Ensure collection exists"""
    if not utility.has_collection(name):
        fields = [
            FieldSchema(name="id", dtype=DataType.VARCHAR, max_length=100, is_primary=True),
            FieldSchema(name="embedding", dtype=DataType.FLOAT_VECTOR, dim=dimension),
            FieldSchema(name="text", dtype=DataType.VARCHAR, max_length=65535),
            FieldSchema(name="metadata", dtype=DataType.JSON),
            FieldSchema(name="created_at", dtype=DataType.VARCHAR, max_length=50),
        ]
        
        schema = CollectionSchema(fields, description=f"{name} collection")
        collection = Collection(name=name, schema=schema)
        
        # Create index
        index_params = {
            "metric_type": "IP",
            "index_type": "IVF_SQ8",
            "params": {"nlist": 4096}
        }
        collection.create_index("embedding", index_params)
        collection.load()
        print(f"✅ Created collection: {name}")
        return collection
    
    collection = Collection(name=name)
    collection.load()
    return collection

# API Endpoints
@app.get("/health")
async def health():
    """Health check with GPU stats"""
    gpu_stats = {}
    if torch.cuda.is_available():
        gpu_stats = {
            "name": torch.cuda.get_device_name(0),
            "memory_allocated_gb": torch.cuda.memory_allocated(0) / 1e9,
            "memory_total_gb": torch.cuda.get_device_properties(0).total_memory / 1e9,
        }
    
    return {
        "status": "healthy",
        "device": DEVICE,
        "gpu": gpu_stats,
        "milvus_connected": connections.has_connection("default"),
        "embedding_model": EMBEDDING_MODEL,
        "timestamp": datetime.now().isoformat()
    }

@app.post("/v1/vectors")
async def create_vector(vector: VectorCreate):
    """Create a new vector embedding"""
    vector_id = str(uuid.uuid4())
    
    # Compute embedding on GPU
    embedding = compute_embedding(vector.text)
    
    # Ensure collection exists
    collection = ensure_collection(vector.collection)
    
    # Prepare data
    data = [
        [vector_id],
        [embedding],
        [vector.text],
        [vector.metadata],
        [datetime.now().isoformat()]
    ]
    
    # Insert into Milvus
    collection.insert(data)
    collection.flush()
    
    return {
        "vector_id": vector_id,
        "text": vector.text,
        "metadata": vector.metadata,
        "collection": vector.collection,
        "created_at": datetime.now().isoformat()
    }

@app.post("/v1/vectors/batch")
async def create_vectors_batch(vectors: List[VectorCreate]):
    """Create multiple vectors in batch"""
    texts = [v.text for v in vectors]
    embeddings = compute_embeddings_batch(texts)
    
    vector_ids = [str(uuid.uuid4()) for _ in vectors]
    
    # Group by collection
    collections = {}
    for i, vector in enumerate(vectors):
        if vector.collection not in collections:
            collections[vector.collection] = []
        collections[vector.collection].append(i)
    
    # Insert per collection
    for collection_name, indices in collections.items():
        collection = ensure_collection(collection_name)
        
        batch_data = [
            [vector_ids[i] for i in indices],
            [embeddings[i] for i in indices],
            [texts[i] for i in indices],
            [vectors[i].metadata for i in indices],
            [datetime.now().isoformat() for _ in indices]
        ]
        
        collection.insert(batch_data)
        collection.flush()
    
    return [{
        "vector_id": vector_ids[i],
        "text": vectors[i].text,
        "metadata": vectors[i].metadata,
        "collection": vectors[i].collection,
        "created_at": datetime.now().isoformat()
    } for i in range(len(vectors))]

@app.post("/v1/search", response_model=SearchResponse)
async def search_vectors(request: SearchRequest):
    """Search for similar vectors"""
    import time
    start = time.time()
    
    # Get query vector
    query_vector = compute_embedding(request.text)
    
    # Search parameters
    search_params = {
        "metric_type": "IP",
        "params": {"nprobe": 16}
    }
    
    # Determine collections to search
    if request.collection:
        collections = [request.collection] if utility.has_collection(request.collection) else []
    else:
        collections = utility.list_collections()
    
    all_results = []
    
    # Search each collection
    for collection_name in collections:
        collection = Collection(name=collection_name)
        collection.load()
        
        results = collection.search(
            data=[query_vector],
            anns_field="embedding",
            param=search_params,
            limit=request.top_k,
            output_fields=["id", "text", "metadata", "created_at"]
        )
        
        for hits in results:
            for hit in hits:
                if hit.score >= request.min_score:
                    all_results.append({
                        "id": hit.id,
                        "score": hit.score,
                        "text": hit.entity.get('text'),
                        "metadata": hit.entity.get('metadata'),
                        "created_at": hit.entity.get('created_at'),
                        "collection": collection_name
                    })
    
    # Sort and limit
    all_results.sort(key=lambda x: x['score'], reverse=True)
    all_results = all_results[:request.top_k]
    
    elapsed = (time.time() - start) * 1000
    
    return SearchResponse(
        results=all_results,
        time_ms=elapsed
    )

@app.get("/v1/stats")
async def get_stats():
    """Get vector database statistics"""
    collections = utility.list_collections()
    
    total_vectors = 0
    collection_stats = []
    
    for name in collections:
        collection = Collection(name=name)
        collection.flush()
        count = collection.num_entities
        
        total_vectors += count
        collection_stats.append({
            "name": name,
            "vector_count": count
        })
    
    gpu_stats = {}
    if torch.cuda.is_available():
        gpu_stats = {
            "name": torch.cuda.get_device_name(0),
            "memory_used_gb": torch.cuda.memory_allocated(0) / 1e9,
            "memory_total_gb": torch.cuda.get_device_properties(0).total_memory / 1e9,
        }
    
    return {
        "total_collections": len(collections),
        "total_vectors": total_vectors,
        "collections": collection_stats,
        "gpu": gpu_stats,
        "embedding_model": EMBEDDING_MODEL
    }

if __name__ == "__main__":
    port = int(os.environ.get("VECTORDB_PORT", 3002))
    uvicorn.run(
        "vectordb_api:app",
        host="0.0.0.0",
        port=port,
        reload=False
    )
EOF

# ===== PART 6: DEEPSEEK API WITH VECTORDB INTEGRATION =====
deepseek "Creating DeepSeek API with VectorDB integration..."

cat > $DEEPSEEK_DIR/api_server.py << 'EOF'
#!/usr/bin/env python3
"""
DeepSeek API Server optimized for single H200
With Vector Database integration for RAG
"""

import os
import sys
import json
import time
from typing import Optional, List, Dict, Any
from datetime import datetime

import torch
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import httpx
import asyncio

# Import transformers
from transformers import AutoModelForCausalLM, AutoTokenizer

app = FastAPI(title="DeepSeek H200 API with VectorDB")

# Add CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ===== H200 CONFIGURATION =====
MODEL_PATH = os.environ.get("DEEPSEEK_MODEL_PATH", "/opt/deepseek/models")
API_KEY = os.environ.get("DEEPSEEK_API_KEY", None)
VECTORDB_URL = os.environ.get("VECTORDB_URL", "http://localhost:3002")
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

# Global model variable
model = None
tokenizer = None

# Models
class CompletionRequest(BaseModel):
    prompt: str
    max_tokens: int = 512
    temperature: float = 0.7
    top_p: float = 0.95
    use_rag: bool = False
    rag_collection: Optional[str] = None
    rag_top_k: int = 5

class ChatMessage(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    messages: List[ChatMessage]
    max_tokens: int = 512
    temperature: float = 0.7
    top_p: float = 0.95
    use_rag: bool = False
    rag_collection: Optional[str] = None
    rag_top_k: int = 5

def load_model():
    """Lazy load the model onto H200"""
    global model, tokenizer
    if model is None:
        print(f"📦 Loading DeepSeek model on H200...")
        
        tokenizer = AutoTokenizer.from_pretrained(
            MODEL_PATH,
            trust_remote_code=True
        )
        
        model = AutoModelForCausalLM.from_pretrained(
            MODEL_PATH,
            torch_dtype=torch.float16,
            device_map="auto",
            max_memory={0: "141GB"},
            trust_remote_code=True
        )
        
        # Print GPU memory usage
        mem_allocated = torch.cuda.memory_allocated(0) / 1e9
        mem_total = torch.cuda.get_device_properties(0).total_memory / 1e9
        print(f"✅ Model loaded on H200")
        print(f"💾 GPU Memory: {mem_allocated:.1f}GB / {mem_total:.1f}GB")
    
    return model, tokenizer

async def retrieve_context(query: str, collection: Optional[str] = None, top_k: int = 5) -> str:
    """Retrieve relevant context from vector database"""
    async with httpx.AsyncClient() as client:
        try:
            response = await client.post(
                f"{VECTORDB_URL}/v1/search",
                json={
                    "text": query,
                    "top_k": top_k,
                    "collection": collection,
                    "min_score": 0.5
                },
                timeout=10.0
            )
            
            if response.status_code == 200:
                data = response.json()
                
                # Build context string
                context_parts = []
                for result in data['results']:
                    text = result.get('text', '')
                    score = result.get('score', 0)
                    metadata = result.get('metadata', {})
                    
                    source = metadata.get('filename', 'Unknown')
                    context_parts.append(f"[Source: {source} (relevance: {score:.2f})]\n{text}\n")
                
                return "\n---\n".join(context_parts)
        except Exception as e:
            print(f"Error retrieving from vector DB: {e}")
    
    return ""

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
    gpu_stats = {}
    if torch.cuda.is_available():
        gpu_stats = {
            "name": torch.cuda.get_device_name(0),
            "memory_allocated_gb": torch.cuda.memory_allocated(0) / 1e9,
            "memory_total_gb": torch.cuda.get_device_properties(0).total_memory / 1e9,
        }
    
    # Check vector DB health
    vectordb_healthy = False
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(f"{VECTORDB_URL}/health", timeout=5.0)
            vectordb_healthy = response.status_code == 200
    except:
        pass
    
    return {
        "status": "healthy",
        "device": DEVICE,
        "gpu": gpu_stats,
        "model_loaded": model is not None,
        "vectordb_connected": vectordb_healthy
    }

@app.post("/v1/completions")
async def create_completion(request: CompletionRequest, req: Request):
    """Create a completion with optional RAG"""
    verify_api_key(req)
    
    # Load model
    model, tokenizer = load_model()
    
    # Retrieve context if RAG enabled
    context = ""
    if request.use_rag:
        context = await retrieve_context(
            query=request.prompt,
            collection=request.rag_collection,
            top_k=request.rag_top_k
        )
    
    # Build prompt with context
    if context:
        full_prompt = f"Context:\n{context}\n\nBased on the context above, please answer: {request.prompt}\n\nAnswer:"
    else:
        full_prompt = request.prompt
    
    # Tokenize
    inputs = tokenizer(full_prompt, return_tensors="pt")
    inputs = {k: v.to(model.device) for k, v in inputs.items()}
    
    # Generate
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=request.max_tokens,
            temperature=request.temperature,
            top_p=request.top_p,
            do_sample=request.temperature > 0,
            pad_token_id=tokenizer.eos_token_id
        )
    
    # Decode
    generated_text = tokenizer.decode(outputs[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)
    
    return {
        "id": f"cmpl-{int(time.time())}",
        "object": "text_completion",
        "created": int(time.time()),
        "choices": [{
            "text": generated_text,
            "index": 0,
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": len(inputs["input_ids"][0]),
            "completion_tokens": len(outputs[0]) - len(inputs["input_ids"][0]),
            "total_tokens": len(outputs[0])
        },
        "rag_used": request.use_rag,
        "rag_results": len(context.split('---')) if context else 0
    }

@app.post("/v1/chat/completions")
async def create_chat_completion(request: ChatRequest, req: Request):
    """Create a chat completion with optional RAG"""
    verify_api_key(req)
    
    model, tokenizer = load_model()
    
    # Get last user message for RAG
    last_user_message = ""
    for msg in reversed(request.messages):
        if msg.role == "user":
            last_user_message = msg.content
            break
    
    # Retrieve context if RAG enabled
    context = ""
    if request.use_rag and last_user_message:
        context = await retrieve_context(
            query=last_user_message,
            collection=request.rag_collection,
            top_k=request.rag_top_k
        )
    
    # Format messages
    formatted_messages = []
    if context:
        formatted_messages.append({
            "role": "system",
            "content": f"Use the following context to answer the user's question:\n\n{context}"
        })
    
    for msg in request.messages:
        formatted_messages.append({"role": msg.role, "content": msg.content})
    
    # Convert to prompt
    prompt = ""
    for msg in formatted_messages:
        prompt += f"{msg['role'].capitalize()}: {msg['content']}\n"
    prompt += "Assistant: "
    
    inputs = tokenizer(prompt, return_tensors="pt")
    inputs = {k: v.to(model.device) for k, v in inputs.items()}
    
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=request.max_tokens,
            temperature=request.temperature,
            top_p=request.top_p,
            do_sample=request.temperature > 0,
            pad_token_id=tokenizer.eos_token_id
        )
    
    generated_text = tokenizer.decode(outputs[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)
    
    return {
        "id": f"chatcmpl-{int(time.time())}",
        "object": "chat.completion",
        "created": int(time.time()),
        "choices": [{
            "message": {
                "role": "assistant",
                "content": generated_text
            },
            "index": 0,
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": len(inputs["input_ids"][0]),
            "completion_tokens": len(outputs[0]) - len(inputs["input_ids"][0]),
            "total_tokens": len(outputs[0])
        },
        "rag_used": request.use_rag,
        "rag_results": len(context.split('---')) if context else 0
    }

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=3000)
    parser.add_argument("--host", type=str, default="0.0.0.0")
    args = parser.parse_args()
    
    uvicorn.run(app, host=args.host, port=args.port)
EOF

# ===== PART 7: WEB TERMINAL WITH VECTORDB UI =====
terminal "Creating web terminal with VectorDB UI..."

cat > $WEBTERM_DIR/server/index.js << 'EOF'
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const { Client } = require('ssh2');
const path = require('path');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
    cors: {
        origin: "*",
        methods: ["GET", "POST"]
    }
});

// Proxy to VectorDB API
app.use('/api/vectordb', createProxyMiddleware({
    target: 'http://localhost:3002',
    changeOrigin: true,
    pathRewrite: {
        '^/api/vectordb': '/'
    }
}));

// Proxy to Upload service
app.use('/upload', createProxyMiddleware({
    target: 'http://localhost:3003',
    changeOrigin: true
}));

app.use('/files', createProxyMiddleware({
    target: 'http://localhost:3003',
    changeOrigin: true
}));

// Serve static files
app.use(express.static(path.join(__dirname, '../public')));

// SSH Connection handling
io.on('connection', (socket) => {
    console.log(`Client connected: ${socket.id}`);
    
    let sshClient = new Client();
    let stream;

    socket.on('connect-ssh', (config) => {
        sshClient.on('ready', () => {
            sshClient.shell({ term: 'xterm-256color' }, (err, sshStream) => {
                if (err) {
                    socket.emit('data', `\r\n*** SSH shell error: ${err.message}\r\n`);
                    return;
                }
                
                stream = sshStream;
                
                stream.on('data', (data) => {
                    socket.emit('data', data.toString('utf-8'));
                });
                
                stream.on('close', () => {
                    sshClient.end();
                });
                
                // Welcome message
                socket.emit('data', '\r\n*** Connected to H200 Instance ***\r\n');
                socket.emit('data', 'Welcome to DeepSeek H200 + VectorDB\r\n');
                socket.emit('data', 'GPU: 1× H200 (141GB VRAM)\r\n');
                socket.emit('data', 'DeepSeek API: http://localhost:3000\r\n');
                socket.emit('data', 'VectorDB API: http://localhost:3002\r\n');
                socket.emit('data', '\r\n$ ');
            });
        });
        
        sshClient.on('error', (err) => {
            socket.emit('data', `\r\n*** SSH connection error: ${err.message}\r\n`);
        });
        
        sshClient.connect({
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password,
            readyTimeout: 20000
        });
    });
    
    socket.on('input', (data) => {
        if (stream && stream.writable) {
            stream.write(data);
        }
    });
    
    socket.on('disconnect', () => {
        if (stream) stream.end();
        sshClient.end();
    });
});

// API endpoint for status
app.get('/api/status', (req, res) => {
    res.json({ 
        status: 'running', 
        timestamp: new Date().toISOString(),
        services: {
            deepseek: 3000,
            vectordb: 3002,
            upload: 3003
        }
    });
});

const PORT = process.env.PORT || 3001;
server.listen(PORT, '0.0.0.0', () => {
    console.log(`Web Terminal running on http://0.0.0.0:${PORT}`);
});
EOF

# Create web terminal package.json
cat > $WEBTERM_DIR/package.json << 'EOF'
{
  "name": "web-terminal-h200",
  "version": "1.0.0",
  "description": "Web SSH terminal for H200",
  "main": "server/index.js",
  "scripts": {
    "start": "node server/index.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "socket.io": "^4.6.1",
    "ssh2": "^1.15.0",
    "http-proxy-middleware": "^2.0.6"
  }
}
EOF

# Install web terminal dependencies
cd $WEBTERM_DIR
npm install

# Copy HTML file (from previous version, shortened for brevity)
cp /path/to/index.html $WEBTERM_DIR/public/index.html

# ===== PART 8: PM2 ECOSYSTEM FOR H200 =====
log "Creating PM2 ecosystem file..."

cat > /opt/ecosystem.config.js << EOF
module.exports = {
    apps: [
        {
            name: 'deepseek-api-h200',
            cwd: '$DEEPSEEK_DIR',
            script: 'api_server.py',
            interpreter: '/opt/venv/bin/python3',
            instances: 1,
            exec_mode: 'fork',
            max_memory_restart: '200G',
            env: {
                DEEPSEEK_API_KEY: '$DEEPSEEK_API_KEY',
                DEEPSEEK_PORT: $DEEPSEEK_PORT,
                CUDA_VISIBLE_DEVICES: '0',
                VECTORDB_URL: 'http://localhost:3002'
            },
            error_file: '$DEEPSEEK_DIR/logs/api-error.log',
            out_file: '$DEEPSEEK_DIR/logs/api-out.log'
        },
        {
            name: 'vectordb-api-h200',
            cwd: '$VECTORDB_DIR',
            script: 'vectordb_api.py',
            interpreter: '/opt/venv/bin/python3',
            instances: 1,
            exec_mode: 'fork',
            max_memory_restart: '150G',
            env: {
                VECTORDB_PORT: $VECTORDB_PORT,
                MILVUS_HOST: 'localhost',
                MILVUS_PORT: '19530',
                EMBEDDING_MODEL: 'BAAI/bge-small-en-v1.5',
                CUDA_VISIBLE_DEVICES: '0'
            },
            error_file: '$VECTORDB_DIR/logs/vectordb-error.log',
            out_file: '$VECTORDB_DIR/logs/vectordb-out.log'
        },
        {
            name: 'upload-service-h200',
            cwd: '$UPLOAD_DIR',
            script: 'upload_service.py',
            interpreter: '/opt/venv/bin/python3',
            instances: 1,
            exec_mode: 'fork',
            max_memory_restart: '50G',
            env: {
                UPLOAD_PORT: $UPLOAD_PORT,
                CUDA_VISIBLE_DEVICES: '0'
            },
            error_file: '$UPLOAD_DIR/logs/upload-error.log',
            out_file: '$UPLOAD_DIR/logs/upload-out.log'
        },
        {
            name: 'web-terminal-h200',
            cwd: '$WEBTERM_DIR',
            script: 'server/index.js',
            interpreter: 'node',
            instances: 1,
            exec_mode: 'fork',
            max_memory_restart: '1G',
            env: {
                PORT: $WEBTERM_PORT
            },
            error_file: '$WEBTERM_DIR/logs/terminal-error.log',
            out_file: '$WEBTERM_DIR/logs/terminal-out.log'
        }
    ]
};
EOF

# ===== PART 9: CREATE HELPER SCRIPTS =====
log "Creating helper scripts..."

# Test script
cat > /opt/test-h200.sh << 'EOF'
#!/bin/bash

echo "🔍 Testing H200 Setup"
echo "======================"

# Check GPU
echo -n "1. GPU: "
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

# Check services
echo "2. Services:"
for port in 3000 3001 3002 3003; do
    if curl -s http://localhost:$port/health > /dev/null 2>&1; then
        echo "   ✅ Port $port is running"
    else
        echo "   ❌ Port $port is not responding"
    fi
done

# Check Docker
echo "3. Docker:"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep milvus

# Test vector DB
echo "4. Vector DB Test:"
curl -s http://localhost:3002/v1/stats | python3 -m json.tool

echo ""
echo "🌐 Access URLs:"
echo "   Web Terminal: http://$INSTANCE_IP:$WEBTERM_PORT"
echo "   DeepSeek API: http://$INSTANCE_IP:$DEEPSEEK_PORT"
echo "   VectorDB API: http://$INSTANCE_IP:$VECTORDB_PORT"
echo "   Milvus Dashboard: http://$INSTANCE_IP:3000"
EOF

chmod +x /opt/test-h200.sh

# ===== PART 10: START SERVICES =====
log "Starting all services..."

# Start Milvus
cd $VECTORDB_DIR
docker-compose up -d

# Start PM2 services
pm2 start /opt/ecosystem.config.js
pm2 save
pm2 startup

# Wait for services
sleep 10

# ===== FINAL OUTPUT =====
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         DEEPSEEK H200 + VECTORDB SETUP COMPLETE!              ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

info "Your DigitalOcean H200 is now ready!"
echo ""
info "📡 SERVICES RUNNING:"
echo "   • DeepSeek API:   http://$INSTANCE_IP:$DEEPSEEK_PORT"
echo "   • VectorDB API:   http://$INSTANCE_IP:$VECTORDB_PORT"
echo "   • Web Terminal:   http://$INSTANCE_IP:$WEBTERM_PORT"
echo "   • Upload Service: http://$INSTANCE_IP:$UPLOAD_PORT"
echo "   • Milvus UI:      http://$INSTANCE_IP:3000"
echo ""
info "🔧 H200 CONFIGURATION:"
echo "   • GPU: 1× H200 (141GB VRAM)"
echo "   • Embedding Model: BAAI/bge-small-en-v1.5 (384 dim)"
echo "   • Cache Size: 100GB"
echo "   • Batch Size: 32"
echo ""
info "📊 MANAGEMENT:"
echo "   • Test everything:    /opt/test-h200.sh"
echo "   • View logs:          pm2 logs"
echo "   • Monitor GPU:        watch -n 1 nvidia-smi"
echo "   • Monitor NVMe:       iostat -x 1"
echo ""
info "🔑 API Key: ${DEEPSEEK_API_KEY:-"Not Set (open access)"}"
echo ""
info "📤 UPLOAD FILES:"
echo "   curl -X POST http://$INSTANCE_IP:$UPLOAD_PORT/upload \\"
echo "     -F \"file=@document.pdf\" -F \"collection=docs\""
echo ""
info "🔍 SEARCH:"
echo "   curl -X POST http://$INSTANCE_IP:$VECTORDB_PORT/v1/search \\"
echo "     -H \"Content-Type: application/json\" \\"
echo "     -d '{\"text\": \"your query\", \"top_k\": 10}'"
echo ""
info "🤖 DEEPSEEK RAG:"
echo "   curl -X POST http://$INSTANCE_IP:$DEEPSEEK_PORT/v1/completions \\"
echo "     -H \"Content-Type: application/json\" \\"
if [ -n "$DEEPSEEK_API_KEY" ]; then
    echo "     -H \"Authorization: Bearer $DEEPSEEK_API_KEY\" \\"
fi
echo "     -d '{\"prompt\": \"Your question\", \"use_rag\": true}'"
echo ""
log "✅ Setup complete! Access the web UI at: http://$INSTANCE_IP:$WEBTERM_PORT"