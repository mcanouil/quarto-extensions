#!/usr/bin/env bash
set -euo pipefail

# Generate extensions-listing.json from extensions.json and extension.yml files
# for client-side progressive rendering.
# Called during Quarto pre-render.

output_file="extensions-listing.json"
source_file="extensions.json"

if [[ ! -f "${source_file}" ]]; then
	echo "[]" >"${output_file}"
	echo "Warning: ${source_file} not found, generated empty listing data."
	exit 0
fi

# Build a lookup from extension.yml files for fields not in extensions.json:
# - usage (owner/repo@version format)
# - categories (includes derived values beyond repositoryTopics)
# - contributes
# - file-modified
# - image (local path)
# - image-alt
# - stars (formatted)
# - template / example flags

yml_data_json=$(python3 -c "
import json, sys, base64, urllib.parse, os, re

result = {}
for root, dirs, files in os.walk('extensions'):
    if 'extension.yml' not in files:
        continue
    yml_path = os.path.join(root, 'extension.yml')

    # Parse the YAML manually (simple key-value format, no nested structures)
    data = {}
    with open(yml_path) as f:
        for line in f:
            line = line.rstrip()
            if not line or line.startswith('#'):
                continue
            # Handle list start
            if line.startswith('- '):
                line = line[2:]
            # Handle indented key-value pairs
            line = line.lstrip()
            if ':' not in line:
                continue
            key, _, val = line.partition(':')
            key = key.strip()
            val = val.strip()

            # Remove surrounding quotes
            if val.startswith('\"') and val.endswith('\"'):
                val = val[1:-1]
            elif val.startswith(\"'\") and val.endswith(\"'\"):
                val = val[1:-1]

            # Handle YAML lists like [\"a\",\"b\"]
            if val.startswith('[') and val.endswith(']'):
                val = [v.strip().strip('\"').strip(\"'\") for v in val[1:-1].split(',') if v.strip()]
            # Handle multiline (|) - just use what's there
            elif val == '|':
                val = ''  # multiline values read from remaining lines
                continue
            elif val == 'true':
                val = True
            elif val == 'false':
                val = False
            data[key] = val

    usage = data.get('usage', '')
    if not usage:
        continue

    # Derive the key (owner/repo) from directory structure
    parts = root.split(os.sep)
    # extensions/{owner}/{repo}
    if len(parts) >= 3:
        key = parts[-2] + '/' + parts[-1]
    else:
        continue

    encoded_id = base64.b64encode(urllib.parse.quote(str(usage), safe='').encode()).decode()

    categories = data.get('categories', [])
    if isinstance(categories, str):
        categories = [categories]

    contributes = data.get('contributes', [])
    if isinstance(contributes, str):
        contributes = [contributes]

    result[key] = {
        'usage': str(usage),
        'id': encoded_id,
        'categories': categories,
        'contributes': contributes,
        'fileModified': str(data.get('file-modified', '')),
        'image': str(data.get('image', '')),
        'imageAlt': str(data.get('image-alt', '')),
        'stars': int(str(data.get('stars', 0)).lstrip('0') or '0'),
        'template': data.get('template', False) is True,
        'example': data.get('example', False) is True,
        'license': str(data.get('license', '')),
        'author': str(data.get('author', '')),
        'login': str(data.get('login', '')),
    }

json.dump(result, sys.stdout)
")

# Merge extension.yml data with extensions.json using jq
echo "${yml_data_json}" | jq --slurpfile src "${source_file}" '
  . as $yml |
  # Build a reverse lookup from usage (without @version) to yml data
  (reduce (to_entries[]) as $e ({}; . + {($e.value.usage | split("@") | .[0]): $e.value})) as $usage_lookup |
  [$src[0] | to_entries[] |
    # Try exact key match, then usage-based, then truncated key (for subdirectory extensions)
    (($yml[.key] // $usage_lookup[.key] // $yml[(.key | split("/") | .[0:2] | join("/"))] // $usage_lookup[(.key | split("/") | .[0:2] | join("/"))]) // {}) as $y |
    select($y.usage != null and $y.usage != "") |
    {
      title: .value.title,
      description: (.value.description // ""),
      usage: $y.usage,
      id: $y.id,
      image: (if $y.image != "" then $y.image else ("/extensions/" + .key + "/extension.png") end),
      imageAlt: (if $y.imageAlt != "" then $y.imageAlt else ("GitHub repository OpenGraph image for " + .value.url) end),
      githubUrl: .value.url,
      author: (if $y.author != "" then $y.author else (.value.author // "") end),
      login: (if $y.login != "" then $y.login else .value.owner end),
      license: (if $y.license != "" then $y.license else (.value.licenseInfo // "") end),
      stars: (if $y.stars then $y.stars else .value.stargazerCount end),
      fileModified: (if $y.fileModified != "" then $y.fileModified else (.value.pushedAt // .value.updatedAt // "") end),
      categories: (if ($y.categories | length) > 0 then $y.categories else (.value.repositoryTopics // []) end),
      contributes: (if ($y.contributes | length) > 0 then $y.contributes else (.value.contributes // []) end),
      template: $y.template,
      example: $y.example,
      version: (if .value.latestRelease == "none" then "none" else .value.latestRelease end)
    }
  ]
' >"${output_file}"

count=$(jq 'length' "${output_file}")
echo "Generated ${output_file} with ${count} extensions"
