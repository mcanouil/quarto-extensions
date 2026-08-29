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

# uv keeps the interpreters it downloads under HOME by default, and the render
# step gives every extension its own HOME, so the pinned interpreter would be
# downloaded again for each of them. Hold it outside HOME instead. The mode is
# the one /tmp uses: the render containers run under the host user, which is
# not known here, and a container writes only to its own discarded layer.
RUN install -d -m 1777 /opt/uv-python
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python

USER vscode

# Python virtual environment with Jupyter and common packages.
# The version is pinned instead of resolved by uv: the render scripts share
# these packages with a project venv only when the two Python minor versions
# match, and uv picks the newest interpreter it can find, so an unpinned venv
# would withdraw them from every extension the day a new release lands.
# 3.13 is the version most extensions resolve to. deps-install.sh builds the
# project venv on HARNESS_PYTHON too, unless the repository excludes it.
ARG HARNESS_PYTHON=3.13
ENV UV_LINK_MODE=copy
ENV IMAGE_VENV=/home/vscode/.venv
# deps-install.sh reads this list to replace the packages an extension loses
# when its Python version differs from the image one.
ENV IMAGE_BASELINE="jupyter papermill matplotlib shinylive black"
RUN uv venv --python ${HARNESS_PYTHON} ${IMAGE_VENV} \
    && . ${IMAGE_VENV}/bin/activate \
    && uv pip install ${IMAGE_BASELINE}
ENV HARNESS_PYTHON=${HARNESS_PYTHON}
ENV VIRTUAL_ENV=${IMAGE_VENV}
ENV PATH="${IMAGE_VENV}/bin:${PATH}"
