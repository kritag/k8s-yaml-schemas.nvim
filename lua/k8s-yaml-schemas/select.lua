-- Show and choose the schema yamlls applies to a YAML buffer.
-- The active schema label is kept in `vim.b.yaml_schema` (for statuslines);
-- :YamlSchema picks a schema and writes it as a `# yaml-language-server: $schema=` modeline.
local M = {}

local MODELINE = "# yaml-language-server: $schema="

-- Short label for the schemas yamlls reports for a buffer
local function label(res)
	local s = res and res[1]
	if not s then
		return "no schema"
	end
	local name = s.name
	if not name or name == "" then
		local parts = vim.split((s.uri:gsub("[?#].*", "")), "/", { plain = true })
		name = (parts[#parts]:gsub("%.[jy]?a?son$", ""):gsub("%.ya?ml$", ""))
		if name == "schema" then
			name = parts[#parts - 1]
		end
	end
	if vim.fn.strchars(name) > 34 then
		name = vim.fn.strcharpart(name, 0, 33) .. "…"
	end
	return #res > 1 and ("%s +%d"):format(name, #res - 1) or name
end

-- Ask yamlls which schemas apply to `bufnr` (settings, SchemaStore, modeline, this plugin) and store the label
M.refresh = function(bufnr)
	local client = vim.lsp.get_clients({ bufnr = bufnr, name = "yamlls" })[1]
	if not client or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	client:request("yaml/get/jsonSchema", vim.uri_from_bufnr(bufnr), function(err, res)
		if err or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		vim.b[bufnr].yaml_schema = label(res)
		vim.api.nvim_exec_autocmds("User", { pattern = "YamlSchemaChanged", data = { bufnr = bufnr } })
	end, bufnr)
end

local function refresh_later(bufnr, delay)
	vim.defer_fn(function()
		M.refresh(bufnr)
	end, delay)
end

-- Keep `vim.b.yaml_schema` current
M.setup_status = function()
	local group = vim.api.nvim_create_augroup("k8s_yaml_schemas_status", { clear = true })
	vim.api.nvim_create_autocmd({ "LspAttach", "BufEnter", "BufWritePost" }, {
		group = group,
		callback = function(ev)
			if vim.bo[ev.buf].filetype == "yaml" then
				-- yamlls needs a moment after attaching before it knows its schemas
				refresh_later(ev.buf, ev.event == "LspAttach" and 1000 or 300)
			end
		end,
	})
	-- fired by attach_schema() once this plugin has handed a schema to yamlls
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "K8sSchemasAttached",
		callback = function(ev)
			refresh_later(ev.data.bufnr, 500)
		end,
	})
end

-- Set, replace (or with nil, remove) the schema modeline in the first lines of the buffer
M.set_modeline = function(bufnr, url)
	local idx
	for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)) do
		if line:find("^#%s*yaml%-language%-server:%s*%$schema=") then
			idx = i - 1
			break
		end
	end
	local new = url and { MODELINE .. url } or {}
	if idx then
		vim.api.nvim_buf_set_lines(bufnr, idx, idx + 1, false, new)
	elseif url then
		vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, new)
	end
	refresh_later(bufnr, 1000)
end

M.apply = function(bufnr, item)
	if not item then
		return
	elseif item.remove then
		M.set_modeline(bufnr, nil)
	elseif item.custom then
		vim.ui.input({ prompt = "Schema URL or path: " }, function(value)
			if value and value ~= "" then
				M.set_modeline(bufnr, value)
			end
		end)
	elseif item.source then
		local k8s = require("k8s-yaml-schemas")
		local av, kind = k8s.extract_api_version_and_kind(table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"))
		local default = av and kind and (av .. " " .. kind) or ""
		vim.ui.input({ prompt = item.source.name .. " schema for (apiVersion kind): ", default = default }, function(value)
			local api_version, k = (value or ""):match("^%s*(%S+)%s+(%S+)%s*$")
			if not api_version then
				return
			end
			local url = k8s.source_url(item.source, api_version, k)
			if url then
				M.set_modeline(bufnr, url)
			else
				vim.notify(("No %s schema for %s (%s)"):format(item.source.name, k, api_version), vim.log.levels.WARN)
			end
		end)
	else
		M.set_modeline(bufnr, item.url)
	end
end

-- Pick a schema from the SchemaStore catalog (needs b0o/SchemaStore.nvim) via vim.ui.select
M.pick = function()
	local bufnr = vim.api.nvim_get_current_buf()
	local items = {
		{ name = "Remove schema comment", remove = true },
		{ name = "Custom URL or path…", custom = true },
	}
	-- one entry per configured source (Flux, CRDs, Kubernetes, …); asks for apiVersion and kind
	for _, source in ipairs(require("k8s-yaml-schemas").sources()) do
		items[#items + 1] = { name = source.name .. " for a kind…", desc = "build the URL from this source", source = source }
	end
	local ok, schemastore = pcall(require, "schemastore")
	if ok then
		for _, s in ipairs(schemastore.json.schemas()) do
			items[#items + 1] = { name = s.name, desc = s.description, url = s.url }
		end
	end
	vim.ui.select(items, {
		prompt = "YAML schema",
		format_item = function(item)
			return item.desc and (item.name .. " – " .. item.desc) or item.name
		end,
		-- snacks.nvim sizes the list as min(#items, lines * 0.8 - 10), which is fractional for most window
		-- heights and makes nvim_win_set_config fail ("Number is not integral"). Ignored by other pickers.
		snacks = {
			layout = {
				config = function(layout)
					for _, box in ipairs(layout.layout) do
						if box.win == "list" then
							box.height = math.floor(math.max(math.min(#items, vim.o.lines * 0.8 - 10), 2))
						end
					end
				end,
			},
		},
	}, function(item)
		M.apply(bufnr, item)
	end)
end

return M
