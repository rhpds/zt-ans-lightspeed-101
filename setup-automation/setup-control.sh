#!/bin/bash

# Ensure standard PATH is set (needed when run via different methods)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

systemctl stop systemd-tmpfiles-setup.service
systemctl disable systemd-tmpfiles-setup.service

nmcli connection add type ethernet con-name enp2s0 ifname enp2s0 ipv4.addresses 192.168.1.10/24 ipv4.method manual connection.autoconnect yes
nmcli connection up enp2s0
echo "192.168.1.10 control.lab control" >> /etc/hosts

# COMMON_PASSWORD is provided by the Ansible deployment (main.yml) via extra vars
# VM password is changed by main.yml before this script runs

RHEL_SSH_DIR="/home/rhel/.ssh"
RHEL_PRIVATE_KEY="$RHEL_SSH_DIR/id_rsa"
RHEL_PUBLIC_KEY="$RHEL_SSH_DIR/id_rsa.pub"

if [ -f "$RHEL_PRIVATE_KEY" ]; then
    echo "SSH key already exists for rhel user: $RHEL_PRIVATE_KEY"
else
    echo "Creating SSH key for rhel user..."
    sudo -u rhel mkdir -p /home/rhel/.ssh
    sudo -u rhel chmod 700 /home/rhel/.ssh
    sudo -u rhel ssh-keygen -t rsa -b 4096 -C "rhel@$(hostname)" -f /home/rhel/.ssh/id_rsa -N "" -q
    sudo -u rhel chmod 600 /home/rhel/.ssh/id_rsa*
    
    if [ -f "$RHEL_PRIVATE_KEY" ]; then
        echo "SSH key created successfully for rhel user"
    else
        echo "Error: Failed to create SSH key for rhel user"
    fi
fi

# Pre-configure Cockpit for route access
# This allows Cockpit to accept connections from the OpenShift route
# The Lightspeed-generated playbook will install Cockpit, which will use this config
echo "Pre-configuring Cockpit for route access..."
mkdir -p /etc/cockpit
cat > /etc/cockpit/cockpit.conf << COCKPIT_EOF
[WebService]
Origins = https://cockpit-${GUID}.${DOMAIN}
AllowUnencrypted = true
COCKPIT_EOF
echo "Cockpit configuration created at /etc/cockpit/cockpit.conf"

# Install Python 3.11
# Python 3.9 is not supported by some ansible collections
echo "Installing Python 3.11..."
dnf install -y python3.11 python3.11-pip

# Set Python 3.11 as the default python3 using alternatives
echo "Setting Python 3.11 as default python3..."
alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 1
alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 2
alternatives --set python3 /usr/bin/python3.11

echo "Python version updated:"
python3 -V

# Remove conflicting ansible-core RPM package (uses Python 3.9)
# We use the pip-installed ansible-core with Python 3.11 instead
# Note: This may also remove sshpass as a dependency, so we install it after
echo "Removing RPM ansible-core package to avoid version conflicts..."
dnf remove -y ansible-core || true

# Install sshpass after removing ansible-core to ensure it's available
# sshpass is needed to fetch cloud env variables from vscode node
echo "Installing sshpass..."
dnf install -y sshpass

# Verify sshpass installation
if command -v sshpass &> /dev/null; then
    echo "sshpass installed successfully: $(which sshpass)"
else
    echo "WARNING: sshpass installation may have failed. Attempting to continue..."
fi

# Install ansible-core with Python 3.11 using pip
# This ensures we use the latest ansible-core with Python 3.11 instead of the RPM version with Python 3.9
echo "Installing ansible-core with Python 3.11..."
python3.11 -m pip install --upgrade pip
python3.11 -m pip install ansible-core

# Find where pip installed ansible-core binaries
ANSIBLE_BIN_PATH=$(python3.11 -c "import site; print(site.USER_BASE + '/bin')")
echo "Ansible binaries installed to: $ANSIBLE_BIN_PATH"

# Ensure pip-installed ansible is in PATH
export PATH="$ANSIBLE_BIN_PATH:/usr/local/bin:$PATH"

echo "Ansible version:"
ansible --version

# Fetch cloud provider environment variables from vscode node
# RHDP sets cloud environment variables on vscode node, not control node
echo "Fetching cloud environment variables from vscode node..."

# Wait for vscode node setup to complete - retry up to 30 times (150 seconds)
RETRY_COUNT=0
MAX_RETRIES=30
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  # Use sshpass to connect to vscode node and check if setup is complete
  # The vscode node setup creates /home/rhel/.cloud_env and ~/acme_corp as final steps
  if /usr/bin/sshpass -p "${COMMON_PASSWORD}" ssh -o StrictHostKeyChecking=no rhel@vscode "test -f /home/rhel/.cloud_env && test -d /home/rhel/acme_corp" 2>/dev/null; then
    echo "Vscode node setup detected as complete"
    break
  fi

  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
    echo "Waiting for vscode node setup to complete... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 5
  else
    echo "WARNING: Timed out waiting for vscode node setup. Proceeding anyway..."
  fi
done

# Retrieve cloud environment variables from vscode node
/usr/bin/sshpass -p "${COMMON_PASSWORD}" ssh -o StrictHostKeyChecking=no rhel@vscode "cat /home/rhel/.cloud_env" > /tmp/.cloud_env 2>/dev/null

