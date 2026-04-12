ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root

# System packages required for building R packages and rendering
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    jq libcurl4-openssl-dev libssl-dev libxml2-dev libfontconfig1-dev \
    libharfbuzz-dev libfribidi-dev libfreetype6-dev libpng-dev \
    libtiff5-dev libjpeg-dev libgit2-dev zlib1g-dev cmake \
    ghostscript \
    && rm -rf /var/lib/apt/lists/*

# R packages commonly needed by extensions
RUN Rscript -e 'install.packages(c( \
    "rmarkdown", "knitr", "reticulate", \
    "ggplot2", "dplyr", "tidyverse", \
    "kableExtra", "palmerpenguins", "gt", "tibble", "ragg" \
    ), repos = "https://cloud.r-project.org", lib = .Library)'

# Common LaTeX packages to avoid runtime CTAN mirror dependency
RUN if command -v tlmgr >/dev/null 2>&1; then \
    tlmgr update --self || true; \
    tlmgr install \
      beamer pgf xcolor geometry hyperref booktabs \
      caption float fancyhdr enumitem titlesec \
      listings xkeyval etoolbox iftex kvoptions \
      fontspec unicode-math lualatex-math \
      amsmath amscls tools graphics oberdiek \
      babel-english bookmark epstopdf-pkg grfext \
      infwarerr kvdefinekeys kvsetkeys ltxcmds \
      pdftexcmds tcolorbox environ tikzfill pdfcol \
      multirow makecell longtable wrapfig colortbl \
      tabu varwidth threeparttable threeparttablex \
      ulem adjustbox collectbox soul \
      fira sourcesanspro sourcecodepro \
      mdframed needspace zref \
      awesomebox fontawesome5 \
      babel-german raleway standalone tex-gyre \
    || true; \
    fi

ARG HOST_UID=1000
ARG HOST_GID=1000
RUN if [ -d /opt/tinytex ]; then chown -R ${HOST_UID}:${HOST_GID} /opt/tinytex; fi

USER vscode

# Python virtual environment with Jupyter and common packages
ENV UV_LINK_MODE=copy
RUN uv venv /home/vscode/.venv \
    && . /home/vscode/.venv/bin/activate \
    && uv pip install jupyter papermill matplotlib shinylive pyyaml
ENV VIRTUAL_ENV=/home/vscode/.venv
ENV PATH="/home/vscode/.venv/bin:${PATH}"
