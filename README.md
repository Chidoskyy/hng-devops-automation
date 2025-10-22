# HNGi13 DevOps Stage 1 — Automated Deployment Script

##  Author
**Chidiebere Uduh**

## Project Overview
This project automates the deployment of a Dockerized Flask web application 
to a remote EC2 server using a single Bash script (`deploy.sh`).

The script:
- Collects deployment parameters from the user
- Clones a GitHub repository using a Personal Access Token (PAT)
- Connects securely to a remote EC2 server via SSH
- Installs Docker, Docker Compose, and Nginx
- Builds and runs the Flask app inside a Docker container
- Configures Nginx as a reverse proxy to serve the app on port 80
- Validates deployment and logs all activities

##  How to Use

1. Make the script executable:
   ```bash
   chmod +x deploy.sh
