# Lab 7 — GitHub Actions CI/CD

**Goal:** Automate `terraform plan` on pull requests and `terraform apply` on merge to `main`, with secrets and an approval gate.

**Depends on:** Labs 0–6 complete (full Terraform config working locally)

**Reference in repo:** [`.github/workflows/terraform.yml`](../../.github/workflows/terraform.yml)

---

## What the Pipeline Does

```
Pull Request  ──►  terraform fmt / init / validate / plan  (no apply)
       │
       ▼
Merge to main ──►  plan again  ──►  PAUSE for approval  ──►  terraform apply
       │
Manual dispatch ──►  plan | apply | destroy (destroy needs typing "destroy")
```

---

## Step 7.1 — Create workflow file

```bash
mkdir -p .github/workflows
```

Create `.github/workflows/terraform.yml`. Copy from the repo or use this structure:

```yaml
name: Terraform Infrastructure

on:
  push:
    branches: [main]
    paths:
      - 'envs/dev/**'
      - 'modules/**'
  pull_request:
    branches: [main]
    paths:
      - 'envs/dev/**'
      - 'modules/**'
  workflow_dispatch:
    inputs:
      action:
        description: 'Terraform action'
        required: true
        default: 'plan'
        type: choice
        options: [plan, apply, destroy]
      confirm_destroy:
        description: 'Type "destroy" to confirm destruction'
        required: false
        default: ''

permissions:
  contents: read

env:
  TF_VERSION: '1.15.6'
  AWS_REGION: us-east-1
  TF_STATE_BUCKET: zen-pharma-terraform-state-YOUR-UNIQUE-SUFFIX

concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: false

jobs:
  plan:
    name: Terraform Plan
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: envs/dev
    steps:
      - uses: actions/checkout@v5

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v5
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Terraform Format Check
        run: terraform fmt -check -recursive
        continue-on-error: true

      - name: Terraform Init
        run: terraform init

      - name: Terraform Validate
        run: terraform validate -no-color

      - name: Terraform Plan
        run: |
          terraform plan \
            -var="db_password=${{ secrets.DEV_DB_PASSWORD }}" \
            -var="jwt_secret=${{ secrets.DEV_JWT_SECRET }}" \
            -var="github_org=YOUR-GITHUB-ORG" \
            -out=tfplan \
            -no-color

      - name: Upload plan file
        uses: actions/upload-artifact@v6
        with:
          name: tfplan
          path: envs/dev/tfplan
          retention-days: 1

  apply:
    name: Terraform Apply
    runs-on: ubuntu-latest
    needs: plan
    if: |
      (github.ref == 'refs/heads/main' && github.event_name == 'push') ||
      (github.event_name == 'workflow_dispatch' && github.event.inputs.action == 'apply')
    environment: dev
    defaults:
      run:
        working-directory: envs/dev
    steps:
      - uses: actions/checkout@v5

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v5
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Terraform Init
        run: terraform init

      - name: Download plan file
        uses: actions/download-artifact@v6
        with:
          name: tfplan
          path: envs/dev

      - name: Terraform Apply
        run: terraform apply -auto-approve -no-color tfplan

  destroy:
    name: Terraform Destroy
    runs-on: ubuntu-latest
    if: |
      github.event_name == 'workflow_dispatch' &&
      github.event.inputs.action == 'destroy' &&
      github.event.inputs.confirm_destroy == 'destroy'
    environment: dev
    defaults:
      run:
        working-directory: envs/dev
    steps:
      - uses: actions/checkout@v5

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v5
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Terraform Init
        run: terraform init

      - name: Terraform Destroy
        run: |
          terraform destroy \
            -var="db_password=${{ secrets.DEV_DB_PASSWORD }}" \
            -var="jwt_secret=${{ secrets.DEV_JWT_SECRET }}" \
            -var="github_org=${{ vars.GH_ORG }}" \
            -auto-approve \
            -no-color

      - name: Release state lock on failure
        if: failure() || cancelled()
        run: |
          aws s3 rm s3://${{ vars.TF_STATE_BUCKET }}/envs/dev/terraform.tfstate.tflock || true
```

**Replace:**
- `TF_STATE_BUCKET` — your S3 bucket name (must match `backend.tf`)
- `github_org=YOUR-GITHUB-ORG` — your GitHub org or username (plan/apply jobs)

**Destroy job notes:**

| Line | Purpose |
|---|---|
| `if: workflow_dispatch && action == destroy && confirm_destroy == destroy` | Destroy runs **only** when you manually trigger it and type `destroy` to confirm — never on push/merge |
| `environment: dev` | Same approval gate as apply — a human must approve before resources are deleted |
| `terraform destroy` (not `tfplan`) | Destroy does not use the saved plan file; it removes all resources in state |
| `Release state lock on failure` | Cleans up S3 state lock if the job fails mid-run |

See the full workflow (including plan job state lock cleanup) in [`.github/workflows/terraform.yml`](../../.github/workflows/terraform.yml).

---

## Step 7.2 — GitHub Repository Secrets

Go to **GitHub → your repo → Settings → Secrets and variables → Actions → Secrets**

| Secret name | Value | Used for |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user access key | AWS authentication in CI |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key | AWS authentication in CI |
| `DEV_DB_PASSWORD` | Strong password (8+ chars) | RDS master password |
| `DEV_JWT_SECRET` | Random string (`openssl rand -hex 32`) | JWT signing secret |

