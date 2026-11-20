.PHONY: apply destroy

VAR_FILE := terraform.tfvars
VAR_ARGS := $(if $(wildcard $(VAR_FILE)),-var-file=$(VAR_FILE),)

apply:
	terraform init -input=false
	terraform apply -input=false -auto-approve $(VAR_ARGS)

destroy:
	terraform init -input=false
	terraform destroy -input=false -auto-approve $(VAR_ARGS)
