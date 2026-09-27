NVIM ?= nvim

.PHONY: test test-gh

test:
ifdef FILE
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"
else
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"
endif

test-gh:
	@echo "diffy: test-gh (live GitHub scenarios) lands in phase 7" >&2
	@exit 1