**Why Secrets (not Variables)?** These values are sensitive — GitHub encrypts secrets and never shows them in logs.

Generate a JWT secret:

```bash
openssl rand -hex 32
```

---

## Step 7.3 — GitHub Repository Variables (optional)

Go to **Settings → Secrets and variables → Actions → Variables**

| Variable name | Example value | Used for |
|---|---|---|
| `TF_STATE_BUCKET` | `zen-pharma-terraform-state-your-name` | Destroy job state lock cleanup |
| `GH_ORG` | `your-github-org` | Destroy job `-var=github_org` |

Variables are non-sensitive configuration. The plan job uses `env.TF_STATE_BUCKET` at the workflow level.

---

## Step 7.4 — GitHub Environment (approval gate)

Go to **Settings → Environments → New environment**

- Name: `dev`
- Enable **Required reviewers** → add yourself
- Save

The `apply` job declares `environment: dev` — GitHub pauses and shows **Review deployments** before running `terraform apply`.

**Why?** Prevents accidental infrastructure changes even if bad code merges to `main`.

---

## Step 7.5 — Update `backend.tf` to match workflow

Ensure `envs/dev/backend.tf` bucket name matches `env.TF_STATE_BUCKET` in the workflow:

```hcl
bucket = "zen-pharma-terraform-state-YOUR-UNIQUE-SUFFIX"
```

---

## Step 7.6 — Run the pipeline

### First run via Pull Request

```bash
git checkout -b lab/complete-infra
git add .
git commit -m "feat: complete zen-pharma infra modules and CI pipeline"
git push -u origin lab/complete-infra
```

Open a PR to `main`. Watch **Actions → Terraform Plan**:
- `terraform fmt -check` passes
- `terraform validate` passes
- Plan shows expected resources

### Apply after merge

1. Merge PR to `main`
2. Plan job runs again on `main`
3. Apply job starts and **pauses** at the `dev` environment
4. Go to **Actions → running workflow → Review deployments → Approve**
5. Wait ~20–25 minutes for EKS + RDS

### Verify after apply

```bash
aws eks update-kubeconfig --region us-east-1 --name pharma-dev-cluster
kubectl get nodes

aws rds describe-db-instances --query 'DBInstances[0].DBInstanceStatus'
aws secretsmanager list-secrets --query 'SecretList[?contains(Name, `/pharma/dev`)].Name'
```

---

## Step 7.7 — Destroy when done (save costs)

**Actions → Terraform Infrastructure → Run workflow**

| Input | Value |
|---|---|
| action | `destroy` |
| confirm_destroy | `destroy` |

Approve at the `dev` environment gate. Wait ~15–20 minutes.

---

## Secrets & Variables Summary Table

| Name | Type | Where set | Passed to Terraform as |
|---|---|---|---|
| `AWS_ACCESS_KEY_ID` | Secret | GitHub Secrets | AWS credentials action |
| `AWS_SECRET_ACCESS_KEY` | Secret | GitHub Secrets | AWS credentials action |
| `DEV_DB_PASSWORD` | Secret | GitHub Secrets | `-var="db_password=..."` |
| `DEV_JWT_SECRET` | Secret | GitHub Secrets | `-var="jwt_secret=..."` |
| `TF_STATE_BUCKET` | Variable | GitHub Variables / workflow `env` | State lock cleanup script |
| `GH_ORG` | Variable | GitHub Variables | `-var="github_org=..."` (destroy) |
| `github_org` | Terraform variable | workflow `-var` flag | IAM OIDC trust policy |
| `github_org_id` | Terraform variable | `envs/dev/variables.tf` default | IAM OIDC trust policy |
| `github_repo_ids` | Terraform variable | `envs/dev/variables.tf` default | IAM OIDC trust policy |

---

## Teaching Points

| Question | Answer |
|---|---|
| Why plan on PR but apply only on main? | Review changes before anything touches AWS |
| Why upload `tfplan` as artifact? | Apply runs exactly what was planned — no drift between review and apply |
| Why destroy skips the plan file? | Destroy removes resources; it uses `terraform destroy` directly, not a saved plan |
| Why `environment: dev`? | Manual approval gate before destructive/ costly changes |
| Why static AWS keys in GitHub Secrets for infra CI? | Bootstrap — app repos later use OIDC role from Lab 5 |
| Why `paths` filter? | Workflow only runs when Terraform files change |

---

## Final Checkpoint — Lab Complete

- [ ] All 6 modules built and wired (Labs 1–6)
- [ ] `.github/workflows/terraform.yml` committed
- [ ] GitHub Secrets configured (4 secrets)
- [ ] GitHub Environment `dev` with required reviewer
- [ ] PR plan succeeds
- [ ] Merge + approve apply → infrastructure live in AWS
- [ ] Destroy workflow tested when lab ends

---

## You Built This

```
Lab 0  →  provider, backend, variables
Lab 1  →  VPC module
Lab 2  →  EKS module        ← wired to VPC outputs
Lab 3  →  RDS module        ← wired to VPC + EKS outputs
Lab 4  →  ECR module
Lab 5  →  IAM module        ← wired to EKS outputs
Lab 6  →  Secrets module    ← wired to RDS output
Lab 7  →  GitHub Actions    ← automates plan/apply
```

**Further reading:** [Terraform Modules Guide](../terraform-modules-guide.md) · [Main README](../../README.md)
