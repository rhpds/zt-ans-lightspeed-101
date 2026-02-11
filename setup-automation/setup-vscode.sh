#!/bin/bash

# Configure secondary network interface for PostgreSQL communication
nmcli connection add type ethernet con-name eth1 ifname eth1 ipv4.addresses 192.168.1.12/24 ipv4.method manual connection.autoconnect yes
nmcli connection up eth1
echo "192.168.1.10 control.lab control" >> /etc/hosts
echo "192.168.1.11 netbox.lab netbox" >> /etc/hosts
echo "192.168.1.12 devtools.lab devtools" >> /etc/hosts

# COMMON_PASSWORD is provided by the Ansible deployment (main.yml) via extra vars
# VM password is changed by main.yml before this script runs

# Set katello facts before satellite registration
mkdir -p /etc/rhsm/facts
INVENTORY_HOSTNAME=$(hostname -s)
DATETIME=$(date -u +%Y%m%dT%H%M%SZ | tr '[:upper:]' '[:lower:]')
if echo "${INVENTORY_HOSTNAME}" | grep -q "${GUID}"; then
    SUBSCRIPTION_HOSTNAME="${INVENTORY_HOSTNAME}-${DATETIME}"
else
    SUBSCRIPTION_HOSTNAME="${INVENTORY_HOSTNAME}.${GUID}.internal-${DATETIME}"
fi
printf '{"network.fqdn": "%s"}\n' "${SUBSCRIPTION_HOSTNAME}" > /etc/rhsm/facts/katello.facts

# Register with content source (Satellite or custom script)
if [ -n "${SATELLITE_SCRIPT}" ]; then
    echo "Executing custom satellite registration script..."
    eval "${SATELLITE_SCRIPT}"
elif [ -n "${SATELLITE_URL}" ]; then
    curl -k -L https://${SATELLITE_URL}/pub/katello-server-ca.crt -o /etc/pki/ca-trust/source/anchors/${SATELLITE_URL}.ca.crt
    update-ca-trust
    rpm -Uhv https://${SATELLITE_URL}/pub/katello-ca-consumer-latest.noarch.rpm
    subscription-manager register --org=${SATELLITE_ORG} --activationkey=${SATELLITE_ACTIVATIONKEY}
else
    echo "WARNING: No SATELLITE_SCRIPT or SATELLITE_URL defined, skipping registration"
fi
setenforce 0

echo "%rhel ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/rhel_sudoers
# chmod 440 /etc/sudoers.d/rhel_sudoers
# sudo -u rhel mkdir -p /home/rhel/.ssh
# sudo -u rhel chmod 700 /home/rhel/.ssh
# sudo -u rhel ssh-keygen -t rsa -b 4096 -C "rhel@$(hostname)" -f /home/rhel/.ssh/id_rsa -N ""
# sudo -u rhel chmod 600 /home/rhel/.ssh/id_rsa*

systemctl stop firewalld
systemctl stop code-server
mv /home/rhel/.config/code-server/config.yaml /home/rhel/.config/code-server/config.bk.yaml

tee /home/rhel/.config/code-server/config.yaml << EOF
bind-addr: 0.0.0.0:8080
auth: none
cert: false
EOF

systemctl start code-server
#Enable linger for the user `rhel`
loginctl enable-linger rhel
dnf install ansible-core nano git python3-firewall -y

# Set Python 3.11 as the default python3 using alternatives
echo "Setting Python 3.11 as default python3..."
alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 1
alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 2
alternatives --set python3 /usr/bin/python3.11

# Remove conflicting ansible-core RPM package (uses Python 3.9)
# We use the pip-installed ansible-core 2.18.6 with Python 3.11 instead
echo "Removing RPM ansible-core package to avoid version conflicts..."
dnf remove -y ansible-core

# Install required VSCode extensions
echo "Installing Red Hat Authentication extension..."
sudo -u rhel code-server --install-extension redhat.vscode-redhat-account

echo "Installing Ansible extension..."
sudo -u rhel code-server --install-extension redhat.ansible

# Clone demo repository from Gitea
echo "Cloning demo repository from Gitea..."
GITEA_URL="http://gitea:3000"
REPO_NAME="acme_corp"
GITEA_ORG="student"

