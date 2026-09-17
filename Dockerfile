FROM nousresearch/hermes-agent:v2026.8.3@sha256:16788311e2fa3035456bdc1bafb8ec2b1777db64ebf020af9bb7eb73c3712c9e

# Install the Hermes Python SDK dependency into Hermes' own virtualenv.
# The base image intentionally has no system pip; uv is bundled by Hermes.
# The 282 MB Supermemory server binary is installed at runtime into the
# persistent /data volume, so Railway image builds stay fast and reliable.
RUN uv pip install --python /opt/hermes/.venv/bin/python supermemory

ENV PATH="/data/.supermemory-bin:/root/.local/bin:/root/.supermemory/bin:${PATH}"

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/hermes-railway-entrypoint

ENV HERMES_HOME=/data/.hermes \
    HERMES_WRITE_SAFE_ROOT=/data/.hermes \
    HERMES_LAZY_INSTALL_TARGET=/data/.hermes/lazy-packages \
    HERMES_DASHBOARD=1 \
    HERMES_DASHBOARD_HOST=0.0.0.0 \
    HERMES_GATEWAY_BOOTSTRAP_STATE=running

ENTRYPOINT ["/usr/local/bin/hermes-railway-entrypoint"]
CMD ["gateway", "run"]
