# External Extension for Quarto

This repository provides an extension for Quarto that allows you to include content from external sources or files into your Quarto documents.

## Installation

```bash
quarto add mcanouil/quarto-external
```

This will install the extension under the `_extensions` subdirectory.
If you're using version control, you will want to check in this directory.

## Usage

To use the external extension, you can include external content or a section from a file into your Quarto document using the `external` shortcode.

```markdown
{{< external <URL>#<section-id> >}}
```

> [!IMPORTANT]
> The `external` shortcode must be placed on its own line with no other content.
> Include blank lines both before and after the shortcode.
>
> Currently supports `.md`, `.markdown`, and `.qmd` files only.
>
> - `.md` and `.markdown` files are included as-is.
> - `.qmd` files are processed as Quarto documents, so you can use Quarto features like citations, cross-references, and math.
>
> **Note:** Using external content breaks the fully reproducible and self-contained nature of Quarto projects, as documents become dependent on external sources that may change or become unavailable.

## Example

Here is the source code for a minimal example: [example.qmd](example.qmd).

Outputs of `example.qmd`:

- [HTML](https://m.canouil.dev/quarto-external/)