# Wait for Gitea to be available
echo "Waiting for Gitea to be ready..."
until curl -s "${GITEA_URL}" > /dev/null; do
    sleep 5
done

# Configure git for rhel user
sudo -u rhel git config --global http.sslVerify false
sudo -u rhel git config --global user.name "Lab User"
sudo -u rhel git config --global user.email "rhel@lab.local"

# Configure git credential storage for Gitea
echo "Configuring Git credentials for Gitea..."
sudo -u rhel git config --global credential.helper store
echo "http://gitea:gitea@gitea:3000" | sudo -u rhel tee /home/rhel/.git-credentials > /dev/null
sudo -u rhel chmod 600 /home/rhel/.git-credentials

# Clone the repository as rhel user
echo "Cloning ${GITEA_ORG}/${REPO_NAME} to /home/rhel/${REPO_NAME}..."
sudo -u rhel rm -rf /home/rhel/${REPO_NAME}
sudo -u rhel git clone ${GITEA_URL}/${GITEA_ORG}/${REPO_NAME} /home/rhel/${REPO_NAME}

# Checkout devel branch (matches original playbook behavior)
cd /home/rhel/${REPO_NAME}
sudo -u rhel git checkout devel

# Create workspace settings for the repository
echo "Creating workspace settings for ${REPO_NAME}..."
sudo -u rhel mkdir -p /home/rhel/${REPO_NAME}/.vscode
sudo -u rhel tee /home/rhel/${REPO_NAME}/.vscode/settings.json > /dev/null << 'VSCODE_EOF'
{
  "ansible.python.interpreterPath": "/usr/bin/python3.11",
  "ansible.ansible.path": "/usr/local/bin/ansible",
  "ansible.validation.enabled": true,
  "ansible.validation.lint.enabled": true,
  "ansible.validation.lint.path": "/usr/local/bin/ansible-lint",
  "ansible.lightspeed.enabled": false,
  "ansible.lightspeed.suggestions.enabled": false
}
VSCODE_EOF

# Create/update .gitignore to avoid lock files showing in git status
echo "Configuring .gitignore for lock files..."
sudo -u rhel tee -a /home/rhel/${REPO_NAME}/.gitignore > /dev/null << 'GITIGNORE_EOF'

# Ansible and Podman lock files
*.lock
.ansible/
collections/ansible_collections/
*.retry

# Python cache
__pycache__/
*.py[cod]
*$py.class

# Ansible Navigator artifacts
/tmp/playbook-artifacts/
*-artifact-*.json

# Editor files
.vscode/.ropeproject
GITIGNORE_EOF

# Create inventory file for the new lab platform (targeting localhost/vscode VM)
echo "Creating inventory file for lab platform..."
sudo -u rhel tee /home/rhel/${REPO_NAME}/inventory.yml > /dev/null << INVENTORY_EOF
---
all:
  children:
    rhel:
      hosts:
        localhost:
          ansible_connection: local
  vars:
    ansible_user: rhel
    ansible_become_password: ${COMMON_PASSWORD}
    ansible_host_key_checking: false
INVENTORY_EOF

# Update cockpit inventory file for the new lab platform (target control VM)
echo "Updating cockpit playbook inventory..."
COCKPIT_INVENTORY="/home/rhel/${REPO_NAME}/playbooks/infra/install_cockpit/inventory/inventory.yml"
if [ -f "${COCKPIT_INVENTORY}" ]; then
    sudo -u rhel tee "${COCKPIT_INVENTORY}" > /dev/null << COCKPIT_INVENTORY_EOF
---
all:
  children:
    rhel:
      hosts:
        control:
          ansible_host: control.lab
  vars:
    ansible_user: rhel
    ansible_password: ${COMMON_PASSWORD}
    ansible_become_password: ${COMMON_PASSWORD}
    ansible_host_key_checking: false
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
COCKPIT_INVENTORY_EOF
    echo "  Updated ${COCKPIT_INVENTORY}"
else
    echo "  Warning: ${COCKPIT_INVENTORY} not found"
fi

# Update apache inventory file for the new lab platform (target control VM)
echo "Updating apache playbook inventory..."
APACHE_INVENTORY="/home/rhel/${REPO_NAME}/playbooks/infra/install_apache/inventory/inventory.yml"
if [ -f "${APACHE_INVENTORY}" ]; then
    sudo -u rhel tee "${APACHE_INVENTORY}" > /dev/null << APACHE_INVENTORY_EOF
