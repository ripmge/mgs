# /ansible/Dockerfile
FROM python:3.11-slim-bookworm

# Environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    sshpass \
    netcat-openbsd \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Install Ansible (Latest stable) and WinRM libraries
# 'ansible' includes ansible-core and standard collections
RUN pip install --no-cache-dir \
    ansible-core==2.15.9 \
    pywinrm \
    requests \
    requests-credssp

# Install required Ansible Collections for GOAD
# We PIN ansible.windows to 2.8.0 because v3.0.0 removed 'win_domain'
RUN ansible-galaxy collection install --force \
    ansible.windows:==2.8.0 \
    community.windows:==2.0.0 \
    microsoft.ad:==1.0.0 \
    community.general:==8.1.0

WORKDIR /barb/ansible

COPY entrypoint_barb.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]