if [ -f /tmp/.cloud_env ]; then
  echo "Cloud environment variables retrieved from vscode node"
  # Move to system-wide profile.d location
  mv /tmp/.cloud_env /etc/profile.d/cloud_env.sh
  chmod 644 /etc/profile.d/cloud_env.sh

  # Source the cloud environment variables for this session
  source /etc/profile.d/cloud_env.sh

  echo "Cloud environment variables loaded:"
  echo "  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:10}..."
  echo "  AZURE_CLIENT_ID: ${AZURE_CLIENT_ID:0:10}..."

  # Run AWS/Azure resource preparation playbooks on vscode node where credentials are available
  echo "Setting up AWS resources on vscode node..."
  /usr/bin/sshpass -p "${COMMON_PASSWORD}" ssh -o StrictHostKeyChecking=no rhel@vscode "source /home/rhel/.cloud_env && cd ~/acme_corp && ansible-navigator run playbooks/cloud/aws/prepare_aws_environment.yml -m stdout"

  if [ $? -eq 0 ]; then
    echo "AWS resources created successfully"
  else
    echo "WARNING: Failed to create AWS resources. EC2 provisioning job template may not work correctly."
  fi

  echo "Setting up Azure resources on vscode node..."
  /usr/bin/sshpass -p "${COMMON_PASSWORD}" ssh -o StrictHostKeyChecking=no rhel@vscode "source /home/rhel/.cloud_env && cd ~/acme_corp && ansible-navigator run playbooks/cloud/azure/prepare_azure_environment.yml -m stdout"

  if [ $? -eq 0 ]; then
    echo "Azure resources created successfully"

    # Fetch the generated Azure SSH public key from vscode node
    echo "Fetching Azure SSH public key from vscode node..."
    /usr/bin/sshpass -p "${COMMON_PASSWORD}" ssh -o StrictHostKeyChecking=no rhel@vscode "cat ~/acme_corp/playbooks/cloud/azure/files/azure_demo_ssh_key.pub" > /tmp/azure_demo_ssh_key.pub 2>/dev/null

    if [ -f /tmp/azure_demo_ssh_key.pub ] && [ -s /tmp/azure_demo_ssh_key.pub ]; then
      echo "Azure SSH public key retrieved successfully"
      # Export it as an environment variable for use in the playbook
      export AZURE_SSH_PUB_KEY=$(cat /tmp/azure_demo_ssh_key.pub)
      echo "  Key fingerprint: $(echo $AZURE_SSH_PUB_KEY | cut -d' ' -f2 | cut -c1-20)..."
    else
      echo "WARNING: Could not retrieve Azure SSH public key. Azure VM provisioning may fail."
    fi
  else
    echo "WARNING: Failed to create Azure resources. Azure VM provisioning job template may not work correctly."
  fi
else
  echo "WARNING: Could not retrieve cloud environment variables from vscode node. AWS/Azure credentials may not be available."
fi

# Create a playbook for the user to execute