---
all:
  children:
    rhel:
      hosts:
        control:
          ansible_host: control.lab
  vars:
    ansible_user: rhel
    ansible_password: ${COMMON_PASSWORD}
    ansible_become_password: ${COMMON_PASSWORD}
    ansible_host_key_checking: false
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
APACHE_INVENTORY_EOF
    echo "  Updated ${APACHE_INVENTORY}"
else
    echo "  Warning: ${APACHE_INVENTORY} not found"
fi

# Update postgresql/pgadmin inventory file for the new lab platform (target vscode VM via secondary network)
echo "Updating postgresql/pgadmin playbook inventory..."
PGSQL_INVENTORY="/home/rhel/${REPO_NAME}/playbooks/infra/install_pgsql_and_pgadmin/inventory/inventory.yml"
if [ -f "${PGSQL_INVENTORY}" ]; then
    sudo -u rhel tee "${PGSQL_INVENTORY}" > /dev/null << PGSQL_INVENTORY_EOF
---
all:
  children:
    rhel:
      hosts:
        devtools:
          ansible_host: devtools.lab
  vars:
    ansible_user: rhel
    ansible_password: ${COMMON_PASSWORD}
    ansible_become_password: ${COMMON_PASSWORD}
    ansible_host_key_checking: false
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
PGSQL_INVENTORY_EOF
    echo "  Updated ${PGSQL_INVENTORY}"
else
    echo "  Warning: ${PGSQL_INVENTORY} not found"
fi

# Remove firewall task from PostgreSQL playbooks (firewalld is disabled on vscode VM)
echo "Removing firewall tasks from PostgreSQL playbooks..."
PGSQL_DEMO="/home/rhel/${REPO_NAME}/playbooks/infra/install_pgsql_and_pgadmin/demo_install_pgsql_pgadmin.yml"
PGSQL_SOLUTION="/home/rhel/${REPO_NAME}/playbooks/infra/install_pgsql_and_pgadmin/solution_install_pgsql_pgadmin.yml"

if [ -f "${PGSQL_DEMO}" ]; then
    sudo -u rhel sed -i '/Allow the traffic through the firewall/,/immediate: true/d' "${PGSQL_DEMO}"
    echo "  Removed firewall task from ${PGSQL_DEMO}"
fi

if [ -f "${PGSQL_SOLUTION}" ]; then
    sudo -u rhel sed -i '/Allow the traffic through the firewall/,/immediate: true/d' "${PGSQL_SOLUTION}"
    echo "  Removed firewall task from ${PGSQL_SOLUTION}"
fi

# Update cockpit task name to include "directory" at the end for better Lightspeed suggestions
echo "Updating cockpit playbook task names..."
COCKPIT_DEMO="/home/rhel/${REPO_NAME}/playbooks/infra/install_cockpit/demo_install_cockpit.yml"
COCKPIT_SOLUTION="/home/rhel/${REPO_NAME}/playbooks/infra/install_cockpit/solution_install_cockpit.yml"

if [ -f "${COCKPIT_DEMO}" ]; then
    sudo -u rhel sed -i 's/Copy cockpit\.conf\.j2 to \/etc\/cockpit$/Copy cockpit.conf.j2 to \/etc\/cockpit directory/g' "${COCKPIT_DEMO}"
    echo "  Updated task name in ${COCKPIT_DEMO}"
fi

if [ -f "${COCKPIT_SOLUTION}" ]; then
    sudo -u rhel sed -i 's/Copy cockpit\.conf\.j2 to \/etc\/cockpit$/Copy cockpit.conf.j2 to \/etc\/cockpit directory/g' "${COCKPIT_SOLUTION}"
    echo "  Updated task name in ${COCKPIT_SOLUTION}"
fi

# Update ansible-navigator.yml files to add mode: stdout
echo "Updating ansible-navigator.yml files to use stdout mode..."
for navigator_file in \
    "/home/rhel/${REPO_NAME}/playbooks/infra/install_cockpit/ansible-navigator.yml" \
    "/home/rhel/${REPO_NAME}/playbooks/infra/install_pgsql_and_pgadmin/ansible-navigator.yml" \
    "/home/rhel/${REPO_NAME}/playbooks/cloud/aws/ansible-navigator.yml" \
    "/home/rhel/${REPO_NAME}/playbooks/cloud/azure/ansible-navigator.yml"
