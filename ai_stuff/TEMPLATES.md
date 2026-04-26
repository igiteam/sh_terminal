🎯 Vast.ai Template for DeepSeek H100 + Web Terminal

Here's how to configure each section:

1. Identification Section
   text

Template Name: DeepSeek H100 + Web Terminal
Template Description: DeepSeek AI with browser-based SSH terminal. Includes web terminal on port 3001, DeepSeek API on port 3000, and full monitoring.

2. Docker Repository And Environment
   text

Image Path:Tag: vastai/base-image:@vastai-automatic-tag

Docker Options (add these):
text

-p 3000:3000 -p 3001:3001 -p 8080:8080 -e OPEN_BUTTON_PORT=8080 -e OPEN_BUTTON_TOKEN=1 -e JUPYTER_DIR=/ -e DATA_DIRECTORY=/workspace/ -e PORTAL_CONFIG="localhost:3000:3000:/:DeepSeek API|localhost:3001:3001:/:Web Terminal|localhost:8080:18080:/:Jupyter"

3. Ports Section

Add these ports (internal/external will be auto-assigned):
Port Protocol Purpose
3000 TCP DeepSeek API
3001 TCP Web Terminal
8080 TCP Jupyter (optional)
22 TCP SSH (already there) 4. Environment Variables

Add these:
Key Value
DEEPSEEK_PORT 3000
WEBTERM_PORT 3001
DEEPSEEK_API_KEY (your-key-here)
DEBIAN_FRONTEND noninteractive
NVIDIA_VISIBLE_DEVICES all
NVIDIA_DRIVER_CAPABILITIES compute,utility 5. Launch Mode

Select Jupyter-python notebook + SSH - this gives you both options.
Check ✅ Use Jupyter Lab interface (better UI)
Check ✅ Jupyter direct HTTPS (faster)

6. On-start Script

Create an entrypoint.sh with:
bash

#!/bin/bash

# DeepSeek H100 Auto-Setup Script

set -e

echo "🚀 Starting DeepSeek H100 setup..."

# Update system

apt-get update -qq
apt-get install -y -qq curl wget git build-essential python3-pip python3-venv htop screen tmux nginx

# Install Python ML deps

pip3 install --upgrade pip
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
pip3 install transformers accelerate sentencepiece protobuf blobfile
pip3 install fastapi uvicorn pydantic python-multipart httpx huggingface-hub

# Install Node.js for web terminal

curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y -qq nodejs
npm install -g pm2

# Create directories

mkdir -p /opt/deepseek/{models,logs,api}
mkdir -p /opt/web-terminal/{public,server,logs}
cd /opt

# Download setup script

curl -o setup.sh https://gist.githubusercontent.com/your-username/deepseek-setup/raw/setup.sh
chmod +x setup.sh
./setup.sh

# Start services

pm2 start /opt/ecosystem.config.js
pm2 save
pm2 startup

echo "✅ DeepSeek H100 setup complete!"
echo "📍 Web Terminal: http://$(curl -s ifconfig.me):3001"
echo "📍 DeepSeek API: http://$(curl -s ifconfig.me):3000"

7. Extra Filters (Optional)

cuda_vers >= 12.0 gpu_ram >= 40 verified=true

8. Disk Space

Set Container disk size to at least 100 GB (models are ~80GB, plus room for OS and tools). 9. Visibility

Choose:
Public - Share with community (recommended to help others)
Private - Only visible to you

10. Final CLI Command

The template will generate something like:
bash

vastai create instance <OFFER_ID> --image vastai/base-image:@vastai-automatic-tag --env '-p 3000:3000 -p 3001:3001 -e DEEPSEEK_PORT=3000 -e WEBTERM_PORT=3001 -e DEBIAN_FRONTEND=noninteractive -e NVIDIA_VISIBLE_DEVICES=all' --onstart-cmd 'entrypoint.sh' --disk 100 --jupyter --ssh --direct

🚀 Quick Start for Users

Once saved, users can:
Go to Offers page
Filter for H100/H200 GPUs
Click "Rent" on your template
Instance auto-configures in ~10 minutes

    Access:
        Web Terminal: http://[IP]:3001
        DeepSeek API: http://[IP]:3000/v1/completions
        Jupyter: http://[IP]:8080

💡 Pro Tips
Save as Public - Help the community preserve AI models too!
Add to README - Include setup instructions in template description
Version tags - Use :latest for auto-updates or pin to specific version
API Key - Set DEEPSEEK_API_KEY env var for security
