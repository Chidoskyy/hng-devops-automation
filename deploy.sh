#!/bin/bash

# HNG Stage 1 DevOps Deployment Script
# Author: Chidiebere Uduh

# Optional Cleanup Section
if [[ "$1" == "--cleanup" ]]; then
  echo "Running cleanup on remote server..."
  read -p "Are you sure you want to remove all deployed resources? (y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    echo "Cleanup aborted."
    exit 0
  fi

  read -p "Enter remote server username: " SSH_USER
  read -p "Enter remote server IP address: " SERVER_IP
  read -p "Enter SSH key path: " SSH_KEY_PATH

  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << EOF
  echo "Removing Docker containers and Nginx configuration..."
  sudo docker stop flask_app || true
  sudo docker rm flask_app || true
  sudo docker rmi flask_app || true
  sudo rm -rf ~/app
  sudo rm -f /etc/nginx/sites-enabled/flask_app /etc/nginx/sites-available/flask_app
  sudo systemctl reload nginx
  echo "Cleanup complete."
EOF
  exit 0
fi

# Exit immediately on error
set -e

LOG_FILE="deploy_$(date +%Y%m%d).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "Deployment failed. Check log file: $LOG_FILE" >&2' ERR

echo "====================================="
echo "Starting HNG Stage 1 Deployment Script"
echo "====================================="

# Collect user inputs
read -p "Enter Git repository URL: " REPO_URL
read -s -p "Enter Git PAT (Personal Access Token): " GIT_PAT
echo
read -p "Enter branch to deploy (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter remote server username: " SSH_USER
read -p "Enter remote server IP address: " SERVER_IP
read -p "Enter SSH key path: " SSH_KEY_PATH
read -p "Enter application internal port (e.g., 8080): " APP_INTERNAL_PORT

# Validate inputs
if [[ -z "$REPO_URL" || -z "$GIT_PAT" || -z "$SSH_USER" || -z "$SERVER_IP" || -z "$SSH_KEY_PATH" || -z "$APP_INTERNAL_PORT" ]]; then
  echo "Error: All inputs are required."
  exit 1
fi

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "Error: SSH key file not found at $SSH_KEY_PATH"
  exit 1
fi

# Clone or update repository
REPO_NAME=$(basename "$REPO_URL" .git)

if [[ -d "$REPO_NAME" ]]; then
  echo "Repository already exists. Pulling latest changes."
  cd "$REPO_NAME"
  git pull origin "$BRANCH"
else
  git clone -b "$BRANCH" "https://$GIT_PAT@${REPO_URL#https://}" "$REPO_NAME"
  cd "$REPO_NAME"
fi

echo "Repository $REPO_NAME is ready on branch $BRANCH."

# SSH connection check
echo "Checking SSH connection to $SSH_USER@$SERVER_IP..."
if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo SSH connection successful"; then
  echo "SSH connection established."
else
  echo "Error: Unable to establish SSH connection to $SSH_USER@$SERVER_IP"
  exit 1
fi

# Prepare remote environment
echo "Preparing remote environment on $SERVER_IP..."

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << 'EOF'
set -e
sudo apt-get update -y

if ! command -v docker &> /dev/null; then
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable docker
  sudo systemctl start docker
else
  echo "Docker already installed."
fi

docker --version

if ! command -v nginx &> /dev/null; then
  sudo apt-get install -y nginx
  sudo systemctl enable nginx
  sudo systemctl start nginx
else
  echo "Nginx already installed."
fi

echo "Remote environment ready."
EOF

# Transfer and deploy the application
echo "Transferring application files to remote server..."
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "rm -rf ~/app && mkdir -p ~/app"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -r ./* "$SSH_USER@$SERVER_IP:~/app/"

echo "Deploying application on remote server..."
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << EOF
set -e
cd ~/app

sudo docker build -t flask_app .
sudo docker ps -q --filter "name=flask_app" | grep -q . && sudo docker stop flask_app && sudo docker rm flask_app || true
sudo docker run -d --name flask_app -p ${APP_INTERNAL_PORT}:${APP_INTERNAL_PORT} flask_app

echo "Deployment completed successfully."
EOF

# Configure Nginx as reverse proxy
echo "Configuring Nginx as a reverse proxy..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" << EOF
set -e
NGINX_CONF="/etc/nginx/sites-available/flask_app"
sudo bash -c "cat > \$NGINX_CONF" << 'CONFIG'
server {
    listen 80;
    server_name $SERVER_IP;

    location / {
        proxy_pass http://localhost:$APP_INTERNAL_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
CONFIG

sudo ln -sf /etc/nginx/sites-available/flask_app /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
EOF

# Validate deployment
echo "Validating deployment..."
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << EOF
set -e
sudo docker ps --filter "name=flask_app"
if curl -s --head http://localhost | grep "200 OK" > /dev/null; then
  echo "Application is running and reachable through Nginx."
else
  echo "Error: Application not responding on port 80."
  exit 1
fi
EOF

echo "Deployment completed successfully."
exit 0
