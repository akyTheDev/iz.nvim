NVIM ?= nvim
DEPS := deps

.PHONY: test deps clean

deps: $(DEPS)/mini.nvim

$(DEPS)/mini.nvim:
	@mkdir -p $(DEPS)
	git clone --filter=blob:none --depth 1 https://github.com/echasnovski/mini.nvim $@

# Run every test file, or a single one with `make test FILE=tests/test_x.lua`.
test: deps
ifdef FILE
	$(NVIM) --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"
else
	$(NVIM) --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run()"
endif

clean:
	rm -rf $(DEPS)