tee /tmp/setup.yml > /dev/null << EOF
### Automation Controller setup 
###
---
- name: Setup Controller
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
    azure_subscription: "{{ lookup('env', 'AZURE_SUBSCRIPTION_ID') | default('AZURE_SUBSCRIPTION_NOT_FOUND', true) }}"
    azure_tenant: "{{ lookup('env', 'AZURE_TENANT') | default('AZURE_TENANT_NOT_FOUND', true) }}"
    azure_client_id: "{{ lookup('env', 'AZURE_CLIENT_ID') | default('AZURE_CLIENT_ID_NOT_FOUND', true) }}"
    azure_password: "{{ lookup('env', 'AZURE_SECRET') | default('AZURE_SECRET_NOT_FOUND', true) }}"
    azure_resourcegroup: "{{ lookup('env', 'AZURE_RESOURCE_GROUP') | default('AZURE_RESOURCEGROUP_NOT_FOUND', true) }}"
    azure_ssh_pub_key: "{{ lookup('env', 'AZURE_SSH_PUB_KEY') | default('', true) }}"
    controller_login: &controller_login
      controller_username: "{{ controller_username }}"
      controller_password: "{{ controller_password }}"
      controller_host: "{{ controller_hostname }}"
      validate_certs: "{{ controller_validate_certs }}"

  vars_files:
    - track_vars.yml

  tasks:

    # Initial controller setup - runs automatically (no tags) at startup
    # Note: Using Default organization instead of creating custom one due to permissions
    - name: Initial Controller Setup - Create Execution Environment
      ansible.controller.execution_environment:
        name: "{{ lab.execution_environment.name }}"
        image: "{{ lab.execution_environment.image }}"
        pull: missing
        <<: *controller_login

    - name: Initial Controller Setup - Create Project from Gitea
      ansible.controller.project:
        name: "{{ lab.project.name }}"
        description: "ACME Corp playbooks from Gitea"
        organization: "{{ lab.organization }}"
        state: present
        scm_type: git
        scm_url: "{{ lab.project.repo }}"
        scm_branch: "{{ lab.project.branch }}"
        scm_update_on_launch: true
        scm_update_cache_timeout: 0
        default_environment: "{{ lab.execution_environment.name }}"
        <<: *controller_login
      register: __project_created
      retries: 5
      delay: 2
      until: __project_created is not failed

    - name: Initial Controller Setup - Update Project (sync)
      ansible.controller.project_update:
        name: "{{ lab.project.name }}"
        <<: *controller_login
      register: __project_update
      retries: 5
      delay: 2
      until: __project_update is not failed

    - name: Initial Controller Setup - Create Inventory
      ansible.controller.inventory:
        name: "{{ lab.inventory.name }}"
        description: "{{ lab.inventory.description }}"
        organization: "{{ lab.organization }}"
        state: present
        <<: *controller_login

    - name: Initial Controller Setup - Add control host to inventory
      ansible.controller.host:
        name: "control"
        inventory: "{{ lab.inventory.name }}"
        state: present
        <<: *controller_login
        variables:
          ansible_host: "control.lab"
          ansible_user: rhel
          ansible_password: "${COMMON_PASSWORD}"
          ansible_become_password: "${COMMON_PASSWORD}"
          ansible_python_interpreter: /usr/bin/python3
          ansible_ssh_extra_args: '-o StrictHostKeyChecking=no'

    - name: Initial Controller Setup - Add devtools (vscode) host to inventory
      ansible.controller.host:
        name: "devtools"
        inventory: "{{ lab.inventory.name }}"
        state: present
        <<: *controller_login
        variables:
          ansible_host: "vscode.lab"
          ansible_user: rhel
          ansible_password: "${COMMON_PASSWORD}"
          ansible_become_password: "${COMMON_PASSWORD}"
          ansible_python_interpreter: /usr/bin/python3
          ansible_ssh_extra_args: '-o StrictHostKeyChecking=no'

    - name: Initial Controller Setup - Create rhel group with hosts
      ansible.controller.group:
        name: "rhel"
        inventory: "{{ lab.inventory.name }}"
        state: present
        <<: *controller_login
        hosts:
          - control
          - devtools

    - name: Initial Controller Setup - Create SSH Machine Credential
      ansible.controller.credential:
        name: "{{ lab.credential.ssh.name }}"
        description: "SSH credential for ACME Corp machines"
        organization: "{{ lab.organization }}"
        credential_type: Machine
        state: present
        <<: *controller_login
        inputs:
          username: rhel
          ssh_key_data: "{{ lookup('file', '/home/rhel/.ssh/id_rsa') }}"

    - name: Initial Controller Setup - Create AWS Credential
      ansible.controller.credential:
        name: "{{ lab.credential.aws.name }}"
        description: "AWS credential for cloud provisioning"
        organization: "{{ lab.organization }}"
        credential_type: Amazon Web Services
        state: present
        <<: *controller_login
        inputs:
          username: "{{ aws_access_key }}"
          password: "{{ aws_secret_key }}"
      when:
        - aws_access_key is defined
        - aws_access_key != 'AWS_ACCESS_KEY_ID_NOT_FOUND'

    - name: Initial Controller Setup - Create Azure Credential
      ansible.controller.credential:
        name: "{{ lab.credential.azure.name }}"
        description: "Azure credential for cloud provisioning"
        organization: "{{ lab.organization }}"
        credential_type: Microsoft Azure Resource Manager
        state: present
        <<: *controller_login
        inputs:
          client: "{{ azure_client_id }}"
          secret: "{{ azure_password }}"
          subscription: "{{ azure_subscription }}"
          tenant: "{{ azure_tenant }}"
      when:
        - azure_subscription is defined
        - azure_subscription != 'AZURE_SUBSCRIPTION_NOT_FOUND'

    - name: Initial Controller Setup - Create Job Template - Deploy Monitoring
      ansible.controller.job_template:
        name: "Deploy monitoring"
        description: "Deploy Cockpit monitoring on control node"
        organization: "{{ lab.organization }}"
        state: present
        job_type: run
        playbook: "playbooks/infra/install_cockpit/demo_install_cockpit.yml"
        execution_environment: "{{ lab.execution_environment.name }}"
        inventory: "{{ lab.inventory.name }}"
        limit: "control"
        credentials:
          - "{{ lab.credential.ssh.name }}"
        project: "{{ lab.project.name }}"
        <<: *controller_login

    - name: Initial Controller Setup - Create Job Template - Deploy PostgreSQL and PGAdmin
      ansible.controller.job_template:
        name: "Deploy PostgreSQL and PG Admin"
        description: "Deploy PostgreSQL database and PGAdmin on devtools node"
        organization: "{{ lab.organization }}"
        state: present
        job_type: run
        playbook: "playbooks/infra/install_pgsql_and_pgadmin/demo_install_pgsql_pgadmin.yml"
        execution_environment: "{{ lab.execution_environment.name }}"
        inventory: "{{ lab.inventory.name }}"
        limit: "devtools"
        credentials:
          - "{{ lab.credential.ssh.name }}"
        project: "{{ lab.project.name }}"
        <<: *controller_login

    - name: Initial Controller Setup - Create Job Template - Provision EC2 Instance
      ansible.controller.job_template:
        name: "Provision EC2 instance"
        description: "Provision EC2 instance on AWS"
        organization: "{{ lab.organization }}"
        state: present
        job_type: run
        playbook: "playbooks/cloud/aws/demo_provision_ec2_instance.yml"
        execution_environment: "{{ lab.execution_environment.name }}"
        inventory: "{{ lab.inventory.name }}"
        credentials:
          - "{{ lab.credential.aws.name }}"
        project: "{{ lab.project.name }}"
        <<: *controller_login
      when:
        - aws_access_key is defined
        - aws_access_key != 'AWS_ACCESS_KEY_ID_NOT_FOUND'

    - name: Initial Controller Setup - Create Job Template - Provision Azure VM
      ansible.controller.job_template:
        name: "Provision Azure VM"
        description: "Provision VM on Azure"
        organization: "{{ lab.organization }}"
        state: present
        job_type: run
        playbook: "playbooks/cloud/azure/demo_provision_azure_vm.yml"
        execution_environment: "{{ lab.execution_environment.name }}"
        inventory: "{{ lab.inventory.name }}"
        credentials:
          - "{{ lab.credential.azure.name }}"
        project: "{{ lab.project.name }}"
        extra_vars:
          pub_key_data: "{{ azure_ssh_pub_key }}"
        <<: *controller_login
      when:
        - azure_subscription is defined
        - azure_subscription != 'AZURE_SUBSCRIPTION_NOT_FOUND'
        - azure_ssh_pub_key is defined
        - azure_ssh_pub_key | length > 0

  # Have to update objects with $_SANDBOX_ID in FQDN.
    - name: Setup initial environment
      tags:
        - setup-env
      block:
    #  Needs Instruqt Azure account name to be "azureadmin"
        - name: Setup Azure environment vars
          ansible.builtin.blockinfile:
            path: /etc/profile
            mode: "0644"
            owner: root
            group: root
            block: |
              export AZURE_CLIENT_ID="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SPN_ID}"
              export AZURE_TENANT="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_TENANT_ID}"
              export AZURE_SUBSCRIPTION_ID="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SUBSCRIPTION_ID}"
              export AZURE_SECRET="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SPN_PASSWORD}"
              export AZURE_PASSWORD="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_PASSWORD}"
              export AZURE_AD_USER="${INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_USERNAME}"

        - name: Wait for controller availability
          ansible.builtin.uri:
            url: https://localhost/api/v2/ping/
            method: GET
            user: "{{ controller_login.controller_username }}"
            password: "{{ controller_login.controller_password }}"
            validate_certs: "{{ controller_login.validate_certs }}"
          register: __controller_check
          until: 
            - __controller_check.json is defined 
            - __controller_check.json.instances[0].capacity > 0
            - __controller_check.json.instance_groups[0].capacity > 0
          retries: 20
          delay: 1

        #  Temp
        - name: Remove current repo dir
          ansible.builtin.file:
            state: absent
            path: "~{{ student_username }}/acme_corp"
          become_user: "{{ student_username }}"

        # # temp
        - name: Clone repository to {{ student_username }} # noqa latest[git]
          environment:
            GIT_SSL_NO_VERIFY: true
          ansible.builtin.git:
            repo: "{{ gitea_app_url }}/{{ student_username }}/{{ gitea_repo_name }}"
            dest: "~{{ student_username }}/acme_corp"
          become_user: "{{ student_username }}"

        # temp or rh1 branch
        - name: Temp - checkout devel
          ansible.builtin.command:
            # TODO fix to correct branch
            cmd: git checkout devel
            chdir: "~{{ student_username }}/{{ gitea_repo_name }}"
          become_user: "{{ student_username }}"
        # temp
        - name: Copy VS Code workspace settings to repo
          ansible.builtin.copy:
            src: "/opt/setup-scripts/{{ track_slug }}/files/.vscode"
            dest: "~{{ student_username }}/{{ gitea_repo_name }}/"
            remote_src: true
            owner: "{{ student_username }}"
            group: "{{ student_username }}"
            directory_mode: "755"
            mode: "644"
        # # temp
        - name: Fix directory permissions - {{ gitea_repo_name }}
          ansible.builtin.file:
            path: "~{{ student_username }}/{{ gitea_repo_name }}/.vscode"
            state: directory
            owner: "{{ student_username }}"
            group: "{{ student_username }}"
            mode: "755"
  
    - name: Solve Overwrite demo Playbooks with solution playbooks - {{ gitea_repo_name }}
      ansible.builtin.copy:
        src: "{{ item.source_playbook }}"
        dest: "{{ item.dest_playbook }}"
        owner: "{{ student_username }}"
        group: "{{ student_username }}"
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
        chdir: "~{{ student_username }}/{{ gitea_repo_name }}"
      become_user: "{{ student_username }}"
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
        chdir: "~{{ student_username }}/{{ gitea_repo_name }}"
      become_user: "{{ student_username }}"
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

    - name: Update controller credentials - {{ content_list }}
      ansible.controller.credential:
        name: "{{ item.name }}"
        description: "{{ item.description }}"
        organization: "{{ item.organization }}"
        state: "{{ item.state }}"
        inputs: "{{ item.inputs }}"
        credential_type: "{{ item.credential_type }}"
        <<: *controller_login
      # no_log: true
      delegate_to: localhost
      loop: "{{ controller_credentials[content_list] }}"
      when: 
        - controller_credentials is defined
        - content_list is defined
      retries: 10
      delay: 1
      tags:
        # Have to add playground-credentials because of content_list var
        - setup-playground-credentials
        - setup-aws-credentials
        - setup-azure-credentials

    - name: Setup - create job templates - {{ content_list }}
      ansible.controller.job_template:
        name: "{{ item.name }}"
        state: "{{ item.state }}"
        become_enabled: "{{ item.become_enabled | default(omit)}}"
        project: "{{ item.project }}"
        credentials: "{{ item.credentials }}"
        organization: "{{ item.organization }}"
        inventory: "{{ item.inventory }}"
        playbook: "{{ item.playbook }}"
        survey_spec: "{{ item.survey_spec | default(omit) }}"
        ask_inventory_on_launch: "{{ item.ask_inventory_on_launch | default(false) }}"
        ask_limit_on_launch: "{{ item.ask_limit_on_launch | default(omit) }}"
        extra_vars: "{{ item.extra_vars | default(omit) }}"
        limit: "{{ item.limit | default(omit) }}"
        execution_environment: "{{ item.execution_environment }}"
        job_tags: "{{ item.job_tags | default(omit) }}"
        <<: *controller_login
      delegate_to: localhost
      register: __create_job_templates
      until: not __create_job_templates.failed
      retries: 20
      delay: 1
      loop: "{{ controller_templates[content_list] }}"
      when: 
        - controller_templates[content_list] is defined
      tags:
        - setup-monitoring-jt
        - setup-database-jt
        - setup-workflow-jt
        - setup-aws-jt
        - setup-azure-jt
        - setup-playground-jt

    # AWS and Azure resources are now created on vscode node via prepare_aws_environment.yml
    # and prepare_azure_environment.yml playbooks (run via SSH earlier in this script)
    # No need for these tasks blocks here anymore

    - name: Solve configure-tools VS Code settings
      ansible.builtin.copy:
        src: "{{ playbook_dir }}/files/settings_workspace_solve.json"
        dest: "~{{ student_username }}/{{ gitea_repo_name }}/.vscode/settings.json"
        owner: "{{ student_username }}"
        group: "{{ student_username }}"
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
            path: "~{{ student_username }}/{{ gitea_repo_name }}/.vscode/settings.json"
            # path: "~{{ student_username }}/.config/Code/User/settings.json"
            state: absent
            backrefs: true
            regex: "{{ item.regex }}"
            owner: "{{ student_username }}"
            group: "{{ student_username }}"
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

    - name: Solve run job templates
      delegate_to: localhost
      ansible.controller.job_launch:
        name: "{{ item.name }}"
        wait: true
        <<: *controller_login
      loop: "{{ controller_templates[content_list] }}"
      when:
        - controller_templates[content_list] is defined
      tags:
        - solve-database-jt
        - solve-monitoring-jt
        - solve-aws-jt
        - solve-azure-jt

