#!/bin/bash

# DeepSeek AI H200 + Vector Database Setup
# Optimized for DigitalOcean 1× H200 (141GB VRAM) Droplet
# Usage: curl -sL https://your-domain.com/setup-deepseek-h200-do.sh | sudo bash

# curl -o h200_digitalocean.sh https://cdn.sdappnet.cloud/rtx/sh/h200_digitalocean.sh && chmod +x h200_digitalocean.sh && sudo ./h200_digitalocean.sh


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
VECTORDB_DIR="/opt/vectordb"
UPLOAD_DIR="/opt/uploads"
TEMPLATES_DIR="/opt/templates"
MODELS_DIR="/opt/models"
SCRATCH_DIR="/mnt/scratch"

DEEPSEEK_PORT=3000
VECTORDB_PORT=3002
UPLOAD_PORT=3003

# DigitalOcean H200 Specs
NUM_GPUS=1
GPU_MEM_GB=141
TOTAL_RAM_GB=240
CPU_CORES=24

# Performance tuning for single H200
BATCH_SIZE=32
EMBEDDING_DIM=384  # Using bge-small for better performance
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

read -p "Enter VectorDB API port [3002]: " input
VECTORDB_PORT=${input:-3002}

read -p "Enter Upload Service port [3003]: " input
UPLOAD_PORT=${input:-3003}

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
    tmux htop iotop iftop nvtop jq  # Monitoring tools

# Install Node.js 18 (for PM2)
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
mkdir -p $DEEPSEEK_DIR/{models,logs,cache,config}
mkdir -p $VECTORDB_DIR/{data,logs,config,indices}
mkdir -p $UPLOAD_DIR/{temp,processed,failed}
mkdir -p $TEMPLATES_DIR
mkdir -p $MODELS_DIR
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
pip install transformers accelerate sentencepiece protobuf
pip install xformers --index-url https://download.pytorch.org/whl/cu121

# Vector database packages
pip install pymilvus==2.3.9
pip install chromadb
pip install pgvector psycopg2-binary

# Embedding models optimized for GPU
pip install sentence-transformers
pip install langchain langchain-community

# Document processing
pip install pypdf pdfplumber pypdf2
pip install docx2txt python-docx
pip install openpyxl
pip install markdown beautifulsoup4 lxml
pip install tiktoken
pip install pytesseract pillow
pip install python-magic

# File handling
pip install aiofiles aiohttp
pip install python-multipart
pip install watchfiles

# Web frameworks
pip install fastapi uvicorn[standard]
pip install pydantic pydantic-settings
pip install httpx requests

# Data processing optimized for GPU
pip install numpy pandas
pip install scipy scikit-learn
pip install nltk spacy
pip install faiss-gpu

# Utilities
pip install redis celery
pip install sqlalchemy
pip install loguru
pip install python-dotenv

# Download NLTK and spaCy models
python3 -c "import nltk; nltk.download('punkt'); nltk.download('averaged_perceptron_tagger'); nltk.download('stopwords')"
python3 -m spacy download en_core_web_sm

# ===== PART 3: MILVUS VECTOR DATABASE FOR H200 =====
log "Setting up Milvus vector database optimized for single H200..."

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
      - /mnt/scratch/milvus/etcd:/etcd
    command: etcd -advertise-client-urls=http://127.0.0.1:2379 -listen-client-urls http://0.0.0.0:2379 --data-dir /etcd
    restart: always
    networks:
      - milvus

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
    networks:
      - milvus

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
      - ${VECTORDB_DIR}/milvus.yaml:/milvus/configs/milvus.yaml
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
    networks:
      - milvus

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
    networks:
      - milvus

networks:
  milvus:
    driver: bridge
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
  hnsw:
    M: 32
    efConstruction: 200
    efSearch: 64

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

# Wait for Milvus to start
log "Waiting for Milvus to start..."
sleep 20

# ===== PART 4: VECTOR DATABASE API OPTIMIZED FOR H200 =====
log "Creating Vector Database API optimized for H200..."

cat > $VECTORDB_DIR/vectordb_api.py << 'EOF'
#!/usr/bin/env python3
"""
Vector Database API optimized for single H200 GPU
"""

import os
import sys
import json
import time
import uuid
from typing import List, Dict, Any, Optional
from datetime import datetime

import torch
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
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "BAAI/bge-small-en-v1.5")
EMBEDDING_DIMENSION = 384
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