do
    if [ -f "${navigator_file}" ]; then
        sudo -u rhel bash -c "echo '  mode: stdout' >> ${navigator_file}"
        echo "  Added mode: stdout to ${navigator_file}"
    fi
done

# Commit and push .gitignore and updated inventory files to remote
echo "Committing and pushing configuration updates..."
cd /home/rhel/${REPO_NAME}
sudo -u rhel git add .gitignore inventory.yml \
    playbooks/infra/install_cockpit/inventory/inventory.yml \
    playbooks/infra/install_apache/inventory/inventory.yml \
    playbooks/infra/install_pgsql_and_pgadmin/inventory/inventory.yml \
    playbooks/infra/install_cockpit/demo_install_cockpit.yml \
    playbooks/infra/install_cockpit/solution_install_cockpit.yml \
    playbooks/infra/install_pgsql_and_pgadmin/demo_install_pgsql_pgadmin.yml \
    playbooks/infra/install_pgsql_and_pgadmin/solution_install_pgsql_pgadmin.yml \
    playbooks/infra/install_cockpit/ansible-navigator.yml \
    playbooks/infra/install_pgsql_and_pgadmin/ansible-navigator.yml \
    playbooks/cloud/aws/ansible-navigator.yml \
    playbooks/cloud/azure/ansible-navigator.yml
sudo -u rhel git commit -m "Update inventory, playbooks, and ansible-navigator config for new lab platform" || true
sudo -u rhel git push origin devel || true

# Set password in Antora attributes for showroom build
echo "Setting lab password in documentation..."
sed -i "s/%common_password%/${COMMON_PASSWORD}/g" /home/rhel/${REPO_NAME}/content/antora.yml

# Also replace directly in pre-built HTML and adoc as fallback
find /home/rhel/${REPO_NAME}/www/modules/ /home/rhel/${REPO_NAME}/content/modules/ROOT/pages/ \
    -type f \( -name "*.html" -o -name "*.adoc" \) \
    -exec sed -i "s/%common_password%/${COMMON_PASSWORD}/g" {} +

# Pull execution environment image from Quay
echo "Pulling execution environment image from Quay..."
EE_IMAGE="quay.io/acme_corp/lightspeed-101_ee:latest"
sudo -u rhel podman pull ${EE_IMAGE}

# Configure cloud provider environment variables for rhel user
echo "Configuring cloud provider environment variables for rhel user..."
sudo -u rhel tee /home/rhel/.cloud_env > /dev/null << CLOUD_ENV_EOF
# AWS credentials for cloud playbooks
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Azure credentials for cloud playbooks
# Map from platform variable names to Azure module expected names
export AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION}"
export AZURE_TENANT="${AZURE_TENANT}"
export AZURE_CLIENT_ID="${AZURE_CLIENT_ID}"
export AZURE_SECRET="${AZURE_PASSWORD}"
export AZURE_RESOURCE_GROUP="${AZURE_RESOURCEGROUP}"
CLOUD_ENV_EOF

# Add sourcing of cloud env to .bashrc if not already present
if ! grep -q ".cloud_env" /home/rhel/.bashrc; then
    echo "" | sudo -u rhel tee -a /home/rhel/.bashrc > /dev/null
    echo "# Source cloud provider credentials" | sudo -u rhel tee -a /home/rhel/.bashrc > /dev/null
    echo "[ -f ~/.cloud_env ] && source ~/.cloud_env" | sudo -u rhel tee -a /home/rhel/.bashrc > /dev/null
fi

# Note: Cloud environment variables are fetched by setup-control.sh via reverse SSH
# No need to push them here - control node will pull them when needed

echo "Dev machine setup complete!"
echo "Repository cloned to: /home/rhel/${REPO_NAME}"
echo "Execution environment ready: ${EE_IMAGE}"


# Create playbook and track_vars.yml for challenge setup/solve automation
# This playbook handles dev machine setup and (commented out) AAP Controller tasks

