NVIM ?= nvim

.PHONY: test test-gh

test:
ifdef FILE
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"
else
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"
endif

GH_FILES := { 'tests/test_github_read.lua', 'tests/test_github_write.lua' }

test-gh:
	DIFFY_TESTGH=1 $(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return $(GH_FILES) end } })"
