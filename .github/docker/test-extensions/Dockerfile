ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root

# System packages required for building R packages and rendering
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    jq libcurl4-openssl-dev libssl-dev libxml2-dev libfontconfig1-dev \
    libharfbuzz-dev libfribidi-dev libfreetype6-dev libpng-dev \
    libtiff5-dev libjpeg-dev libwebp-dev libgit2-dev zlib1g-dev cmake \
    libmagick++-dev ghostscript \
    && rm -rf /var/lib/apt/lists/*

# R packages commonly needed by extensions.
# pak pulls PPM binaries (no compilation) and auto-installs system
# requirements via apt (it runs here as root). pak ships in the image's
# user library, which root cannot see, so bootstrap it into the site
# library first.
# V8 is forced from source: the PPM binary links the system libnode, which
# the base image does not provide, so build it with its own static libv8.
RUN Rscript -e 'Sys.setenv(DOWNLOAD_STATIC_LIBV8 = "1"); \
    install.packages("pak", lib = .Library, repos = sprintf("https://r-lib.github.io/p/pak/stable/%s/%s/%s", .Platform$pkgType, R.Version()$os, R.Version()$arch)); \
    pak::pkg_install(c( \
    "rmarkdown", "knitr", "reticulate", \
    "ggplot2", "dplyr", "tidyverse", \
    "kableExtra", "palmerpenguins", "gt", "tibble", "ragg", \
    "magick", "V8?source" \
    ), lib = .Library, ask = FALSE)'

# Common LaTeX packages to avoid runtime CTAN mirror dependency
RUN if command -v tlmgr >/dev/null 2>&1; then \
    tlmgr update --self; \
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
      tex-gyre raleway babel-german \
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
    && uv pip install jupyter papermill matplotlib shinylive black
ENV VIRTUAL_ENV=/home/vscode/.venv
ENV PATH="/home/vscode/.venv/bin:${PATH}"
