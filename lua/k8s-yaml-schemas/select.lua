-- Show and choose the schema yamlls applies to a YAML buffer.
-- The active schema label is kept in `vim.b.yaml_schema` (for statuslines; see M.status);
-- :YamlSchema picks a schema and attaches it to the buffer for this session (nothing is written to the file).
local M = {}

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
		-- uninformative file names: prefix the folder, e.g. "v1.30-standalone/all"
		if name == "schema" or name == "all" or name == "index" then
			name = parts[#parts - 1] .. "/" .. name
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
		-- with a schema per document, yamlls lists the schemas of every document; show one label instead
		vim.b[bufnr].yaml_schema = vim.b[bufnr].k8s_schemas_per_document and "kubernetes (per document)" or label(res)
		vim.cmd.redrawstatus()
	end, bufnr)
end

local function refresh_later(bufnr, delay)
	vim.defer_fn(function()
		M.refresh(bufnr)
	end, delay)
end

-- Text for a statusline: the schema label, or with a schema per document the kind under the cursor
M.status = function()
	local label = vim.b.yaml_schema
	if not label or not vim.b.k8s_schemas_per_document then
		return label or ""
	end
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local first, last = 1, #lines
	for i = row, 1, -1 do
		if lines[i]:match("^%-%-%-") then
			first = i + 1
			break
		end
	end
	for i = row + 1, #lines do
		if lines[i]:match("^%-%-%-") then
			last = i - 1
			break
		end
	end
	for i = first, last do
		local kind = lines[i]:match("^kind:%s*([%w%-%.]+)")
		if kind then
			return "kubernetes: " .. kind
		end
	end
	return label
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

-- Attach `url` to the buffer (replacing the current schema). A modeline in the file still wins over it.
M.set_schema = function(bufnr, url, name)
	for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)) do
		if line:find("^#%s*yaml%-language%-server:%s*%$schema=") then
			vim.notify("This file has a $schema comment, which overrides the schema you picked.", vim.log.levels.WARN)
			break
		end
	end
	require("k8s-yaml-schemas").attach_schema(url, name or url:gsub("[?#].*", ""):match("([^/]+)$") or url, bufnr)
end

-- vim.ui.select. snacks.nvim sizes the list as min(#items, lines * 0.8 - 10), which is fractional for most
-- window heights and makes nvim_win_set_config fail ("Number is not integral"); the snacks key fixes that
-- and is ignored by other pickers.
local function select(items, prompt, format_item, on_choice)
	vim.ui.select(items, {
		prompt = prompt,
		format_item = format_item,
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
	}, on_choice)
end

-- Ask for apiVersion and kind and build the URL from one source's template
local function apply_kind(bufnr, source)
	local k8s = require("k8s-yaml-schemas")
	local av, kind = k8s.extract_api_version_and_kind(table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"))
	local default = av and kind and (av .. " " .. kind) or ""
	vim.ui.input({ prompt = source.name .. " schema for (apiVersion kind): ", default = default }, function(value)
		local api_version, k = (value or ""):match("^%s*(%S+)%s+(%S+)%s*$")
		if not api_version then
			return
		end
		local url = k8s.source_url(source, api_version, k)
		if url then
			M.set_schema(bufnr, url, source.name .. " for " .. k)
		else
			vim.notify(("No %s schema for %s (%s)"):format(source.name, k, api_version), vim.log.levels.WARN)
		end
	end)
end

-- Walk a directory listing: pick a folder to go into it, a .json file to use it
local function browse(bufnr, source, url, base)
	local entries, reason = require("k8s-yaml-schemas.catalog").index(url)
	if not entries then
		vim.notify(("%s: %s"):format(source.name, reason), vim.log.levels.WARN)
		return
	end
	local items = {}
	if url ~= base then
		items[1] = { name = "../", up = true, url = url:gsub("[^/]+/$", "") }
	end
	vim.list_extend(items, entries)
	select(items, source.name .. " " .. url:sub(#base + 1), function(e)
		return e.name
	end, function(e)
		if not e then
			return
		elseif e.up or e.dir then
			browse(bufnr, source, e.url, base)
		else
			M.set_schema(bufnr, e.url, source.name .. " " .. e.url:sub(#base + 1))
		end
	end)
end

M.apply = function(bufnr, item)
	if not item then
		return
	elseif item.remove then
		require("k8s-yaml-schemas").reset_schema(bufnr)
	elseif item.custom then
		vim.ui.input({ prompt = "Schema URL or path: " }, function(value)
			if value and value ~= "" then
				M.set_schema(bufnr, value)
			end
		end)
	elseif item.source then
		local k8s = require("k8s-yaml-schemas")
		local files, reason = require("k8s-yaml-schemas.catalog").list(item.source, k8s.github_headers())
		if files then
			select(files, item.source.name .. " schema", function(f)
				return f.path
			end, function(f)
				if f then
					M.set_schema(bufnr, f.url, item.source.name .. " " .. f.path)
				end
			end)
		else
			-- not on GitHub: browse the server's directory listing, if it has one
			local catalog = require("k8s-yaml-schemas.catalog")
			local base = catalog.static_base(item.source.url_template)
			if base and catalog.index(base) then
				browse(bufnr, item.source, base, base)
			else
				vim.notify(("%s: %s. Enter apiVersion and kind instead."):format(item.source.name, reason), vim.log.levels.INFO)
				apply_kind(bufnr, item.source)
			end
		end
	else
		M.set_schema(bufnr, item.url, item.name)
	end
end

-- Pick a schema from the SchemaStore catalog (needs b0o/SchemaStore.nvim) or from one of the configured sources
M.pick = function()
	local bufnr = vim.api.nvim_get_current_buf()
	local items = {
		{ name = "Reset to auto-detect", remove = true },
		{ name = "Custom URL or path…", custom = true },
	}
	-- one entry per configured source (Flux, CRDs, Kubernetes, …); opens that source's schema list
	for _, source in ipairs(require("k8s-yaml-schemas").sources()) do
		items[#items + 1] = { name = source.name .. " schemas…", desc = "search this source", source = source }
	end
	local ok, schemastore = pcall(require, "schemastore")
	if ok then
		for _, s in ipairs(schemastore.json.schemas()) do
			items[#items + 1] = { name = s.name, desc = s.description, url = s.url }
		end
	end
	select(items, "YAML schema", function(item)
		return item.desc and (item.name .. " – " .. item.desc) or item.name
	end, function(item)
		M.apply(bufnr, item)
	end)
end

return M