def ensure_collection(name: str):
    """Ensure collection exists"""
    if not utility.has_collection(name):
        fields = [
            FieldSchema(name="id", dtype=DataType.VARCHAR, max_length=100, is_primary=True),
            FieldSchema(name="embedding", dtype=DataType.FLOAT_VECTOR, dim=EMBEDDING_DIMENSION),
            FieldSchema(name="text", dtype=DataType.VARCHAR, max_length=65535),
            FieldSchema(name="metadata", dtype=DataType.JSON),
            FieldSchema(name="created_at", dtype=DataType.VARCHAR, max_length=50),
        ]
        
        schema = CollectionSchema(fields, description=f"{name} collection")
        collection = Collection(name=name, schema=schema)
        
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

# ===== PART 5: UPLOAD SERVICE OPTIMIZED FOR H200 =====
log "Creating file upload service..."

cat > $UPLOAD_DIR/upload_service.py << 'EOF'
#!/usr/bin/env python3
"""
File Upload Service for H200
"""

import os
import asyncio
import hashlib
import uuid
import shutil
from pathlib import Path
from datetime import datetime
from typing import List, Optional, Dict, Any
import magic

import aiofiles
from fastapi import FastAPI, File, UploadFile, Form, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
from pydantic import BaseModel
import aiohttp
import torch

app = FastAPI(title="H200 File Upload Service")

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
PROCESSED_DIR = f"{UPLOAD_DIR}/processed"
SCRATCH_DIR = "/mnt/scratch/temp"
VECTORDB_URL = "http://localhost:3002"
MAX_FILE_SIZE = 10 * 1024 * 1024 * 1024  # 10GB
CHUNK_SIZE = 1024 * 1024  # 1MB

# Ensure directories exist
for dir_path in [UPLOAD_DIR, PROCESSED_DIR, SCRATCH_DIR]:
    os.makedirs(dir_path, exist_ok=True)

# GPU info
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "CPU"

print(f"🚀 Upload Service running on {gpu_name}")

class FileInfo(BaseModel):
    id: str
    filename: str
    size: int
    type: str
    upload_time: str
    vector_ids: List[str] = []

def chunk_text(text: str, chunk_size: int = 512, overlap: int = 50) -> List[str]:
    """Split text into chunks"""
    chunks = []
    start = 0
    text_len = len(text)
    
    while start < text_len:
        end = min(start + chunk_size, text_len)
        
        # Try to end at sentence
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

async def vectorize_chunks(chunks: List[str], file_id: str, filename: str) -> List[str]:
    """Send chunks to vector database"""
    async with aiohttp.ClientSession() as session:
        vector_ids = []
        
        for i, chunk in enumerate(chunks):
            payload = {
                'text': chunk,
                'metadata': {
                    'file_id': file_id,
                    'filename': filename,
                    'chunk_index': i,
                    'total_chunks': len(chunks),
                },
                'collection': 'documents'
            }
            
            try:
                async with session.post(f"{VECTORDB_URL}/v1/vectors", json=payload) as resp:
                    if resp.status == 200:
                        result = await resp.json()
                        vector_ids.append(result['vector_id'])
            except Exception as e:
                print(f"Error vectorizing chunk {i}: {e}")
        
        return vector_ids

@app.post("/upload")
async def upload_file(
    file: UploadFile = File(...),
    collection: str = Form("default")
):
    """Upload a file"""
    file_id = str(uuid.uuid4())
    temp_path = f"{SCRATCH_DIR}/{file_id}_{file.filename}"
    
    try:
        # Save file
        file_size = 0
        async with aiofiles.open(temp_path, 'wb') as out_file:
            while chunk := await file.read(CHUNK_SIZE):
                await out_file.write(chunk)
                file_size += len(chunk)
                
                if file_size > MAX_FILE_SIZE:
                    raise HTTPException(413, "File too large")
        
        # For now, just extract text from text files
        text = ""
        if file.filename.endswith(('.txt', '.md', '.py', '.sh', '.js', '.html', '.css')):
            async with aiofiles.open(temp_path, 'r', errors='ignore') as f:
                text = await f.read()
        
        vector_ids = []
        if text:
            chunks = chunk_text(text)
            vector_ids = await vectorize_chunks(chunks, file_id, file.filename)
        
        # Move to processed
        processed_path = f"{PROCESSED_DIR}/{file_id}_{file.filename}"
        shutil.move(temp_path, processed_path)
        
        return {
            "success": True,
            "file_id": file_id,
            "filename": file.filename,
            "size": file_size,
            "vectors_created": len(vector_ids),
            "vector_ids": vector_ids
        }
        
    except Exception as e:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        raise HTTPException(500, f"Upload failed: {str(e)}")

@app.get("/files")
async def list_files():
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
                    "modified": datetime.fromtimestamp(stat.st_mtime).isoformat()
                })
    
    return {"files": files}