tee /tmp/setup.yml << 'PLAYBOOK_EOF'
### Dev Machine and Automation Controller setup
###
---
- name: Setup Dev Machine and Controller
  hosts: localhost
  connection: local
  collections:
    - ansible.controller

  vars:
    aws_access_key: "{{ lookup('env', 'AWS_ACCESS_KEY_ID') | default('AWS_ACCESS_KEY_ID_NOT_FOUND', true) }}"
    aws_secret_key: "{{ lookup('env', 'AWS_SECRET_ACCESS_KEY') | default('AWS_SECRET_ACCESS_KEY_NOT_FOUND', true) }}"
    aws_default_region: "{{ lookup('env', 'AWS_DEFAULT_REGION') | default('AWS_DEFAULT_REGION_NOT_FOUND', true) }}"
    quay_username: "{{ lookup('env', 'QUAY_USERNAME') | default('QUAY_USERNAME_NOT_FOUND', true) }}"
    quay_password: "{{ lookup('env', 'QUAY_PASSWORD') | default('QUAY_PASSWORD_NOT_FOUND', true) }}"
    azure_subscription: "{{ lookup('env', 'AZURE_SUBSCRIPTION') | default('AZURE_SUBSCRIPTION_NOT_FOUND', true) }}"
    azure_tenant: "{{ lookup('env', 'AZURE_TENANT') | default('AZURE_TENANT_NOT_FOUND', true) }}"
    azure_client_id: "{{ lookup('env', 'AZURE_CLIENT_ID') | default('AZURE_CLIENT_ID_NOT_FOUND', true) }}"
    azure_password: "{{ lookup('env', 'AZURE_PASSWORD') | default('AZURE_PASSWORD_NOT_FOUND', true) }}"
    azure_resourcegroup: "{{ lookup('env', 'AZURE_RESOURCEGROUP') | default('AZURE_RESOURCEGROUP_NOT_FOUND', true) }}"

  vars_files:
    - /tmp/track_vars.yml
    # - vault_track_vars.yml  # Vault not needed for now

  vars:
      controller_login: &controller_login
        controller_username: "{{ controller_username }}"
        controller_password: "{{ controller_password }}"
        controller_host: "{{ controller_hostname }}"
        validate_certs: "{{ controller_validate_certs }}"

  tasks:

  # Have to update objects with $_SANDBOX_ID in FQDN.
    - name: Setup initial environment
      tags:
        - setup-env
      block:
    #  Needs Instruqt Azure account name to be "azureadmin"
    #   - name: Setup Azure environment vars
    #     ansible.builtin.blockinfile:
    #       path: /etc/profile
    #       mode: "0644"
    #       owner: root
    #       group: root
    #       block: |
    #         export AZURE_CLIENT_ID="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SPN_ID}"
    #         export AZURE_TENANT="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_TENANT_ID}"
    #         export AZURE_SUBSCRIPTION_ID="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SUBSCRIPTION_ID}"
    #         export AZURE_SECRET="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SPN_PASSWORD}"
    #         export AZURE_PASSWORD="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_PASSWORD}"
    #         export AZURE_AD_USER="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_USERNAME}"

    # AAP Controller tasks - commented out for dev machine setup
    #   - name: Wait for controller availability
    #     ansible.builtin.uri:
    #       url: https://localhost/api/v2/ping/
    #       method: GET
    #       user: "{{ controller_login.controller_username }}"
    #       password: "{{ controller_login.controller_password }}"
    #       validate_certs: "{{ controller_login.validate_certs }}"
    #     register: __controller_check
    #     until:
    #       - __controller_check.json is defined
    #       - __controller_check.json.instances[0].capacity > 0
    #       - __controller_check.json.instance_groups[0].capacity > 0
    #     retries: 20
    #     delay: 1

    # NOTE: Git clone, branch checkout, and .vscode setup are handled by bash script above
    # The following tasks are for runtime challenge setup/solve operations only

    - name: Solve Overwrite demo Playbooks with solution playbooks - {{ gitea_repo_name }}
      ansible.builtin.copy:
        src: "{{ item.source_playbook }}"
        dest: "{{ item.dest_playbook }}"
        owner: rhel
        group: rhel
        remote_src: "{{ item.remote_src | default(omit) }}"
        mode: "644"
      loop: "{{ lookup('ansible.builtin.vars', content_list)['playbooks'] }}"
      tags:
        - setup-workflow-playbooks
        - solve-workflow-playbooks
        - solve-database-playbooks
        - solve-monitoring-playbooks
        - solve-aws-playbooks
        - solve-azure-playbooks
        - setup-playground-playbooks

    - name: Setup and Solve - Git add Playbooks to repo
      ansible.builtin.command:
        cmd: "git add {{ item.dest_playbook }}"
        chdir: "~rhel/{{ gitea_repo_name }}"
      become_user: rhel
      register: __add_output
      changed_when: __add_output.rc == 0
      loop: "{{ lookup('ansible.builtin.vars', content_list)['playbooks']  }}"
      tags:
        - setup-playground-playbooks
        - setup-workflow-playbooks
        - solve-monitoring-playbooks
        - solve-database-playbooks
        - solve-aws-playbooks
        - solve-azure-playbooks
        - solve-workflow-playbooks

    - name: Setup - Push challenge setup commit to repo
      ansible.builtin.command:
        cmd: "{{ item }}"
        chdir: "~rhel/{{ gitea_repo_name }}"
      become_user: rhel
      register: __output
      failed_when: false # TODO loop with matching changed_when and failed_when text.
      loop:
        - "git commit -m'Challenge setup commit.'"
        - "git push -u origin devel --force" # Temp
        # - "git push -u origin main --force"
      tags:
        - setup-playground-playbooks
        - setup-workflow-playbooks
        - solve-workflow-playbooks
        - solve-database-playbooks
        - solve-monitoring-playbooks
        - solve-aws-playbooks
        - solve-azure-playbooks

  # AAP Controller tasks - commented out for dev machine setup
  #   - name: Update controller credentials - {{ content_list }}
  #     awx.awx.credential:
  #       name: "{{ item.name }}"
  #       description: "{{ item.description }}"
  #       organization: "{{ item.organization }}"
  #       state: "{{ item.state }}"
  #       inputs: "{{ item.inputs }}"
  #       credential_type: "{{ item.credential_type }}"
  #       <<: *controller_login
  #     # no_log: true
  #     delegate_to: localhost
  #     loop: "{{ controller_credentials[content_list] }}"
  #     when:
  #       - controller_credentials is defined
  #       - content_list is defined
  #     retries: 10
  #     delay: 1
  #     tags:
  #       # Have to add playground-credentials because of content_list var
  #       - setup-playground-credentials
  #       - setup-aws-credentials
  #       - setup-azure-credentials

  #   - name: Setup - create job templates - {{ content_list }}
  #     awx.awx.job_template:
  #       name: "{{ item.name }}"
  #       state: "{{ item.state }}"
  #       become_enabled: "{{ item.become_enabled | default(omit)}}"
  #       project: "{{ item.project }}"
  #       credentials: "{{ item.credentials }}"
  #       organization: "{{ item.organization }}"
  #       inventory: "{{ item.inventory }}"
  #       playbook: "{{ item.playbook }}"
  #       survey_spec: "{{ item.survey_spec | default(omit) }}"
  #       ask_inventory_on_launch: "{{ item.ask_inventory_on_launch | default(false) }}"
  #       ask_limit_on_launch: "{{ item.ask_limit_on_launch | default(omit) }}"
  #       extra_vars: "{{ item.extra_vars | default(omit) }}"
  #       limit: "{{ item.limit | default(omit) }}"
  #       execution_environment: "{{ item.execution_environment }}"
  #       job_tags: "{{ item.job_tags | default(omit) }}"
  #       <<: *controller_login
  #     delegate_to: localhost
  #     register: __create_job_templates
  #     until: not __create_job_templates.failed
  #     retries: 20
  #     delay: 1
  #     loop: "{{ controller_templates[content_list] }}"
  #     when:
  #       - controller_templates[content_list] is defined
  #     tags:
  #       - setup-monitoring-jt
  #       - setup-database-jt
  #       - setup-workflow-jt
  #       - setup-aws-jt
  #       - setup-azure-jt
  #       - setup-playground-jt

  # NOTE: AWS and Azure resource setup tasks commented out - these would run on AAP Controller
  # NOTE: Additional controller/check/solve tasks commented out
  # These include: solve run job templates, check EC2/Azure/database/monitoring, cleanup tasks
  # Uncomment when setting up controller-specific tasks

    - name: Solve configure-tools VS Code settings
      ansible.builtin.copy:
        src: "{{ playbook_dir }}/files/settings_workspace_solve.json"
        dest: "~rhel/{{ gitea_repo_name }}/.vscode/settings.json"
        owner: rhel
        group: rhel
        remote_src: true
        mode: "0644"
      register: __settings_file
      tags:
        - solve-configure-tools

    - name: Check configure-tools present VS Code settings
      tags:
        - check-configure-tools
      block:
        - name: Check Lightspeed config present
          ansible.builtin.lineinfile:
            path: "~rhel/{{ gitea_repo_name }}/.vscode/settings.json"
            # path: "~rhel/.config/Code/User/settings.json"
            state: absent
            backrefs: true
            regex: "{{ item.regex }}"
            owner: rhel
            group: rhel
            mode: "0644"
          check_mode: "{{ check_mode | default(true) }}"
          register: __vscode_lightspeed
          loop: "{{ configure_tools['vscode_settings']['present'] }}"

        - name: Assert __vscode_lightspeed lines found
          ansible.builtin.assert:
            that:
              - item.found > 0
            fail_msg: The VS Code .vscode/settings.json missing Lightspeed entries.
            success_msg: VS Code Lightspeed config entries present.
          loop: "{{ __vscode_lightspeed.results }}"