EOF

tee /tmp/track_vars.yml > /dev/null << EOF

---
# config vars
ansible_ssh_pipelining: true
ansible_ssh_extra_args: -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=60s
ansible_host_key_checking: false

track_slug: lightspeed-101

# controller_hostname: "{{ vault_controller_hostname }}"
# controller_validate_certs: "{{ vault_controller_validate_certs }}"
# controller_username: "{{ vault_controller_username }}"
# controller_password: "{{ vault_controller_password }}"

# student_username: "{{ vault_student_username }}"
# student_password: "{{ vault_student_password }}"

controller_username: "admin"
controller_password: "${COMMON_PASSWORD}"
controller_hostname: "https://localhost"
controller_validate_certs: false
student_username: "student"
student_password: "learn_ansible"


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
  organization: Default
  project:
    name: ACME Corp Repo
    repo: "{{ gitea_app_url }}/{{ student_username }}/acme_corp.git"
    branch: main
  inventory:
    name: ACME Corp DC
    description: ACME Corp Data center
  execution_environment:
    name: ACME Corp execution environment
    image: quay.io/acme_corp/lightspeed-101_ee
  s3_bucket_name: tmm-instruqt-content.demoredhat.com.private
  workflow_name: Database ops workflow
  # navigator_execution_environment: quay.io/acme_corp/lightspeed-101_ee
  navigator_execution_environment:
    name: ACME Corp execution environment
    image: quay.io/acme_corp/lightspeed-101_ee
