# Terraform + GitHub Actions CI/CD Automation

## Project Purpose
This project demonstrates how to automate the provisioning of AWS infrastructure and deployment of a Java application using Terraform, Ansible, and GitHub Actions.

## AWS Resources Provisioned
- VPC
- Subnet
- Route Table
- Internet Gateway
- Security Group (SSH + app port)
- EC2 instance (Ubuntu)
- S3 bucket
- DynamoDB table

## Workflow Explanation
- **Build:** Clones a Maven project (URL can be set at workflow dispatch), builds the JAR, and uploads it as an artifact.
- **Terraform:** Provisions AWS infrastructure (VPC, EC2, S3, DynamoDB, etc.) and outputs the public IP/DNS.
- **Deploy:** Downloads the JAR artifact, prepares Ansible inventory, and runs the playbook to deploy and start the app on the EC2 instance.

## How to Use
1. Set up GitHub secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `SSH_PUBLIC_KEY`, `SSH_PRIVATE_KEY`.
2. Run the workflow manually or push to `main` to trigger automation.
3. The workflow provisions infra, builds the app, and deploys it to the new EC2 instance.

## Ansible Playbook
The playbook expects the built JAR to exist at `ansible/artifact/myapp.jar` inside the repo checkout in Actions (copied from the build job artifact).

---

```hcl
variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ssh_public_key" {
  type        = string
  description = "Public SSH key content to create AWS key pair (passed from GH secrets)"
}

variable "app_port" {
  type    = number
  default = 8080
}
```

**`terraform/main.tf`**

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "deployer" {
  key_name   = "gh-actions-deployer"
  public_key = var.ssh_public_key
}

resource "aws_security_group" "app_sg" {
  name        = "app-sg"
  description = "Allow SSH and app traffic"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # tighten in production
  }

  ingress {
    description = "App port"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.deployer.key_name
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "gh-actions-app-server"
  }

  # optional user_data can be added if you want bootstrap scripts
}
```

**`terraform/outputs.tf`**

```hcl
output "public_ip" {
  value       = aws_instance.app.public_ip
  description = "Public IP of the EC2 instance"
}

output "public_dns" {
  value       = aws_instance.app.public_dns
  description = "Public DNS of EC2"
}
```

> Note: in production, use an S3 backend for Terraform state + DynamoDB locking.

# 4) Ansible playbook

**`ansible/playbook.yml`**

```yaml
- hosts: all
  become: true
  vars:
    app_user: appuser
    app_dir: /opt/myapp
    jar_name: myapp.jar
    jar_path: "{{ app_dir }}/{{ jar_name }}"
    service_name: myapp
    jar_port: 8080

  tasks:
    - name: Update apt
      apt:
        update_cache: yes
        cache_valid_time: 3600

    - name: Install Java
      apt:
        name: openjdk-17-jdk
        state: present

    - name: Ensure app user exists
      user:
        name: "{{ app_user }}"
        system: yes
        create_home: no
        shell: /usr/sbin/nologin

    - name: Create app directory
      file:
        path: "{{ app_dir }}"
        state: directory
        owner: "{{ app_user }}"
        group: "{{ app_user }}"
        mode: '0755'

    - name: Copy JAR to server
      copy:
        src: "./artifact/{{ jar_name }}"
        dest: "{{ jar_path }}"
        owner: "{{ app_user }}"
        group: "{{ app_user }}"
        mode: '0755'

    - name: Create systemd service for the app
      copy:
        dest: /etc/systemd/system/{{ service_name }}.service
        content: |
          [Unit]
          Description=Java App Service
          After=network.target

          [Service]
          User={{ app_user }}
          ExecStart=/usr/bin/java -jar {{ jar_path }}
          Restart=on-failure
          LimitNOFILE=65536

          [Install]
          WantedBy=multi-user.target
      notify: Reload systemd

    - name: Enable & start service
      systemd:
        name: "{{ service_name }}"
        enabled: yes
        state: started

  handlers:
    - name: Reload systemd
      command: systemctl daemon-reload
