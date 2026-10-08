# Bootstrap image: creates the Vault Postgres schema and runs `vault operator init`.
# Kept tiny - just the tools the bootstrap script needs.
FROM alpine:3.20

RUN apk add --no-cache \
      bash \
      curl \
      jq \
      aws-cli \
      postgresql-client

COPY bootstrap.sh /usr/local/bin/bootstrap.sh
RUN chmod +x /usr/local/bin/bootstrap.sh

ENTRYPOINT ["/usr/local/bin/bootstrap.sh"]