# Gitea vars
gitea_http_port: 3000
gitea_protocol: http
gitea_hostname: gitea
gitea_app_url: "{{ gitea_protocol }}://{{ gitea_hostname }}:{{ gitea_http_port }}"
gitea_repo_name: acme_corp
# Dev
gitea_clone_address: "https://github.com/ansible/ansible-lightspeed-demos"

configure_tools:
  vscode_settings:
    present:
      - line: '\1"ansible.lightspeed.suggestions.enabled": true\2'
        regex: '^(.*?)"ansible.lightspeed.suggestions.enabled": true(.*?)$'
      - line: '\1"ansible.lightspeed.enabled": true\2'
        regex: '^(.*?)"ansible\.lightspeed\.enabled": true(.*?)$'
    # absent:
    #   - line: '\1"ansible.validation.lint.enabled": false\2'
    #     regex: '^(.*?)"ansible.validation.lint.enabled": false(.*?)$'
    #   - line: '\1"ansible.validation.enabled": false\2'
    #     regex: '^(.*?)"ansible.validation.enabled": false(.*?)$'

monitoring:
  playbooks:
    - dest_playbook: "~{{ student_username }}/{{ gitea_repo_name }}/playbooks/infra/install_cockpit/demo_install_cockpit.yml"
      source_playbook: "files/solution_playbooks/solution_install_cockpit.yml"
      # remote_src: true
  playbook_names:
    - demo_install_cockpit.yml
  jt_names:
    - Deploy monitoring
apache:
  playbooks:
    - dest_playbook: "~{{ student_username }}/{{ gitea_repo_name }}/playbooks/infra/install_apache/demo_install_apache.yml"
      source_playbook: "files/solution_playbooks/solution_install_apache.yml"
      # remote_src: true
  playbook_names:
    - demo_install_apache.yml
  jt_names:
    - Deploy Apache webserver
database:
  playbooks:
    - dest_playbook: "~{{ student_username }}/{{ gitea_repo_name }}/playbooks/infra/install_pgsql_and_pgadmin/demo_install_pgsql_pgadmin.yml"
      source_playbook: "files/solution_playbooks/solution_install_pgsql_pgadmin.yml"
      # remote_src: true
  playbook_names:
    - demo_install_pgsql_pgadmin.yml
  jt_names:
    - Deploy PostgreSQL and PG Admin
