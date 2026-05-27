# 🧬 k8s-yaml-schemas.nvim

> Auto-attach Kubernetes & CRD schemas to `yaml-language-server` in Neovim 🧠⚡

`k8s-yaml-schemas.nvim` enhances your YAML editing experience for Kubernetes manifests by dynamically detecting the `apiVersion` and `kind` in your buffer, then attaching the appropriate JSON schema for validation and autocompletion via `yamlls`. No file name matching needed!

- 🚀 **Lazy-loadable**: Loads only for `yaml` files
- 🔎 **Smart detection**: Extracts `apiVersion` and `kind`
- 🔗 **Dynamic schema fetching**: Supports Kubernetes core + CRDs + Flux (via GitHub)
- ✅ **Better LSP UX**: Proper validation, better hover/completion support
- 🧠 **Schema caching**: Avoids repeated requests

---

## ✨ Features

- Detects and attaches:
  - ✅ Core Kubernetes resource schemas (from [kubernetes-json-schema](https://github.com/yannh/kubernetes-json-schema))
  - 🧩 Custom Resource Definitions (from [datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog))
  - 🔁 Flux schemas (from [fluxcd-community/flux2-schemas](https://github.com/fluxcd-community/flux2-schemas))
- Works only when `yaml-language-server` is active
- Automatically syncs schema configuration with LSP
- Fully async and performance-aware (uses `plenary.curl`)

---

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

---

## ⚙️ Requirements

- Neovim `>=0.8`
- [yaml-language-server](https://github.com/redhat-developer/yaml-language-server) via `lspconfig`
- [`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim)
- [`yq`](https://github.com/mikefarah/yq) — required for YAML config files (optional if using JSON)

---

## ⚙️ Configuration

By default, the plugin ships with built-in sources (Flux, Datree CRDs, OpenShift, Kubernetes). You can override them entirely via a config file — useful for adding private/internal schema servers.

The config file is looked up in this order:
1. `config_file` passed to `setup()`
2. `$K8S_YAML_SCHEMAS_CONFIG` environment variable
3. `~/.config/nvim/k8s-yaml-schemas.json` (default)

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

| Variable | Example | Description |
|---|---|---|
| `{{.ResourceKind}}` | `cronjob` | Lowercased `kind` |
| `{{.Group}}` | `batch` | API group (empty for core) |
| `{{.ResourceAPIVersion}}` | `v1` | Version part of `apiVersion` |
| `{{.GroupSegment}}` | `batch` | First segment of group |
| `{{.KindSuffix}}` | `-batch-v1` | Computed suffix (see below) |

### `kind_suffix_style` values

| Style | Suffix produced | Example filename |
|---|---|---|
| `flux` | `-<group>-<version>` or `-<version>` for core | `cronjob-batch-v1.json` |
| `k8s` | `-<version>` | `cronjob-v1.json` |
| `none` | _(empty)_ | `cronjob.json` |
| _(custom template)_ | e.g. `"-{{.GroupSegment}}-{{.ResourceAPIVersion}}"` | custom |

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

---

## 🔍 How It Works

1. On opening a YAML file, it waits for `yamlls` to attach.
2. It reads the buffer, extracts `apiVersion` and `kind`.
3. It tries to match a CRD schema from `datreeio/CRDs-catalog`.
4. If no CRD matches, it tries the core Kubernetes schema, or a Flux schema.
5. It attaches the found schema to the current buffer via `yamlls`.

No manual YAML schema linking needed, and no file name matching required!

---

## 🛠️ Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
```

💡 `k8s-yaml-schemas.nvim` will auto-link the correct Deployment schema from Kubernetes `apps/v1` without you lifting a finger.

---

## 🤖 Manual Trigger

Want to run it manually?

```lua
require("k8s_yaml_schemas").init(0) -- 0 = current buffer
```

---

## 🧪 Debugging

- Check for messages via `:messages`
- If `yamlls` is not running, schema won't attach
- CRD matching depends on consistent `group/kind_version.json` format

---

## 📚 Credits

- [yannh/kubernetes-json-schema](https://github.com/yannh/kubernetes-json-schema)
- [datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog)
- Inspired by native support in `kubectl explain` and `helm schema-gen`

---

## 🔧 TODO

- Implement support for multiple object definitions in one file. Currentl not supported by `yamlls`. [#946](https://github.com/redhat-developer/yaml-language-server/issues/946)

---

## 📝 License

This project is licensed under the terms of the **GNU General Public License v3.0**.
See [LICENSE](./LICENSE) for details.