PLAYBOOK_EOF

# Create track_vars.yml with all lab configuration variables

tee /tmp/track_vars.yml << 'TRACK_VARS_EOF'

---
# config vars
ansible_ssh_pipelining: true
ansible_ssh_extra_args: -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=60s
ansible_host_key_checking: false

track_slug: lightspeed-101

controller_username: "admin"
controller_password: ""
controller_hostname: "http://control.lab"
controller_validate_certs: false

# Gitea vars
gitea_http_port: 3000
gitea_protocol: http
gitea_hostname: gitea
gitea_app_url: "{{ gitea_protocol }}://{{ gitea_hostname }}:{{ gitea_http_port }}"
gitea_repo_name: acme_corp
gitea_org: student
gitea_clone_address: "https://github.com/ansible/ansible-lightspeed-demos"

# Lab vars
lab:
  credential_type:
    pub_ssh:
      name: Public SSH key credential type
  credential:
    pub_ssh:
      name: ACME Corp public SSH key
    ssh:
      name: ACME Corp machine credential
    controller:
      name: ACME Corp controller credential
    aws:
      name: ACME Corp AWS credential
    azure:
      name: ACME Corp Azure credential
  organization: ACME Corp
  project:
    name: ACME Corp Repo
    repo: "{{ gitea_app_url }}/{{ gitea_org }}/acme_corp.git"
    branch: main
  inventory:
    name: ACME Corp DC
    description: ACME Corp Data center
  execution_environment:
    name: ACME Corp execution environment
    image: quay.io/acme_corp/lightspeed-101_ee
  s3_bucket_name: tmm-instruqt-content.demoredhat.com.private
  workflow_name: Database ops workflow
  navigator_execution_environment:
    name: ACME Corp execution environment
    image: quay.io/acme_corp/lightspeed-101_ee