aws:
  playbooks:
    - dest_playbook: "~{{ student_username }}/{{ gitea_repo_name }}/playbooks/cloud/aws/demo_provision_ec2_instance.yml"
      source_playbook: "files/solution_playbooks/solution_provision_ec2_instance.yml"
      # remote_src: true
  playbook_names:
    - demo_provision_ec2_instance.yml
  jt_names:
    - Provision EC2 instance
azure:
  playbooks:
    - dest_playbook: "~{{ student_username }}/{{ gitea_repo_name }}/playbooks/cloud/azure/demo_provision_azure_vm.yml"
      source_playbook: "files/solution_playbooks/solution_provision_azure_vm.yml"
      # remote_src: true
  playbook_names:
    - demo_provision_azure_vm.yml
  jt_names:
    - Provision Azure VM
# workflow:
#   playbooks:
#     - dest_playbook: "~{{ student_username }}/{{ gitea_repo_name }}/playbooks/create_workflow.yml"
#       source_playbook: "files/initial_playbooks/create_workflow.yml"
#   jt_names:
#     - Solve - Create database ops workflow
playground:
  playbooks:
    - dest_playbook: "~{{ student_username }}/{{ gitea_repo_name }}/playbooks/infra/install_cockpit/demo_install_cockpit.yml"
      source_playbook: "files/initial_playbooks/demo_install_cockpit.yml"
    - dest_playbook: "~{{ student_username }}/{{ gitea_repo_name }}/playbooks/infra/install_pgsql_and_pgadmin/demo_install_pgsql.yml"
      source_playbook: "files/initial_playbooks/demo_install_pgsql_pgadmin.yml"
    - dest_playbook: "~{{ student_username }}/{{ gitea_repo_name }}/playbooks/cloud/aws/demo_provision_ec2_instance.yml"
      source_playbook: "files/initial_playbooks/demo_provision_ec2_instance.yml"
    - dest_playbook: "~{{ student_username }}/{{ gitea_repo_name }}/playbooks/cloud/azure/demo_provision_azure_vm.yml"
      source_playbook: "files/initial_playbooks/demo_provision_azure_vm.yml"

# PGAdmin container
pgadmin_service_name: app-pgadmin
pgadmin_container:
  name: pgadmin
  image: docker.io/dpage/pgadmin4
  ports:
    - 8083:80
  state: started
  generate_systemd:
    path: /etc/systemd/system/
    container_prefix: app
    restart_policy: always
  network: bridge
  env:
    PGADMIN_DEFAULT_EMAIL: "{{ student_username }}@example.com"
    PGADMIN_DEFAULT_PASSWORD: "{{ student_password }}"
# mattermost_app:
#   env:
#     MM_TEAMSETTINGS_SITENAME: ACME Corp Chat
#   generate_systemd:
#     path: /etc/systemd/system/
#     container_prefix: app
#     restart_policy: always
#   recreate: true
#   name: mattermost-preview
#   image: docker.io/mattermost/mattermost-preview
#   state: started
#   ports:
#     - 8065:8065

# Controller objects
controller_inventories:
  - name: "{{ lab.inventory.name }}"
    organization: "{{ lab.organization }}"
    description: "{{ lab.inventory.name }}"
    variables:
      ansible_ssh_private_key_file: ~/.ssh/instruqt_lab
      ansible_host: "{{ track_slug }}-controller"
      # ansible_host: "lightspeed-101-controller.{{ lookup('env', '_SANDBOX_ID') }}.svc.cluster.local"
      ansible_user: rhel
      ansible_python_interpreter: /usr/bin/python3
      ansible_ssh_extra_args: '-o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=60s'
      ansible_ssh_pipelining: true

controller_credentials:
  # - name: "{{ lab.credential.controller.name }}"
  #   organization: "{{ lab.organization }}"
  #   credential_type: Red Hat Ansible Automation Platform
  #   description: "{{ lab.credential.controller.name }}"
  #   state: present
  #   inputs:
  #     host: "{{ controller_hostname }}.{{ lookup('env', '_SANDBOX_ID') }}.svc.cluster.local"
  #     verify_ssl: "{{ controller_validate_certs }}"
  #     username: "{{ controller_username }}"
  #     password: "{{ controller_password }}"

  #  Might be temp - depends on if we stick with this format
  playground:
    - name: "{{ lab.credential.aws.name }}"
      organization: "{{ lab.organization }}"
      credential_type: Amazon Web Services
      description: "{{ lab.credential.aws.name }}"
      state: present
      inputs:
        username: "{{ lookup('env', 'AWS_ACCESS_KEY_ID', default='empty') }}"
        password: "{{ lookup('env', 'AWS_SECRET_ACCESS_KEY', default='empty') }}"
    - name: "{{ lab.credential.azure.name }}"
      organization: "{{ lab.organization }}"
      credential_type: Microsoft Azure Resource Manager
      description: "{{ lab.credential.azure.name }}"
      state: present
      inputs:
        # Can't use proper Azure vars here created in setup-env section.
        client: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SPN_ID') }}"
        secret: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SPN_PASSWORD') }}"
        subscription: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SUBSCRIPTION_ID') }}"
        tenant: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_TENANT_ID') }}"
        username: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_USERNAME') }}"
        password: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_PASSWORD') }}"
  aws:
    - name: "{{ lab.credential.aws.name }}"
      organization: "{{ lab.organization }}"
      credential_type: Amazon Web Services
      description: "{{ lab.credential.aws.name }}"
      state: present
      inputs:
        username: "{{ lookup('env', 'AWS_ACCESS_KEY_ID', default='empty') }}"
        password: "{{ lookup('env', 'AWS_SECRET_ACCESS_KEY', default='empty') }}"
  azure:
    - name: "{{ lab.credential.azure.name }}"
      organization: "{{ lab.organization }}"
      credential_type: Microsoft Azure Resource Manager
      description: "{{ lab.credential.azure.name }}"
      state: present
      inputs:
        client: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SPN_ID') }}"
        secret: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SPN_PASSWORD') }}"
        subscription: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_SUBSCRIPTION_ID') }}"
        tenant: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_TENANT_ID') }}"
        username: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_USERNAME') }}"
        password: "{{ lookup('ansible.builtin.env', 'INSTRUQT_AZURE_SUBSCRIPTION_AZUREADMIN_PASSWORD') }}"

