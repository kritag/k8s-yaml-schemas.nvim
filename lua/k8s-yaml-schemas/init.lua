-- lua/k8s-yaml-schemas.lua
local curl = require("plenary.curl")
local M = {
	schema_cache = {},
	config = {
		-- you can pass `sources` directly via setup(), or point to a config_file
		config_file = nil, -- e.g., vim.fn.stdpath('config') .. "/k8s-yaml-schemas.json"
		sources = nil, -- table form of the same schema as the file
		github_headers = {
			Accept = "application/vnd.github+json",
			["X-GitHub-Api-Version"] = "2022-11-28",
		},
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Small template renderer: replaces {{.Var}} with value
-- Supports variables we compute from apiVersion/kind
-- Also supports per-source KindSuffix via kind_suffix_style or template string
-- ─────────────────────────────────────────────────────────────────────────────
local function render_template(tpl, vars)
	if not tpl or tpl == "" then
		return ""
	end
	return (
		tpl:gsub("{{%s*%.([%w_]+)%s*}}", function(key)
			local v = vars[key]
			return v ~= nil and tostring(v) or ""
		end)
	)
end

local function parse_api_version(av)
	-- returns group (string or ""), version (string)
	if not av or av == "" then
		return "", ""
	end
	local g, v = av:match("^([^/]+)/([^/]+)$")
	if g and v then
		return g, v
	end
	-- core: e.g. "v1"
	return "", av
end

local function first_group_segment(group)
	if not group or group == "" then
		return ""
	end
	local seg = group:match("([^.]+)")
	return seg or group
end

local function compute_kind_suffix(style, vars, custom_tpl)
	if style == "none" then
		return ""
	elseif style == "flux" then
		-- -<GroupSegment>-<version>
		local gs = vars.GroupSegment or ""
		local v = vars.ResourceAPIVersion or ""
		if gs == "" then
			return "-" .. v
		end
		return "-" .. gs .. "-" .. v
	elseif style == "k8s" then
		-- -<version>
		return "-" .. (vars.ResourceAPIVersion or "")
	elseif type(style) == "string" and style ~= "" and style ~= "flux" and style ~= "k8s" then
		-- assume custom template string (e.g. "-{{.GroupSegment}}-{{.ResourceAPIVersion}}")
		return render_template(style, vars)
	elseif custom_tpl and custom_tpl ~= "" then
		return render_template(custom_tpl, vars)
	else
		-- default: -<version>
		return "-" .. (vars.ResourceAPIVersion or "")
	end
end

local function load_file_if_exists(path)
	if not path or path == "" then
		return nil
	end
	local stat = vim.loop.fs_stat(path)
	if not stat or stat.type ~= "file" then
		return nil
	end
	local ok, data = pcall(vim.fn.readfile, path)
	if not ok then
		vim.notify("k8s-yaml-schemas: failed reading " .. path, vim.log.levels.WARN)
		return nil
	end
	return table.concat(data, "\n")
end

local function parse_config_string(str, path_hint)
	-- detect by extension: .json or .yaml/.yml, else try JSON then YAML
	local function try_json()
		local ok, decoded = pcall(vim.fn.json_decode, str)
		return ok and decoded or nil
	end
	local function try_yaml()
		if not vim.fn.has("nvim-0.10") == 1 then
			return nil
		end
		if not vim.json or not vim.json.decode then
			-- nvim <= 0.9: fall back to crude yaml via tiny parser
			return nil
		end
		return nil
	end
	if path_hint and path_hint:match("%.json$") then
		return try_json()
	elseif path_hint and (path_hint:match("%.ya?ml$")) then
		-- best-effort yaml using community parser if present; else naive unmarshal
		-- Prefer plenary.yaml if available
		local ok_yaml, yaml = pcall(require, "yaml")
		if ok_yaml and yaml and yaml.load then
			local ok, t = pcall(yaml.load, str)
			if ok then
				return t
			end
		end
		-- fallback: try json anyway
		return try_json()
	else
		return try_json()
	end
end

local function default_sources()
	-- Mirrors your requested templates & order
	return {
		{
			name = "Flux",
			url_template = "https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/refs/heads/main/{{.ResourceKind}}{{.KindSuffix}}.json",
			kind_suffix_style = "flux",
			when = { group_regex = "(toolkit%.fluxcd%.io|fluxcd%.io)" },
		},
		{
			name = "Datree CRDs",
			url_template = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json",
		},
		{
			name = "OpenShift (melmorabity)",
			url_template = "https://raw.githubusercontent.com/melmorabity/openshift-json-schemas/refs/heads/main/v4.17-standalone-strict/{{.ResourceKind}}.json",
			kind_suffix_style = "none",
			when = { group_regex = "(^|%.)openshift(%.|$)" },
		},
		{
			name = "Kubernetes core",
			url_template = "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/refs/heads/master/master-standalone-strict/{{.ResourceKind}}{{.KindSuffix}}.json",
			kind_suffix_style = "k8s",
			when = { group_regex = "^$" },
		},
	}
end

local function deep_copy(t)
	return vim.deepcopy(t)
end

local function load_config()
	if M.schema_cache._config_loaded then
		return M.schema_cache._effective_config
	end

	local cfg = deep_copy(M.config)
	local file = cfg.config_file
		or vim.env.K8S_YAML_SCHEMAS_CONFIG
		or (vim.fn.stdpath("config") .. "/k8s-yaml-schemas.json")

	local sources_tbl = cfg.sources
	if not sources_tbl then
		local content = load_file_if_exists(file)
		if content then
			local decoded = parse_config_string(content, file)
			if type(decoded) == "table" and type(decoded.sources) == "table" then
				sources_tbl = decoded.sources
			end
		end
	end

	if not sources_tbl then
		sources_tbl = default_sources()
	end

	-- normalize: ensure each source has required fields
	for _, s in ipairs(sources_tbl) do
		s.name = s.name or "unnamed"
		s.url_template = assert(s.url_template, ("source '%s' missing url_template"):format(s.name))
	end

	local effective = {
		sources = sources_tbl,
		github_headers = cfg.github_headers,
	}

	M.schema_cache._effective_config = effective
	M.schema_cache._config_loaded = true
	return effective
end

-- User-facing setup() to override config_file or inline sources
M.setup = function(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	-- allow reload
	M.schema_cache._config_loaded = false
end

-- Build the variables used in template expansion
local function build_vars(api_version, kind, source)
	local group, version = parse_api_version(api_version or "")
	local vars = {
		Group = group or "",
		ResourceAPIVersion = version or "",
		ResourceKind = (kind or ""):lower(),
		GroupSegment = first_group_segment(group or ""),
		KindSuffix = "", -- filled below
	}

	local style = source.kind_suffix_style
	local custom_tpl = source.kind_suffix_template
	vars.KindSuffix = compute_kind_suffix(style, vars, custom_tpl)
	return vars
end

-- Check if source should apply based on `when` conditions
local function source_matches(source, group, kind)
	local w = source.when
	if not w then
		return true
	end

	if w.group_regex and w.group_regex ~= "" then
		local ok, m = pcall(function()
			return (group or ""):match(w.group_regex)
		end)
		if not ok or m == nil then
			return false
		end
	end
	if w.kind_in and type(w.kind_in) == "table" then
		local set = {}
		for _, k in ipairs(w.kind_in) do
			set[k:lower()] = true
		end
		if not set[(kind or ""):lower()] then
			return false
		end
	end
	return true
end

-- Try sources in order; return first 200
local function resolve_schema_url(api_version, kind)
	if not api_version or not kind then
		return nil, "missing apiVersion/kind"
	end
	local cfg = load_config()
	local group = select(1, parse_api_version(api_version))
	for _, source in ipairs(cfg.sources) do
		if source_matches(source, group, kind) then
			local vars = build_vars(api_version, kind, source)
			local url = render_template(source.url_template, vars)
			local resp = curl.get(url, { headers = cfg.github_headers, timeout = 8000 })
			if resp and resp.status == 200 then
				return url, source.name
			end
		end
	end
	return nil, "no schema resolved"
end

-- Attach schema to current buffer, scoped by filename
M.attach_schema = function(schema_url, description, bufnr)
	local clients = vim.lsp.get_clients({ name = "yamlls" })
	if #clients == 0 then
		vim.notify("yaml-language-server is not active.", vim.log.levels.WARN)
		return
	end
	local yaml_client = clients[1]
	yaml_client.config.settings = yaml_client.config.settings or {}
	yaml_client.config.settings.yaml = yaml_client.config.settings.yaml or {}
	yaml_client.config.settings.yaml.schemas = yaml_client.config.settings.yaml.schemas or {}
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	yaml_client.config.settings.yaml.schemas[schema_url] = { bufname }
	yaml_client.notify("workspace/didChangeConfiguration", {
		settings = yaml_client.config.settings,
	})
	vim.notify("Attached schema: " .. description, vim.log.levels.INFO)
end

-- Extract apiVersion and kind from buffer content
M.extract_api_version_and_kind = function(buffer_content)
	buffer_content = buffer_content:gsub("%-%-%-%s*\n", "")
	local api_version = buffer_content:match("apiVersion:%s*([%w%p]+)")
	local kind = buffer_content:match("kind:%s*([%w%-]+)")
	return api_version, kind
end

-- Main entrypoint to attach schemas for a buffer
M.init = function(bufnr)
	if vim.b[bufnr].schema_attached then
		return
	end
	vim.b[bufnr].schema_attached = true

	local buffer_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local api_version, kind = M.extract_api_version_and_kind(buffer_content)
	if not api_version or not kind then
		vim.notify("No apiVersion/kind detected in buffer.", vim.log.levels.WARN)
		return
	end

	local url, source_name = resolve_schema_url(api_version, kind)
	if url then
		M.attach_schema(url, (source_name or "Schema") .. " for " .. kind, bufnr)
	else
		vim.notify("No schema source yielded a match for " .. kind .. " (" .. api_version .. ")", vim.log.levels.WARN)
	end
end

M.setup_autocmd = function()
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "yaml",
		callback = function(args)
			local bufnr = args.buf
			local clients = vim.lsp.get_clients({ name = "yamlls", bufnr = bufnr })

			if #clients > 0 then
				require("k8s-yaml-schemas").init(bufnr)
			else
				vim.api.nvim_create_autocmd("LspAttach", {
					once = true,
					buffer = bufnr,
					callback = function(lsp_args)
						local client = vim.lsp.get_client_by_id(lsp_args.data.client_id)
						if client and client.name == "yamlls" then
							require("k8s-yaml-schemas").init(bufnr)
						end
					end,
				})
			end
		end,
	})

	-- Helper command to reload config on the fly
	vim.api.nvim_create_user_command("K8sSchemasReload", function()
		M.schema_cache._config_loaded = false
		vim.notify("k8s-yaml-schemas: configuration reloaded", vim.log.levels.INFO)
	end, {})
end

return M