configure_tools:
  vscode_settings:
    present:
      - line: '\1"ansible.lightspeed.suggestions.enabled": true\2'
        regex: '^(.*?)"ansible.lightspeed.suggestions.enabled": true(.*?)$'
      - line: '\1"ansible.lightspeed.enabled": true\2'
        regex: '^(.*?)"ansible\.lightspeed\.enabled": true(.*?)$'

monitoring:
  playbooks:
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/infra/install_cockpit/demo_install_cockpit.yml"
      source_playbook: "files/solution_playbooks/solution_install_cockpit.yml"
  playbook_names:
    - demo_install_cockpit.yml
  jt_names:
    - Deploy monitoring

apache:
  playbooks:
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/infra/install_apache/demo_install_apache.yml"
      source_playbook: "files/solution_playbooks/solution_install_apache.yml"
  playbook_names:
    - demo_install_apache.yml
  jt_names:
    - Deploy Apache webserver

database:
  playbooks:
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/infra/install_postgresql/demo_install_postgresql.yml"
      source_playbook: "files/solution_playbooks/solution_install_postgresql.yml"
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/infra/install_pgadmin/demo_install_pgadmin.yml"
      source_playbook: "files/solution_playbooks/solution_install_pgadmin.yml"
  playbook_names:
    - demo_install_postgresql.yml
    - demo_install_pgadmin.yml
  jt_names:
    - Deploy PostgreSQL database
    - Configure PGAdmin container

