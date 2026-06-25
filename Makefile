TEST_DIR := tests
PLENARY := nvim --headless --noplugin -u tests/minimal_init.vim

.PHONY: test test-unit test-file

test:
	$(PLENARY) -c "PlenaryBustedDirectory $(TEST_DIR)/ {minimal_init = 'tests/minimal_init.vim'}"

test-unit:
	$(PLENARY) -c "PlenaryBustedDirectory $(TEST_DIR)/ {minimal_init = 'tests/minimal_init.vim', sequential = true}"

test-file:
	$(PLENARY) -c "PlenaryBustedFile $(FILE)"
