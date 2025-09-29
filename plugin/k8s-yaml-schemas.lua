-- plugin/k8s-yaml-schemas.lua
if vim.g.loaded_k8s_yaml_schemas then
	return
end
vim.g.loaded_k8s_yaml_schemas = true

-- Autocmd to attach schemas when yamlls is active
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

-- Optional: reload command
vim.api.nvim_create_user_command("K8sSchemasReload", function()
	require("k8s-yaml-schemas").reload()
end, {})