workflow:
  playbooks:
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/infra/install_postgresql/demo_install_postgresql.yml"
      source_playbook: "files/solution_playbooks/solution_install_postgresql.yml"
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/infra/install_pgadmin/demo_install_pgadmin.yml"
      source_playbook: "files/solution_playbooks/solution_install_pgadmin.yml"
  playbook_names:
    - demo_install_postgresql.yml
    - demo_install_pgadmin.yml
  jt_names:
    - Deploy PostgreSQL database
    - Configure PGAdmin container

aws:
  playbooks:
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/cloud/aws/demo_provision_ec2.yml"
      source_playbook: "files/solution_playbooks/solution_provision_ec2.yml"
  playbook_names:
    - demo_provision_ec2.yml
  jt_names:
    - Provision demo EC2 instance

azure:
  playbooks:
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/cloud/azure/demo_provision_vm.yml"
      source_playbook: "files/solution_playbooks/solution_provision_vm.yml"
  playbook_names:
    - demo_provision_vm.yml
  jt_names:
    - Provision demo Azure VM

playground:
  playbooks:
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/infra/install_cockpit/demo_install_cockpit.yml"
      source_playbook: "files/solution_playbooks/initial_install_cockpit.yml"
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/infra/install_apache/demo_install_apache.yml"
      source_playbook: "files/solution_playbooks/initial_install_apache.yml"
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/infra/install_postgresql/demo_install_postgresql.yml"
      source_playbook: "files/solution_playbooks/initial_install_postgresql.yml"
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/infra/install_pgadmin/demo_install_pgadmin.yml"
      source_playbook: "files/solution_playbooks/initial_install_pgadmin.yml"
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/cloud/aws/demo_provision_ec2.yml"
      source_playbook: "files/solution_playbooks/initial_provision_ec2.yml"
    - dest_playbook: "~rhel/{{ gitea_repo_name }}/playbooks/cloud/azure/demo_provision_vm.yml"
      source_playbook: "files/solution_playbooks/initial_provision_vm.yml"

# Controller credentials configuration (commented out for dev machine setup)
# controller_credentials:
#   playground:
#     - name: "{{ lab.credential.ssh.name }}"
#       description: ACME Corp machine credential
#       organization: "{{ lab.organization }}"
#       state: present
#       credential_type: Machine
#       inputs:
#         username: rhel
#         ssh_key_data: "{{ lookup('file', '~/.ssh/instruqt_lab') }}"

# Controller templates configuration (commented out for dev machine setup)
# controller_templates:
#   playground:
#     - name: "{{ monitoring.jt_names[0] }}"
#       state: present
#       job_type: run
#       playbook: "playbooks/infra/install_cockpit/{{ monitoring.playbook_names[0] }}"
#       execution_environment: "{{ lab.execution_environment.name }}"
#       organization: "{{ lab.organization }}"
#       inventory: "{{ lab.inventory.name }}"
#       verbosity: 0
#       credentials:
#         - "{{ lab.credential.ssh.name }}"
#       project: "{{ lab.project.name }}"

TRACK_VARS_EOF

# Set controller password in track vars (heredoc above is non-expanding)
sed -i "s|controller_password:.*|controller_password: \"${COMMON_PASSWORD}\"|" /tmp/track_vars.yml

# Set environment variables for Ansible execution
export ANSIBLE_LOCALHOST_WARNING=False
export ANSIBLE_INVENTORY_UNPARSED_WARNING=False

# Note: Playbook execution is not needed during initial setup
# The playbook /tmp/setup.yml can be run later with tagged tasks for challenge setup/solve
# Example: ansible-playbook /tmp/setup.yml --tags setup-playground-playbooks
# Example: ansible-playbook /tmp/setup.yml --tags solve-database-playbooks

echo "Setup complete! Playbook and vars files created:"
echo "  - /tmp/setup.yml (challenge setup/solve playbook)"
echo "  - /tmp/track_vars.yml (configuration variables)"
echo ""
echo "To run tagged tasks, use:"
echo "  ansible-playbook /tmp/setup.yml --tags <tag-name>"
