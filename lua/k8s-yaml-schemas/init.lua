local curl = require("plenary.curl")

local M = {
	schemas_catalog = "datreeio/CRDs-catalog",
	schema_catalog_branch = "main",
	github_base_api_url = "https://api.github.com/repos",
	github_headers = {
		Accept = "application/vnd.github+json",
		["X-GitHub-Api-Version"] = "2022-11-28",
	},
	schema_cache = {},
}

M.schema_url = "https://raw.githubusercontent.com/" .. M.schemas_catalog .. "/" .. M.schema_catalog_branch
M.flux_schemas_repo = "fluxcd-community/flux2-schemas"
M.flux_schema_url = "https://raw.githubusercontent.com/" .. M.flux_schemas_repo .. "/main"

-- List CRD schemas from GitHub (include both json and yaml)
M.list_github_tree = function()
	if M.schema_cache.trees then
		return M.schema_cache.trees
	end
	local url = M.github_base_api_url .. "/" .. M.schemas_catalog .. "/git/trees/" .. M.schema_catalog_branch
	local response = curl.get(url, { headers = M.github_headers, query = { recursive = 1 } })
	local body = vim.fn.json_decode(response.body)
	local trees = {}
	for _, tree in ipairs(body.tree) do
		if tree.type == "blob" and (tree.path:match("%.json$") or tree.path:match("%.yaml$")) then
			table.insert(trees, tree.path)
		end
	end
	M.schema_cache.trees = trees
	return trees
end

-- Extract apiVersion and kind from buffer content
M.extract_api_version_and_kind = function(buffer_content)
	buffer_content = buffer_content:gsub("%-%-%-%s*\n", "")
	local api_version = buffer_content:match("apiVersion:%s*([%w%p]+)")
	local kind = buffer_content:match("kind:%s*([%w%-]+)")
	return api_version, kind
end

-- Normalize CRD filename: pluralize kind, ignore version in filename
M.normalize_crd_name = function(api_version, kind)
	if not api_version or not kind then
		return nil
	end
	local group, version = api_version:match("([^/]+)/([^/]+)")
	if not group or not version then
		return nil
	end
	-- underscore before version, and lowercase kind
	return group .. "/" .. kind:lower() .. "_" .. version .. ".json"
end

-- Match CRD file from GitHub tree
M.match_crd = function(api_version, kind)
	local crd_name = M.normalize_crd_name(api_version, kind)
	if not crd_name then
		return nil
	end
	local all_crds = M.list_github_tree()
	for _, crd in ipairs(all_crds) do
		if crd:match(crd_name) then
			return crd
		end
	end
	return nil
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

-- Kubernetes core schema URL fallback
M.get_kubernetes_schema_url = function(api_version, kind)
	local version = api_version:match("/([%w%-]+)$") or api_version
	local schema_name = kind:lower() .. "-" .. version .. ".json"
	local base_url =
		"https://raw.githubusercontent.com/yannh/kubernetes-json-schema/refs/heads/master/master-standalone-strict/"

	local url_with_version = base_url .. schema_name
	local url_without_version = base_url .. kind:lower() .. ".json"

	local r1 = curl.get(url_with_version, { headers = M.github_headers })
	if r1.status == 200 then
		return url_with_version
	end

	local r2 = curl.get(url_without_version, { headers = M.github_headers })
	if r2.status == 200 then
		return url_without_version
	end

	return nil
end

-- Main entrypoint to attach schemas for a buffer
M.init = function(bufnr)
	if vim.b[bufnr].schema_attached then
		return
	end
	vim.b[bufnr].schema_attached = true

	local buffer_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

	local number_of_k8s_resources = select(2, string.gsub(buffer_content, "apiVersion:", ""))
	vim.notify("Number of apiVersion occurrences: " .. number_of_k8s_resources, vim.log.levels.DEBUG)
	if number_of_k8s_resources < 1 then
		vim.notify("No kubernets resources found in buffer " .. vim.api.nvim_buf_get_name(bufnr), vim.log.levels.DEBUG)
		return
	elseif number_of_k8s_resources > 1 then
		vim.notify(
			"Multiple resources in a single file not supported. Please split them or ignore the message.",
			vim.log.levels.INFO
		)
		return
	else
		local api_version, kind = M.extract_api_version_and_kind(buffer_content)

		local crd = M.match_crd(api_version, kind)
		-- Try Flux match
		if api_version and kind then
			local flux_url, flux_name = M.match_flux_crd(api_version, kind)
			if flux_url then
				M.attach_schema(flux_url, "Flux schema for " .. flux_name, bufnr)
				return
			end
		end

		if crd then
			local schema_url = M.schema_url .. "/" .. crd
			M.attach_schema(schema_url, "CRD schema for " .. crd, bufnr)
		else
			-- local api_version, kind = M.extract_api_version_and_kind(buffer_content)
			if api_version and kind then
				local url = M.get_kubernetes_schema_url(api_version, kind)
				if url then
					M.attach_schema(url, "Kubernetes schema for " .. kind, bufnr)
				else
					vim.notify(
						"No Kubernetes schema found for " .. kind .. " (" .. api_version .. ")",
						vim.log.levels.WARN
					)
				end
			else
				vim.notify(
					"No CRD or Kubernetes schema found. Falling back to default LSP configuration.",
					vim.log.levels.WARN
				)
			end
		end
	end
end

M.list_flux_schemas = function()
	if M.schema_cache.flux then
		return M.schema_cache.flux
	end
	local url = M.github_base_api_url .. "/" .. M.flux_schemas_repo .. "/contents"
	local response = curl.get(url, { headers = M.github_headers })
	local files = vim.fn.json_decode(response.body)
	local schemas = {}
	for _, file in ipairs(files) do
		if file.name:match("%.json$") and file.name ~= "_definitions.json" and file.name ~= "all.json" then
			table.insert(schemas, file.name)
		end
	end
	M.schema_cache.flux = schemas
	return schemas
end

M.match_flux_crd = function(api_version, kind)
	local group, version = api_version:match("([^/]+)/([^/]+)")
	if not group or not version then
		return nil
	end

	local group_segment = group:match("([^.]+)")
	if not group_segment then
		return nil
	end

	local expected_filename = kind:lower() .. "-" .. group_segment .. "-" .. version .. ".json"
	local all_flux = M.list_flux_schemas()
	for _, fname in ipairs(all_flux) do
		if fname == expected_filename then
			return M.flux_schema_url .. "/" .. fname, fname
		end
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
end

return M
