# 🧬 k8s-yaml-schemas.nvim

> Auto-attach Kubernetes & CRD schemas to `yaml-language-server` in Neovim 🧠⚡

`k8s-yaml-schemas.nvim` enhances your YAML editing experience for Kubernetes
manifests by dynamically detecting the `apiVersion` and `kind` in your buffer,
then attaching the appropriate JSON schema for validation and autocompletion via
`yamlls`. No file name matching needed!

- 🚀 **Lazy-loadable**: Loads only for `yaml` files
- 🔎 **Smart detection**: Extracts `apiVersion` and `kind`
- 🔗 **Dynamic schema fetching**: Supports Kubernetes core + CRDs + Flux (via
  GitHub)
- ✅ **Better LSP UX**: Proper validation, better hover/completion support
- 🧠 **Schema caching**: Avoids repeated requests
- 🎯 **Manual override**: `:YamlSchema` picks any SchemaStore schema
- 🏷️ **Statusline info**: the active schema in `vim.b.yaml_schema`

______________________________________________________________________

## ✨ Features

- Detects and attaches:
    - ✅ Core Kubernetes resource schemas (from
      [kubernetes-json-schema](https://github.com/yannh/kubernetes-json-schema))
    - 🧩 Custom Resource Definitions (from
      [datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog))
    - 🔁 Flux schemas (from
      [fluxcd-community/flux2-schemas](https://github.com/fluxcd-community/flux2-schemas))
- Works only when `yaml-language-server` is active
- Automatically syncs schema configuration with LSP
- Fully async and performance-aware (uses `plenary.curl`)

______________________________________________________________________

## 📦 Installation

### Using [Lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "kritag/k8s-yaml-schemas.nvim",
  event = "FileType yaml",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("k8s-yaml-schemas").setup_autocmd()
  end,
}
```

______________________________________________________________________

## ⚙️ Requirements

- Neovim `>=0.8`
- [yaml-language-server](https://github.com/redhat-developer/yaml-language-server)
  via `lspconfig`
- [`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim)
- [`yq`](https://github.com/mikefarah/yq) — required for YAML config files
  (optional if using JSON)

______________________________________________________________________

## ⚙️ Configuration

By default, the plugin ships with built-in sources (Flux, Datree CRDs,
OpenShift, Kubernetes). You can override them entirely via a config file —
useful for adding private/internal schema servers.

The config file is looked up in this order:

1. `config_file` passed to `setup()`
1. `$K8S_YAML_SCHEMAS_CONFIG` environment variable
1. `~/.config/nvim/k8s-yaml-schemas.json` (default)

Both `.yaml` and `.json` formats are supported (YAML requires `yq` in `$PATH`).

### Config file format

```yaml
sources:
  - name: Flux
    url_template: "https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/refs/heads/main/{{.ResourceKind}}{{.KindSuffix}}.json"
    kind_suffix_style: flux
    when:
      group_regex: "(toolkit\\.fluxcd\\.io|fluxcd\\.io)"

  - name: Datree CRDs
    url_template: "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

  - name: Kubernetes (yannh)
    url_template: "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/refs/heads/master/master-standalone-strict/{{.ResourceKind}}{{.KindSuffix}}.json"
    kind_suffix_style: flux
```

### Available template variables

| Variable                  | Example     | Description                  |
| ------------------------- | ----------- | ---------------------------- |
| `{{.ResourceKind}}`       | `cronjob`   | Lowercased `kind`            |
| `{{.Group}}`              | `batch`     | API group (empty for core)   |
| `{{.ResourceAPIVersion}}` | `v1`        | Version part of `apiVersion` |
| `{{.GroupSegment}}`       | `batch`     | First segment of group       |
| `{{.KindSuffix}}`         | `-batch-v1` | Computed suffix (see below)  |

### `kind_suffix_style` values

| Style               | Suffix produced                                     | Example filename        |
| ------------------- | --------------------------------------------------- | ----------------------- |
| `flux`              | `-<group>-<version>` or `-<version>` for core       | `cronjob-batch-v1.json` |
| `k8s`               | `-<version>`                                        | `cronjob-v1.json`       |
| `none`              | _(empty)_                                           | `cronjob.json`          |
| _(custom template)_ | e.g. `"-{{.GroupSegment}}-{{.ResourceAPIVersion}}"` | custom                  |

### `when` conditions

Sources can be filtered with a `when` block:

```yaml
when:
  group_regex: "^$"          # only core group (Pod, Service, …)
  kind_in: ["Deployment"]    # restrict to specific kinds
```

### Pointing to a custom config file

```lua
require("k8s-yaml-schemas").setup({
  config_file = vim.fn.expand("~/.config/k8s/k8s-yaml-schemas.yaml"),
})
```

To reload the config at runtime (e.g. after editing the file):

```vim
:K8sSchemasReload
```

______________________________________________________________________

## 🔍 How It Works

1. On opening a YAML file, it waits for `yamlls` to attach.
1. It reads the buffer, extracts `apiVersion` and `kind`.
1. It tries to match a CRD schema from `datreeio/CRDs-catalog`.
1. If no CRD matches, it tries the core Kubernetes schema, or a Flux schema.
1. It attaches the found schema to the current buffer via `yamlls`.

No manual YAML schema linking needed, and no file name matching required!

______________________________________________________________________

## 📚 Files With Several Objects

`yamlls` attaches one schema to a whole file, so attaching the first object's
schema to a file with several objects (`---` separated) marks every other object
as invalid. When a file has more than one top-level `apiVersion:`, the plugin
instead maps the file to the `kubernetes` keyword of `yamlls`. `yamlls` then
picks a schema per document from its `apiVersion` and `kind`: core kinds from its
built-in Kubernetes schema, custom resources from the CRD store (by default
[datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog), configurable
with `yaml.kubernetesCRDStore.url`).

The statusline label reads `kubernetes (per document)` for these files.

Things to know:

- This path does not use your configured `sources`. Only `yamlls`' own Kubernetes
  and CRD store schemas apply. A custom resource missing from the CRD store shows
  `Unable to load schema from …` on that document.
- To use one of your sources as the CRD store instead of datree, name it in
  `crd_store_source`. Its `url_template` must end in
  `/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json`, the datree layout.
  The URL stays in your config file, not in your Neovim config:

```lua
require("k8s-yaml-schemas").setup({ crd_store_source = "My internal schemas" })
```

- Files with a single object keep the normal lookup, which does use your sources.
- Picking a schema with `:YamlSchema` still replaces it for the whole file;
  "Reset to auto-detect" switches back.
- To keep the old behavior (first object's schema for the file):

```lua
require("k8s-yaml-schemas").setup({ multi_document = false })
```

______________________________________________________________________

## 🛠️ Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
```

💡 `k8s-yaml-schemas.nvim` will auto-link the correct Deployment schema from
Kubernetes `apps/v1` without you lifting a finger.

______________________________________________________________________

## 🤖 Manual Trigger

Want to run it manually?

```lua
require("k8s_yaml_schemas").init(0) -- 0 = current buffer
```

______________________________________________________________________

## 🎯 Choosing a Schema Manually

```vim
:YamlSchema
```

Opens a picker (via `vim.ui.select`, so it becomes a fuzzy finder if you use
snacks, telescope or fzf-lua) with the full
[SchemaStore](https://www.schemastore.org) catalog. The chosen schema replaces the
one attached to the buffer. Nothing is written to the file, so a private schema
URL never ends up in your repo. The choice lasts until you close the buffer or
restart Neovim; after that the schema is detected automatically again. It also
works to override a wrong match on a Kubernetes manifest.

If the file starts with a `# yaml-language-server: $schema=…` comment, that
comment still wins, and the plugin warns you about it.

Extra entries sit at the top of the list:

- **Reset to auto-detect**: drops the chosen schema and detects it again from
  `apiVersion` and `kind`
- **Custom URL or path…**: prompts for any schema URL or local file
- **`<source> schemas…`**: one entry per configured source (Flux, Datree CRDs,
  Kubernetes, and any you added). It opens a second picker with every schema
  file that source offers, so you can search it, for example `kustomization` in
  the Flux list. Listing works for sources whose `url_template` points at
  `raw.githubusercontent.com`; it reads the repo's file tree through the GitHub
  API (60 requests per hour without a token, so set `GITHUB_TOKEN` if you hit the
  limit). For any other source, the plugin looks for a web server directory
  listing (nginx or Apache autoindex) at the template's fixed path, the part
  before the first `{{variable}}`, and lets you walk it: pick a folder to go into
  it, `../` to go back up, or a `.json` file to use it. If there is no listing,
  it asks for `apiVersion kind` instead (prefilled from the buffer), builds the
  URL from the `url_template`, and only attaches it if the schema exists. The source's `when` filter is ignored here.

The SchemaStore catalog needs
[`b0o/SchemaStore.nvim`](https://github.com/b0o/SchemaStore.nvim). Without it,
only the extra entries are available.

______________________________________________________________________

## 🏷️ Showing the Active Schema in a Statusline

The plugin asks `yamlls` (`yaml/get/jsonSchema`) which schemas apply to the
buffer and stores a short label in `vim.b.yaml_schema`, or `no schema` if there
is none. This covers every source: `yamlls` settings, SchemaStore, a modeline,
and this plugin. If several schemas apply, the label reads `name +N`.

The label refreshes on `LspAttach`, `BufEnter`, `BufWritePost`, and after the
plugin attaches a schema, and the statusline is redrawn each time. Example for
[lualine](https://github.com/nvim-lualine/lualine.nvim):

```lua
{
  function()
    return require("k8s-yaml-schemas.select").status()
  end,
  cond = function()
    return vim.bo.filetype == "yaml" and vim.b.yaml_schema ~= nil
  end,
}
```

`status()` returns the label. In a file with a schema per document (see below)
it follows the cursor and shows the kind of the document you are in, for example
`kubernetes: RoleBinding`. To show only the label, return `vim.b.yaml_schema`
instead.

The plugin fires `User K8sSchemasAttached` (with `data.bufnr`) after it hands a
schema to `yamlls`.

______________________________________________________________________

## 🔒 SOPS-encrypted files

Files encrypted with [SOPS](https://github.com/getsops/sops) contain a top-level
`sops:` key that is not part of any Kubernetes schema. The plugin detects this
automatically and skips schema attachment for those files, avoiding
false-positive validation errors.

______________________________________________________________________

## 🧪 Debugging

- Check for messages via `:messages`
- If `yamlls` is not running, schema won't attach
- CRD matching depends on consistent `group/kind_version.json` format

______________________________________________________________________

## 📚 Credits

- [yannh/kubernetes-json-schema](https://github.com/yannh/kubernetes-json-schema)
- [datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog)
- Inspired by native support in `kubectl explain` and `helm schema-gen`

______________________________________________________________________

## 📝 License

This project is licensed under the terms of the **GNU General Public License
v3.0**. See [LICENSE](./LICENSE) for details.