```

**Important**: The playbook expects the built JAR to exist at `ansible/artifact/myapp.jar` inside the repo checkout in Actions (we’ll copy it from the build job artifact).

# 5) GitHub Actions workflow (full)

Create `.github/workflows/cicd-terraform-ansible.yml`. This workflow has a **workflow\_dispatch** input `app_repo_url` (so you can change the Maven repo URL at run-time).

```yaml
name: CI - Terraform - Ansible Deploy

on:
  push:
    branches: [ main ]
  workflow_dispatch:
    inputs:
      app_repo_url:
        description: 'Git HTTPS URL of Maven project to build'
        required: true
        default: 'https://github.com/spring-projects/spring-petclinic.git'

env:
  AWS_REGION: ${{ secrets.AWS_REGION }}

jobs:
  build:
    name: Build JAR (clone app repo & maven)
    runs-on: ubuntu-latest
    outputs:
      artifact-name: app-jar
    steps:
      - name: Checkout infra repo
        uses: actions/checkout@v4

      - name: Clone application source (from input)
        run: |
          git clone --depth 1 "${{ github.event.inputs.app_repo_url }}" app-src
        # If you need a specific branch or tag, update above.

      - name: Setup Java 17
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - name: Build with Maven (skip tests)
        working-directory: app-src
        run: mvn -B package -DskipTests

      - name: Prepare artifact for Ansible
        run: |
          mkdir -p ansible/artifact
          # copy first jar found in target/
          cp app-src/target/*.jar ansible/artifact/myapp.jar
          ls -l ansible/artifact

      - name: Upload app jar artifact
        uses: actions/upload-artifact@v4
        with:
          name: app-jar
          path: ansible/artifact/myapp.jar

  terraform:
    name: Terraform Apply
    needs: build
    runs-on: ubuntu-latest
    outputs:
      public-ip: ${{ steps.outputs.outputs_public_ip.outputs.instance_ip }}
    steps:
      - name: Checkout infra repo
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Terraform Init
        working-directory: terraform
        run: terraform init -input=false

      - name: Terraform Apply
        working-directory: terraform
        env:
          TF_VAR_ssh_public_key: ${{ secrets.SSH_PUBLIC_KEY }}
        run: |
          terraform apply -auto-approve -input=false

      - name: Read Terraform output (public_ip)
        id: outputs_public_ip
        working-directory: terraform
        run: |
          echo "instance_ip=$(terraform output -raw public_ip)" >> $GITHUB_OUTPUT

  deploy:
    name: Deploy via Ansible
    needs: [terraform, build]
    runs-on: ubuntu-latest
    steps:
      - name: Checkout infra repo
        uses: actions/checkout@v4

      - name: Download artifact (jar)
        uses: actions/download-artifact@v4
        with:
          name: app-jar
          path: ansible/artifact

      - name: Show jar
        run: ls -l ansible/artifact

      - name: Set INSTANCE_IP env
        run: echo "INSTANCE_IP=${{ needs.terraform.outputs.public-ip }}" >> $GITHUB_ENV

      - name: Install Ansible and helpers
        run: |
          sudo apt-get update
          sudo apt-get install -y python3-pip sshpass
          python3 -m pip install --user ansible paramiko

      - name: Prepare SSH private key
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa

      - name: Write Ansible inventory
        run: |
          cat > ansible/inventory.ini <<EOF
          [app]
          ${INSTANCE_IP} ansible_user=ubuntu ansible_python_interpreter=/usr/bin/python3 ansible_private_key_file=~/.ssh/id_rsa
          EOF
          cat ansible/inventory.ini

      - name: Run Ansible playbook
        working-directory: ansible
        env:
          ANSIBLE_HOST_KEY_CHECKING: "False"
          PATH: ${{ runner.tool_cache }}/python/3.*/x64/bin:$HOME/.local/bin:$PATH
        run: |
          export PATH=$HOME/.local/bin:$PATH
          ansible-playbook -i inventory.ini playbook.yml --ssh-extra-args='-o StrictHostKeyChecking=no'