controller_templates:
  # Temp - if this works build into image
  playground:
    - name: Provision Azure VM
      organization: "{{ lab.organization }}"
      state: present
      job_type: run
      playbook: "playbooks/cloud/azure/demo_provision_azure_vm.yml"
      execution_environment: "{{ lab.execution_environment.name }}"
      inventory: "{{ lab.inventory.name }}"
      credentials:
        - "{{ lab.credential.azure.name }}"
        - "{{ lab.credential.pub_ssh.name }}"
      project: "{{ lab.project.name }}"
      extra_vars:
        pub_key_data: "{{ lookup('ansible.builtin.file', '~/.ssh/instruqt_lab.pub') }}"
    - name: Provision EC2 instance
      organization: "{{ lab.organization }}"
      state: present
      job_type: run
      playbook: "playbooks/cloud/aws/demo_provision_ec2_instance.yml"
      execution_environment: "{{ lab.execution_environment.name }}"
      inventory: "{{ lab.inventory.name }}"
      credentials:
        - "{{ lab.credential.aws.name }}"
      project: "{{ lab.project.name }}"
    - name: Deploy monitoring
      organization: "{{ lab.organization }}"
      state: present
      job_type: run
      playbook: "playbooks/infra/install_cockpit/demo_install_cockpit.yml"
      execution_environment: "{{ lab.execution_environment.name }}"
      inventory: "{{ lab.inventory.name }}"
      credentials:
        - "{{ lab.credential.ssh.name }}"
      project: "{{ lab.project.name }}"
    - name: Deploy Apache webserver
      organization: "{{ lab.organization }}"
      state: present
      job_type: run
      playbook: "playbooks/infra/install_apache/demo_install_apache.yml"
      execution_environment: "{{ lab.execution_environment.name }}"
      inventory: "{{ lab.inventory.name }}"
      credentials:
        - "{{ lab.credential.ssh.name }}"
      project: "{{ lab.project.name }}"
    - name: Deploy PostgreSQL and PG Admin
      organization: "{{ lab.organization }}"
      state: present
      job_type: run
      playbook: "playbooks/infra/install_pgsql_and_pgadmin/demo_install_pgsql_pgadmin.yml"
      execution_environment: "{{ lab.execution_environment.name }}"
      inventory: "{{ lab.inventory.name }}"
      credentials:
        - "{{ lab.credential.ssh.name }}"
      project: "{{ lab.project.name }}"
  azure:
    - name: Provision Azure VM
      organization: "{{ lab.organization }}"
      state: present
      job_type: run
      playbook: "playbooks/cloud/azure/demo_provision_azure_vm.yml"
      execution_environment: "{{ lab.execution_environment.name }}"
      inventory: "{{ lab.inventory.name }}"
      credentials:
        - "{{ lab.credential.azure.name }}"
        - "{{ lab.credential.pub_ssh.name }}"
      project: "{{ lab.project.name }}"
      extra_vars:
        pub_key_data: "{{ lookup('ansible.builtin.file', '~/.ssh/instruqt_lab.pub') }}"
    # - name: Prepare Azure demo
    #   state: present
    #   job_type: run
    #   playbook: "playbooks/cloud/azure/prepare_azure_environment.yml"
    #   execution_environment: "{{ lab.execution_environment.name }}"
    #   organization: "{{ lab.organization }}"
    #   inventory: "{{ lab.inventory.name }}"
    #   verbosity: 0
    #   credentials:
    #     - "{{ lab.credential.azure.name }}"
    #   project: "{{ lab.project.name }}"
    #   extra_vars:
    #     _SANDBOX_ID: "{{ lookup('ansible.builtin.env', '_SANDBOX_ID') }}" # Updated in lifecycle script.
  aws:
    - name: Provision EC2 instance
      organization: "{{ lab.organization }}"
      state: present
      job_type: run
      playbook: "playbooks/cloud/aws/demo_provision_ec2_instance.yml"
      execution_environment: "{{ lab.execution_environment.name }}"
      inventory: "{{ lab.inventory.name }}"
      credentials:
        - "{{ lab.credential.aws.name }}"
      project: "{{ lab.project.name }}"
    # - name: Prepare AWS demo
    #   state: present
    #   job_type: run
    #   playbook: "playbooks/cloud/aws/prepare_aws_environment.yml"
    #   execution_environment: "{{ lab.execution_environment.name }}"
    #   organization: "{{ lab.organization }}"
    #   inventory: "{{ lab.inventory.name }}"
    #   verbosity: 0
    #   credentials:
    #     - "{{ lab.credential.aws.name }}"
    #   project: "{{ lab.project.name }}"
    #   extra_vars:
    #     _SANDBOX_ID: "{{ lookup('ansible.builtin.env', '_SANDBOX_ID') }}" # Updated in lifecycle script.
  monitoring:
    - name: Deploy monitoring
      organization: "{{ lab.organization }}"
      state: present
      job_type: run
      playbook: "playbooks/infra/install_cockpit/demo_install_cockpit.yml"
      execution_environment: "{{ lab.execution_environment.name }}"
      inventory: "{{ lab.inventory.name }}"
      credentials:
        - "{{ lab.credential.ssh.name }}"
      project: "{{ lab.project.name }}"
  apache:
    - name: Deploy Apache webserver
      organization: "{{ lab.organization }}"
      state: present
      job_type: run
      playbook: "playbooks/infra/install_apache/demo_install_apache.yml"
      execution_environment: "{{ lab.execution_environment.name }}"
      inventory: "{{ lab.inventory.name }}"
      credentials:
        - "{{ lab.credential.ssh.name }}"
      project: "{{ lab.project.name }}"
  database:
    - name: Deploy PostgreSQL and PG Admin
      organization: "{{ lab.organization }}"
      state: present
      job_type: run
      playbook: "playbooks/infra/install_pgsql_and_pgadmin/demo_install_pgsql_pgadmin.yml"
      execution_environment: "{{ lab.execution_environment.name }}"
      inventory: "{{ lab.inventory.name }}"
      credentials:
        - "{{ lab.credential.ssh.name }}"
      project: "{{ lab.project.name }}"
    # - name: Configure PGAdmin container
    #   organization: "{{ lab.organization }}"
    #   state: present
    #   job_type: run
    #   playbook: "playbooks/infra/install_pgsql_and_pgadmin/demo_pgadmin_podman.yml"
    #   execution_environment: "{{ lab.execution_environment.name }}"
    #   inventory: "{{ lab.inventory.name }}"
    #   credentials:
    #     - "{{ lab.credential.ssh.name }}"
    #   project: "{{ lab.project.name }}"
  # workflow:
  #   - name: Solve - Create database ops workflow
  #     state: present
  #     job_type: run
  #     playbook: "playbooks/create_workflow.yml"
  #     execution_environment: "{{ lab.execution_environment.name }}"
  #     organization: "{{ lab.organization }}"
  #     inventory: "{{ lab.inventory.name }}"
  #     verbosity: 0
  #     credentials:
  #       - "{{ lab.credential.ssh.name }}"
  #       - "{{ lab.credential.controller.name }}"
  #     project: "{{ lab.project.name }}"

