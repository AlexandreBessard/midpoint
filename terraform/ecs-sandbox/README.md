# MidPoint ECS sandbox

Throwaway real-AWS infra to validate the deployment flow documented in
[`../../DEVOPS.md`](../../DEVOPS.md) against actual ECS/RDS/EFS - specifically the two
things that couldn't be checked locally (DEVOPS.md §10): does `sg-import` really
reach RDS, and does `force-new-deployment` really refresh midPoint's cache.

Cost: a few cents per hour (`db.t4g.micro`, one small Fargate task, no NAT Gateway,
no ALB). **Destroy it when you're done** (§6).

## 1. Prerequisites

- An AWS account and credentials configured (`aws sts get-caller-identity` should work).
- `terraform >= 1.5`, `docker`, `aws` CLI.
- Your public **IPv4** address: `curl -s -4 ifconfig.me` (the `-4` matters - plain
  `curl ifconfig.me` may return IPv6 on a dual-stack connection, which this
  IPv4-only sandbox's security groups can't use).

## 2. Configure

```sh
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set allowed_cidr to <your-ip>/32
```

## 3. Provision

```sh
terraform init
terraform plan
terraform apply
```

This creates the ECR repo, RDS, EFS, ECS cluster/service/task definitions, security
groups, IAM roles, and Secrets Manager secrets - but the `midpoint` service will sit
in a crash loop until you push an image and load the schema (next steps). That's
expected.

## 4. Build and push the image

```sh
$(terraform output -raw ecr_login_command)
terraform output docker_build_push_commands   # then run the two printed commands
```

## 5. Bootstrap (schema load, then start midpoint) - mirrors DEVOPS.md §8

```sh
# One-time schema load, direct JDBC, before midpoint can boot successfully
# (DEVOPS.md §4: the native/sqale repository doesn't auto-create its schema)
eval "$(terraform output -raw bootstrap_schema_load_command)"
# find the printed taskArn, then:
aws ecs wait tasks-stopped --cluster "$(terraform output -raw ecs_cluster_name)" --tasks <taskArn>
aws ecs describe-tasks --cluster "$(terraform output -raw ecs_cluster_name)" --tasks <taskArn> \
  --query 'tasks[0].containers[0].exitCode'   # expect 0

# Now (re)start midpoint against the now-initialized schema
terraform output create_service_note
```

Check it's healthy:
```sh
aws ecs describe-services --cluster "$(terraform output -raw ecs_cluster_name)" \
  --services "midpoint-sandbox-midpoint" --query 'services[0].deployments'
```

Find its public IP to hit the UI directly (optional, confirms the actual app, not
just the ECS-level health check):
```sh
TASK_ARN=$(aws ecs list-tasks --cluster "$(terraform output -raw ecs_cluster_name)" \
  --service-name "midpoint-sandbox-midpoint" --query 'taskArns[0]' --output text)
ENI_ID=$(aws ecs describe-tasks --cluster "$(terraform output -raw ecs_cluster_name)" \
  --tasks "$TASK_ARN" \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
curl -s "http://$PUBLIC_IP:8080/midpoint/actuator/health"
```

## 6. Run the import + restart flow - mirrors DEVOPS.md §7 (the actual CI steps)

```sh
eval "$(terraform output -raw run_import_task_command)"
# wait for it the same way as step 5, confirm exitCode 0

eval "$(terraform output -raw force_new_deployment_command)"
# this is the thing we specifically couldn't validate locally - confirm a new
# task starts, passes its health check, and old task drains
```

Re-run the `curl .../actuator/health` check from step 5 against the (new) public IP
to confirm midPoint came back up with the imported config.

## 7. Tear down

```sh
terraform destroy
```

Double-check in the console afterward (ECR repos and RDS sometimes leave artifacts
if a step failed mid-way) - this is a billable sandbox, don't leave it running.
