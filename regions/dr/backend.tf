terraform {
  backend "s3" {
    # Supplied at init time, e.g.:
    #   terraform init \
    #     -backend-config="bucket=my-tf-state" \
    #     -backend-config="key=vault-ha/dr/terraform.tfstate" \
    #     -backend-config="region=us-east-1" \
    #     -backend-config="dynamodb_table=my-tf-locks"
    #
    # NOTE: the backend bucket/table can live in any region; only the Vault
    # infrastructure differs per region. Use a distinct key from the primary.
  }
}
