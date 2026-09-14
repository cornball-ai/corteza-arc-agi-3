FROM rocker/r2u:noble@sha256:061613c564c752437e54db7544afebad8be79a2a7f64f20730a47e07d729819e

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=America/Chicago

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        r-cran-callr \
        r-cran-codetools \
        r-cran-curl \
        r-cran-digest \
        r-cran-jsonlite \
        r-cran-processx \
        r-cran-tinytest \
    && rm -rf /var/lib/apt/lists/*

COPY src/printify.tar.gz /opt/src/printify.tar.gz
COPY src/tinyoauth /opt/src/tinyoauth
COPY src/saber /opt/src/saber
COPY src/llm.api /opt/src/llm.api
COPY src/corteza /opt/src/corteza
COPY arcagi3 /opt/arcagi3
COPY SOURCE-MANIFEST.txt /opt/arcagi3/SOURCE-MANIFEST.txt

RUN Rscript -e 'for (p in c("/opt/src/printify.tar.gz", \
        "/opt/src/tinyoauth", "/opt/src/saber", "/opt/src/llm.api", \
        "/opt/src/corteza")) install.packages(p, repos = NULL, type = "source")' \
    && Rscript -e 'stopifnot( \
        packageVersion("corteza") >= "0.7.1.51", \
        packageVersion("llm.api") >= "0.1.9.9", \
        packageVersion("saber") >= "0.7.2.3", \
        "checkpoint_callback" %in% names(formals(llm.api::agent)))' \
    && chmod -R a-w /opt/src /opt/arcagi3 \
    && mkdir -p /home/arc/.cache/R/tinyoauth \
    && chmod 0755 /home/arc /home/arc/.cache /home/arc/.cache/R \
    && chmod 0770 /home/arc/.cache/R/tinyoauth

WORKDIR /opt/arcagi3
CMD ["bash", "/opt/arcagi3/sweep.sh", "claude-opus-5", "anthropic", "5", "2"]
