# PiggyChat Installer 🐷

PiggyChat is a fully automated Bash script designed to simplify the deployment of a complete Matrix communication stack on Ubuntu/Debian servers. It installs and configures Matrix Synapse, Element Web, and Coturn (TURN server) with minimal user intervention.

## Features

🚀 **Automated Installation**  
Installs Synapse, Element, Nginx, Certbot, and Coturn.

🔒 **SSL/TLS**  
Automatically obtains Let's Encrypt SSL certificates for all subdomains.

🔄 **Auto-Update**  
Fetches and installs the latest stable version of Element Web directly from GitHub.

📞 **VoIP Ready**  
Configures a TURN server (Coturn) for reliable voice and video calls.

⚙️ **Interactive Setup**  
Prompts for domains and IP addresses, handling all configuration files automatically.

## Prerequisites

- A fresh Ubuntu or Debian VPS  
- Root access (or sudo privileges)

### Required DNS Records (pointing to your server IP)

- `example.com` (Root domain)
- `chat.example.com` (Matrix Synapse)
- `app.example.com` (Element Web)

### Required Open Ports

- 80
- 443
- 3478
- 5349
- UDP range: 49160–49200

## Quick Start

Run the following command on your server to start the installation:

```bash
sudo bash <(curl -s https://raw.githubusercontent.com/piggyteam99/piggychat/main/piggy.sh)
