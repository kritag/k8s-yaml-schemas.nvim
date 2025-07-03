# 🧬 k8s-yaml-schemas.nvim

> Auto-attach Kubernetes & CRD schemas to `yaml-language-server` in Neovim 🧠⚡

`k8s-yaml-schemas.nvim` enhances your YAML editing experience for Kubernetes manifests by dynamically detecting the `apiVersion` and `kind` in your buffer, then attaching the appropriate JSON schema for validation and autocompletion via `yamlls`.

- 🚀 **Lazy-loadable**: Loads only for `yaml` files
- 🔎 **Smart detection**: Extracts `apiVersion` and `kind`
- 🔗 **Dynamic schema fetching**: Supports Kubernetes core + CRDs (via GitHub)
- ✅ **Better LSP UX**: Proper validation, better hover/completion support
- 🧠 **Schema caching**: Avoids repeated requests

---

## ✨ Features

- Detects and attaches:
  - ✅ Core Kubernetes resource schemas (from [kubernetes-json-schema](https://github.com/yannh/kubernetes-json-schema))
  - 🧩 Custom Resource Definitions (from [datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog))
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
    require("k8s_yaml_schema").setup_autocmd()
  end,
}
```

---

## ⚙️ Requirements

- Neovim `>=0.8`
- [yaml-language-server](https://github.com/redhat-developer/yaml-language-server) via `lspconfig`
- [`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim)

---

## 🔍 How It Works

1. On opening a YAML file, it waits for `yamlls` to attach.
2. It reads the buffer, extracts `apiVersion` and `kind`.
3. It tries to match a CRD schema from `datreeio/CRDs-catalog`.
4. If no CRD matches, it tries the core Kubernetes schema.
5. It attaches the found schema to the current buffer via `yamlls`.

No manual YAML schema linking needed.

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
require("k8s_yaml_schema").init(0) -- 0 = current buffer
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

## 📝 License

This project is licensed under the terms of the **GNU General Public License v3.0**.
See [LICENSE](./LICENSE) for details.