# controller_workflows:
#   - name: "{{ lab.workflow_name }}"
#     description: "{{ lab.workflow_name }}"
#     organization: "{{ lab.organization }}"

# controller_workflow_nodes:
#   - all_parents_must_converge: false
#     organization: "{{ lab.organization }}"
#     workflow_job_template: "{{ lab.workflow_name }}"
#     identifier: Database
#     unified_job_template: Deploy PostgreSQL database
#     success_nodes:
#       - PGAdmin
#   - all_parents_must_converge: false
#     organization: "{{ lab.organization }}"
#     workflow_job_template: "{{ lab.workflow_name }}"
#     identifier: PGAdmin
#     unified_job_template: Configure PGAdmin container


EOF

##
export ANSIBLE_LOCALHOST_WARNING=False
export ANSIBLE_INVENTORY_UNPARSED_WARNING=False

# Run the controller setup playbook to configure initial setup
# Skip tagged tasks - only run the untagged initial setup tasks
# Use the certified collections bundled with AAP instead of galaxy collections
echo "Running controller initial setup..."
cd /tmp

# Find where pip installed ansible-core binaries
ANSIBLE_BIN_PATH=$(python3.11 -c "import site; print(site.USER_BASE + '/bin')")

# Ensure pip-installed ansible binaries are in PATH
export PATH="$ANSIBLE_BIN_PATH:/usr/local/bin:$PATH"
hash -r

echo "Using ansible from: $ANSIBLE_BIN_PATH"
ansible --version

# Set collections path to use AAP bundled collections if available, fallback to system collections
if [ -d "/tmp/ansible-automation-platform-containerized-setup-bundle-2.5-9-x86_64/collections/" ]; then
  export ANSIBLE_COLLECTIONS_PATH="/tmp/ansible-automation-platform-containerized-setup-bundle-2.5-9-x86_64/collections/:/root/.ansible/collections/ansible_collections/"
  echo "Using AAP bundled collections"
else
  export ANSIBLE_COLLECTIONS_PATH="/usr/share/ansible/collections:/root/.ansible/collections/ansible_collections/"
  echo "Using system collections"
fi

ansible-playbook setup.yml -e ansible_python_interpreter=/usr/bin/python3 --skip-tags setup-env,solve-monitoring-playbooks,solve-database-playbooks,solve-aws-playbooks,solve-azure-playbooks,solve-workflow-playbooks,setup-workflow-playbooks,solve-configure-tools,check-configure-tools,solve-database-jt,solve-monitoring-jt,solve-aws-jt,solve-azure-jt,setup-playground-playbooks,setup-playground-credentials,setup-playground-jt,setup-monitoring-jt,setup-database-jt,setup-aws-jt,setup-azure-jt 2>&1 | tee /tmp/controller_setup.log

if [ $? -eq 0 ]; then
  echo "Controller setup completed successfully!"
else
  echo "Controller setup failed - check /tmp/controller_setup.log for details"
  exit 1
fi