if __name__ == "__main__":
    port = int(os.environ.get("UPLOAD_PORT", 3003))
    uvicorn.run(
        "upload_service:app",
        host="0.0.0.0",
        port=port,
        reload=False
    )
EOF

# ===== PART 6: DEEPSEEK API WITH VECTORDB INTEGRATION =====
log "Creating DeepSeek API with VectorDB integration..."

cat > $DEEPSEEK_DIR/api_server.py << 'EOF'
#!/usr/bin/env python3
"""
DeepSeek API Server optimized for single H200
With Vector Database integration for RAG
"""

import os
import time
from typing import Optional, List, Dict, Any

import torch
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import httpx

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
            trust_remote_code=True
        )
        
        print(f"✅ Model loaded on H200")
    
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

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=3000)
    parser.add_argument("--host", type=str, default="0.0.0.0")
    args = parser.parse_args()
    
    uvicorn.run(app, host=args.host, port=args.port)
EOF

# ===== PART 7: PM2 ECOSYSTEM FOR H200 =====
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
                VECTORDB_URL: 'http://localhost:$VECTORDB_PORT'
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
        }
    ]
};
EOF

# ===== PART 8: CREATE HELPER SCRIPTS =====
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
for port in 3000 3002 3003; do
    if curl -s http://localhost:$port/health > /dev/null 2>&1; then
        echo "   ✅ Port $port is running"
    else
        echo "   ❌ Port $port is not responding"
    fi
done

# Check Docker
echo "3. Milvus:"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep milvus

# Test vector DB
echo "4. Vector DB Stats:"
curl -s http://localhost:3002/v1/stats | python3 -m json.tool

echo ""
echo "🌐 API Endpoints:"
echo "   DeepSeek API: http://$INSTANCE_IP:$DEEPSEEK_PORT"
echo "   VectorDB API: http://$INSTANCE_IP:$VECTORDB_PORT"
echo "   Upload Service: http://$INSTANCE_IP:$UPLOAD_PORT"
echo "   Milvus Dashboard: http://$INSTANCE_IP:3000"
EOF

chmod +x /opt/test-h200.sh

# Upload test script
cat > /opt/test-upload.sh << 'EOF'
#!/bin/bash

echo "📤 Testing file upload..."
echo "======================"

# Create test file
echo "This is a test document for vector database. DeepSeek AI is awesome!" > /tmp/test.txt

# Upload file
curl -X POST http://localhost:3003/upload \
  -F "file=@/tmp/test.txt" \
  -F "collection=test"

echo ""
echo "✅ Test complete. Check vector DB with:"
echo "curl -X POST http://localhost:3002/v1/search -H 'Content-Type: application/json' -d '{\"text\": \"test\"}'"
EOF

chmod +x /opt/test-upload.sh

# ===== PART 9: START SERVICES =====
log "Starting all services..."

# Start Milvus
cd $VECTORDB_DIR
docker-compose -f docker-compose.yml up -d

# Wait for Milvus
log "Waiting for Milvus to initialize..."
sleep 30

# Start PM2 services
pm2 start /opt/ecosystem.config.js
pm2 save
pm2 startup

# Wait for services
sleep 10

# ===== PART 10: NGINX CONFIGURATION =====
log "Configuring nginx..."

cat > /etc/nginx/sites-available/deepseek << EOF
server {
    listen 80;
    server_name _;
    
    location /api/deepseek/ {
        proxy_pass http://localhost:$DEEPSEEK_PORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    location /api/vectordb/ {
        proxy_pass http://localhost:$VECTORDB_PORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    location /upload {
        client_max_body_size 10G;
        proxy_pass http://localhost:$UPLOAD_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    location /milvus/ {
        proxy_pass http://localhost:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/deepseek /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

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
echo "   • Test upload:        /opt/test-upload.sh"
echo "   • View logs:          pm2 logs"
echo "   • Monitor GPU:        watch -n 1 nvidia-smi"
echo "   • Monitor NVMe:       iostat -x 1"
echo ""
info "🔑 API Key: ${DEEPSEEK_API_KEY:-"Not Set (open access)"}"
echo ""
info "📤 UPLOAD FILES:"
echo "   curl -X POST http://$INSTANCE_IP:$UPLOAD_PORT/upload \\"
echo "     -F \"file=@document.txt\" -F \"collection=docs\""
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
info "📁 TEMPLATE LOADING:"
echo "   To load your templates, run:"
echo "   for file in /opt/templates/*; do"
echo "     curl -X POST http://$INSTANCE_IP:$UPLOAD_PORT/upload -F \"file=@\$file\" -F \"collection=templates\""
echo "   done"
echo ""
log "✅ Setup complete! Access the services at the URLs above."