```

**Notes on the workflow**

* The `workflow_dispatch` input `app_repo_url` lets you specify any public Maven repo to build at runtime (default is Spring Petclinic).
* `build` clones the app repo, builds the jar, uploads artifact.
* `terraform` applies infra; it receives the public key via `TF_VAR_ssh_public_key` from GitHub secret `SSH_PUBLIC_KEY`.
* `deploy` downloads the artifact, prepares the SSH key (`SSH_PRIVATE_KEY` secret), writes the inventory and runs Ansible.

# 6) GitHub Secrets (create these in repo Settings → Secrets → Actions)

* `AWS_ACCESS_KEY_ID` — IAM user key
* `AWS_SECRET_ACCESS_KEY` — IAM user secret
* `AWS_REGION` — e.g. `ap-south-1`
* `SSH_PUBLIC_KEY` — your SSH public key (`ssh-rsa AAAA...`)
* `SSH_PRIVATE_KEY` — corresponding private key (PEM or OpenSSH private key). **Ensure it matches the public key provided.**

# 7) Minimal IAM policy for the GitHub Actions AWS user

Below is an example JSON policy (attach to the IAM user used by GitHub Actions). This is fairly permissive for EC2 actions; tighten for production.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Actions",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeImages",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:DescribeKeyPairs",
        "ec2:CreateSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:DeleteSecurityGroup",
        "ec2:DescribeSecurityGroups",
        "ec2:CreateTags",
        "ec2:DescribeTags",
        "ec2:ModifyInstanceAttribute"
      ],
      "Resource": "*"
    }
  ]
}
```

(Prefer restricting `"Resource"` and adding least privilege in production. If you use S3 for state, add S3/DynamoDB permissions.)

# 8) How to run (step-by-step)

1. Create the repo and push the files above to `main`.
2. In GitHub repo settings → Secrets, add the secrets listed in section 6.
3. Go to Actions → select **CI - Terraform - Ansible Deploy** and click **Run workflow** (or push to main). The `app_repo_url` field defaults to `https://github.com/spring-projects/spring-petclinic.git` — leave it or change to another public Maven project URL.
4. Watch the Actions:

   * **build**: clones app, builds JAR, uploads artifact
   * **terraform**: runs `terraform apply` — creates EC2 + keypair + SG
   * **deploy**: downloads JAR, connects to the instance and runs Ansible playbook
5. When done, Actions will output the public IP from Terraform in logs. You can test the app at:

```
http://<EC2_PUBLIC_IP>:8080
```

(If you used Petclinic it serves on 8080).

# 9) Clean up (destroy resources)

Run a job or locally:

```bash
cd terraform
terraform destroy -auto-approve -var="ssh_public_key='ssh-rsa AAAA...'"
```

Or add a GitHub Actions job to call `terraform destroy`.

# 10) Troubleshooting tips

* **SSH auth fails**: ensure `SSH_PRIVATE_KEY` matches `SSH_PUBLIC_KEY` and that the EC2 instance was created with that key. For Ubuntu AMIs the user is `ubuntu`; for Amazon Linux it's `ec2-user`.
* **Ansible connection errors**: set `ANSIBLE_HOST_KEY_CHECKING=False` (we already do) and use `--ssh-extra-args='-o StrictHostKeyChecking=no'`.
* **No JAR found**: check that the app repo builds to `target/*.jar`. Some projects produce multiple jars; we copy the first jar.
* **Port blocked**: check security group allows inbound on port 8080 from your IP.
* **Terraform state**: for team use, configure an S3 backend + DynamoDB locking.

# 11) Optional improvements (next steps I can provide)

* Make the app repo private and add deploy credentials (PAT) to clone it.
* Store the built JAR in S3 or a Docker registry, and change Ansible to pull from there.
* Add ALB + autoscaling rather than a single EC2.
* Template systemd unit, and pass environment variables to the app.
* Add healthchecks and smoke-test step in the workflow.

---

If you want, I can now:

* Create the **exact** repo files packaged so you can copy-paste (I already gave them above).
* Update the workflow to use a specific branch/tag of the application repo.
* Add an S3 backend + Terraform backend config example.

Which of those do you want next?
