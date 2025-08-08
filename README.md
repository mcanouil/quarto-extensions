# Quarto Extensions Listing <img src="assets/media/quarto-extensions.svg" align="right" width="120" alt="Quarto extensions logo"/>

This is a listing of Quarto extensions using GitHub API to retrieve information from the repositories.

## How to submit your extension?

To add your extension to this list, please submit a pull request to this repository by adding your extension repository at the bottom of [`extensions/quarto-extensions.csv`](https://github.com/mcanouil/quarto-extensions/edit/main/extensions/quarto-extensions.csv) following `<owner>/<repository></optional-path>`.

```md
<owner>/<repository>
<owner>/<repository></optional-path>
```

> [!IMPORTANT]
> Before submitting, please make sure that:
>
> - The extension is not already listed.
> - Your GitHub repository contains a **Description**.
>   - Avoid special characters/strings in the **Description**, such as `'<style>'` instead of `` `<style>` ``.
> - Your GitHub repository contains **Topics**.
> - Your GitHub repository contains a **Release** with **Tag**.
> - Your GitHub repository has `example.qmd` or `template.qmd` file.
> - Your GitHub repository has only one extension  under `_extensions`.

## Disclaimer

This project is an independent community resource and is not affiliated with or endorsed by Quarto or its maintainers.

## Support

If you find this project helpful, please consider [sponsoring it](https://github.com/sponsors/mcanouil?o=esb) to support ongoing development and maintenance.
